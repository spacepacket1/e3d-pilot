// Unit tests for the internal run listener (lib/mcp/run-server.js) over real HTTP on loopback: the real run store,
// metering and local usage, a fake billing service (authorize-run, finalize, no reserve allowed), and a fake executor.
// Usage: node tests/fixtures/runserver-test.mjs <state root>
import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import http from 'node:http';
import { createMetering } from '../../lib/mcp/metering.js';
import { createUsage } from '../../lib/mcp/usage.js';
import { createRuns, validateRunsConfig, principalDir } from '../../lib/mcp/runs.js';
import { startRunServer, validateRunServerConfig, validateRunRequest, RUN_TOKEN_MIN } from '../../lib/mcp/run-server.js';

const ROOT = process.argv[2];
if (!ROOT) { console.error('usage: runserver-test.mjs <state root>'); process.exit(2); }
let n = 0;
const ok = (m) => { n++; console.log(`ok - run-server: ${m}`); };
const logs = [];
const log = (...a) => logs.push(a.join(' '));
const SVC_TOKEN = `svc-MARKER-${'x'.repeat(40)}`;
const Q = 'QCONTENT-rs: a JSON file or SQLite?';
const RESULT = { final_answer: 'ACONTENT-rs use a JSON file', consensus: 'split', dissent: 'Codex prefers SQLite.', positions: [{ provider: 'claude', model: 'unspecified', position: 'JSON.' }, { provider: 'codex', model: 'unspecified', position: 'SQLite.' }] };
const TRANSCRIPT = '# Debate\n\n## Round 1 -- claude\n\nTCONTENT-rs JSON.\n';
const worst = { calls: 3, tokens: 3000 };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms = 3000) { const end = Date.now() + ms; while (Date.now() < end) { if (await fn()) return true; await sleep(10); } return false; }
const hex = (k) => k.toString(16).padStart(24, '0');
let seq = 0;
const ids = () => { seq++; return { reservation_id: `rsv_web_${seq}`, debate_id: `dbt_${hex(seq)}` }; };

// The billing service: reservations are made by the web page (pre-seeded here); authorize-run binds a pair immutably.
function fakeService() {
  const s = { features: ['finalize', 'fetch', 'authorize-run'], owners: new Map(), bindings: new Map(), authorizes: [], finalizes: [], releases: [], reserves: [], effects: new Map(), authFails: null };
  s.reserve = (reservation_id, principal) => s.owners.set(reservation_id, principal);
  s.ext = {
    hasFeature: (f) => s.features.includes(f),
    async reserve(a) { s.reserves.push(a); throw new Error('a web run must never reserve again'); },
    async releaseDurable(p) { s.releases.push(p); return { ok: true }; },
    async settleDurable() { throw new Error('a settle must never be sent with finalize'); },
    async authorizeRun({ reservation_id, debate_id }) {
      s.authorizes.push({ reservation_id, debate_id });
      if (s.authFails) { const e = new Error('down'); e.kind = 'unavailable'; throw e; }
      const owner = s.owners.get(reservation_id);
      if (!owner) return { ok: false, code: 'not_found' };
      const b = s.bindings.get(reservation_id);
      if (b) return b === debate_id ? { ok: true, principal: owner, price_credits: 9, status: 'bound' } : { ok: false, code: 'conflict' };
      if ([...s.bindings.values()].includes(debate_id)) return { ok: false, code: 'conflict' };
      s.bindings.set(reservation_id, debate_id);
      return { ok: true, principal: owner, price_credits: 9, status: 'reserved' };
    },
    async finalizeDurable(p) {
      s.finalizes.push(p);
      const key = JSON.stringify(p);
      const prior = s.effects.get(p.reservation_id);
      if (prior && prior !== key) return { ok: true, delivered: false, dead: true };
      s.effects.set(p.reservation_id, key);
      const charged = p.outcome === 'ok' && p.actual.calls > 0 ? 9 : 0;
      return { ok: true, delivered: true, stored: true, charged };
    },
    async fetchDebate() { return { ok: false, code: 'not_found' }; },
  };
  return s;
}

