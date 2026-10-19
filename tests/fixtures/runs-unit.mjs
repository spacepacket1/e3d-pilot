// Unit tests for lib/mcp/runs.js: the real metering and local usage, a fake billing service, and a fake executor.
// Usage: node tests/fixtures/runs-unit.mjs <state root>
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createMetering } from '../../lib/mcp/metering.js';
import { createUsage } from '../../lib/mcp/usage.js';
import { createRuns, validateRunsConfig, parseCustomerLimits, principalDir, CUSTOMER_LIMIT_DEFAULTS } from '../../lib/mcp/runs.js';

const ROOT = process.argv[2];
if (!ROOT) { console.error('usage: runs-unit.mjs <state root>'); process.exit(2); }
let n = 0;
const ok = (m) => { n++; console.log(`ok - runs: ${m}`); };
const logs = [];
const log = (...a) => logs.push(a.join(' '));
const Q = 'QCONTENT-unit: a JSON file or SQLite?';
const RESULT = { final_answer: 'ACONTENT-unit use a JSON file', consensus: 'split', dissent: 'Codex prefers SQLite.', positions: [{ provider: 'claude', model: 'unspecified', position: 'JSON.' }, { provider: 'codex', model: 'unspecified', position: 'SQLite.' }] };
const TRANSCRIPT = '# Debate\n\n## Round 1 -- claude\n\nTCONTENT-unit JSON.\n\n## Round 1 -- codex\n\nSQLite.\n';
const plan = (q = Q) => ({ question: q, mode: 'quick', providers: ['claude', 'codex'], rounds: 1, maxWords: 80, synthesizer: 'claude' });
const worst = { calls: 3, tokens: 3000 };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms = 3000) { const end = Date.now() + ms; while (Date.now() < end) { if (await fn()) return true; await sleep(10); } return false; }

// A billing service in memory: reserve, finalize (stored unless told otherwise), fetch by owner only.
function fakeService() {
  const s = { reserves: [], finalizes: [], releases: [], fetches: [], features: ['finalize', 'fetch'], refuse: null, finalizeMode: 'store', stored: new Map(), seq: 0 };
  s.ext = {
    hasFeature: (f) => s.features.includes(f),
    async reserve(a) { s.reserves.push(a); if (s.refuse) return { ok: false, code: s.refuse, message: 'refused' }; return { ok: true, reservation_id: `rsv_${++s.seq}`, expires_at: new Date(Date.now() + 9e5).toISOString() }; },
    async releaseDurable(p) { s.releases.push(p); return { ok: true }; },
    async settleDurable() { throw new Error('a settle must never be sent with finalize'); },
    async finalizeDurable(p) {
      s.finalizes.push(p);
      if (s.finalizeMode === 'queue') return { ok: true, delivered: false, queued: true };
      const keep = s.finalizeMode !== 'not_stored';
      const charged = keep && p.outcome === 'ok' && p.actual.calls > 0 ? 7 : 0;
      const reserve = s.reserves.find((r, i) => `rsv_${i + 1}` === p.reservation_id);
      if (keep) s.stored.set(p.debate_id, { principal: reserve?.principal, body: p, charged });
      return { ok: true, delivered: true, stored: keep, charged };
    },
    async fetchDebate({ debate_id, principal, include_transcript }) {
      s.fetches.push({ debate_id, principal });
      const d = s.stored.get(debate_id);
      if (!d || d.principal !== principal) return { ok: false, code: 'not_found' };
      const b = d.body;
      const debate = { debate_id, status: b.outcome === 'ok' ? 'done' : 'failed', outcome: b.outcome, question: b.question, providers: b.providers, rounds: b.rounds, result: b.result, usage: b.actual, credits_charged: d.charged, created_at: b.started_at, finished_at: b.finished_at, truncated: b.truncated };
      if (include_transcript) debate.transcript = b.transcript;
      return { ok: true, debate };
    },
  };
  return s;
}

