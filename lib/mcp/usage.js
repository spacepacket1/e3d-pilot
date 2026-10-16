// Usage accounting and daily caps, per principal ("local" over stdio, the token's name over HTTP).
// Numbers are ESTIMATES: model calls are counted from the debate transcript; tokens are characters / 4.
// State is one JSON file per principal under E3D_MCP_STATE_DIR (default ~/.e3d-pilot/usage), written
// atomically, so budgets survive restarts. Days are UTC. 0 or unset = unlimited.
import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
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
    return { day: today(), calls: 0, est_input_tokens: 0, est_output_tokens: 0, debates: 0 };
  }
  const budgetView = (principal, s) => ({
    principal, day: s.day, calls_today: s.calls, calls_limit: limits.calls || null,
    est_tokens_today: s.est_input_tokens + s.est_output_tokens, est_tokens_limit: limits.tokens || null,
    remaining_calls: limits.calls ? Math.max(limits.calls - s.calls, 0) : null,
    remaining_est_tokens: limits.tokens ? Math.max(limits.tokens - s.est_input_tokens - s.est_output_tokens, 0) : null,
  });
  const withLock = (principal, fn) => {
    const next = (chains.get(principal) ?? Promise.resolve()).then(fn, fn);
    chains.set(principal, next.catch(() => {}));
    return next;
  };

  return {
    limits, dir,
    async snapshot(principal) { return budgetView(principal, await load(principal)); },

    // Would a request that could use up to `calls` / `tokens` stay inside today's caps? Nothing is spent here.
    async check(principal, { calls, tokens }) {
      const s = await load(principal);
      const budget = budgetView(principal, s);
      if (limits.calls && s.calls + calls > limits.calls) {
        return { ok: false, budget, reason: `this request could use up to ${calls} model calls but only ${budget.remaining_calls} of today's ${limits.calls} remain for "${principal}" (resets at 00:00 UTC; raise E3D_MCP_DAILY_CALLS)` };
      }
      if (limits.tokens && s.est_input_tokens + s.est_output_tokens + tokens > limits.tokens) {
        return { ok: false, budget, reason: `this request could use about ${tokens} tokens (estimate) but only ${budget.remaining_est_tokens} of today's ${limits.tokens} remain for "${principal}" (resets at 00:00 UTC; raise E3D_MCP_DAILY_EST_TOKENS)` };
      }
      return { ok: true, budget };
    },

    // Records what a finished debate actually used (estimates) and returns the updated budget.
    record(principal, { calls, inTokens, outTokens }) {
      return withLock(principal, async () => {
        const s = await load(principal);
        s.calls += calls; s.est_input_tokens += inTokens; s.est_output_tokens += outTokens; s.debates += 1;
        await mkdir(dir, { recursive: true });
        const file = fileFor(principal);
        await writeFile(`${file}.tmp`, `${JSON.stringify(s)}\n`);
        await rename(`${file}.tmp`, file);
        return budgetView(principal, s);
      });
    },
  };
}

// What a finished debate cost, estimated from its transcript ("## Round N -- provider" sections + the synthesis).
export function usageFromTranscript(transcript, question) {
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
  if (!fastPath && calls > 0) {
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

export const usageTool = {
  name: 'e3d_usage',
  description: 'FREE. Today\'s usage and daily limits for the caller: model calls and estimated tokens used by e3d_debate, what remains, and when it resets (00:00 UTC). Numbers are estimates.',
  inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  annotations: { title: 'Usage and budget', readOnlyHint: true, openWorldHint: false },
};

export function usageHandler(usage) {
  return async (_args, _progress, ctx) => {
    const b = await usage.snapshot(ctx?.principal ?? 'local');
    const lim = (v, unit) => (v ? `of ${v} ${unit}` : `(no daily limit)`);
    const out = `Usage for "${b.principal}" on ${b.day} (UTC; estimates):\n  model calls: ${b.calls_today} ${lim(b.calls_limit, 'calls')}\n  tokens: ~${b.est_tokens_today} ${lim(b.est_tokens_limit, 'tokens')}`;
    return { ...text(out), structuredContent: b };
  };
}