// Debates wait on a gate unless open; a cancelled one (signal) ends as an error, like the real executor.
function fakeExecutor(ref) {
  const ex = { open: true, ran: [], waiting: new Map() };
  ex.execute = async ({ plan, handle, onStarted, signal }) => {
    ex.ran.push({ id: handle.debate_id, plan });
    await ref.m.start(handle); await onStarted();
    if (!ex.open) await new Promise((resolve) => { ex.waiting.set(handle.debate_id, resolve); signal?.addEventListener('abort', resolve, { once: true }); });
    if (signal?.aborted) {
      const c = await ref.m.commit(handle, { calls: 1, inTokens: 100, outTokens: 0 }, { outcome: 'error', duration_ms: 5, models: [], transcript: null, finished_at: Date.now() });
      return { outcome: 'error', result: null, transcript: null, usage: { calls: 1, est_input_tokens: 100, est_output_tokens: 0 }, billing: c.billing };
    }
    const c = await ref.m.commit(handle, { calls: 3, inTokens: 300, outTokens: 100 }, { outcome: 'ok', duration_ms: 5, models: [], result: RESULT, transcript: TRANSCRIPT, finished_at: Date.now() });
    return { outcome: 'ok', result: RESULT, transcript: TRANSCRIPT, usage: { calls: 3, est_input_tokens: 300, est_output_tokens: 100 }, billing: c.billing };
  };
  ex.releaseAll = () => { ex.open = true; for (const r of ex.waiting.values()) r(); ex.waiting.clear(); };
  return ex;
}

// `down`: providers the planner treats as unavailable (a vendor outage), and how often a request was planned.
const down = new Set();
const planned = { n: 0 };
const plan = (f) => (planned.n++, f.question.includes('FORBIDDEN') || (f.providers ?? []).some((p) => down.has(p)) ? { error: 'error: panel_unavailable: your panel needs at least two available vendors from different companies' }
  : { plan: { question: f.question.trim(), mode: 'quick', providers: f.providers ?? ['claude', 'codex'], rounds: Math.min(f.rounds ?? 1, 2), maxWords: Math.min(f.max_words ?? 80, 300), synthesizer: 'claude' }, worst });
const servers = [];
let active = 0;
async function setup(name, { env = {}, svc = fakeService(), concurrent = 2, failsPerMin = 20, executor = null } = {}) {
  const dir = join(ROOT, name);
  const usage = createUsage({ env: { E3D_MCP_STATE_DIR: dir } });
  const ref = { m: createMetering({ localUsage: usage, external: svc.ext, log, dir, env: {} }) };
  const ex = executor ?? fakeExecutor(ref);
  const config = validateRunsConfig(env).config;
  active = 0;
  const runs = createRuns({ dir, config, metering: ref.m, external: svc.ext, log, execute: ex.execute,
    acquireExec: () => { if (active >= concurrent) return false; active++; return true; }, releaseExec: () => { active--; } });
  await runs.load(); await ref.m.recover({ claim: runs.claimIntent }); await runs.recover();
  const server = await startRunServer({ port: 0, token: SVC_TOKEN, runs, external: svc.ext, plan, log, failsPerMin });
  servers.push(server);
  const base = `http://127.0.0.1:${server.port}`;
  const req = async (method, path, { body, token = SVC_TOKEN, runToken, headers = {} } = {}) => {
    const h = { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(runToken !== undefined ? { 'x-e3d-run-token': runToken } : {}), ...(body !== undefined ? { 'content-type': 'application/json' } : {}), ...headers };
    const r = await fetch(`${base}${path}`, { method, headers: h, body: body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body) });
    return { status: r.status, body: await r.json().catch(() => null) };
  };
  const post = (b, o) => req('POST', '/internal/runs', { body: b, ...o });
  const get = (id, runToken, o) => req('GET', `/internal/runs/${id}`, { runToken, ...o });
  const del = (id, runToken, o) => req('DELETE', `/internal/runs/${id}`, { runToken, ...o });
  const done = (id, st = ['done', 'failed']) => until(async () => st.includes(JSON.parse(readFileSync(join(dir, 'runs', principalDir(svc.owners.get(svc.authorizes.find((a) => a.debate_id === id)?.reservation_id) ?? '-'), id, 'state.json'), 'utf8')).status) && !runs._internal.slots.held.has(id));
  return { dir, svc, ex, runs, metering: ref.m, server, base, req, post, get, del, done, usage };
}
const intents = (dir) => (existsSync(join(dir, 'metering-intents')) ? readdirSync(join(dir, 'metering-intents')).filter((f) => f.endsWith('.json')) : []);
const runCount = (dir) => (existsSync(join(dir, 'runs')) ? readdirSync(join(dir, 'runs')).flatMap((g) => readdirSync(join(dir, 'runs', g))).filter((x) => x.startsWith('dbt_')).length : 0);

