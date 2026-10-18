// Outbox tests for lib/mcp/outbox.js and settleDurable/releaseDurable, against examples/external-auth-stub.js.
// Driven by tests/mcp-extauth.sh: STUB_URL, SVC_TOKEN, OUTBOX_ROOT (every state dir is created under it), OUTBOX_LOG.
// Assertions are on ledger effects (the stub's settlements and reservation states), not on HTTP attempt counts.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { appendFileSync, mkdirSync, readdirSync, readFileSync, renameSync, statSync, utimesSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createExternalAuth } from '../../lib/mcp/external-auth.js';
import { backoffMs, createOutbox, outboxRetryDead, recordIdFor } from '../../lib/mcp/outbox.js';

const E = process.env;
const HERE = dirname(fileURLToPath(import.meta.url));
const URL_ = E.STUB_URL; const SVC = E.SVC_TOKEN;
const log = (...a) => appendFileSync(E.OUTBOX_LOG, `${a.join(' ')}\n`);
let passed = 0;
const test = async (name, fn) => { await fn(); passed++; console.log(`ok - ${name}`); };

const clock = () => { const c = { t: Date.now() }; c.now = () => c.t; return c; };
let n = 0;
const stateDir = (name) => { const d = join(E.OUTBOX_ROOT, `${++n}-${name}`); mkdirSync(d, { recursive: true }); return d; };
const client = (opts = {}) => createExternalAuth({ url: URL_, serviceToken: SVC, log, env: {}, timeouts: { settle: 1000, release: 1000 }, ...opts });
const setup = (name, { c = clock(), limits = {}, authOpts = {} } = {}) => {
  const auth = client({ now: c.now, ...authOpts });
  const outbox = createOutbox({ dir: stateDir(name), auth, now: c.now, log, env: {}, limits });
  auth.attachOutbox(outbox);
  return { auth, outbox, c, dirs: { pending: join(outbox.dir, 'pending'), claimed: join(outbox.dir, 'claimed'), dead: join(outbox.dir, 'dead') } };
};
const admin = async (path, body) => {
  const r = await fetch(`${URL_}/_stub/${path}`, { method: body ? 'POST' : 'GET', headers: { authorization: `Bearer ${SVC}`, 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
  return r.json();
};
const ledger = () => admin('state');
const inject = (mode, calls, extra = {}) => admin('inject', { mode, calls, ...extra });
const clear = () => admin('inject', { mode: null });
const files = (d) => readdirSync(d).filter((f) => f.endsWith('.json') && !f.startsWith('.'));
const MIN = 60000;

const reserveMany = async (count, principal = 'acct_ok') => {
  const a = client();
  const out = [];
  for (let i = 0; i < count; i++) {
    const args = { principal, request_id: randomUUID(), kind: 'debate', tool: 'e3d_debate', units: { calls: 3, est_tokens: 4000 } };
    const r = await a.reserve(args);
    assert.equal(r.ok, true, `reserve: ${JSON.stringify(r)}`);
    out.push({ ...r, request_id: args.request_id });
  }
  return out;
};
const settleArgs = (reservation_id, calls = 2) => ({ reservation_id, actual: { calls, est_input_tokens: 1500, est_output_tokens: 500 }, models: [{ provider: 'claude', model: 'claude-test', calls }], outcome: 'ok', duration_ms: 900 });
const CHARGE = 2 + 2; // 2 calls + ceil(2000 tokens / 1000) at the stub's default prices
// every reservation is settled exactly once, with the expected charge
const assertChargedOnce = async (ids, why) => {
  const s = await ledger();
  for (const id of ids) {
    const charges = s.settlements.filter((x) => x.reservation_id === id);
    assert.equal(charges.length, 1, `${why}: ${id} charged ${charges.length} times`);
    assert.equal(charges[0].charge, CHARGE, `${why}: charge`);
    assert.equal(s.reservations.find((r) => r.reservation_id === id).state, 'settled', `${why}: state`);
  }
  return s;
};
const empty = async (outbox, why) => {
  const s = await outbox.stats();
  assert.deepEqual([s.pending, s.claimed, s.dead], [0, 0, 0], `${why}: outbox not empty ${JSON.stringify(s)}`);
};
const run = (args, env) => new Promise((resolve, reject) => {
  const p = spawn(process.execPath, [join(HERE, 'extauth-outbox-worker.mjs'), ...args], { env: { ...process.env, ...env }, stdio: ['ignore', 'pipe', 'pipe'] });
  let out = ''; let err = '';
  p.stdout.on('data', (d) => { out += d; });
  p.stderr.on('data', (d) => { err += d; });
  const kill = setTimeout(() => { p.kill('SIGKILL'); reject(new Error(`worker ${args[0]} did not exit: ${err}`)); }, 15000);
  p.on('exit', (code) => { clearTimeout(kill); code === 0 ? resolve(out) : reject(new Error(`worker ${args[0]} exited ${code}: ${err}`)); });
});

await clear();

await test('record ids are the idempotency key; backoff is 30 s doubling to 15 minutes with jitter', async () => {
  assert.equal(recordIdFor('settle', { reservation_id: 'res_1' }), 'settle.reservation_id.res_1');
  assert.equal(recordIdFor('release', { request_id: '6f1c2b3a-0000-4000-8000-000000000001', reason: 'x' }), 'release.request_id.6f1c2b3a-0000-4000-8000-000000000001');
  assert.throws(() => recordIdFor('settle', {}), TypeError);
  assert.throws(() => recordIdFor('reserve', { reservation_id: 'r' }), TypeError);
  assert.throws(() => recordIdFor('settle', { reservation_id: '../../etc/passwd' }), TypeError, 'path characters are refused');
  for (const r of [0, 0.5, 0.999]) {
    const b1 = backoffMs(1, {}, () => r);
    assert.ok(b1 >= 24000 && b1 <= 36000, `attempt 1: ${b1}`);
    const b3 = backoffMs(3, {}, () => r);
    assert.ok(b3 >= 96000 && b3 <= 144000, `attempt 3: ${b3}`);
    assert.ok(backoffMs(20, {}, () => r) <= 15 * MIN && backoffMs(20, {}, () => r) >= 12 * MIN, 'capped at 15 minutes');
  }
});

await test('a dead-lettered conflict record can be retried with the documented operator command', async () => {
  const { outbox, dirs } = setup('conflict-retry');
  await outbox.enqueue('settle', settleArgs('res_conflict_retry'));
  const c = await outbox.enqueue('settle', settleArgs('res_conflict_retry', 5));
  assert.equal(c.conflict, true);
  const conflictId = c.record_id; assert.match(conflictId, /^conflict-[0-9a-f]{8}\.settle\.reservation_id\.res_conflict_retry$/);
  assert.deepEqual(await outboxRetryDead(dirname(dirname(dirs.pending)), conflictId), { record_id: conflictId });
  assert.equal(files(dirs.dead).length, 0, 'moved out of dead/'); assert.equal(files(dirs.pending).length, 2);
});

await test('enqueue is durable, mode 0600 in 0700 dirs, and the same record_id twice is a no-op', async () => {
  const { outbox, dirs } = setup('enqueue');
  const a = await outbox.enqueue('settle', settleArgs('res_dupe_check'));
  assert.equal(a.queued, true);
  const b = await outbox.enqueue('settle', settleArgs('res_dupe_check'));
  assert.deepEqual([b.queued, b.duplicate], [false, true], 'an identical second enqueue is a no-op');
  assert.equal(files(dirs.pending).length, 1);
  // Same id, DIFFERENT payload: never reported as a duplicate success. The second payload is kept whole in dead/.
  const conflict = await outbox.enqueue('settle', settleArgs('res_dupe_check', 5));
  assert.deepEqual([conflict.queued, conflict.duplicate, conflict.dead, conflict.conflict], [false, false, true, true]);
  assert.equal(files(dirs.pending).length, 1, 'the original record is untouched');
  assert.equal(files(dirs.dead).length, 1, 'the conflicting payload is retained in dead/');
  const deadRec = JSON.parse(readFileSync(join(dirs.dead, files(dirs.dead)[0]), 'utf8'));
  assert.equal(deadRec.payload.actual.calls, 5); assert.match(deadRec.dead_reason, /conflicts with the existing record/);
  assert.equal(outbox.canAccept(), false, 'a dead-lettered conflict stops new billed work until an operator resolves it');
  const rec = JSON.parse(readFileSync(join(dirs.pending, files(dirs.pending)[0]), 'utf8'));
  assert.equal(rec.record_id, 'settle.reservation_id.res_dupe_check');
  assert.equal(rec.payload.actual.calls, 2, 'the first payload is kept');
  assert.equal(rec.attempts, 0);
  for (const k of ['call', 'payload', 'created_at', 'attempts', 'next_attempt_at']) assert.ok(k in rec, k);
  assert.equal(statSync(join(dirs.pending, files(dirs.pending)[0])).mode & 0o777, 0o600);
  for (const d of [outbox.dir, ...Object.values(dirs)]) assert.equal(statSync(d).mode & 0o777, 0o700, d);
  // also a no-op while the record is claimed or dead
  renameSync(join(dirs.pending, files(dirs.pending)[0]), join(dirs.claimed, `1-${files(dirs.pending)[0]}`));
  assert.equal((await outbox.enqueue('settle', settleArgs('res_dupe_check'))).duplicate, true, 'no-op while claimed');
  await outbox.enqueue('settle', settleArgs('res_dead_dupe'), { dead: 'test' });
  assert.equal((await outbox.enqueue('settle', settleArgs('res_dead_dupe'))).duplicate, true, 'no-op while dead');
  assert.equal(files(dirs.pending).length, 0);
});

await test('settle outage fills the outbox; recovery delivers every record, each charged exactly once', async () => {
  const { auth, outbox, c } = setup('outage');
  const res = await reserveMany(6);
  const before = (await ledger()).accounts.acct_ok.balance;
  await inject('5xx', ['settle']);
  for (const r of res.slice(0, 3)) {
    const out = await auth.settleDurable(settleArgs(r.reservation_id));
    assert.deepEqual([out.ok, out.delivered, out.queued], [true, false, true], JSON.stringify(out));
  }
  await inject('drop', ['settle']); // the connection drops before the service commits
  for (const r of res.slice(3)) assert.equal((await auth.settleDurable(settleArgs(r.reservation_id))).queued, true);
  let s = await outbox.stats();
  assert.equal(s.pending, 6, 'every failed settle is in the outbox');
  assert.equal((await ledger()).settlements.filter((x) => res.some((r) => r.reservation_id === x.reservation_id)).length, 0, 'nothing charged yet');
  // not yet due: flush does nothing; due but the service is still down: attempts grow, nothing is lost
  assert.deepEqual((await outbox.flush()).delivered, []);
  c.t += 40000;
  await inject('5xx', ['settle']);
  const r1 = await outbox.flush();
  assert.equal(r1.delivered.length, 0);
  assert.ok(r1.retried.length >= 1, 'a due record was retried');
  s = await outbox.stats();
  assert.equal(s.pending, 6, 'nothing lost during the outage');
  assert.equal(s.counters.delivered, 0);
  // recovery
  await clear();
  c.t += 20 * MIN;
  const r2 = await outbox.flush();
  assert.equal(r2.delivered.length, 6, JSON.stringify(r2));
  await empty(outbox, 'after recovery');
  const st = await assertChargedOnce(res.map((r) => r.reservation_id), 'outage');
  assert.equal(before - st.accounts.acct_ok.balance, 6 * CHARGE, 'the balance moved by exactly the six charges');
});

await test('releaseDurable during an outage releases the hold once the service is back (by reservation_id and request_id)', async () => {
  const { auth, outbox, c } = setup('release');
  const [a, b] = await reserveMany(2);
  await inject('5xx', ['release']);
  assert.equal((await auth.releaseDurable({ reservation_id: a.reservation_id, reason: 'zero_usage' })).queued, true);
  assert.equal((await auth.releaseDurable({ request_id: b.request_id, reason: 'ambiguous_reserve' })).queued, true);
  await clear();
  c.t += 2 * MIN;
  assert.equal((await outbox.flush()).delivered.length, 2);
  const st = await ledger();
  for (const id of [a.reservation_id, b.reservation_id]) assert.equal(st.reservations.find((r) => r.reservation_id === id).state, 'released');
  await empty(outbox, 'after release');
});

await test('drop-after-commit: the record stays pending, redelivery is a no-op in the ledger, then the record is deleted', async () => {
  const { auth, outbox, c } = setup('drop-after-commit');
  const [r] = await reserveMany(1);
  await inject('drop-after-commit', ['settle'], { count: 1 });
  const out = await auth.settleDurable(settleArgs(r.reservation_id));
  assert.deepEqual([out.delivered, out.queued], [false, true]);
  assert.equal((await outbox.stats()).pending, 1, 'the record is pending although the service committed');
  const mid = await assertChargedOnce([r.reservation_id], 'committed before the response was lost');
  c.t += 2 * MIN;
  assert.deepEqual((await outbox.flush()).delivered, [`settle.reservation_id.${r.reservation_id}`]);
  const end = await assertChargedOnce([r.reservation_id], 'after redelivery');
  assert.equal(end.accounts.acct_ok.balance, mid.accounts.acct_ok.balance, 'redelivery changed nothing');
  await empty(outbox, 'after redelivery');
});

await test('two processes delivering one directory never deliver a record twice and never lose one', async () => {
  const { outbox } = setup('concurrent');
  const res = await reserveMany(80);
  for (const r of res) await outbox.enqueue('settle', settleArgs(r.reservation_id));
  const go = join(outbox.dir, '..', 'go');
  const env = { OUTBOX_STATE: join(outbox.dir, '..'), OUTBOX_GO: go, WORKER_LOG: E.OUTBOX_LOG };
  const workers = [run(['flush'], env), run(['flush'], env), run(['flush'], env)];
  await new Promise((r) => setTimeout(r, 300));
  writeFileSync(go, '');
  const outs = (await Promise.all(workers)).map((o) => JSON.parse(o.trim()));
  const all = outs.flatMap((o) => o.delivered);
  assert.equal(new Set(all).size, all.length, 'no record was delivered by two processes');
  assert.equal(all.length, 80, `every record delivered once (${outs.map((o) => o.delivered.length).join('+')})`);
  assert.ok(outs.filter((o) => o.delivered.length > 0).length >= 2, `both processes took part (${outs.map((o) => o.delivered.length).join('+')})`);
  await empty(outbox, 'after concurrent delivery');
  await assertChargedOnce(res.map((r) => r.reservation_id), 'concurrent');
});

await test('a crashed deliverer\'s stale claim is recovered (attempts preserved) and delivered', async () => {
  const { outbox, dirs, c } = setup('stale-claim');
  const [r] = await reserveMany(1);
  await outbox.enqueue('settle', settleArgs(r.reservation_id), { attempts: 3, next_attempt_at: c.t });
  const name = files(dirs.pending)[0];
  const claimed = join(dirs.claimed, `999999-${name}`); // a deliverer that claimed it and died
  renameSync(join(dirs.pending, name), claimed);
  utimesSync(claimed, c.t / 1000, c.t / 1000);
  assert.deepEqual((await outbox.flush()).delivered, [], 'a fresh claim is left alone');
  assert.equal(files(dirs.claimed).length, 1);
  assert.equal((await outbox.stats()).claimed, 1);
  c.t += 6 * MIN;
  await inject('5xx', ['settle']);
  await outbox.flush();
  assert.equal(files(dirs.claimed).length, 0, 'the stale claim was recovered');
  const rec = JSON.parse(readFileSync(join(dirs.pending, name), 'utf8'));
  assert.equal(rec.attempts, 4, 'attempt count preserved across recovery (3 + the failed redelivery)');
  await clear();
  c.t += 20 * MIN;
  assert.equal((await outbox.flush()).delivered.length, 1);
  await assertChargedOnce([r.reservation_id], 'stale claim');
  await empty(outbox, 'after stale-claim recovery');
});

await test('a restart with a non-empty outbox delivers at startup; the timer does not keep the process alive', async () => {
  const { outbox } = setup('restart');
  const res = await reserveMany(4);
  for (const r of res) await outbox.enqueue('settle', settleArgs(r.reservation_id));
  const env = { OUTBOX_STATE: join(outbox.dir, '..'), WORKER_LOG: E.OUTBOX_LOG };
  const out = JSON.parse((await run(['start'], env)).trim());
  assert.deepEqual([out.pending, out.claimed, out.dead, out.delivered], [0, 0, 0, 4], JSON.stringify(out));
  await assertChargedOnce(res.map((r) => r.reservation_id), 'restart');
  const t0 = Date.now();
  await run(['start-only'], env); // rejects if it is still alive after 15 s
  assert.ok(Date.now() - t0 < 10000, 'start() alone does not keep the process alive');
});

await test('at the safety bound canAccept() is false; nothing is dropped and recovery makes it true again', async () => {
  const { auth, outbox, c } = setup('bound', { limits: { max: 3 } });
  const res = await reserveMany(5);
  await inject('5xx', ['settle']);
  assert.equal(outbox.canAccept(), true);
  for (const r of res.slice(0, 3)) await auth.settleDurable(settleArgs(r.reservation_id));
  assert.equal(outbox.canAccept(), false, 'at the bound');
  let s = await outbox.stats();
  assert.deepEqual([s.accepting, s.healthy], [false, false]);
  // usage that already happened is still recorded beyond the bound: never silently dropped
  for (const r of res.slice(3)) assert.equal((await auth.settleDurable(settleArgs(r.reservation_id))).queued, true);
  s = await outbox.stats();
  assert.equal(s.pending, 5, 'nothing dropped at the bound');
  await clear();
  c.t += 20 * MIN;
  await outbox.flush();
  assert.equal(outbox.canAccept(), true, 'delivery drained the queue');
  await assertChargedOnce(res.map((r) => r.reservation_id), 'bound');
  await empty(outbox, 'after draining');
});

await test('a record that cannot be written is held in memory, refuses new work, and is written later', async () => {
  const { auth, outbox, dirs, c } = setup('held');
  const [r] = await reserveMany(1);
  await outbox.stats(); // creates the directories
  const { chmodSync } = await import('node:fs');
  chmodSync(dirs.pending, 0o500);
  try {
    await inject('5xx', ['settle']);
    const out = await auth.settleDurable(settleArgs(r.reservation_id));
    assert.deepEqual([out.ok, out.held], [false, true], JSON.stringify(out));
    assert.equal(outbox.canAccept(), false, 'an unwritten record refuses new work');
  } finally { chmodSync(dirs.pending, 0o700); }
  await clear();
  await outbox.flush(); // writes the held record (due later, by backoff)
  assert.equal((await outbox.stats()).held_in_memory, 0);
  assert.equal(outbox.canAccept(), true);
  c.t += 2 * MIN;
  await outbox.flush();
  await assertChargedOnce([r.reservation_id], 'held');
  await empty(outbox, 'after the held record');
});

await test('a conflict answer or a configuration failure moves the record to dead/ with an error line', async () => {
  const { auth, outbox, dirs, c } = setup('conflict');
  const [r, r2] = await reserveMany(2);
  assert.deepEqual(await auth.settle(settleArgs(r.reservation_id)), { ok: true });
  const out = await auth.settleDurable(settleArgs(r.reservation_id, 3)); // a different payload: conflict
  assert.deepEqual([out.ok, out.queued, out.dead], [true, true, true], JSON.stringify(out));
  assert.equal(files(dirs.dead).length, 1);
  // a conflict found during delivery (queued while the service was down) is dead-lettered too
  await inject('5xx', ['settle']);
  await auth.settleDurable(settleArgs(r2.reservation_id, 3));
  await clear();
  assert.deepEqual(await auth.settle(settleArgs(r2.reservation_id)), { ok: true });
  c.t += 2 * MIN;
  const f = await outbox.flush();
  assert.deepEqual(f.dead, [`settle.reservation_id.${r2.reservation_id}`]);
  // a permanent configuration failure (the service rejects the service token)
  const bad = createExternalAuth({ url: URL_, serviceToken: 'wrong-service-token-0123456789abcdef', log, env: {}, now: c.now });
  const badOutbox = createOutbox({ dir: join(outbox.dir, '..'), auth: bad, now: c.now, log, env: {} });
  const [r3] = await reserveMany(1);
  await badOutbox.enqueue('settle', settleArgs(r3.reservation_id));
  assert.equal((await badOutbox.flush()).dead.length, 1);
  const s = await outbox.stats();
  assert.deepEqual([s.dead, s.pending, s.healthy], [3, 0, false], 'dead records make the outbox unhealthy');
  const logText = readFileSync(E.OUTBOX_LOG, 'utf8');
  for (const id of [r.reservation_id, r2.reservation_id, r3.reservation_id]) assert.match(logText, new RegExp(`ERROR record settle\\.reservation_id\\.${id} moved to dead-letter`));
  const st = await ledger();
  assert.equal(st.settlements.filter((x) => x.reservation_id === r.reservation_id).length, 1, 'the conflict charged nothing more');
  for (const name of files(dirs.dead)) assert.ok(JSON.parse(readFileSync(join(dirs.dead, name), 'utf8')).dead_reason, 'dead records carry a reason');
  // dead records are never deleted by later passes
  c.t += 10 * 24 * 60 * MIN;
  await outbox.flush();
  assert.equal(files(dirs.dead).length, 3);
});

await test('records older than 72 hours are flagged stale; stats() never reveals payloads', async () => {
  const { auth, outbox, c } = setup('stale');
  const [r] = await reserveMany(1);
  await inject('5xx', ['settle']);
  await auth.settleDurable(settleArgs(r.reservation_id));
  let s = await outbox.stats();
  assert.equal(s.stale, 0);
  c.t += 71 * 60 * MIN;
  assert.equal((await outbox.stats()).stale, 0, 'not stale at 71 hours');
  c.t += 2 * 60 * MIN;
  s = await outbox.stats();
  assert.deepEqual([s.pending, s.stale], [1, 1], 'stale at 73 hours, and still pending (never discarded by age)');
  assert.ok(s.oldest_age_sec >= 73 * 3600, `oldest age ${s.oldest_age_sec}`);
  assert.ok(!JSON.stringify(s).includes(r.reservation_id), 'stats() carries no payload or record id');
  await clear();
  await outbox.flush();
  await assertChargedOnce([r.reservation_id], 'stale');
  await empty(outbox, 'after stale delivery');
});

await test('every outbox file has mode 0600', async () => {
  const walk = (d) => readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(d, e.name)) : [join(d, e.name)]));
  const all = walk(E.OUTBOX_ROOT).filter((f) => f.includes('auth-outbox'));
  assert.ok(all.length >= 3, `outbox files exist to check (${all.length})`);
  for (const f of all) assert.equal(statSync(f).mode & 0o777, 0o600, f);
});

console.log(`outbox tests: ${passed} passed`);
