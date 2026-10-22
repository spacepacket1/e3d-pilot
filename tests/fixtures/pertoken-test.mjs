// Unit tests for token pricing (per_token_v1): lib/debate/token-pricing.mjs (truncation, usage rows, limits), lib/mcp/pricing.js
// (config, run fields, plan limits, the quote and usage clients) and the run listener's capability and field handling over
// real HTTP on loopback. Usage: node tests/fixtures/pertoken-test.mjs <scratch dir>
import assert from 'node:assert/strict';
import http from 'node:http';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';
import { truncateBytes, limitsFromEnv, vendorUsage, reachedVendor, usageRow } from '../../lib/debate/token-pricing.mjs';
import { validatePricingConfig, validatePerTokenFields, limitsForPlan, pricedError, debateEnvFor, readUsageRows, createPricingClient, PER_TOKEN_CAPABILITY } from '../../lib/mcp/pricing.js';
import { pricingOf } from '../../lib/mcp/external-auth.js';
import { startRunServer } from '../../lib/mcp/run-server.js';

const DIR = process.argv[2];
if (!DIR) { console.error('usage: pertoken-test.mjs <scratch dir>'); process.exit(2); }
mkdirSync(DIR, { recursive: true });
let n = 0;
const ok = (m) => { n++; console.log(`ok - token pricing: ${m}`); };
const bytes = (s) => Buffer.byteLength(s, 'utf8');

// ---- truncation: at most the limit in UTF-8 bytes, on a character boundary ----
{
  const samples = ['plain ascii text that is long enough', '日本語のテスト回答です。これはとても長い回答ですね。', 'emoji 😀😀😀😀😀 and 🧑‍💻 family 👨‍👩‍👧', 'é'.repeat(50), 'mixed ascii 日本語 😀 é'.repeat(5)];
  for (const s of samples) {
    for (let max = 1; max <= bytes(s) + 2; max++) {
      const t = truncateBytes(s, max);
      assert.ok(bytes(t) <= max, `never more than ${max} bytes (got ${bytes(t)})`);
      assert.ok(s.startsWith(t), 'a prefix of the answer');
      assert.ok(!t.includes('�') && !/[\uD800-\uDBFF]$/.test(t) && !/^[\uDC00-\uDFFF]/.test(t), 'never half a character');
      // greedy: one more character would not have fitted
      const next = [...s.slice(t.length)][0];
      if (next !== undefined) assert.ok(bytes(t) + bytes(next) > max, 'as much as fits');
    }
    assert.equal(truncateBytes(s, bytes(s)), s, 'an answer within the limit is untouched');
  }
  for (let i = 0; i < 300; i++) { // random code points
    const s = Array.from({ length: 1 + (i % 40) }, () => String.fromCodePoint([0x20 + Math.floor(Math.random() * 90), 0xe9, 0x3042, 0x4e00 + Math.floor(Math.random() * 500), 0x1f600 + Math.floor(Math.random() * 60)][Math.floor(Math.random() * 5)])).join('');
    const max = 1 + Math.floor(Math.random() * 80);
    const t = truncateBytes(s, max);
    assert.ok(bytes(t) <= max && s.startsWith(t) && Buffer.from(t, 'utf8').toString('utf8') === t);
  }
  ok('answers are cut to at most the byte limit on a character boundary (CJK, emoji, combining, random)');
}