// ---- configuration: enabled by the port or the token; short tokens and a missing hook refuse to start ----
{
  assert.equal(validateRunServerConfig({}).enabled, false);
  const good = validateRunServerConfig({ E3D_MCP_AUTH_URL: 'https://x', E3D_MCP_RUN_PORT: '9000', E3D_MCP_RUN_TOKEN: 'k'.repeat(RUN_TOKEN_MIN) });
  assert.equal(good.ok, true); assert.equal(good.config.port, 9000); assert.equal(good.config.failsPerMin, 20);
  const short = validateRunServerConfig({ E3D_MCP_AUTH_URL: 'https://x', E3D_MCP_RUN_PORT: '9000', E3D_MCP_RUN_TOKEN: 'k'.repeat(RUN_TOKEN_MIN - 1) });
  assert.equal(short.ok, false); assert.match(short.errors.join(), /E3D_MCP_RUN_TOKEN/); assert.doesNotMatch(short.errors.join(), /kkkk/);
  assert.equal(validateRunServerConfig({ E3D_MCP_AUTH_URL: 'https://x', E3D_MCP_RUN_PORT: '9000', E3D_MCP_RUN_TOKEN: `${'k'.repeat(20)} ${'k'.repeat(20)}` }).ok, false, 'spaces refused');
  const noHook = validateRunServerConfig({ E3D_MCP_RUN_PORT: '9000', E3D_MCP_RUN_TOKEN: 'k'.repeat(40) });
  assert.equal(noHook.ok, false); assert.match(noHook.errors.join(), /E3D_MCP_AUTH_URL/);
  assert.equal(validateRunServerConfig({ E3D_MCP_AUTH_URL: 'https://x', E3D_MCP_RUN_TOKEN: 'k'.repeat(40) }).ok, false, 'a token without a port');
  assert.equal(validateRunServerConfig({ E3D_MCP_AUTH_URL: 'https://x', E3D_MCP_RUN_PORT: '70000', E3D_MCP_RUN_TOKEN: 'k'.repeat(40) }).ok, false);
  await assert.rejects(startRunServer({ port: 0, token: 'short', runs: {}, external: {}, plan }), /at least 32/);
  ok('configuration: needs the hook, a port and a token of 32+ characters; short tokens refuse to start');
}

// ---- strict request validation ----
{
  const b = { reservation_id: 'rsv_1', debate_id: `dbt_${hex(1)}`, question: 'Q?' };
  assert.ok(validateRunRequest(b).key);
  assert.equal(validateRunRequest(b).key, validateRunRequest({ question: 'Q?', debate_id: b.debate_id, reservation_id: 'rsv_1' }).key, 'key order does not matter');
  assert.notEqual(validateRunRequest(b).key, validateRunRequest({ ...b, rounds: 1 }).key);
  for (const bad of [null, [], 'x', { ...b, principal: 'acct_evil' }, { ...b, reservation_id: 'a b' }, { ...b, debate_id: 'dbt_XYZ' }, { ...b, question: '' }, { ...b, question: '   ' },
    { ...b, question: 'a\u0001b' }, { ...b, question: 'x'.repeat(8001) }, { ...b, providers: [] }, { ...b, providers: ['Bad Name'] }, { ...b, rounds: 1.5 }, { ...b, max_words: -1 }]) {
    assert.ok(validateRunRequest(bad).error, JSON.stringify(bad)?.slice(0, 60));
  }
  ok('strict validation: unknown fields (a principal in the body included), malformed ids, bad questions and bad options are invalid');
}

