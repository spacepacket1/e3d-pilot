#!/usr/bin/env node
// EXAMPLE AND TEST FIXTURE -- NOT PRODUCTION CODE.
//
// A reference implementation of the external auth and metering protocol (docs/external-auth.md), using only
// Node built-ins. Accounts, keys, balances and the reservation ledger live in memory and vanish on exit. It is
// here so the protocol has a runnable reference, so tests/mcp-extauth.sh has something to talk to, and so you
// can run examples/external-auth-conformance.js against something before pointing it at your own service.
//
//   STUB_SERVICE_TOKEN=<24+ chars> node examples/external-auth-stub.js
//
// Environment:
//   STUB_SERVICE_TOKEN        required; the bearer token e3d-mcp must present (E3D_MCP_AUTH_SERVICE_TOKEN)
//   STUB_HOST / STUB_PORT     listen address (loopback only; default 127.0.0.1:0 = any free port)
//   STUB_URL_FILE             if set, the base URL is written there once listening (also printed on stdout)
//   STUB_SEED                 JSON file with accounts and keys (shape: see DEFAULT_SEED); default: DEFAULT_SEED
//   STUB_RESERVATION_TTL_SEC  how long a hold lives before it expires (default 900)
//   STUB_CREDITS_PER_CALL / STUB_CREDITS_PER_KTOKEN   price (default 1 and 1)
//   STUB_INTROSPECT_PER_MIN / STUB_HEALTH_PER_MIN      rate limits (default 600 and 120); 429 beyond
//   STUB_FAIL_MODE            failure injection: slow | 5xx | malformed | oversized | redirect | invalid | drop | drop-after-commit
//   STUB_FAIL_CALLS           comma list of calls the injection applies to (default: all)
//   STUB_FAIL_COUNT           how many requests to affect (default: unlimited)
//   STUB_SLOW_MS              delay for "slow" (default 5000)
//
// Test-only admin endpoints (service token required): GET /_stub/state, POST /_stub/inject {mode,calls,count,ms},
// POST /_stub/revoke {key_id}. A real service has no such thing.
import http from 'node:http';
import { createHash, randomUUID, timingSafeEqual } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';

const env = process.env;
const sha = (s) => createHash('sha256').update(String(s)).digest();
const hex = (s) => sha(s).toString('hex');
const int = (v, d) => { const n = Number.parseInt(v ?? '', 10); return Number.isFinite(n) && n >= 0 ? n : d; };
const log = (fields) => process.stderr.write(`${JSON.stringify({ t: new Date().toISOString(), ...fields })}\n`); // never tokens

const SERVICE_TOKEN = env.STUB_SERVICE_TOKEN || '';
if (SERVICE_TOKEN.length < 24) { console.error('external-auth-stub: STUB_SERVICE_TOKEN (24+ characters) is required'); process.exit(2); }
const HOST = env.STUB_HOST || '127.0.0.1';
if (!(HOST === 'localhost' || HOST === '::1' || /^127\.\d+\.\d+\.\d+$/.test(HOST))) { console.error('external-auth-stub: listens on loopback only'); process.exit(2); }
const TTL_MS = int(env.STUB_RESERVATION_TTL_SEC, 900) * 1000;
const PER_CALL = int(env.STUB_CREDITS_PER_CALL, 1);
const PER_KTOKEN = int(env.STUB_CREDITS_PER_KTOKEN, 1);

// Matches the default fixtures of examples/external-auth-conformance.js.
const DEFAULT_SEED = {
  accounts: [
    { principal: 'acct_ok', balance: 1000000, keys: [
      { id: 'key-ok', token: 'stub-key-ok-0123456789abcdef', tools: ['e3d_debate', 'e3d_usage'], limits: { rate_per_min: 60, max_inflight: 2 } },
      { id: 'key-revoked', token: 'stub-key-revoked-0123456789ab', revoked: true },
    ] },
    { principal: 'acct_broke', balance: 0, keys: [] },
    { principal: 'acct_suspended', balance: 1000000, status: 'suspended', keys: [] },
    { principal: 'acct_limited', balance: 1000000, max_holds: 0, keys: [] },
  ],
};

