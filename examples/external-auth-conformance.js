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
import { randomUUID, randomBytes } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validateSchema } from '../lib/mcp/external-auth.js';

const SCHEMA_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'docs', 'external-auth');
const schemas = Object.fromEntries(readdirSync(SCHEMA_DIR).filter((f) => f.endsWith('.schema.json'))
  .map((f) => [f.replace('.schema.json', ''), JSON.parse(readFileSync(join(SCHEMA_DIR, f), 'utf8'))]));

const DEFAULT_FIXTURES = {
  active_token: 'stub-key-ok-0123456789abcdef',
  inactive_token: 'stub-key-revoked-0123456789ab',
  principals: { ok: 'acct_ok', insufficient_credits: 'acct_broke', suspended: 'acct_suspended', limit_reached: 'acct_limited' },
};

class Violation extends Error {}
const expect = (cond, msg) => { if (!cond) throw new Violation(msg); };

let BASE = ''; let TOKEN = '';
// One request; returns { status, body }. Every 2xx response must match the call's response schema.
async function rpc(call, body, { method = 'POST', token = TOKEN, version = '1', raw } = {}) {
  const headers = { 'x-e3d-auth-version': version, accept: 'application/json' };
  if (token) headers.authorization = `Bearer ${token}`;
  if (method === 'POST') headers['content-type'] = 'application/json';
  const res = await fetch(`${BASE}/${call}`, { method, headers, body: method === 'POST' ? (raw ?? JSON.stringify(body)) : undefined, redirect: 'manual', signal: AbortSignal.timeout(15000) });
  const text = await res.text();
  expect(text.length <= 64 * 1024, `${call}: response larger than 64 KB`);
  let json = null;
  try { json = JSON.parse(text); } catch { /* checked below for 2xx */ }
  if (res.status >= 200 && res.status < 300) {
    expect(json !== null, `${call}: HTTP ${res.status} with a body that is not JSON`);
    const errs = validateSchema(schemas[`${call}.response`], json);
    expect(errs.length === 0, `${call}: response violates ${call}.response.schema.json: ${errs.join('; ')}`);
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
  for (const [i, v] of VECTORS.entries()) {
    try { await v.run(F); } catch (e) {
      console.log(`not ok ${i + 1} - ${v.name}`);
      console.log(`  ${e instanceof Violation ? 'violation' : 'error'}: ${e.message}`);
      return 1;
    }
    console.log(`ok ${i + 1} - ${v.name}`);
  }
  console.log(`conformance: all ${VECTORS.length} vectors passed`);
  return 0;
}

process.exit(await main(process.argv.slice(2)));
