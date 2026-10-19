// Fails if docs/external-auth.md, docs/external-auth/*.schema.json, lib/mcp/external-auth.js (SCHEMAS), the stub
// and the conformance vectors disagree.   node extauth-drift.mjs [--doc <file>] [--schemas <dir>]
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SCHEMAS, REFUSAL_CODES, DEBATE_CODES, DEBATE_STATUS, FEATURES, schemaOf } from '../../lib/mcp/external-auth.js';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const arg = (name, dflt) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : dflt; };
const docFile = arg('--doc', join(ROOT, 'docs', 'external-auth.md'));
const schemaDir = arg('--schemas', join(ROOT, 'docs', 'external-auth'));
const doc = readFileSync(docFile, 'utf8');
const stub = readFileSync(join(ROOT, 'examples', 'external-auth-stub.js'), 'utf8');
const coverage = new Set(JSON.parse(execFileSync(process.execPath, [join(ROOT, 'examples', 'external-auth-conformance.js'), '--list'], { encoding: 'utf8' })).covers);
const section = (name) => {
  const m = new RegExp(`<!-- conformance:${name} -->([\\s\\S]*?)<!-- /conformance:${name} -->`).exec(doc);
  assert.ok(m, `the document has no conformance:${name} section`);
  return m[1];
};
const sorted = (xs) => [...new Set(xs)].sort();

// 1. the schema files are exactly the client's SCHEMAS
const files = readdirSync(schemaDir).filter((f) => f.endsWith('.schema.json')).map((f) => f.replace('.schema.json', ''));
assert.deepEqual(sorted(files), sorted(Object.keys(SCHEMAS)), 'docs/external-auth/ must hold exactly one file per schema in lib/mcp/external-auth.js');
for (const name of files) assert.deepEqual(JSON.parse(readFileSync(join(schemaDir, `${name}.schema.json`), 'utf8')), SCHEMAS[name], `${name}.schema.json differs from SCHEMAS['${name}']`);