// ---- loopback only; service token checks; failures are rate-limited ----
{
  const t = await setup('auth', { failsPerMin: 5 });
  assert.equal(t.server.host, '127.0.0.1');
  for (const token of [null, 'wrong', `${SVC_TOKEN}x`, SVC_TOKEN.slice(0, -1)]) {
    const r = await t.post({ ...ids(), question: Q }, { token });
    assert.equal(r.status, 401, String(token)); assert.equal(r.body.code, 'unauthorized');
  }
  assert.equal(t.svc.authorizes.length, 0, 'nothing reaches the service without the service token');
  assert.equal((await t.post({ ...ids(), question: Q }, { headers: { origin: 'http://evil.example' } })).status, 403, 'a browser origin is refused');
  // fetch() cannot set Host, so this one goes through node:http (a DNS-rebinding page would send its own host name)
  const hostStatus = await new Promise((resolve, reject) => {
    const rq = http.request({ host: '127.0.0.1', port: t.server.port, path: '/internal/runs', method: 'POST', headers: { host: 'evil.example', authorization: `Bearer ${SVC_TOKEN}`, 'content-type': 'application/json' } }, (res) => { res.resume(); resolve(res.statusCode); });
    rq.on('error', reject); rq.end(JSON.stringify({ ...ids(), question: Q }));
  });
  assert.equal(hostStatus, 403, 'a foreign Host is refused');
  assert.equal((await t.get(`dbt_${hex(999)}`, 'x')).status, 401, 'an unknown run looks like a wrong run token');
  // the fifth failure in a minute: every request is refused, the right token included, without being checked
  const r = await t.post({ ...ids(), question: Q });
  assert.equal(r.status, 429); assert.equal(r.body.code, 'rate_limited'); assert.equal(r.body.accepted, false);
  assert.equal(t.svc.authorizes.length, 0);
  ok('loopback only; missing or wrong service tokens get 401 before any service call; failed authentication is rate-limited');
}

// ---- features: a new run needs finalize, fetch and authorize-run ----
{
  const t = await setup('features');
  for (const f of [[], ['finalize', 'fetch'], ['finalize', 'authorize-run'], ['fetch', 'authorize-run']]) {
    t.svc.features = f;
    const r = await t.post({ ...ids(), question: Q });
    assert.equal(r.status, 503, f.join()); assert.equal(r.body.code, 'not_ready'); assert.equal(r.body.accepted, false);
  }
  assert.equal(t.svc.authorizes.length, 0); assert.equal(runCount(t.dir), 0);
  ok('the listener accepts runs only while finalize, fetch and authorize-run are all advertised');
}

