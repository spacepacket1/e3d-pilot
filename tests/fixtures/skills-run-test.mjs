// Unit tests for the hosted skills run (docs/skills/phase3/plan-3c-hosted-user-skills.md, section 3 "Listener fields"): the switches and the strict run-body fields.
// No network, no model. Usage: node tests/fixtures/skills-run-test.mjs
import assert from 'node:assert/strict';
import { validateRunRequest, SKILLS_LIMITS } from '../../lib/mcp/run-server.js';
import { skillsRunFrom, readUsageRows } from '../../lib/mcp/pricing.js';
import { skillsExtra, worstCase } from '../../lib/mcp/usage.js';
import { writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

let n = 0;
const ok = (m) => { n++; console.log(`ok - skills-run: ${m}`); };
const P = ['anthropic-api', 'openai-api', 'gemini-api'];
const per = () => Object.fromEntries(P.map((p) => [p, 100]));
const base = () => ({ reservation_id: 'rsv_1', debate_id: `dbt_${'a'.repeat(24)}`, question: 'Q?', providers: P, rounds: 2, max_words: 300, max_tokens: per(), answer_bytes: per() });
const DEF = () => ({ id: 'skill.u_abc123def456.lens-a', name: 'lens-a', version: '1.0.0', definition_hash: `sha256:${'a'.repeat(64)}` }); // shape is the engine's business; only size is checked here
const seat = (target = 'anthropic-api') => ({ hook: 'seat', target, definition: DEF() });
const S2 = { hook: 'seat', target: 'gemini-api', definition: DEF() }; // a good second seat, so a refusal below is for its own reason and not for the seat count
const obs = () => ({ hook: 'observer', definition: DEF() });
const OBS = { provider: 'gemini-api', max_tokens: 150, input_bytes: 20000 };
const withSk = (extra = {}) => ({ ...base(), skill_attachments: [seat(), seat('openai-api')], skills_principal: 'u_abc123def456', skill_bytes: 4096, ...extra });
const full = { mode: 'per_token', customer: null, search: false, experts: false, skills: { seats: true, observer: true } };
const noObs = { ...full, skills: { seats: true, observer: false } };
const noSeat = { ...full, skills: { seats: false, observer: true } };
const off = { mode: 'per_token', customer: null, search: false };
const refused = (b, p = full, why = '') => { const v = validateRunRequest(b, p); assert.ok(v.error, `must be refused: ${why}`); assert.ok(!/abc123def456|lens-a/.test(v.error), `${why}: the error echoes a value from the request: ${v.error}`); return v.error; };

// the switches
assert.deepEqual(skillsRunFrom({}, { mode: 'per_token' }), { ok: true, errors: [], on: false, seats: false, observer: false });
assert.equal(skillsRunFrom({ E3D_MCP_SKILLS_RUN: '0', E3D_SKILLS_V1: 'garbage' }, { mode: 'per_token' }).ok, true, 'nothing else is read while the listener switch is off');
const ALL = { E3D_MCP_SKILLS_RUN: '1', E3D_SKILLS_V1: '1', E3D_SKILLS_HOSTED: '1', E3D_SKILLS_SEATS: '1', E3D_SKILLS_OBSERVER: '1' };
assert.deepEqual(skillsRunFrom(ALL, { mode: 'per_token' }), { ok: true, errors: [], on: true, seats: true, observer: true });
for (const k of Object.keys(ALL)) for (const bad of ['2', 'true', 'yes', ' 1']) assert.equal(skillsRunFrom({ ...ALL, [k]: bad }, { mode: 'per_token' }).ok, false, `${k}=${bad} refuses to start`);
assert.equal(skillsRunFrom(ALL, { mode: null }).ok, false, 'needs per-token pricing');
for (const k of ['E3D_SKILLS_V1', 'E3D_SKILLS_HOSTED']) { const e = { ...ALL }; delete e[k]; const r = skillsRunFrom(e, { mode: 'per_token' }); assert.equal(r.ok, true); assert.equal(r.on, false, `${k} off: skills_v1 is not advertised`); assert.equal(r.seats || r.observer, false); }
assert.deepEqual(skillsRunFrom({ ...ALL, E3D_SKILLS_SEATS: '0' }, { mode: 'per_token' }), { ok: true, errors: [], on: true, seats: false, observer: true });
assert.deepEqual(skillsRunFrom({ ...ALL, E3D_SKILLS_OBSERVER: '0' }, { mode: 'per_token' }), { ok: true, errors: [], on: true, seats: true, observer: false });
ok('the switches are strict (unset, 0 or 1), skills_v1 needs all of SKILLS_RUN, V1, HOSTED and per-token pricing');

// without the capability the fields are unknown fields (today's behaviour)
for (const p of [off, { ...off, skills: false }]) {
  assert.match(validateRunRequest(withSk(), p).error, /unknown field/);
  assert.match(validateRunRequest({ ...base(), observer: OBS }, p).error, /unknown field/);
  assert.match(validateRunRequest({ ...base(), skill_bytes: 5 }, p).error, /unknown field/);
}
ok('without skills_v1 every new field is refused as an unknown field');

// good bodies
let v = validateRunRequest(withSk(), full);
assert.ok(!v.error, v.error);
assert.equal(v.skills.attachments.length, 2); assert.equal(v.skills.observer, null); assert.equal(v.skills.principal, 'u_abc123def456'); assert.equal(v.skills.skill_bytes, 4096);
const withObs = withSk({ skill_attachments: [seat(), seat('openai-api'), obs()], observer: OBS });
const vo = validateRunRequest(withObs, full);
assert.ok(!vo.error, vo.error); assert.deepEqual(vo.skills.observer, OBS);
assert.ok(!validateRunRequest(withSk({ skill_attachments: [obs()], observer: OBS }), full).error, 'an observer-only run');
assert.ok(!validateRunRequest(withSk({ skill_attachments: [seat(), seat('openai-api'), seat('gemini-api'), obs()], observer: OBS }), full).error, 'four attachments');
assert.ok(!validateRunRequest(withSk({ skill_attachments: [seat('anthropic-api'), seat('openai-api'), obs()], observer: { ...OBS, provider: 'or-some-voice' } }), full).error, 'an OpenRouter voice may observe');
assert.ok(!validateRunRequest(withSk({ skill_bytes: 1 }), full).error && !validateRunRequest(withSk({ skill_bytes: 32768 }), full).error);
// the key covers every skill field
const keys = new Set([v.key, vo.key, validateRunRequest(withSk({ skill_bytes: 4097 }), full).key, validateRunRequest(withSk({ skills_principal: 'u_zzzzzz999999' }), full).key,
  validateRunRequest(withSk({ skill_attachments: [seat('openai-api'), seat()] }), full).key, validateRunRequest(withSk({ skill_attachments: [{ ...seat(), definition: { ...DEF(), version: '1.0.1' } }, seat('openai-api')] }), full).key,
  validateRunRequest(withSk({ skill_attachments: [seat(), seat('openai-api'), obs()], observer: { ...OBS, max_tokens: 151 } }), full).key, validateRunRequest(withSk({ skill_attachments: [seat(), seat('openai-api'), obs()], observer: { ...OBS, input_bytes: 20001 } }), full).key,
  validateRunRequest(withSk({ skill_attachments: [seat(), seat('openai-api'), obs()], observer: { ...OBS, provider: 'openai-api' } }), full).key]);
assert.equal(keys.size, 9, 'every skill field is part of the idempotency key');
assert.equal(validateRunRequest(withSk(), full).key, v.key, 'the key is stable');
ok('well formed bodies are accepted and every skill field is part of the idempotency key');

// strict refusals
refused(withSk({ skill_attachments: undefined }), full, 'attachments missing'); refused(withSk({ skills_principal: undefined }), full, 'principal missing'); refused(withSk({ skill_bytes: undefined }), full, 'bytes missing');
refused({ ...base(), observer: OBS }, full, 'observer alone');
refused(withSk({ max_tokens: undefined, answer_bytes: undefined, rounds: undefined, max_words: undefined }), full, 'without the token fields');
refused({ ...withSk(), experts: [{ id: 'skeptic', hash: `sha256:${'a'.repeat(64)}` }, { id: 'customer', hash: `sha256:${'b'.repeat(64)}` }], lens_bytes: 640 }, { ...full, experts: true }, 'experts together with skills');
refused({ ...withSk(), lens_bytes: 640 }, { ...full, experts: true }, 'lens_bytes together with skills');
for (const bad of [[], 'x', {}, null, 5, Array.from({ length: 5 }, (_, i) => seat(['anthropic-api', 'openai-api', 'gemini-api'][i] ?? 'x'))]) refused(withSk({ skill_attachments: bad }), full, `attachments ${JSON.stringify(bad)?.slice(0, 20)}`);
for (const bad of [null, 'seat', [], 7]) refused(withSk({ skill_attachments: [bad, S2] }), full, 'attachment not an object');
refused(withSk({ skill_attachments: [{ ...seat(), extra: 1 }, S2] }), full, 'unknown key in an attachment');
refused(withSk({ skill_attachments: [{ ...seat(), attachment_id: 'a1' }, S2] }), full, 'attachment_id is not a field');
refused(withSk({ skill_attachments: [{ hook: 'chat', target: 'anthropic-api', definition: DEF() }, S2] }), full, 'unknown hook'); refused(withSk({ skill_attachments: [{ hook: 5, target: 'anthropic-api', definition: DEF() }, S2] }), full, 'hook type');
refused(withSk({ skill_attachments: [{ hook: 'seat', definition: DEF() }, S2] }), full, 'seat without target');
refused(withSk({ skill_attachments: [{ ...seat(), target: 'xai-api' }, S2] }), full, 'target not in providers'); refused(withSk({ skill_attachments: [{ ...seat(), target: 5 }, S2] }), full, 'target type');
refused(withSk({ skill_attachments: [{ ...seat(), target: 'Anthropic API' }, S2] }), full, 'target form'); refused(withSk({ skill_attachments: [{ ...seat(), target: 'a\u0000b' }, S2] }), full, 'control character in a target');
refused(withSk({ skill_attachments: [seat(), seat(), S2] }), full, 'duplicate targets');
refused({ ...withSk(), providers: undefined }, full, 'seat attachments need providers');
refused(withSk({ skill_attachments: [{ ...obs(), target: 'anthropic-api' }], observer: OBS }), full, 'observer with a target');
refused(withSk({ skill_attachments: [obs(), obs()], observer: OBS }), full, 'two observers');
refused(withSk({ skill_attachments: [{ hook: 'seat', target: 'anthropic-api' }, S2] }), full, 'definition missing');
for (const bad of [null, 'x', [], 5]) refused(withSk({ skill_attachments: [{ ...seat(), definition: bad }, S2] }), full, 'definition not an object');
const big = { ...DEF(), pad: 'x'.repeat(SKILLS_LIMITS.definitionBytes) };
refused(withSk({ skill_attachments: [{ ...seat(), definition: big }, S2] }), full, 'oversized definition');
assert.ok(!validateRunRequest(withSk({ skill_attachments: [{ ...seat(), definition: { ...DEF(), pad: 'x'.repeat(SKILLS_LIMITS.definitionBytes - 300) } }, seat('openai-api')] }), full).error, 'a definition just under the cap passes this layer');
let deep = {}; for (let i = 0; i < 30000; i++) deep = { a: deep };
refused(withSk({ skill_attachments: [{ ...seat(), definition: deep }, S2] }), full, 'a definition nested far too deep must be refused, not crash');
for (const bad of ['u_abc', 'U_abc123def456', 'abc123def456', 'u_abc123def456\n', 'u_' + 'a'.repeat(37), 5, null, 'e3d']) refused(withSk({ skills_principal: bad }), full, `principal ${String(bad).slice(0, 12)}`);
for (const bad of [0, 32769, -1, 1.5, '4096', null, NaN, Infinity]) refused(withSk({ skill_bytes: bad }), full, `skill_bytes ${String(bad)}`);
// observer fields iff an observer attachment
refused(withSk({ skill_attachments: [seat(), seat('openai-api'), obs()] }), full, 'observer attachment without observer limits');
assert.ok(!validateRunRequest(withSk({ skill_attachments: [seat()] }), full).error, 'one seat skill alone is accepted: the other seats of the panel run plain'); assert.ok(!validateRunRequest(withSk({ skill_attachments: [seat(), obs()], observer: OBS }), full).error, 'one seat skill and an observer is accepted');
refused(withSk({ observer: OBS }), full, 'observer limits without an observer attachment');
for (const bad of [null, 'x', [], { ...OBS, extra: 1 }, { provider: 'gemini-api', max_tokens: 150 }, { provider: 'gemini-api', input_bytes: 20000 }, { max_tokens: 150, input_bytes: 20000 }]) refused(withSk({ skill_attachments: [seat(), seat('openai-api'), obs()], observer: bad }), full, `observer ${JSON.stringify(bad)?.slice(0, 30)}`);
for (const bad of ['claude', 'claude-cli', 'gemini', 'codex', 'anthropic-api ', 'or-', 'OR-x', 5, null]) refused(withSk({ skill_attachments: [seat(), seat('openai-api'), obs()], observer: { ...OBS, provider: bad } }), full, `observer provider ${String(bad)}`);
for (const bad of [0, 4097, 1.5, '150', -1, null]) refused(withSk({ skill_attachments: [seat(), seat('openai-api'), obs()], observer: { ...OBS, max_tokens: bad } }), full, `observer max_tokens ${String(bad)}`);
for (const bad of [0, 256001, 1.5, '20000', -1, null]) refused(withSk({ skill_attachments: [seat(), seat('openai-api'), obs()], observer: { ...OBS, input_bytes: bad } }), full, `observer input_bytes ${String(bad)}`);
for (const g of [1, 4096]) assert.ok(!validateRunRequest(withSk({ skill_attachments: [seat(), seat('openai-api'), obs()], observer: { ...OBS, max_tokens: g } }), full).error);
for (const g of [1, 256000]) assert.ok(!validateRunRequest(withSk({ skill_attachments: [seat(), seat('openai-api'), obs()], observer: { ...OBS, input_bytes: g } }), full).error);
// a hook whose switch is off
refused(withSk(), noSeat, 'a seat attachment when seats are off'); refused(withObs, noObs, 'an observer attachment when observers are off');
assert.ok(!validateRunRequest(withSk(), noObs).error && !validateRunRequest(withSk({ skill_attachments: [obs()], observer: OBS }), noSeat).error);
ok('every key, type, range and combination is checked, and no error echoes the request');

// usage rows: the observer's row (key observer:<skill>) is kept only for a run that has an observer; every other row rule is unchanged
{
  const dir = mkdtempSync(join(tmpdir(), 'skills-rows-')); const f = join(dir, 'usage.json');
  const row = (key, provider) => ({ key, provider, model: 'm1', input_tokens: 10, output_tokens: 5, source: 'vendor' });
  writeFileSync(f, JSON.stringify([row('r1:anthropic-api', 'anthropic-api'), row('synth', 'anthropic-api'), row('observer:reviewer', 'gemini-api'), row('observer:Bad Name', 'gemini-api'), row('observer:', 'gemini-api')]));
  const plain = await readUsageRows(f);
  assert.deepEqual(plain.rows.map((r) => r.key), ['r1:anthropic-api', 'synth'], 'without the option the observer row is dropped, as before');
  const withObs = await readUsageRows(f, { observer: true });
  assert.deepEqual(withObs.rows.map((r) => r.key), ['r1:anthropic-api', 'synth', 'observer:reviewer'], 'with an observer the row is kept, malformed observer keys are not');
  assert.equal(withObs.dropped, 2);
  rmSync(dir, { recursive: true, force: true });
  ok('the observer usage row is kept only for a run with an observer');
}


// review findings: nesting is bounded without recursion, and is a plain refusal (never a thrown error that becomes a retryable 503)
{
  const nest = (d) => { let o = 1; for (let i = 0; i < d; i++) o = { a: o }; return o; };
  const at = (d) => withSk({ skill_attachments: [{ ...seat(), definition: { ...DEF(), extensions: nest(d) } }, seat('openai-api')] });
  assert.doesNotThrow(() => validateRunRequest(at(3000), full), 'a very deep definition must not throw');
  refused(at(3000), full, 'nesting 3000 deep');
  refused(at(SKILLS_LIMITS.definitionDepth + 1), full, 'one level past the limit');
  assert.ok(!validateRunRequest(at(SKILLS_LIMITS.definitionDepth - 2), full).error, 'a definition within the depth limit is not refused by the listener');
  ok('nesting: bounded by a loop, 3000 levels is a refusal and not an exception, the limit is exact');
}
// the daily-budget estimate counts what hosted skills add
{
  const w = worstCase({ providers: 3, rounds: 2, maxWords: 300, questionChars: 100 });
  assert.deepEqual(skillsExtra({ skillBytes: 4096, seats: 2, rounds: 2, observer: { inputBytes: 20000, maxTokens: 150 } }), { calls: 1, tokens: 1024 * 2 * 2 + 5000 + 150 });
  assert.deepEqual(skillsExtra({ skillBytes: 4096, seats: 2, rounds: 2, observer: null }), { calls: 0, tokens: 4096 }, 'seats only: lens text per seat per round, no extra call');
  assert.deepEqual(skillsExtra({ skillBytes: 5, seats: 0, rounds: 3, observer: { inputBytes: 1, maxTokens: 1 } }), { calls: 1, tokens: 2 }, 'observer only, rounding up');
  assert.ok(w.tokens > 0);
  ok('budget estimate: lens bytes per seat per round plus the observer call, nothing for a plain run');
}
console.log(`skills-run unit tests: ${n} groups passed`);
