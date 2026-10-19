#!/usr/bin/env node
// Conformance vectors for the external auth and metering protocol (docs/external-auth.md).
//
//   node examples/external-auth-conformance.js <base-url> <service-token>
//   node examples/external-auth-conformance.js --list      # print what the vectors cover (no network)
//
// Runs every vector against any implementation, validates every response against docs/external-auth/*.schema.json,
// and exits non-zero on the first violation. It needs a few accounts in known states; by default it uses the ones
// examples/external-auth-stub.js seeds. For your own service, point E3D_CONFORMANCE_FIXTURES at a JSON file:
//
//   { "active_token": "...",           a key that introspects active, belonging to principals.ok
//     "inactive_token": "...",         a revoked or expired key
//     "principals": { "ok": "...", "insufficient_credits": "...", "suspended": "...", "limit_reached": "..." } }
//
// "ok" needs credits for a few small debates. The expiry vector waits for a reservation to expire, so configure the
// service under test with a short reservation lifetime (E3D_CONFORMANCE_MAX_WAIT_SEC, default 30, bounds the wait).
// Vectors create real reservations and charges: run it against a test environment, never production.
//
// Debate contract v1 (finalize, fetch, authorize-run): each of those vectors runs only when the service advertises the call
// in introspect `features` (for active_token); otherwise it is reported as "# SKIP not advertised" and the version-skew
// vectors check that the e3d-pilot client would not use it. The fetch vectors need a second principal
// (principals.other, default principals.insufficient_credits) to check that a foreign debate is not_found.
// The offline vectors check the shared fixtures (docs/external-auth/debate-fixtures.json) and CONTRACT-VERSION hashes.
import { createHash, randomUUID, randomBytes } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validateSchema, canonicalJson, createExternalAuth, DEBATE_CONTRACT_VERSION, DEBATE_STATUS } from '../lib/mcp/external-auth.js';
import { truncateTranscript } from '../lib/mcp/outbox.js';

const SCHEMA_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'docs', 'external-auth');
const schemas = Object.fromEntries(readdirSync(SCHEMA_DIR).filter((f) => f.endsWith('.schema.json'))
  .map((f) => [f.replace('.schema.json', ''), JSON.parse(readFileSync(join(SCHEMA_DIR, f), 'utf8'))]));
// '<call>.<kind>' files for the original calls; one '<call>' file with $defs.request / $defs.response for the debate calls
const schemaFor = (call, kind) => schemas[`${call}.${kind}`] ?? schemas[call]?.$defs?.[kind];
const DEBATE_CALLS = new Set(['finalize', 'fetch', 'authorize-run']);
const FIXTURES_FILE = join(SCHEMA_DIR, 'debate-fixtures.json');

const DEFAULT_FIXTURES = {
  active_token: 'stub-key-ok-0123456789abcdef',
  inactive_token: 'stub-key-revoked-0123456789ab',
  principals: { ok: 'acct_ok', insufficient_credits: 'acct_broke', suspended: 'acct_suspended', limit_reached: 'acct_limited' },
};

class Violation extends Error {}
const expect = (cond, msg) => { if (!cond) throw new Violation(msg); };

