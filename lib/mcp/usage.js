// Usage accounting and daily caps, per principal ("local" over stdio, the token's name over HTTP).
// Numbers are ESTIMATES: model calls are counted from the debate transcript; tokens are characters / 4.
// State is one JSON file per principal under E3D_MCP_STATE_DIR (default ~/.e3d-pilot/usage), written
// atomically, so budgets survive restarts. Days are UTC. 0 or unset = unlimited.
import { mkdir, readFile, writeFile, rename, rmdir, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { text } from './util.js';

const today = () => new Date().toISOString().slice(0, 10);
const safeName = (p) => String(p).replace(/[^A-Za-z0-9_.-]/g, '_').slice(0, 80) || 'local';
const num = (v) => { const n = Number.parseInt(v ?? '', 10); return Number.isFinite(n) && n >= 0 ? n : null; };
export const estTokens = (chars) => Math.ceil(chars / 4);

export function createUsage({ env = process.env, defaults = { calls: 0, tokens: 0 } } = {}) {
  const dir = env.E3D_MCP_STATE_DIR || join(homedir(), '.e3d-pilot', 'usage');
  const limits = {
    calls: num(env.E3D_MCP_DAILY_CALLS) ?? defaults.calls,
    tokens: num(env.E3D_MCP_DAILY_EST_TOKENS) ?? defaults.tokens,
  };
  const chains = new Map(); // principal -> promise, serializes read-modify-write inside this process

  const fileFor = (principal) => join(dir, `${safeName(principal)}.json`);
  async function load(principal) {
    try {
      const s = JSON.parse(await readFile(fileFor(principal), 'utf8'));
      if (s.day === today()) return s;
    } catch { /* first use or unreadable: start fresh */ }
    return { day: today(), calls: 0, est_input_tokens: 0, est_output_tokens: 0, debates: 0, jobs: 0 };
  }
  const nextResetIso = () => { const d = new Date(); return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 1)).toISOString(); };
  const budgetView = (principal, s) => ({
    principal, day: s.day, resets_at: nextResetIso(), state_file: fileFor(principal), calls_today: s.calls, calls_limit: limits.calls || null,
    est_tokens_today: s.est_input_tokens + s.est_output_tokens, est_tokens_limit: limits.tokens || null,
    remaining_calls: limits.calls ? Math.max(limits.calls - s.calls, 0) : null,
    remaining_est_tokens: limits.tokens ? Math.max(limits.tokens - s.est_input_tokens - s.est_output_tokens, 0) : null,
  });
  // Two layers: a promise chain serializes work inside this process; a lock directory serializes it across processes
  // (several editor windows can run one server each against the same counter file). A lock older than 30 s is stale.
  const fileLocked = async (principal, fn) => {
    const lock = `${fileFor(principal)}.lock`;
    await mkdir(dir, { recursive: true });
    const deadline = Date.now() + 8000;
    for (;;) {
      try { await mkdir(lock); break; } catch (e) {
        if (e.code !== 'EEXIST') throw e;
        try { if (Date.now() - (await stat(lock)).mtimeMs > 30000) { await rmdir(lock); continue; } } catch { continue; }
        if (Date.now() > deadline) throw new Error('could not lock the usage counter (another e3d-mcp process is holding it)');
        await new Promise((r) => setTimeout(r, 25 + Math.random() * 50));
      }
    }
    try { return await fn(); } finally { await rmdir(lock).catch(() => {}); }
  };
  const withLock = (principal, fn) => {
    const run = () => fileLocked(principal, fn);
    const next = (chains.get(principal) ?? Promise.resolve()).then(run, run);
    chains.set(principal, next.catch(() => {}));
    return next;
  };

  async function persist(principal, s) {
    await mkdir(dir, { recursive: true });
    const file = fileFor(principal);
    await writeFile(`${file}.tmp`, `${JSON.stringify(s)}\n`);
    await rename(`${file}.tmp`, file);
  }
  function refusalFor(principal, s, budget, { calls, tokens }) {
    if (limits.calls && s.calls + calls > limits.calls) {
      return `this request could use up to ${calls} model calls but only ${budget.remaining_calls} of today's ${limits.calls} remain for "${principal}" (resets at 00:00 UTC; raise E3D_MCP_DAILY_CALLS)`;
    }
    if (limits.tokens && s.est_input_tokens + s.est_output_tokens + tokens > limits.tokens) {
      return `this request could use about ${tokens} tokens (estimate) but only ${budget.remaining_est_tokens} of today's ${limits.tokens} remain for "${principal}" (resets at 00:00 UTC; raise E3D_MCP_DAILY_EST_TOKENS)`;
    }
    return null;
  }

  return {
    limits, dir,
    async snapshot(principal) { return budgetView(principal, await load(principal)); },

    // Would a request that could use up to `calls` / `tokens` stay inside today's caps? Nothing is spent here.
    async check(principal, { calls, tokens }) {
      const s = await load(principal);
      const budget = budgetView(principal, s);
      const reason = refusalFor(principal, s, budget, { calls, tokens });
      return reason ? { ok: false, budget, reason } : { ok: true, budget };
    },

    // Records what a finished debate actually used (estimates) and returns the updated budget.
    record(principal, { calls, inTokens, outTokens, kind = 'debate' }) {
      return withLock(principal, async () => {
        const s = await load(principal);
        s.calls += calls; s.est_input_tokens += inTokens; s.est_output_tokens += outTokens;
        if (kind === 'debate') s.debates += 1; else s.jobs = (s.jobs ?? 0) + 1;
        await persist(principal, s);
        return budgetView(principal, s);
      });
    },

    // Reserves what a request could use BEFORE it runs: check the caps and record the reservation in one locked step, so
    // concurrent requests (even from other processes) cannot all pass the same check. A debate reserves its worst case and
    // then settles to what it actually used; a pipeline job (discover/ideate, draft+negotiate, execute) spends credits that
    // cannot be measured from here, so its reservation is a conservative estimate that stays.
    // Returns { ok: false, reason, budget } and records nothing when the reservation would break a cap.
    reserve(principal, cost, kind = 'job') {
      return withLock(principal, async () => {
        const s = await load(principal);
        const budget = budgetView(principal, s);
        const reason = refusalFor(principal, s, budget, cost);
        if (reason) return { ok: false, budget, reason };
        s.calls += cost.calls; s.est_input_tokens += cost.tokens;
        if (kind === 'debate') s.debates += 1; else s.jobs = (s.jobs ?? 0) + 1;
        await persist(principal, s);
        return { ok: true, budget: budgetView(principal, s), reserved: { kind, calls: cost.calls, est_tokens: cost.tokens, estimate: true } };
      });
    },

    // Replaces a debate's reservation with what it actually used.
    settle(principal, reserved, { calls, inTokens, outTokens }) {
      return withLock(principal, async () => {
        const s = await load(principal);
        s.calls = Math.max(s.calls - reserved.calls + calls, 0);
        s.est_input_tokens = Math.max(s.est_input_tokens - reserved.tokens + inTokens, 0);
        s.est_output_tokens += outTokens;
        await persist(principal, s);
        return budgetView(principal, s);
      });
    },

    // Gives back a reservation when the request could not run (it refused, errored, or the job could not start).
    release(principal, cost, kind = 'job') {
      return withLock(principal, async () => {
        const s = await load(principal);
        s.calls = Math.max(s.calls - cost.calls, 0); s.est_input_tokens = Math.max(s.est_input_tokens - cost.tokens, 0);
        if (kind === 'debate') s.debates = Math.max(s.debates - 1, 0); else s.jobs = Math.max((s.jobs ?? 1) - 1, 0);
        await persist(principal, s);
        return budgetView(principal, s);
      });
    },
  };
}