// An executor whose debates wait on a gate (per debate id) unless the gate is open.
function fakeExecutor(meteringRef, { open = true, startFails = false, hang = false } = {}) {
  const gates = new Map(); const ran = [];
  const ex = {
    ran, open,
    release(id) { const g = gates.get(id); if (g) g.resolve(); else gates.set(id, { done: true }); },
    releaseAll() { ex.open = true; for (const g of gates.values()) g.resolve?.(); },
    async execute({ plan: p, handle, onStarted }) {
      ran.push({ id: handle.debate_id, plan: p });
      if (startFails) { await meteringRef.m.abort(handle, 'not_run'); return { startFailed: true }; }
      await meteringRef.m.start(handle);
      await onStarted();
      if (hang) await new Promise(() => {});
      if (!ex.open && !gates.get(handle.debate_id)?.done) await new Promise((resolve) => gates.set(handle.debate_id, { resolve }));
      const spent = { calls: 3, inTokens: 300, outTokens: 100 };
      const c = await meteringRef.m.commit(handle, spent, { outcome: 'ok', duration_ms: 5, models: [], result: RESULT, transcript: TRANSCRIPT, finished_at: Date.now() });
      return { outcome: 'ok', result: RESULT, transcript: TRANSCRIPT, usage: { calls: 3, est_input_tokens: 300, est_output_tokens: 100 }, billing: c.billing };
    },
  };
  return ex;
}

let active = 0;
function setup(name, { env = {}, svc = fakeService(), executor = null, exOpts = {}, concurrent = 2, now, outbox = null } = {}) {
  const dir = join(ROOT, name);
  const usage = createUsage({ env: { E3D_MCP_STATE_DIR: dir } });
  const ref = { m: null };
  ref.m = createMetering({ localUsage: usage, external: svc.ext, log, dir, env: {} });
  const ex = executor ?? fakeExecutor(ref, exOpts);
  // the tests poll often; the rate limit has its own test
  const config = validateRunsConfig({ E3D_MCP_RUNS_POLL_PER_MIN: '100000', ...env }).config;
  active = 0;
  const runs = createRuns({ dir, config, metering: ref.m, outbox, external: svc.ext, log, ...(now ? { now } : {}), execute: ex.execute,
    acquireExec: () => { if (active >= concurrent) return false; active++; return true; }, releaseExec: () => { active--; } });
  return { dir, usage, metering: ref.m, ref, runs, svc, ex };
}
const runDirs = (dir) => (existsSync(join(dir, 'runs')) ? readdirSync(join(dir, 'runs')).flatMap((g) => readdirSync(join(dir, 'runs', g)).map((id) => join(dir, 'runs', g, id))) : []);
// finished = terminal on disk and its slot given back (the last step of a run)
const settled = async (runs, id, principal = 'acct_a') => until(async () => !runs._internal.slots.held.has(id) && ['done', 'failed'].includes((await runs.status(principal, id)).status?.status));
// the slot is given back right after the terminal state is durable
const idle = (runs) => until(() => runs.stats().slots_in_use === 0);

// ---- configuration ----
{
  const d = validateRunsConfig({});
  assert.equal(d.ok, true);
  assert.deepEqual([d.config.perPrincipal, d.config.global, d.config.keepPerPrincipal, d.config.ttlSec, d.config.maxBytes], [3, 8, 50, 86400, 64 * 1024 * 1024]);
  assert.deepEqual(d.config.customer, { rounds: 2, max_words: 300, providers: 3 });
  assert.deepEqual(parseCustomerLimits('rounds=1,providers=2').value, { ...CUSTOMER_LIMIT_DEFAULTS, rounds: 1, providers: 2 });
  for (const bad of ['rounds=0', 'providers=1', 'colour=3', 'rounds=two']) assert.ok(parseCustomerLimits(bad).error, bad);
  const b = validateRunsConfig({ E3D_MCP_RUNS_PER_PRINCIPAL: '0', E3D_MCP_RUNS_TTL_SEC: 'soon', E3D_MCP_CUSTOMER_LIMITS: 'rounds=0' });
  assert.equal(b.ok, false); assert.equal(b.errors.length, 3);
  assert.equal(validateRunsConfig({ E3D_MCP_RUNS_PER_PRINCIPAL: '9', E3D_MCP_RUNS_GLOBAL: '8' }).ok, false);
  ok('configuration defaults, customer maxima parsing, and refusals of bad values');
}

