// Durable settlement outbox for the external auth hook (docs/external-auth.md). Zero dependencies.
//
// `settle` and `release` calls (and orphan reconciliation, which is a `settle`) that could not be delivered at once
// are written here and delivered later: at-least-once transport, exactly-once effect (the service's operations are
// idempotent per reservation, see the state machine). Records are never discarded by age or count.
//
//   <stateDir>/auth-outbox/pending/<record>.json          waiting for delivery (or for its next_attempt_at)
//   <stateDir>/auth-outbox/claimed/<pid>-<record>.json    being delivered by process <pid>
//   <stateDir>/auth-outbox/dead/<record>.json             conflict or permanent failure: kept until an operator acts
//
// A record is one JSON file (mode 0600, written to a temp file, fsynced, then linked/renamed into place):
//   { record_id, call, payload, created_at, attempts, next_attempt_at, last_error? }
// record_id is the idempotency key: "<call>.<reservation_id|request_id field>.<value>".
//
// Claiming is a rename from pending/ to claimed/: exactly one process wins, the losers move on. A claim older than
// E3D_MCP_OUTBOX_CLAIM_SEC (default 300) belongs to a crashed deliverer and is moved back to pending/ (attempts kept).
// At E3D_MCP_OUTBOX_MAX (default 5000) undelivered records, canAccept() is false: the server must refuse new billed
// work until delivery drains the queue. Dead-lettered records (E3D_MCP_OUTBOX_MAX_DEAD, default 1) also stop new work. enqueue() itself never refuses, so usage that already happened is never lost.
import { chmod, link, mkdir, open, readdir, readFile, rename, rmdir, stat, unlink, utimes } from 'node:fs/promises';
import { readdirSync } from 'node:fs';
import { createHash, randomBytes } from 'node:crypto';
import { join } from 'node:path';

export const OUTBOX_DEFAULTS = {
  max: 5000, claimSec: 300, staleSec: 72 * 3600, intervalMs: 30000,
  backoffBaseMs: 30000, backoffMaxMs: 15 * 60000, maxConsecutiveFailures: 3,
};
const ID_FIELDS = { settle: ['reservation_id'], release: ['reservation_id', 'request_id'] };
const ID_VALUE = /^[A-Za-z0-9_.:-]{1,128}$/;
// A full record id as recordIdFor() builds it: <call>.<field>.<id value>.
// (A dead-lettered conflict has the same form behind a conflict-<8 hex>. prefix.)
const RECORD_ID = /^(conflict-[0-9a-f]{8}\.)?(settle|release)\.(reservation_id|request_id)\.[A-Za-z0-9_.:-]{1,128}$/;
const iso = (ms) => new Date(ms).toISOString();
const posInt = (raw, dflt) => { const n = Number(raw); return raw != null && raw !== '' && Number.isSafeInteger(n) && n > 0 ? n : dflt; };

// The stable idempotency key of a call. Throws TypeError for an unknown call or a payload without a usable id.
export function recordIdFor(call, payload) {
  const fields = ID_FIELDS[call];
  if (!fields) throw new TypeError(`auth-outbox: unknown call ${JSON.stringify(call)}`);
  const field = fields.find((f) => payload?.[f] != null);
  if (!field || !ID_VALUE.test(String(payload[field]))) throw new TypeError(`auth-outbox: ${call} payload has no valid ${fields.join(' or ')}`);
  return `${call}.${field}.${payload[field]}`;
}
// ':' is legal in ids but not in every filesystem's names; '%' never appears in an id, so this is reversible.
const fileFor = (recordId) => `${recordId.replace(/:/g, '%3A')}.json`;
const isRecordFile = (name) => name.endsWith('.json') && !name.startsWith('.');
const unclaimedName = (name) => name.replace(/^\d+-/, '');

