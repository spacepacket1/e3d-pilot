// The internal run listener: the billing service's web "Ask" page runs a debate it has already reserved. Zero dependencies.
//
//   POST   /internal/runs              {reservation_id, debate_id, question, providers?, rounds?, max_words?, web_search?}
//   GET    /internal/runs/{debate_id}  status, progress, and the result once done
//   DELETE /internal/runs/{debate_id}  cancel: finalized as outcome "error" without a result
//
// Enabled with E3D_MCP_RUN_PORT and E3D_MCP_RUN_TOKEN (32+ characters), hook mode only. It binds to 127.0.0.1 only and is a
// separate listener: the public /mcp listener never serves these paths. Every request carries the service token
// (Authorization: Bearer); GET and DELETE also need the run's own token (X-E3D-Run-Token), returned by POST. Both are compared
// in constant time; failed authentication is rate-limited (E3D_MCP_RUN_AUTH_FAILS_PER_MIN, after which every request is
// refused for up to a minute without being checked). A new run needs finalize, fetch and authorize-run advertised.
//
// The owner is whatever authorize-run says, never the request body; nothing runs unless it authorizes. The run is metered
// from that reservation (no new reserve), executed by the async runner (lib/mcp/runs.js, same slots, limits and recovery)
// and finalized once with source "web". A repeated POST with the same fields returns the same run and run token (answered from
// the request's key before any planning, so a provider that became unavailable never turns a retry into a refusal); changed
// fields, or either id reused with another counterpart, are a conflict. Answers say whether the run was accepted:
//   202 accepted | 200 existing | 400 invalid | 403 not_authorized | 409 conflict | 429 busy        (definitive)
//   503 unavailable / not_ready (nothing was accepted; retry later) | 401 bad service or run token | 429 rate_limited
// Logs carry the method, the route, the status and ids; never a body, a question or a token.
import http from 'node:http';
import { createHash } from 'node:crypto';
import { canonicalJson } from './external-auth.js';
import { questionFitsContract } from './metering.js';
import { DEBATE_ID_RE, safeEqual } from './runs.js';
import { NAME_RE } from './util.js';

export const RUN_TOKEN_MIN = 32;
export const RUN_FEATURES = Object.freeze(['finalize', 'fetch', 'authorize-run']);
const HOST = '127.0.0.1';
const MAX_BODY = 64 * 1024;
const RID_RE = /^[A-Za-z0-9_.:-]{1,128}$/;
const FIELDS = new Set(['reservation_id', 'debate_id', 'question', 'providers', 'rounds', 'max_words', 'web_search']);
const TOKEN_RE = /^[!-~]+$/;

// Startup checks. Returns { enabled, ok, errors, config: { port, token, failsPerMin } } (the token only in config).
export function validateRunServerConfig(env = process.env) {
  const enabled = Boolean(env.E3D_MCP_RUN_PORT || env.E3D_MCP_RUN_TOKEN);
  const errors = [];
  const config = { port: null, token: null, failsPerMin: 20 };
  if (!enabled) return { enabled, ok: true, errors, config };
  if (!env.E3D_MCP_AUTH_URL) errors.push('the internal run listener (E3D_MCP_RUN_PORT) needs the external auth hook (E3D_MCP_AUTH_URL)');
  const port = String(env.E3D_MCP_RUN_PORT ?? '');
  if (!/^\d{1,5}$/.test(port) || Number(port) > 65535) errors.push('E3D_MCP_RUN_PORT must be a port number (0 to 65535)');
  else config.port = Number(port);
  const token = env.E3D_MCP_RUN_TOKEN ?? '';
  if (token.length < RUN_TOKEN_MIN || token.length > 512 || !TOKEN_RE.test(token)) errors.push(`E3D_MCP_RUN_TOKEN must be ${RUN_TOKEN_MIN} to 512 printable characters without spaces`);
  else config.token = token;
  const fails = env.E3D_MCP_RUN_AUTH_FAILS_PER_MIN;
  if (fails != null && fails !== '') {
    if (!/^\d{1,6}$/.test(fails) || Number(fails) < 1) errors.push('E3D_MCP_RUN_AUTH_FAILS_PER_MIN must be a whole number from 1 to 999999');
    else config.failsPerMin = Number(fails);
  }
  return { enabled, ok: errors.length === 0, errors, config };
}