// ---- the accepted path: ownership from authorize-run, metered without a reserve, finalized once with source web ----
let mainT;
{
  const t = await setup('accept'); mainT = t;
  const id = ids(); t.svc.reserve(id.reservation_id, 'acct_web');
  const r = await t.post({ ...id, question: Q, rounds: 3, providers: ['claude', 'codex'] });
  assert.equal(r.status, 202); assert.equal(r.body.accepted, true); assert.equal(r.body.existing, false); assert.equal(r.body.debate_id, id.debate_id);
  assert.match(r.body.run_token, /^[A-Za-z0-9_-]{43}$/); assert.ok(['queued', 'running'].includes(r.body.status));
  assert.ok(await t.done(id.debate_id));
  assert.equal(t.svc.reserves.length, 0, 'never reserved again');
  assert.equal(t.svc.finalizes.length, 1);
  const f = t.svc.finalizes[0];
  assert.deepEqual([f.reservation_id, f.debate_id, f.source, f.outcome, f.rounds], [id.reservation_id, id.debate_id, 'web', 'ok', 2], 'customer maxima clamp web runs too');
  assert.deepEqual(f.result, RESULT);
  // stored under the principal authorize-run named
  assert.ok(existsSync(join(t.dir, 'runs', principalDir('acct_web'), id.debate_id, 'state.json')));
  const st = JSON.parse(readFileSync(join(t.dir, 'runs', principalDir('acct_web'), id.debate_id, 'state.json'), 'utf8'));
  assert.equal(st.principal, 'acct_web'); assert.equal(st.source, 'web'); assert.equal(st.price_credits, 9);
  // GET needs the run token
  const g = await t.get(id.debate_id, r.body.run_token);
  assert.equal(g.status, 200); assert.equal(g.body.run.status, 'done'); assert.deepEqual(g.body.run.result, RESULT); assert.equal(g.body.run.credits_charged, 9);
  assert.ok(!('transcript' in g.body.run) && !('question' in g.body.run) && !('run_token' in g.body.run));
  for (const rt of [undefined, '', 'x', `${r.body.run_token}x`]) assert.equal((await t.get(id.debate_id, rt)).status, 401, String(rt));
  assert.equal((await t.get(id.debate_id, r.body.run_token, { token: 'wrong' })).status, 401, 'the run token alone is not enough');
  // the customer of that account sees it through the connector tools too (same store, same owner)
  assert.equal((await t.runs.status('acct_web', id.debate_id)).status.status, 'done');
  assert.equal((await t.runs.status('acct_other', id.debate_id)).code, 'not_found');
  assert.equal(intents(t.dir).length, 0);
  ok('accepted run: owner from authorize-run, no new reserve, one finalize with source web, GET only with the service and the run token');

  // a duplicate POST with the same fields returns the same run and run token, and runs nothing again
  const d = await t.post({ question: Q, providers: ['claude', 'codex'], rounds: 3, ...id });
  assert.equal(d.status, 200); assert.equal(d.body.existing, true); assert.equal(d.body.run_token, r.body.run_token); assert.equal(d.body.status, 'done');
  // changed fields, or either id with another counterpart, are conflicts
  assert.equal((await t.post({ ...id, question: `${Q} changed`, providers: ['claude', 'codex'], rounds: 3 })).body.code, 'conflict');
  assert.equal((await t.post({ ...id, question: Q })).status, 409, 'an omitted option is a different request');
  const other = ids(); t.svc.reserve(other.reservation_id, 'acct_web');
  assert.equal((await t.post({ reservation_id: id.reservation_id, debate_id: other.debate_id, question: Q })).status, 409, 'the reservation is bound to another debate');
  assert.equal((await t.post({ reservation_id: other.reservation_id, debate_id: id.debate_id, question: Q })).status, 409, 'the debate is bound to another reservation');
  assert.equal(t.ex.ran.length, 1); assert.equal(t.svc.finalizes.length, 1);
  ok('idempotent create: the same fields return the same run and token; changed fields or bindings are conflicts');
}

// ---- concurrent identical requests: one run, one token ----
{
  const t = mainT;
  const id = ids(); t.svc.reserve(id.reservation_id, 'acct_web');
  const ran0 = t.ex.ran.length;
  const rs = await Promise.all([1, 2, 3].map(() => t.post({ ...id, question: Q })));
  assert.deepEqual(rs.map((x) => x.status).sort(), [200, 200, 202]);
  assert.equal(new Set(rs.map((x) => x.body.run_token)).size, 1);
  assert.ok(await t.done(id.debate_id));
  assert.equal(t.ex.ran.length, ran0 + 1);
  ok('concurrent identical creates produce one run with one run token');
}

// ---- refused authorization: no model work, nothing local; the service is the only judge of ownership ----
{
  const t = await setup('refused');
  const unknown = ids();
  const r = await t.post({ ...unknown, question: Q });
  assert.equal(r.status, 403); assert.equal(r.body.code, 'not_authorized'); assert.equal(r.body.reason, 'not_found'); assert.equal(r.body.accepted, false);
  const bound = ids(); t.svc.reserve(bound.reservation_id, 'acct_web'); t.svc.bindings.set(bound.reservation_id, `dbt_${hex(77777)}`);
  assert.equal((await t.post({ ...bound, question: Q })).status, 409);
  t.svc.authFails = true;
  const down = ids(); t.svc.reserve(down.reservation_id, 'acct_web');
  const u = await t.post({ ...down, question: Q });
  assert.equal(u.status, 503); assert.equal(u.body.code, 'unavailable'); assert.equal(u.body.retry, true);
  t.svc.authFails = false;
  const inv = await t.post({ ...ids(), question: 'FORBIDDEN providers' });
  assert.equal(inv.status, 400); assert.equal(inv.body.code, 'invalid');
  assert.equal((await t.post('{"not json', {})).status, 400);
  assert.equal(t.ex.ran.length, 0, 'no model work'); assert.equal(runCount(t.dir), 0); assert.equal(intents(t.dir).length, 0);
  assert.equal(t.svc.finalizes.length + t.svc.releases.length + t.svc.reserves.length, 0);
  // after the outage the same request is accepted (nothing was left behind)
  const ok2 = await t.post({ ...down, question: Q });
  assert.equal(ok2.status, 202);
  assert.ok(await t.done(down.debate_id));
  ok('refused or failed authorization starts no model work and leaves nothing; invalid plans are refused; a retry after an outage is accepted');
}

