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
//                             | unavailable | not_ready (the debate calls' coded 503 answers)
//   STUB_FAIL_CALLS           comma list of calls the injection applies to (default: all)
//   STUB_FAIL_COUNT           how many requests to affect (default: unlimited)
//   STUB_SLOW_MS              delay for "slow" (default 5000)
//   STUB_AGENT=1              with STUB_PRICING=1: the agent contract (POST /agent/v1/quote and /agent/v1/begin, reserve `reason`, finalize `agent`); see the AGENT section below
//   STUB_FEATURES             Debate contract v1 calls to advertise in introspect `features` (comma list of finalize, fetch,
//                             authorize-run; default none = the original protocol only, and those calls answer 404)
//   STUB_DEBATE_CREDITS       flat price of an ok, stored debate with calls (default: the per-call price of its usage)
//   STUB_DEBATE_FAILED_CREDITS  price of an error or timeout debate with calls (default 0; never above the hold)
//   STUB_FETCH_PER_MIN        fetch rate limit per principal (default 120)
//
// Test-only admin endpoints (service token required): GET /_stub/state, POST /_stub/inject {mode,calls,count,ms},
// POST /_stub/revoke {key_id}, POST /_stub/features {features}, POST /_stub/tombstone {debate_id?, principal?},
// POST /_stub/web-debate {reservation_id, debate_id, question} (a web debate created before its run), POST /_stub/panel
// {principal, providers: [{id, family}] | null} and POST /_stub/panel-mode {mode: 404 | 5xx | slow | garbled | redirect | null}.
// A real service has no such thing.
//
// Per-account model panels (pilot.e3d.ai docs/panel-config-spec.md 4.2; NOT part of the hook protocol): POST /panel/v1/resolve
// {principal} with the service token and X-E3D-Panel-Version: 1 answers { ok: true, source, providers: [{id, family}] }, the
// panel set for that principal or STUB_PANEL_DEFAULT (comma list of id:family; default anthropic-api:anthropic,
// openai-api:openai) for any other, identically.
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
const DEBATE_CREDITS = env.STUB_DEBATE_CREDITS ? int(env.STUB_DEBATE_CREDITS, null) : null;
const FAILED_CREDITS = int(env.STUB_DEBATE_FAILED_CREDITS, 0);
let FEATURES = (env.STUB_FEATURES ?? '').split(',').map((f) => f.trim()).filter(Boolean);

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
let agentHdr = false;           // the current request carries X-E3D-Agent-Version: 1
let reserveRefuse = null;       // { code, reason, retry_after_seconds?, count }
const reservations = new Map(); // reservation_id -> { id, request_id, principal, units, hold, state, expires_at, settlement }
const byRequest = new Map();    // request_id -> reservation_id
const settlements = [];         // every accepted charge, in order: { reservation_id, principal, charge, outcome }
const cost = (calls, tokens) => calls * PER_CALL + Math.ceil(tokens / 1000) * PER_KTOKEN;
// Debate contract v1: stored debates, one finalize effect per reservation, immutable run bindings, tombstones.
const debates = new Map();       // debate_id -> { debate_id, reservation_id, principal, status, outcome, question, providers, rounds, result, usage, credits_charged, created_at, finished_at, truncated, transcript }
const finalizations = new Map(); // reservation_id -> { key: sha256 of the canonical body, answer }
const bindings = new Map();      // reservation_id -> { debate_id, answer }   (authorize-run)
const finalizeRequests = {};     // reservation_id -> every finalize request received (replays included)
const received = {};             // call -> requests that arrived (counted before any failure injection)
const effects = [];              // one entry per applied finalize: { reservation_id, debate_id, stored, charged }
const tombstones = new Set();    // deleted debate ids
const closed = new Set();        // closed accounts (principals)
// Canonical JSON (contract fixtures): keys sorted recursively by UTF-16 code unit, arrays in order, no whitespace.
// (by hand: JSON.stringify would order integer-like keys numerically)
const canon = (v) => {
  if (Array.isArray(v)) return `[${v.map((x) => (x === undefined ? 'null' : canon(x))).join(',')}]`;
  if (v !== null && typeof v === 'object') return `{${Object.keys(v).filter((k) => v[k] !== undefined).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)).map((k) => `${JSON.stringify(k)}:${canon(v[k])}`).join(',')}}`;
  return JSON.stringify(v);
};
const DEBATE_STATUS = { invalid: 400, not_found: 404, conflict: 409, too_large: 413, rate_limited: 429, unavailable: 503, not_ready: 503 };
const refuse = (code) => ({ ok: false, code });

// held -> expired once its time passes: the funds are released, the liability for a later settle is kept.
function sweep() {
  const t = Date.now();
  for (const r of reservations.values()) if (r.state === 'held' && Date.parse(r.expires_at) <= t) { r.state = 'expired'; r.hold = 0; log({ call: 'expire', reservation_id: r.id }); }
}
const holds = (principal) => [...reservations.values()].filter((r) => r.principal === principal && r.state === 'held');
const available = (a) => a.balance - holds(a.principal).reduce((s, r) => s + r.hold, 0);
const view = (r) => ({ ok: true, reservation_id: r.id, expires_at: r.expires_at });

