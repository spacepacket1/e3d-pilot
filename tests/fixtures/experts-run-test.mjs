// Unit tests for the hosted experts run (docs/specs/experts-phase2b1-hosted-lenses-spec.md section 2): the strict run-body fields, the
// E3D_MCP_EXPERTS_RUN switch, and the guard that every built-in lens block fits the proposed lensBytesMax. No network, no model.
// Usage: node tests/fixtures/experts-run-test.mjs
import assert from 'node:assert/strict';
import { validateRunRequest, EXPERTS_LIMITS } from '../../lib/mcp/run-server.js';
import { expertsRunFrom } from '../../lib/mcp/pricing.js';
import { loadExperts } from '../../lib/debate/specialists.mjs';
import { lensBlock } from '../../lib/debate/specialists-plan.mjs';

let n = 0;
const ok = (m) => { n++; console.log(`ok - experts-run: ${m}`); };
const H = (c) => `sha256:${c.repeat(64)}`;
const P4 = ['anthropic-api', 'openai-api', 'gemini-api', 'xai-api'];
const per = (o = {}) => Object.fromEntries(P4.map((p) => [p, o[p] ?? 100]));
const base = () => ({ reservation_id: 'rsv_1', debate_id: `dbt_${'a'.repeat(24)}`, question: 'Q?', providers: P4, rounds: 2, max_words: 300, max_tokens: per(), answer_bytes: per() });
const withEx = (extra = {}) => ({ ...base(), experts: [{ id: 'skeptic', hash: H('a') }, { id: 'customer', hash: H('b') }], lens_bytes: 640, ...extra });
const on = { mode: 'per_token', customer: null, search: false, experts: true };
const off = { mode: 'per_token', customer: null, search: false };

// the switch
assert.deepEqual(expertsRunFrom({}, { mode: 'per_token' }), { ok: true, errors: [], on: false });
assert.equal(expertsRunFrom({ E3D_MCP_EXPERTS_RUN: '0' }, { mode: null }).on, false);
assert.equal(expertsRunFrom({ E3D_MCP_EXPERTS_RUN: '1' }, { mode: 'per_token' }).on, true);
for (const bad of ['2', 'true', 'yes']) assert.equal(expertsRunFrom({ E3D_MCP_EXPERTS_RUN: bad }, { mode: 'per_token' }).ok, false, `value ${bad} refuses to start`);
assert.equal(expertsRunFrom({ E3D_MCP_EXPERTS_RUN: '1' }, { mode: null }).ok, false, 'needs per-token pricing');
ok('E3D_MCP_EXPERTS_RUN is unset, 0 or 1 (1 needs per-token pricing); anything else refuses');

// valid bodies
let v = validateRunRequest(withEx(), on);
assert.ok(!v.error, v.error);
assert.deepEqual(v.experts, { list: [{ id: 'skeptic', hash: H('a') }, { id: 'customer', hash: H('b') }], lens_bytes: 640 });
assert.ok(v.fields.experts && v.fields.lens_bytes === 640, 'both fields are in the idempotency key');
const w = validateRunRequest(withEx({ lens_bytes: 641 }), on);
assert.notEqual(w.key, v.key, 'lens_bytes is part of the key');
assert.notEqual(validateRunRequest(withEx({ experts: [{ id: 'customer', hash: H('b') }, { id: 'skeptic', hash: H('a') }] }), on).key, v.key, 'the order of experts is part of the key');
const many = Array.from({ length: 16 }, (_, i) => ({ id: `e${i}`, hash: H('c') }));
assert.ok(!validateRunRequest(withEx({ experts: many }), on).error, '16 experts are well formed');
assert.ok(!validateRunRequest(withEx({ lens_bytes: 1 }), on).error && !validateRunRequest(withEx({ lens_bytes: 4096 }), on).error);
ok('a well formed body is accepted; experts and lens_bytes are part of the idempotency key');

// a body without them is the same with or without the capability (flag off: nothing changes)
const a = validateRunRequest(base(), on); const b = validateRunRequest(base(), off);
assert.equal(a.key, b.key); assert.equal(a.experts, null);
assert.deepEqual(Object.keys(a.fields), Object.keys(b.fields));
ok('a body without experts has the same fields and key with and without the capability');