// ---- cancel: a running run finalizes as error without a result; a queued one with zero calls ----
{
  const t = await setup('cancel', { concurrent: 1 });
  t.ex.open = false;
  const a = ids(); const b = ids(); t.svc.reserve(a.reservation_id, 'acct_web'); t.svc.reserve(b.reservation_id, 'acct_web');
  const ra = await t.post({ ...a, question: Q }); const rb = await t.post({ ...b, question: Q });
  assert.equal(ra.status, 202); assert.equal(rb.status, 202); assert.equal(rb.body.status, 'queued');
  await until(() => t.ex.waiting.has(a.debate_id));
  assert.equal((await t.get(a.debate_id, ra.body.run_token)).body.run.status, 'running');
  assert.equal((await t.del(a.debate_id, rb.body.run_token)).status, 401, 'another run\'s token cannot cancel it');
  assert.equal((await t.del(b.debate_id, undefined)).status, 401);
  // cancel the queued one: zero calls, never started
  const cb = await t.del(b.debate_id, rb.body.run_token);
  assert.equal(cb.status, 200); assert.deepEqual([cb.body.run.status, cb.body.run.outcome, cb.body.run.cancelled], ['failed', 'error', true]); assert.ok(!('result' in cb.body.run));
  const fb = t.svc.finalizes.find((x) => x.debate_id === b.debate_id);
  assert.deepEqual([fb.outcome, fb.result, fb.actual.calls, fb.source], ['error', null, 0, 'web']);
  // cancel the running one
  const ca = await t.del(a.debate_id, ra.body.run_token);
  assert.equal(ca.status, 200); assert.deepEqual([ca.body.run.status, ca.body.run.outcome, ca.body.run.cancelled], ['failed', 'error', true]);
  const fa = t.svc.finalizes.filter((x) => x.debate_id === a.debate_id);
  assert.equal(fa.length, 1); assert.equal(fa[0].outcome, 'error'); assert.equal(fa[0].result, null);
  assert.equal(t.ex.ran.filter((x) => x.id === b.debate_id).length, 0, 'the queued run never ran');
  // cancelling again is a no-op that returns the terminal run
  const again = await t.del(a.debate_id, ra.body.run_token);
  assert.equal(again.status, 200); assert.equal(t.svc.finalizes.filter((x) => x.debate_id === a.debate_id).length, 1);
  assert.equal(t.runs.stats().slots_in_use, 0); assert.equal(intents(t.dir).length, 0);
  ok('cancel: only the run token permits it; queued and running runs finalize once as error without a result; slots released');
}

