// Unit tests for the recap job (lib/mcp/recap-runner.js) and its route on the internal run listener (POST /internal/recaps).
// A fake adapter stands in for the model; no network beyond loopback, no key. Usage: node tests/fixtures/recap-run-test.mjs
import assert from 'node:assert/strict';
import { existsSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { createRecapRunner, recapConfigFrom, RECAP_CAPABILITY } from '../../lib/mcp/recap-runner.js';
import { startRunServer } from '../../lib/mcp/run-server.js';
import { parseRounds } from '../../lib/debate/recap.mjs';

let n = 0;
const ok = (m) => { n++; console.log(`ok - recap: ${m}`); };
const DEBATE = 'dbt_000000000000000000000001';
const TRANSCRIPT = ['## Round 1 -- alpha', '', 'SECRET-POSITION-A keep it. Fix boundaries.', '', '## Round 1 -- beta', '', 'Split billing now. Compliance.', '',
  '## Round 2 -- alpha', '', 'I hold, billing is special.', 'POSITION: Keep it, except billing.', 'status: revise', '', '## Round 2 -- beta', '', 'Holding.', 'POSITION: Split billing now.', 'status: approved', ''].join('\n');
const ROUNDS = parseRounds(TRANSCRIPT);
const REPLY = JSON.stringify({ entries: [{ round: 2, model: 'alpha', tag: 'partly_moved', reason: 'compliance', new_evidence: true }, { round: 2, model: 'beta', tag: 'held', reason: 'none given', new_evidence: false }], recap: { ended: 'Split billing.', moved: 'alpha moved partly.', open: ['when'] } });
const USAGE = 'e3d_provider_usage={"provider":"openai-api","model":"gpt-test","tokens":900,"input_tokens":800,"output_tokens":100}\n';
const req = (over = {}) => ({ requestId: 'req-1', debateId: DEBATE, provider: 'openai-api', maxTokens: 700, rounds: ROUNDS, ...over });

// ---- configuration
assert.deepEqual(recapConfigFrom({}), { ok: true, on: false, providers: [], errors: [] });
assert.equal(recapConfigFrom({ E3D_MCP_RECAP: '0' }).on, false);
assert.equal(recapConfigFrom({ E3D_MCP_RECAP: 'yes' }).ok, false);
assert.match(recapConfigFrom({ E3D_MCP_RECAP: '1' }).errors[0], /needs E3D_MCP_RECAP_PROVIDERS/);
assert.match(recapConfigFrom({ E3D_MCP_RECAP: '1', E3D_MCP_RECAP_PROVIDERS: 'claude' }).errors.join(), /no output-limit setting/);
assert.match(recapConfigFrom({ E3D_MCP_RECAP: '1', E3D_MCP_RECAP_PROVIDERS: 'openai-api,openai-api' }).errors.join(), /twice/);
assert.deepEqual(recapConfigFrom({ E3D_MCP_RECAP: '1', E3D_MCP_RECAP_PROVIDERS: 'openai-api, anthropic-api' }), { ok: true, on: true, providers: ['openai-api', 'anthropic-api'], errors: [] });
assert.equal(RECAP_CAPABILITY, 'recap_v1');
ok('configuration: off by default, a provider list is required, and only providers with an output limit may write recaps');

// ---- the runner
const before = readdirSync(tmpdir()).filter((f) => f.startsWith('e3d-recap-')).length;
let calls = [];
let behaviour = { stdout: REPLY, stderr: USAGE, error: null };
const exec = async (file, args, opts) => {
  calls.push({ file, args, opts });
  const prompt = await import('node:fs').then((fs) => fs.readFileSync(args[0], 'utf8'));
  calls[calls.length - 1].prompt = prompt;
  return { ...behaviour };
};
const logs = [];
const runner = createRecapRunner({ providersDir: '/providers', providers: ['openai-api'], log: (m) => logs.push(m), exec });

let r = await runner.run(req());
assert.equal(r.ok, true);
assert.deepEqual(r.usage, { input_tokens: 800, output_tokens: 100, model: 'gpt-test' });
assert.deepEqual(r.recap.entries.map((e) => [e.round, e.model, e.tag, e.newEvidence]), [[2, 'alpha', 'partly_moved', true], [2, 'beta', 'held', false]]);
assert.equal(calls.length, 1);
assert.equal(calls[0].file, '/providers/openai-api');
assert.equal(calls[0].opts.env.OPENAI_API_MAX_TOKENS, '700');
assert.equal(calls[0].opts.env.E3D_PROVIDER_PER_TOKEN, '1');
assert.ok(calls[0].opts.timeout > 0 && calls[0].opts.maxBuffer > 0);
assert.ok(calls[0].prompt.includes('<<<DEBATE DATA') && calls[0].prompt.includes('Keep it, except billing.'));
assert.equal(readdirSync(tmpdir()).filter((f) => f.startsWith('e3d-recap-')).length, before, 'the temporary prompt file is removed');
ok('a recap: the adapter gets the quoted limit in its own variable, the data prompt, a time and size limit; usage is read from its usage line; the temp file is gone');

assert.deepEqual(await runner.run(req()), r);
assert.equal(calls.length, 1, 'the same request id is answered from memory, with no second paid call');
assert.deepEqual(await runner.run(req({ maxTokens: 701 })), { ok: false, code: 'invalid' });
assert.equal(calls.length, 1);
ok('idempotent: a retry returns the same answer; the same id with other fields is invalid and calls nothing');

assert.deepEqual(await runner.run(req({ requestId: 'r2', provider: 'claude' })), { ok: false, code: 'not_allowed' });
for (const bad of [{ requestId: '' }, { requestId: 'a b' }, { debateId: 'dbt_x' }, { maxTokens: 10 }, { maxTokens: 99999 }, { maxTokens: 1.5 }, { rounds: null }, { rounds: { rounds: [] } },
  { rounds: parseRounds('## Round 1 -- a\n\nonly one round\n') }, { rounds: { rounds: [{ round: 1, provider: 'BAD NAME' }, { round: 2, provider: 'x' }] } }]) {
  assert.equal((await runner.run(req({ requestId: `r-${Math.random()}`, ...bad }))).code, 'invalid', JSON.stringify(bad).slice(0, 60));
}
assert.equal(calls.length, 1, 'nothing invalid reaches the model');
ok('refused before any call: a provider that is not allowed, bad ids, a limit out of range, rounds that are missing, too few or malformed');

behaviour = { stdout: 'I would rather not.', stderr: USAGE, error: null };
r = await runner.run(req({ requestId: 'u1' }));
assert.deepEqual(r, { ok: false, code: 'unusable', usage: { input_tokens: 800, output_tokens: 100, model: 'gpt-test' } });
ok('an answer that cannot be checked is unusable, and still reports what the call used so it can be settled');
behaviour = { stdout: '', stderr: `${USAGE}error: openai-api HTTP 503: down\n`, error: new Error('exit 1') };
r = await runner.run(req({ requestId: 'u2' }));
assert.deepEqual([r.ok, r.code, r.retry, r.usage.input_tokens], [false, 'unavailable', true, 800]);
behaviour = { stdout: '', stderr: 'error: openai-api HTTP 401: refused\n', error: new Error('exit 1') };
r = await runner.run(req({ requestId: 'u3' }));
assert.deepEqual([r.ok, r.code, r.retry, 'usage' in r], [false, 'unavailable', true, false]);
ok('a failed call is unavailable and retryable; usage is reported only when the adapter printed it');
assert.ok(!logs.join('\n').includes('SECRET-POSITION-A') && !logs.join('\n').includes('Keep it, except billing.'), 'logs carry ids and counts, never a position');
ok('logs hold no model text');

// ---- the route
const TOKEN = `svc-${'x'.repeat(40)}`;
behaviour = { stdout: REPLY, stderr: USAGE, error: null };
const server = await startRunServer({ port: 0, token: TOKEN, runs: {}, external: { hasFeature: () => true }, plan: async () => ({ error: 'no' }), recap: runner, log: () => {} });
const base = `http://127.0.0.1:${server.port}`;
const call = (path, { method = 'POST', body, headers = {} } = {}) => fetch(base + path, { method, headers: { 'content-type': 'application/json', authorization: `Bearer ${TOKEN}`, ...headers }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
const wire = (over = {}) => ({ request_id: 'w-1', debate_id: DEBATE, provider: 'openai-api', max_tokens: 700, rounds: ROUNDS, ...over });
let res = await call('/internal/recaps', { body: wire() });
let j = await res.json();
assert.deepEqual([res.status, j.ok, j.usage.input_tokens, j.recap.entries.length], [200, true, 800, 2]);
res = await call('/internal/recaps', { headers: { authorization: 'Bearer wrong' }, body: wire({ request_id: 'w-2' }) });
assert.equal(res.status, 401);
res = await call('/internal/recaps', { body: { ...wire({ request_id: 'w-3' }), extra: 1 } });
assert.equal(res.status, 400);
res = await call('/internal/recaps', { body: wire({ request_id: 'w-4', provider: 'claude' }) });
assert.deepEqual([res.status, (await res.json()).code], [403, 'not_allowed']);
res = await call('/internal/recaps', { method: 'GET' });
assert.equal(res.status, 405);
res = await call('/internal/recaps', { body: wire({ request_id: 'w-5', max_tokens: 5 }) });
assert.equal(res.status, 400);
behaviour = { stdout: 'nope', stderr: USAGE, error: null };
res = await call('/internal/recaps', { body: wire({ request_id: 'w-6' }) });
j = await res.json();
assert.deepEqual([res.status, j.ok, j.code, j.usage.output_tokens], [200, false, 'unusable', 100]);
behaviour = { stdout: '', stderr: '', error: new Error('x') };
res = await call('/internal/recaps', { body: wire({ request_id: 'w-7' }) });
j = await res.json();
assert.deepEqual([res.status, j.code, j.retry], [503, 'unavailable', true]);
res = await call('/internal/runs', { body: {} });
assert.deepEqual((await res.json()).capabilities, [RECAP_CAPABILITY], 'recap_v1 is advertised in the health answer');
await server.close();
ok('route: needs the service token, refuses unknown fields, a provider that is not allowed and a bad limit, answers unusable with its usage, 503 with retry, and advertises recap_v1');

const off = await startRunServer({ port: 0, token: TOKEN, runs: {}, external: { hasFeature: () => true }, plan: async () => ({ error: 'no' }), log: () => {} });
res = await fetch(`http://127.0.0.1:${off.port}/internal/recaps`, { method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${TOKEN}` }, body: '{}' });
assert.equal(res.status, 404);
res = await fetch(`http://127.0.0.1:${off.port}/internal/runs`, { method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${TOKEN}` }, body: '{}' });
assert.equal('capabilities' in (await res.json()), false, 'no capability without the feature');
await off.close();
ok('without E3D_MCP_RECAP the route is a 404 and nothing is advertised');

console.log(`recap run-server unit tests: ${n} passed`);
