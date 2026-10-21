// Unit tests for lib/mcp/panel.js (per-account model panels, hosted mode): configuration, the resolve client against a fake
// fetch (every failure refuses, single-flight, no cache), and the degrade / subset / family decisions. No network, no models.
// Usage: node tests/fixtures/panel-unit.mjs
import assert from 'node:assert/strict';
import { validatePanelConfig, createPanelClient, degrade, explicitPanel, checkFamilies, requireFamilies, familiesOf, PANEL_ROUTE } from '../../lib/mcp/panel.js';
import { PROVIDER_FAMILY } from '../../lib/mcp/voices.js';
import { worstCase } from '../../lib/mcp/usage.js';

let n = 0;
// The client's timers are unref'd (they never hold a server open); keep this process alive while they run.
const keepAlive = setInterval(() => {}, 1000);
const ok = (m) => { n++; console.log(`ok - panel: ${m}`); };
const SVC = `svc-MARKER-${'x'.repeat(40)}`;
const ENV = { E3D_MCP_AUTH_URL: 'http://127.0.0.1:9', E3D_MCP_AUTH_SERVICE_TOKEN: SVC };

// ---- configuration ----
{
  const v = (env) => validatePanelConfig(env);
  assert.deepEqual(v({}), { ok: true, errors: [], allowed: null, panel: false });
  assert.deepEqual(v({ E3D_MCP_ALLOWED_PROVIDERS: 'anthropic-api, openai-api', E3D_MCP_PROVIDERS: 'anthropic-api,openai-api' }), { ok: true, errors: [], allowed: ['anthropic-api', 'openai-api'], panel: false });
  assert.equal(v({ E3D_MCP_ALLOWED_PROVIDERS: 'anthropic-api,mystery-api' }).errors[0], 'E3D_MCP_ALLOWED_PROVIDERS names a provider with no vendor family: mystery-api');
  assert.equal(v({ E3D_MCP_ALLOWED_PROVIDERS: 'anthropic-api,Open AI' }).errors[0], 'E3D_MCP_ALLOWED_PROVIDERS must be a comma-separated list of provider names');
  assert.equal(v({ E3D_MCP_ALLOWED_PROVIDERS: 'anthropic-api,anthropic-api' }).errors[0], 'E3D_MCP_ALLOWED_PROVIDERS lists a provider twice');
  assert.equal(v({ E3D_MCP_ALLOWED_PROVIDERS: 'anthropic-api,openai-api', E3D_MCP_PROVIDERS: 'anthropic-api,claude' }).errors[0], 'E3D_MCP_PROVIDERS must be inside E3D_MCP_ALLOWED_PROVIDERS (not allowed: claude)');
  assert.deepEqual(v({ E3D_MCP_PANEL: '1' }).errors, ['E3D_MCP_PANEL=1 needs E3D_MCP_ALLOWED_PROVIDERS', 'E3D_MCP_PANEL=1 needs the external auth hook (E3D_MCP_AUTH_URL)']);
  assert.equal(v({ E3D_MCP_PANEL: 'yes' }).errors[0], 'E3D_MCP_PANEL must be 1 or unset');
  assert.equal(v({ ...ENV, E3D_MCP_PANEL: '1', E3D_MCP_ALLOWED_PROVIDERS: 'anthropic-api,openai-api' }).panel, true);
  ok('configuration: allowlist names known families, the default is inside it, the panel needs the allowlist and the hook');
}