// ---- start returns before the debate ends; status progresses; result; transcript only on request; hashed 0700/0600 store ----
let first;
{
  const t = setup('basic', { exOpts: { open: false } });
  const t0 = Date.now();
  const r = await t.runs.start({ principal: 'acct_a', plan: plan(), worst });
  assert.equal(r.ok, true); assert.match(r.debate_id, /^dbt_[0-9a-f]{24}$/); assert.ok(['queued', 'running'].includes(r.status)); assert.ok(r.poll_after_sec > 0);
  assert.ok(Date.now() - t0 < 1000, 'start does not wait for the debate');
  assert.equal(t.svc.reserves.length, 1); assert.equal(t.svc.finalizes.length, 0);
  await until(async () => (await t.runs.status('acct_a', r.debate_id)).status?.status === 'running');
  const s1 = await t.runs.status('acct_a', r.debate_id);
  assert.equal(s1.status.status, 'running'); assert.ok(s1.status.poll_after_sec > 0);
  const notYet = await t.runs.result('acct_a', r.debate_id);
  assert.equal(notYet.ok, true); assert.equal(notYet.debate.status, 'running'); assert.equal(notYet.debate.result, null);
  t.ex.release(r.debate_id);
  assert.ok(await settled(t.runs, r.debate_id));
  const s2 = await t.runs.status('acct_a', r.debate_id);
  assert.equal(s2.status.status, 'done'); assert.equal(s2.status.outcome, 'ok'); assert.equal(s2.status.poll_after_sec, undefined);
  const res = await t.runs.result('acct_a', r.debate_id);
  assert.deepEqual(res.debate.result, RESULT); assert.equal(res.debate.credits_charged, 7); assert.equal(res.debate.source, 'local'); assert.ok(!('transcript' in res.debate));
  const withT = await t.runs.result('acct_a', r.debate_id, true);
  assert.equal(withT.debate.transcript, TRANSCRIPT);
  assert.equal(t.svc.finalizes.length, 1); assert.equal(t.svc.finalizes[0].debate_id, r.debate_id); assert.equal(t.svc.finalizes[0].outcome, 'ok');
  // store layout: runs/<32 hex of sha256(principal)>/<debate_id>/, never the principal name
  const ph = principalDir('acct_a'); assert.match(ph, /^[0-9a-f]{32}$/);
  const rd = join(t.dir, 'runs', ph, r.debate_id);
  assert.ok(existsSync(join(rd, 'state.json')) && existsSync(join(rd, 'transcript.md')));
  for (const p of [join(t.dir, 'runs'), join(t.dir, 'runs', ph), rd]) assert.equal(statSync(p).mode & 0o777, 0o700, p);
  for (const f of ['state.json', 'transcript.md']) assert.equal(statSync(join(rd, f)).mode & 0o777, 0o600, f);
  assert.ok(!readdirSync(join(t.dir, 'runs')).some((g) => g.includes('acct')));
  assert.ok(await idle(t.runs), 'the slot is released when the run ends');
  first = { t, id: r.debate_id };
  ok('start returns before completion; status queued/running -> done; result with verdict and positions; transcript only on request; hashed 0700/0600 store');
}

// ---- per-principal isolation, fetch fallback not_found, negative cache ----
{
  const { t, id } = first;
  const fetches0 = t.svc.fetches.length;
  const other = await t.runs.result('acct_b', id);
  const unknown = await t.runs.result('acct_a', 'dbt_000000000000000000000000');
  assert.deepEqual(other, { ok: false, code: 'not_found' }); assert.deepEqual(unknown, other, 'foreign and unknown ids are indistinguishable');
  assert.deepEqual(await t.runs.status('acct_b', id), other);
  assert.equal(t.svc.fetches.length, fetches0 + 2, 'the foreign id fell back to the service, which also said not_found');
  assert.equal(t.svc.fetches.at(-2).principal, 'acct_b', 'the fallback claims the caller, never the owner');
  await t.runs.result('acct_b', id); await t.runs.status('acct_b', id);
  assert.equal(t.svc.fetches.length, fetches0 + 2, 'a not_found is cached for 60 s: no further service calls');
  assert.deepEqual(await t.runs.result('acct_a', '../../etc'), other); assert.deepEqual(await t.runs.result('acct_a', 42), other);
  assert.equal(t.svc.fetches.length, fetches0 + 2, 'malformed ids never reach the service');
  ok('another principal gets not_found (local and on fetch fallback), identical to an unknown id; negative cache; malformed ids');
}