// What a finished debate cost, estimated from its transcript ("## Round N -- provider" sections + the synthesis).
// `synthesized: false` (the debate was stopped before its verdict) leaves the synthesis call out, so a timeout is not billed for it.
export function usageFromTranscript(transcript, question, { synthesized = true } = {}) {
  const q = estTokens(question.length) + 100;
  const rounds = new Map();
  for (const m of transcript.matchAll(/^## Round (\d+) -- (\S+)\n\n([\s\S]*?)(?=\n## |$(?![\s\S]))/gm)) {
    const r = Number(m[1]);
    if (!rounds.has(r)) rounds.set(r, []);
    rounds.get(r).push(m[3]);
  }
  let calls = 0; let inTokens = 0; let outTokens = 0;
  let prevChars = 0;
  for (const r of [...rounds.keys()].sort((a, b) => a - b)) {
    for (const answer of rounds.get(r)) {
      calls += 1;
      inTokens += q + estTokens(r === 1 ? 0 : prevChars);
      outTokens += estTokens(answer.length);
    }
    prevChars = rounds.get(r).reduce((n, a) => n + a.length, 0);
  }
  const fastPath = /## Synthesis \(fast path/.test(transcript);
  const synth = transcript.match(/\n## Synthesis[^\n]*\n\n([\s\S]*)$/)?.[1] ?? '';
  if (!fastPath && synthesized && calls > 0) {
    calls += 1;
    inTokens += q + estTokens(transcript.length - synth.length);
    outTokens += estTokens(synth.length || 200);
  }
  return { calls, inTokens, outTokens };
}

// Worst case for a request, used to refuse BEFORE spending: providers x rounds + one synthesis.
export function worstCase({ providers, rounds, maxWords, questionChars }) {
  const calls = providers * rounds + 1;
  const answerTok = Math.ceil(maxWords * 1.4);
  const perCallIn = estTokens(questionChars) + 200 + (rounds > 1 ? providers * answerTok : 0);
  return { calls, tokens: calls * (perCallIn + answerTok) };
}

// Conservative reservation for a pipeline job. These are ESTIMATES of model invocations and tokens, not measurements:
// a code-writing phase is one long session (about 190k tokens was observed for one phase), so a phase counts as 3 calls.
export function jobCost(kind, { phases = 1, providers = 1, drafters = 1, negotiators = 1, reviewers = 1 } = {}, env = process.env) {
  const perPhase = Number.parseInt(env.E3D_MCP_EST_TOKENS_PER_PHASE ?? '', 10) || 200000;
  const n = (v) => Math.max(Number(v) || 1, 1);
  if (kind === 'stage') { const calls = 2 * n(providers); return { calls, tokens: calls * 20000 }; }
  if (kind === 'implement') { const calls = n(drafters) + 2 * n(negotiators); return { calls, tokens: calls * 15000 }; }
  if (kind === 'execute') return { calls: n(phases) * 3 + n(reviewers), tokens: n(phases) * perPhase + n(reviewers) * 40000 };
  throw new Error(`unknown job kind: ${kind}`);
}

export const usageTool = {
  name: 'e3d_usage',
  description: 'FREE. Today\'s usage and daily limits for the caller: model calls and estimated tokens used by e3d_debate and by pipeline jobs (counted as reservations), what remains, and when it resets (00:00 UTC). Numbers are estimates. Use it before an expensive request when the user asks what is left.',
  inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  annotations: { title: 'Usage and budget', readOnlyHint: true, openWorldHint: false },
};

export function usageHandler(usage) {
  return async (_args, _progress, ctx) => {
    const b = await usage.snapshot(ctx?.principal ?? 'local');
    const lim = (v, unit) => (v ? `of ${v} ${unit}` : `(no daily limit)`);
    const out = `Usage for "${b.principal}" on ${b.day} (UTC; estimates):\n  model calls: ${b.calls_today} ${lim(b.calls_limit, 'calls')}\n  tokens: ~${b.est_tokens_today} ${lim(b.est_tokens_limit, 'tokens')}\n  resets at ${b.resets_at}\nThis counter covers every repository this server touches for "${b.principal}" and lives in ${b.state_file}. Pipeline jobs (discover/ideate, implement, execute) are counted as reservations at a conservative estimate, because their real spend is not measurable here.`;
    return { ...text(out), structuredContent: b };
  };
}