// 2. one request and one response schema per documented call, and the stub implements every call
const calls = sorted([...doc.matchAll(/^### `([\w-]+)`/gm)].map((m) => m[1]));
assert.deepEqual(calls, sorted(['health', 'introspect', 'release', 'reserve', 'settle', ...FEATURES]), 'documented calls');
for (const c of calls) for (const kind of ['request', 'response']) assert.ok(schemaOf(c, kind), `no ${c}.${kind} schema`);
for (const c of calls.filter((c) => c !== 'health')) assert.match(stub, new RegExp(`^  (${c}|'${c}')\\(b\\) \\{`, 'm'), `the stub does not implement ${c}`);

// 2b. Debate contract codes: document = schemas (with the HTTP status of each code)
const debateCodes = [...section('debate-codes').matchAll(/^\|\s*`([\w-]+)`\s*\|\s*`(\w+)`\s*\|\s*(\d{3})\s*\|/gm)].map((m) => ({ call: m[1], code: m[2], status: Number(m[3]) }));
for (const call of FEATURES) {
  assert.deepEqual(sorted(debateCodes.filter((c) => c.call === call).map((c) => c.code)), sorted(DEBATE_CODES[call]), `${call} codes in the document vs ${call}.schema.json`);
  assert.deepEqual(sorted(schemaOf(call, 'response').oneOf.find((b) => b.properties.code).properties.code.enum), sorted(DEBATE_CODES[call]), `${call} codes in the schema vs the client`);
}
for (const c of debateCodes) assert.equal(c.status, DEBATE_STATUS[c.code], `${c.call} ${c.code}: the document says HTTP ${c.status}`);
for (const c of debateCodes.filter((x) => !['rate_limited', 'unavailable', 'not_ready'].includes(x.code))) assert.ok(stub.includes(`refuse('${c.code}')`) || c.code === 'invalid' || c.code === 'too_large', `the stub never answers ${c.call}:${c.code}`);

// 3. refusal codes: document = schemas = stub = vectors
const codes = [...section('codes').matchAll(/^\|\s*`(\w+)`\s*\|\s*`(\w+)`\s*\|/gm)].map((m) => `${m[1]}:${m[2]}`);
assert.ok(codes.length > 0, 'no codes parsed from the document');
const docReserve = sorted(codes.filter((c) => c.startsWith('reserve:')).map((c) => c.slice(8)));
const schemaReserve = SCHEMAS['reserve.response'].oneOf.find((b) => b.properties.code).properties.code.enum;
assert.deepEqual(docReserve, sorted(schemaReserve), 'reserve codes in the document vs reserve.response.schema.json');
assert.deepEqual(docReserve, sorted(REFUSAL_CODES), 'reserve codes in the document vs the client');
const docSettle = sorted(codes.filter((c) => c.startsWith('settle:')).map((c) => c.slice(7)));
assert.deepEqual(docSettle, [SCHEMAS['settle.response'].oneOf.find((b) => b.properties.code).properties.code.const], 'settle codes in the document vs settle.response.schema.json');
assert.deepEqual(sorted(codes.map((c) => c.split(':')[0])), ['reserve', 'settle'], 'only reserve and settle have refusal codes');
for (const c of codes) {
  assert.ok(coverage.has(c), `the document lists ${c} but no conformance vector covers it`);
  assert.ok(stub.includes(`code: '${c.split(':')[1]}'`), `the stub never answers ${c}`);
}
for (const c of coverage) if (/^(reserve|settle):/.test(c)) assert.ok(codes.includes(c), `a vector covers ${c} but the document does not list it`);

// 4. state transitions: document = vectors
const transitions = [...section('transitions').matchAll(/^\|\s*`(T-[a-z-]+)`/gm)].map((m) => m[1]);
assert.ok(transitions.length > 0, 'no transitions parsed from the document');
assert.equal(new Set(transitions).size, transitions.length, 'duplicate transition ids in the document');
for (const t of transitions) assert.ok(coverage.has(t), `the document lists transition ${t} but no conformance vector covers it`);
for (const t of coverage) if (t.startsWith('T-')) assert.ok(transitions.includes(t), `a vector covers ${t} but the document does not list it`);
// every terminal debate answer has a vector
for (const c of debateCodes.filter((x) => !['rate_limited', 'unavailable', 'not_ready'].includes(x.code))) assert.ok(coverage.has(`${c.call}:${c.code}`) || (c.call === 'authorize-run' && c.code === 'invalid'), `no conformance vector covers ${c.call}:${c.code}`);
for (const s of ['held', 'settled', 'released', 'expired']) assert.ok(section('transitions').includes(`\`${s}\``), `state ${s} missing from the transition table`);

// 5. the required prose sections and numbers
for (const needle of ['X-E3D-Auth-Version: 1', '16 KB', '64 KB', 'Store only key hashes', 'Constant-time comparison', 'Rate-limit `introspect`',
  'Atomic balance checks', 'No token logging', 'Maximum revocation latency', '## Compatibility', 'Unknown fields are ignored', '## What the server guarantees',
  'E3D_MCP_AUTH_SERVICE_TOKEN_FILE', 'E3D_MCP_AUTH_CACHE_SEC', 'E3D_MCP_AUTH_MAX_INFLIGHT', '^[A-Za-z0-9_.:-]{1,80}$',
  '## Debate contract v1', '### Capability gating', 'CONTRACT-VERSION', '512 KB', '480 KB', '8000 Unicode scalar', 'section boundary', 'E3D_MCP_OUTBOX_MAX_BYTES']) {
  assert.ok(doc.includes(needle), `the document is missing: ${needle}`);
}
assert.equal(SCHEMAS['introspect.response'].oneOf[0].properties.principal.pattern, '^[A-Za-z0-9_.:-]{1,80}$', 'principal pattern in the schema matches the document');

console.log(`drift: document, ${files.length} schemas, stub and ${coverage.size} covered items agree (${codes.length} codes, ${debateCodes.length} debate codes, ${transitions.length} transitions)`);