// ---- admission slots: refused slot reserves nothing and leaves no run; global bound; released on every path ----
{
  const t = setup('slots', { env: { E3D_MCP_RUNS_PER_PRINCIPAL: '2', E3D_MCP_RUNS_GLOBAL: '3' }, exOpts: { open: false }, concurrent: 1 });
  const a1 = await t.runs.start({ principal: 'acct_a', plan: plan(), worst });
  const a2 = await t.runs.start({ principal: 'acct_a', plan: plan(), worst });
  assert.ok(a1.ok && a2.ok); assert.equal(a2.status, 'queued', 'queued runs hold a slot too');
  const dirs0 = runDirs(t.dir).length; const res0 = t.svc.reserves.length;
  const a3 = await t.runs.start({ principal: 'acct_a', plan: plan(), worst });
  assert.equal(a3.ok, false); assert.equal(a3.kind, 'busy');
  assert.equal(t.svc.reserves.length, res0, 'a refused slot reserves nothing'); assert.equal(runDirs(t.dir).length, dirs0, 'and leaves no run');
  const b1 = await t.runs.start({ principal: 'acct_b', plan: plan(), worst }); assert.ok(b1.ok);
  const c1 = await t.runs.start({ principal: 'acct_c', plan: plan(), worst }); assert.equal(c1.kind, 'busy', 'the global bound');
  t.ex.releaseAll();
  for (const r of [a1, a2]) assert.ok(await settled(t.runs, r.debate_id));
  assert.ok(await settled(t.runs, b1.debate_id, 'acct_b'));
  assert.ok(await idle(t.runs));
  const a4 = await t.runs.start({ principal: 'acct_a', plan: plan(), worst }); assert.ok(a4.ok, 'slots are free again');
  assert.ok(await settled(t.runs, a4.debate_id));
  // a reserve refusal: no run, nothing held, the slot back
  t.svc.refuse = 'insufficient_credits';
  const dirs1 = runDirs(t.dir).length;
  const rf = await t.runs.start({ principal: 'acct_a', plan: plan(), worst });
  assert.equal(rf.ok, false); assert.equal(rf.kind, 'begin'); assert.equal(rf.rsv.code, 'insufficient_credits');
  assert.equal(runDirs(t.dir).length, dirs1, 'a refused reserve leaves no visible run'); assert.equal(t.runs.stats().slots_in_use, 0, 'and releases the slot');
  t.svc.refuse = null;
  // a start that fails before the models (metering.start) releases the hold and the slot
  const sf = setup('slots-startfail', { exOpts: { startFails: true } });
  const r = await sf.runs.start({ principal: 'acct_a', plan: plan(), worst });
  assert.ok(await settled(sf.runs, r.debate_id));
  assert.equal((await sf.runs.status('acct_a', r.debate_id)).status.status, 'failed'); assert.ok(await idle(sf.runs));
  assert.equal(sf.svc.releases.length, 1); assert.equal(sf.svc.finalizes.length, 0);
  // an invalid question is refused before a slot or a reserve
  const inv = await sf.runs.start({ principal: 'acct_a', plan: plan('bad\u0001question'), worst });
  assert.equal(inv.kind, 'invalid'); assert.equal(sf.svc.reserves.length, 1);
  ok('slots: per-principal and global bounds count queued runs; a refused slot or reserve leaves no run and holds nothing; released on every path');
}