// The strict shape of a run request. Returns { fields, key } (key: sha256 of the canonical fields) or { error }.
export function validateRunRequest(b) {
  if (!b || typeof b !== 'object' || Array.isArray(b)) return { error: 'the body must be a JSON object' };
  for (const k of Object.keys(b)) if (!FIELDS.has(k)) return { error: `unknown field ${JSON.stringify(k.slice(0, 40))}` };
  if (typeof b.reservation_id !== 'string' || !RID_RE.test(b.reservation_id)) return { error: 'reservation_id is missing or malformed' };
  if (typeof b.debate_id !== 'string' || !DEBATE_ID_RE.test(b.debate_id)) return { error: 'debate_id must be dbt_ followed by 24 lowercase hex characters' };
  if (!questionFitsContract(b.question) || !b.question.trim()) return { error: 'the question must be 1 to 8000 characters without control characters' };
  if (b.providers !== undefined && (!Array.isArray(b.providers) || b.providers.length < 1 || b.providers.length > 16 || b.providers.some((p) => typeof p !== 'string' || p.length > 64 || !NAME_RE.test(p)))) return { error: 'providers must be an array of provider names' };
  if (b.rounds !== undefined && (!Number.isSafeInteger(b.rounds) || b.rounds < 1 || b.rounds > 100)) return { error: 'rounds must be a whole number' };
  if (b.max_words !== undefined && (!Number.isSafeInteger(b.max_words) || b.max_words < 1 || b.max_words > 100000)) return { error: 'max_words must be a whole number' };
  if (b.web_search !== undefined && typeof b.web_search !== 'boolean') return { error: 'web_search must be a boolean' };
  const fields = {};
  for (const k of FIELDS) if (b[k] !== undefined) fields[k] = b[k];
  return { fields, key: createHash('sha256').update(canonicalJson(fields)).digest('hex') };
}

