// Client for the external auth and metering service (protocol: docs/external-auth.md). Zero dependencies.
//
//   introspect(token)  is this bearer token valid, and whose is it?  (cached, deduplicated, capped)
//   reserve(args)      may this principal spend?  -> { ok, reservation_id, expires_at } or a business refusal
//   settle(args)       report actual usage (single attempt; durable retry lives in the outbox)
//   release(args)      give back a hold that was never used (single attempt)
//   settleDurable(args) / releaseDurable(args)
//                      one immediate attempt, then the durable outbox (lib/mcp/outbox.js) on any failure; never throw
//   health()           GET <url>/health
//
// Every call: https (http only to loopback), no redirects, a timeout, a 16 KB request cap, a 64 KB response cap,
// and strict validation of known fields against SCHEMAS (unknown fields are ignored). Failures throw
// AuthServiceError with kind "unavailable" (transport, timeout, non-2xx, redirect), "bad-response" (malformed,
// oversized, schema-invalid) or "config" (401/403 for the service token, bad configuration). Business refusals
// (HTTP 200, ok:false) are returned, not thrown. Neither the caller's token nor the service token is ever logged.
import { createHash } from 'node:crypto';
import { readFileSync, statSync } from 'node:fs';

export const PROTOCOL_VERSION = '1';
export const LIMITS = { requestBytes: 16 * 1024, responseBytes: 64 * 1024, maxTokenLength: 512, cacheEntries: 5000, negativeTtlMs: 5000, clockSkewMs: 60000 };
const DEFAULT_TIMEOUTS = { introspect: 3000, reserve: 3000, health: 3000, settle: 10000, release: 10000 };
const LOOPBACK = new Set(['127.0.0.1', '[::1]', '::1', 'localhost']);
const isLoopback = (host) => LOOPBACK.has(host) || /^127\.\d+\.\d+\.\d+$/.test(host);
const sha256 = (s) => createHash('sha256').update(s).digest('hex');
const TOKEN_RE = /^[!-~]+$/; // printable ASCII, no spaces

export class AuthServiceError extends Error {
  constructor(kind, message) { super(message); this.name = 'AuthServiceError'; this.kind = kind; }
}

// ---- JSON Schemas (the docs/external-auth/*.schema.json files must equal these; tests/mcp-extauth.sh checks) ----
const BASE_ID = 'https://github.com/spacepacket1/e3d-pilot/blob/main/docs/external-auth/';
const DRAFT = 'https://json-schema.org/draft/2020-12/schema';
const int = (maximum, minimum = 0) => ({ type: 'integer', minimum, maximum });
const PRINCIPAL = { type: 'string', pattern: '^[A-Za-z0-9_.:-]{1,80}$' };
const RESERVATION_ID = { type: 'string', pattern: '^[A-Za-z0-9_.:-]{1,128}$' };
const REQUEST_ID = { type: 'string', pattern: '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' };
const TIMESTAMP = { type: 'string', format: 'date-time', maxLength: 64 };
const TOOL = { type: 'string', pattern: '^[A-Za-z0-9_.-]{1,64}$' };
const MESSAGE = { type: 'string', maxLength: 500 };
export const REFUSAL_CODES = ['insufficient_credits', 'suspended', 'limit_reached', 'unknown_principal', 'conflict'];
export const OUTCOMES = ['ok', 'error', 'timeout', 'orphaned'];
const schema = (name, title, body) => ({ $schema: DRAFT, $id: `${BASE_ID}${name}.schema.json`, title, ...body });

