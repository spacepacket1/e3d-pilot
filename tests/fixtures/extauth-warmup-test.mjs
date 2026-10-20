// Feature warm-up: the web-run path must become ready after a restart without any client call, when the billing service
// advertises features on GET /health. Real client, real readiness probe, real run listener, fake billing over loopback.
// Usage: node tests/fixtures/extauth-warmup-test.mjs <state root>
import assert from 'node:assert/strict';
import http from 'node:http';
import { createExternalAuth } from '../../lib/mcp/external-auth.js';
import { createReadiness } from '../../lib/mcp/metering.js';
import { startRunServer } from '../../lib/mcp/run-server.js';

let n = 0;
const ok = (m) => { n++; console.log(`ok - warmup: ${m}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms = 4000) { const end = Date.now() + ms; while (Date.now() < end) { if (await fn()) return true; await sleep(10); } return false; }
const SVC = `svc-MARKER-${'x'.repeat(40)}`;
const CALLER = `caller-MARKER-${'y'.repeat(30)}`;
const ALL = ['finalize', 'fetch', 'authorize-run'];

// mode: 'ok' | 'no-route' (404) | 'down' (destroy) | 'error' (503) | 'slow' | 'bad-json' | 'wrong-shape'
function billing(initial = {}) {
  const b = { mode: 'ok', features: ALL, healthFeatures: true, introspectActive: true, hits: { health: 0, introspect: 0 }, headers: [], ...initial };
  b.server = http.createServer((req, res) => {
    const call = req.url.slice(1);
    b.headers.push(JSON.stringify(req.headers));
    if (call === 'health') {
      b.hits.health++;
      if (b.mode === 'down') return req.socket.destroy();
      if (b.mode === 'error') { res.writeHead(503); return res.end('{}'); }
      if (b.mode === 'no-route') { res.writeHead(404); return res.end('{}'); }
      if (b.mode === 'bad-json') { res.writeHead(200); return res.end('{"status":'); }
      if (b.mode === 'wrong-shape') { res.writeHead(200); return res.end(JSON.stringify({ status: 'nope', features: ALL })); }
      const body = JSON.stringify({ status: 'ok', ...(b.healthFeatures ? { features: b.features } : {}) });
      if (b.mode === 'slow') return setTimeout(() => { res.writeHead(200); res.end(body); }, 400);
      res.writeHead(200, { 'content-type': 'application/json' }); return res.end(body);
    }
    if (call === 'introspect') {
      b.hits.introspect++;
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify(b.introspectActive ? { active: true, principal: 'acct_web', features: b.features } : { active: false, features: ALL }));
    }
    res.writeHead(404); res.end('{}');
  });
  return new Promise((r) => b.server.listen(0, '127.0.0.1', () => { b.url = `http://127.0.0.1:${b.server.address().port}`; r(b); }));
}
const client = (b, logs = [], extra = {}) => createExternalAuth({ url: b.url, serviceToken: SVC, log: (m) => logs.push(m), timeouts: { health: 200 }, env: {}, ...extra });
const postRun = (port, token = 'r'.repeat(32)) => fetch(`http://127.0.0.1:${port}/internal/runs`, { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: '{}' });
async function runListener(external) {
  const RUNTOK = 'r'.repeat(32);
  const srv = await startRunServer({ port: 0, token: RUNTOK, runs: {}, external, plan: () => ({ error: 'stop here' }) });
  return { srv, port: srv.port };
}

// 1. restart, no client call: the probe answers, the web path becomes ready
{
  const b = await billing(); const logs = [];
  const ext = client(b, logs);
  assert.deepEqual([...ext.features()], [], 'unknown after a restart');
  const ready = createReadiness({ external: ext, outbox: { stats: async () => ({}), canAccept: () => true }, intervalMs: 50, log: (m) => logs.push(m) });
  await ready.start();
  assert.deepEqual([...ext.features()], ALL); assert.equal(b.hits.introspect, 0, 'no client call was needed');
  for (const f of ALL) assert.ok(ext.hasFeature(f));
  ready.stop();
  ok('startup probe learns the features with no client call and no introspect');
  const joined = [...logs, ...b.headers].join('\n');
  assert.ok(!joined.includes(CALLER));
  assert.ok(!logs.join('\n').includes(SVC), 'the service token is never logged');
  ok('no secret in the logs');
  b.server.close();
}

// 2. the run listener asks on demand (no timer at all), throttled and single-flight
{
  const b = await billing(); let t = 0;
  const ext = client(b, [], { now: () => t });
  const { srv, port } = await runListener(ext);
  const r = await postRun(port);
  assert.equal(r.status, 400, 'ready: past the 503 gate, rejected later as a malformed body');
  assert.equal(b.hits.health, 1);
  await srv.close(); b.server.close();
  ok('web run path becomes ready on its own: the first run probes health on demand');
}

// 3. unreachable / erroring / slow / malformed probe: 503 not_ready, backoff, then recovery
for (const mode of ['down', 'error', 'slow', 'bad-json', 'wrong-shape', 'no-route']) {
  const b = await billing({ mode }); const logs = [];
  const ext = client(b, logs);
  const { srv, port } = await runListener(ext);
  const r = await postRun(port); const j = await r.json();
  assert.equal(r.status, 503, mode); assert.equal(j.code, 'not_ready', mode);
  assert.deepEqual([...ext.features()], [], `${mode}: nothing advertised`);
  const hits = b.hits.health;
  await postRun(port); assert.equal(b.hits.health, hits, `${mode}: throttled, no probe storm`);
  assert.ok(!logs.join('\n').includes(SVC), `${mode}: no secret logged`);
  await srv.close(); b.server.close();
}
ok('down/5xx/slow/malformed/wrong-shape/no-route probes: 503 not_ready, nothing advertised, throttled, no secret logged');

// 4. readiness backoff: a failing probe retries with growing gaps (not hammering), then recovers
{
  const b = await billing({ mode: 'down' }); const logs = [];
  const ext = client(b, logs);
  const ready = createReadiness({ external: ext, outbox: { stats: async () => ({}), canAccept: () => true }, intervalMs: 4000, log: (m) => logs.push(m) });
  const stamps = []; const orig = b.server.listeners('request')[0];
  b.server.removeAllListeners('request'); b.server.on('request', (q, s) => { if (q.url === '/health') stamps.push(Date.now()); orig(q, s); });
  await ready.start();
  await sleep(3600);
  assert.ok(stamps.length >= 3 && stamps.length <= 4, `1s,2s backoff gives 3 or 4 probes in 3.6 s, got ${stamps.length}`);
  assert.ok(stamps[2] - stamps[1] > stamps[1] - stamps[0] + 300, 'gaps grow');
  assert.deepEqual([...ext.features()], []);
  b.mode = 'ok';
  assert.ok(await until(() => ext.hasFeature('authorize-run'), 7000), 'recovers on a later probe');
  assert.ok(logs.some((m) => m.includes('recovered')));
  ready.stop(); b.server.close();
  ok('readiness probe backs off while the service is unreachable and recovers when it answers');
}

// 5. never advertised from an inactive or failed answer
{
  const b = await billing({ healthFeatures: false, introspectActive: false }); const logs = [];
  const ext = client(b, logs);
  const v = await ext.introspect('some-token-abc'); assert.equal(v.active, false);
  assert.deepEqual([...ext.features()], [], 'inactive introspect advertising features teaches nothing');
  await ext.health(); assert.deepEqual([...ext.features()], [], 'health without features teaches nothing');
  b.mode = 'wrong-shape'; await assert.rejects(ext.health()); assert.deepEqual([...ext.features()], []);
  b.mode = 'error'; await assert.rejects(ext.health()); assert.deepEqual([...ext.features()], []);
  b.server.close();
  ok('features are never learned from an inactive, failed, malformed or feature-less answer');
}

// 6. old path: an active introspect still advertises; a health without features leaves it; unknown names are ignored
{
  const b = await billing({ healthFeatures: false, features: [...ALL, 'future-thing'] });
  const ext = client(b);
  const v = await ext.introspect('some-token-abc'); assert.equal(v.active, true);
  assert.deepEqual([...ext.features()], ALL);
  await ext.health(); assert.deepEqual([...ext.features()], ALL, 'a feature-less health keeps what introspect learned');
  b.server.close();
  ok('the old path (active introspect) still advertises; unknown feature names ignored');
}

// 7. a service without the new field degrades exactly as before: health ok, run path stays 503 until an introspect
{
  const b = await billing({ healthFeatures: false });
  const ext = client(b);
  const { srv, port } = await runListener(ext);
  assert.equal((await postRun(port)).status, 503);
  await ext.introspect('some-token-abc');
  assert.equal((await postRun(port)).status, 400, 'ready after an active introspect, as before');
  await srv.close(); b.server.close();
  ok('billing without health features: 503 not_ready until a client introspects, as today');
}
console.log(`extauth warm-up tests: ${n} groups passed`);
process.exit(0);