// ---- Phase 2 limits apply: slots (busy) and the byte bound, refused before authorize-run where possible ----
{
  const t = await setup('limits', { env: { E3D_MCP_RUNS_PER_PRINCIPAL: '1', E3D_MCP_RUNS_GLOBAL: '2' }, concurrent: 1 });
  t.ex.open = false;
  const a = ids(); const b = ids(); const c = ids(); const d = ids();
  t.svc.reserve(a.reservation_id, 'acct_1'); t.svc.reserve(b.reservation_id, 'acct_1'); t.svc.reserve(c.reservation_id, 'acct_2'); t.svc.reserve(d.reservation_id, 'acct_3');
  assert.equal((await t.post({ ...a, question: Q })).status, 202);
  const rb = await t.post({ ...b, question: Q });
  // The per-principal limit is only known after authorize-run has bound the reservation, so it is answered as "try again later"
  // (503 unavailable, not accepted), never as a definitive rejection that would make the service release a bound reservation.
  assert.equal(rb.status, 503); assert.equal(rb.body.code, 'unavailable'); assert.equal(rb.body.accepted, false);
  assert.equal((await t.post({ ...c, question: Q })).status, 202);
  const nAuth = t.svc.authorizes.length;
  const rd = await t.post({ ...d, question: Q });
  assert.equal(rd.status, 429); assert.equal(t.svc.authorizes.length, nAuth, 'the global slot limit refuses before authorize-run');
  t.ex.releaseAll();
  assert.ok(await until(() => t.runs.stats().slots_in_use === 0));
  // the busy run is accepted on retry (the binding was idempotent)
  assert.equal((await t.post({ ...b, question: Q })).status, 202);
  assert.ok(await t.done(b.debate_id));
  const big = await setup('bytes', { env: { E3D_MCP_RUNS_MAX_BYTES: '1' } });
  const e = ids(); big.svc.reserve(e.reservation_id, 'acct_1');
  assert.equal((await big.post({ ...e, question: Q })).status, 202); assert.ok(await big.done(e.debate_id));
  const f = ids(); big.svc.reserve(f.reservation_id, 'acct_1');
  const rf = await big.post({ ...f, question: Q });
  assert.equal(rf.status, 429); assert.equal(rf.body.code, 'busy'); assert.equal(big.svc.authorizes.length, 1, 'the byte bound refuses before authorize-run');
  ok('Phase 2 limits apply: per-account and global slots and the byte bound refuse with busy; a retry is accepted later');
}

// ---- recovery: a queued web run resumes without a reserve; a started one is finalized as error; an unaccepted one is dropped locally ----
{
  const svc = fakeService();
  const a = await setup('recover', { svc, concurrent: 1 });
  a.ex.open = false;
  const x = ids(); const y = ids(); svc.reserve(x.reservation_id, 'acct_r'); svc.reserve(y.reservation_id, 'acct_r');
  const rx = await a.post({ ...x, question: Q }); const ry = await a.post({ ...y, question: Q });
  await until(() => a.ex.waiting.has(x.debate_id));
  assert.equal(ry.body.status, 'queued');
  // "crash": stop the runner without finishing anything, then a new process on the same state directory
  a.runs.stop(); await a.server.close();
  const pidOf = (id) => join(a.dir, 'runs', principalDir('acct_r'), id, 'state.json');
  for (const id of [x.debate_id, y.debate_id]) { const s = JSON.parse(readFileSync(pidOf(id), 'utf8')); s.pid = 999999; await import('node:fs').then((fs) => fs.writeFileSync(pidOf(id), JSON.stringify(s))); }
  for (const f of intents(a.dir)) { const p = join(a.dir, 'metering-intents', f); const it = JSON.parse(readFileSync(p, 'utf8')); it.pid = 999999; (await import('node:fs')).writeFileSync(p, JSON.stringify(it)); }
  const b = await setup('recover', { svc, concurrent: 1 });
  assert.ok(await b.done(y.debate_id));
  const fx = svc.finalizes.filter((f) => f.debate_id === x.debate_id); const fy = svc.finalizes.filter((f) => f.debate_id === y.debate_id);
  assert.equal(fx.length, 1); assert.deepEqual([fx[0].outcome, fx[0].result, fx[0].source], ['error', null, 'web'], 'the started run is finalized as error');
  assert.equal(fy.length, 1); assert.deepEqual([fy[0].outcome, fy[0].source], ['ok', 'web'], 'the queued run resumed');
  assert.equal(svc.reserves.length, 0);
  const g = await b.get(y.debate_id, ry.body.run_token);
  assert.equal(g.status, 200); assert.equal(g.body.run.status, 'done', 'the run token survives the restart');
  assert.equal((await b.get(x.debate_id, rx.body.run_token)).body.run.status, 'failed');
  assert.equal(intents(b.dir).length, 0);
  // an authorized intent that was never accepted (a crash between beginAuthorized and the queued state) is dropped locally
  const handle = await b.metering.beginAuthorized('acct_r', worst, { reservation_id: 'rsv_orphan', debate_id: `dbt_${hex(55555)}`, debate: { question: Q, providers: ['claude', 'codex'], rounds: 1 } });
  assert.equal(handle.ok, true);
  const p = join(b.dir, 'metering-intents', `${handle.handle.request_id}.json`); const it = JSON.parse(readFileSync(p, 'utf8')); it.pid = 999999; (await import('node:fs')).writeFileSync(p, JSON.stringify(it));
  const nf = svc.finalizes.length; const nr = svc.releases.length;
  await b.metering.recover();
  assert.equal(intents(b.dir).length, 0); assert.equal(svc.finalizes.length, nf); assert.equal(svc.releases.length, nr, 'nothing is sent for an unaccepted web run');
  ok('recovery: a queued web run resumes without a reserve, a started one ends as error, an unaccepted one is dropped locally');
}