export const SCHEMAS = {
  'introspect.request': schema('introspect.request', 'introspect request', {
    type: 'object', required: ['token'],
    properties: { token: { type: 'string', minLength: 1, maxLength: 512, pattern: '^[!-~]+$' } },
  }),
  'introspect.response': schema('introspect.response', 'introspect response', {
    oneOf: [
      { type: 'object', required: ['active', 'principal'], properties: {
        active: { const: true }, principal: PRINCIPAL,
        tools: { type: 'array', maxItems: 64, items: TOOL },
        limits: { type: 'object', properties: { rate_per_min: int(100000, 1), max_inflight: int(1000, 1) } },
        expires_at: TIMESTAMP,
      } },
      { type: 'object', required: ['active'], properties: { active: { const: false } } },
    ],
  }),
  'reserve.request': schema('reserve.request', 'reserve request', {
    type: 'object', required: ['principal', 'request_id', 'kind', 'tool', 'units'],
    properties: {
      principal: PRINCIPAL, request_id: REQUEST_ID, kind: { const: 'debate' }, tool: TOOL,
      units: { type: 'object', required: ['calls', 'est_tokens'], properties: { calls: int(10000, 1), est_tokens: int(1000000000) } },
    },
  }),
  'reserve.response': schema('reserve.response', 'reserve response', {
    oneOf: [
      { type: 'object', required: ['ok', 'reservation_id', 'expires_at'], properties: { ok: { const: true }, reservation_id: RESERVATION_ID, expires_at: TIMESTAMP } },
      { type: 'object', required: ['ok', 'code'], properties: { ok: { const: false }, code: { enum: REFUSAL_CODES }, message: MESSAGE } },
    ],
  }),
  'settle.request': schema('settle.request', 'settle request', {
    type: 'object', required: ['reservation_id', 'actual', 'models', 'outcome', 'duration_ms'],
    properties: {
      reservation_id: RESERVATION_ID,
      actual: { type: 'object', required: ['calls', 'est_input_tokens', 'est_output_tokens'], properties: { calls: int(10000), est_input_tokens: int(1000000000), est_output_tokens: int(1000000000) } },
      models: { type: 'array', maxItems: 32, items: { type: 'object', required: ['provider', 'model', 'calls'], properties: {
        provider: { type: 'string', pattern: '^[!-~]{1,64}$' }, model: { type: 'string', pattern: '^[!-~]{1,128}$' }, calls: int(10000),
      } } },
      outcome: { enum: OUTCOMES }, duration_ms: int(86400000),
    },
  }),
  'settle.response': schema('settle.response', 'settle response', {
    oneOf: [
      { type: 'object', required: ['ok'], properties: { ok: { const: true } } },
      { type: 'object', required: ['ok', 'code'], properties: { ok: { const: false }, code: { const: 'conflict' }, message: MESSAGE } },
    ],
  }),
  'release.request': schema('release.request', 'release request', {
    type: 'object', required: ['reason'],
    properties: { reservation_id: RESERVATION_ID, request_id: REQUEST_ID, reason: { type: 'string', pattern: '^[a-z0-9_]{1,40}$' } },
    oneOf: [{ required: ['reservation_id'] }, { required: ['request_id'] }],
  }),
  'release.response': schema('release.response', 'release response', {
    type: 'object', required: ['ok'], properties: { ok: { const: true } },
  }),
  'health.request': schema('health.request', 'health request (GET, no body)', { type: 'object', maxProperties: 0 }),
  'health.response': schema('health.response', 'health response', {
    type: 'object', required: ['status'], properties: { status: { const: 'ok' } },
  }),
};