// ---- caps refuse before reserve; eviction never removes a run with a pending finalize ----
{
  const t = setup('caps', { env: { E3D_MCP_RUNS_KEEP_PER_PRINCIPAL: '2' } });
  const r1 = await t.runs.start({ principal: 'acct_a', plan: plan(), worst }); assert.ok(await settled(t.runs, r1.debate_id));
  const r2 = await t.runs.start({ principal: 'acct_a', plan: plan(), worst }); assert.ok(await settled(t.runs, r2.debate_id));
  // r1's finalize is still in the outbox: it must survive; r2 (newer, settled) is evicted to make room instead
  const pend = join(t.dir, 'auth-outbox', 'pending'); mkdirSync(pend, { recursive: true });
  const rid1 = t.svc.finalizes.find((f) => f.debate_id === r1.debate_id).reservation_id;
  writeFileSync(join(pend, `finalize.reservation_id.${rid1}.json`), '{}');
  const r3 = await t.runs.start({ principal: "acct_a", plan: plan(), worst }); assert.ok(r3.ok, JSON.stringify(r3)); assert.ok(await settled(t.runs, r3.debate_id));
  assert.equal((await t.runs.status('acct_a', r1.debate_id)).status?.status, 'done', 'the run with a pending finalize was kept');
  assert.ok(!runDirs(t.dir).some((p) => p.endsWith(r2.debate_id)), 'the oldest evictable run went');
  // now r1 (pending) and r3 (pending via a claimed record) cannot go: refused before any reserve
  const rid3 = t.svc.finalizes.find((f) => f.debate_id === r3.debate_id).reservation_id;
  mkdirSync(join(t.dir, 'auth-outbox', 'claimed'), { recursive: true });
  writeFileSync(join(t.dir, 'auth-outbox', 'claimed', `123-finalize.reservation_id.${rid3}.json`), '{}');
  const res0 = t.svc.reserves.length;
  const r4 = await t.runs.start({ principal: 'acct_a', plan: plan(), worst });
  assert.equal(r4.kind, 'caps'); assert.equal(t.svc.reserves.length, res0, 'caps refuse before reserve');
  // other principals are unaffected
  assert.ok((await t.runs.start({ principal: 'acct_b', plan: plan(), worst })).ok);
  // the byte cap refuses new starts before reserve
  const b = setup('caps-bytes', { env: { E3D_MCP_RUNS_MAX_BYTES: '100' } });
  const b1 = await b.runs.start({ principal: 'acct_a', plan: plan(), worst }); assert.ok(b1.ok); assert.ok(await settled(b.runs, b1.debate_id));
  const bres = b.svc.reserves.length;
  const b2 = await b.runs.start({ principal: 'acct_z', plan: plan(), worst });
  assert.equal(b2.kind, 'caps'); assert.equal(b.svc.reserves.length, bres); assert.equal(runDirs(b.dir).length, 1);
  // the outbox's bound refuses too
  const o = setup('caps-outbox', { outbox: { canAccept: () => false } });
  const o1 = await o.runs.start({ principal: 'acct_a', plan: plan(), worst });
  assert.equal(o1.kind, 'caps'); assert.equal(o.svc.reserves.length, 0);
  ok('kept-runs cap evicts the oldest settled run, never one with a pending finalize; caps, byte bound and outbox bound refuse before reserve');
}

// ---- TTL: pending finalize protects; after eviction the result comes from the service ----
{
  let clock = Date.now();
  const t = setup('ttl', { env: { E3D_MCP_RUNS_TTL_SEC: '60' }, now: () => clock });
  const r = await t.runs.start({ principal: 'acct_a', plan: plan(), worst }); assert.ok(await settled(t.runs, r.debate_id));
  // the metering intent still journaled = finalize pending
  const rid = t.svc.finalizes[0].reservation_id;
  const pend = join(t.dir, 'auth-outbox', 'dead'); mkdirSync(pend, { recursive: true });
  writeFileSync(join(pend, `finalize.reservation_id.${rid}.json`), '{}');
  clock += 120000;
  assert.equal(await t.runs.sweep(), 0, 'a run with a pending (even dead-lettered) finalize is never evicted');
  assert.equal((await t.runs.result('acct_a', r.debate_id)).debate.source, 'local');
  rmSync(join(pend, `finalize.reservation_id.${rid}.json`));
  assert.equal(await t.runs.sweep(), 1); assert.equal(runDirs(t.dir).length, 0);
  const viaSvc = await t.runs.result('acct_a', r.debate_id, true);
  assert.equal(viaSvc.ok, true); assert.equal(viaSvc.debate.source, 'service'); assert.deepEqual(viaSvc.debate.result, RESULT); assert.equal(viaSvc.debate.transcript, TRANSCRIPT);
  const noT = await t.runs.result('acct_a', r.debate_id); assert.ok(!('transcript' in noT.debate));
  assert.deepEqual(await t.runs.result('acct_b', r.debate_id), { ok: false, code: 'not_found' }, 'the service fallback checks the owner');
  assert.equal((await t.runs.status('acct_a', r.debate_id)).status.status, 'done');
  ok('TTL eviction skips a pending finalize; after eviction the owner still gets the result (and the transcript on request) from the service');
}