// ---- state: keys are stored only as hashes ----
const seed = env.STUB_SEED ? JSON.parse(readFileSync(env.STUB_SEED, 'utf8')) : DEFAULT_SEED;
const accounts = new Map(); // principal -> { principal, balance, status, max_holds }
const keys = new Map();     // sha256(token) hex -> { id, principal, tools, limits, expires_at, revoked }
for (const a of seed.accounts ?? []) {
  accounts.set(a.principal, { principal: a.principal, balance: a.balance ?? 0, status: a.status ?? 'active', max_holds: a.max_holds ?? 100 });
  for (const k of a.keys ?? []) {
    const expires_at = k.expires_at ?? (k.expires_in_sec != null ? new Date(Date.now() + k.expires_in_sec * 1000).toISOString() : undefined);
    keys.set(hex(k.token), { id: k.id, principal: a.principal, tools: k.tools, limits: k.limits, expires_at, revoked: !!k.revoked });
  }
}
const reservations = new Map(); // reservation_id -> { id, request_id, principal, units, hold, state, expires_at, settlement }
const byRequest = new Map();    // request_id -> reservation_id
const settlements = [];         // every accepted charge, in order: { reservation_id, principal, charge, outcome }
const cost = (calls, tokens) => calls * PER_CALL + Math.ceil(tokens / 1000) * PER_KTOKEN;

// held -> expired once its time passes: the funds are released, the liability for a later settle is kept.
function sweep() {
  const t = Date.now();
  for (const r of reservations.values()) if (r.state === 'held' && Date.parse(r.expires_at) <= t) { r.state = 'expired'; r.hold = 0; log({ call: 'expire', reservation_id: r.id }); }
}
const holds = (principal) => [...reservations.values()].filter((r) => r.principal === principal && r.state === 'held');
const available = (a) => a.balance - holds(a.principal).reduce((s, r) => s + r.hold, 0);
const view = (r) => ({ ok: true, reservation_id: r.id, expires_at: r.expires_at });

// ---- request validation (the same rules as docs/external-auth/*.request.schema.json) ----
const re = { principal: /^[A-Za-z0-9_.:-]{1,80}$/, uuid: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/, rid: /^[A-Za-z0-9_.:-]{1,128}$/, tool: /^[A-Za-z0-9_.-]{1,64}$/, token: /^[!-~]{1,512}$/, reason: /^[a-z0-9_]{1,40}$/, word64: /^[!-~]{1,64}$/, word128: /^[!-~]{1,128}$/ };
const n = (v, max, min = 0) => Number.isSafeInteger(v) && v >= min && v <= max;
const obj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const valid = {
  introspect: (b) => typeof b.token === 'string' && re.token.test(b.token),
  reserve: (b) => re.principal.test(b.principal ?? '') && re.uuid.test(b.request_id ?? '') && b.kind === 'debate' && re.tool.test(b.tool ?? '')
    && obj(b.units) && n(b.units.calls, 10000, 1) && n(b.units.est_tokens, 1e9),
  settle: (b) => re.rid.test(b.reservation_id ?? '') && obj(b.actual) && n(b.actual.calls, 10000) && n(b.actual.est_input_tokens, 1e9) && n(b.actual.est_output_tokens, 1e9)
    && Array.isArray(b.models) && b.models.length <= 32 && b.models.every((m) => obj(m) && re.word64.test(m.provider ?? '') && re.word128.test(m.model ?? '') && n(m.calls, 10000))
    && ['ok', 'error', 'timeout', 'orphaned'].includes(b.outcome) && n(b.duration_ms, 86400000),
  release: (b) => re.reason.test(b.reason ?? '') && (('reservation_id' in b) !== ('request_id' in b))
    && ('reservation_id' in b ? re.rid.test(String(b.reservation_id)) : re.uuid.test(String(b.request_id))),
};
// Settle payloads are compared on their known fields only (unknown fields are ignored).
const settleKey = (b) => JSON.stringify([b.actual.calls, b.actual.est_input_tokens, b.actual.est_output_tokens, b.models.map((m) => [m.provider, m.model, m.calls]), b.outcome, b.duration_ms]);