// A validator for the subset of JSON Schema used above. Returns a list of error strings (empty = valid).
const RFC3339 = /^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(\.\d{1,9})?([Zz]|[+-]\d{2}:\d{2})$/;
const typeOk = (t, v) => ({
  object: v !== null && typeof v === 'object' && !Array.isArray(v), array: Array.isArray(v), string: typeof v === 'string',
  integer: Number.isSafeInteger(v), number: typeof v === 'number' && Number.isFinite(v), boolean: typeof v === 'boolean', null: v === null,
})[t] ?? false;
export function validateSchema(s, v, path = '$') {
  const errs = [];
  if (s.type && !typeOk(s.type, v)) return [`${path}: expected ${s.type}`];
  if ('const' in s && v !== s.const) errs.push(`${path}: expected ${JSON.stringify(s.const)}`);
  if (s.enum && !s.enum.includes(v)) errs.push(`${path}: not one of ${s.enum.join(', ')}`);
  if (typeof v === 'string') {
    if (s.minLength != null && v.length < s.minLength) errs.push(`${path}: shorter than ${s.minLength}`);
    if (s.maxLength != null && v.length > s.maxLength) errs.push(`${path}: longer than ${s.maxLength}`);
    if (s.pattern && !new RegExp(s.pattern).test(v)) errs.push(`${path}: does not match the pattern`);
    if (s.format === 'date-time' && !(RFC3339.test(v) && Number.isFinite(Date.parse(v)))) errs.push(`${path}: not an RFC 3339 timestamp`);
  }
  if (typeof v === 'number') {
    if (s.minimum != null && v < s.minimum) errs.push(`${path}: below ${s.minimum}`);
    if (s.maximum != null && v > s.maximum) errs.push(`${path}: above ${s.maximum}`);
  }
  if (Array.isArray(v)) {
    if (s.minItems != null && v.length < s.minItems) errs.push(`${path}: fewer than ${s.minItems} items`);
    if (s.maxItems != null && v.length > s.maxItems) errs.push(`${path}: more than ${s.maxItems} items`);
    if (s.items) v.forEach((x, i) => errs.push(...validateSchema(s.items, x, `${path}[${i}]`)));
  }
  if (typeOk('object', v)) {
    if (s.maxProperties != null && Object.keys(v).length > s.maxProperties) errs.push(`${path}: more than ${s.maxProperties} properties`);
    for (const k of s.required ?? []) if (!(k in v)) errs.push(`${path}.${k}: required`);
    for (const [k, sub] of Object.entries(s.properties ?? {})) if (k in v) errs.push(...validateSchema(sub, v[k], `${path}.${k}`));
  }
  if (s.oneOf) {
    const n = s.oneOf.filter((b) => validateSchema(b, v, path).length === 0).length;
    if (n !== 1) errs.push(`${path}: matches ${n} of the allowed shapes (expected exactly 1)`);
  }
  return errs;
}

// ---- configuration ----
const intIn = (raw, dflt, lo, hi) => {
  if (raw == null || raw === '') return { value: dflt };
  const n = Number(raw);
  return Number.isSafeInteger(n) && n >= lo && n <= hi ? { value: n } : { error: true };
};

function readServiceToken(env) {
  if (env.E3D_MCP_AUTH_SERVICE_TOKEN && env.E3D_MCP_AUTH_SERVICE_TOKEN_FILE) return { error: 'set only one of E3D_MCP_AUTH_SERVICE_TOKEN and E3D_MCP_AUTH_SERVICE_TOKEN_FILE' };
  if (env.E3D_MCP_AUTH_SERVICE_TOKEN_FILE) {
    const file = env.E3D_MCP_AUTH_SERVICE_TOKEN_FILE;
    let st;
    try { st = statSync(file); } catch { return { error: 'E3D_MCP_AUTH_SERVICE_TOKEN_FILE cannot be read' }; }
    if (!st.isFile()) return { error: 'E3D_MCP_AUTH_SERVICE_TOKEN_FILE is not a regular file' };
    if (process.platform !== 'win32' && (st.mode & 0o077)) return { error: `E3D_MCP_AUTH_SERVICE_TOKEN_FILE is group- or world-accessible (mode ${(st.mode & 0o777).toString(8)}); chmod 600 it` };
    try { return { token: readFileSync(file, 'utf8').trim() }; } catch { return { error: 'E3D_MCP_AUTH_SERVICE_TOKEN_FILE cannot be read' }; }
  }
  return { token: env.E3D_MCP_AUTH_SERVICE_TOKEN ?? '' };
}