let BASE = ''; let TOKEN = '';
// One request; returns { status, body }. Every 2xx response must match the call's response schema. A debate call's error
// answer must be { ok:false, code } with exactly that code's HTTP status.
async function rpc(call, body, { method = 'POST', token = TOKEN, version = '1', raw } = {}) {
  const headers = { 'x-e3d-auth-version': version, accept: 'application/json' };
  if (token) headers.authorization = `Bearer ${token}`;
  if (method === 'POST') headers['content-type'] = 'application/json';
  const res = await fetch(`${BASE}/${call}`, { method, headers, body: method === 'POST' ? (raw ?? JSON.stringify(body)) : undefined, redirect: 'manual', signal: AbortSignal.timeout(15000) });
  const text = await res.text();
  const cap = call === 'fetch' ? 2 * 1024 * 1024 : 64 * 1024;
  expect(Buffer.byteLength(text) <= cap, `${call}: response larger than ${cap / 1024} KB`);
  let json = null;
  try { json = JSON.parse(text); } catch { /* checked below for 2xx */ }
  const file = DEBATE_CALLS.has(call) ? `${call}.schema.json` : `${call}.response.schema.json`;
  if (res.status >= 200 && res.status < 300) {
    expect(json !== null, `${call}: HTTP ${res.status} with a body that is not JSON`);
    const errs = validateSchema(schemaFor(call, 'response'), json);
    expect(errs.length === 0, `${call}: response violates ${file}: ${errs.join('; ')}`);
    if (DEBATE_CALLS.has(call)) expect(json.ok === true, `${call}: an error answer must use its code's HTTP status, not ${res.status}`);
  } else if (DEBATE_CALLS.has(call) && Object.values(DEBATE_STATUS).includes(res.status)) {
    expect(json !== null && validateSchema(schemaFor(call, 'response'), json).length === 0 && json.ok === false, `${call}: HTTP ${res.status} must carry { ok:false, code } (${file})`);
    expect(DEBATE_STATUS[json.code] === res.status, `${call}: code ${json.code} must be HTTP ${DEBATE_STATUS[json.code]}, got ${res.status}`);
  }
  return { status: res.status, body: json };
}
const ok200 = (r, call) => { expect(r.status === 200, `${call}: expected HTTP 200, got ${r.status}`); return r.body; };
const units = (calls = 3, est_tokens = 3000) => ({ calls, est_tokens });
const reserveReq = (principal, extra = {}) => ({ principal, request_id: randomUUID(), kind: 'debate', tool: 'e3d_debate', units: units(), ...extra });
const settleReq = (reservation_id, calls = 2, extra = {}) => ({ reservation_id, actual: { calls, est_input_tokens: 1200, est_output_tokens: 300 }, models: calls ? [{ provider: 'claude', model: 'claude-test', calls }] : [], outcome: 'ok', duration_ms: 1234, ...extra });

async function held(F) {
  const b = ok200(await rpc('reserve', reserveReq(F.principals.ok)), 'reserve');
  expect(b.ok === true, `reserve for principals.ok was refused (${b.code}); does the fixture account have credits?`);
  return b.reservation_id;
}

// ---- Debate contract v1 ----
const debateId = () => `dbt_${randomBytes(12).toString('hex')}`;
const TRANSCRIPT = '# Debate\n\n## Round 1 -- claude\n\nJSON file.\n\n## Round 1 -- codex\n\nSQLite.\n';
const finalizeReq = (reservation_id, debate_id, extra = {}) => ({
  reservation_id, debate_id, source: 'connector', outcome: 'ok', actual: { calls: 2, est_input_tokens: 1200, est_output_tokens: 300 },
  models: [{ provider: 'claude', model: 'claude-test', calls: 1 }, { provider: 'codex', model: 'codex-test', calls: 1 }], duration_ms: 1234,
  question: 'Conformance: a JSON file or SQLite?', providers: ['claude', 'codex'], rounds: 1,
  result: { final_answer: 'A JSON file.', consensus: 'split', dissent: 'codex prefers SQLite', positions: [{ provider: 'claude', model: 'claude-test', position: 'JSON file.' }, { provider: 'codex', model: 'codex-test', position: 'SQLite.' }] },
  transcript: TRANSCRIPT, truncated: false, started_at: new Date(Date.now() - 2000).toISOString(), finished_at: new Date().toISOString(), ...extra,
});
const coded = (r, call, code) => { expect(r.status === DEBATE_STATUS[code] && r.body?.ok === false && r.body.code === code, `${call}: expected HTTP ${DEBATE_STATUS[code]} { ok:false, code:${code} }, got ${r.status} ${JSON.stringify(r.body)}`); };
const other = (F) => F.principals.other ?? F.principals.insufficient_credits;
// The e3d-pilot client against this service, optionally with every introspect answer rewritten (version-skew vectors).
async function clientFeatures(F, rewrite = (x) => x) {
  const fetchImpl = async (url, init) => {
    const res = await fetch(url, init);
    if (!String(url).endsWith('/introspect') || res.status !== 200) return res;
    const body = JSON.stringify(rewrite(await res.json()));
    return new Response(body, { status: 200, headers: { 'content-type': 'application/json' } });
  };
  const client = createExternalAuth({ url: BASE, serviceToken: TOKEN, env: {}, fetchImpl });
  const info = await client.introspect(F.active_token);
  expect(info.active, 'introspect(active_token) through the e3d-pilot client: expected active');
  return client;
}
let ADVERTISED = [];

