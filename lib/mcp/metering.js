// Metering for e3d_debate: one object that hides whether spend is checked only by the local daily caps (usage.js) or
// also by the external auth and metering service (docs/external-auth.md). Zero dependencies.
//
//   begin(principal, cost, meta)  reserve BEFORE any model runs. With the hook: external reserve first, then the local
//                                 reserve, then a metering intent on disk; a refusal of either touches nothing else.
//   commit(handle, actual, meta)  settle what actually happened (from the transcript), whatever the outcome; release is
//                                 used only when actual calls are zero. Local and external settlement are independent.
//   abort(handle, reason)         nothing ran: give both reservations back.
//   recover()                     at startup: settle or release every intent a crashed process left behind.
//
// Without the hook every call delegates to the local usage object exactly as before.
//
// Intents live in <stateDir>/metering-intents/<request_id>.json (dir 0700, files 0600, written atomically):
//   { request_id, principal, reservation_id, units, tool, started_at, pid, settlement? }
// `settlement` is the exact settle/release call commit decided on; recover() replays it (idempotent) instead of
// applying the orphan policy. An intent is removed only once its settlement is delivered or durably in the outbox.
import { randomBytes, randomUUID } from 'node:crypto';
import { chmod, link, mkdir, open, readdir, readFile, rename, unlink, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

export const ORPHAN_POLICIES = ['charge', 'release'];
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
  const counters = { orphans: 0, orphans_charged: 0, orphans_released: 0, settlements_replayed: 0, intents_kept: 0, reserve_retries: 0, unconfirmed_reserves: 0 };

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
  const intentOf = (h) => ({ request_id: h.request_id, principal: h.principal, reservation_id: h.reservation_id, units: { calls: h.cost.calls, est_tokens: h.cost.tokens }, tool: h.tool, started_at: new Date(h.started_at).toISOString(), pid: process.pid });

  const durable = (call, payload) => (call === 'settle' ? external.settleDurable(payload) : external.releaseDurable(payload));
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

  // Returns { ok: true, handle, budget } or { ok: false, kind: local | billing | unavailable, reason?, code?, message?, budget? }.
  async function begin(principal, cost, meta = {}) {
    if (!hooked) {
      const r = await localUsage.reserve(principal, cost, 'debate');
      if (!r.ok) return { ok: false, kind: 'local', reason: r.reason, budget: r.budget };
      return { ok: true, handle: Object.freeze({ external: false, principal, cost: { ...cost } }), budget: r.budget };
    }
    if (outbox && !outbox.canAccept()) { log(`metering: refusing new billed work principal=${principal} (the outbox cannot accept records)`); return unavailable; }
    const tool = meta.tool ?? 'e3d_debate';
    const request_id = randomUUID();
    const ext = await reserveExternal({ principal, request_id, kind: 'debate', tool, units: { calls: cost.calls, est_tokens: cost.tokens } });
    if (ext.state === 'refused') { log(`metering: reserve refused principal=${principal} request_id=${request_id} code=${ext.code}`); return { ok: false, kind: 'billing', code: ext.code, message: ext.message }; }
    if (ext.state !== 'ok') return unavailable;
    const handle = Object.freeze({ external: true, principal, cost: { ...cost }, tool, request_id, reservation_id: ext.reservation_id, started_at: now() });
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
      await removeIntent(request_id).catch(() => {});
      await releaseExternal(handle.reservation_id, 'local_cap');
      log(`metering: local cap refused principal=${principal} request_id=${request_id} reservation_id=${handle.reservation_id}; external hold released`);
      return { ok: false, kind: 'local', reason: local.reason, budget: local.budget };
    }
    log(`metering: reserved principal=${principal} request_id=${request_id} reservation_id=${handle.reservation_id}`);
    return { ok: true, handle, budget: local.budget };
  }

  // actual: { calls, inTokens, outTokens } from the transcript. meta: { outcome, duration_ms, models }.
  // Returns { budget, billing } (billing only with the hook). Never throws with the hook.
  async function commit(handle, actual, meta = {}) {
    if (!handle.external) return { budget: await localUsage.settle(handle.principal, handle.cost, actual), billing: null };
    const { principal, reservation_id, request_id } = handle; // captured at begin, never re-derived
    const call = actual.calls > 0 ? 'settle' : 'release';
    const payload = call === 'settle'
      ? { reservation_id, actual: { calls: actual.calls, est_input_tokens: actual.inTokens, est_output_tokens: actual.outTokens }, models: meta.models ?? [], outcome: meta.outcome ?? 'ok', duration_ms: Math.min(Math.max(Math.round(meta.duration_ms ?? now() - handle.started_at), 0), 86400000) }
      : { reservation_id, reason: 'zero_usage' };
    // From here on a crash replays this exact settlement instead of applying the orphan policy.
    try { await writeIntent({ ...intentOf(handle), settlement: { call, payload } }); } catch (e) { log(`metering: could not record the settlement in the intent request_id=${request_id} (${e.code ?? e.message})`); }
    let budget = null;
    try { budget = await localUsage.settle(principal, handle.cost, actual, request_id); } catch (e) { log(`metering: ERROR local settle failed principal=${principal} request_id=${request_id} (${e.message})`); }
    const ext = await durable(call, payload);
    if (ext.ok) await removeIntent(request_id).catch((e) => log(`metering: could not remove intent request_id=${request_id} (${e.code ?? e.message})`));
    else { counters.intents_kept++; log(`metering: ERROR ${call} for reservation_id=${reservation_id} is not yet durable; intent kept for recovery`); }
    log(`metering: ${call === 'settle' ? 'settled' : 'released (zero usage)'} principal=${principal} request_id=${request_id} reservation_id=${reservation_id} calls=${actual.calls} outcome=${meta.outcome ?? 'ok'}${ext.delivered ? '' : ' (queued)'}`);
    return { budget, billing: { principal, reservation_id } };
  }

  // Nothing ran: give the reservations back. Never throws with the hook.
  async function abort(handle, reason = 'aborted') {
    if (!handle.external) return localUsage.release(handle.principal, handle.cost, 'debate');
    const { principal, reservation_id, request_id } = handle;
    const why = /^[a-z0-9_]{1,40}$/.test(reason) ? reason : 'aborted';
    // The terminal decision is persisted first; the local adjustment is idempotent per request id, so a crash anywhere
    // after this point is replayed by recover() without charging work that never ran.
    try { await writeIntent({ ...intentOf(handle), settlement: { call: 'release', payload: { reservation_id, reason: why } } }); } catch { /* the orphan policy still covers it */ }
    let budget = null;
    try { budget = await localUsage.release(principal, handle.cost, 'debate', request_id); } catch (e) { log(`metering: ERROR local release failed principal=${principal} request_id=${request_id} (${e.message})`); }
    const ext = await releaseExternal(reservation_id, why);
    if (ext.ok) await removeIntent(request_id).catch(() => {});
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
        if (Number.isInteger(owner) && alive(owner)) return false;
        if (!Number.isInteger(owner)) return false; // unreadable: leave it to the next start rather than race
        await unlink(lock).catch(() => {});
      } finally { await unlink(tmp).catch(() => {}); }
    }
    return false;
  }
  const maxOrphanAgeMs = (Number.parseInt(env.E3D_MCP_ORPHAN_MAX_AGE_SEC, 10) || 6 * 3600) * 1000;
  async function recover() {
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
      // two recovering processes must not both reconcile one intent: whoever creates the lock file owns it
      const lock = `${path}.lock`;
      if (!(await takeLock(lock))) continue;
      try {
      // re-read under the lock: another process may have reconciled and removed it since the first read
      try { it = JSON.parse(await readFile(path, 'utf8')); } catch { continue; }
      let call; let payload; let kind;
      if (it.settlement?.call && it.settlement?.payload) {
        ({ call, payload } = it.settlement); kind = 'replayed';
      } else if (policy === 'charge') {
        call = 'settle'; kind = 'charged';
        // duration_ms is fixed at 0 so a replay of this recovery is an identical settle (a no-op), never a conflict
        payload = { reservation_id: it.reservation_id, actual: { calls: it.units.calls, est_input_tokens: it.units.est_tokens, est_output_tokens: 0 }, models: [], outcome: 'orphaned', duration_ms: 0 };
      } else { call = 'release'; kind = 'released'; payload = { reservation_id: it.reservation_id, reason: 'orphaned' }; }
      // The local daily counter was charged the worst case at begin. Bring it in line; the adjustment is keyed by the request
      // id, so it applies once however often recovery or an interrupted commit/abort repeats it. An orphan under the charge
      // policy keeps the reserved units, which is exactly what it is charged externally.
      if (Number.isInteger(it.units?.calls) && Number.isInteger(it.units?.est_tokens)) {
        const reserved = { calls: it.units.calls, tokens: it.units.est_tokens };
        const act = call === 'settle' ? payload.actual : null;
        try {
          if (kind === 'replayed' && act) await localUsage.settle(it.principal, reserved, { calls: act.calls, inTokens: act.est_input_tokens, outTokens: act.est_output_tokens }, it.request_id);
          else if (kind === 'replayed' || kind === 'released') await localUsage.release(it.principal, reserved, 'debate', it.request_id);
        } catch (e) { log(`metering: ERROR could not reconcile the local counter for request_id=${it.request_id} (${e.message}); the day's counter stays charged`); }
      }
      const r = await durable(call, payload);
      if (kind === 'replayed') counters.settlements_replayed++;
      else {
        counters.orphans++; counters[`orphans_${kind}`]++;
        log(`metering: orphaned debate ${kind} (policy ${policy}) principal=${it.principal} request_id=${it.request_id} reservation_id=${it.reservation_id}`);
      }
      if (r.ok) { await removeIntent(it.request_id); recovered++; } else log(`metering: ERROR could not reconcile intent request_id=${it.request_id}; kept for the next start`);
      } finally { await unlink(lock).catch(() => {}); }
    }
    return { recovered };
  }

  const stats = () => ({ hooked, orphan_policy: hooked ? policy : null, ...counters });
  return { hooked, begin, commit, abort, recover, stats };
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
    probe.ok = ok; probe.checked_at = now();
  }
  async function start() {
    await check();
    timer = setInterval(() => { check().catch(() => {}); }, intervalMs);
    timer.unref?.();
  }
  const stop = () => { if (timer) clearInterval(timer); timer = null; };
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