// ---- limits from the environment ----
{
  const e = (o) => limitsFromEnv(o, ['anthropic-api', 'openai-api']);
  assert.deepEqual(e({}), { perToken: false, maxTokens: null, answerBytes: null });
  assert.deepEqual(e({ E3D_DEBATE_MAX_TOKENS: '{"anthropic-api":100,"openai-api":200}' }), { perToken: true, maxTokens: { 'anthropic-api': 100, 'openai-api': 200 }, answerBytes: null });
  assert.deepEqual(e({ E3D_DEBATE_ANSWER_BYTES_MAX: '{"anthropic-api":5,"openai-api":6}' }), { perToken: false, maxTokens: null, answerBytes: { 'anthropic-api': 5, 'openai-api': 6 } });
  for (const bad of ['{"anthropic-api":100}', '{"anthropic-api":0,"openai-api":1}', '{"anthropic-api":1.5,"openai-api":1}', '[1]', 'nope', '{"anthropic-api":999999999,"openai-api":1}', '{}']) {
    assert.ok(e({ E3D_DEBATE_MAX_TOKENS: bad }).error, `refused: ${bad}`);
  }
  assert.ok(limitsFromEnv({ E3D_DEBATE_MAX_TOKENS: '{"claude":100,"openai-api":1}' }, ['claude', 'openai-api']).error, 'per-token pricing is API providers only');
  assert.ok(e({ E3D_DEBATE_ANSWER_BYTES_MAX: '{"anthropic-api":5}' }).error, 'a limit for every provider');
  ok('E3D_DEBATE_MAX_TOKENS and E3D_DEBATE_ANSWER_BYTES_MAX are validated; unset means today\'s behaviour');
}

// ---- usage rows ----
{
  const f = (name, text) => { const p = join(DIR, name); writeFileSync(p, text); return p; };
  const prompt = f('prompt.md', 'a prompt of 一二三 characters'); // 18 + 9 = 27 bytes... computed below
  const out = f('out.md', 'the answer 日本');
  const line = (o) => `e3d_provider_usage=${JSON.stringify(o)}\n`;
  const row = (stderr, status, extra = {}) => usageRow({ key: 'r1:openai-api', provider: 'openai-api', promptFile: prompt, outFile: out, stderrFile: f('e.txt', stderr), status, maxTokens: 456, ...extra });
  // vendor
  assert.deepEqual(row(line({ provider: 'openai-api', model: 'gpt-x-2026', tokens: 30, input_tokens: 13, output_tokens: 17 }), 0), { key: 'r1:openai-api', provider: 'openai-api', model: 'gpt-x-2026', input_tokens: 13, output_tokens: 17, source: 'vendor' });
  assert.equal(row(`noise\n${line({ model: 'a', input_tokens: 1, output_tokens: 2 })}${line({ model: 'b', input_tokens: 3, output_tokens: 4 })}`, 0).model, 'b', 'the last usage line');
  // a call that failed after the vendor returned usage still has its vendor row
  assert.equal(row(`${line({ model: 'm', input_tokens: 5, output_tokens: 6 })}error: provider token ceiling exceeded\n`, 1).source, 'vendor');
  // missing or unparseable usage: bytes
  const b1 = row('', 0);
  assert.deepEqual([b1.source, b1.input_tokens, b1.output_tokens, b1.model], ['bytes', bytes('a prompt of 一二三 characters'), bytes('the answer 日本'), 'unspecified']);
  assert.equal(row('e3d_provider_usage={broken\n', 0).source, 'bytes');
  assert.equal(row(line({ model: 'm', tokens: 9, usage: null, input_tokens: null, output_tokens: null }), 0).source, 'bytes');
  assert.equal(row(line({ model: 'gpt-null-usage', input_tokens: null, output_tokens: null }), 0).model, 'gpt-null-usage', 'the model id survives into the estimate');
  assert.equal(row(line({ model: 'm', input_tokens: -1, output_tokens: 2 }), 0).source, 'bytes');
  assert.equal(row(line({ model: 'm', input_tokens: 1.5, output_tokens: 2 }), 0).source, 'bytes');
  // a lost response: max_tokens
  const lost = row('error: openai-api request failed (curl exit 28): timed out\n', 1);
  assert.deepEqual([lost.source, lost.output_tokens, lost.input_tokens], ['bytes', 456, bytes('a prompt of 一二三 characters')]);
  assert.equal(row('error: openai-api returned no message content\n', 1).output_tokens, 456, 'a 200 with no content was billed');
  assert.equal(row('', 'inflight').output_tokens, 456, 'a call under way when the debate was stopped');
  // never reached the vendor: no row
  assert.equal(row('error: openai-api HTTP 429: Rate limit exceeded\n', 1), null);
  assert.equal(row('error: openai-api HTTP 500\n', 1), null);
  assert.equal(row('error: openai-api request failed (curl exit 7): connect refused\n', 1), null);
  assert.equal(row('error: openai-api is not configured (OPENAI_API_KEY)\n', 3), null);
  assert.equal(reachedVendor({ status: 1, stderr: 'curl exit 56' }), true);
  assert.equal(vendorUsage(''), null);
  ok('one row per attempted call: vendor counts, bytes estimates (never an undercount), and no row for a call that never reached the vendor');
}

