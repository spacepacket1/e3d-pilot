// Async debate runs for hosted customers (e3d_debate_start / _status / _result). Zero dependencies.
//
// A run is a debate that was admitted, reserved at the billing service and then executed in the background, so a client that
// stops waiting never loses a paid answer: the debate is finalized (settled AND stored by the service, Debate contract v1)
// whether or not anyone polls, and can be read back here until the local TTL, then through the service's `fetch`.
//
//   start({ principal, plan, worst })   admission slot -> caps -> tentative state -> reserve -> queued; refusals leave nothing
//   status(principal, id) / result(principal, id, includeTranscript)
//                                       the local copy, else the service (`fetch`); unknown and foreign ids are both not_found
//   claimIntent(intent) + recover()     restart: queued runs resume (or expire with zero charge), started ones end as errors
//   accept(...) / get(id, token) / cancel(id, token)
//                                       web runs (the internal run listener, lib/mcp/run-server.js): a debate the billing
//                                       service reserved itself, bound by authorize-run, metered from that reservation; the
//                                       same slots, caps, runner and recovery as connector runs. Each has a per-run token.
//
// Store: <stateDir>/runs/<first 32 hex of sha256(principal)>/<debate_id>/{state.json, transcript.md}; directories 0700,
// files 0600, every write a same-directory temp file + fsync + rename + directory fsync. state.json holds the question and the
// result, so it is never logged, listed or exported; logs carry ids, statuses and counts only.
//
// Limits (all refuse a start BEFORE anything is reserved): an admission slot per principal (E3D_MCP_RUNS_PER_PRINCIPAL, 3) and
// globally (E3D_MCP_RUNS_GLOBAL, 8), queued runs included; finished runs kept per principal (E3D_MCP_RUNS_KEEP_PER_PRINCIPAL, 50,
// the oldest finished ones evicted first); the store's total bytes (E3D_MCP_RUNS_MAX_BYTES, 64 MB) and the outbox's own bound.
// Finished runs are evicted after E3D_MCP_RUNS_TTL_SEC (24 h). A run whose finalize is still pending (journaled metering intent,
// or a finalize record in the outbox, dead ones included) is never evicted.
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { chmod, mkdir, open, readdir, readFile, rename, rm, stat, unlink } from 'node:fs/promises';
import { existsSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { newDebateId, questionFitsContract } from './metering.js';

export const DEBATE_ID_RE = /^dbt_[0-9a-f]{24}$/;
export const RUN_DEFAULTS = Object.freeze({
  perPrincipal: 3, global: 8, keepPerPrincipal: 50, ttlSec: 24 * 3600, maxBytes: 64 * 1024 * 1024,
  pollPerMin: 60, runTimeoutSec: 1800, negativeTtlMs: 60000,
});
// Customer cost drivers (per_debate pricing): caller values are clamped to these maxima.
export const CUSTOMER_LIMIT_DEFAULTS = Object.freeze({ rounds: 2, max_words: 300, providers: 3 });
const POLL_AFTER = { queued: 10, running: 5 };
const TERMINAL = new Set(['done', 'failed']);
const NEGATIVE_MAX = 10000;

// Constant-time equality of two secrets of any length (both hashed first, so neither length nor content leaks).
export const safeEqual = (a, b) => typeof a === 'string' && typeof b === 'string' && timingSafeEqual(createHash('sha256').update(a).digest(), createHash('sha256').update(b).digest());

export const principalDir = (principal) => createHash('sha256').update(String(principal)).digest('hex').slice(0, 32);

// "rounds=2,max_words=300,providers=3" (any subset; omitted keys keep their default maxima).
export function parseCustomerLimits(raw) {
  const out = { ...CUSTOMER_LIMIT_DEFAULTS };
  if (raw == null || raw === '') return { value: out };
  const bounds = { rounds: [1, 100], max_words: [20, 100000], providers: [2, 16] };
  for (const part of String(raw).split(',').map((s) => s.trim()).filter(Boolean)) {
    const m = /^([a-z_]+)=(\d{1,6})$/.exec(part);
    if (!m || !bounds[m[1]]) return { error: 'E3D_MCP_CUSTOMER_LIMITS must look like rounds=2,max_words=300,providers=3' };
    const n = Number(m[2]);
    if (n < bounds[m[1]][0] || n > bounds[m[1]][1]) return { error: `E3D_MCP_CUSTOMER_LIMITS ${m[1]} must be from ${bounds[m[1]][0]} to ${bounds[m[1]][1]}` };
    out[m[1]] = n;
  }
  return { value: out };
}

// Startup checks for the run settings. Returns { ok, errors, config }.
export function validateRunsConfig(env = process.env) {
  const errors = [];
  const int = (name, dflt, lo, hi) => {
    const raw = env[name];
    if (raw == null || raw === '') return dflt;
    const n = Number(raw);
    if (!/^\d+$/.test(String(raw)) || !Number.isSafeInteger(n) || n < lo || n > hi) { errors.push(`${name} must be a whole number from ${lo} to ${hi}`); return dflt; }
    return n;
  };
  const config = {
    perPrincipal: int('E3D_MCP_RUNS_PER_PRINCIPAL', RUN_DEFAULTS.perPrincipal, 1, 1000),
    global: int('E3D_MCP_RUNS_GLOBAL', RUN_DEFAULTS.global, 1, 10000),
    keepPerPrincipal: int('E3D_MCP_RUNS_KEEP_PER_PRINCIPAL', RUN_DEFAULTS.keepPerPrincipal, 1, 100000),
    ttlSec: int('E3D_MCP_RUNS_TTL_SEC', RUN_DEFAULTS.ttlSec, 1, 365 * 86400),
    maxBytes: int('E3D_MCP_RUNS_MAX_BYTES', RUN_DEFAULTS.maxBytes, 1, Number.MAX_SAFE_INTEGER),
    pollPerMin: int('E3D_MCP_RUNS_POLL_PER_MIN', RUN_DEFAULTS.pollPerMin, 1, 100000),
    runTimeoutSec: int('E3D_MCP_RUN_TIMEOUT_SEC', RUN_DEFAULTS.runTimeoutSec, 1, 7 * 86400),
    negativeTtlMs: RUN_DEFAULTS.negativeTtlMs,
  };
  if (config.perPrincipal > config.global) errors.push('E3D_MCP_RUNS_PER_PRINCIPAL cannot exceed E3D_MCP_RUNS_GLOBAL');
  const customer = parseCustomerLimits(env.E3D_MCP_CUSTOMER_LIMITS);
  if (customer.error) errors.push(customer.error);
  config.customer = customer.value ?? { ...CUSTOMER_LIMIT_DEFAULTS };
  return { ok: errors.length === 0, errors, config };
}

async function syncDir(dir) {
  let fh;
  try { fh = await open(dir, 'r'); await fh.sync(); } catch { /* not supported on this platform */ } finally { await fh?.close().catch(() => {}); }
}
async function ensureDir(dir) { await mkdir(dir, { recursive: true, mode: 0o700 }); await chmod(dir, 0o700); }
async function writeDurable(dir, name, data) {
  const tmp = join(dir, `.tmp-${process.pid}-${randomBytes(6).toString('hex')}`);
  const fh = await open(tmp, 'wx', 0o600);
  try { await fh.writeFile(data); await fh.sync(); } finally { await fh.close(); }
  try { await rename(tmp, join(dir, name)); } catch (e) { await unlink(tmp).catch(() => {}); throw e; }
  await syncDir(dir);
}
const sizeOf = async (p) => stat(p).then((s) => s.size, () => 0);

// Files under <stateDir>/runs (count and bytes only), for --doctor.
export function runsUsage(stateDir) {
  const root = join(stateDir, 'runs');
  const out = { runs: 0, bytes: 0, root };
  const size = (p) => { try { return statSync(p).size; } catch { return 0; } };
  const list = (d) => { try { return readdirSync(d); } catch { return []; } };
  for (const g of list(root)) {
    for (const id of list(join(root, g)).filter((x) => DEBATE_ID_RE.test(x))) {
      out.runs++;
      out.bytes += size(join(root, g, id, 'state.json')) + size(join(root, g, id, 'transcript.md'));
    }
  }
  return out;
}

export function createRuns({ dir, config = validateRunsConfig({}).config, metering, outbox = null, external = null, execute, acquireExec = () => true, releaseExec = () => {}, log = () => {}, now = Date.now, alive = defaultAlive }) {
  if (!dir) throw new TypeError('createRuns: dir (the state directory) is required');
  if (!metering || typeof execute !== 'function') throw new TypeError('createRuns: metering and execute are required');
  const root = join(dir, 'runs');
  const intentsDir = join(dir, 'metering-intents');
  const outboxRoot = join(dir, 'auth-outbox');
  const index = new Map(); // debate_id -> { id, ph, principal, status, created_ms, finished_ms, request_id, reservation_id, bytes, uncertain, deleted }
  const handles = new Map(); // debate_id -> metering handle of a queued or running run
  const slots = { global: 0, byPrincipal: new Map(), held: new Set() };
  const queue = [];
  const progress = new Map(); // debate_id -> { step, message }   (in memory only)
  const polls = new Map(); // principal -> timestamps within the last minute
  const negative = new Map(); // principal \0 debate_id -> until (ms): the service answered not_found
  const claimable = new Map(); // request_id -> entry, during recovery
  const seenIntents = new Map(); // debate_id -> intent seen during recovery
  const claimed = new Set(); // debate ids whose intent this store owns after recovery
  const webPending = new Map(); // debate_id -> { key, reservation_id, promise }: a web run being accepted
  const aborts = new Map(); // debate_id -> AbortController of a running run (cancel)
  const running = new Map(); // debate_id -> promise of its runOne
  const cancelRequested = new Set(); // debate ids cancelled after leaving the queue, before their AbortController existed
  const counters = { web_accepted: 0, web_duplicates: 0, web_refused: 0, cancelled: 0, started: 0, refused_busy: 0, refused_caps: 0, refused_reserve: 0, finished: 0, expired: 0, recovered_errors: 0, resumed: 0, evicted: 0, fetched: 0, fetch_not_found: 0 };
  let timer = null;

  const runDir = (e) => join(root, e.ph, e.id);
  const iso = (ms) => new Date(ms).toISOString();

  // ---- admission slots (synchronous, so a check and its increment can never interleave) ----
  function acquireSlot(principal, id, { force = false } = {}) {
    const mine = slots.byPrincipal.get(principal) ?? 0;
    if (!force && (mine >= config.perPrincipal || slots.global >= config.global)) return false;
    slots.byPrincipal.set(principal, mine + 1); slots.global++; slots.held.add(id);
    return true;
  }
  function releaseSlot(principal, id) {
    if (!slots.held.delete(id)) return;
    const n = (slots.byPrincipal.get(principal) ?? 1) - 1;
    if (n > 0) slots.byPrincipal.set(principal, n); else slots.byPrincipal.delete(principal);
    slots.global = Math.max(0, slots.global - 1);
  }

  // ---- state files ----
  async function writeState(e, state) {
    const d = runDir(e);
    await ensureDir(join(root, e.ph)); await ensureDir(d);
    await writeDurable(d, 'state.json', `${JSON.stringify(state)}\n`);
    e.status = state.status; e.request_id = state.request_id ?? null; e.reservation_id = state.reservation_id ?? null;
    e.created_ms = Date.parse(state.created_at); e.finished_ms = state.finished_at ? Date.parse(state.finished_at) : null;
    e.uncertain = state.uncertain === true; e.deleted = state.deleted === true; e.source = state.source ?? 'connector';
    e.bytes = (await sizeOf(join(d, 'state.json'))) + (await sizeOf(join(d, 'transcript.md')));
  }
  async function readState(e) {
    try { return JSON.parse(await readFile(join(runDir(e), 'state.json'), 'utf8')); } catch { return null; }
  }
  async function removeRun(e) {
    await rm(runDir(e), { recursive: true, force: true });
    await syncDir(join(root, e.ph));
    index.delete(e.id); progress.delete(e.id);
  }
  const totalBytes = () => { let n = 0; for (const e of index.values()) n += e.bytes ?? 0; return n; };

  // A finalize still on its way to the service: the metering intent (journaled, not yet durable) or an outbox record.
  async function finalizePending(e) {
    if (e.request_id && existsSync(join(intentsDir, `${e.request_id}.json`))) return true;
    if (!e.reservation_id) return false;
    const name = `${`finalize.reservation_id.${e.reservation_id}`.replace(/:/g, '%3A')}.json`;
    if (existsSync(join(outboxRoot, 'pending', name)) || existsSync(join(outboxRoot, 'dead', name))) return true;
    try { return (await readdir(join(outboxRoot, 'claimed'))).some((f) => f.endsWith(`-${name}`)); } catch { return false; }
  }

  // ---- eviction ----
  async function sweep() {
    const t = now();
    let n = 0;
    for (const e of [...index.values()]) {
      if (TERMINAL.has(e.status)) {
        const at = e.finished_ms ?? e.created_ms;
        if (Number.isFinite(at) && t - at < config.ttlSec * 1000) continue;
        if (await finalizePending(e)) continue;
        await removeRun(e); n++;
      } else if (e.status === 'reserving' && !handles.has(e.id) && !slots.held.has(e.id) && t - e.created_ms > 10 * 60000) {
        await removeRun(e); n++; // a tentative run of a crashed start
      }
    }
    if (n) { counters.evicted += n; log(`runs: evicted ${n} run(s) past the local TTL`); }
    for (const [k, until] of negative) if (until <= t) negative.delete(k);
    return n;
  }
  // Make room for one more run of this principal: the oldest finished runs without a pending finalize go first.
  async function makeRoom(ph) {
    const mine = [...index.values()].filter((e) => e.ph === ph);
    let over = mine.length - config.keepPerPrincipal + 1;
    if (over <= 0) return true;
    const done = mine.filter((e) => TERMINAL.has(e.status)).sort((a, b) => (a.finished_ms ?? a.created_ms) - (b.finished_ms ?? b.created_ms));
    for (const e of done) {
      if (over <= 0) break;
      if (await finalizePending(e)) continue;
      await removeRun(e); over--; counters.evicted++;
    }
    return over <= 0;
  }

  // ---- start ----
  // plan: { question, mode, providers, rounds, maxWords, synthesizer }. Returns { ok, debate_id, status, poll_after_sec } or
  // { ok:false, kind: invalid | busy | caps | unavailable | begin, message?, rsv? }. Every refusal leaves no run and no hold.
  async function start({ principal, plan, worst }) {
    if (!questionFitsContract(plan.question)) return { ok: false, kind: 'invalid', message: 'the question must be 1 to 8000 characters without control characters' };
    // caps first: nothing is admitted or reserved when the store or the outbox is at its bound
    await sweep();
    const ph = principalDir(principal);
    if (outbox && !outbox.canAccept()) { counters.refused_caps++; log(`runs: refusing a start principal=${principal} (the outbox is at its bound)`); return { ok: false, kind: 'caps', message: 'the server cannot accept new debates right now (billing queue full); retry later' }; }
    if (totalBytes() >= config.maxBytes) { counters.refused_caps++; log(`runs: refusing a start principal=${principal} (the run store is at its byte bound)`); return { ok: false, kind: 'caps', message: 'the server cannot store more debates right now; retry later' }; }
    if (!(await makeRoom(ph))) { counters.refused_caps++; log(`runs: refusing a start principal=${principal} (kept-runs cap; the oldest still await settlement)`); return { ok: false, kind: 'caps', message: `this account already has ${config.keepPerPrincipal} stored debates that cannot be removed yet; retry later` }; }
    const id = newDebateId();
    if (!acquireSlot(principal, id)) { counters.refused_busy++; return { ok: false, kind: 'busy', message: `${config.perPrincipal} debates are already queued or running for this account (or the server is full); wait for one to finish and retry` }; }
    const e = { id, ph, principal, status: 'reserving', created_ms: now(), finished_ms: null, request_id: null, reservation_id: null, bytes: 0 };
    const base = { v: 1, debate_id: id, principal, created_at: iso(e.created_ms), finished_at: null, started_at: null, outcome: null, question: plan.question,
      args: { mode: plan.mode, providers: [...plan.providers], rounds: plan.rounds, max_words: plan.maxWords, synthesizer: plan.synthesizer }, pid: process.pid };
    const undo = async () => { await removeRun(e).catch(() => {}); releaseSlot(principal, id); };
    try { index.set(id, e); await writeState(e, { ...base, status: 'reserving' }); } catch (err) {
      log(`runs: ERROR could not write the run state debate_id=${id} (${err.code ?? err.message})`); await undo();
      return { ok: false, kind: 'unavailable', message: 'temporarily unavailable' };
    }
    let rsv;
    try { rsv = await metering.begin(principal, worst, { tool: 'e3d_debate_start', debate: { question: plan.question, providers: plan.providers, rounds: plan.rounds }, debate_id: id }); }
    catch (err) { await undo(); throw err; }
    if (!rsv.ok) { counters.refused_reserve++; await undo(); return { ok: false, kind: 'begin', rsv }; }
    const { handle } = rsv;
    if (!handle.finalize) {
      // the service stopped advertising finalize: without it the result could not be stored durably, so nothing runs
      await metering.abort(handle, 'no_finalize').catch(() => {}); await undo();
      return { ok: false, kind: 'unavailable', message: 'temporarily unavailable' };
    }
    try { await writeState(e, { ...base, status: 'queued', request_id: handle.request_id, reservation_id: handle.reservation_id }); } catch (err) {
      log(`runs: ERROR could not record the queued run debate_id=${id} (${err.code ?? err.message}); releasing it`);
      await metering.abort(handle, 'run_state_failed').catch(() => {}); await undo();
      return { ok: false, kind: 'unavailable', message: 'temporarily unavailable' };
    }
    handles.set(id, handle);
    queue.push(id);
    counters.started++;
    log(`runs: queued principal=${principal} debate_id=${id} reservation_id=${handle.reservation_id}`);
    pump();
    const status = index.get(id)?.status === 'running' || (handles.has(id) && !queue.includes(id)) ? 'running' : 'queued';
    return { ok: true, debate_id: id, status, poll_after_sec: POLL_AFTER[status] };
  }

  // ---- the runner ----
  const expiredQueued = (e) => now() - e.created_ms > config.runTimeoutSec * 1000;
  function pump() {
    // queued runs past the run timeout end without running anything (finalized with zero calls: zero charge)
    for (let i = queue.length - 1; i >= 0; i--) {
      const e = index.get(queue[i]);
      if (e && expiredQueued(e)) { const [id] = queue.splice(i, 1); expire(id).catch((err) => log(`runs: ERROR expiring debate_id=${id} (${err.message})`)); }
    }
    while (queue.length && acquireExec()) {
      const id = queue.shift();
      const p = runOne(id).catch((err) => log(`runs: ERROR run debate_id=${id} (${err.message})`)).finally(() => { running.delete(id); releaseExec(); pump(); });
      running.set(id, p);
    }
  }
  async function finish(e, handle, state, fields, transcript) {
    if (typeof transcript === 'string' && transcript && !fields.deleted) await writeDurable(runDir(e), 'transcript.md', transcript);
    else await unlink(join(runDir(e), 'transcript.md')).catch(() => {});
    await writeState(e, { ...state, ...fields, finished_at: iso(now()), pid: process.pid });
    handles.delete(e.id); progress.delete(e.id); cancelRequested.delete(e.id); releaseSlot(e.principal, e.id);
    counters.finished++;
  }
  // A queued run that ends without running anything (past the run timeout, or cancelled): finalized with zero calls.
  async function expire(id, { cancel = false } = {}) {
    const e = index.get(id); const handle = handles.get(id);
    if (!e || !handle) return;
    const state = await readState(e) ?? {};
    const c = await metering.commit(handle, { calls: 0, inTokens: 0, outTokens: 0 }, { outcome: 'error', duration_ms: 0, models: [], transcript: null, finished_at: now() });
    await finish(e, handle, state, { status: 'failed', outcome: 'error', ...(cancel ? { cancelled: true } : { expired: true }), result: null, usage: { calls: 0, est_input_tokens: 0, est_output_tokens: 0 }, billing: billingOf(c.billing) }, null);
    if (!cancel) counters.expired++;
    log(`runs: ${cancel ? 'cancelled' : 'expired'} before it started principal=${e.principal} debate_id=${id} (finalized with zero calls)`);
  }
  const billingOf = (b) => (b ? { ...(b.stored !== undefined ? { stored: b.stored, charged: b.charged } : {}), ...(b.queued ? { queued: true } : {}) } : {});
  async function runOne(id) {
    const e = index.get(id); const handle = handles.get(id);
    if (!e || !handle) return;
    let state = await readState(e);
    if (!state) { log(`runs: ERROR the state of debate_id=${id} is unreadable; finalizing it as an error`); state = { debate_id: id, principal: e.principal, created_at: iso(e.created_ms) }; }
    if (expiredQueued(e)) { await expire(id); return; }
    const plan = { question: state.question, mode: state.args?.mode, providers: state.args?.providers ?? [], rounds: state.args?.rounds, maxWords: state.args?.max_words, synthesizer: state.args?.synthesizer };
    let x;
    const ac = new AbortController(); aborts.set(id, ac);
    if (cancelRequested.delete(id)) ac.abort();
    try {
      x = await execute({ plan, handle, principal: e.principal, signal: ac.signal,
        // the models-started marker is already durable in the metering intent (metering.start); this records it for status
        onStarted: async () => {
          try { state = { ...state, status: 'running', started_at: iso(now()), pid: process.pid }; await writeState(e, state); } catch (err) { log(`runs: could not record running debate_id=${id} (${err.code ?? err.message})`); }
        },
        progress: (step, message) => progress.set(id, { step, message: String(message ?? '').replace(/[^\x20-\x7e]/g, '?').slice(0, 80) }) });
    } catch (err) {
      log(`runs: ERROR debate_id=${id} failed unexpectedly (${err.message})`);
      x = { outcome: 'error', result: null, transcript: null, usage: null, billing: null };
    } finally { aborts.delete(id); }
    const cancelled = ac.signal.aborted ? { cancelled: true } : {};
    if (x.startFailed) {
      await finish(e, handle, state, { status: 'failed', outcome: 'error', result: null, usage: { calls: 0, est_input_tokens: 0, est_output_tokens: 0 }, billing: {}, ...cancelled }, null);
      log(`runs: could not start principal=${e.principal} debate_id=${id}; the hold was released`);
      return;
    }
    const deleted = x.billing?.stored === false; // the service did not store it (deleted or account closed): nothing to serve
    await finish(e, handle, state, {
      status: x.outcome === 'ok' && !deleted ? 'done' : 'failed', outcome: x.outcome, result: deleted ? null : (x.result ?? null), usage: x.usage ?? null,
      billing: billingOf(x.billing), truncated: false, ...cancelled, ...(deleted ? { deleted: true, question: null } : {}),
    }, deleted ? null : x.transcript);
    log(`runs: finished principal=${e.principal} debate_id=${id} outcome=${x.outcome}${cancelled.cancelled ? ' (cancelled)' : ''}${deleted ? ' (not stored by the service)' : ''}`);
  }

  // The service reported "stored:false" for a finalize that was still queued when the debate was deleted (or the account closed):
  // drop the local result, question and transcript so nothing is served until the TTL.
  async function purgeUnstored(id) {
    const e = index.get(id);
    if (!e) return false;
    const s = await readState(e);
    if (!s || s.deleted === true) return false;
    await writeState(e, { ...s, status: 'failed', result: null, question: null, truncated: false, deleted: true });
    await unlink(join(root, e.ph, id, 'transcript.md')).catch(() => {});
    e.status = 'failed'; e.deleted = true;
    return true;
  }

  // ---- reads ----
  const view = (s, transcript) => ({
    debate_id: s.debate_id, status: s.status, outcome: s.outcome ?? null, question: s.question, providers: s.args?.providers ?? [], rounds: s.args?.rounds ?? 0,
    result: s.result ?? null, usage: s.usage ?? null, credits_charged: s.billing?.charged ?? null, created_at: s.created_at, finished_at: s.finished_at ?? null,
    truncated: s.truncated === true, ...(transcript !== undefined ? { transcript } : {}), source: 'local',
  });
  function limited(principal) {
    const t = now();
    const recent = (polls.get(principal) ?? []).filter((x) => t - x < 60000);
    if (recent.length >= config.pollPerMin) { polls.set(principal, recent); return Math.max(1, Math.ceil((60000 - (t - recent[0])) / 1000)); }
    recent.push(t); polls.set(principal, recent);
    if (polls.size > NEGATIVE_MAX) polls.delete(polls.keys().next().value);
    return 0;
  }
  const notFound = { ok: false, code: 'not_found' };
  // The service copy: used when the run is not (or no longer) here. Unknown and foreign ids get the same not_found, and a
  // not_found is remembered for 60 s per principal so repeated guesses never reach the service.
  async function fromService(principal, id, includeTranscript) {
    if (!external || typeof external.fetchDebate !== 'function' || !external.hasFeature?.('fetch')) return notFound;
    const key = `${principal}\0${id}`;
    if ((negative.get(key) ?? 0) > now()) return notFound;
    let r;
    try { r = await external.fetchDebate({ debate_id: id, principal, include_transcript: includeTranscript }); } catch (err) {
      if (err instanceof TypeError) return notFound; // a principal or id the contract cannot express: nothing to find
      return { ok: false, code: 'unavailable' };
    }
    if (!r.ok) {
      counters.fetch_not_found++;
      negative.set(key, now() + config.negativeTtlMs);
      while (negative.size > NEGATIVE_MAX) negative.delete(negative.keys().next().value);
      return notFound;
    }
    counters.fetched++;
    return { ok: true, debate: { ...r.debate, source: 'service' } };
  }
  async function lookup(principal, id, includeTranscript) {
    if (typeof id !== 'string' || !DEBATE_ID_RE.test(id)) return notFound;
    const wait = limited(principal);
    if (wait) return { ok: false, code: 'rate_limited', retry_after: wait };
    const e = index.get(id);
    if (e && e.principal === principal && e.status !== 'reserving' && !e.deleted) {
      if (TERMINAL.has(e.status) && now() - (e.finished_ms ?? e.created_ms) >= config.ttlSec * 1000 && !(await finalizePending(e))) {
        await removeRun(e).catch(() => {}); counters.evicted++;
      } else {
        const s = await readState(e);
        if (s && !e.uncertain) {
          const transcript = includeTranscript && TERMINAL.has(s.status) ? await readFile(join(runDir(e), 'transcript.md'), 'utf8').catch(() => null) : undefined;
          return { ok: true, debate: { ...view(s, includeTranscript ? (transcript ?? null) : undefined), ...(progress.has(id) ? { progress: progress.get(id) } : {}) } };
        }
        if (s && e.uncertain) {
          // interrupted around its finalize: the service holds the authoritative copy; this one only says it failed
          const svc = await fromService(principal, id, includeTranscript);
          if (svc.ok || svc.code === 'unavailable') return svc;
          return { ok: true, debate: view(s, includeTranscript ? null : undefined) };
        }
      }
    }
    return fromService(principal, id, includeTranscript);
  }
  async function status(principal, id) {
    const r = await lookup(principal, id, false);
    if (!r.ok) return r;
    const d = r.debate;
    return { ok: true, status: { debate_id: d.debate_id, status: d.status, outcome: d.outcome, created_at: d.created_at, finished_at: d.finished_at, ...(d.progress ? { progress: d.progress } : {}),
      ...(TERMINAL.has(d.status) ? {} : { poll_after_sec: POLL_AFTER[d.status] ?? 5 }) } };
  }
  async function result(principal, id, includeTranscript = false) {
    const r = await lookup(principal, id, includeTranscript === true);
    if (!r.ok) return r;
    const d = { ...r.debate };
    if (!TERMINAL.has(d.status)) d.poll_after_sec = POLL_AFTER[d.status] ?? 5;
    if (!includeTranscript) delete d.transcript;
    return { ok: true, debate: d };
  }

  // ---- web runs (the internal run listener) ----
  // accept({ reservation_id, debate_id, key, plan, worst, authorize }): key is the canonical hash of the request's fields;
  // authorize({ reservation_id, debate_id }) is the service's authorize-run, the ONLY source of the owner. Returns
  // { ok:true, existing, debate_id, status, run_token } or { ok:false, kind: conflict | busy | caps | refused | unavailable | begin, code?, rsv? }.
  // Every refusal leaves no run here and touches nothing at the service beyond the (idempotent) authorize-run binding.
  const conflict = { ok: false, kind: 'conflict' };
  async function accept(req) {
    const { reservation_id, debate_id, key } = req;
    // duplicates are recognized synchronously, before anything is awaited, so two identical requests can never both run
    const pend = webPending.get(debate_id);
    if (pend) {
      if (pend.key !== key) return conflict;
      counters.web_duplicates++;
      return pend.promise.then((r) => (r.ok ? { ...r, existing: true } : r));
    }
    for (const p of webPending.values()) if (p.reservation_id === reservation_id) return conflict;
    const e = index.get(debate_id);
    if (e) return existingRun(e, key);
    for (const x of index.values()) if (x.reservation_id === reservation_id) return conflict;
    const promise = acceptNew(req);
    webPending.set(debate_id, { key, reservation_id, promise });
    try { return await promise; } finally { webPending.delete(debate_id); }
  }
  async function existingRun(e, key) {
    const s = e.source === 'web' ? await readState(e) : null;
    if (!s || s.request_key !== key || typeof s.run_token !== 'string' || e.status === 'reserving') return conflict;
    counters.web_duplicates++;
    return { ok: true, existing: true, debate_id: e.id, status: e.status, run_token: s.run_token };
  }
  async function acceptNew({ reservation_id, debate_id, key, plan, worst, authorize }) {
    const refuse = (r) => { counters.web_refused++; return r; };
    if (!questionFitsContract(plan.question)) return refuse({ ok: false, kind: 'invalid' });
    await sweep();
    if (outbox && !outbox.canAccept()) { log(`runs: refusing a web run debate_id=${debate_id} (the outbox is at its bound)`); return refuse({ ok: false, kind: 'caps' }); }
    if (totalBytes() >= config.maxBytes) { log(`runs: refusing a web run debate_id=${debate_id} (the run store is at its byte bound)`); return refuse({ ok: false, kind: 'caps' }); }
    if (slots.global >= config.global) return refuse({ ok: false, kind: 'busy' });
    let auth;
    try { auth = await authorize({ reservation_id, debate_id }); } catch (err) {
      if (err instanceof TypeError) return refuse({ ok: false, kind: 'invalid' });
      log(`runs: authorize-run failed debate_id=${debate_id} (${err.kind ?? 'error'})`);
      return refuse({ ok: false, kind: 'unavailable' });
    }
    if (!auth?.ok) { log(`runs: authorize-run refused debate_id=${debate_id} code=${auth?.code}`); return refuse({ ok: false, kind: 'refused', code: auth?.code ?? 'invalid' }); }
    const principal = auth.principal; // from the service, never from the request
    const ph = principalDir(principal);
    // The reservation is already bound at the service by now (authorize-run is idempotent). A refusal from here on is therefore
    // "try again later", never a definitive rejection that would make the service release a reservation it can still submit.
    if (!(await makeRoom(ph))) return refuse({ ok: false, kind: 'unavailable' });
    if (!acquireSlot(principal, debate_id)) return refuse({ ok: false, kind: 'unavailable' });
    const e = { id: debate_id, ph, principal, status: 'reserving', created_ms: now(), finished_ms: null, request_id: null, reservation_id, bytes: 0, source: 'web' };
    const run_token = randomBytes(32).toString('base64url');
    const base = { v: 1, debate_id, principal, source: 'web', request_key: key, run_token, price_credits: auth.price_credits, created_at: iso(e.created_ms), finished_at: null, started_at: null, outcome: null,
      question: plan.question, args: { mode: plan.mode, providers: [...plan.providers], rounds: plan.rounds, max_words: plan.maxWords, synthesizer: plan.synthesizer }, pid: process.pid };
    const undo = async () => { await removeRun(e).catch(() => {}); releaseSlot(principal, debate_id); };
    try { index.set(debate_id, e); await writeState(e, { ...base, status: 'reserving', reservation_id }); } catch (err) {
      log(`runs: ERROR could not write the run state debate_id=${debate_id} (${err.code ?? err.message})`); await undo();
      return refuse({ ok: false, kind: 'unavailable' });
    }
    let rsv;
    try { rsv = await metering.beginAuthorized(principal, worst, { tool: 'web_run', reservation_id, debate_id, debate: { question: plan.question, providers: plan.providers, rounds: plan.rounds, source: 'web' } }); }
    catch (err) { await undo(); throw err; }
    if (!rsv.ok) { await undo(); return refuse({ ok: false, kind: 'begin', rsv }); }
    const { handle } = rsv;
    try { await writeState(e, { ...base, status: 'queued', request_id: handle.request_id, reservation_id }); } catch (err) {
      log(`runs: ERROR could not record the queued web run debate_id=${debate_id} (${err.code ?? err.message})`);
      await metering.forget(handle); await undo();
      return refuse({ ok: false, kind: 'unavailable' });
    }
    handles.set(debate_id, handle);
    queue.push(debate_id);
    counters.web_accepted++;
    log(`runs: accepted a web run principal=${principal} debate_id=${debate_id} reservation_id=${reservation_id}`);
    pump();
    const status = index.get(debate_id)?.status === 'running' || (handles.has(debate_id) && !queue.includes(debate_id)) ? 'running' : 'queued';
    return { ok: true, existing: false, debate_id, status, run_token };
  }
  // The web run debate_id, if runToken is its token (constant time); otherwise null, the same for an unknown id.
  async function webRun(id, runToken) {
    const e = typeof id === 'string' ? index.get(id) : null;
    const s = e && e.source === 'web' ? await readState(e) : null;
    const match = safeEqual(s?.run_token ?? `-${randomBytes(16).toString('hex')}`, typeof runToken === 'string' ? runToken : '');
    return s && match ? { e, s } : null;
  }
  const webView = (s) => ({
    debate_id: s.debate_id, status: s.status === 'reserving' ? 'queued' : s.status, outcome: s.outcome ?? null,
    ...(progress.has(s.debate_id) ? { progress: progress.get(s.debate_id) } : {}),
    ...(s.status === 'done' && s.result ? { result: s.result } : {}),
    usage: s.usage ?? null, credits_charged: s.billing?.charged ?? null, created_at: s.created_at, started_at: s.started_at ?? null, finished_at: s.finished_at ?? null,
    ...(s.cancelled ? { cancelled: true } : {}), ...(s.deleted ? { deleted: true } : {}),
  });
  async function get(id, runToken) {
    const w = await webRun(id, runToken);
    return w ? { ok: true, run: webView(w.s) } : null;
  }
  // Cancel: a queued run is finalized with zero calls; a running one is stopped and finalized as an error without a result
  // (the service charges its failed price for the calls that ran). A finished run is returned as it is.
  async function cancel(id, runToken, { waitMs = 10000 } = {}) {
    const w = await webRun(id, runToken);
    if (!w) return null;
    const { e } = w;
    const qi = queue.indexOf(id);
    if (qi >= 0) { queue.splice(qi, 1); await expire(id, { cancel: true }); counters.cancelled++; }
    else if (handles.has(id)) {
      if (aborts.has(id)) aborts.get(id).abort(); else cancelRequested.add(id);
      counters.cancelled++;
      log(`runs: cancelling a running web run debate_id=${id}`);
      const p = running.get(id);
      if (p) await Promise.race([p, new Promise((r) => { const t = setTimeout(r, waitMs); t.unref?.(); })]);
    }
    const s = await readState(e);
    return { ok: true, run: webView(s ?? w.s) };
  }

  // ---- startup: load, claim intents, recover ----
  async function load() {
    await ensureDir(root);
    index.clear();
    let unreadable = 0;
    for (const ph of await readdir(root).catch(() => [])) {
      if (!/^[0-9a-f]{32}$/.test(ph)) continue;
      for (const id of await readdir(join(root, ph)).catch(() => [])) {
        if (!DEBATE_ID_RE.test(id)) continue;
        const e = { id, ph };
        const s = await readState(e);
        if (!s || s.debate_id !== id || principalDir(s.principal) !== ph) { unreadable++; continue; }
        // a temp file left by a crash mid-write is never the state; remove it
        for (const f of await readdir(join(root, ph, id)).catch(() => [])) if (f.startsWith('.tmp-')) await unlink(join(root, ph, id, f)).catch(() => {});
        Object.assign(e, { principal: s.principal, status: s.status, created_ms: Date.parse(s.created_at), finished_ms: s.finished_at ? Date.parse(s.finished_at) : null,
          request_id: s.request_id ?? null, reservation_id: s.reservation_id ?? null, uncertain: s.uncertain === true, deleted: s.deleted === true, pid: s.pid, source: s.source ?? 'connector' });
        e.bytes = (await sizeOf(join(root, ph, id, 'state.json'))) + (await sizeOf(join(root, ph, id, 'transcript.md')));
        index.set(id, e);
        if (!TERMINAL.has(e.status) && e.request_id && !liveOtherRun(e)) claimable.set(e.request_id, e);
      }
    }
    if (unreadable) log(`runs: ${unreadable} unreadable run state file(s) kept for an operator`);
    return { runs: index.size };
  }
  // Passed to metering.recover(): the intent of a queued run that never started its models stays with this store.
  function claimIntent(it) {
    const e = claimable.get(it?.request_id);
    if (!e) return false;
    seenIntents.set(e.id, it);
    if (e.status === 'queued' && it.phase === 'prepared' && !it.settlement) { claimed.add(e.id); return true; }
    return false;
  }
  // Another server's run is only honoured while it is plausibly alive: a pid can be reused after a crash, so a run older than
  // E3D_MCP_ORPHAN_MAX_AGE_SEC (default 6 hours, the same bound the metering intents use) is recovered regardless.
  const staleRunMs = (Number.parseInt(process.env.E3D_MCP_ORPHAN_MAX_AGE_SEC ?? '', 10) || 6 * 3600) * 1000;
  function liveOtherRun(e) {
    if (!(Number.isInteger(e.pid) && e.pid !== process.pid && alive(e.pid))) return false;
    return !(Number.isFinite(e.created_ms) && now() - e.created_ms > staleRunMs);
  }
  async function recover() {
    let resumed = 0; let errors = 0; let removed = 0; let expired = 0;
    for (const e of [...index.values()]) {
      if (TERMINAL.has(e.status)) continue;
      if (liveOtherRun(e)) continue; // another live server's run
      const s = await readState(e);
      if (!s) continue;
      if (e.status === 'reserving') { await removeRun(e); removed++; continue; } // metering released any hold it made
      const it = seenIntents.get(e.id);
      if (claimed.has(e.id)) {
        const handle = metering.adopt(it);
        if (handle) {
          handles.set(e.id, handle);
          acquireSlot(e.principal, e.id, { force: true }); // reconstructed: it held a slot before the restart
          if (expiredQueued(e)) { await expire(e.id); expired++; } else { queue.push(e.id); resumed++; }
          continue;
        }
      }
      // models had started (or the outcome was journaled): metering.recover finalized it; mirror what it sent
      const fin = it?.settlement?.call === 'finalize' ? it.settlement.payload : null;
      const fields = fin
        ? { status: fin.outcome === 'ok' ? 'done' : 'failed', outcome: fin.outcome, result: fin.result ?? null, usage: fin.actual, truncated: fin.truncated === true }
        : it ? { status: 'failed', outcome: 'error', result: null, usage: { calls: it.units?.calls ?? 0, est_input_tokens: it.units?.est_tokens ?? 0, est_output_tokens: 0 } }
          : { status: 'failed', outcome: 'error', result: null, uncertain: true }; // finished around the crash: ask the service
      if (fin?.transcript) await writeDurable(runDir(e), 'transcript.md', fin.transcript).catch(() => {});
      await writeState(e, { ...s, ...fields, billing: { recovered: true }, finished_at: iso(now()), pid: process.pid });
      errors++;
    }
    claimable.clear(); seenIntents.clear(); claimed.clear();
    counters.resumed += resumed; counters.recovered_errors += errors; counters.expired += expired;
    if (resumed || errors || removed || expired) log(`runs: recovered ${resumed} queued run(s), ${expired} expired, ${errors} interrupted run(s) ended, ${removed} unfinished start(s) removed`);
    pump();
    return { resumed, errors, removed, expired };
  }

  function startTimers(intervalMs = 60000) {
    if (timer) return;
    timer = setInterval(() => { sweep().catch((err) => log(`runs: sweep failed (${err.code ?? err.message})`)); pump(); }, intervalMs);
    timer.unref?.();
  }
  const stop = () => { if (timer) clearInterval(timer); timer = null; };

  // Counts only; never a question, an answer or a principal list.
  const stats = () => {
    const by = { reserving: 0, queued: 0, running: 0, done: 0, failed: 0 };
    for (const e of index.values()) by[e.status] = (by[e.status] ?? 0) + 1;
    return { runs: index.size, ...by, bytes: totalBytes(), byte_bound: config.maxBytes, slots_in_use: slots.global, slots_global: config.global, waiting: queue.length, ...counters };
  };

  return { start, status, result, accept, get, cancel, pump, sweep, load, claimIntent, recover, startTimers, stop, stats, config, purgeUnstored,
    _internal: { index, slots, queue, finalizePending, webPending } };
}

function defaultAlive(pid) { try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; } }