// ---- request validation (the same rules as docs/external-auth/*.request.schema.json) ----
const re = { debate: /^dbt_[0-9a-f]{24}$/, principal: /^[A-Za-z0-9_.:-]{1,80}$/, uuid: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/, rid: /^[A-Za-z0-9_.:-]{1,128}$/, tool: /^[A-Za-z0-9_.-]{1,64}$/, token: /^[!-~]{1,512}$/, reason: /^[a-z0-9_]{1,40}$/, word64: /^[!-~]{1,64}$/, word128: /^[!-~]{1,128}$/ };
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
  // Debate contract v1 (docs/external-auth/finalize.schema.json, fetch.schema.json, authorize-run.schema.json)
  finalize: (b) => re.rid.test(b.reservation_id ?? '') && re.debate.test(b.debate_id ?? '') && ['connector', 'web'].includes(b.source)
    && ['ok', 'error', 'timeout'].includes(b.outcome) && obj(b.actual) && n(b.actual.calls, 10000) && n(b.actual.est_input_tokens, 1e9) && n(b.actual.est_output_tokens, 1e9)
    && Array.isArray(b.models) && b.models.length <= 32 && b.models.every((m) => obj(m) && re.word64.test(m.provider ?? '') && re.word128.test(m.model ?? '') && n(m.calls, 10000))
    && n(b.duration_ms, 86400000) && question(b.question) && Array.isArray(b.providers) && b.providers.length <= 16 && b.providers.every((p) => re.word64.test(p ?? ''))
    && n(b.rounds, 100) && (b.outcome === 'ok' ? result(b.result) : b.result === null)
    && (b.transcript === null || (typeof b.transcript === 'string' && [...b.transcript].length <= 480 * 1024)) && typeof b.truncated === 'boolean' && ts(b.started_at) && ts(b.finished_at),
  fetch: (b) => re.debate.test(b.debate_id ?? '') && re.principal.test(b.principal ?? '') && typeof b.include_transcript === 'boolean',
  'authorize-run': (b) => re.rid.test(b.reservation_id ?? '') && re.debate.test(b.debate_id ?? ''),
};
function question(q) { return typeof q === 'string' && q.length > 0 && [...q].length <= 8000 && !/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/.test(q); }
function text(t) { return typeof t === 'string' && [...t].length <= 20000; }
function result(r) {
  return obj(r) && text(r.final_answer) && ['full', 'majority', 'split', 'unknown'].includes(r.consensus) && text(r.dissent)
    && Array.isArray(r.positions) && r.positions.length <= 16 && r.positions.every((p) => obj(p) && re.word64.test(p.provider ?? '') && re.word128.test(p.model ?? '') && text(p.position));
}
function ts(t) { return typeof t === 'string' && t.length <= 64 && /^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(\.\d{1,9})?([Zz]|[+-]\d{2}:\d{2})$/.test(t) && Number.isFinite(Date.parse(t)); }
const DEBATE_CALLS = new Set(['finalize', 'fetch', 'authorize-run']);
// Settle payloads are compared on their known fields only (unknown fields are ignored).
const settleKey = (b) => JSON.stringify([b.actual.calls, b.actual.est_input_tokens, b.actual.est_output_tokens, b.models.map((m) => [m.provider, m.model, m.calls]), b.outcome, b.duration_ms]);