// Each vector declares the protocol codes ("call:code") and state transitions ("T-...") it covers. The test suite
// fails if docs/external-auth.md lists a code or transition that no vector covers.
const VECTORS = [
  { name: 'health answers {status: ok}', covers: ['health'], run: async () => {
    const r = await rpc('health', null, { method: 'GET' });
    expect(ok200(r, 'health').status === 'ok', 'health: status is not ok');
  } },
  { name: 'a wrong service token is refused with 401 or 403', covers: ['service-auth'], run: async () => {
    const r = await rpc('introspect', { token: 'x'.repeat(30) }, { token: `wrong-${randomBytes(16).toString('hex')}` });
    expect(r.status === 401 || r.status === 403, `introspect with a wrong service token: expected 401/403, got ${r.status}`);
  } },
  { name: 'an invalid request is refused with a 4xx', covers: ['invalid-request'], run: async (F) => {
    const r = await rpc('reserve', { ...reserveReq(F.principals.ok), request_id: 'not-a-uuid' });
    expect(r.status >= 400 && r.status < 500, `reserve with a malformed request_id: expected 4xx, got ${r.status}`);
  } },
  { name: 'introspect: a valid token is active', covers: ['introspect:active'], run: async (F) => {
    const b = ok200(await rpc('introspect', { token: F.active_token }), 'introspect');
    expect(b.active === true, 'introspect(active_token): expected active true');
    expect(b.principal === F.principals.ok, `introspect(active_token): principal should be ${F.principals.ok}`);
  } },
  { name: 'introspect: a revoked token is inactive', covers: ['introspect:inactive'], run: async (F) => {
    expect(ok200(await rpc('introspect', { token: F.inactive_token }), 'introspect').active === false, 'introspect(inactive_token): expected active false');
  } },
  { name: 'introspect: an unknown token is inactive', covers: ['introspect:inactive'], run: async () => {
    expect(ok200(await rpc('introspect', { token: `unknown-${randomBytes(24).toString('hex')}` }), 'introspect').active === false, 'introspect(unknown): expected active false');
  } },
  { name: 'reserve creates a hold; unknown request fields are ignored', covers: ['T-reserve-new', 'compat:unknown-fields'], run: async (F) => {
    const b = ok200(await rpc('reserve', reserveReq(F.principals.ok, { x_future_field: { anything: [1, 2] } })), 'reserve');
    expect(b.ok === true && b.reservation_id, 'reserve: expected ok with a reservation_id');
    expect(Date.parse(b.expires_at) > Date.now() - 60000, 'reserve: expires_at is already in the past');
  } },
  { name: 'reserve is idempotent per request_id', covers: ['T-reserve-repeat'], run: async (F) => {
    const req = reserveReq(F.principals.ok);
    const a = ok200(await rpc('reserve', req), 'reserve');
    const b = ok200(await rpc('reserve', req), 'reserve');
    expect(a.ok && b.ok && a.reservation_id === b.reservation_id, 'reserve: a repeated request_id must return the same reservation');
  } },
  { name: 'reserve: the same request_id with different units is a conflict', covers: ['T-reserve-conflict', 'reserve:conflict'], run: async (F) => {
    const req = reserveReq(F.principals.ok);
    expect(ok200(await rpc('reserve', req), 'reserve').ok, 'reserve: first attempt refused');
    const b = ok200(await rpc('reserve', { ...req, units: units(5, 9000) }), 'reserve');
    expect(b.ok === false && b.code === 'conflict', `reserve: expected code conflict, got ${JSON.stringify(b)}`);
  } },
  ...['unknown_principal', 'suspended', 'limit_reached', 'insufficient_credits'].map((code) => ({
    name: `reserve refuses with ${code}`, covers: [`reserve:${code}`], run: async (F) => {
      const principal = code === 'unknown_principal' ? `conformance-unknown-${randomBytes(6).toString('hex')}` : F.principals[code];
      const b = ok200(await rpc('reserve', reserveReq(principal)), 'reserve');
      expect(b.ok === false && b.code === code, `reserve(${code} fixture): expected code ${code}, got ${JSON.stringify(b)}`);
    },
  })),
  { name: 'settle a held reservation; repeat identical is ok; different is a conflict; release after settle is a no-op', covers: ['T-settle-held', 'T-settle-repeat-same', 'T-settle-repeat-diff', 'settle:conflict', 'T-release-settled'], run: async (F) => {
    const id = await held(F);
    expect(ok200(await rpc('settle', settleReq(id)), 'settle').ok === true, 'settle(held): expected ok');
    expect(ok200(await rpc('settle', settleReq(id)), 'settle').ok === true, 'settle repeated with an identical payload: expected ok');
    const c = ok200(await rpc('settle', settleReq(id, 3)), 'settle');
    expect(c.ok === false && c.code === 'conflict', `settle repeated with a different payload: expected conflict, got ${JSON.stringify(c)}`);
    expect(ok200(await rpc('release', { reservation_id: id, reason: 'zero_usage' }), 'release').ok === true, 'release(settled): expected ok');
    expect(ok200(await rpc('settle', settleReq(id)), 'settle').ok === true, 'settle(identical) after a release of a settled reservation: still ok, nothing changed');
  } },
  { name: 'release a hold; release again is ok; a later settle with usage is still charged', covers: ['T-release-held', 'T-release-released', 'T-settle-released'], run: async (F) => {
    const id = await held(F);
    expect(ok200(await rpc('release', { reservation_id: id, reason: 'zero_usage' }), 'release').ok === true, 'release(held): expected ok');
    expect(ok200(await rpc('release', { reservation_id: id, reason: 'zero_usage' }), 'release').ok === true, 'release(released): expected ok');
    expect(ok200(await rpc('settle', settleReq(id)), 'settle').ok === true, 'settle with usage after release: must be accepted');
    const c = ok200(await rpc('settle', settleReq(id, 4)), 'settle');
    expect(c.ok === false && c.code === 'conflict', 'settle after release then a different settle: expected conflict (it was settled)');
  } },
  { name: 'settle with zero calls is a release', covers: ['T-settle-zero'], run: async (F) => {
    const id = await held(F);
    expect(ok200(await rpc('settle', settleReq(id, 0)), 'settle').ok === true, 'settle(calls 0): expected ok');
    expect(ok200(await rpc('settle', settleReq(id, 2)), 'settle').ok === true, 'settle with usage after a zero settle: must be accepted (the reservation was released, not settled)');
  } },
  { name: 'release by request_id (the reserve response was lost)', covers: ['T-release-by-request'], run: async (F) => {
    const req = reserveReq(F.principals.ok);
    const a = ok200(await rpc('reserve', req), 'reserve');
    expect(a.ok, 'reserve refused');
    expect(ok200(await rpc('release', { request_id: req.request_id, reason: 'ambiguous_reserve' }), 'release').ok === true, 'release by request_id: expected ok');
    const again = ok200(await rpc('reserve', req), 'reserve');
    expect(again.ok && again.reservation_id === a.reservation_id, 'reserve with the released request_id: expected the same (released) reservation');
    expect(ok200(await rpc('settle', settleReq(a.reservation_id)), 'settle').ok === true, 'settle after release by request_id: must be accepted');
  } },
  { name: 'unknown ids: release is ok, settle with usage is a conflict', covers: ['T-release-unknown', 'T-settle-unknown'], run: async () => {
    expect(ok200(await rpc('release', { reservation_id: `res_unknown_${randomBytes(6).toString('hex')}`, reason: 'zero_usage' }), 'release').ok === true, 'release(unknown reservation_id): expected ok');
    expect(ok200(await rpc('release', { request_id: randomUUID(), reason: 'ambiguous_reserve' }), 'release').ok === true, 'release(unknown request_id): expected ok');
    const c = ok200(await rpc('settle', settleReq(`res_unknown_${randomBytes(6).toString('hex')}`)), 'settle');
    expect(c.ok === false && c.code === 'conflict', 'settle(unknown reservation): expected conflict');
  } },
  // ---- Debate contract v1 ----
  { name: 'contract: the shared fixtures and CONTRACT-VERSION hashes match (offline)', covers: ['contract:version', 'contract:canonical-json', 'contract:truncation', 'contract:examples'], run: async () => {
    const lines = readFileSync(join(SCHEMA_DIR, 'CONTRACT-VERSION'), 'utf8').trim().split('\n');
    expect(lines[0] === `debate-contract ${DEBATE_CONTRACT_VERSION}`, `CONTRACT-VERSION says "${lines[0]}", this runner speaks debate-contract ${DEBATE_CONTRACT_VERSION}`);
    for (const line of lines.slice(1)) {
      const [hash, file] = line.split(/\s+/);
      expect(createHash('sha256').update(readFileSync(join(SCHEMA_DIR, file))).digest('hex') === hash, `${file} does not match its SHA-256 in CONTRACT-VERSION`);
    }
    const fx = JSON.parse(readFileSync(FIXTURES_FILE, 'utf8'));
    expect(fx.contract_version === DEBATE_CONTRACT_VERSION, 'debate-fixtures.json is for another contract version');
    for (const v of fx.canonical_json) expect(canonicalJson(v.input) === v.canonical, `canonical JSON of ${JSON.stringify(v.input).slice(0, 60)} differs from the fixture`);
    for (const v of fx.transcript_truncation) {
      const got = truncateTranscript(v.transcript, v.max_bytes);
      expect(got.transcript === v.expected && got.truncated === v.truncated, `transcript truncation to ${v.max_bytes} bytes differs from the fixture`);
    }
    for (const [where, set] of [['request', fx.requests], ['response', fx.responses]]) {
      for (const [call, { valid, invalid }] of Object.entries(set)) {
        valid.forEach((x, i) => expect(validateSchema(schemaFor(call, where), x).length === 0, `${call} ${where} fixture valid[${i}] is rejected by the schema`));
        invalid.forEach((x, i) => expect(validateSchema(schemaFor(call, where), x).length > 0, `${call} ${where} fixture invalid[${i}] is accepted by the schema`));
      }
    }
  } },
  { name: 'introspect: features, when present, is a list of distinct call names', covers: ['features'], run: async (F) => {
    const b = ok200(await rpc('introspect', { token: F.active_token }), 'introspect');
    if (b.features !== undefined) expect(Array.isArray(b.features) && new Set(b.features).size === b.features.length, 'introspect: features must be an array of distinct names');
  } },
  { name: 'version skew: the e3d-pilot client uses exactly the advertised calls (none when features is absent)', covers: ['skew:unadvertised'], run: async (F) => {
    const client = await clientFeatures(F);
    expect(JSON.stringify(client.features()) === JSON.stringify(['finalize', 'fetch', 'authorize-run'].filter((f) => ADVERTISED.includes(f))), `client features ${JSON.stringify(client.features())} vs advertised ${JSON.stringify(ADVERTISED)}`);
    const legacy = await clientFeatures(F, (x) => { const { features, ...rest } = x; return rest; });
    expect(legacy.features().length === 0 && !legacy.hasFeature('finalize'), 'without features the client must use no debate call');
    // a call the service does not advertise is not part of its protocol: it must not answer it as if it were
    for (const call of ['finalize', 'fetch', 'authorize-run'].filter((f) => !ADVERTISED.includes(f))) {
      const r = await fetch(`${BASE}/${call}`, { method: 'POST', headers: { authorization: `Bearer ${TOKEN}`, 'x-e3d-auth-version': '1', 'content-type': 'application/json' }, body: '{}', redirect: 'manual', signal: AbortSignal.timeout(15000) });
      await r.arrayBuffer().catch(() => {});
      expect(r.status >= 400 && r.status < 500, `${call} is not advertised, yet it answered HTTP ${r.status}`);
    }
  } },
  { name: 'version skew: an advertised feature the client does not know is ignored', covers: ['skew:unknown-feature'], run: async (F) => {
    const client = await clientFeatures(F, (x) => ({ ...x, features: [...(x.features ?? []), 'x-future-call'] }));
    expect(!client.features().includes('x-future-call'), 'the client must ignore a feature it does not know');
    expect(client.features().length === ADVERTISED.filter((f) => ['finalize', 'fetch', 'authorize-run'].includes(f)).length, 'the known features are still used');
  } },
  { name: 'finalize: ok stores and charges once; fetch returns it to its owner only (transcript only when asked)', feature: 'finalize', also: 'fetch', covers: ['finalize:ok', 'fetch:owner', 'fetch:transcript', 'fetch:not_found'], run: async (F) => {
    const id = await held(F); const dbt = debateId(); const req = finalizeReq(id, dbt);
    const a = ok200(await rpc('finalize', req), 'finalize');
    expect(a.ok === true && a.stored === true && Number.isSafeInteger(a.charged), `finalize(ok): expected { ok, stored:true, charged }, got ${JSON.stringify(a)}`);
    const plain = ok200(await rpc('fetch', { debate_id: dbt, principal: F.principals.ok, include_transcript: false }), 'fetch');
    expect(plain.ok && plain.debate.debate_id === dbt && plain.debate.status === 'done' && plain.debate.outcome === 'ok', 'fetch(owner): expected the done debate');
    expect(plain.debate.result?.final_answer === req.result.final_answer && plain.debate.question === req.question, 'fetch(owner): the stored result and question');
    expect(!('transcript' in plain.debate), 'fetch: transcript must be absent unless include_transcript is true');
    expect(plain.debate.credits_charged === a.charged, 'fetch: credits_charged equals what finalize charged');
    const full = ok200(await rpc('fetch', { debate_id: dbt, principal: F.principals.ok, include_transcript: true }), 'fetch');
    expect(full.debate.transcript === TRANSCRIPT, 'fetch(include_transcript): the stored transcript');
    const foreign = await rpc('fetch', { debate_id: dbt, principal: other(F), include_transcript: true });
    const unknown = await rpc('fetch', { debate_id: debateId(), principal: F.principals.ok, include_transcript: true });
    coded(foreign, 'fetch', 'not_found'); coded(unknown, 'fetch', 'not_found');
    expect(JSON.stringify(foreign.body) === JSON.stringify(unknown.body), 'fetch: a foreign debate and an unknown one must answer identically');
  } },
  { name: 'finalize: idempotent per reservation (same body = same answer, different body or reused debate_id = conflict)', feature: 'finalize', covers: ['finalize:replay', 'finalize:conflict'], run: async (F) => {
    const id = await held(F); const dbt = debateId(); const req = finalizeReq(id, dbt);
    const a = ok200(await rpc('finalize', req), 'finalize');
    const b = ok200(await rpc('finalize', JSON.parse(JSON.stringify(req))), 'finalize');
    expect(JSON.stringify(a) === JSON.stringify(b), `finalize replayed: expected the original answer ${JSON.stringify(a)}, got ${JSON.stringify(b)}`);
    coded(await rpc('finalize', { ...req, duration_ms: req.duration_ms + 1 }), 'finalize', 'conflict');
    coded(await rpc('finalize', finalizeReq(await held(F), dbt)), 'finalize', 'conflict');
  } },
  { name: 'finalize: error and timeout carry no result; zero calls charge zero', feature: 'finalize', covers: ['finalize:error', 'finalize:zero-calls'], run: async (F) => {
    const e = ok200(await rpc('finalize', finalizeReq(await held(F), debateId(), { outcome: 'error', result: null })), 'finalize');
    expect(e.ok === true && Number.isSafeInteger(e.charged), 'finalize(error): expected ok');
    const z = ok200(await rpc('finalize', finalizeReq(await held(F), debateId(), { outcome: 'timeout', result: null, transcript: null, actual: { calls: 0, est_input_tokens: 0, est_output_tokens: 0 }, models: [] })), 'finalize');
    expect(z.ok === true && z.charged === 0, `finalize(zero calls): expected charged 0, got ${JSON.stringify(z)}`);
  } },
  { name: 'finalize: unknown reservation is not_found; malformed is invalid; over 512 KB is too_large', feature: 'finalize', covers: ['finalize:not_found', 'finalize:invalid', 'finalize:too_large'], run: async (F) => {
    coded(await rpc('finalize', finalizeReq(`res_unknown_${randomBytes(6).toString('hex')}`, debateId())), 'finalize', 'not_found');
    const id = await held(F);
    coded(await rpc('finalize', finalizeReq(id, debateId(), { result: null })), 'finalize', 'invalid');
    coded(await rpc('finalize', { ...finalizeReq(id, debateId()), question: undefined }), 'finalize', 'invalid');
    coded(await rpc('finalize', finalizeReq(id, debateId(), { transcript: 'x'.repeat(600 * 1024) })), 'finalize', 'too_large');
  } },
  { name: 'fetch: a malformed request is invalid', feature: 'fetch', covers: ['fetch:invalid'], run: async (F) => {
    coded(await rpc('fetch', { debate_id: 'dbt_short', principal: F.principals.ok, include_transcript: false }), 'fetch', 'invalid');
    coded(await rpc('fetch', { debate_id: debateId(), principal: F.principals.ok }), 'fetch', 'invalid');
  } },
  { name: 'authorize-run: the same pair gets the same answer; another pair is a conflict; unknown is not_found', feature: 'authorize-run', covers: ['authorize-run:ok', 'authorize-run:conflict', 'authorize-run:not_found'], run: async (F) => {
    const id = await held(F); const dbt = debateId();
    const a = ok200(await rpc('authorize-run', { reservation_id: id, debate_id: dbt }), 'authorize-run');
    expect(a.ok === true && a.principal === F.principals.ok && ['reserved', 'bound'].includes(a.status), `authorize-run: expected the owner, got ${JSON.stringify(a)}`);
    const b = ok200(await rpc('authorize-run', { reservation_id: id, debate_id: dbt }), 'authorize-run');
    expect(JSON.stringify(a) === JSON.stringify(b), 'authorize-run repeated: expected the same answer');
    coded(await rpc('authorize-run', { reservation_id: id, debate_id: debateId() }), 'authorize-run', 'conflict');
    coded(await rpc('authorize-run', { reservation_id: await held(F), debate_id: dbt }), 'authorize-run', 'conflict');
    coded(await rpc('authorize-run', { reservation_id: `res_unknown_${randomBytes(6).toString('hex')}`, debate_id: debateId() }), 'authorize-run', 'not_found');
    coded(await rpc('authorize-run', { reservation_id: id }), 'authorize-run', 'invalid');
    // after the debate is finalized the same pair is refused: a repeated run request cannot rerun a finished debate
    ok200(await rpc('finalize', finalizeReq(id, dbt)), 'finalize');
    coded(await rpc('authorize-run', { reservation_id: id, debate_id: dbt }), 'authorize-run', 'conflict');
  } },
  { name: 'a hold expires; a later settle with usage is still charged', covers: ['T-expire', 'T-settle-expired'], run: async (F) => {
    const b = ok200(await rpc('reserve', reserveReq(F.principals.ok)), 'reserve');
    expect(b.ok, 'reserve refused');
    const maxWait = Number(process.env.E3D_CONFORMANCE_MAX_WAIT_SEC || 30) * 1000;
    const wait = Date.parse(b.expires_at) - Date.now() + 1500;
    expect(wait <= maxWait, `reservations live ${Math.round(wait / 1000)} s; configure the service under test with a short reservation lifetime (or raise E3D_CONFORMANCE_MAX_WAIT_SEC)`);
    if (wait > 0) await new Promise((r) => setTimeout(r, wait));
    expect(ok200(await rpc('release', { reservation_id: b.reservation_id, reason: 'zero_usage' }), 'release').ok === true, 'release(expired): expected ok');
    expect(ok200(await rpc('settle', settleReq(b.reservation_id)), 'settle').ok === true, 'settle with usage after expiry: must be accepted and charged');
    expect(ok200(await rpc('settle', settleReq(b.reservation_id)), 'settle').ok === true, 'settle repeated after expiry: identical payload is ok');
  } },
];