// Startup checks. Returns { ok, errors, config }; error messages never contain the URL or any token.
export function validateConfig(env = process.env, { url = env.E3D_MCP_AUTH_URL, serviceToken, fetchImpl = globalThis.fetch } = {}) {
  const errors = [];
  let base = null;
  try {
    const u = new URL(String(url ?? ''));
    if (u.protocol !== 'https:' && u.protocol !== 'http:') errors.push('E3D_MCP_AUTH_URL must be an https: URL');
    else if (u.protocol === 'http:' && !isLoopback(u.hostname)) errors.push('E3D_MCP_AUTH_URL must use https: (http: is allowed only for loopback hosts)');
    if (u.username || u.password) errors.push('E3D_MCP_AUTH_URL must not contain credentials');
    if (u.search || String(url).includes('?')) errors.push('E3D_MCP_AUTH_URL must not contain a query');
    if (u.hash || String(url).includes('#')) errors.push('E3D_MCP_AUTH_URL must not contain a fragment');
    base = `${u.origin}${u.pathname}`.replace(/\/+$/, '');
  } catch { errors.push('E3D_MCP_AUTH_URL is not a valid URL'); }
  let token = serviceToken;
  if (token == null) { const r = readServiceToken(env); if (r.error) errors.push(r.error); token = r.token ?? ''; }
  if (!token) errors.push('a service token is required (E3D_MCP_AUTH_SERVICE_TOKEN or E3D_MCP_AUTH_SERVICE_TOKEN_FILE)');
  else if (token.length < 24) errors.push('the service token is shorter than 24 characters');
  else if (token.length > LIMITS.maxTokenLength || !TOKEN_RE.test(token)) errors.push('the service token must be printable ASCII without spaces, at most 512 characters');
  const cache = intIn(env.E3D_MCP_AUTH_CACHE_SEC, 30, 1, 300);
  if (cache.error) errors.push('E3D_MCP_AUTH_CACHE_SEC must be an integer from 1 to 300');
  const inflight = intIn(env.E3D_MCP_AUTH_MAX_INFLIGHT, 32, 1, 1024);
  if (inflight.error) errors.push('E3D_MCP_AUTH_MAX_INFLIGHT must be an integer from 1 to 1024');
  if (typeof fetchImpl !== 'function') errors.push('this Node.js has no global fetch (Node 18 or later is required)');
  const config = { base, serviceToken: token, cacheSec: cache.value ?? 30, maxInflight: inflight.value ?? 32 };
  Object.defineProperty(config, 'serviceToken', { enumerable: false }); // never serialized by accident
  return { ok: errors.length === 0, errors, config };
}