// ---- the protocol ----
const ops = {
  introspect(b) {
    const k = keys.get(hex(b.token));
    if (!k || k.revoked || (k.expires_at && Date.parse(k.expires_at) <= Date.now())) return { active: false };
    return { active: true, principal: k.principal, ...(k.tools ? { tools: k.tools } : {}), ...(k.limits ? { limits: k.limits } : {}), ...(k.expires_at ? { expires_at: k.expires_at } : {}), ...(FEATURES.length ? { features: FEATURES } : {}) };
  },
  reserve(b) {
    // STUB_AGENT: /_stub/reserve-refuse makes the next reserves refuse with a hook code; an agent caller also gets the catalog `reason`
    if (reserveRefuse && reserveRefuse.count > 0 && !byRequest.has(b.request_id)) {
      reserveRefuse.count--;
      return { ok: false, code: reserveRefuse.code, message: 'refused (stub)', ...(agentHdr ? { reason: reserveRefuse.reason, ...(reserveRefuse.retry_after_seconds !== undefined ? { retry_after_seconds: reserveRefuse.retry_after_seconds } : {}) } : {}) };
    }
    const a = accounts.get(b.principal);
    if (!a) return { ok: false, code: 'unknown_principal', message: 'no such account' };
    const existing = reservations.get(byRequest.get(b.request_id));
    if (existing) {
      if (existing.principal !== b.principal || existing.units.calls !== b.units.calls || existing.units.est_tokens !== b.units.est_tokens) return { ok: false, code: 'conflict', message: 'request_id was already used with different parameters' };
      return view(existing); // idempotent: the same reservation, whatever its state now
    }
    if (a.status === 'suspended') return { ok: false, code: 'suspended', message: 'account suspended' };
    if (holds(a.principal).length >= a.max_holds) return { ok: false, code: 'limit_reached', message: 'too many reservations in progress' };
    const quoted = PRICING ? quotes.get(b.request_id.toLowerCase()) : null;
    if (quoted && b.units.calls !== quoted.calls) return { ok: false, code: 'limit_reached', message: 'pricing basis mismatch' };
    const hold = quoted ? quoted.answer.credits : cost(b.units.calls, b.units.est_tokens);
    if (available(a) < hold) return { ok: false, code: 'insufficient_credits', message: `this debate needs up to ${hold} credits; ${Math.max(available(a), 0)} available` };
    const r = { id: `res_${randomUUID()}`, request_id: b.request_id, principal: a.principal, units: { ...b.units }, hold, price: hold, state: 'held', expires_at: new Date(Date.now() + TTL_MS).toISOString(), settlement: null };
    reservations.set(r.id, r); byRequest.set(b.request_id, r.id);
    if (quoted) { quoted.reservation_id = r.id; order.push(['reserve', r.id]); }
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
  // Settle and store in one step, idempotent per reservation: the same canonical body returns the original answer, a
  // different one is a conflict. Ownership comes from the reservation, never from the body. A tombstoned debate or a closed
  // account settles nothing and stores nothing (stored:false, charged 0, the hold released).
  finalize(b) {
    const r = reservations.get(b.reservation_id);
    if (!r) return refuse('not_found');
    const key = hex(canon(b));
    const prior = finalizations.get(r.id);
    if (prior) return prior.key === key ? prior.answer : refuse('conflict');
    const other = debates.get(b.debate_id);
    if (other && other.reservation_id !== r.id) return refuse('conflict');
    const bound = bindings.get(r.id);
    if (bound && bound.debate_id !== b.debate_id) return refuse('conflict');
    if (r.state === 'settled') return refuse('conflict'); // already charged through settle
    const stored = !(tombstones.has(b.debate_id) || closed.has(r.principal));
    let charged = 0;
    if (stored && b.actual.calls > 0) {
      charged = b.outcome === 'ok' ? (DEBATE_CREDITS ?? cost(b.actual.calls, b.actual.est_input_tokens + b.actual.est_output_tokens)) : Math.min(FAILED_CREDITS, r.price);
    }
    accounts.get(r.principal).balance -= charged;
    r.state = charged > 0 ? 'settled' : 'released'; r.hold = 0; r.settlement = { key: `finalize:${key}`, charge: charged, outcome: b.outcome };
    if (charged > 0) settlements.push({ reservation_id: r.id, principal: r.principal, charge: charged, outcome: b.outcome, call: 'finalize' });
    if (stored) {
      debates.set(b.debate_id, {
        debate_id: b.debate_id, reservation_id: r.id, principal: r.principal, source: b.source, status: b.outcome === 'ok' ? 'done' : 'failed', outcome: b.outcome,
        question: b.question, providers: [...b.providers], rounds: b.rounds, result: b.result, usage: { ...b.actual }, credits_charged: charged,
        created_at: other?.created_at ?? b.started_at, finished_at: b.finished_at, truncated: b.truncated, transcript: b.transcript,
      });
    }
    effects.push({ reservation_id: r.id, debate_id: b.debate_id, stored, charged });
    const answer = { ok: true, stored, charged };
    const q = PRICING ? quotes.get(r.request_id.toLowerCase()) : null;
    if (q) {
      order.push(['finalize', r.id]);
      const rep = usageReports.get(r.id);
      answer.pricing = { quote_credits: q.answer.credits, charged_credits: charged, rate_version: q.answer.rate_version,
        ...(rep && q.search ? { search: searchPriced(q, rep.rows) } : {}),
        usage: rep ? { input_tokens: rep.rows.reduce((t, x) => t + x.input_tokens, 0), output_tokens: rep.rows.reduce((t, x) => t + x.output_tokens, 0), source: rep.rows.some((x) => x.source === 'bytes') ? 'estimate' : 'vendor' }
          : { input_tokens: b.actual.est_input_tokens, output_tokens: b.actual.est_output_tokens, source: 'estimate' } };
    }
    if (agentHdr && AGENT) answer.agent = agentFor(b.outcome, b.result, b.truncated, q ? q.answer.credits : null, charged);
    finalizations.set(r.id, { key, answer });
    if (AGENT) { const run = [...agentRuns.values()].find((x) => x.quoteId === r.request_id); if (run) { run.state = 'done'; run.reservation_id = r.id; run.debate_id = b.debate_id; run.outcome = b.outcome; } }
    return answer;
  },
  // The principal is a claim, compared with the owner; unknown and foreign debates answer identically.
  fetch(b) {
    if (limited(`fetch:${b.principal}`, int(env.STUB_FETCH_PER_MIN, 120))) return refuse('rate_limited');
    const d = debates.get(b.debate_id);
    if (!d || d.principal !== b.principal) return refuse('not_found');
    const debate = { debate_id: d.debate_id, status: d.status, outcome: d.outcome, question: d.question, providers: d.providers, rounds: d.rounds, result: d.result, usage: d.usage, credits_charged: d.credits_charged, created_at: d.created_at, finished_at: d.finished_at, truncated: d.truncated };
    if (b.include_transcript) debate.transcript = d.transcript ?? null;
    return { ok: true, debate };
  },
  // Binds a held reservation to a debate id, immutably; the same pair always gets the same answer.
  'authorize-run'(b) {
    const r = reservations.get(b.reservation_id);
    if (!r) return refuse('not_found');
    // Once a reservation is finalized nothing may be authorized for it again, even the same pair: a repeated run request for a
    // finished debate must never start a second run.
    if (finalizations.has(r.id)) return refuse('conflict');
    const bound = bindings.get(r.id);
    if (bound) return bound.debate_id === b.debate_id ? bound.answer : refuse('conflict');
    const d = debates.get(b.debate_id);
    if (d && d.reservation_id !== r.id) return refuse('conflict');
    if ([...bindings.values()].some((x) => x.debate_id === b.debate_id)) return refuse('conflict');
    if (r.state !== 'held' || finalizations.has(r.id)) return refuse('conflict');
    const answer = { ok: true, principal: r.principal, price_credits: r.price, status: d ? 'bound' : 'reserved' };
    bindings.set(r.id, { debate_id: b.debate_id, answer });
    return answer;
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
const readBody = (req, cap = 16384) => new Promise((resolve) => {
  const chunks = []; let size = 0;
  req.on('data', (c) => { size += c.length; if (size <= cap) chunks.push(c); });
  req.on('end', () => resolve(size > cap ? null : Buffer.concat(chunks).toString('utf8')));
  req.on('error', () => resolve(null));
});

// ---- token pricing side channels (not the hook protocol; docs/token-pricing.md): STUB_PRICING=1 serves them ----
// POST /pricing/v1/quote (x-e3d-pricing-version: 1) and POST /usage/v1/report (x-e3d-usage-version: 1), as billing's
// docs/token-pricing-interface.md sections 2 and 4 describe them: a quote is write-once under its request id; a reserve with a
// quoted request id must carry units.calls = providers x rounds + 1; a usage report is validated against that manifest and accepted
// once per reservation; a finalize of a quoted reservation answers with a `pricing` object. Limits per provider come from
// STUB_PRICING_LIMITS ({"<provider>": {"maxTokens": n, "answerBytes": n}}); a provider not in it has no rate.
// STUB_SEARCH=1 also answers web search (per_token_search_v1; billing's docs/token-pricing-search-spec.md 22.1): a version 2 quote with `searches`
// {provider: k} gets a `search` object (effective caps: the providers of STUB_SEARCH_PROVIDERS, default all four, at most 2 per call; cite_bytes
// STUB_SEARCH_CITE_BYTES, default 1000; 5 credits per searching call on top); a version 2 usage report may carry `searches` per row (a whole number
// or null) and the finalize answer's pricing gets `search: {searches, charged_credits_search}` (reported searches clamped to each key's cap, 1 credit each).
// Without STUB_SEARCH a version 2 quote is answered like billing before the feature: no `search` object.
const PRICING = env.STUB_PRICING === '1';
const SEARCH = env.STUB_SEARCH === '1';
const SEARCH_PROVIDERS = env.STUB_SEARCH_PROVIDERS ? env.STUB_SEARCH_PROVIDERS.split(',') : ['anthropic-api', 'openai-api', 'gemini-api', 'xai-api'];
const RATE_LIMITS = env.STUB_PRICING_LIMITS ? JSON.parse(env.STUB_PRICING_LIMITS) : { 'anthropic-api': { maxTokens: 700, answerBytes: 6000 }, 'openai-api': { maxTokens: 700, answerBytes: 6000 }, 'gemini-api': { maxTokens: 700, answerBytes: 6000 }, 'xai-api': { maxTokens: 700, answerBytes: 6000 } };
const QUOTE_MAX_CREDITS = int(env.STUB_QUOTE_MAX_CREDITS, 1000);
const quotes = new Map();       // request_id -> { key, answer, basis, calls, reservation_id }
const usageReports = new Map(); // reservation_id -> { key, rows, replays }
const order = [];               // the order of quote, reserve, usage and finalize calls: [call, reservation_id|request_id]
// reported searches per row, each clamped to its key's cap (the synthesizer and a provider without a cap price 0; null prices 0)
const searchPriced = (q, rows) => {
  const priced = rows.reduce((t, x) => t + (x.key === 'synth' ? 0 : Math.min(Number.isSafeInteger(x.searches) ? x.searches : 0, q.search[x.provider] ?? 0)), 0);
  return { searches: priced, charged_credits_search: priced };
};
const manifestOf = (basis) => new Set([...basis.providers.flatMap((p) => Array.from({ length: basis.rounds }, (_, i) => `r${i + 1}:${p}`)), 'synth']);
async function pricingRoute(req, res, raw, route) {
  if (req.method !== 'POST') return send(res, 405, { error: 'method_not_allowed' });
  if (!authorized(req)) return send(res, 401, { error: 'unauthorized' });
  const header = route === 'quote' ? 'x-e3d-pricing-version' : 'x-e3d-usage-version';
  const version = req.headers[header];
  if (version !== '1' && version !== '2') return send(res, 400, { error: 'unsupported_version' });
  received[route] = (received[route] ?? 0) + 1;
  received[`${route}_v${version}`] = (received[`${route}_v${version}`] ?? 0) + 1;
  let b; try { b = JSON.parse(raw || ''); } catch { return send(res, 400, { ok: false, code: 'invalid' }); }
  if (!obj(b)) return send(res, 400, { ok: false, code: 'invalid' });
  if (route === 'quote') {
    const okShape = re.principal.test(b.principal ?? '') && re.uuid.test(b.request_id ?? '') && Array.isArray(b.providers) && b.providers.length >= 1 && b.providers.length <= 16 && b.providers.every((p) => re.word64.test(p ?? ''))
      && n(b.rounds, 10, 1) && n(b.max_words, 10000, 1) && n(b.question_bytes, 32000, 1) && /^[0-9a-f]{64}$/.test(b.question_sha256 ?? '') && /^v[0-9]{1,4}$/.test(b.prompt_version ?? '');
    if (!okShape) return send(res, 400, { ok: false, code: 'invalid' });
    const reqId = b.request_id.toLowerCase();
    const key = hex(canon(b));
    const prior = quotes.get(reqId);
    if (prior) return prior.key === key ? send(res, 200, prior.answer) : send(res, 409, { ok: false, code: 'conflict' });
    if (b.providers.some((p) => !RATE_LIMITS[p])) return send(res, 400, { ok: false, code: 'unknown_model_rate' });
    const creditsOff = b.providers.length * b.rounds * 3 + 2;
    // search (version 2 and STUB_SEARCH only): the effective cap map
    let effective = null;
    if (version === '2' && SEARCH && obj(b.searches)) {
      const e = Object.fromEntries(Object.entries(b.searches).filter(([p, k]) => b.providers.includes(p) && SEARCH_PROVIDERS.includes(p) && n(k, 10, 1)).map(([p, k]) => [p, Math.min(k, 2)]));
      if (Object.keys(e).length) effective = e;
    }
    const credits = creditsOff + (effective ? Object.keys(effective).length * b.rounds * 5 : 0);
    if (credits > QUOTE_MAX_CREDITS) return send(res, 400, { ok: false, code: 'quote_exceeds_limit', credits, max_credits: QUOTE_MAX_CREDITS, ...(effective ? { credits_off: creditsOff } : {}) });
    const answer = { ok: true, credits, rate_version: 'stub.1', max_credits: QUOTE_MAX_CREDITS,
      max_tokens: Object.fromEntries(b.providers.map((p) => [p, RATE_LIMITS[p].maxTokens])), answer_bytes: Object.fromEntries(b.providers.map((p) => [p, RATE_LIMITS[p].answerBytes])),
      ...(version === '2' && SEARCH ? { search: effective ? { enabled: true, max_searches: effective, cite_bytes: int(env.STUB_SEARCH_CITE_BYTES, 1000), search_credits_max: credits - creditsOff, credits_off: creditsOff } : { enabled: false, max_searches: {}, cite_bytes: 0, search_credits_max: 0, credits_off: credits } } : {}) };
    quotes.set(reqId, { key, answer, search: effective, asked: obj(b.searches) ? b.searches : null, version, basis: { providers: [...b.providers], rounds: b.rounds, max_words: b.max_words, question_sha256: b.question_sha256 }, calls: b.providers.length * b.rounds + 1, reservation_id: null });
    order.push(['quote', reqId]);
    return send(res, 200, answer);
  }
  // usage report
  if (!re.rid.test(b.reservation_id ?? '') || (b.debate_id !== undefined && !re.debate.test(b.debate_id)) || !Array.isArray(b.rows) || b.rows.length > 64) return send(res, 400, { ok: false, code: 'invalid' });
  const r = reservations.get(b.reservation_id);
  const q = r && quotes.get(r.request_id);
  if (!r || !q) return send(res, 404, { ok: false, code: 'not_found' });
  if (finalizations.has(r.id)) return send(res, 409, { ok: false, code: 'closed' });
  const manifest = manifestOf(q.basis);
  const seen = new Set();
  const rows = [];
  for (const x of b.rows) {
    if (!obj(x)) return send(res, 400, { ok: false, code: 'invalid', why: 'row' });
    if (!manifest.has(x.key)) return send(res, 400, { ok: false, code: 'invalid', why: 'unknown_key' });
    if (seen.has(x.key)) return send(res, 400, { ok: false, code: 'invalid', why: 'duplicate_key' });
    seen.add(x.key);
    if (x.key !== 'synth' && x.key.slice(x.key.indexOf(':') + 1) !== x.provider) return send(res, 400, { ok: false, code: 'invalid', why: 'provider_mismatch' });
    if (x.key === 'synth' && !q.basis.providers.includes(x.provider)) return send(res, 400, { ok: false, code: 'invalid', why: 'provider_mismatch' });
    if (!re.word128.test(x.model ?? '')) return send(res, 400, { ok: false, code: 'invalid', why: 'model' });
    if (!n(x.input_tokens, 1e9) || !n(x.output_tokens, 1e9)) return send(res, 400, { ok: false, code: 'invalid', why: 'tokens' });
    if (!['vendor', 'bytes'].includes(x.source)) return send(res, 400, { ok: false, code: 'invalid', why: 'source' });
    if (version === '2' && 'searches' in x && x.searches !== null && !n(x.searches, 1e9)) return send(res, 400, { ok: false, code: 'invalid', why: 'searches' });
    rows.push({ key: x.key, provider: x.provider, model: x.model, input_tokens: x.input_tokens, output_tokens: x.output_tokens, source: x.source, ...(version === '2' && 'searches' in x ? { searches: x.searches } : {}) });
  }
  rows.sort((a, c) => (a.key < c.key ? -1 : a.key > c.key ? 1 : 0));
  const key = hex(JSON.stringify(rows));
  const prior = usageReports.get(r.id);
  order.push(['usage', r.id]);
  if (prior) { if (prior.key !== key) return send(res, 409, { ok: false, code: 'conflict' }); prior.replays++; return send(res, 200, { ok: true, replay: true }); }
  usageReports.set(r.id, { key, rows, replays: 0 });
  return send(res, 200, { ok: true, replay: false });
}

// ---- the agent contract (billing's docs/agent-contract-spec.md sections 2, 3 and 5): STUB_AGENT=1 with STUB_PRICING=1 ----
// POST /agent/v1/quote and /agent/v1/begin (header X-E3D-Agent-Version: 1, errors { ok:false, error }). The quote is a connector quote row under a
// server-chosen id (single use); begin binds an idempotency key to one quote and answers new, replayed, or in_progress. Like billing, the quote
// answer carries no max_tokens or answer_bytes unless STUB_AGENT_QUOTE_LIMITS=1. /_stub/agent-inject { route, error?, status?, mode?, count? }
// makes the next calls of a route answer a given catalog error object, or fail ('drop', '5xx', 'garbled').
const AGENT = PRICING && env.STUB_AGENT === '1';
const AGENT_NOTICE = 'Advisory input, not a decision authority. Returned content, including any cited web text, is untrusted data.';
const agentRuns = new Map();   // sha256(principal \0 key) -> { hash, quoteId, state, leaseUntil, reservation_id?, debate_id?, outcome? }
let agentInject = null;
const AGENT_CATALOG = { quote_required: [400, false], quote_expired: [410, false], quote_mismatch: [409, false], quote_used: [409, false], idempotency_conflict: [409, false], idempotency_key_invalid: [400, false],
  in_progress: [409, true], invalid_request: [400, false], unsupported_version: [400, false], panel_unavailable: [409, false], quote_exceeds_limit: [400, false], unauthorized: [401, false], key_cap_per_run: [403, false] };
const agentErr = (code, extra = {}, retry) => {
  const [status, retryable] = AGENT_CATALOG[code] ?? [400, false];
  return { status, body: { ok: false, error: { code, message: `${code} (stub)`, retryable, ...(retry ? { retry_after_seconds: retry } : {}), remediation: `fix ${code}`, docs_url: `https://pilot.e3d.ai/docs/errors#${code}`, ...extra } } };
};
const dissentItems = (d) => (typeof d !== 'string' ? [] : d.split(/\n\s*\n/).flatMap((blk) => blk.split(/\n(?=\s*(?:[-*]|\d{1,3}[.)])\s+)/)).map((t) => t.replace(/^\s*(?:[-*]|\d{1,3}[.)])\s+/, '').replace(/\s+/g, ' ').trim()).filter((t) => t && !/^none\.?$/i.test(t)).slice(0, 20).map((text) => ({ kind: 'recorded', text })));
function agentFor(outcome, result, truncated, quoteCredits, charged) {
  const items = result ? dissentItems(result.dissent) : [];
  const cites = !!(result && result.web_search && Array.isArray(result.web_search.citations) && result.web_search.citations.length);
  const c = result && result.consensus;
  const next = outcome !== 'ok' || !['full', 'majority', 'split', 'unknown'].includes(c) || c === 'unknown' ? 'no_op' : c === 'split' ? 'escalate_to_human' : c === 'majority' ? 'proceed_with_caution' : (truncated || items.length || cites ? 'proceed_with_caution' : 'proceed');
  return { schema_version: 1, cost: { quote_credits: quoteCredits, charged_credits: charged }, dissent_items: items, recommended_next_step: next, notice: AGENT_NOTICE };
}
const KEY_LIMITS = { cap_per_run_credits: null, cap_daily_credits: 2000, cap_daily_remaining_credits: 1688, cap_total_credits: null, cap_total_remaining_credits: null, service_max_per_run_credits: QUOTE_MAX_CREDITS };
async function agentRoute(req, res, raw, route) {
  if (req.method !== 'POST') return send(res, 405, { error: 'method_not_allowed' });
  if (!authorized(req)) { const e = agentErr('unauthorized'); return send(res, e.status, e.body); }
  received[`agent_${route}`] = (received[`agent_${route}`] ?? 0) + 1;
  if (req.headers['x-e3d-agent-version'] !== '1') { const e = agentErr('unsupported_version'); return send(res, e.status, e.body); }
  if (agentInject && agentInject.route === route && agentInject.count > 0) {
    agentInject.count--;
    if (agentInject.mode === 'drop') return req.socket.destroy();
    if (agentInject.mode === '5xx') return send(res, 503, { error: 'injected' });
    if (agentInject.mode === 'garbled') return send(res, 200, '{"ok": tru');
    return send(res, agentInject.status ?? 400, { ok: false, error: agentInject.error });
  }
  let b; try { b = JSON.parse(raw || ''); } catch { const e = agentErr('invalid_request'); return send(res, e.status, e.body); }
  const bad = (code, extra, retry) => { const e = agentErr(code, extra, retry); return send(res, e.status, e.body); };
  const shapeOk = obj(b) && re.principal.test(b.principal ?? '') && Array.isArray(b.providers) && b.providers.length >= 1 && b.providers.length <= 16 && b.providers.every((p) => re.word64.test(p ?? ''))
    && n(b.rounds, 10, 1) && n(b.max_words, 10000, 1) && /^[0-9a-f]{64}$/.test(b.question_sha256 ?? '');
  if (!shapeOk) return bad('invalid_request');
  if (route === 'quote') {
    if (!n(b.question_bytes, 1e9, 1) || !/^v[0-9]{1,4}$/.test(b.prompt_version ?? '')) return bad('invalid_request');
    if (b.question_bytes > 32000) return bad('invalid_request', { max_question_bytes: 32000 });
    if (b.providers.some((p) => !RATE_LIMITS[p])) return bad('panel_unavailable');
    const creditsOff = b.providers.length * b.rounds * 3 + 2;
    let effective = null;
    if (SEARCH && obj(b.searches)) {
      const e = Object.fromEntries(Object.entries(b.searches).filter(([p, k]) => b.providers.includes(p) && SEARCH_PROVIDERS.includes(p) && n(k, 100, 1)).map(([p, k]) => [p, Math.min(k, 2)]));
      if (Object.keys(e).length) effective = e;
    }
    const credits = creditsOff + (effective ? Object.keys(effective).length * b.rounds * 5 : 0);
    if (credits > QUOTE_MAX_CREDITS) return bad('quote_exceeds_limit', { credits, per_debate_limit_credits: QUOTE_MAX_CREDITS });
    const id = randomUUID();
    const search = effective ? { enabled: true, max_searches: effective, cite_bytes: int(env.STUB_SEARCH_CITE_BYTES, 1000), search_credits_max: credits - creditsOff, credits_off: creditsOff } : { enabled: false, max_searches: {}, cite_bytes: 0, search_credits_max: 0, credits_off: credits };
    const expires = Date.now() + int(env.STUB_AGENT_QUOTE_TTL_MS, 600000);
    const answer = { ok: true, credits, rate_version: 'stub.1', max_credits: QUOTE_MAX_CREDITS };
    quotes.set(id, { key: id, answer, search: effective, asked: null, version: '2', basis: { providers: [...b.providers], rounds: b.rounds, max_words: b.max_words, question_sha256: b.question_sha256 }, calls: b.providers.length * b.rounds + 1, reservation_id: null,
      agent: { principal: b.principal, expires, key: null, searchOn: !!effective } });
    order.push(['quote', id]);
    return send(res, 200, { ok: true, quote: { quote_id: id, max_credits: credits, expires_at: new Date(expires).toISOString(), ttl_seconds: 600, schema_version: 1, question_sha256: b.question_sha256, panel: b.providers, rounds: b.rounds, max_words: b.max_words, search, rate_version: 'stub.1',
      ...(env.STUB_AGENT_QUOTE_LIMITS === '1' ? { max_tokens: Object.fromEntries(b.providers.map((p) => [p, RATE_LIMITS[p].maxTokens])), answer_bytes: Object.fromEntries(b.providers.map((p) => [p, RATE_LIMITS[p].answerBytes])) } : {}) }, key_limits: KEY_LIMITS });
  }
  // begin
  if (typeof b.idempotency_key !== 'string' || !/^[A-Za-z0-9._:-]{8,128}$/.test(b.idempotency_key)) return bad('idempotency_key_invalid');
  const searchOn = b.search_enabled === true;
  const hash = hex(canon([b.principal, b.question_sha256, b.providers, b.rounds, b.max_words, searchOn]));
  const id = hex(`${b.principal}\0${b.idempotency_key}`);
  const claimQuote = () => {
    if (b.quote_id === undefined) return { err: ['quote_required'] };
    const q = typeof b.quote_id === 'string' ? quotes.get(b.quote_id) : null;
    if (!q || !q.agent || q.agent.expires <= Date.now()) return { err: ['quote_expired'] };
    const mismatch = [];
    if (q.agent.principal !== b.principal) mismatch.push('principal');
    if (q.basis.question_sha256 !== b.question_sha256) mismatch.push('question');
    if (JSON.stringify(q.basis.providers) !== JSON.stringify(b.providers)) mismatch.push('panel');
    if (q.basis.rounds !== b.rounds || q.basis.max_words !== b.max_words) mismatch.push('length');
    if (q.agent.searchOn !== searchOn) mismatch.push('search');
    if (mismatch.length) return { err: ['quote_mismatch', { mismatch }] };
    if (q.agent.key && q.agent.key !== id) return { err: ['quote_used'] };
    return { q };
  };
  const claim = (row) => {
    const c = claimQuote();
    if (c.err) return bad(...c.err);
    c.q.agent.key = id;
    c.q.agent.expires = Math.max(c.q.agent.expires, Date.now() + 120000);
    agentRuns.set(id, { hash, quoteId: b.quote_id, state: 'claimed', leaseUntil: Date.now() + 60000, v: (row?.v ?? 0) + 1 });
    return send(res, 200, { ok: true, status: 'new', request_id: b.quote_id, idempotency: { window_hours: 24 }, key_limits: KEY_LIMITS });
  };
  const row = agentRuns.get(id);
  if (!row) return claim(null);
  if (row.hash !== hash) return bad('idempotency_conflict');
  const r = reservations.get(byRequest.get(row.quoteId));
  if (row.state === 'done' || (r && finalizations.has(r.id))) {
    const d = r ? [...debates.values()].find((x) => x.reservation_id === r.id) : null;
    const q = quotes.get(row.quoteId);
    const outcome = d?.outcome ?? row.outcome ?? 'error';
    const agent = agentFor(outcome, d?.result ?? null, d?.truncated ?? false, q ? q.answer.credits : null, r?.settlement?.charge ?? 0);
    return send(res, 200, { ok: true, status: 'replayed', debate_id: d?.debate_id ?? row.debate_id ?? null, outcome, agent,
      ...(d ? { debate: { debate_id: d.debate_id, status: d.status, outcome: d.outcome, question: d.question, providers: d.providers, rounds: d.rounds, result: d.result, usage: d.usage, credits_charged: d.credits_charged, created_at: d.created_at, finished_at: d.finished_at, truncated: d.truncated } } : {}) });
  }
  if (r && r.state === 'held') return bad('in_progress', {}, 5);
  if (!r && row.leaseUntil > Date.now()) return bad('in_progress', {}, 5);
  return claim(row); // released, expired or an abandoned claim: take over with this call's quote
}

// ---- per-account model panels (not the hook protocol) ----
const PANEL_DEFAULT = (env.STUB_PANEL_DEFAULT || 'anthropic-api:anthropic,openai-api:openai').split(',').map((x) => x.trim()).filter(Boolean)
  .map((x) => { const [id, family] = x.split(':'); return { id, family }; });
const panels = new Map();
let panelMode = null;
async function resolvePanel(req, res, raw) {
  if (req.method !== 'POST') return send(res, 405, { error: 'method_not_allowed' });
  if (!authorized(req)) return send(res, 401, { error: 'unauthorized' });
  if (req.headers['x-e3d-panel-version'] !== '1') return send(res, 400, { error: 'unsupported_version' });
  received.panel = (received.panel ?? 0) + 1;
  if (panelMode === 'slow') await new Promise((r) => setTimeout(r, 5000));
  if (panelMode === '404') return send(res, 404, { error: 'not_found' });
  if (panelMode === '5xx') return send(res, 503, { error: 'injected' });
  if (panelMode === 'garbled') return send(res, 200, '{"ok": tru');
  if (panelMode === 'redirect') return send(res, 307, { error: 'moved' }, { location: '/panel/v1/resolve?x=1' });
  let b; try { b = JSON.parse(raw || ''); } catch { return send(res, 400, { error: 'invalid_json' }); }
  if (!obj(b) || typeof b.principal !== 'string') return send(res, 400, { error: 'invalid_request' });
  const mine = panels.get(b.principal);
  log({ call: 'panel', principal: b.principal, source: mine ? 'account' : 'default' });
  return send(res, 200, { ok: true, source: mine ? 'account' : 'default', providers: mine ?? PANEL_DEFAULT });
}

const server = http.createServer(async (req, res) => {
  const path = (req.url ?? '').split('?')[0];
  const call = path.replace(/^\/+/, '');
  const raw = req.method === 'POST' ? await readBody(req, call === 'finalize' ? 512 * 1024 : 16384) : '';
  if (path === '/panel/v1/resolve') return resolvePanel(req, res, raw);
  if (PRICING && path === '/pricing/v1/quote') return pricingRoute(req, res, raw, 'quote');
  if (PRICING && path === '/usage/v1/report') return pricingRoute(req, res, raw, 'usage');
  if (AGENT && (path === '/agent/v1/quote' || path === '/agent/v1/begin')) return agentRoute(req, res, raw, path.slice('/agent/v1/'.length));

  // test-only admin
  if (path.startsWith('/_stub/')) {
    if (!authorized(req)) return send(res, 401, { error: 'unauthorized' });
    sweep();
    if (path === '/_stub/state' && req.method === 'GET') {
      return send(res, 200, {
        accounts: Object.fromEntries([...accounts.values()].map((a) => [a.principal, { balance: a.balance, available: available(a), status: a.status, holds: holds(a.principal).length }])),
        reservations: [...reservations.values()].map((r) => ({ reservation_id: r.id, request_id: r.request_id, principal: r.principal, state: r.state, hold: r.hold, charge: r.settlement?.charge ?? 0 })),
        settlements,
        features: FEATURES,
        // no debate content here: ids, states and amounts only
        debates: [...debates.values()].map((d) => ({ debate_id: d.debate_id, reservation_id: d.reservation_id, principal: d.principal, status: d.status, outcome: d.outcome, credits_charged: d.credits_charged, truncated: d.truncated, has_result: d.result != null, transcript_bytes: d.transcript == null ? null : Buffer.byteLength(d.transcript) })),
        finalize_requests: finalizeRequests, effects, received,
        ...(AGENT ? { agent: { runs: [...agentRuns.values()].map((x) => ({ quote_id: x.quoteId, state: x.state, outcome: x.outcome ?? null })), quotes: [...quotes.values()].filter((x) => x.agent).length } } : {}),
        ...(PRICING ? { pricing: { quotes: [...quotes.entries()].map(([id, x]) => ({ request_id: id, calls: x.calls, reservation_id: x.reservation_id, providers: x.basis.providers, rounds: x.basis.rounds, max_words: x.basis.max_words, version: x.version, asked: x.asked, search: x.search, agent: x.agent ? true : null })),
          reports: Object.fromEntries([...usageReports.entries()].map(([id, x]) => [id, { rows: x.rows, replays: x.replays }])), order } } : {}),
      });
    }
    let b; try { b = JSON.parse(raw || '{}'); } catch { return send(res, 400, { error: 'invalid_json' }); }
    if (path === '/_stub/inject' && req.method === 'POST') {
      inject = { mode: b.mode || null, calls: b.calls ?? null, count: b.count ?? Infinity, ms: b.ms ?? 5000 };
      return send(res, 200, { ok: true });
    }
    if (path === '/_stub/features' && req.method === 'POST') {
      FEATURES = Array.isArray(b.features) ? b.features.map(String) : [];
      return send(res, 200, { ok: true, features: FEATURES });
    }
    if (path === '/_stub/tombstone' && req.method === 'POST') {
      if (b.debate_id) { tombstones.add(b.debate_id); debates.delete(b.debate_id); }
      if (b.principal) { closed.add(b.principal); for (const [id, d] of debates) if (d.principal === b.principal) debates.delete(id); }
      return send(res, 200, { ok: true });
    }
    if (path === '/_stub/web-debate' && req.method === 'POST') {
      const r = reservations.get(b.reservation_id);
      if (!r || !re.debate.test(b.debate_id ?? '') || !question(b.question)) return send(res, 400, { ok: false });
      debates.set(b.debate_id, { debate_id: b.debate_id, reservation_id: r.id, principal: r.principal, source: 'web', status: 'queued', outcome: null, question: b.question, providers: [], rounds: 0, result: null, usage: { calls: 0, est_input_tokens: 0, est_output_tokens: 0 }, credits_charged: 0, created_at: new Date().toISOString(), finished_at: null, truncated: false, transcript: null });
      return send(res, 200, { ok: true });
    }
    if (path === '/_stub/panel' && req.method === 'POST') {
      if (b.providers === null) panels.delete(b.principal); else panels.set(b.principal, b.providers);
      return send(res, 200, { ok: true });
    }
    if (path === '/_stub/panel-mode' && req.method === 'POST') {
      panelMode = b.mode ?? null;
      return send(res, 200, { ok: true });
    }
    if (path === '/_stub/agent-inject' && req.method === 'POST') { agentInject = b.route ? { ...b, count: b.count ?? 1 } : null; return send(res, 200, { ok: true }); }
    if (path === '/_stub/reserve-refuse' && req.method === 'POST') { reserveRefuse = b.code ? { ...b, count: b.count ?? 1 } : null; return send(res, 200, { ok: true }); }
    if (path === '/_stub/revoke' && req.method === 'POST') {
      let found = false;
      for (const k of keys.values()) if (k.id === b.key_id) { k.revoked = true; found = true; }
      return send(res, found ? 200 : 404, { ok: found });
    }
    return send(res, 404, { error: 'not_found' });
  }

  const isHealth = call === 'health' && req.method === 'GET';
  const debateCall = DEBATE_CALLS.has(call);
  // a debate call this service does not advertise does not exist here (version skew: the server must not call it)
  if (debateCall && !FEATURES.includes(call)) log({ call, refused: 'not_advertised' }); // visible to tests: a server sent an unadvertised call
  if (!isHealth && !(req.method === 'POST' && call in ops && (!debateCall || FEATURES.includes(call)))) return send(res, 404, { error: 'not_found' });
  // health may be called without a service token; a wrong one is still refused so misconfiguration shows up
  if (!(isHealth && !req.headers.authorization) && !authorized(req)) return send(res, 401, { error: 'unauthorized' });
  if (req.headers['x-e3d-auth-version'] !== '1') return send(res, 400, { error: 'unsupported_version' });
  if (call === 'introspect' && limited('introspect', int(env.STUB_INTROSPECT_PER_MIN, 600))) return send(res, 429, { error: 'rate_limited' }, { 'retry-after': '60' });
  if (isHealth && limited('health', int(env.STUB_HEALTH_PER_MIN, 120))) return send(res, 429, { error: 'rate_limited' }, { 'retry-after': '60' });

  received[call] = (received[call] ?? 0) + 1;
  const mode = injected(call);
  if (mode === 'slow') await new Promise((r) => setTimeout(r, inject.ms));
  if (mode === '5xx') return send(res, 503, { error: 'injected' });
  if (mode === 'malformed') return send(res, 200, '{"ok": tru');
  if (mode === 'oversized') return send(res, 200, JSON.stringify({ ok: true, active: false, status: 'ok', pad: 'x'.repeat(100 * 1024) }));
  if (mode === 'redirect') return send(res, 307, { error: 'moved' }, { location: `${path}?redirected=1` }) // following it would succeed;
  if (mode === 'invalid') return send(res, 200, { ok: 'yes', active: 'yes', principal: 'not a valid principal!', status: 'nope' });
  if (mode === 'drop') return req.socket.destroy();
  if (mode === 'unavailable' || mode === 'not_ready') return send(res, 503, refuse(mode));

  if (isHealth) return send(res, 200, { status: 'ok', ...(env.STUB_HEALTH_FEATURES === '1' && FEATURES.length ? { features: FEATURES } : {}) });
  // the debate calls answer errors with { ok:false, code } and the code's HTTP status
  const answer = (code) => send(res, DEBATE_STATUS[code], refuse(code));
  if (raw === null) return debateCall ? answer('too_large') : send(res, 413, { error: 'too_large' });
  let body; try { body = JSON.parse(raw); } catch { return debateCall ? answer('invalid') : send(res, 400, { error: 'invalid_json' }); }
  if (!obj(body) || !valid[call](body)) return debateCall ? answer('invalid') : send(res, 400, { error: 'invalid_request' });

  sweep();
  if (call === 'finalize') finalizeRequests[body.reservation_id] = (finalizeRequests[body.reservation_id] ?? 0) + 1;
  agentHdr = req.headers['x-e3d-agent-version'] === '1'; // read by reserve and finalize
  const out = ops[call](body);
  // ids, outcomes and codes only: never a question, an answer or a transcript
  log({ call, principal: out.principal ?? body.principal, request_id: body.request_id, reservation_id: body.reservation_id ?? out.reservation_id, debate_id: body.debate_id, outcome: out.ok ?? out.active, code: out.code, ...(call === 'finalize' && out.ok ? { stored: out.stored, charged: out.charged } : {}) });
  if (mode === 'drop-after-commit') return req.socket.destroy(); // committed, but the caller never hears about it
  if (debateCall && out.ok === false) return answer(out.code);
  return send(res, 200, out);
});

server.listen(int(env.STUB_PORT, 0), HOST, () => {
  const { port } = server.address();
  const url = `http://${HOST.includes(':') ? `[${HOST}]` : HOST}:${port}`;
  if (env.STUB_URL_FILE) writeFileSync(env.STUB_URL_FILE, url);
  console.log(`external-auth-stub listening ${url}`);
});
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => { server.close(() => process.exit(0)); server.closeAllConnections?.(); });