// ---- configuration and run fields ----
{
  assert.equal(validatePricingConfig({}).mode, null);
  assert.deepEqual(validatePricingConfig({ E3D_MCP_PRICING: 'per_token', E3D_MCP_AUTH_URL: 'http://127.0.0.1:1', E3D_MCP_CUSTOMER_LIMITS: 'rounds=2,max_words=300' }, { http: true }), { ok: true, errors: [], mode: 'per_token' });
  assert.equal(validatePricingConfig({ E3D_MCP_PRICING: 'per_debate' }).ok, false);
  assert.equal(validatePricingConfig({ E3D_MCP_PRICING: 'per_token', E3D_MCP_AUTH_URL: 'http://x', E3D_MCP_CUSTOMER_LIMITS: 'rounds=2' }, { http: false }).ok, false, 'hosted mode only');
  assert.equal(validatePricingConfig({ E3D_MCP_PRICING: 'per_token' }, { http: true, hook: false }).ok, false, 'needs the hook');
  assert.equal(validatePricingConfig({ E3D_MCP_PRICING: 'per_token', E3D_MCP_AUTH_URL: 'http://x' }, { http: true }).ok, false, 'the customer limits must be stated');

  const good = { rounds: 2, max_words: 300, max_tokens: { 'anthropic-api': 728, 'openai-api': 800 }, answer_bytes: { 'anthropic-api': 2000, 'openai-api': 2400 } };
  const ctx = { mode: 'per_token', customer: { rounds: 2, max_words: 300 } };
  assert.deepEqual(validatePerTokenFields({}, ctx), { absent: true });
  assert.deepEqual(validatePerTokenFields({ question: 'x', providers: ['a'] }, { mode: null, customer: null }), { absent: true }, 'no new field: nothing changes, whatever the mode');
  assert.deepEqual(validatePerTokenFields({ rounds: 5, max_words: 999 }, ctx), { absent: true }, 'rounds and max_words alone are the older optional fields: clamped as before, never per-token');
  assert.deepEqual(validatePerTokenFields({ rounds: 5, max_words: 999 }, { mode: null, customer: null }), { absent: true });
  assert.deepEqual(validatePerTokenFields(good, ctx), good);
  assert.ok(validatePerTokenFields(good, { mode: null, customer: null }).error, 'a listener that never advertised per_token_v1 refuses the fields');
  for (const k of Object.keys(good)) { const { [k]: _, ...rest } = good; assert.ok(validatePerTokenFields(rest, ctx).error, `all four together (missing ${k})`); }
  assert.ok(validatePerTokenFields({ ...good, rounds: 3 }, ctx).error, 'rounds above the customer limit are refused, never clamped');
  assert.ok(validatePerTokenFields({ ...good, max_words: 301 }, ctx).error, 'max_words above the customer limit are refused, never clamped');
  assert.equal(validatePerTokenFields({ ...good, rounds: 1, max_words: 100 }, ctx).rounds, 1, 'lower values are honoured as sent');
  for (const bad of [{ rounds: 0 }, { rounds: 11 }, { rounds: 1.5 }, { rounds: '2' }, { max_words: 0 }, { max_words: 10001 }, { max_tokens: {} }, { max_tokens: { 'openai-api': 0, 'anthropic-api': 1 } }, { max_tokens: { 'anthropic-api': 1, 'openai-api': 2.5 } },
    { max_tokens: { 'anthropic-api': 200001, 'openai-api': 1 } }, { answer_bytes: { 'anthropic-api': 3200001, 'openai-api': 1 } }, { max_tokens: [1] }, { answer_bytes: { 'anthropic-api': 1 } }, { max_tokens: { 'Bad Name': 1, 'openai-api': 1 } }]) {
    assert.ok(validatePerTokenFields({ ...good, ...bad }, { mode: 'per_token', customer: { rounds: 10, max_words: 10000 } }).error, `refused: ${JSON.stringify(bad)}`);
  }
  // plan limits
  assert.deepEqual(limitsForPlan(good, ['anthropic-api', 'openai-api', 'anthropic-api']), { maxTokens: good.max_tokens, answerBytes: good.answer_bytes });
  assert.ok(limitsForPlan({ ...good, max_tokens: { 'anthropic-api': 1, 'gemini-api': 1 }, answer_bytes: { 'anthropic-api': 1, 'gemini-api': 1 } }, ['anthropic-api', 'openai-api']).error, 'a provider without limits');
  assert.ok(limitsForPlan(good, ['claude', 'openai-api']).error, 'CLI voices have no rate');
  const xai = { ...good, max_tokens: { 'anthropic-api': 1, 'xai-api': 1 }, answer_bytes: { 'anthropic-api': 1, 'xai-api': 1 } };
  assert.match(limitsForPlan(xai, ['anthropic-api', 'xai-api'], { env: {} }).error, /reasoning tokens are not capped/);
  assert.ok(limitsForPlan(xai, ['anthropic-api', 'xai-api'], { env: { E3D_MCP_PER_TOKEN_ALLOW_XAI: '1' } }).maxTokens, 'xAI only when the operator accepted it');
  assert.equal(pricedError(['gemini-api', 'openai-api'], { env: {} }), null);
  assert.deepEqual(debateEnvFor({ maxTokens: { a: 1 }, answerBytes: { a: 2 } }), { E3D_DEBATE_MAX_TOKENS: '{"a":1}', E3D_DEBATE_ANSWER_BYTES_MAX: '{"a":2}' });
  assert.deepEqual(debateEnvFor(null), {});
  ok('config, the four run fields (all or none, exact, never clamped), and the limits a plan must carry');
}