// without the capability both fields are refused like any unknown field
for (const [label, body] of [['both', withEx()], ['experts only', { ...base(), experts: withEx().experts }], ['lens_bytes only', { ...base(), lens_bytes: 640 }]]) {
  for (const p of [off, undefined]) { const r = p ? validateRunRequest(body, p) : validateRunRequest(body); assert.ok(r.error && /unknown field/.test(r.error), `${label}: ${r.error}`); }
}
ok('without the capability experts and lens_bytes are refused (unknown field)');

// strict validation, each a 400 reason and never an echo of the value
const refuse = (label, body, re) => { const r = validateRunRequest(body, on); assert.ok(r.error, `${label} must be refused`); if (re) assert.match(r.error, re, label); assert.ok(!/SECRETVALUE/.test(r.error), `${label}: the value is not echoed`); };
refuse('experts alone', { ...base(), experts: withEx().experts }, /sent together/);
refuse('lens_bytes alone', { ...base(), lens_bytes: 640 }, /sent together/);
const { max_tokens, answer_bytes, ...noTok } = withEx();
refuse('no token fields', noTok, /need the token fields/);
refuse('one expert', withEx({ experts: [{ id: 'skeptic', hash: H('a') }] }), /2 to 16/);
refuse('zero experts', withEx({ experts: [] }), /2 to 16/);
refuse('17 experts', withEx({ experts: [...many, { id: 'extra', hash: H('c') }] }), /2 to 16/);
refuse('not an array', withEx({ experts: 'skeptic,customer' }), /2 to 16/);
refuse('object instead of array', withEx({ experts: { skeptic: H('a') } }), /2 to 16/);
refuse('duplicate id', withEx({ experts: [{ id: 'skeptic', hash: H('a') }, { id: 'skeptic', hash: H('b') }] }), /twice/);
for (const id of ['Skeptic', 'a_b', 'a b', '-a', 'a-', 'a--b', '', 5, null, 'x'.repeat(65), 'SECRETVALUE/../x']) refuse(`id ${JSON.stringify(id)}`, withEx({ experts: [{ id, hash: H('a') }, { id: 'customer', hash: H('b') }] }), /id is malformed/);
for (const hash of ['sha256:abc', H('A'), `md5:${'a'.repeat(64)}`, 'a'.repeat(64), `${H('a')}0`, 7, null]) refuse(`hash ${String(hash).slice(0, 12)}`, withEx({ experts: [{ id: 'skeptic', hash }, { id: 'customer', hash: H('b') }] }), /hash must be/);
refuse('unknown key in an expert', withEx({ experts: [{ id: 'skeptic', hash: H('a'), lens: 'SECRETVALUE' }, { id: 'customer', hash: H('b') }] }), /only an id and a hash/);
refuse('a string expert', withEx({ experts: ['skeptic', 'customer'] }), /object with only/);
refuse('an array expert', withEx({ experts: [[], []] }), /object with only/);
for (const lb of [0, -1, 4097, 1.5, '640', null, 1e9]) refuse(`lens_bytes ${JSON.stringify(lb)}`, withEx({ lens_bytes: lb }), /lens_bytes must be|sent together/);
refuse('an unknown extra field', withEx({ lens: 'SECRETVALUE' }), /unknown field/);
assert.deepEqual([EXPERTS_LIMITS.min, EXPERTS_LIMITS.max, EXPERTS_LIMITS.lensBytes], [2, 16, [1, 4096]]);
ok('bad ids, hashes, duplicates, counts (2 to 16), lens_bytes (1 to 4096) and unknown keys are all refused, never echoed');

// the guard: every built-in lens block is at most the proposed lensBytesMax
const LENS_BYTES_MAX = 640;
const { experts } = loadExperts({ tiers: [{ name: 'built-in', dir: new URL('../../lib/specialists', import.meta.url).pathname }] });
assert.ok(experts.length >= 8, `all eight built-ins load (${experts.length})`);
for (const e of experts) assert.ok(Buffer.byteLength(lensBlock(e)) <= LENS_BYTES_MAX, `${e.name}: ${Buffer.byteLength(lensBlock(e))} bytes is over ${LENS_BYTES_MAX}`);
ok(`every built-in lens block is at most ${LENS_BYTES_MAX} bytes (largest: ${Math.max(...experts.map((e) => Buffer.byteLength(lensBlock(e))))})`);

console.log(`experts-run unit tests: ${n} groups passed`);