// ---- the protocol ----
const ops = {
  introspect(b) {
    const k = keys.get(hex(b.token));
    if (!k || k.revoked || (k.expires_at && Date.parse(k.expires_at) <= Date.now())) return { active: false };
    return { active: true, principal: k.principal, ...(k.tools ? { tools: k.tools } : {}), ...(k.limits ? { limits: k.limits } : {}), ...(k.expires_at ? { expires_at: k.expires_at } : {}) };
  },
  reserve(b) {
    const a = accounts.get(b.principal);
    if (!a) return { ok: false, code: 'unknown_principal', message: 'no such account' };
    const existing = reservations.get(byRequest.get(b.request_id));
    if (existing) {
      if (existing.principal !== b.principal || existing.units.calls !== b.units.calls || existing.units.est_tokens !== b.units.est_tokens) return { ok: false, code: 'conflict', message: 'request_id was already used with different parameters' };
      return view(existing); // idempotent: the same reservation, whatever its state now
    }
    if (a.status === 'suspended') return { ok: false, code: 'suspended', message: 'account suspended' };
    if (holds(a.principal).length >= a.max_holds) return { ok: false, code: 'limit_reached', message: 'too many reservations in progress' };
    const hold = cost(b.units.calls, b.units.est_tokens);
    if (available(a) < hold) return { ok: false, code: 'insufficient_credits', message: `this debate needs up to ${hold} credits; ${Math.max(available(a), 0)} available` };
    const r = { id: `res_${randomUUID()}`, request_id: b.request_id, principal: a.principal, units: { ...b.units }, hold, state: 'held', expires_at: new Date(Date.now() + TTL_MS).toISOString(), settlement: null };
    reservations.set(r.id, r); byRequest.set(b.request_id, r.id);
    return view(r);
  },
  settle(b) {
    if (b.actual.calls === 0) return ops.release({ reservation_id: b.reservation_id, reason: 'zero_usage' }); // equivalent to release
    const r = reservations.get(b.reservation_id);
    if (!r) return { ok: false, code: 'conflict', message: 'unknown reservation' };
    const k = settleKey(b);
    if (r.state === 'settled') return r.settlement.key === k ? { ok: true } : { ok: false, code: 'conflict', message: 'already settled with a different payload' };
    // held, released or expired: usage that happened is always charged
    const charge = cost(b.actual.calls, b.actual.est_input_tokens + b.actual.est_output_tokens);
    accounts.get(r.principal).balance -= charge;
    r.state = 'settled'; r.hold = 0; r.settlement = { key: k, charge, outcome: b.outcome };
    settlements.push({ reservation_id: r.id, principal: r.principal, charge, outcome: b.outcome });
    return { ok: true };
  },
  release(b) {
    const r = reservations.get(b.reservation_id ?? byRequest.get(b.request_id));
    if (r && r.state === 'held') { r.state = 'released'; r.hold = 0; }
    return { ok: true }; // settled, released, expired or unknown: nothing to do
  },
};

// ---- failure injection ----
let inject = { mode: env.STUB_FAIL_MODE || null, calls: env.STUB_FAIL_CALLS ? env.STUB_FAIL_CALLS.split(',') : null, count: env.STUB_FAIL_COUNT ? int(env.STUB_FAIL_COUNT, 0) : Infinity, ms: int(env.STUB_SLOW_MS, 5000) };
const injected = (call) => {
  if (!inject.mode || inject.count <= 0 || (inject.calls && !inject.calls.includes(call))) return null;
  inject.count--;
  return inject.mode;
};

// ---- rate limits (fixed one-minute windows) ----
const windows = new Map();
const limited = (name, perMin) => {
  const w = Math.floor(Date.now() / 60000); const cur = windows.get(name);
  if (!cur || cur.w !== w) { windows.set(name, { w, n: 1 }); return false; }
  return ++cur.n > perMin;
};

const SERVICE_DIGEST = sha(SERVICE_TOKEN);
const authorized = (req) => {
  const m = /^Bearer\s+(\S+)$/i.exec(req.headers.authorization ?? '');
  return m ? timingSafeEqual(sha(m[1]), SERVICE_DIGEST) : false;
};
const send = (res, status, body, headers = {}) => {
  const text = typeof body === 'string' ? body : JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text), ...headers });
  res.end(text);
};
const readBody = (req) => new Promise((resolve) => {
  const chunks = []; let size = 0;
  req.on('data', (c) => { size += c.length; if (size <= 16384) chunks.push(c); });
  req.on('end', () => resolve(size > 16384 ? null : Buffer.concat(chunks).toString('utf8')));
  req.on('error', () => resolve(null));
});