// Backoff after `attempts` failed deliveries: 30 s doubling to 15 minutes, +/-20% jitter, never above the cap.
export function backoffMs(attempts, { backoffBaseMs = OUTBOX_DEFAULTS.backoffBaseMs, backoffMaxMs = OUTBOX_DEFAULTS.backoffMaxMs } = {}, random = Math.random) {
  const delay = Math.min(backoffMaxMs, backoffBaseMs * 2 ** Math.min(Math.max(attempts, 1) - 1, 30));
  return Math.min(backoffMaxMs, Math.round(delay * (0.8 + 0.4 * random())));
}

async function syncDir(dir) {
  // fsync of a directory makes a rename/link durable on POSIX; some platforms (Windows) cannot open a directory.
  let fh;
  try { fh = await open(dir, 'r'); await fh.sync(); } catch { /* not supported here */ } finally { await fh?.close().catch(() => {}); }
}

// Write `data` durably as dir/name. exclusive: never replace an existing file (returns false if one exists).
async function writeDurable(dir, name, data, { exclusive = false } = {}) {
  const tmp = join(dir, `.tmp-${process.pid}-${randomBytes(6).toString('hex')}`);
  const fh = await open(tmp, 'wx', 0o600);
  try { await fh.writeFile(data); await fh.sync(); } finally { await fh.close(); }
  const target = join(dir, name);
  try {
    if (!exclusive) await rename(tmp, target);
    else {
      try { await link(tmp, target); } catch (e) {
        if (e.code === 'EEXIST') return false;
        if (!['EPERM', 'ENOTSUP', 'EOPNOTSUPP', 'ENOSYS'].includes(e.code)) throw e;
        // no hard links on this filesystem: a mkdir lock (atomic everywhere) makes check-then-rename exclusive
        const lock = `${target}.lk`;
        try { await mkdir(lock, { mode: 0o700 }); } catch (err) { if (err.code === 'EEXIST') return false; throw err; }
        try {
          if (await stat(target).then(() => true, () => false)) return false;
          await rename(tmp, target);
        } finally { await rmdir(lock).catch(() => {}); }
      }
    }
  } finally { await unlink(tmp).catch(() => {}); }
  await syncDir(dir);
  return true;
}