// ---- usage.json and the finalize pricing object ----
{
  const file = join(DIR, 'usage.json');
  const r = (key, extra = {}) => ({ key, provider: key === 'synth' ? 'anthropic-api' : key.split(':')[1], model: 'm-1', input_tokens: 10, output_tokens: 5, source: 'vendor', ...extra });
  writeFileSync(file, JSON.stringify([r('r1:anthropic-api'), r('r1:openai-api', { source: 'bytes' }), r('synth'), r('r1:anthropic-api'), r('r9:UPPER'), r('r2:openai-api', { input_tokens: -1 }), { nope: 1 }, r('r2:anthropic-api', { model: 'has space' }), r('r2:gemini-api', { source: 'estimate' })]));
  const u = await readUsageRows(file);
  assert.deepEqual(u.rows.map((x) => x.key), ['r1:anthropic-api', 'r1:openai-api', 'synth']);
  assert.equal(u.dropped, 6);
  assert.deepEqual(await readUsageRows(join(DIR, 'missing.json')), { rows: [], dropped: 0, present: false });
  writeFileSync(file, '[]');
  assert.deepEqual(await readUsageRows(file), { rows: [], dropped: 0, present: true });
  const p = { quote_credits: 19, charged_credits: 5, rate_version: '2026-11-01.1', usage: { input_tokens: 9123, output_tokens: 2210, source: 'vendor' } };
  assert.deepEqual(pricingOf(p), p);
  assert.equal(pricingOf({ ...p, usage: { ...p.usage, source: 'v1_estimate' } }), null);
  assert.equal(pricingOf({ ...p, charged_credits: -1 }), null);
  assert.equal(pricingOf(undefined), null);
  assert.deepEqual(pricingOf({ ...p, extra: 'dropped' }), p);
  ok('usage.json is read defensively; only a well-formed pricing object is passed on from finalize');
}