// ---- status/result rate limit per principal ----
{
  const t = setup('rate', { env: { E3D_MCP_RUNS_POLL_PER_MIN: '3' } });
  const id = 'dbt_111111111111111111111111';
  for (let i = 0; i < 3; i++) assert.equal((await t.runs.status('acct_a', id)).code, 'not_found');
  const lim = await t.runs.result('acct_a', id);
  assert.equal(lim.code, 'rate_limited'); assert.ok(lim.retry_after >= 1);
  assert.equal((await t.runs.status('acct_b', id)).code, 'not_found', 'per principal');
  ok('status and result are rate-limited per principal');
}

// ---- stored:false (deleted while running): nothing served, nothing charged ----
{
  const svc = fakeService(); svc.finalizeMode = 'not_stored';
  const t = setup('deleted', { svc });
  const r = await t.runs.start({ principal: 'acct_a', plan: plan(), worst });
  await until(async () => t.runs.stats().finished === 1);
  assert.deepEqual(await t.runs.result('acct_a', r.debate_id), { ok: false, code: 'not_found' });
  const st = JSON.parse(readFileSync(join(runDirs(t.dir)[0], 'state.json'), 'utf8'));
  assert.equal(st.result, null); assert.equal(st.question, null); assert.ok(!existsSync(join(runDirs(t.dir)[0], 'transcript.md')));
  ok('a debate the service did not store (stored:false) is not served locally and keeps no content');
}

// ---- a finalize that was QUEUED and is later answered stored:false must drop the local copy ----
{
  const svc = fakeService(); svc.finalizeMode = 'queue';
  const t = setup('purge-late', { svc });
  const r = await t.runs.start({ principal: 'acct_a', plan: plan(), worst });
  await until(async () => t.runs.stats().finished === 1);
  const before = await t.runs.result('acct_a', r.debate_id);
  assert.equal(before.ok, true, 'while the finalize is queued the local result is served');
  assert.equal(await t.runs.purgeUnstored(r.debate_id), true);
  assert.deepEqual(await t.runs.result('acct_a', r.debate_id), { ok: false, code: 'not_found' }, 'once the service says it kept nothing, nothing is served');
  const st = JSON.parse(readFileSync(join(runDirs(t.dir)[0], 'state.json'), 'utf8'));
  assert.equal(st.result, null); assert.equal(st.question, null); assert.ok(!existsSync(join(runDirs(t.dir)[0], 'transcript.md')));
  assert.equal(await t.runs.purgeUnstored(r.debate_id), false, 'a second purge is a no-op');
  assert.equal(await t.runs.purgeUnstored('dbt_ffffffffffffffffffffffff'), false, 'an unknown id is a no-op');
  ok('a queued finalize later answered stored:false purges the local result, question and transcript');
}