export function createOutbox({ dir, auth, now = Date.now, log = () => {}, limits = {}, env = process.env, random = Math.random } = {}) {
  if (!dir) throw new TypeError('createOutbox: dir (the state directory) is required');
  if (!auth || typeof auth.settle !== 'function' || typeof auth.release !== 'function') throw new TypeError('createOutbox: auth with settle() and release() is required');
  const cfg = {
    ...OUTBOX_DEFAULTS,
    max: posInt(env.E3D_MCP_OUTBOX_MAX, OUTBOX_DEFAULTS.max),
    maxDead: posInt(env.E3D_MCP_OUTBOX_MAX_DEAD, 1),
    claimSec: posInt(env.E3D_MCP_OUTBOX_CLAIM_SEC, OUTBOX_DEFAULTS.claimSec),
    ...limits,
  };
  const root = join(dir, 'auth-outbox');
  const dirs = { pending: join(root, 'pending'), claimed: join(root, 'claimed'), dead: join(root, 'dead') };
  const held = new Map(); // record_id -> { call, payload, opts }: records that could not be written; retried by flush()
  const counters = { enqueued: 0, duplicates: 0, delivered: 0, retried: 0, dead_lettered: 0, recovered_claims: 0, write_failures: 0 };
  let timer = null;
  let chain = Promise.resolve();

  let initPromise = null;
  const init = () => (initPromise ??= (async () => {
    for (const d of [dir, root, ...Object.values(dirs)]) {
      await mkdir(d, { recursive: true, mode: 0o700 });
      if (d !== dir) await chmod(d, 0o700);
    }
  })().catch((e) => { initPromise = null; throw e; }));

  const list = async (d) => (await readdir(d).catch((e) => { if (e.code === 'ENOENT') return []; throw e; })).filter(isRecordFile);
  const countSync = (d) => { try { return readdirSync(d).filter(isRecordFile).length; } catch { return 0; } };
  const readRecord = async (path) => JSON.parse(await readFile(path, 'utf8'));
  // The path of the record with this id wherever it is (pending, claimed or dead), or null.
  const findRecord = async (recordId) => {
    const file = fileFor(recordId);
    for (const d of [dirs.pending, dirs.dead]) if (await stat(join(d, file)).then(() => true, () => false)) return join(d, file);
    const c = (await list(dirs.claimed)).find((n) => unclaimedName(n) === file);
    return c ? join(dirs.claimed, c) : null;
  };
  const exists = async (recordId) => (await findRecord(recordId)) !== null;
  const canon = (v) => JSON.stringify(v, (_k, x) => (x && typeof x === 'object' && !Array.isArray(x) ? Object.fromEntries(Object.entries(x).sort(([a], [b]) => (a < b ? -1 : 1))) : x));

  // If a record with this id exists: an identical payload is a duplicate (no-op); a different one is kept whole in dead/ under a
  // conflict-<hash> id and never reported as a duplicate. Returns the enqueue result, or null when there is no such record.
  async function resolveExisting(record_id, call, payload) {
    const found = await findRecord(record_id);
    if (!found) return null;
    let prior = null;
    try { prior = JSON.parse(await readFile(found, 'utf8')); } catch { /* moved by a concurrent deliverer: treat as unreadable */ }
    if (prior && canon(prior.payload) === canon(payload)) { counters.duplicates++; return { record_id, queued: false, duplicate: true }; }
    const hash = createHash('sha256').update(canon(payload)).digest('hex').slice(0, 8);
    const conflict_id = `conflict-${hash}.${record_id}`;
    const t0 = now();
    const crec = { record_id: conflict_id, call, payload, created_at: iso(t0), attempts: 0, next_attempt_at: iso(t0), dead_at: iso(t0), dead_reason: `conflicts with the existing record ${record_id} (same id, different payload)` };
    await writeDurable(dirs.dead, fileFor(conflict_id), `${JSON.stringify(crec)}\n`, { exclusive: true });
    counters.dead_lettered++; deadLog(conflict_id, crec.dead_reason);
    return { record_id: conflict_id, queued: false, duplicate: false, dead: true, conflict: true };
  }

  // Durable before it returns. Enqueuing a record_id that is already pending, claimed or dead is a no-op.
  // opts: attempts (failed deliveries so far; > 0 schedules the next try by backoff), next_attempt_at (ms),
  // last_error, dead (a reason: write straight to dead/).
  async function enqueue(call, payload, opts = {}) {
    const record_id = recordIdFor(call, payload);
    await init();
    const dup = await resolveExisting(record_id, call, payload);
    if (dup) return dup;
    const t = now();
    const attempts = opts.attempts ?? 0;
    const rec = {
      record_id, call, payload, created_at: iso(t), attempts,
      next_attempt_at: iso(opts.next_attempt_at ?? (attempts > 0 ? t + backoffMs(attempts, cfg, random) : t)), ...(opts.last_error ? { last_error: String(opts.last_error).slice(0, 200) } : {}),
      ...(opts.dead ? { dead_at: iso(t), dead_reason: String(opts.dead).slice(0, 200) } : {}),
    };
    const wrote = await writeDurable(opts.dead ? dirs.dead : dirs.pending, fileFor(record_id), `${JSON.stringify(rec)}\n`, { exclusive: true });
    if (!wrote) {
      // lost the exclusive-create race: the winner may carry a different payload, so compare instead of assuming a duplicate
      const dup = await resolveExisting(record_id, call, payload);
      if (dup) return dup;
      counters.duplicates++; return { record_id, queued: false, duplicate: true }; // the winner was already delivered and removed
    }
    counters.enqueued++;
    if (opts.dead) { counters.dead_lettered++; deadLog(record_id, rec.dead_reason); }
    return { record_id, queued: true, duplicate: false, dead: !!opts.dead };
  }

  // Like enqueue, but never throws: if the record cannot be written it is held in memory (canAccept() turns false)
  // and flush() keeps trying to write it. Returns { record_id, queued, duplicate, held, dead, error }.
  async function enqueueOrHold(call, payload, opts = {}) {
    let record_id;
    try { record_id = recordIdFor(call, payload); } catch (e) {
      log(`auth-outbox: ERROR cannot record a ${String(call).slice(0, 20)} call: ${e.message}`);
      return { record_id: null, queued: false, held: false, error: e.message };
    }
    try {
      const r = await enqueue(call, payload, opts);
      held.delete(record_id);
      return { ...r, held: false };
    } catch (e) {
      counters.write_failures++;
      held.set(record_id, { call, payload, opts });
      log(`auth-outbox: ERROR could not write record ${record_id} (${e.code ?? e.message}); held in memory, new billed work is refused until it is written`);
      return { record_id, queued: false, held: true, error: e.code ?? e.message };
    }
  }

  const deadLog = (recordId, reason) => log(`auth-outbox: ERROR record ${recordId} moved to dead-letter (${reason}); it will not be retried until an operator acts`);

  // Rewrite a claimed record in place (atomically), then move it to `toDir` with one rename.
  async function moveClaimed(claimedPath, rec, toDir) {
    await writeDurable(dirs.claimed, claimedPath.slice(dirs.claimed.length + 1), `${JSON.stringify(rec)}\n`);
    await rename(claimedPath, join(toDir, fileFor(rec.record_id)));
    await syncDir(toDir);
  }

  async function deliver(rec, claimedPath) {
    let reason = null;
    try {
      const r = rec.call === 'settle' ? await auth.settle(rec.payload) : await auth.release(rec.payload);
      if (r?.ok) {
        await unlink(claimedPath).catch((e) => { if (e.code !== 'ENOENT') throw e; });
        await syncDir(dirs.claimed);
        counters.delivered++;
        return 'delivered';
      }
      reason = `service answered ${r?.code ?? 'not ok'}`;
    } catch (e) {
      if (e instanceof TypeError || e?.kind === 'config') reason = e instanceof TypeError ? `invalid record: ${e.message}` : 'configuration failure (service token rejected)';
      else {
        rec.attempts = (rec.attempts ?? 0) + 1;
        rec.next_attempt_at = iso(now() + backoffMs(rec.attempts, cfg, random));
        rec.last_error = `${e?.kind ?? 'error'}: ${String(e?.message ?? e).slice(0, 160)}`;
        await moveClaimed(claimedPath, rec, dirs.pending);
        counters.retried++;
        return 'retried';
      }
    }
    rec.dead_at = iso(now());
    rec.dead_reason = reason.slice(0, 200);
    await moveClaimed(claimedPath, rec, dirs.dead);
    counters.dead_lettered++;
    deadLog(rec.record_id, rec.dead_reason);
    return 'dead';
  }

  // Claims older than claimSec belong to a crashed (or hung) deliverer: put them back, attempts preserved.
  // Leftover temp files from a crash mid-write are removed after the same age.
  async function recoverClaims() {
    const limit = cfg.claimSec * 1000;
    for (const d of [dirs.claimed, dirs.pending, dirs.dead]) {
      for (const name of await readdir(d).catch(() => [])) {
        const path = join(d, name);
        const st = await stat(path).catch(() => null);
        if (!st || now() - st.mtimeMs <= limit) continue;
        if (name.startsWith('.tmp-')) { await unlink(path).catch(() => {}); continue; }
        if (d !== dirs.claimed || !isRecordFile(name)) continue;
        try {
          await rename(path, join(dirs.pending, unclaimedName(name)));
          counters.recovered_claims++;
          log(`auth-outbox: recovered a stale claim on ${unclaimedName(name).replace(/\.json$/, '').replace(/%3A/g, ':')} (older than ${cfg.claimSec} s)`);
        } catch (e) { if (e.code !== 'ENOENT') throw e; }
      }
    }
    await syncDir(dirs.pending);
  }

  async function doFlush() {
    const result = { delivered: [], retried: [], dead: [], skipped: 0 };
    await init();
    for (const [, h] of [...held]) await enqueueOrHold(h.call, h.payload, h.opts);
    await recoverClaims();
    let failures = 0;
    for (const name of await list(dirs.pending)) {
      if (failures >= cfg.maxConsecutiveFailures) { result.skipped++; continue; } // the service is down: try again next tick
      const pendingPath = join(dirs.pending, name);
      let rec;
      try { rec = await readRecord(pendingPath); } catch (e) {
        if (e.code === 'ENOENT') continue; // another deliverer took it
        rec = null; // unreadable: claim it and dead-letter it below, never delete it
      }
      if (rec && Date.parse(rec.next_attempt_at) > now()) continue;
      // claim: stamp the claim time, then rename; losing the race (ENOENT) means someone else has it
      const claimedPath = join(dirs.claimed, `${process.pid}-${name}`);
      try {
        const t = now() / 1000;
        await utimes(pendingPath, t, t);
        await rename(pendingPath, claimedPath);
      } catch (e) { if (e.code === 'ENOENT') continue; throw e; }
      try { rec = await readRecord(claimedPath); } catch (e) {
        if (e.code === 'ENOENT') continue;
        const id = name.replace(/\.json$/, '').replace(/%3A/g, ':');
        await rename(claimedPath, join(dirs.dead, name));
        counters.dead_lettered++;
        deadLog(id, 'unreadable record');
        result.dead.push(id);
        continue;
      }
      const outcome = await deliver(rec, claimedPath);
      result[outcome].push(rec.record_id);
      failures = outcome === 'retried' ? failures + 1 : 0;
    }
    return result;
  }

  // Deliver everything that is due. Calls are serialized inside this process; other processes coordinate by claim.
  function flush() {
    const p = chain.then(doFlush, doFlush);
    chain = p.catch(() => {});
    return p;
  }

  // Safety bound: false while undelivered records are at the bound or a record could not be written.
  const undelivered = () => countSync(dirs.pending) + countSync(dirs.claimed);
  // Dead-lettered settlements are billed work the service never received: until an operator retries or resolves them
  // (--outbox-status, --outbox-retry-dead), no new billed work starts. E3D_MCP_OUTBOX_MAX_DEAD (default 1) is how many are tolerated.
  const canAccept = () => held.size === 0 && undelivered() < cfg.max && countSync(dirs.dead) < cfg.maxDead;

  // Counts and ages only, never payloads.
  async function stats() {
    await init();
    const out = { pending: 0, claimed: 0, dead: 0, stale: 0, held_in_memory: held.size, oldest_age_sec: 0, bound: cfg.max };
    const t = now();
    for (const [kind, d] of Object.entries(dirs)) {
      for (const name of await list(d)) {
        out[kind]++;
        let created;
        try { created = Date.parse((await readRecord(join(d, name))).created_at); } catch { continue; }
        if (!Number.isFinite(created)) continue;
        const age = Math.max(0, Math.floor((t - created) / 1000));
        if (age > cfg.staleSec) out.stale++;
        if (age > out.oldest_age_sec) out.oldest_age_sec = age;
      }
    }
    out.accepting = held.size === 0 && out.pending + out.claimed < cfg.max;
    out.healthy = out.accepting && out.dead === 0;
    out.counters = { ...counters };
    return out;
  }

  // Deliver now, then every intervalMs, without keeping the process alive.
  function start() {
    if (timer) return chain;
    const tick = () => flush().catch((e) => log(`auth-outbox: delivery pass failed: ${e.code ?? e.message}`));
    timer = setInterval(tick, cfg.intervalMs);
    timer.unref?.();
    return tick();
  }
  function stop() { if (timer) clearInterval(timer); timer = null; }

  return { enqueue, enqueueOrHold, flush, canAccept, stats, start, stop, dir: root, limits: { ...cfg } };
}