// ---- the quote and usage clients (a fake billing service) ----
{
  const calls = [];
  let mode = 'ok';
  let answers = [];
  const srv = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (d) => { raw += d; });
    req.on('end', () => {
      calls.push({ url: req.url, auth: req.headers.authorization, qv: req.headers['x-e3d-pricing-version'], uv: req.headers['x-e3d-usage-version'], body: JSON.parse(raw || '{}') });
      const send = (c, b) => { res.writeHead(c, { 'content-type': 'application/json' }); res.end(JSON.stringify(b)); };
      if (answers.length) { const [c, b] = answers.shift(); return send(c, b); }
      if (req.url === '/pricing/v1/quote') return send(200, { ok: true, credits: 19, rate_version: 'r.1', max_credits: 100, max_tokens: { 'anthropic-api': 728 }, answer_bytes: { 'anthropic-api': 2000 } });
      if (req.url === '/usage/v1/report') return send(200, { ok: true, replay: false });
      send(404, {});
    });
  });
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  const env = { E3D_MCP_AUTH_URL: `http://127.0.0.1:${srv.address().port}`, E3D_MCP_AUTH_SERVICE_TOKEN: `svc-${'k'.repeat(30)}` };
  const logs = [];
  const client = createPricingClient({ env, log: (m) => logs.push(m), sleep: async () => {}, reportAttempts: 4 });
  const q = await client.quote({ principal: 'pk_1', request_id: 'x' });
  assert.deepEqual([q.ok, q.credits, q.max_tokens['anthropic-api']], [true, 19, 728]);
  assert.deepEqual([calls[0].url, calls[0].auth, calls[0].qv], ['/pricing/v1/quote', `Bearer ${env.E3D_MCP_AUTH_SERVICE_TOKEN}`, '1']);
  answers = [[400, { ok: false, code: 'unknown_model_rate' }]];
  assert.deepEqual(await client.quote({}), { ok: false, code: 'unknown_model_rate', status: 400 });
  answers = [[400, { ok: false, code: 'quote_exceeds_limit', credits: 120, max_credits: 100 }]];
  assert.deepEqual(await client.quote({}), { ok: false, code: 'quote_exceeds_limit', credits: 120, max_credits: 100, status: 400 });
  answers = [[503, { ok: false }]];
  assert.equal((await client.quote({})).retry, true);
  answers = [[401, { error: 'unauthorized' }]];
  assert.equal((await client.quote({})).retry, true, 'a configuration error is not a price');
  // the report: retried on 5xx, 429 and transport failures, with the same body
  const before = calls.length;
  answers = [[503, {}], [429, {}], [200, { ok: true, replay: true }]];
  assert.deepEqual(await client.report({ reservation_id: 'rsv_1', debate_id: 'dbt_1', rows: [] }), { ok: true, replay: true });
  const sent = calls.slice(before);
  assert.equal(sent.length, 3);
  assert.ok(sent.every((c) => c.url === '/usage/v1/report' && c.uv === '1' && JSON.stringify(c.body) === JSON.stringify(sent[0].body)), 'the same body every time, with the usage version header');
  answers = [[400, { ok: false, code: 'invalid', why: 'unknown_key' }]];
  assert.deepEqual(await client.report({ rows: [] }), { ok: false, definitive: true, status: 400, code: 'invalid', why: 'unknown_key' });
  answers = [[409, { ok: false, code: 'closed' }]];
  assert.equal((await client.report({ rows: [] })).code, 'closed');
  answers = [[503, {}], [503, {}], [503, {}], [503, {}], [200, { ok: true }]];
  const gaveUp = await client.report({ rows: [] });
  assert.equal(gaveUp.ok, false, 'gives up after its attempts (the caller still finalizes)');
  srv.closeAllConnections?.(); await new Promise((r) => srv.close(r));
  const dead = await client.report({ rows: [] });
  assert.equal(dead.ok, false);
  assert.ok(!logs.join('\n').includes(env.E3D_MCP_AUTH_SERVICE_TOKEN), 'the service token is never logged');
  ok('the quote client (answers, refusals) and the usage-report client (versioned headers, retries with one body, definitive 400 and 409)');
}

