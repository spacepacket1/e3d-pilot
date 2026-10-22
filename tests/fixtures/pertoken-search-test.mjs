// Unit tests for web search inside per-token pricing (per_token_search_v1): the environment contract of bin/e3d-debate, the usage row's
// `searches`, per-provider caps and over-cap records, the run-body fields (both or neither, refused 400 invalid, never clamped), the capability
// gate, the connector quote client (version 2, the `search` object, a missing one means off) and the usage report (version 2).
// Shared vectors: tests/fixtures/search-vectors/*.json. Usage: node tests/fixtures/pertoken-search-test.mjs <scratch dir>
import assert from 'node:assert/strict';
import http from 'node:http';
import { mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';
import { limitsFromEnv, searchFromEnv, usageRow, reachedVendor, vendorUsage } from '../../lib/debate/token-pricing.mjs';
import { webSearchConfig, perTokenCaps, filterRecord, summarize, decisionLogFields } from '../../lib/debate/websearch.mjs';
import { validatePricingConfig, validatePerTokenFields, limitsForPlan, debateEnvFor, readUsageRows, createPricingClient, searchOf, searchCapable, requestedSearches,
  searchCapFromEnv, SEARCH_CAPABILITY, PER_TOKEN_CAPABILITY } from '../../lib/mcp/pricing.js';
import { pricingOf } from '../../lib/mcp/external-auth.js';
import { startRunServer, validateRunRequest } from '../../lib/mcp/run-server.js';

const DIR = process.argv[2];
if (!DIR) { console.error('usage: pertoken-search-test.mjs <scratch dir>'); process.exit(2); }
mkdirSync(DIR, { recursive: true });
const HERE = dirname(fileURLToPath(import.meta.url));
const vec = (name) => JSON.parse(readFileSync(join(HERE, 'search-vectors', name), 'utf8'));
let n = 0;
const ok = (m) => { n++; console.log(`ok - per-token search: ${m}`); };
const P = ['anthropic-api', 'openai-api', 'gemini-api', 'xai-api'];

// ---- the environment contract of e3d-debate ----
{
  const base = { E3D_DEBATE_MAX_TOKENS: JSON.stringify(Object.fromEntries(P.map((p) => [p, 700]))) };
  // search variables absent: the result is exactly what it was before this feature (no new keys)
  assert.deepEqual(limitsFromEnv(base, P), { perToken: true, maxTokens: Object.fromEntries(P.map((p) => [p, 700])), answerBytes: null });
  assert.deepEqual(limitsFromEnv({}, P), { perToken: false, maxTokens: null, answerBytes: null });
  const good = { ...base, E3D_DEBATE_MAX_SEARCHES: '{"anthropic-api":2,"openai-api":1}', E3D_DEBATE_CITE_BYTES_MAX: '1000' };
  const r = limitsFromEnv(good, P);
  assert.deepEqual([r.maxSearches, r.citeBytes], [{ 'anthropic-api': 2, 'openai-api': 1 }, 1000]);
  assert.equal(limitsFromEnv({ ...good, E3D_DEBATE_CITE_BYTES_MAX: '0' }, P).citeBytes, 0, 'cite_bytes 0 is valid');
  const refused = [
    [{ E3D_DEBATE_MAX_SEARCHES: good.E3D_DEBATE_MAX_SEARCHES }, 'together or not at all'],
    [{ E3D_DEBATE_CITE_BYTES_MAX: '1000' }, 'together or not at all'],
    [{ E3D_DEBATE_MAX_SEARCHES: '{"anthropic-api":0}' }, 'whole number'],
    [{ E3D_DEBATE_MAX_SEARCHES: '{"anthropic-api":11}' }, 'whole number'],
    [{ E3D_DEBATE_MAX_SEARCHES: '{"anthropic-api":1.5}' }, 'whole number'],
    [{ E3D_DEBATE_MAX_SEARCHES: '{}' }, 'object'],
    [{ E3D_DEBATE_MAX_SEARCHES: 'nope' }, 'JSON'],
    [{ E3D_DEBATE_MAX_SEARCHES: '{"claude":2}' }, 'not an API provider'],
    [{ E3D_DEBATE_MAX_SEARCHES: '{"deepseek-api":2}' }, 'not an API provider'],
    [{ E3D_DEBATE_CITE_BYTES_MAX: '20001' }, 'from 0 to 20000'],
    [{ E3D_DEBATE_CITE_BYTES_MAX: '-1' }, 'from 0 to 20000'],
    [{ E3D_DEBATE_CITE_BYTES_MAX: '1e3' }, 'from 0 to 20000'],
    [{ E3D_DEBATE_CITE_BYTES_MAX: '10.5' }, 'from 0 to 20000'],
  ];
  for (const [over, why] of refused) {
    const e = { ...base, E3D_DEBATE_MAX_SEARCHES: good.E3D_DEBATE_MAX_SEARCHES, E3D_DEBATE_CITE_BYTES_MAX: '1000', ...over };
    if (over.E3D_DEBATE_MAX_SEARCHES === undefined && over.E3D_DEBATE_CITE_BYTES_MAX !== undefined && why === 'together or not at all') delete e.E3D_DEBATE_MAX_SEARCHES;
    if (over.E3D_DEBATE_CITE_BYTES_MAX === undefined && over.E3D_DEBATE_MAX_SEARCHES !== undefined && why === 'together or not at all') delete e.E3D_DEBATE_CITE_BYTES_MAX;
    const got = limitsFromEnv(e, P);
    assert.ok(got.error && got.error.includes(why), `refused (${why}): ${JSON.stringify(over)} -> ${got.error}`);
  }
  assert.match(searchFromEnv({ E3D_DEBATE_MAX_SEARCHES: '{"anthropic-api":2}', E3D_DEBATE_CITE_BYTES_MAX: '5' }, ['anthropic-api'], false).error, /needs E3D_DEBATE_MAX_TOKENS/, 'search is priced inside per-token pricing only');
  // a provider that only writes the synthesis is not a panel provider: it never searches
  const synthOnly = limitsFromEnv({ ...base, E3D_DEBATE_MAX_SEARCHES: '{"xai-api":2}', E3D_DEBATE_CITE_BYTES_MAX: '5' }, ['xai-api', 'anthropic-api', 'openai-api'], ['anthropic-api', 'openai-api']);
  assert.match(synthOnly.error, /not an API provider of this debate/);
  ok('E3D_DEBATE_MAX_SEARCHES and E3D_DEBATE_CITE_BYTES_MAX: both or neither, per-token only, API providers of the panel, 1..10 and 0..20000; absent changes nothing');
}

// ---- the usage row's `searches` ----
{
  const f = (name, text) => { const p = join(DIR, name); writeFileSync(p, text); return p; };
  const prompt = f('p.md', 'a prompt');
  const out = f('o.md', 'an answer');
  const line = (o) => `e3d_provider_usage=${JSON.stringify(o)}\n`;
  const row = (stderr, status, extra = {}) => usageRow({ key: 'r1:openai-api', provider: 'openai-api', promptFile: prompt, outFile: out, stderrFile: f('e.txt', stderr), status, maxTokens: 1000, ...extra });
  const u = line({ provider: 'openai-api', model: 'm', tokens: 30, searches: 3, input_tokens: 2500, output_tokens: 30 });
  assert.equal('searches' in row(u, 0), false, 'without the search argument the row is exactly today\'s (usage report version 1)');
  assert.deepEqual(row(u, 0), { key: 'r1:openai-api', provider: 'openai-api', model: 'm', input_tokens: 2500, output_tokens: 30, source: 'vendor' });
  assert.equal(row(u, 0, { search: 'search' }).searches, 3, 'a searching call: the vendor\'s own counter, as reported (never clamped here)');
  assert.equal(row(line({ model: 'm', searches: 12, input_tokens: 1, output_tokens: 1 }), 0, { search: 'search' }).searches, 12, 'above the cap: the raw count (billing clamps and alarms)');
  assert.equal(row(u, 0, { search: 'none' }).searches, 0, 'a call made without the search tool: 0');
  assert.equal(row(line({ model: 'm', input_tokens: 1, output_tokens: 1 }), 0, { search: 'search' }).searches, null, 'no counter on the usage line: unknown (null), never a guess');
  assert.equal(row(line({ model: 'm', searches: -1, input_tokens: 1, output_tokens: 1 }), 0, { search: 'search' }).searches, null);
  assert.equal(row(line({ model: 'm', searches: 1.5, input_tokens: 1, output_tokens: 1 }), 0, { search: 'search' }).searches, null);
  assert.equal(row(line({ model: 'm', searches: '2', input_tokens: 1, output_tokens: 1 }), 0, { search: 'search' }).searches, null);
  const lost = row('error: openai-api web search unavailable (timeout)\n', 1, { search: 'search' });
  assert.deepEqual([lost.source, lost.searches, lost.output_tokens], ['bytes', null, 1000], 'a lost search response: bytes at the output limit, search count unknown');
  assert.equal(row('', 0, { search: 'none' }).searches, 0, 'bytes row of a call without the search tool: 0');
  assert.equal(row('error: openai-api request failed (curl exit 52): x\n', 1, { search: 'search' }).searches, null);
  // which failures reached the vendor
  for (const why of ['timeout', 'bad_response', 'response_failed', 'unexpected_tool', 'search_failed', 'no_text', 'status_failed', 'response_errors', 'search_error_unavailable', 'pause_turn_limit']) {
    assert.equal(reachedVendor({ status: 1, stderr: `error: x web search unavailable (${why})\n` }), true, `${why}: a 200 arrived or the request was lost: may be billed`);
  }
  for (const why of ['http_503', 'http_400', 'http_429', 'invalid_domain_config', 'search_disabled']) {
    assert.equal(reachedVendor({ status: 1, stderr: `error: x web search unavailable (${why}): m\n` }), false, `${why}: not billed`);
  }
  assert.equal(reachedVendor({ status: 1, stderr: 'error: x web search unavailable (request_failed): curl exit 7' }), false, 'connection refused: never sent');
  assert.equal(reachedVendor({ status: 1, stderr: 'error: x web search unavailable (request_failed): curl exit 52' }), true, 'empty reply after the request was sent');
  assert.equal(vendorUsage(u).searches, 3);
  assert.equal(vendorUsage(line({ model: 'm', input_tokens: 1, output_tokens: 1 })).searches, null);
  ok('rows carry `searches` only with the search argument: the vendor\'s raw counter, 0 for a call without the tool, null when unknown; failures that may have been billed are rows');
}

// ---- per-provider caps and over-cap records ----
{
  assert.equal(perTokenCaps({}), null);
  assert.equal(perTokenCaps({ E3D_DEBATE_MAX_SEARCHES: 'junk' }), null);
  assert.deepEqual(perTokenCaps({ E3D_DEBATE_MAX_SEARCHES: '{"anthropic-api":2,"openai-api":1,"claude":3,"xai-api":99}' }), { 'anthropic-api': 2, 'openai-api': 1 }, 'only API providers within 1..10');
  const env = { E3D_DEBATE_MAX_SEARCHES: '{"anthropic-api":2,"xai-api":1}', E3D_DEBATE_SEARCH_MAX_PER_CALL: '7' };
  const cfg = webSearchConfig(env);
  assert.deepEqual(cfg.providers, ['anthropic-api', 'xai-api'], 'only the providers the quote names search');
  assert.deepEqual(cfg.caps, { 'anthropic-api': 2, 'xai-api': 1 });
  assert.equal(cfg.maxSearches, 7, 'the global cap is still parsed, but a call\'s cap is the quote\'s');
  assert.deepEqual(webSearchConfig({ ...env, E3D_DEBATE_WEB_SEARCH_PROVIDERS: 'xai-api,openai-api' }).providers, ['xai-api'], 'the allowlist and the quote must both say yes');
  assert.equal(webSearchConfig({ ...env, E3D_DEBATE_WEB_SEARCH: 'off' }).enabled, false, 'the kill switch still wins');
  const plain = webSearchConfig({});
  assert.equal('caps' in plain, false, 'no quote: the config is exactly today\'s');
  const rec = (provider, searches) => filterRecord({ ok: true, searches, citations: [] }, { provider, round: 1, cfg });
  assert.deepEqual([rec('anthropic-api', 2).cap, rec('anthropic-api', 2).cap_exceeded], [2, false]);
  assert.deepEqual([rec('xai-api', 2).cap, rec('xai-api', 2).cap_exceeded], [1, true], 'xAI has no native cap: 2 against a quoted 1 is detected after the fact');
  assert.equal(rec('gemini-api', 5).cap, 7, 'a provider outside the map keeps the global figure (it never searches under per-token)');
  const records = [rec('anthropic-api', 1), rec('xai-api', 8)];
  const s = summarize(records, cfg, { requested: true, providersTotal: 2, searching: ['anthropic-api', 'xai-api'] });
  assert.deepEqual(s.flags.cap_exceeded, [{ alarm: 'web_search_cap_exceeded', provider: 'xai-api', round: 1, searches: 8, cap: 1 }]);
  assert.deepEqual(s.cap_by_provider, { 'anthropic-api': 2, 'xai-api': 1 });
  assert.match(decisionLogFields(s).alarms[0], /ALARM web_search_cap_exceeded provider=xai-api round=1 searches=8 cap=1/);
  assert.equal('cap_by_provider' in summarize([], plain, {}), false, 'unchanged summary without a quote');
  ok('the per-call cap per provider comes from the quote, not the global setting; over-cap searches are detected and alarmed per provider with no second call');
}

// ---- run-body fields ----
{
  const v = vec('runbody-vectors.json');
  const pricings = { capable: { mode: 'per_token', customer: v.customer, search: true }, per_token_only: { mode: 'per_token', customer: v.customer, search: false }, none: { mode: null, customer: null, search: false } };
  for (const c of v.cases) {
    const body = JSON.parse(JSON.stringify(v.base));
    for (const k of c.delete ?? []) delete body[k];
    Object.assign(body, c.set ?? {});
    const r = validateRunRequest(body, pricings[c.pricing]);
    if (c.expect === 'ok') {
      assert.ok(!r.error, `${c.name}: accepted (${r.error})`);
      if (body.max_searches) assert.deepEqual([r.perToken.max_searches, r.perToken.cite_bytes], [body.max_searches, body.cite_bytes], `${c.name}: honoured exactly`);
      else assert.equal(r.perToken.max_searches, undefined);
      assert.ok(r.key, 'part of the idempotency key');
    } else assert.ok(r.error, `${c.name}: refused`);
  }
  const base = JSON.parse(JSON.stringify(v.base));
  const withSearch = validateRunRequest(base, pricings.capable);
  const other = validateRunRequest({ ...base, max_searches: { 'anthropic-api': 1, 'openai-api': 2 } }, pricings.capable);
  const noSearch = validateRunRequest({ ...base, max_searches: undefined, cite_bytes: undefined }, pricings.capable);
  assert.notEqual(withSearch.key, other.key, 'max_searches is part of the idempotency key');
  assert.notEqual(withSearch.key, validateRunRequest({ ...base, cite_bytes: 999 }, pricings.capable).key, 'cite_bytes is part of it');
  assert.notEqual(withSearch.key, noSearch.key);
  // a body without the new fields: byte-identical to before
  assert.deepEqual(Object.keys(noSearch.perToken).sort(), ['answer_bytes', 'max_tokens', 'max_words', 'rounds'], 'no new keys without the new fields');
  const plan = ['anthropic-api', 'openai-api', 'xai-api'];
  const env = { E3D_MCP_PER_TOKEN_ALLOW_XAI: '1' };
  const lim = limitsForPlan(withSearch.perToken, [...plan], { env, panel: plan });
  assert.deepEqual([lim.maxSearches, lim.citeBytes], [base.max_searches, 1000]);
  assert.deepEqual(debateEnvFor(lim), { E3D_DEBATE_MAX_TOKENS: JSON.stringify(lim.maxTokens), E3D_DEBATE_ANSWER_BYTES_MAX: JSON.stringify(lim.answerBytes), E3D_DEBATE_MAX_SEARCHES: JSON.stringify(base.max_searches), E3D_DEBATE_CITE_BYTES_MAX: '1000' });
  assert.deepEqual(debateEnvFor({ maxTokens: { a: 1 }, answerBytes: { a: 2 } }), { E3D_DEBATE_MAX_TOKENS: '{"a":1}', E3D_DEBATE_ANSWER_BYTES_MAX: '{"a":2}' }, 'no search: exactly the old environment');
  assert.equal(limitsForPlan(noSearch.perToken, plan, { env, panel: plan }).maxSearches, undefined);
  // priced searches are run exactly or refused: a provider this server will not search with
  assert.match(limitsForPlan(withSearch.perToken, plan, { env: { ...env, E3D_DEBATE_WEB_SEARCH_PROVIDERS: 'openai-api' }, panel: plan }).error, /anthropic-api is quoted with web search but this server does not search with it/);
  assert.match(limitsForPlan(withSearch.perToken, plan, { env: { ...env, E3D_DEBATE_WEB_SEARCH: 'off' }, panel: plan }).error, /does not search/);
  // the synthesizer never searches: a cap for a provider outside the panel is dropped, as its token limits are
  const synth = limitsForPlan({ ...withSearch.perToken, max_searches: { 'openai-api': 2 } }, ['anthropic-api', 'openai-api'], { env, panel: ['anthropic-api'] });
  assert.equal(synth.maxSearches, undefined);
  ok('run body: max_searches and cite_bytes together or not at all, refused 400 invalid by a listener without the capability, never clamped, part of the idempotency key (shared vectors)');
}

// ---- capability gate ----
{
  const hook = { E3D_MCP_AUTH_URL: 'http://127.0.0.1:1', E3D_MCP_CUSTOMER_LIMITS: 'rounds=2,max_words=300' };
  const per = { ...hook, E3D_MCP_PRICING: 'per_token' };
  assert.equal(searchCapable({ ...per }), false, 'advertised only when configured: E3D_MCP_PER_TOKEN_SEARCH=1');
  assert.equal(searchCapable({ ...per, E3D_MCP_PER_TOKEN_SEARCH: '1' }), true);
  assert.equal(searchCapable({ E3D_MCP_PER_TOKEN_SEARCH: '1' }), false, 'never without E3D_MCP_PRICING=per_token');
  assert.equal(searchCapable({ ...per, E3D_MCP_PER_TOKEN_SEARCH: '1', E3D_DEBATE_WEB_SEARCH: 'off' }), false);
  assert.equal(searchCapable({ ...per, E3D_MCP_PER_TOKEN_SEARCH: '1', E3D_DEBATE_WEB_SEARCH_PROVIDERS: 'claude' }), false, 'no API provider may search');
  assert.equal(validatePricingConfig({ ...per, E3D_MCP_PER_TOKEN_SEARCH: '1' }, { http: true }).ok, true);
  assert.deepEqual(validatePricingConfig({ ...per }, { http: true }), { ok: true, errors: [], mode: 'per_token' }, 'unset: exactly today\'s answer');
  assert.deepEqual(validatePricingConfig({}), { ok: true, errors: [], mode: null });
  for (const bad of [{ E3D_MCP_PER_TOKEN_SEARCH: '1' }, { ...per, E3D_MCP_PER_TOKEN_SEARCH: 'yes' }, { ...per, E3D_MCP_PER_TOKEN_SEARCH: '1', E3D_DEBATE_WEB_SEARCH: 'off' }, { ...per, E3D_MCP_PER_TOKEN_SEARCH: '1', E3D_DEBATE_WEB_SEARCH_PROVIDERS: 'claude' }]) {
    assert.equal(validatePricingConfig(bad, { http: true }).ok, false, `startup refuses ${JSON.stringify(bad)}`);
  }
  const e = { ...per, E3D_MCP_PER_TOKEN_SEARCH: '1' };
  assert.equal(searchCapFromEnv({}), 2, 'the owner\'s cap: 2 per call');
  assert.equal(searchCapFromEnv({ E3D_DEBATE_SEARCH_MAX_PER_CALL: '3' }), 3);
  assert.equal(searchCapFromEnv({ E3D_DEBATE_SEARCH_MAX_PER_CALL: '99' }), 2);
  assert.deepEqual(requestedSearches(['anthropic-api', 'openai-api', 'claude', 'mcp-sampling'], e), { 'anthropic-api': 2, 'openai-api': 2 }, 'every searching API provider of the panel at cap 2; never a CLI or sampling voice');
  assert.equal(requestedSearches(['anthropic-api'], per), null, 'not configured: nothing is asked for');
  assert.deepEqual(requestedSearches(['anthropic-api', 'openai-api'], { ...e, E3D_DEBATE_WEB_SEARCH_PROVIDERS: 'openai-api' }), { 'openai-api': 2 });
  assert.equal(requestedSearches(['claude', 'codex'], e), null);
  ok('per_token_search_v1 is advertised only with E3D_MCP_PRICING=per_token and E3D_MCP_PER_TOKEN_SEARCH=1 and web search on here; the quote asks for cap 2 on the searching providers');
}

// ---- the quote and usage clients (a fake billing service) ----
{
  const v = vec('quote-vectors.json');
  for (const c of v.answers) assert.deepEqual(searchOf(c.search, c.asked), c.expect, `quote answer: ${c.name}`);
  const calls = [];
  let reply = null;
  const srv = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (d) => { raw += d; });
    req.on('end', () => {
      calls.push({ url: req.url, qv: req.headers['x-e3d-pricing-version'], uv: req.headers['x-e3d-usage-version'], body: JSON.parse(raw || '{}') });
      const send = (c, b) => { res.writeHead(c, { 'content-type': 'application/json' }); res.end(JSON.stringify(b)); };
      if (req.url === '/pricing/v1/quote') return send(reply?.[0] ?? 200, reply?.[1] ?? { ok: true, credits: 19, rate_version: 'r.1', max_credits: 100, max_tokens: { 'anthropic-api': 728 }, answer_bytes: { 'anthropic-api': 2000 } });
      if (req.url === '/usage/v1/report') return send(200, { ok: true, replay: false });
      send(404, {});
    });
  });
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  const env = { E3D_MCP_AUTH_URL: `http://127.0.0.1:${srv.address().port}`, E3D_MCP_AUTH_SERVICE_TOKEN: `svc-${'k'.repeat(30)}` };
  const client = createPricingClient({ env, sleep: async () => {}, reportAttempts: 2 });
  const answerWith = (search) => ({ ok: true, credits: 53, rate_version: 'r.2', max_credits: 75, max_tokens: { 'anthropic-api': 728, 'openai-api': 728 }, answer_bytes: { 'anthropic-api': 2000, 'openai-api': 2000 }, ...(search ? { search } : {}) });
  // no searches in the request: the version 1 request and answer, byte for byte
  let q = await client.quote({ principal: 'p', request_id: 'x' });
  assert.equal(calls.at(-1).qv, '1');
  assert.equal('search' in q, false);
  assert.equal('searches' in calls.at(-1).body, false);
  // with searches: version 2
  const asked = { 'anthropic-api': 2, 'openai-api': 2 };
  reply = [200, answerWith({ enabled: true, max_searches: asked, cite_bytes: 1000, search_credits_max: 34, credits_off: 19 })];
  q = await client.quote({ principal: 'p', request_id: 'y', searches: asked });
  assert.equal(calls.at(-1).qv, '2');
  assert.deepEqual(calls.at(-1).body.searches, asked);
  assert.deepEqual(q.search, { maxSearches: asked, citeBytes: 1000, creditsOff: 19, searchCreditsMax: 34 });
  assert.equal(q.credits, 53);
  // an older billing drops the unknown field and answers without a `search` object: search OFF
  reply = [200, answerWith(null)];
  q = await client.quote({ principal: 'p', request_id: 'z', searches: asked });
  assert.equal(q.ok, true); assert.equal('search' in q, false, 'a missing search object means off');
  // a refusal carries credits_off
  reply = [400, { ok: false, code: 'quote_exceeds_limit', credits: 80, max_credits: 75, credits_off: 40 }];
  assert.deepEqual(await client.quote({ searches: asked }), { ok: false, code: 'quote_exceeds_limit', credits: 80, max_credits: 75, credits_off: 40, status: 400 });
  // the report: version 2 only when the rows carry `searches`
  const row = { key: 'r1:anthropic-api', provider: 'anthropic-api', model: 'm', input_tokens: 5, output_tokens: 6, source: 'vendor' };
  await client.report({ reservation_id: 'rsv_1', debate_id: 'dbt_1', rows: [row] });
  assert.equal(calls.at(-1).uv, '1');
  await client.report({ reservation_id: 'rsv_1', debate_id: 'dbt_1', rows: [{ ...row, searches: 2 }, { ...row, key: 'synth', searches: null }] });
  assert.equal(calls.at(-1).uv, '2');
  assert.deepEqual(calls.at(-1).body.rows.map((r) => r.searches), [2, null]);
  srv.closeAllConnections?.(); await new Promise((r) => srv.close(r));
  // usage.json rows
  const file = join(DIR, 'usage-s.json');
  const r = (key, extra = {}) => ({ key, provider: key === 'synth' ? 'anthropic-api' : key.split(':')[1], model: 'm-1', input_tokens: 10, output_tokens: 5, source: 'vendor', ...extra });
  writeFileSync(file, JSON.stringify([r('r1:anthropic-api', { searches: 2 }), r('r1:openai-api', { searches: null }), r('synth', { searches: 0 }), r('r2:anthropic-api', { searches: -1 }), r('r2:openai-api', { searches: 1.5 }), r('r2:gemini-api', { searches: '1' }), r('r2:xai-api', { searches: 2e9 })]));
  const u = await readUsageRows(file);
  assert.deepEqual(u.rows.map((x) => [x.key, x.searches]), [['r1:anthropic-api', 2], ['r1:openai-api', null], ['synth', 0]]);
  assert.equal(u.dropped, 4);
  writeFileSync(file, JSON.stringify([r('r1:anthropic-api')]));
  assert.equal('searches' in (await readUsageRows(file)).rows[0], false, 'rows without searches stay without');
  // finalize: the additive search part
  const p = { quote_credits: 53, charged_credits: 17, rate_version: 'r.2', usage: { input_tokens: 9, output_tokens: 8, source: 'vendor' } };
  assert.deepEqual(pricingOf({ ...p, search: { searches: 5, charged_credits_search: 7.8 } }).search, { searches: 5, charged_credits_search: 7.8 });
  assert.deepEqual(pricingOf(p), p, 'no search part: exactly the old object');
  assert.deepEqual(pricingOf({ ...p, search: { searches: -1, charged_credits_search: 1 } }), p, 'an unusable search part is ignored, never a reason to drop the pricing');
  assert.deepEqual(pricingOf({ ...p, search: 'x' }), p);
  ok('the quote client: version 2 only with searches, the search object checked against what was asked (a missing one means off), credits_off on a refusal; the report is version 2 only when rows carry searches');
}