// ---- a run that exists is answered from its key BEFORE planning (pilot.e3d.ai docs/panel-config-spec.md 4.3 item 4) ----
{
  const t = await setup('replan');
  t.ex.open = false;
  const id = ids(); t.svc.reserve(id.reservation_id, 'acct_web');
  const body = { ...id, question: Q, providers: ['anthropic-api', 'openai-api'] };
  const first = await t.post(body);
  assert.equal(first.status, 202);
  down.add('openai-api'); // a vendor of the panel goes down while the run is held
  const p0 = planned.n;
  const again = await t.post(body);
  assert.equal(again.status, 200, JSON.stringify(again.body)); assert.equal(again.body.existing, true); assert.equal(again.body.run_token, first.body.run_token);
  assert.equal(planned.n, p0, 'an identical retry is not planned again');
  assert.equal((await t.post({ ...body, providers: ['anthropic-api', 'gemini-api'] })).status, 409, 'a changed body is still a conflict');
  // A NEW run with the vendor still down is planned and refused: 400 invalid, nothing authorized, nothing local.
  const fresh = ids(); t.svc.reserve(fresh.reservation_id, 'acct_web');
  const a0 = t.svc.authorizes.length;
  const r = await t.post({ ...fresh, question: Q, providers: ['anthropic-api', 'openai-api'] });
  assert.equal(r.status, 400); assert.equal(r.body.code, 'invalid'); assert.match(r.body.message, /panel_unavailable/);
  assert.equal(t.svc.authorizes.length, a0);
  down.clear(); t.ex.releaseAll();
  assert.ok(await t.done(id.debate_id));
  assert.equal(t.ex.ran.length, 1); assert.equal(t.svc.finalizes.length, 1);
  assert.deepEqual([t.svc.finalizes[0].outcome], ['ok'], 'the held run finishes and is charged normally');
  ok('an identical retry after a vendor went down is 200 existing (never planned again); only a new run is planned and refused');
}

// ---- privacy: no question, answer, transcript, service token or run token in any log line ----
{
  assert.ok(logs.length > 20);
  for (const l of logs) {
    assert.doesNotMatch(l, /QCONTENT|ACONTENT|TCONTENT/, l);
    assert.ok(!l.includes(SVC_TOKEN) && !l.includes('MARKER'), l);
  }
  const tokens = [];
  for (const d of readdirSync(ROOT)) {
    const rr = join(ROOT, d, 'runs'); if (!existsSync(rr)) continue;
    for (const g of readdirSync(rr)) for (const id of readdirSync(join(rr, g))) { try { tokens.push(JSON.parse(readFileSync(join(rr, g, id, 'state.json'), 'utf8')).run_token); } catch { /* none */ } }
  }
  assert.ok(tokens.filter(Boolean).length > 3);
  for (const tk of tokens.filter(Boolean)) for (const l of logs) assert.ok(!l.includes(tk), 'a run token leaked into a log line');
  ok(`no content, service token or run token in ${logs.length} log lines`);
}

for (const s of servers) await s.close().catch(() => {});
console.log(`run-server unit tests: ${n} passed`);
process.exit(0);