// ---- operator commands (e3d-mcp --outbox-status | --outbox-export <file> | --outbox-retry-dead <id>) ----
// They work on the files directly, need no auth client and print only record ids, call names, ages and counts.
const KINDS = ['pending', 'claimed', 'dead'];
async function readAll(dir, now) {
  const root = join(dir, 'auth-outbox');
  const out = [];
  for (const kind of KINDS) {
    let names = [];
    try { names = (await readdir(join(root, kind))).filter(isRecordFile); } catch { /* no outbox yet */ }
    for (const name of names) {
      try {
        const rec = JSON.parse(await readFile(join(root, kind, name), 'utf8'));
        const created = Date.parse(rec.created_at);
        out.push({ kind, name, rec, age_sec: Number.isFinite(created) ? Math.max(0, Math.floor((now - created) / 1000)) : null });
      } catch { out.push({ kind, name, rec: null, age_sec: null }); }
    }
  }
  return { root, entries: out };
}

export async function outboxStatus(dir, { now = Date.now(), staleSec = OUTBOX_DEFAULTS.staleSec } = {}) {
  const { entries } = await readAll(dir, now);
  const lines = [];
  const count = (k) => entries.filter((e) => e.kind === k).length;
  lines.push(`outbox: ${count('pending')} pending, ${count('claimed')} claimed, ${count('dead')} dead, ${entries.filter((e) => e.age_sec > staleSec).length} stale (older than ${Math.round(staleSec / 3600)} h)`);
  for (const e of entries) {
    const id = e.rec?.record_id ?? e.name.replace(/\.json$/, '').replace(/%3A/g, ':');
    lines.push(`  ${e.kind.padEnd(7)} ${id}  call=${e.rec?.call ?? 'unreadable'}  age=${e.age_sec ?? 'unknown'}s${e.kind === 'dead' && e.rec?.dead_reason ? `  reason=${String(e.rec.dead_reason).replace(/[^\x20-\x7e]/g, '?').slice(0, 80)}` : ''}`);
  }
  return { lines, dead: count('dead') };
}

