// Metering for e3d_debate: one object that hides whether spend is checked only by the local daily caps (usage.js) or
// also by the external auth and metering service (docs/external-auth.md). Zero dependencies.
//
//   begin(principal, cost, meta)  reserve BEFORE any model runs. With the hook: external reserve first, then the local
//                                 reserve, then a metering intent on disk; a refusal of either touches nothing else.
//   commit(handle, actual, meta)  settle what actually happened (from the transcript), whatever the outcome; release is
//                                 used only when actual calls are zero. Local and external settlement are independent.
//   abort(handle, reason)         nothing ran: give both reservations back.
//   recover({ claim })            at startup: settle or release every intent a crashed process left behind; an intent for
//                                 which claim(intent) returns true is left to its owner (the async run store, lib/mcp/runs.js).
//   adopt(intent)                 rebuild the handle of a claimed intent (a queued async run resumed after a restart).
//   beginAuthorized(...)          a web run the billing service already reserved (authorize-run, lib/mcp/run-server.js): no
//                                 new reserve; the intent and the local reserve only. Once accepted, every way it ends is ONE
//                                 finalize (abort included); forget() undoes it locally before it was accepted.
//
// Without the hook every call delegates to the local usage object exactly as before.
//
// When the service advertises `finalize` (Debate contract v1) and begin() is given the debate (meta.debate), the debate
// is finalized instead of settled: commit() sends ONE immutable finalize body per reservation (outcome, usage, and the
// result only for an ok outcome) through the outbox, never a settle. A run that started models and was interrupted is
// finalized on recovery as outcome "error" without a result; the orphan policy applies only without `finalize`.
//
// Intents live in <stateDir>/metering-intents/<request_id>.json (dir 0700, files 0600, written atomically):
//   { request_id, principal, reservation_id, units, tool, started_at, pid, settlement?, debate_id?, debate? }
// `settlement` is the exact settle/release/finalize call commit decided on; recover() replays it (idempotent) instead of
// applying the orphan policy. An intent is removed only once its settlement is delivered or durably in the outbox.
// `debate` (finalize only) holds the question, providers and rounds so recovery can build the finalize body; intents are
// state files, never logged.
import { randomBytes, randomUUID } from 'node:crypto';
import { chmod, link, mkdir, open, readdir, readFile, rename, stat, unlink, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { schemaOf, validateSchema } from './external-auth.js';
import { fitFinalizeBody } from './outbox.js';

export const ORPHAN_POLICIES = ['charge', 'release'];
const LOCK_STALE_MS = 10 * 60 * 1000;
const INTENT_FILE = /^[0-9a-fA-F-]{36}\.json$/;
const sleepMs = (ms) => new Promise((r) => { const t = setTimeout(r, ms); t.unref?.(); });

// E3D_MCP_ORPHAN_POLICY: charge (default: a crash never produces free usage) or release (operators who prefer to under-charge).
export function orphanPolicy(env = process.env) {
  const p = env.E3D_MCP_ORPHAN_POLICY || 'charge';
  if (!ORPHAN_POLICIES.includes(p)) throw new Error(`E3D_MCP_ORPHAN_POLICY must be one of ${ORPHAN_POLICIES.join(', ')}`);
  return p;
}

// Who answered, for the settle record: one entry per provider from the transcript ("## Round N -- provider"), and the
// synthesizer for any remaining counted call. Model names are not known here, so they are reported as "unspecified".
export function modelsFromTranscript(transcript, { synthesizer, calls }) {
  const counts = new Map();
  for (const m of String(transcript).matchAll(/^## Round \d+ -- (\S+)$/gm)) counts.set(m[1], (counts.get(m[1]) ?? 0) + 1);
  const counted = [...counts.values()].reduce((a, b) => a + b, 0);
  if (calls > counted && synthesizer) counts.set(synthesizer, (counts.get(synthesizer) ?? 0) + calls - counted);
  return [...counts].filter(([p]) => /^[!-~]{1,64}$/.test(p)).slice(0, 32).map(([provider, n]) => ({ provider, model: 'unspecified', calls: n }));
}

export const newDebateId = () => `dbt_${randomBytes(12).toString('hex')}`;
const FINALIZE_SCHEMA = schemaOf('finalize', 'request');
const QUESTION_SCHEMA = FINALIZE_SCHEMA.properties.question;
// The contract's bound on a question (8000 Unicode scalar values, no control characters but tab, LF and CR): a debate that
// cannot be finalized is refused before anything is reserved or any model runs.
export const questionFitsContract = (q) => typeof q === 'string' && validateSchema(QUESTION_SCHEMA, q).length === 0;

async function syncDir(dir) {
  let fh;
  try { fh = await open(dir, 'r'); await fh.sync(); } catch { /* not supported on this platform */ } finally { await fh?.close().catch(() => {}); }
}

export function createMetering({ localUsage, external = null, outbox = null, log = () => {}, dir = localUsage?.dir, env = process.env, now = Date.now, reserveBudgetMs = 3000, sleep = sleepMs } = {}) {
  if (!localUsage) throw new TypeError('createMetering: localUsage is required');
  const hooked = Boolean(external);
  const policy = hooked ? orphanPolicy(env) : 'charge';
  const intentsDir = dir ? join(dir, 'metering-intents') : null;
  if (hooked && !intentsDir) throw new TypeError('createMetering: a state directory is required with the external hook');
  const counters = { orphans: 0, orphans_charged: 0, orphans_released: 0, orphans_finalized: 0, settlements_replayed: 0, intents_kept: 0, reserve_retries: 0, unconfirmed_reserves: 0, finalize_unfit: 0 };
  // Debates are finalized (not settled) exactly when the service advertises it; checked per debate at begin().
  const finalizeEnabled = () => hooked && typeof external.hasFeature === 'function' && external.hasFeature('finalize');

  let ready = null;
  const init = () => (ready ??= (async () => { await mkdir(intentsDir, { recursive: true, mode: 0o700 }); await chmod(intentsDir, 0o700); })().catch((e) => { ready = null; throw e; }));
  const intentPath = (requestId) => join(intentsDir, `${requestId}.json`);
  async function writeIntent(intent) {
    await init();
    const tmp = join(intentsDir, `.tmp-${process.pid}-${randomBytes(6).toString('hex')}`);
    const fh = await open(tmp, 'wx', 0o600);
    try { await fh.writeFile(`${JSON.stringify(intent)}\n`); await fh.sync(); } finally { await fh.close(); }
    try { await rename(tmp, intentPath(intent.request_id)); } catch (e) { await unlink(tmp).catch(() => {}); throw e; }
    await syncDir(intentsDir);
  }
  async function removeIntent(requestId) {
    await unlink(intentPath(requestId)).catch((e) => { if (e.code !== 'ENOENT') throw e; });
    await syncDir(intentsDir);
  }
  const intentOf = (h, phase = 'prepared') => ({ phase, request_id: h.request_id, principal: h.principal, reservation_id: h.reservation_id, units: { calls: h.cost.calls, est_tokens: h.cost.tokens }, tool: h.tool, started_at: new Date(h.started_at).toISOString(), pid: process.pid,
    ...(h.finalize ? { finalize: true, debate_id: h.debate_id, debate: h.debate } : {}), ...(h.authorized ? { authorized: true } : {}) });

  const durable = (call, payload) => (call === 'settle' ? external.settleDurable(payload) : call === 'finalize' ? external.finalizeDurable(payload) : external.releaseDurable(payload));

  // The one finalize body of a reservation. An ok outcome needs a result; error and timeout carry none. Fitted to the contract
  // limits (the transcript is cut at a section boundary); a body that still does not fit or match the schema (an oversized
  // answer, say) becomes an error without a result, so a result that cannot be stored is never charged as one.
  function finalizeBody({ reservation_id, debate_id, debate, started_at }, actual, meta) {
    const outcome = meta.outcome === 'ok' && meta.result ? 'ok' : meta.outcome === 'timeout' ? 'timeout' : 'error';
    const startedMs = Date.parse(started_at);
    const finishedMs = meta.finished_at ?? now();
    const body = {
      reservation_id, debate_id, source: debate.source ?? 'connector', outcome,
      actual: { calls: actual.calls, est_input_tokens: actual.inTokens, est_output_tokens: actual.outTokens },
      models: meta.models ?? [], duration_ms: Math.min(Math.max(Math.round(meta.duration_ms ?? finishedMs - startedMs), 0), 86400000),
      question: debate.question, providers: [...debate.providers], rounds: debate.rounds,
      result: outcome === 'ok' ? meta.result : null, transcript: meta.transcript ?? null, truncated: false,
      started_at: new Date(startedMs).toISOString(), finished_at: new Date(Math.max(finishedMs, startedMs)).toISOString(),
    };
    const fitted = fitFinalizeBody(body);
    const errs = fitted ? validateSchema(FINALIZE_SCHEMA, fitted) : ['too large'];
    if (errs.length === 0) return fitted;
    counters.finalize_unfit++;
    log(`metering: ERROR the finalize body for reservation_id=${reservation_id} debate_id=${debate_id} does not fit the contract (${errs.slice(0, 2).join('; ')}); finalizing as error without a result`);
    return fitFinalizeBody({ ...body, outcome: 'error', result: null, transcript: null, truncated: true });
  }
  const releaseExternal = (reservationId, reason) => external.releaseDurable({ reservation_id: reservationId, reason });

  // External reserve. A transport failure or a bad answer is ambiguous (the service may have committed the hold), so it
  // is retried with the SAME request_id for up to reserveBudgetMs to learn the reservation id; if that never works, the
  // possible hold is released by request_id through the outbox. Returns { state: ok | refused | unknown | failed }.
  async function reserveExternal(args) {
    let deadline = null; let delay = 200;
    for (;;) {
      try {
        const r = await external.reserve(args);
        return r.ok ? { state: 'ok', reservation_id: r.reservation_id } : { state: 'refused', code: r.code, message: r.message ?? '' };
      } catch (e) {
        // a rejected service token or an invalid request was never committed: nothing to recover
        if (e instanceof TypeError || e?.kind === 'config') { log(`metering: reserve failed (${e instanceof TypeError ? 'invalid request' : 'configuration'}) request_id=${args.request_id}`); return { state: 'failed' }; }
        deadline ??= now() + reserveBudgetMs;
        if (now() + delay >= deadline) break;
        counters.reserve_retries++;
        await sleep(delay);
        delay *= 2;
      }
    }
    counters.unconfirmed_reserves++;
    log(`metering: reserve unconfirmed request_id=${args.request_id} principal=${args.principal}; releasing it by request_id`);
    await external.releaseDurable({ request_id: args.request_id, reason: 'reserve_unconfirmed' });
    return { state: 'unknown' };
  }

  const unavailable = { ok: false, kind: 'unavailable' };

  // Returns { ok: true, handle, budget } or { ok: false, kind: local | billing | unavailable | invalid, reason?, code?, message?, budget? }.
  // meta: { tool, debate?: { question, providers, rounds, source? } }; the debate is finalized when meta.debate is given and the
  // service advertises finalize.
  async function begin(principal, cost, meta = {}) {
    if (!hooked) {
      const r = await localUsage.reserve(principal, cost, 'debate');
      if (!r.ok) return { ok: false, kind: 'local', reason: r.reason, budget: r.budget };
      return { ok: true, handle: Object.freeze({ external: false, principal, cost: { ...cost } }), budget: r.budget };
    }
    const finalize = Boolean(meta.debate) && finalizeEnabled();
    if (finalize && !questionFitsContract(meta.debate.question)) return { ok: false, kind: 'invalid', reason: 'the question must be 1 to 8000 characters without control characters' };
    if (outbox && !outbox.canAccept()) { log(`metering: refusing new billed work principal=${principal} (the outbox cannot accept records)`); return unavailable; }
    const tool = meta.tool ?? 'e3d_debate';
    const request_id = randomUUID();
    const ext = await reserveExternal({ principal, request_id, kind: 'debate', tool, units: { calls: cost.calls, est_tokens: cost.tokens } });
    if (ext.state === 'refused') { log(`metering: reserve refused principal=${principal} request_id=${request_id} code=${ext.code}`); return { ok: false, kind: 'billing', code: ext.code, message: ext.message }; }
    if (ext.state !== 'ok') return unavailable;
    const debate = finalize ? Object.freeze({ question: meta.debate.question, providers: Object.freeze([...meta.debate.providers]), rounds: meta.debate.rounds, source: meta.debate.source ?? 'connector' }) : null;
    const handle = Object.freeze({ external: true, principal, cost: { ...cost }, tool, request_id, reservation_id: ext.reservation_id, started_at: now(),
      ...(finalize ? { finalize: true, debate_id: meta.debate_id ?? newDebateId(), debate } : {}) });
    // The intent is journaled BEFORE the local reservation, and the local reservation is keyed by the request id, so a crash
    // at any point leaves something recover() can undo or settle exactly once (a settle/release only adjusts the counter
    // when the keyed reserve really happened).
    try { await writeIntent(intentOf(handle)); } catch (e) {
      log(`metering: ERROR could not write the metering intent request_id=${request_id} (${e.code ?? e.message}); refusing`);
      await releaseExternal(handle.reservation_id, 'intent_failed');
      return unavailable;
    }
    let local;
    try { local = await localUsage.reserve(principal, cost, 'debate', request_id); } catch (e) {
      await abort(handle, 'local_error').catch(() => {});
      throw e;
    }
    if (!local.ok) {
      // the release decision is persisted and confirmed before the intent goes, so a crash or a failed enqueue keeps it for recovery
      try { await writeIntent({ ...intentOf(handle), settlement: { call: 'release', payload: { reservation_id: handle.reservation_id, reason: 'local_cap' } } }); } catch { /* the prepared intent still releases on recovery */ }
      const rel = await releaseExternal(handle.reservation_id, 'local_cap');
      if (rel.ok) await removeIntent(request_id).catch(() => {}); else counters.intents_kept++;
      log(`metering: local cap refused principal=${principal} request_id=${request_id} reservation_id=${handle.reservation_id}; external hold released`);
      return { ok: false, kind: 'local', reason: local.reason, budget: local.budget };
    }
    log(`metering: reserved principal=${principal} request_id=${request_id} reservation_id=${handle.reservation_id}${finalize ? ` debate_id=${handle.debate_id}` : ''}`);
    return { ok: true, handle, budget: local.budget };
  }

  // A run the billing service reserved itself (the web page) and authorize-run bound to debate_id: metered from that
  // reservation, never reserved again. Needs finalize. The intent is journaled before the local reserve (keyed by a fresh
  // request id), exactly as in begin(). Returns { ok: true, handle, budget } or { ok: false, kind: local | unavailable | invalid }.
  async function beginAuthorized(principal, cost, { tool = 'web_run', reservation_id, debate_id, debate }) {
    if (!hooked || !finalizeEnabled()) return unavailable;
    if (!questionFitsContract(debate?.question)) return { ok: false, kind: 'invalid', reason: 'the question must be 1 to 8000 characters without control characters' };
    if (outbox && !outbox.canAccept()) { log(`metering: refusing a web run principal=${principal} (the outbox cannot accept records)`); return unavailable; }
    const request_id = randomUUID();
    const handle = Object.freeze({ external: true, authorized: true, principal, cost: { ...cost }, tool, request_id, reservation_id, started_at: now(), finalize: true, debate_id,
      debate: Object.freeze({ question: debate.question, providers: Object.freeze([...debate.providers]), rounds: debate.rounds, source: debate.source ?? 'web' }) });
    try { await writeIntent(intentOf(handle)); } catch (e) {
      log(`metering: ERROR could not write the metering intent request_id=${request_id} (${e.code ?? e.message}); refusing`);
      return unavailable;
    }
    let local;
    try { local = await localUsage.reserve(principal, cost, 'debate', request_id); } catch (e) { await forget(handle).catch(() => {}); throw e; }
    if (!local.ok) {
      await removeIntent(request_id).catch(() => {});
      log(`metering: local cap refused a web run principal=${principal} reservation_id=${reservation_id} debate_id=${debate_id}`);
      return { ok: false, kind: 'local', reason: local.reason, budget: local.budget };
    }
    log(`metering: authorized principal=${principal} request_id=${request_id} reservation_id=${reservation_id} debate_id=${debate_id}`);
    return { ok: true, handle, budget: local.budget };
  }

  // Undo beginAuthorized() locally (the run was never accepted, so the service keeps its reservation and decides).
  async function forget(handle) {
    try { await localUsage.release(handle.principal, handle.cost, 'debate', handle.request_id); } catch (e) { log(`metering: ERROR local release failed request_id=${handle.request_id} (${e.message})`); }
    await removeIntent(handle.request_id).catch(() => {});
  }

  // Called right before the model work begins. Until then an intent is only "prepared": a crash leaves nothing that ran, so
  // recovery releases it. From here on a crash is an orphan and E3D_MCP_ORPHAN_POLICY applies. Returns false (and the caller
  // must abort) if the started marker cannot be made durable.
  async function start(handle) {
    if (!handle.external) return true;
    try { await writeIntent(intentOf(handle, 'started')); return true; } catch (e) {
      log(`metering: ERROR could not mark the intent started request_id=${handle.request_id} (${e.code ?? e.message})`);
      return false;
    }
  }

  // actual: { calls, inTokens, outTokens } from the transcript. meta: { outcome, duration_ms, models } and, for a finalized
  // debate, { result (ok only), transcript, finished_at }. Returns { budget, billing } (billing only with the hook).
  // Never throws with the hook.
  async function commit(handle, actual, meta = {}) {
    if (!handle.external) return { budget: await localUsage.settle(handle.principal, handle.cost, actual), billing: null };
    const { principal, reservation_id, request_id } = handle; // captured at begin, never re-derived
    // with finalize every outcome, zero calls included, is one finalize (the service charges zero for zero calls)
    const call = handle.finalize ? 'finalize' : actual.calls > 0 ? 'settle' : 'release';
    const payload = call === 'finalize'
      ? finalizeBody({ ...handle, started_at: new Date(handle.started_at).toISOString() }, actual, meta)
      : call === 'settle'
        ? { reservation_id, actual: { calls: actual.calls, est_input_tokens: actual.inTokens, est_output_tokens: actual.outTokens }, models: meta.models ?? [], outcome: meta.outcome ?? 'ok', duration_ms: Math.min(Math.max(Math.round(meta.duration_ms ?? now() - handle.started_at), 0), 86400000) }
        : { reservation_id, reason: 'zero_usage' };
    // From here on a crash replays this exact settlement instead of applying the orphan policy.
    // Persist the decision first, retrying a few times. If the journal stays unwritable the usage still has to be billed (refusing
    // would make it free), so settlement goes ahead; the stale "started" intent can then only produce an orphan settle that
    // the service answers with a conflict (it already holds the real settlement), which is dead-lettered and alerted, never charged.
    let journaled = false; let lastErr = null;
    for (let attempt = 0; attempt < 3 && !journaled; attempt++) {
      try { await writeIntent({ ...intentOf(handle), settlement: { call, payload } }); journaled = true; } catch (e) { lastErr = e; await new Promise((r) => setTimeout(r, 40 * (attempt + 1))); }
    }
    if (!journaled) { counters.journal_failures = (counters.journal_failures ?? 0) + 1; log(`metering: ERROR could not record the settlement in the intent request_id=${request_id} (${lastErr?.code ?? lastErr?.message}); settling anyway`); }
    let budget = null; let localOk = true;
    try { budget = await localUsage.settle(principal, handle.cost, actual, request_id); } catch (e) { localOk = false; log(`metering: ERROR local settle failed principal=${principal} request_id=${request_id} (${e.message}); intent kept so recovery retries it`); }
    const ext = await durable(call, payload);
    if (ext.ok && localOk) await removeIntent(request_id).catch((e) => log(`metering: could not remove intent request_id=${request_id} (${e.code ?? e.message})`));
    else if (!ext.ok) { counters.intents_kept++; log(`metering: ERROR ${call} for reservation_id=${reservation_id} is not yet durable; intent kept for recovery`); }
    if (call === 'finalize') {
      log(`metering: finalized principal=${principal} request_id=${request_id} reservation_id=${reservation_id} debate_id=${handle.debate_id} calls=${actual.calls} outcome=${payload.outcome}${payload.truncated ? ' truncated' : ''}${ext.delivered ? ` stored=${ext.stored} charged=${ext.charged}` : ext.dead ? ' (dead-lettered)' : ' (queued)'}`);
      return { budget, billing: { principal, reservation_id, debate_id: handle.debate_id, ...(ext.delivered ? { stored: ext.stored, charged: ext.charged } : ext.queued && !ext.dead ? { queued: true } : {}) } };
    }
    log(`metering: ${call === 'settle' ? 'settled' : 'released (zero usage)'} principal=${principal} request_id=${request_id} reservation_id=${reservation_id} calls=${actual.calls} outcome=${meta.outcome ?? 'ok'}${ext.delivered ? '' : ' (queued)'}`);
    return { budget, billing: { principal, reservation_id } };
  }

  // Nothing ran: give the reservations back. Never throws with the hook.
  async function abort(handle, reason = 'aborted') {
    if (!handle.external) return localUsage.release(handle.principal, handle.cost, 'debate');
    // an accepted web run ends in its one finalize (error, zero calls: nothing charged), so the service's record is terminal too
    if (handle.authorized) return (await commit(handle, { calls: 0, inTokens: 0, outTokens: 0 }, { outcome: 'error', duration_ms: 0, models: [], transcript: null, finished_at: now() })).budget;
    const { principal, reservation_id, request_id } = handle;
    const why = /^[a-z0-9_]{1,40}$/.test(reason) ? reason : 'aborted';
    // The terminal decision is persisted first; the local adjustment is idempotent per request id, so a crash anywhere
    // after this point is replayed by recover() without charging work that never ran.
    try { await writeIntent({ ...intentOf(handle), settlement: { call: 'release', payload: { reservation_id, reason: why } } }); } catch { /* the orphan policy still covers it */ }
    let budget = null; let localOk = true;
    try { budget = await localUsage.release(principal, handle.cost, 'debate', request_id); } catch (e) { localOk = false; log(`metering: ERROR local release failed principal=${principal} request_id=${request_id} (${e.message})`); }
    const ext = await releaseExternal(reservation_id, why);
    if (ext.ok && localOk) await removeIntent(request_id).catch(() => {});
    else counters.intents_kept++;
    log(`metering: aborted principal=${principal} request_id=${request_id} reservation_id=${reservation_id} reason=${why}`);
    return budget;
  }

  const alive = (pid) => { try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; } };

  // Startup: every intent left by a process that is gone is reconciled. One with a recorded settlement is replayed
  // (idempotent at the service); one without is an orphan: E3D_MCP_ORPHAN_POLICY decides (charge the reserved units with
  // outcome "orphaned", or release). Intents of another live process sharing this state directory are left alone.
  // Exclusive per-intent lock: created with 'wx' and holding the owner's pid; a lock whose owner is gone is taken over.
  async function takeLock(lock) {
    for (let attempt = 0; attempt < 2; attempt++) {
      // the pid is written to a private file first and linked into place, so a lock never exists without its owner's pid
      const tmp = join(intentsDir, `.lk-${process.pid}-${randomBytes(6).toString('hex')}`);
      await writeFile(tmp, String(process.pid), { mode: 0o600 });
      try { await link(tmp, lock); return true; }
      catch (e) {
        if (e.code !== 'EEXIST') throw e;
        const owner = Number.parseInt(await readFile(lock, 'utf8').catch(() => ''), 10);
        // A lock is only honoured while it is young: reconciling one intent takes seconds, so a lock older than LOCK_STALE_MS
        // belongs to a crashed process even if its pid has since been reused by a live one.
        const age = Date.now() - (await stat(lock).then((x) => x.mtimeMs, () => Date.now()));
        if (age < LOCK_STALE_MS && Number.isInteger(owner) && alive(owner)) return false;
        if (age < LOCK_STALE_MS && !Number.isInteger(owner)) return false; // unreadable and fresh: another process is mid-write
        await unlink(lock).catch(() => {});
      } finally { await unlink(tmp).catch(() => {}); }
    }
    return false;
  }
  const rawAge = env.E3D_MCP_ORPHAN_MAX_AGE_SEC;
  if (rawAge !== undefined && rawAge !== '' && !(/^[1-9]\d{0,9}$/.test(String(rawAge)))) throw new Error('E3D_MCP_ORPHAN_MAX_AGE_SEC must be a positive whole number of seconds');
  const maxOrphanAgeMs = (rawAge ? Number(rawAge) : 6 * 3600) * 1000;
  async function recover({ claim = null } = {}) {
    if (!hooked) return { recovered: 0 };
    await init();
    let recovered = 0;
    for (const name of await readdir(intentsDir)) {
      const path = join(intentsDir, name);
      if (name.startsWith('.tmp-')) { await unlink(path).catch(() => {}); continue; }
      if (!INTENT_FILE.test(name)) continue;
      let it;
      try { it = JSON.parse(await readFile(path, 'utf8')); } catch (e) { log(`metering: ERROR unreadable intent ${name} kept for an operator (${e.code ?? 'invalid JSON'})`); continue; }
      // A live pid normally means another server is still running this debate. A pid can be reused after a crash, though, so an
      // intent older than any debate can last (E3D_MCP_ORPHAN_MAX_AGE_SEC, default 6 hours) is reconciled regardless.
      const age = Date.now() - Date.parse(it.started_at ?? '');
      const stale = Number.isFinite(age) && age > maxOrphanAgeMs;
      if (Number.isInteger(it.pid) && it.pid !== process.pid && alive(it.pid) && !stale) continue;
      // a queued async run that never started its models is resumed (or expired) by the run store, not released here
      if (claim && claim(it)) continue;
      // two recovering processes must not both reconcile one intent: whoever creates the lock file owns it
      const lock = `${path}.lock`;
      if (!(await takeLock(lock))) continue;
      try {
      // re-read under the lock: another process may have reconciled and removed it since the first read
      try { it = JSON.parse(await readFile(path, 'utf8')); } catch { continue; }
      let call; let payload; let kind;
      if (it.settlement?.call && it.settlement?.payload) {
        ({ call, payload } = it.settlement); kind = 'replayed';
      } else if (it.phase === 'prepared' && it.authorized) {
        // a web run that never started: the reservation is the service's (a retried run request re-binds the same pair), so
        // only the local reserve is undone; nothing is sent
        try { await localUsage.release(it.principal, { calls: it.units.calls, tokens: it.units.est_tokens }, 'debate', it.request_id); } catch (e) { log(`metering: ERROR could not reconcile the local counter for request_id=${it.request_id} (${e.message}); intent kept for the next start`); continue; }
        await removeIntent(it.request_id); recovered++;
        log(`metering: an unstarted web run was dropped locally request_id=${it.request_id} reservation_id=${it.reservation_id} debate_id=${it.debate_id}`);
        continue;
      } else if (it.phase === 'prepared') {
        // nothing ran: the debate never started, so whatever the orphan policy, the hold is simply given back
        call = 'release'; kind = 'released'; payload = { reservation_id: it.reservation_id, reason: 'not_started' };
      } else if (it.finalize && it.debate && it.debate_id) {
        // models started and no outcome was recorded: finalized as an error without a result, reporting the reserved units
        // (the local counter keeps them too). Built only from the intent, so a repeated recovery sends the same body.
        call = 'finalize'; kind = 'finalized';
        payload = finalizeBody(it, { calls: it.units.calls, inTokens: it.units.est_tokens, outTokens: 0 }, { outcome: 'error', duration_ms: 0, models: [], finished_at: Date.parse(it.started_at) });
      } else if (policy === 'charge') {
        call = 'settle'; kind = 'charged';
        // duration_ms is fixed at 0 so a replay of this recovery is an identical settle (a no-op), never a conflict
        payload = { reservation_id: it.reservation_id, actual: { calls: it.units.calls, est_input_tokens: it.units.est_tokens, est_output_tokens: 0 }, models: [], outcome: 'orphaned', duration_ms: 0 };
      } else { call = 'release'; kind = 'released'; payload = { reservation_id: it.reservation_id, reason: 'orphaned' }; }
      // The local daily counter was charged the worst case at begin. Bring it in line; the adjustment is keyed by the request
      // id, so it applies once however often recovery or an interrupted commit/abort repeats it. An orphan under the charge
      // policy keeps the reserved units, which is exactly what it is charged externally.
      let localFailed = false;
      if (Number.isInteger(it.units?.calls) && Number.isInteger(it.units?.est_tokens)) {
        const reserved = { calls: it.units.calls, tokens: it.units.est_tokens };
        const act = call === 'settle' || call === 'finalize' ? payload.actual : null;
        try {
          if (kind === 'replayed' && act) await localUsage.settle(it.principal, reserved, { calls: act.calls, inTokens: act.est_input_tokens, outTokens: act.est_output_tokens }, it.request_id);
          else if (kind === 'replayed' || kind === 'released') await localUsage.release(it.principal, reserved, 'debate', it.request_id);
        } catch (e) { localFailed = true; log(`metering: ERROR could not reconcile the local counter for request_id=${it.request_id} (${e.message}); intent kept for the next start`); }
      }
      const r = await durable(call, payload);
      if (kind === 'replayed') counters.settlements_replayed++;
      else {
        counters.orphans++; counters[`orphans_${kind}`]++;
        log(kind === 'finalized'
          ? `metering: interrupted debate finalized as error principal=${it.principal} request_id=${it.request_id} reservation_id=${it.reservation_id} debate_id=${it.debate_id}`
          : `metering: orphaned debate ${kind} (policy ${policy}) principal=${it.principal} request_id=${it.request_id} reservation_id=${it.reservation_id}`);
      }
      if (r.ok && !localFailed) { await removeIntent(it.request_id); recovered++; } else log(`metering: ERROR could not reconcile intent request_id=${it.request_id}; kept for the next start`);
      } finally { await unlink(lock).catch(() => {}); }
    }
    return { recovered };
  }

  // The handle of an intent written by begin() (same fields), so a claimed run can start, commit or abort exactly as if
  // this process had reserved it. The local reservation, if it happened, is keyed by the same request id.
  function adopt(it) {
    if (!hooked || !it?.request_id || !it.reservation_id || !Number.isInteger(it.units?.calls) || !Number.isInteger(it.units?.est_tokens)) return null;
    const startedMs = Date.parse(it.started_at);
    if (!Number.isFinite(startedMs)) return null;
    const finalize = it.finalize === true && it.debate && it.debate_id;
    return Object.freeze({ external: true, ...(it.authorized === true ? { authorized: true } : {}), principal: it.principal, cost: { calls: it.units.calls, tokens: it.units.est_tokens }, tool: it.tool ?? 'e3d_debate', request_id: it.request_id, reservation_id: it.reservation_id, started_at: startedMs,
      ...(finalize ? { finalize: true, debate_id: it.debate_id, debate: Object.freeze({ ...it.debate, providers: Object.freeze([...it.debate.providers]) }) } : {}) });
  }

  const stats = () => ({ hooked, orphan_policy: hooked ? policy : null, finalize: finalizeEnabled(), ...counters });
  return { hooked, begin, beginAuthorized, forget, start, commit, abort, recover, adopt, stats, finalizeEnabled };
}

// /readyz for hook mode: a background health probe (GET /health every intervalMs, result cached) plus the outbox state.
// Answering never calls the service. The outbox counts are read from disk at most once per 2 s.
export function createReadiness({ external, outbox, intervalMs = 15000, log = () => {}, now = Date.now }) {
  const probe = { ok: null, checked_at: null };
  let timer = null;
  let cached = { at: 0, stats: null };
  async function check() {
    let ok = false;
    try { await external.health(); ok = true; } catch { /* the client logged it */ }
    if (probe.ok !== ok && probe.ok !== null) log(`readiness: auth service health ${ok ? 'recovered' : 'failed'}`);
    probe.ok = ok; probe.checked_at = now(); failures = ok ? 0 : failures + 1;
  }
  // The probe also teaches the client the advertised features (health may carry them). While it fails the next try backs
  // off 1 s, 2 s, 4 s ... up to intervalMs; after a success it runs every intervalMs.
  let failures = 0; let stopped = false;
  const nextDelay = () => (failures === 0 ? intervalMs : Math.min(intervalMs, 1000 * 2 ** (failures - 1)));
  const schedule = () => {
    if (stopped) return;
    timer = setTimeout(async () => { await check().catch(() => {}); schedule(); }, nextDelay());
    timer.unref?.();
  };
  async function start() {
    await check();
    schedule();
  }
  const stop = () => { stopped = true; if (timer) clearTimeout(timer); timer = null; };
  async function state() {
    if (!cached.stats || now() - cached.at > 2000) cached = { at: now(), stats: await outbox.stats() };
    const s = cached.stats;
    const accepting = outbox.canAccept() && s.accepting;
    const reasons = [];
    if (!probe.ok) reasons.push(probe.checked_at ? 'auth service health check failed' : 'auth service not checked yet');
    if (s.dead > 0) reasons.push('dead-letter records need an operator');
    if (!s.accepting) reasons.push('outbox is at its bound');
    return {
      ready: reasons.length === 0,
      body: {
        status: reasons.length ? 'not ready' : 'ready', reasons,
        auth_service: { healthy: probe.ok === true, checked_age_sec: probe.checked_at ? Math.floor((now() - probe.checked_at) / 1000) : null },
        outbox: { pending: s.pending, claimed: s.claimed, dead: s.dead, stale: s.stale, oldest_age_sec: s.oldest_age_sec, accepting },
      },
    };
  }
  return { start, stop, check, state };
}