// ---- client ----
export function createExternalAuth({ url, serviceToken, fetchImpl = globalThis.fetch, now = Date.now, env = process.env, log = () => {}, timeouts = {}, outbox: initialOutbox = null } = {}) {
  const checked = validateConfig(env, { url: url ?? env.E3D_MCP_AUTH_URL, serviceToken, fetchImpl });
  if (!checked.ok) throw new AuthServiceError('config', `external auth configuration: ${checked.errors.join('; ')}`);
  const { base, cacheSec, maxInflight } = checked.config;
  const secret = checked.config.serviceToken;
  const limitsMs = { ...DEFAULT_TIMEOUTS, ...timeouts };

  const cache = new Map();    // sha256(token) -> { value, until }  (insertion order = age, for eviction)
  const inflight = new Map(); // sha256(token) -> Promise
  const counters = { cache_hits: 0, cache_misses: 0, shared: 0, cap_rejections: 0, rejected_before_call: 0, calls: {}, errors: { unavailable: 0, 'bad-response': 0, config: 0 } };

  const fail = (call, kind, why) => {
    counters.errors[kind] = (counters.errors[kind] ?? 0) + 1;
    log(kind === 'config'
      ? `external-auth: CONFIGURATION failure on ${call}: ${why} (check the service token and E3D_MCP_AUTH_URL)`
      : `external-auth: service failure on ${call}: ${kind}: ${why}`);
    return new AuthServiceError(kind, `auth service ${call}: ${why}`);
  };

  async function readCapped(res, ac) {
    const declared = Number(res.headers.get('content-length'));
    if (Number.isFinite(declared) && declared > LIMITS.responseBytes) { ac.abort(); return null; }
    if (!res.body) return '';
    const reader = res.body.getReader();
    const chunks = []; let size = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > LIMITS.responseBytes) { ac.abort(); reader.cancel().catch(() => {}); return null; }
      chunks.push(value);
    }
    return Buffer.concat(chunks.map((c) => Buffer.from(c))).toString('utf8');
  }

  // One HTTP exchange. Returns the validated response object (unknown fields included) or throws AuthServiceError.
  async function call(name, body) {
    counters.calls[name] = (counters.calls[name] ?? 0) + 1;
    const method = name === 'health' ? 'GET' : 'POST';
    const payload = method === 'POST' ? JSON.stringify(body) : undefined;
    if (payload && Buffer.byteLength(payload) > LIMITS.requestBytes) throw new TypeError(`${name} request exceeds ${LIMITS.requestBytes} bytes`);
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), limitsMs[name]);
    timer.unref?.();
    try {
      let res;
      try {
        res = await fetchImpl(`${base}/${name}`, {
          method, body: payload, redirect: 'manual', signal: ac.signal,
          headers: { authorization: `Bearer ${secret}`, 'x-e3d-auth-version': PROTOCOL_VERSION, accept: 'application/json', ...(payload ? { 'content-type': 'application/json' } : {}) },
        });
      } catch (e) { throw fail(name, 'unavailable', ac.signal.aborted ? `timed out after ${limitsMs[name]} ms` : 'connection failed'); }
      if (res.type === 'opaqueredirect' || (res.status >= 300 && res.status < 400)) { res.body?.cancel().catch(() => {}); throw fail(name, 'unavailable', `redirect refused (HTTP ${res.status})`); }
      if (res.status === 401 || res.status === 403) { res.body?.cancel().catch(() => {}); throw fail(name, 'config', `the service rejected the service token (HTTP ${res.status})`); }
      if (res.status < 200 || res.status > 299) { res.body?.cancel().catch(() => {}); throw fail(name, 'unavailable', `HTTP ${res.status}`); }
      let text;
      try { text = await readCapped(res, ac); } catch { throw fail(name, 'unavailable', ac.signal.aborted ? `timed out after ${limitsMs[name]} ms` : 'connection lost while reading'); }
      if (text === null) throw fail(name, 'bad-response', `response larger than ${LIMITS.responseBytes} bytes`);
      let json;
      try { json = JSON.parse(text); } catch { throw fail(name, 'bad-response', 'response is not JSON'); }
      const errs = validateSchema(SCHEMAS[`${name}.response`], json);
      if (errs.length) throw fail(name, 'bad-response', `response does not match the schema (${errs.slice(0, 3).join('; ')})`);
      return json;
    } finally { clearTimeout(timer); }
  }

  const checkRequest = (name, args) => {
    const errs = validateSchema(SCHEMAS[`${name}.request`], args);
    if (errs.length) throw new TypeError(`invalid ${name} request: ${errs.slice(0, 3).join('; ')}`);
  };

  const remember = (key, value, ttl) => {
    cache.delete(key);
    if (ttl <= 0) return;
    cache.set(key, { value, until: now() + ttl });
    while (cache.size > LIMITS.cacheEntries) cache.delete(cache.keys().next().value);
  };

  // Normalize to known fields only; an active answer whose expires_at is past (beyond the skew allowance) is inactive.
  const normalize = (r) => {
    if (!r.active) return { value: Object.freeze({ active: false }), ttl: LIMITS.negativeTtlMs };
    let ttl = cacheSec * 1000;
    if (r.expires_at) {
      const left = Date.parse(r.expires_at) - now();
      if (left < -LIMITS.clockSkewMs) return { value: Object.freeze({ active: false }), ttl: LIMITS.negativeTtlMs };
      ttl = Math.min(ttl, left);
    }
    const value = { active: true, principal: r.principal, tools: r.tools ? Object.freeze([...r.tools]) : null, limits: Object.freeze({ rate_per_min: r.limits?.rate_per_min ?? null, max_inflight: r.limits?.max_inflight ?? null }), expires_at: r.expires_at ?? null };
    return { value: Object.freeze(value), ttl };
  };

  async function introspect(token) {
    if (typeof token !== 'string' || token.length === 0 || token.length > LIMITS.maxTokenLength || !TOKEN_RE.test(token)) {
      counters.rejected_before_call++;
      return Object.freeze({ active: false });
    }
    const key = sha256(token);
    const hit = cache.get(key);
    if (hit && hit.until > now()) { counters.cache_hits++; return hit.value; }
    if (hit) cache.delete(key);
    const pending = inflight.get(key);
    if (pending) { counters.shared++; return pending; }
    if (inflight.size >= maxInflight) {
      counters.cap_rejections++;
      throw fail('introspect', 'unavailable', `too many introspect requests in flight (cap ${maxInflight})`);
    }
    counters.cache_misses++;
    const p = (async () => {
      try {
        const { value, ttl } = normalize(await call('introspect', { token }));
        remember(key, value, ttl); // an inactive answer replaces (evicts) any positive entry
        return value;
      } finally { inflight.delete(key); }
    })();
    inflight.set(key, p);
    return p;
  }

  async function reserve(args) {
    checkRequest('reserve', args);
    const r = await call('reserve', args);
    return r.ok ? { ok: true, reservation_id: r.reservation_id, expires_at: r.expires_at } : { ok: false, code: r.code, message: r.message ?? '' };
  }
  async function settle(args) {
    checkRequest('settle', args);
    const r = await call('settle', args);
    return r.ok ? { ok: true } : { ok: false, code: r.code, message: r.message ?? '' };
  }
  async function release(args) {
    checkRequest('release', args);
    await call('release', args);
    return { ok: true };
  }
  async function health() {
    await call('health');
    return { status: 'ok' };
  }

  // Durable settlement: try once now; on any failure hand the call to the outbox. A conflict, a configuration
  // failure or an invalid payload can never succeed by retrying, so it goes straight to dead-letter (kept, logged,
  // and visible to readiness). Returns { ok, delivered, queued, dead, held, record_id }: ok means the usage was
  // delivered or is durably recorded on disk. Never throws.
  let outbox = initialOutbox;
  const attachOutbox = (o) => { outbox = o; };
  async function durable(name, args) {
    let answer = null; let err = null;
    try {
      answer = name === 'settle' ? await settle(args) : await release(args);
      if (answer.ok) return { ok: true, delivered: true, queued: false, dead: false, held: false, record_id: null };
    } catch (e) { err = e; }
    const permanent = answer ? `service answered ${answer.code}`
      : err instanceof TypeError ? `invalid ${name} request`
        : err?.kind === 'config' ? 'configuration failure (service token rejected)' : null;
    if (!outbox) {
      log(`external-auth: ERROR ${name} was not delivered (${permanent ?? err?.kind ?? 'failure'}) and no outbox is configured`);
      return { ok: false, delivered: false, queued: false, dead: false, held: false, record_id: null };
    }
    try {
      const q = await outbox.enqueueOrHold(name, args, permanent
        ? { dead: permanent }
        : { attempts: 1, last_error: `${err?.kind ?? 'error'}: ${String(err?.message ?? err).slice(0, 160)}` });
      return { ok: !!(q.queued || q.duplicate || q.conflict), delivered: false, queued: !!(q.queued || q.duplicate), dead: !!q.dead, held: !!q.held, record_id: q.record_id };
    } catch (e) {
      log(`external-auth: ERROR ${name} could not be recorded in the outbox (${e?.code ?? e?.message})`);
      return { ok: false, delivered: false, queued: false, dead: false, held: false, record_id: null };
    }
  }
  const settleDurable = (args) => durable('settle', args);
  const releaseDurable = (args) => durable('release', args);

  const stats = () => ({ ...counters, calls: { ...counters.calls }, errors: { ...counters.errors }, cache_size: cache.size, inflight: inflight.size, inflight_cap: maxInflight, cache_sec: cacheSec });

  return { introspect, reserve, settle, release, settleDurable, releaseDurable, attachOutbox, health, stats, validateConfig: (e = env) => validateConfig(e, { fetchImpl }) };
}