// ---- the run listener: both capabilities ----
{
  const TOKEN = `run-${randomBytes(20).toString('hex')}`;
  const planned = [];
  const runs = { known: async () => null, accept: async ({ debate_id, plan }) => ({ ok: true, existing: false, debate_id, status: 'queued', run_token: 'rt-'.padEnd(40, 'x'), plan }) };
  const external = { hasFeature: () => true, warmFeatures: async () => {} };
  const plan = async (fields, opts) => { planned.push({ fields, opts }); return { plan: { question: fields.question, providers: fields.providers }, worst: { calls: 1, tokens: 1 } }; };
  const start = (pricing) => startRunServer({ port: 0, token: TOKEN, runs, external, plan, pricing });
  const post = (srv, body) => new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const req = http.request({ host: '127.0.0.1', port: srv.port, path: '/internal/runs', method: 'POST', headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json', 'content-length': Buffer.byteLength(data) } }, (res) => {
      let raw = ''; res.on('data', (d) => { raw += d; }); res.on('end', () => resolve({ status: res.statusCode, body: JSON.parse(raw) }));
    });
    req.on('error', reject); req.end(data);
  });
  const v = vec('runbody-vectors.json');
  const run = (extra = {}) => ({ ...JSON.parse(JSON.stringify(v.base)), reservation_id: `rsv_${randomBytes(8).toString('hex')}`, debate_id: `dbt_${randomBytes(12).toString('hex')}`, ...extra });
  const off = await start({ mode: 'per_token', customer: v.customer, search: false });
  let h = await post(off, {});
  assert.deepEqual(h.body.capabilities, [PER_TOKEN_CAPABILITY], 'per_token_v1 alone: exactly the old health answer');
  let r = await post(off, run());
  assert.deepEqual([r.status, r.body.code, r.body.accepted], [400, 'invalid', false], 'the rollback race: the search fields reach a listener without the capability: definitive refusal');
  assert.equal(planned.length, 0, 'nothing planned, nothing run');
  const { max_searches: _a, cite_bytes: _b, ...noSearch } = run();
  r = await post(off, noSearch);
  assert.equal(r.status, 202, 'a body without the search fields still runs search-off');
  assert.deepEqual([planned.at(-1).opts.perToken.max_searches], [undefined]);
  await off.close();
  const on = await start({ mode: 'per_token', customer: v.customer, search: true });
  h = await post(on, {});
  assert.deepEqual(h.body.capabilities, [PER_TOKEN_CAPABILITY, SEARCH_CAPABILITY]);
  assert.equal(SEARCH_CAPABILITY, 'per_token_search_v1');
  const body = run();
  r = await post(on, body);
  assert.equal(r.status, 202);
  assert.deepEqual(planned.at(-1).opts.perToken.max_searches, body.max_searches, 'the plan gets exactly the quoted map');
  assert.equal(planned.at(-1).opts.perToken.cite_bytes, 1000);
  for (const bad of [{ cite_bytes: undefined }, { max_searches: undefined }, { max_searches: { 'anthropic-api': 3.5 } }, { cite_bytes: 20001 }, { web_search: false }]) {
    const before = planned.length;
    r = await post(on, run(bad));
    assert.deepEqual([r.status, r.body.code, r.body.accepted], [400, 'invalid', false], `refused ${JSON.stringify(bad)}`);
    assert.equal(planned.length, before);
  }
  await on.close();
  ok('the run listener advertises per_token_search_v1 next to per_token_v1 only when configured; the search fields are refused 400 invalid without it and run exactly with it');
}

console.log(`per-token search unit tests: ${n} passed`);