// runs: the run store (accept/get/cancel); external: the auth client (features, authorizeRun); plan(fields) -> { plan, worst }
// or { error } (the debate plan with the customer maxima applied).
export async function startRunServer({ port, token, runs, external, plan, log = () => {}, failsPerMin = 20, now = Date.now }) {
  if (typeof token !== 'string' || token.length < RUN_TOKEN_MIN) throw new Error(`refusing to start the internal run listener: E3D_MCP_RUN_TOKEN must be at least ${RUN_TOKEN_MIN} characters`);
  const fails = [];
  const recentFails = () => { const t = now(); while (fails.length && t - fails[0] >= 60000) fails.shift(); return fails.length; };
  const counters = { requests: 0, auth_failures: 0, rate_limited: 0 };

  const send = (res, status, body, headers = {}) => {
    res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', ...headers });
    res.end(JSON.stringify(body));
  };
  const reject = (res, status, code, message, extra = {}) => send(res, status, { ok: false, accepted: false, code, ...(message ? { message } : {}), ...extra });
  const unauthorized = (res) => {
    counters.auth_failures++; fails.push(now()); if (fails.length > 4096) fails.splice(0, fails.length - 4096);
    return reject(res, 401, 'unauthorized', null);
  };
  async function readJson(req) {
    if (!/^application\/json\b/i.test(req.headers['content-type'] ?? '')) return { error: 'content-type must be application/json' };
    const declared = Number(req.headers['content-length']);
    if (Number.isFinite(declared) && declared > MAX_BODY) return { tooLarge: true };
    const chunks = []; let size = 0;
    for await (const c of req) { size += c.length; if (size > MAX_BODY) return { tooLarge: true }; chunks.push(c); }
    try { return { body: JSON.parse(Buffer.concat(chunks).toString('utf8')) }; } catch { return { error: 'the body is not valid JSON' }; }
  }
  const enabled = () => RUN_FEATURES.every((f) => external?.hasFeature?.(f));

  async function create(req, res) {
    // after a restart the features are unknown until the service has answered; ask it now (throttled) rather than wait for a client call
    if (!enabled()) await external?.warmFeatures?.();
    if (!enabled()) return reject(res, 503, 'not_ready', 'the billing service does not advertise finalize, fetch and authorize-run', { retry: true });
    const got = await readJson(req);
    if (got.tooLarge) return reject(res, 413, 'invalid', 'the body is too large');
    if (got.error) return reject(res, 400, 'invalid', got.error);
    const v = validateRunRequest(got.body);
    if (v.error) return reject(res, 400, 'invalid', v.error);
    // A run this listener already holds is answered from its key BEFORE any planning: an identical retry after a provider
    // became unavailable is `200 existing`, never a `400` that would make the service zero-charge a run that exists.
    const ids = { reservation_id: v.fields.reservation_id, debate_id: v.fields.debate_id, key: v.key };
    const prior = runs.known ? await runs.known(ids) : null;
    let r = prior;
    if (!r) {
      const p = await plan(v.fields);
      if (p.error) return reject(res, 400, 'invalid', String(p.error).replace(/^error:\s*/, '').slice(0, 300));
      r = await runs.accept({ ...ids, plan: p.plan, worst: p.worst, authorize: (args) => external.authorizeRun(args) });
    }
    if (r.ok) return send(res, r.existing ? 200 : 202, { ok: true, accepted: true, existing: r.existing, debate_id: r.debate_id, status: r.status, run_token: r.run_token });
    switch (r.kind) {
      case 'conflict': return reject(res, 409, 'conflict', 'a run with this debate_id or reservation_id already exists with other fields');
      case 'invalid': return reject(res, 400, 'invalid', 'the run request is invalid');
      case 'busy': return reject(res, 429, 'busy', 'too many debates are queued or running; retry later');
      case 'caps': return reject(res, 429, 'busy', 'the server cannot store more debates right now; retry later');
      case 'refused': return r.code === 'conflict' ? reject(res, 409, 'conflict', 'the reservation is bound to another debate')
        : r.code === 'invalid' ? reject(res, 400, 'invalid', 'the billing service refused the run request')
          : reject(res, 403, 'not_authorized', 'the billing service did not authorize this run', { reason: r.code });
      case 'begin': return r.rsv?.kind === 'local' ? reject(res, 429, 'busy', 'the daily budget for this account is used up')
        : r.rsv?.kind === 'invalid' ? reject(res, 400, 'invalid', 'the run request is invalid')
          : reject(res, 503, 'unavailable', 'temporarily unavailable; retry later', { retry: true });
      default: return reject(res, 503, 'unavailable', 'temporarily unavailable; retry later', { retry: true });
    }
  }

  const server = http.createServer(async (req, res) => {
    counters.requests++;
    const started = now();
    const path = (req.url ?? '').split('?')[0];
    const route = path === '/internal/runs' ? path : /^\/internal\/runs\/dbt_[0-9a-f]{24}$/.test(path) ? path : '-';
    res.on('finish', () => log(`run-server: ${req.method} ${route} ${res.statusCode} ${now() - started}ms`));
    try {
      if (recentFails() >= failsPerMin) { counters.rate_limited++; return reject(res, 429, 'rate_limited', 'too many failed authentications; retry later', { retry: true }); }
      // a browser can reach loopback; it can never pass these checks or read an answer
      if (req.headers.origin || !/^(127\.0\.0\.1|localhost)(:\d+)?$/.test(req.headers.host ?? '')) return reject(res, 403, 'forbidden', null);
      const bearer = /^Bearer\s+(\S+)$/i.exec(req.headers.authorization ?? '')?.[1] ?? '';
      if (!safeEqual(bearer, token)) return unauthorized(res);
      if (path === '/internal/runs') return req.method === 'POST' ? await create(req, res) : reject(res, 405, 'method_not_allowed', null);
      const m = /^\/internal\/runs\/([^/]+)$/.exec(path);
      if (!m || !['GET', 'DELETE'].includes(req.method)) return reject(res, 404, 'not_found', null);
      const runToken = req.headers['x-e3d-run-token'];
      // an unknown id and a wrong run token look the same
      const r = req.method === 'GET' ? await runs.get(m[1], typeof runToken === 'string' ? runToken : '') : await runs.cancel(m[1], typeof runToken === 'string' ? runToken : '');
      if (!r) return unauthorized(res);
      return send(res, 200, { ok: true, run: r.run });
    } catch (e) {
      log(`run-server: ERROR ${req.method} ${route} (${e.code ?? e.message})`);
      if (!res.headersSent) reject(res, 503, 'unavailable', null, { retry: true });
    }
  });
  server.requestTimeout = 30000;
  server.headersTimeout = 10000;
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, HOST, () => { server.off('error', reject); resolve(); }); });
  const bound = server.address();
  log(`run-server: listening on ${bound.address}:${bound.port} (internal runs, loopback only)`);
  return {
    port: bound.port, host: bound.address, stats: () => ({ ...counters }),
    close: () => new Promise((r) => { server.close(() => r()); server.closeAllConnections?.(); }),
  };
}