// ---- the run listener: capability and fields ----
{
  const RUN_TOKEN = `run-${randomBytes(20).toString('hex')}`;
  const planned = [];
  let accepted = [];
  const runs = {
    known: async () => null,
    accept: async ({ debate_id, plan }) => { accepted.push({ debate_id, plan }); return { ok: true, existing: false, debate_id, status: 'queued', run_token: 'rt-'.padEnd(40, 'x') }; },
  };
  const external = { hasFeature: () => true, warmFeatures: async () => {} };
  const plan = async (fields, opts) => { planned.push({ fields, opts }); return { plan: { question: fields.question, providers: fields.providers ?? ['anthropic-api', 'openai-api'], perToken: opts.perToken ? { ok: true } : undefined }, worst: { calls: 1, tokens: 1 } }; };
  const start = (pricing) => startRunServer({ port: 0, token: RUN_TOKEN, runs, external, plan, pricing });
  const post = (srv, body) => new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const req = http.request({ host: '127.0.0.1', port: srv.port, path: '/internal/runs', method: 'POST', headers: { authorization: `Bearer ${RUN_TOKEN}`, 'content-type': 'application/json', 'content-length': Buffer.byteLength(data) } }, (res) => {
      let raw = ''; res.on('data', (d) => { raw += d; }); res.on('end', () => resolve({ status: res.statusCode, body: JSON.parse(raw) }));
    });
    req.on('error', reject); req.end(data);
  });
  const run = (extra = {}) => ({ reservation_id: `rsv_${randomBytes(4).toString('hex')}`, debate_id: `dbt_${randomBytes(12).toString('hex')}`, question: 'JSON or SQLite?', providers: ['anthropic-api', 'openai-api'], ...extra });
  const fields = { rounds: 2, max_words: 300, max_tokens: { 'anthropic-api': 728, 'openai-api': 800 }, answer_bytes: { 'anthropic-api': 2000, 'openai-api': 2400 } };

  const old = await start({ mode: null, customer: null });
  let h = await post(old, {});
  assert.deepEqual([h.status, h.body.code, h.body.capabilities], [400, 'invalid', undefined], 'no capability without E3D_MCP_PRICING=per_token');
  const a = await post(old, run());
  assert.equal(a.status, 202, 'an older billing keeps working');
  assert.equal(planned.at(-1).opts.perToken, null);
  const refused = await post(old, run(fields));
  assert.deepEqual([refused.status, refused.body.code], [400, 'invalid'], 'fields sent to a listener that never advertised the capability are refused, not honoured');
  await old.close();

  const srv = await start({ mode: 'per_token', customer: { rounds: 2, max_words: 300 } });
  h = await post(srv, {});
  assert.deepEqual([h.status, h.body.ok, h.body.code, h.body.capabilities], [400, false, 'invalid', [PER_TOKEN_CAPABILITY]]);
  assert.equal(PER_TOKEN_CAPABILITY, 'per_token_v1');
  const noFields = await post(srv, run());
  assert.equal(noFields.status, 202, 'under per_token, a body without the fields (billing rolled back to per_debate) still runs as before');
  assert.equal(planned.at(-1).opts.perToken, null);
  const good = run(fields);
  const g = await post(srv, good);
  assert.equal(g.status, 202);
  assert.deepEqual(planned.at(-1).opts.perToken, fields, 'the plan gets exactly the fields that were sent');
  assert.deepEqual(planned.at(-1).fields.max_tokens, fields.max_tokens);
  for (const bad of [{ rounds: 3 }, { max_words: 301 }, { max_tokens: { 'anthropic-api': 0, 'openai-api': 1 } }, { answer_bytes: { 'anthropic-api': 5 } }, { rounds: undefined }, { max_tokens: undefined }]) {
    const before = planned.length;
    const r = await post(srv, run({ ...fields, ...bad }));
    assert.deepEqual([r.status, r.body.code, r.body.accepted], [400, 'invalid', false], `refused: ${JSON.stringify(bad)}`);
    assert.equal(planned.length, before, 'nothing is planned or run');
  }
  const unknown = await post(srv, run({ ...fields, max_token: 5 }));
  assert.equal(unknown.status, 400, 'an unknown field is still refused');
  await srv.close();
  ok('the run listener advertises per_token_v1 only with E3D_MCP_PRICING=per_token, honours the four fields exactly or refuses (400 invalid), and is unchanged without them');
}

console.log(`token pricing unit tests: ${n} passed`);