// ---- restart: started runs end as errors, queued runs resume, old queued runs expire with zero charge; slots rebuilt ----
{
  const svc = fakeService();
  const a = setup('restart', { svc, exOpts: { hang: true }, concurrent: 1 });
  const s1 = await a.runs.start({ principal: 'acct_a', plan: plan(), worst }); // runs (and hangs: the "crash")
  const s2 = await a.runs.start({ principal: 'acct_a', plan: plan(), worst }); // queued behind it
  const s3 = await a.runs.start({ principal: 'acct_b', plan: plan(), worst }); // queued
  await until(async () => (await a.runs.status('acct_a', s1.debate_id)).status?.status === 'running');
  assert.equal(s2.status, 'queued'); assert.equal(s3.status, 'queued');
  // a tentative start that crashed before its reserve finished
  const tentative = join(a.dir, 'runs', principalDir('acct_c'), 'dbt_aaaaaaaaaaaaaaaaaaaaaaaa');
  mkdirSync(tentative, { recursive: true, mode: 0o700 });
  writeFileSync(join(tentative, 'state.json'), JSON.stringify({ v: 1, debate_id: 'dbt_aaaaaaaaaaaaaaaaaaaaaaaa', principal: 'acct_c', status: 'reserving', created_at: new Date().toISOString(), question: Q, args: {}, pid: process.pid }), { mode: 0o600 });
  const fin0 = svc.finalizes.length;
  // "restart": a new metering and run store over the same state directory; the s3 run is older than the run timeout
  const b = setup('restart', { svc, env: {}, concurrent: 2 });
  const s3state = join(b.dir, 'runs', principalDir('acct_b'), s3.debate_id, 'state.json');
  const st3 = JSON.parse(readFileSync(s3state, 'utf8')); st3.created_at = new Date(Date.now() - 2 * 3600e3).toISOString(); writeFileSync(s3state, JSON.stringify(st3), { mode: 0o600 });
  await b.runs.load();
  const { recovered } = await b.metering.recover({ claim: b.runs.claimIntent });
  assert.equal(recovered, 1, 'metering reconciled only the started run (the queued ones are the store\'s)');
  const rec = await b.runs.recover();
  assert.deepEqual([rec.resumed, rec.expired, rec.errors, rec.removed], [1, 1, 1, 1]);
  const f1 = svc.finalizes.slice(fin0).find((f) => f.debate_id === s1.debate_id);
  assert.equal(f1.outcome, 'error'); assert.equal(f1.result, null, 'an interrupted started run is finalized as an error without a result');
  const s1v = await b.runs.status('acct_a', s1.debate_id); assert.deepEqual([s1v.status.status, s1v.status.outcome], ['failed', 'error']);
  const f3 = svc.finalizes.slice(fin0).find((f) => f.debate_id === s3.debate_id);
  assert.deepEqual([f3.outcome, f3.actual.calls, f3.result], ['error', 0, null], 'an expired queued run is finalized with zero calls');
  assert.equal(svc.stored.get(s3.debate_id).charged, 0, 'and charged nothing');
  assert.ok(await settled(b.runs, s2.debate_id));
  const r2 = await b.runs.result('acct_a', s2.debate_id); assert.deepEqual(r2.debate.result, RESULT, 'the queued run resumed and finished');
  assert.equal(svc.reserves.length, 3, 'a resumed run is never reserved again');
  assert.ok(!existsSync(tentative), 'the tentative start is removed');
  assert.equal(readdirSync(join(b.dir, 'metering-intents')).filter((f) => f.endsWith('.json')).length, 0, 'every intent is reconciled');
  assert.ok(await idle(b.runs), 'slots rebuilt on restart and released again');
  // the slots after restart allow the full per-principal count again
  const again = await Promise.all([1, 2, 3].map(() => b.runs.start({ principal: 'acct_a', plan: plan(), worst })));
  assert.ok(again.every((x) => x.ok));
  for (const x of again) assert.ok(await settled(b.runs, x.debate_id));
  ok('restart: a started run is finalized as error, a queued run resumes without a new reserve, an old queued run expires at zero charge; slots rebuilt');
}

// ---- a reused process id must not leave a recovered run stuck forever ----
{
  const svc = fakeService();
  const a = setup('pidreuse', { svc, exOpts: { hang: true }, concurrent: 1 });
  const s1 = await a.runs.start({ principal: 'acct_a', plan: plan(), worst });
  await until(async () => (await a.runs.status('acct_a', s1.debate_id)).status?.status === 'running');
  const stateFile = join(a.dir, 'runs', principalDir('acct_a'), s1.debate_id, 'state.json');
  const setState = (patch) => { const st = JSON.parse(readFileSync(stateFile, 'utf8')); writeFileSync(stateFile, JSON.stringify({ ...st, ...patch }), { mode: 0o600 }); };
  // the run's recorded process is "another live server" (the parent of this test: alive, but not the server that ran it)
  setState({ pid: process.ppid });
  const young = setup('pidreuse', { svc, env: {}, concurrent: 1 });
  await young.runs.load(); await young.runs.recover();
  assert.equal((await young.runs.status('acct_a', s1.debate_id)).status.status, 'running', 'a young run of a live process is left alone');
  setState({ created_at: new Date(Date.now() - 7 * 3600e3).toISOString() }); // older than the 6 hour bound: the pid was reused
  const old = setup('pidreuse', { svc, env: {}, concurrent: 1 });
  await old.runs.load(); await old.runs.recover();
  const v = await old.runs.status('acct_a', s1.debate_id);
  assert.deepEqual([v.status.status, v.status.outcome], ['failed', 'error'], 'an old run whose pid looks alive is recovered, not stuck');
  ok('recovery: a reused pid does not strand an old run (same stale-age bound as the metering intents)');
}

// ---- no debate content in any log line ----
assert.ok(logs.length > 10);
for (const l of logs) assert.doesNotMatch(l, /QCONTENT|ACONTENT|TCONTENT/, l);
ok(`no question, answer or transcript text in ${logs.length} log lines`);

console.log(`runs unit tests: ${n} passed`);
process.exit(0);