const server = http.createServer(async (req, res) => {
  const path = (req.url ?? '').split('?')[0];
  const call = path.replace(/^\/+/, '');
  const raw = req.method === 'POST' ? await readBody(req) : '';

  // test-only admin
  if (path.startsWith('/_stub/')) {
    if (!authorized(req)) return send(res, 401, { error: 'unauthorized' });
    sweep();
    if (path === '/_stub/state' && req.method === 'GET') {
      return send(res, 200, {
        accounts: Object.fromEntries([...accounts.values()].map((a) => [a.principal, { balance: a.balance, available: available(a), status: a.status, holds: holds(a.principal).length }])),
        reservations: [...reservations.values()].map((r) => ({ reservation_id: r.id, request_id: r.request_id, principal: r.principal, state: r.state, hold: r.hold, charge: r.settlement?.charge ?? 0 })),
        settlements,
      });
    }
    let b; try { b = JSON.parse(raw || '{}'); } catch { return send(res, 400, { error: 'invalid_json' }); }
    if (path === '/_stub/inject' && req.method === 'POST') {
      inject = { mode: b.mode || null, calls: b.calls ?? null, count: b.count ?? Infinity, ms: b.ms ?? 5000 };
      return send(res, 200, { ok: true });
    }
    if (path === '/_stub/revoke' && req.method === 'POST') {
      let found = false;
      for (const k of keys.values()) if (k.id === b.key_id) { k.revoked = true; found = true; }
      return send(res, found ? 200 : 404, { ok: found });
    }
    return send(res, 404, { error: 'not_found' });
  }

  const isHealth = call === 'health' && req.method === 'GET';
  if (!isHealth && !(req.method === 'POST' && call in ops)) return send(res, 404, { error: 'not_found' });
  // health may be called without a service token; a wrong one is still refused so misconfiguration shows up
  if (!(isHealth && !req.headers.authorization) && !authorized(req)) return send(res, 401, { error: 'unauthorized' });
  if (req.headers['x-e3d-auth-version'] !== '1') return send(res, 400, { error: 'unsupported_version' });
  if (call === 'introspect' && limited('introspect', int(env.STUB_INTROSPECT_PER_MIN, 600))) return send(res, 429, { error: 'rate_limited' }, { 'retry-after': '60' });
  if (isHealth && limited('health', int(env.STUB_HEALTH_PER_MIN, 120))) return send(res, 429, { error: 'rate_limited' }, { 'retry-after': '60' });

  const mode = injected(call);
  if (mode === 'slow') await new Promise((r) => setTimeout(r, inject.ms));
  if (mode === '5xx') return send(res, 503, { error: 'injected' });
  if (mode === 'malformed') return send(res, 200, '{"ok": tru');
  if (mode === 'oversized') return send(res, 200, JSON.stringify({ ok: true, active: false, status: 'ok', pad: 'x'.repeat(100 * 1024) }));
  if (mode === 'redirect') return send(res, 307, { error: 'moved' }, { location: `${path}?redirected=1` }) // following it would succeed;
  if (mode === 'invalid') return send(res, 200, { ok: 'yes', active: 'yes', principal: 'not a valid principal!', status: 'nope' });
  if (mode === 'drop') return req.socket.destroy();

  if (isHealth) return send(res, 200, { status: 'ok' });
  if (raw === null) return send(res, 413, { error: 'too_large' });
  let body; try { body = JSON.parse(raw); } catch { return send(res, 400, { error: 'invalid_json' }); }
  if (!obj(body) || !valid[call](body)) return send(res, 400, { error: 'invalid_request' });

  sweep();
  const out = ops[call](body);
  log({ call, principal: out.principal ?? body.principal, request_id: body.request_id, reservation_id: body.reservation_id ?? out.reservation_id, outcome: out.ok ?? out.active, code: out.code });
  if (mode === 'drop-after-commit') return req.socket.destroy(); // committed, but the caller never hears about it
  return send(res, 200, out);
});

server.listen(int(env.STUB_PORT, 0), HOST, () => {
  const { port } = server.address();
  const url = `http://${HOST.includes(':') ? `[${HOST}]` : HOST}:${port}`;
  if (env.STUB_URL_FILE) writeFileSync(env.STUB_URL_FILE, url);
  console.log(`external-auth-stub listening ${url}`);
});
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => { server.close(() => process.exit(0)); server.closeAllConnections?.(); });