const COVERAGE = [...new Set(VECTORS.flatMap((v) => v.covers))].sort();

async function main(argv) {
  if (argv[0] === '--list') { console.log(JSON.stringify({ vectors: VECTORS.map((v) => v.name), covers: COVERAGE }, null, 2)); return 0; }
  if (argv.length !== 2) { console.error('usage: external-auth-conformance.js <base-url> <service-token> | --list'); return 2; }
  BASE = argv[0].replace(/\/+$/, ''); TOKEN = argv[1];
  const F = process.env.E3D_CONFORMANCE_FIXTURES ? JSON.parse(readFileSync(process.env.E3D_CONFORMANCE_FIXTURES, 'utf8')) : DEFAULT_FIXTURES;
  let skipped = 0;
  try { ADVERTISED = (await rpc('introspect', { token: F.active_token })).body?.features ?? []; } catch { ADVERTISED = []; }
  for (const [i, v] of VECTORS.entries()) {
    const needs = [v.feature, v.also].filter(Boolean).filter((f) => !ADVERTISED.includes(f));
    if (needs.length) { skipped++; console.log(`ok ${i + 1} - ${v.name} # SKIP not advertised: ${needs.join(', ')}`); continue; }
    try { await v.run(F); } catch (e) {
      console.log(`not ok ${i + 1} - ${v.name}`);
      console.log(`  ${e instanceof Violation ? 'violation' : 'error'}: ${e.message}`);
      return 1;
    }
    console.log(`ok ${i + 1} - ${v.name}`);
  }
  console.log(`conformance: all ${VECTORS.length - skipped} vectors passed${skipped ? ` (${skipped} skipped: not advertised)` : ''}`);
  return 0;
}

process.exit(await main(process.argv.slice(2)));