// ---- the resolve client ----
const answer = (status, body, headers = {}) => new Response(typeof body === 'string' ? body : JSON.stringify(body), { status, headers: { 'content-type': 'application/json', ...headers } });
const GOOD = { ok: true, source: 'account', providers: [{ id: 'openai-api', family: 'openai' }, { id: 'gemini-api', family: 'google' }] };
function client(handler, { timeoutMs = 200 } = {}) {
  const calls = [];
  const fetchImpl = async (url, init) => { calls.push({ url, init, body: JSON.parse(init.body) }); return handler(url, init); };
  const logs = [];
  return { c: createPanelClient({ env: ENV, fetchImpl, timeoutMs, log: (...a) => logs.push(a.join(' ')) }), calls, logs };
}
{
  const { c, calls } = client(async () => answer(200, GOOD));
  assert.deepEqual(await c.resolve('pk_aaaa'), { ok: true, source: 'account', providers: GOOD.providers });
  const [call] = calls;
  assert.equal(call.url, `http://127.0.0.1:9${PANEL_ROUTE}`);
  assert.equal(call.init.method, 'POST');
  assert.equal(call.init.redirect, 'manual');
  assert.equal(call.init.headers.authorization, `Bearer ${SVC}`);
  assert.equal(call.init.headers['x-e3d-panel-version'], '1');
  assert.deepEqual(call.body, { principal: 'pk_aaaa' });
  // No positive cache: every debate asks again.
  await c.resolve('pk_aaaa'); await c.resolve('pk_aaaa');
  assert.equal(calls.length, 3);
  ok('resolve: POST with the service token and version header; asked again for every debate (no cache)');
}
{
  let release;
  const gate = new Promise((r) => { release = r; });
  const { c, calls } = client(async () => { await gate; return answer(200, GOOD); });
  const all = Promise.all([c.resolve('pk_x'), c.resolve('pk_x'), c.resolve('pk_x'), c.resolve('pk_y')]);
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(calls.length, 2, 'concurrent calls for one principal share one request');
  release();
  const out = await all;
  assert.ok(out.every((r) => r.ok));
  assert.equal(c.stats().shared, 2);
  await c.resolve('pk_x');
  assert.equal(calls.length, 3, 'nothing is kept once it answered');
  ok('resolve: single-flight per principal for concurrent calls only');
}
{
  const cases = [
    ['404', async () => answer(404, { error: 'not_found' }), 'http_404'],
    ['500', async () => answer(500, { error: 'x' }), 'http_500'],
    ['503', async () => answer(503, { ok: false }), 'http_503'],
    ['429', async () => answer(429, { error: 'rate_limited' }), 'http_429'],
    ['401', async () => answer(401, { error: 'unauthorized' }), 'http_401'],
    ['redirect', async () => answer(307, { error: 'moved' }, { location: '/x' }), 'redirect'],
    ['garbled', async () => answer(200, '{"ok": tru'), 'garbled'],
    ['null providers', async () => answer(200, { ok: true, source: 'default', providers: null }), 'garbled'],
    ['ok false', async () => answer(200, { ok: false, source: 'default', providers: [] }), 'garbled'],
    ['unknown source', async () => answer(200, { ...GOOD, source: 'org' }), 'garbled'],
    ['bad id', async () => answer(200, { ...GOOD, providers: [{ id: 'Open AI', family: 'openai' }] }), 'garbled'],
    ['missing family', async () => answer(200, { ...GOOD, providers: [{ id: 'openai-api' }] }), 'garbled'],
    ['duplicate', async () => answer(200, { ...GOOD, providers: [GOOD.providers[0], GOOD.providers[0]] }), 'garbled'],
    ['too many', async () => answer(200, { ...GOOD, providers: Array.from({ length: 17 }, (_, i) => ({ id: `p${i}`, family: 'openai' })) }), 'garbled'],
    ['oversized', async () => answer(200, JSON.stringify({ ...GOOD, pad: 'x'.repeat(20000) })), 'too_large'],
    ['connection', async () => { throw new TypeError('fetch failed'); }, 'connection'],
    ['timeout', (_u, init) => new Promise((_r, rej) => init.signal.addEventListener('abort', () => rej(new Error('aborted')))), 'timeout'],
  ];
  for (const [name, handler, why] of cases) {
    const { c, logs } = client(handler, { timeoutMs: 50 });
    assert.deepEqual(await c.resolve('pk_z'), { ok: false, why }, name);
    assert.ok(logs.some((l) => l.includes(`resolve failed (${why})`)), name);
    assert.ok(!logs.join('\n').includes('pk_z') && !logs.join('\n').includes(SVC), `${name}: no principal or token logged`);
  }
  const { c } = client(async () => answer(200, GOOD));
  assert.deepEqual(await c.resolve(''), { ok: false, why: 'no_principal' });
  assert.deepEqual(await c.resolve(undefined), { ok: false, why: 'no_principal' });
  ok('resolve: 404, 5xx, 429, 401, redirect, garbled, malformed, oversized, connection failure and timeout all refuse; nothing is logged but the class');
}

