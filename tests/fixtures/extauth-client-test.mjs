// Client tests for lib/mcp/external-auth.js against examples/external-auth-stub.js. Driven by tests/mcp-extauth.sh:
//   STUB_URL, SVC_TOKEN, TOKEN_OK, TOKEN_REVOKED, TOKEN_REVOCABLE, TOKEN_SHORT_EXP, TOKEN_SIBLING, CLIENT_LOG
import assert from 'node:assert/strict';
import { randomUUID, randomBytes } from 'node:crypto';
import { appendFileSync, chmodSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createExternalAuth, validateConfig, AuthServiceError } from '../../lib/mcp/external-auth.js';

const E = process.env;
const URL_ = E.STUB_URL; const SVC = E.SVC_TOKEN;
const log = (...a) => appendFileSync(E.CLIENT_LOG, `${a.join(' ')}\n`);
let passed = 0;
const test = async (name, fn) => { await fn(); passed++; console.log(`ok - ${name}`); };

// fetch wrapper counting requests per call (only for cache/dedupe behavior; ledger effects are asserted on the stub)
const counter = () => {
  const n = {};
  const f = (u, o) => { const k = new URL(u).pathname.split('/').pop(); n[k] = (n[k] ?? 0) + 1; return fetch(u, o); };
  return { f, n };
};
const clock = () => { const c = { t: Date.now() }; c.now = () => c.t; return c; };
const client = (opts = {}) => createExternalAuth({ url: URL_, serviceToken: SVC, log, env: {}, ...opts });
const admin = async (path, body) => {
  const r = await fetch(`${URL_}/_stub/${path}`, { method: body ? 'POST' : 'GET', headers: { authorization: `Bearer ${SVC}`, 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
  return r.json();
};
const state = () => admin('state');
const inject = (mode, calls, extra = {}) => admin('inject', { mode, calls, ...extra });
const rejectsKind = async (p, kind, msg) => {
  await assert.rejects(p, (e) => { assert.ok(e instanceof AuthServiceError, `${msg}: expected AuthServiceError, got ${e}`); assert.equal(e.kind, kind, msg); return true; });
};
const reserveArgs = (principal = 'acct_ok', extra = {}) => ({ principal, request_id: randomUUID(), kind: 'debate', tool: 'e3d_debate', units: { calls: 3, est_tokens: 4000 }, ...extra });
const settleArgs = (reservation_id, calls = 2) => ({ reservation_id, actual: { calls, est_input_tokens: 1500, est_output_tokens: 500 }, models: [{ provider: 'claude', model: 'claude-test', calls }], outcome: 'ok', duration_ms: 900 });

// ---- validateConfig ----
await test('validateConfig rejects bad configuration and accepts good configuration', async () => {
  const good = { E3D_MCP_AUTH_URL: 'https://auth.example.com/v1/', E3D_MCP_AUTH_SERVICE_TOKEN: SVC };
  assert.equal(validateConfig(good).ok, true, JSON.stringify(validateConfig(good).errors));
  assert.equal(validateConfig({ ...good, E3D_MCP_AUTH_URL: 'http://localhost:9999' }).ok, true, 'http to loopback is allowed');
  assert.equal(validateConfig({ ...good, E3D_MCP_AUTH_URL: 'http://127.0.0.1:9999/x' }).ok, true);
  const bad = (env, re, why) => {
    const r = validateConfig(env);
    assert.equal(r.ok, false, why);
    assert.ok(r.errors.some((e) => re.test(e)), `${why}: ${r.errors.join(' | ')}`);
    assert.ok(!r.errors.join(' ').includes(SVC), 'errors never contain the service token');
  };
  bad({ ...good, E3D_MCP_AUTH_URL: 'not a url' }, /not a valid URL/, 'non-URL');
  bad({ ...good, E3D_MCP_AUTH_URL: undefined }, /not a valid URL/, 'missing URL');
  bad({ ...good, E3D_MCP_AUTH_URL: 'ftp://auth.example.com' }, /https/, 'non-http scheme');
  bad({ ...good, E3D_MCP_AUTH_URL: 'http://auth.example.com' }, /loopback/, 'http to a non-loopback host');
  bad({ ...good, E3D_MCP_AUTH_URL: 'http://10.0.0.5' }, /loopback/, 'http to a private host');
  bad({ ...good, E3D_MCP_AUTH_URL: 'https://user:pw@auth.example.com' }, /credentials/, 'URL with credentials');
  bad({ ...good, E3D_MCP_AUTH_URL: 'https://auth.example.com/?k=v' }, /query/, 'URL with a query');
  bad({ ...good, E3D_MCP_AUTH_URL: 'https://auth.example.com/#frag' }, /fragment/, 'URL with a fragment');
  bad({ ...good, E3D_MCP_AUTH_SERVICE_TOKEN: '' }, /service token is required/, 'missing service token');
  bad({ ...good, E3D_MCP_AUTH_SERVICE_TOKEN: 'short-token-123' }, /shorter than 24/, 'short service token');
  bad({ ...good, E3D_MCP_AUTH_SERVICE_TOKEN: `${'a'.repeat(30)} b` }, /printable ASCII/, 'service token with a space');
  bad({ ...good, E3D_MCP_AUTH_CACHE_SEC: '0' }, /CACHE_SEC/, 'cache below 1');
  bad({ ...good, E3D_MCP_AUTH_CACHE_SEC: '301' }, /CACHE_SEC/, 'cache above 300');
  bad({ ...good, E3D_MCP_AUTH_MAX_INFLIGHT: 'lots' }, /MAX_INFLIGHT/, 'non-numeric in-flight cap');
  const file = join(tmpdir(), `extauth-token-${process.pid}`);
  writeFileSync(file, `${SVC}\n`);
  chmodSync(file, 0o644);
  const viaFile = { E3D_MCP_AUTH_URL: good.E3D_MCP_AUTH_URL, E3D_MCP_AUTH_SERVICE_TOKEN_FILE: file };
  bad(viaFile, /group- or world-accessible/, 'token file with loose permissions');
  chmodSync(file, 0o640);
  bad(viaFile, /group- or world-accessible/, 'group-readable token file');
  chmodSync(file, 0o600);
  assert.equal(validateConfig(viaFile).ok, true, 'a 0600 token file is accepted');
  bad({ ...viaFile, E3D_MCP_AUTH_SERVICE_TOKEN: SVC }, /only one/, 'both token sources');
  bad({ ...viaFile, E3D_MCP_AUTH_SERVICE_TOKEN_FILE: `${file}.missing` }, /cannot be read/, 'missing token file');
  const realFetch = globalThis.fetch;
  try { delete globalThis.fetch; bad(good, /no global fetch/, 'missing global fetch'); } finally { globalThis.fetch = realFetch; }
  assert.throws(() => createExternalAuth({ env: { E3D_MCP_AUTH_URL: 'http://auth.example.com', E3D_MCP_AUTH_SERVICE_TOKEN: SVC } }), (e) => e instanceof AuthServiceError && e.kind === 'config');
  assert.equal(client().validateConfig(good).ok, true, 'validateConfig is also a method');
});

// ---- introspect ----
await test('valid and invalid tokens', async () => {
  const a = client();
  const ok = await a.introspect(E.TOKEN_OK);
  assert.equal(ok.active, true); assert.equal(ok.principal, 'acct_ok');
  assert.deepEqual([...ok.tools], ['e3d_debate', 'e3d_usage']);
  assert.equal(ok.limits.rate_per_min, 60); assert.equal(ok.limits.max_inflight, 2);
  assert.equal((await a.introspect(E.TOKEN_REVOKED)).active, false, 'revoked');
  assert.equal((await a.introspect(`unknown-${randomBytes(20).toString('hex')}`)).active, false, 'unknown');
});

await test('malformed bearer tokens are rejected before any service call', async () => {
  const { f, n } = counter();
  const a = client({ fetchImpl: f });
  assert.equal((await a.introspect('x'.repeat(513))).active, false, 'longer than 512');
  assert.equal((await a.introspect('tökén-with-non-ascii-chars')).active, false, 'non-ASCII');
  assert.equal((await a.introspect('has a space')).active, false, 'space');
  assert.equal((await a.introspect('')).active, false, 'empty');
  assert.equal((await a.introspect(undefined)).active, false, 'missing');
  assert.equal(n.introspect ?? 0, 0, 'no service call was made');
  assert.equal(a.stats().rejected_before_call, 5);
});

await test('cache hit within the TTL, re-validation after it (injectable clock)', async () => {
  const { f, n } = counter(); const c = clock();
  const a = client({ fetchImpl: f, now: c.now, env: { E3D_MCP_AUTH_CACHE_SEC: '30' } });
  await a.introspect(E.TOKEN_OK); await a.introspect(E.TOKEN_OK);
  c.t += 29000; await a.introspect(E.TOKEN_OK);
  assert.equal(n.introspect, 1, 'served from cache within 30 s');
  c.t += 2000; assert.equal((await a.introspect(E.TOKEN_OK)).active, true);
  assert.equal(n.introspect, 2, 're-validated after the TTL');
  assert.equal(a.stats().cache_hits, 2);
  // negative answers are cached for 5 s
  const bogus = `unknown-${randomBytes(20).toString('hex')}`;
  await a.introspect(bogus); c.t += 4000; await a.introspect(bogus);
  assert.equal(n.introspect, 3, 'negative answer cached');
  c.t += 1500; await a.introspect(bogus);
  assert.equal(n.introspect, 4, 'negative answer re-checked after 5 s');
});

await test('expires_at caps the cache lifetime', async () => {
  const { f, n } = counter(); const c = clock();
  const a = client({ fetchImpl: f, now: c.now, env: { E3D_MCP_AUTH_CACHE_SEC: '300' } });
  const r = await a.introspect(E.TOKEN_SHORT_EXP);
  assert.equal(r.active, true); assert.ok(r.expires_at);
  c.t += 25000; await a.introspect(E.TOKEN_SHORT_EXP);
  assert.equal(n.introspect, 1);
  c.t += 20000; await a.introspect(E.TOKEN_SHORT_EXP);
  assert.equal(n.introspect, 2, 'refetched once expires_at passed, long before the 300 s TTL');
  c.t += 120000;
  const late = await a.introspect(E.TOKEN_SHORT_EXP);
  assert.equal(late.active, false, 'an active answer whose expires_at is past the skew allowance counts as inactive');
});

await test('revocation becomes visible after the TTL', async () => {
  const c = clock();
  const a = client({ now: c.now, env: { E3D_MCP_AUTH_CACHE_SEC: '30' } });
  assert.equal((await a.introspect(E.TOKEN_REVOCABLE)).active, true);
  assert.equal((await admin('revoke', { key_id: 'key-revocable' })).ok, true);
  assert.equal((await a.introspect(E.TOKEN_REVOCABLE)).active, true, 'still cached within the TTL (the documented revocation latency)');
  c.t += 31000;
  assert.equal((await a.introspect(E.TOKEN_REVOCABLE)).active, false, 'revoked after the TTL');
  assert.equal((await a.introspect(E.TOKEN_SIBLING)).active, true, 'a sibling key of the same account keeps working');
  c.t += 1000;
  assert.equal((await a.introspect(E.TOKEN_REVOCABLE)).active, false, 'the inactive answer replaced the cached positive one');
});

await test('concurrent introspects of one token share one request', async () => {
  const { f, n } = counter();
  const a = client({ fetchImpl: f });
  await inject('slow', ['introspect'], { ms: 300 });
  try {
    const all = await Promise.all(Array.from({ length: 10 }, () => a.introspect(E.TOKEN_OK)));
    assert.ok(all.every((r) => r.active && r.principal === 'acct_ok'));
    assert.equal(n.introspect, 1, 'one service call for ten concurrent introspects');
    assert.equal(a.stats().shared, 9);
  } finally { await inject(null); }
});

await test('the global in-flight cap fails excess introspects fast with unavailable', async () => {
  const a = client({ env: { E3D_MCP_AUTH_MAX_INFLIGHT: '2' } });
  await inject('slow', ['introspect'], { ms: 400 });
  try {
    const p1 = a.introspect(E.TOKEN_OK); const p2 = a.introspect(E.TOKEN_SIBLING);
    const t0 = Date.now();
    await rejectsKind(a.introspect(E.TOKEN_REVOKED), 'unavailable', 'third distinct introspect');
    assert.ok(Date.now() - t0 < 200, 'failed fast, without waiting for the service');
    assert.equal((await p1).active, true); assert.equal((await p2).active, true);
    assert.equal(a.stats().cap_rejections, 1);
    assert.equal(a.stats().inflight, 0);
    assert.equal((await a.introspect(E.TOKEN_REVOKED)).active, false, 'works again once in-flight requests finish');
  } finally { await inject(null); }
});

await test('the cache holds at most 5000 entries, oldest evicted', async () => {
  const calls = [];
  const fake = async (u, o) => { calls.push(JSON.parse(o.body).token); return new Response(JSON.stringify({ active: true, principal: 'p1' }), { status: 200 }); };
  const a = client({ fetchImpl: fake });
  for (let i = 0; i <= 5000; i++) await a.introspect(`token-number-${i}-padding`);
  assert.equal(a.stats().cache_size, 5000);
  await a.introspect('token-number-5000-padding');
  assert.equal(calls.length, 5001, 'the newest entry is cached');
  await a.introspect('token-number-0-padding');
  assert.equal(calls.length, 5002, 'the oldest entry was evicted');
});

await test('returned values are re-validated against the schemas', async () => {
  const answer = (body) => async () => new Response(JSON.stringify(body), { status: 200 });
  const cases = [
    [{ active: true, principal: 'has spaces' }, 'principal pattern'],
    [{ active: true }, 'missing principal'],
    [{ active: true, principal: 'p', tools: Array.from({ length: 65 }, (_, i) => `t${i}`) }, 'too many tools'],
    [{ active: true, principal: 'p', limits: { rate_per_min: -1 } }, 'negative limit'],
    [{ active: true, principal: 'p', limits: { max_inflight: 1.5 } }, 'non-integer limit'],
    [{ active: true, principal: 'p', expires_at: 'tomorrow' }, 'bad timestamp'],
    [{ active: 'yes', principal: 'p' }, 'wrong type'],
  ];
  for (const [body, why] of cases) await rejectsKind(client({ fetchImpl: answer(body) }).introspect(`tok-${randomUUID()}`), 'bad-response', why);
  const extra = await client({ fetchImpl: answer({ active: true, principal: 'p', future_field: { x: 1 } }) }).introspect('tok-extra-field');
  assert.equal(extra.active, true, 'unknown fields are ignored');
  assert.equal('future_field' in extra, false, 'and not passed through');
  await rejectsKind(client({ fetchImpl: answer({ ok: true, reservation_id: 'r1', expires_at: 'x' }) }).reserve(reserveArgs()), 'bad-response', 'reserve timestamp');
  await rejectsKind(client({ fetchImpl: answer({ ok: false, code: 'nope' }) }).reserve(reserveArgs()), 'bad-response', 'unknown refusal code');
  await rejectsKind(client({ fetchImpl: answer({ ok: false, code: 'insufficient_credits' }) }).settle(settleArgs('r1')), 'bad-response', 'settle code');
});

// ---- reserve / settle / release ----
await test('reserve success holds funds; each refusal code is returned', async () => {
  const a = client();
  const before = (await state()).accounts.acct_ok;
  const r = await a.reserve(reserveArgs());
  assert.equal(r.ok, true); assert.ok(r.reservation_id); assert.ok(Date.parse(r.expires_at) > Date.now());
  const after = (await state()).accounts.acct_ok;
  assert.equal(before.available - after.available, 3 + 4, 'the hold is 3 calls + 4 ktokens');
  assert.equal(after.balance, before.balance, 'a hold is not a charge');
  for (const [principal, code] of [['acct_nobody', 'unknown_principal'], ['acct_suspended', 'suspended'], ['acct_limited', 'limit_reached'], ['acct_broke', 'insufficient_credits']]) {
    const x = await a.reserve(reserveArgs(principal));
    assert.equal(x.ok, false); assert.equal(x.code, code, principal); assert.equal(typeof x.message, 'string');
  }
  const args = reserveArgs();
  const first = await a.reserve(args);
  assert.equal((await a.reserve(args)).reservation_id, first.reservation_id, 'idempotent request_id');
  const c = await a.reserve({ ...args, units: { calls: 9, est_tokens: 1 } });
  assert.equal(c.ok, false); assert.equal(c.code, 'conflict');
  await assert.rejects(a.reserve({ ...args, request_id: 'not-a-uuid' }), TypeError, 'invalid requests never leave the client');
});

await test('settle charges once; identical repeat ok; different repeat conflict; release by either id', async () => {
  const a = client();
  const r = await a.reserve(reserveArgs());
  const bal = (await state()).accounts.acct_ok.balance;
  assert.deepEqual(await a.settle(settleArgs(r.reservation_id)), { ok: true });
  assert.deepEqual(await a.settle(settleArgs(r.reservation_id)), { ok: true });
  const c = await a.settle(settleArgs(r.reservation_id, 3));
  assert.equal(c.ok, false); assert.equal(c.code, 'conflict');
  const s = await state();
  assert.equal(s.settlements.filter((x) => x.reservation_id === r.reservation_id).length, 1, 'exactly one settlement');
  assert.equal(bal - s.accounts.acct_ok.balance, 2 + 2, 'charged actual use (2 calls + 2 ktokens), once');
  const r2 = await a.reserve(reserveArgs());
  assert.deepEqual(await a.release({ reservation_id: r2.reservation_id, reason: 'zero_usage' }), { ok: true });
  const args3 = reserveArgs(); await a.reserve(args3);
  assert.deepEqual(await a.release({ request_id: args3.request_id, reason: 'ambiguous_reserve' }), { ok: true });
  const st = (await state()).reservations;
  assert.equal(st.find((x) => x.reservation_id === r2.reservation_id).state, 'released');
  assert.equal(st.find((x) => x.request_id === args3.request_id).state, 'released');
  assert.deepEqual(await a.health(), { status: 'ok' });
});

// ---- service failures ----
await test('timeouts, 5xx, malformed, oversized, redirects, drops and invalid bodies become AuthServiceError', async () => {
  const a = client({ timeouts: { introspect: 250, reserve: 250, health: 250, settle: 250, release: 250 } });
  const calls = {
    introspect: () => a.introspect(`unknown-${randomBytes(20).toString('hex')}`),
    reserve: () => a.reserve(reserveArgs()),
    settle: () => a.settle(settleArgs('res_does_not_matter')),
    release: () => a.release({ reservation_id: 'res_does_not_matter', reason: 'zero_usage' }),
    health: () => a.health(),
  };
  const modes = { slow: 'unavailable', '5xx': 'unavailable', redirect: 'unavailable', drop: 'unavailable', malformed: 'bad-response', oversized: 'bad-response', invalid: 'bad-response' };
  try {
    for (const [mode, kind] of Object.entries(modes)) {
      for (const [name, run] of Object.entries(calls)) {
        await inject(mode, [name], { count: 1, ms: 800 });
        await rejectsKind(run(), kind, `${name} with ${mode}`);
      }
    }
  } finally { await inject(null); }
  const bad = client({ serviceToken: `wrong-${'z'.repeat(30)}` });
  await rejectsKind(bad.introspect(E.TOKEN_OK), 'config', '401 for the service token is a configuration failure');
  const refused = client({ url: 'http://127.0.0.1:1' });
  await rejectsKind(refused.health(), 'unavailable', 'connection refused');
  assert.ok(a.stats().errors.unavailable >= 20 && a.stats().errors['bad-response'] >= 15);
});

await test('drop-after-commit: the settle is committed, the retry is a no-op in the ledger', async () => {
  const a = client();
  const r = await a.reserve(reserveArgs());
  const bal = (await state()).accounts.acct_ok.balance;
  await inject('drop-after-commit', ['settle'], { count: 1 });
  await rejectsKind(a.settle(settleArgs(r.reservation_id)), 'unavailable', 'the response was lost');
  assert.deepEqual(await a.settle(settleArgs(r.reservation_id)), { ok: true }, 'the identical retry is ok');
  const s = await state();
  assert.equal(s.settlements.filter((x) => x.reservation_id === r.reservation_id).length, 1, 'charged exactly once');
  assert.equal(bal - s.accounts.acct_ok.balance, 4);
});

await test('errors and stats never contain a token', async () => {
  const a = client();
  await inject('5xx', ['introspect'], { count: 1 });
  try { await a.introspect(E.TOKEN_OK); } catch (e) { assert.ok(!e.message.includes(E.TOKEN_OK) && !e.message.includes(SVC)); }
  const s = JSON.stringify(a.stats());
  assert.ok(!s.includes(E.TOKEN_OK) && !s.includes(SVC));
  assert.ok(!JSON.stringify(validateConfig({ E3D_MCP_AUTH_URL: 'https://x.example', E3D_MCP_AUTH_SERVICE_TOKEN: SVC })).includes(SVC), 'config is not serialized with the token');
});

console.log(`client tests: ${passed} passed`);