// Pending, claimed and dead records with payloads (they hold ids and usage numbers, never a token), for reconciliation.
export async function outboxExport(dir, file, { now = Date.now() } = {}) {
  if (!file) throw new Error('--outbox-export needs a file name');
  const { entries } = await readAll(dir, now);
  const records = entries.filter((e) => e.rec).map((e) => ({ state: e.kind === 'dead' ? 'dead' : 'pending', ...e.rec }));
  const fh = await open(file, 'wx', 0o600); // never overwrites an existing file
  try { await fh.writeFile(`${JSON.stringify({ exported_at: iso(now), records }, null, 2)}\n`); } finally { await fh.close(); }
  await chmod(file, 0o600);
  return { count: records.length, dead: records.filter((r) => r.state === 'dead').length };
}

// The only mutating command: one dead record back to pending, by its exact record id.
export async function outboxRetryDead(dir, id, { now = Date.now() } = {}) {
  if (typeof id !== 'string' || !RECORD_ID.test(id)) throw new Error('--outbox-retry-dead needs one exact record id (see --outbox-status)');
  const root = join(dir, 'auth-outbox');
  const file = fileFor(id);
  const deadPath = join(root, 'dead', file);
  let rec;
  try { rec = JSON.parse(await readFile(deadPath, 'utf8')); } catch { throw new Error(`no dead record with id ${id}`); }
  if (rec.record_id !== id) throw new Error(`no dead record with id ${id}`);
  delete rec.dead_at; delete rec.dead_reason; delete rec.last_error;
  rec.attempts = 0; rec.next_attempt_at = iso(now);
  const wrote = await writeDurable(join(root, 'pending'), file, `${JSON.stringify(rec)}\n`, { exclusive: true });
  if (!wrote) throw new Error(`record ${id} is already pending`);
  await unlink(deadPath);
  return { record_id: id };
}