// ---- decisions ----
{
  const up = (down = []) => (p) => !down.includes(p);
  const allowed = ['anthropic-api', 'openai-api', 'gemini-api', 'azure-openai'];
  assert.deepEqual(degrade(['anthropic-api', 'openai-api', 'gemini-api'], { allowed, isAvailable: up(), max: 3 }), { providers: ['anthropic-api', 'openai-api', 'gemini-api'], dropped: [] });
  assert.deepEqual(degrade(['anthropic-api', 'openai-api', 'gemini-api'], { allowed, isAvailable: up(['openai-api']), max: 3 }), { providers: ['anthropic-api', 'gemini-api'], dropped: ['openai-api'] }, 'order kept');
  assert.deepEqual(degrade(['gemini-api', 'xai-api', 'anthropic-api'], { allowed, isAvailable: up(), max: 3 }), { providers: ['gemini-api', 'anthropic-api'], dropped: ['xai-api'] }, 'a vendor outside the allowlist is dropped, never replaced');
  let r = degrade(['openai-api', 'azure-openai', 'anthropic-api'], { allowed, isAvailable: up(['anthropic-api']), max: 3 });
  assert.equal(r.code, 'panel_unavailable', 'one family left');
  assert.match(r.error, /^error: panel_unavailable: your panel needs at least two available vendors from different companies; anthropic-api is unavailable\. Change it in Settings > Debate panel\./);
  assert.equal(degrade(['anthropic-api', 'openai-api'], { allowed, isAvailable: up(['openai-api']), max: 3 }).code, 'panel_unavailable', 'one vendor left');
  assert.equal(degrade([], { allowed, isAvailable: up(), max: 3 }).code, 'panel_unavailable', 'an empty panel');
  assert.equal(degrade(['anthropic-api', 'openai-api', 'gemini-api', 'azure-openai'], { allowed, isAvailable: up(), max: 3 }).code, 'panel_too_large', 'refused, never truncated');
  ok('degrade: drops unavailable or non-allowed vendors in order, refuses one vendor or one family left and refuses (never truncates) a longer panel');

  const acct = ['anthropic-api', 'gemini-api', 'openai-api'];
  assert.deepEqual(explicitPanel(['gemini-api', 'anthropic-api'], { allowed, accountIds: acct, isAvailable: up(), max: 3 }), { providers: ['gemini-api', 'anthropic-api'] }, 'a subset is used as given');
  r = explicitPanel(['anthropic-api', 'azure-openai'], { allowed, accountIds: acct, isAvailable: up(), max: 3 });
  assert.equal(r.code, 'not_on_panel'); assert.match(r.error, /not on your account's debate panel: azure-openai/);
  assert.equal(explicitPanel(['anthropic-api', 'xai-api'], { allowed, accountIds: acct, isAvailable: up(), max: 3 }).code, 'provider_not_allowed');
  assert.equal(explicitPanel(['anthropic-api', 'mcp-sampling'], { allowed, accountIds: null, isAvailable: up(), max: 3 }).code, 'provider_not_allowed', 'sampling is never allowed in hosted mode');
  assert.equal(explicitPanel(['anthropic-api', 'openai-api'], { allowed, accountIds: acct, isAvailable: up(['openai-api']), max: 3 }).code, 'provider_unavailable', 'an explicit list is strict');
  assert.equal(explicitPanel(acct.concat('azure-openai'), { allowed, accountIds: null, isAvailable: up(), max: 3 }).code, 'panel_too_large');
  ok('explicit: only a subset of the account panel, only allowed, all available, at most the cap; it can never add a vendor');

  assert.equal(requireFamilies(['openai-api', 'azure-openai']).code, 'panel_unavailable');
  assert.equal(requireFamilies(['openai-api', 'mystery']).code, 'panel_unavailable', 'an unknown family does not count');
  assert.equal(requireFamilies(['openai-api', 'anthropic-api']), null);
  assert.deepEqual(familiesOf(['openai-api', 'azure-openai', 'gemini-api']), ['openai', 'google']);
  const logs = [];
  assert.equal(checkFamilies({ providers: [{ id: 'gemini-api', family: 'xai' }, { id: 'openai-api', family: 'openai' }] }, (m) => logs.push(m)).code, 'panel_config_mismatch');
  assert.match(logs[0], /^ALERT panel: billing and e3d-mcp disagree on vendor families \(gemini-api: billing xai, here google\)/);
  assert.equal(checkFamilies({ providers: [{ id: 'unknown-api', family: 'openai' }] }).code, 'panel_config_mismatch', 'a provider e3d-mcp has no family for');
  assert.equal(checkFamilies({ providers: [{ id: 'gemini-api', family: 'google' }] }), null);
  ok('families: two required; billing and e3d-mcp must agree for every resolved provider (panel_config_mismatch)');
}

// ---- the family map billing mirrors, and the reservation sizes of spec section 5 ----
{
  assert.deepEqual(PROVIDER_FAMILY, {
    claude: 'anthropic', codex: 'openai', gemini: 'google', 'grok-build': 'xai', devin: 'anthropic', 'anthropic-api': 'anthropic',
    'openai-api': 'openai', 'gemini-api': 'google', 'xai-api': 'xai', 'azure-openai': 'openai',
  });
  const table = [[2, 3, 6936, 5, 17300], [3, 4, 9248, 7, 27160], [4, 5, 11560, 9, 38700]];
  for (const [p, qc, qt, mc, mt] of table) {
    assert.deepEqual(worstCase({ providers: p, rounds: 1, maxWords: 80, questionChars: 8000 }), { calls: qc, tokens: qt }, `quick p=${p}`);
    assert.deepEqual(worstCase({ providers: p, rounds: 2, maxWords: 300, questionChars: 8000 }), { calls: mc, tokens: mt }, `customer max p=${p}`);
  }
  ok('PROVIDER_FAMILY is the map billing mirrors; worstCase matches the panel spec table (section 5)');
}

clearInterval(keepAlive);
console.log(`panel unit tests: ${n} passed`);
