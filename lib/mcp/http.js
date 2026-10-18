// Remote MCP over streamable HTTP (spec 2025-06-18), JSON responses only. Zero dependencies.
//
//   POST /mcp      one JSON-RPC message; requests get application/json, notifications and responses get 202
//   GET  /mcp      405 (no server-initiated stream: sampling, elicitation and progress are unavailable over HTTP)
//   DELETE /mcp    ends a session
//   GET  /healthz  liveness (no auth, no internals)
//   GET  /readyz   readiness of the external auth hook (hook mode only; 404 otherwise)
//
// TLS is NOT handled here: terminate it at a reverse proxy or load balancer. Binding anywhere other than
// loopback refuses to start without auth tokens. Tokens are never logged.
//
// With the external auth hook (`auth`, see docs/external-auth.md), every /mcp request is authenticated through
// auth.introspect (cached by the client): the principal, the tool allowlist and the limits are recomputed from the
// latest answer on every request; sessions are bound to sha256(token) and the principal; a token whose introspection
// turns inactive loses its sessions (only its own). Unknown tokens pass a per-IP limiter before any service call.
import http from 'node:http';
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { redact } from './redact.js';

const envInt = (env, name, dflt) => { const n = Number.parseInt(env[name] ?? '', 10); return Number.isFinite(n) && n > 0 ? n : dflt; };
const LOOPBACK = new Set(['127.0.0.1', '::1', 'localhost']);
export const isLoopback = (host) => LOOPBACK.has(host) || host.startsWith('127.');
const sha = (s) => createHash('sha256').update(s).digest();
const DEFAULT_TOOLS = ['e3d_debate', 'e3d_list_providers', 'e3d_usage'];
const TOKEN_RE = /^[!-~]{1,512}$/; // printable ASCII, no spaces, at most 512 characters
const KNOWN_ACTIVE_MAX = 10000;

// "name:token,name2:token2" -> [{name, digest}]. Weak or malformed entries are rejected at startup.
export function parseTokens(spec) {
  const out = [];
  for (const entry of (spec || '').split(',').map((s) => s.trim()).filter(Boolean)) {
    const i = entry.indexOf(':');
    const name = entry.slice(0, i);
    const token = entry.slice(i + 1);
    if (i < 1 || !/^[A-Za-z0-9_.-]{1,40}$/.test(name)) throw new Error('E3D_MCP_AUTH_TOKENS entries must look like name:token (name: letters, digits, _ . -)');
    if (token.length < 16) throw new Error(`token for "${name}" is shorter than 16 characters`);
    out.push({ name, digest: sha(token) });
  }
  return out;
}

// Compare against every token (no early exit) in constant time. Returns the principal name or null.
export function authenticate(tokens, header) {
  const m = /^Bearer\s+(\S+)$/i.exec(header ?? '');
  if (!m) return null;
  const given = sha(m[1]);
  let who = null;
  for (const t of tokens) if (timingSafeEqual(given, t.digest)) who = t.name;
  return who;
}

export async function startHttpServer({ host, port, env = process.env, log, handle, newConn, version, auth = null, readiness = null }) {
  const tokens = auth ? [] : parseTokens(env.E3D_MCP_AUTH_TOKENS);
  const loopback = isLoopback(host);
  if (!loopback && tokens.length === 0 && !auth) {
    throw new Error(`refusing to listen on ${host}: binding beyond loopback requires auth. Set E3D_MCP_AUTH_TOKENS="name:token,..." (tokens of 16+ characters) and terminate TLS at a reverse proxy.`);
  }
  const maxBody = envInt(env, 'E3D_MCP_MAX_BODY_BYTES', 256 * 1024);
  const ratePerMin = envInt(env, 'E3D_MCP_RATE_PER_MIN', 60);
  const requestTimeoutMs = envInt(env, 'E3D_MCP_HTTP_REQUEST_TIMEOUT_SEC', 900) * 1000;
  const maxInflight = envInt(env, 'E3D_MCP_HTTP_MAX_INFLIGHT', 16);
  const maxSessions = envInt(env, 'E3D_MCP_MAX_SESSIONS', 1000);
  const sessionTtlMs = envInt(env, 'E3D_MCP_SESSION_TTL_SEC', 3600) * 1000;
  const allowedOrigins = (env.E3D_MCP_ALLOWED_ORIGINS || '').split(',').map((s) => s.trim()).filter(Boolean);
  const toolSpec = (env.E3D_MCP_HTTP_TOOLS || DEFAULT_TOOLS.join(',')).split(',').map((s) => s.trim()).filter(Boolean);
  const allowedTools = toolSpec.includes('*') ? null : new Set(toolSpec);

  const ipPerMin = envInt(env, 'E3D_MCP_AUTH_IP_PER_MIN', 30);
  // Behind N trusted reverse proxies every connection comes from the proxy, so the limiter would treat all customers as one
  // address. With E3D_MCP_TRUST_PROXY_HOPS=N the client is the Nth entry from the right of X-Forwarded-For (what the
  // outermost trusted proxy appended). Default 0: the header is ignored, so a client can never pick its own address.
  const proxyHops = envInt(env, 'E3D_MCP_TRUST_PROXY_HOPS', 0);
  const clientIp = (req) => {
    const peer = req.socket.remoteAddress ?? '-';
    if (!proxyHops) return peer;
    const parts = String(req.headers['x-forwarded-for'] ?? '').split(',').map((x) => x.trim()).filter(Boolean);
    const ip = parts[parts.length - proxyHops];
    return ip && ip.length <= 64 && /^[0-9a-fA-F:.]+$/.test(ip) ? ip : peer;
  };

  const sessions = new Map(); // id -> { conn, principal, digest (hook mode), lastSeen }
  const windows = new Map(); // principal -> [timestamps within the last minute]
  const ipPending = new Map(); // remote address -> unknown-token introspections currently in flight
  const ipWindows = new Map(); // remote address -> [timestamps of unauthenticated attempts within the last minute]
  const knownActive = new Set(); // sha256(token) hex whose latest introspection was active (they skip the IP limiter)
  const principalInflight = new Map(); // principal -> requests in flight (hook mode: the service's max_inflight)
  let inflight = 0;

  const slide = (map, key, limit, record = true) => {
    const now = Date.now();
    const recent = (map.get(key) ?? []).filter((t) => now - t < 60000);
    if (recent.length >= limit) { map.set(key, recent); return Math.ceil((60000 - (now - recent[0])) / 1000); }
    if (record) recent.push(now);
    map.set(key, recent);
    return 0;
  };
  const rateLimited = (principal, limit = ratePerMin) => slide(windows, principal, limit);
  const sweep = () => { const now = Date.now(); for (const [id, s] of sessions) if (now - s.lastSeen > sessionTtlMs) sessions.delete(id); };
  const sweepWindows = () => { const now = Date.now(); for (const m of [windows, ipWindows]) for (const [k, v] of m) if (!v.length || now - v[v.length - 1] >= 60000) m.delete(k); };
  const sweeper = setInterval(() => { sweep(); sweepWindows(); }, 60000); sweeper.unref();

  // Hook mode: only the sessions of this exact token go; other keys of the same account keep theirs.
  const dropSessionsOf = (digest) => {
    let n = 0; let who = '-';
    for (const [id, s] of sessions) if (s.digest === digest) { sessions.delete(id); n++; who = s.principal; }
    if (n) log(`dropped ${n} session(s) of a token that is no longer active principal=${who}`);
  };
  // The operator's allowlist (null = every tool) narrowed by the service's (null = no narrowing); never widened.
  const effectiveTools = (serviceTools) => {
    if (!serviceTools) return allowedTools;
    return new Set(serviceTools.filter((t) => !allowedTools || allowedTools.has(t)));
  };
  const lower = (mine, theirs) => (Number.isSafeInteger(theirs) && theirs > 0 ? Math.min(mine, theirs) : mine);

  const originOk = (origin) => {
    if (!origin) return true; // non-browser clients send none
    if (allowedOrigins.includes(origin)) return true;
    return loopback && allowedOrigins.length === 0 && /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/.test(origin);
  };
  const hostOk = (hostHeader) => !loopback || /^(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/.test(hostHeader ?? '');

  const send = (res, status, body, headers = {}) => {
    const payload = body === undefined ? '' : JSON.stringify(body);
    res.writeHead(status, { ...(body === undefined ? {} : { 'content-type': 'application/json' }), 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', ...headers });
    res.end(payload);
  };
  const rpcError = (res, status, code, message, id = null, headers) => send(res, status, { jsonrpc: '2.0', id, error: { code, message } }, headers);

  async function readBody(req) {
    const declared = Number(req.headers['content-length']);
    if (Number.isFinite(declared) && declared > maxBody) throw Object.assign(new Error('body too large'), { status: 413 });
    const chunks = [];
    let size = 0;
    for await (const c of req) {
      size += c.length;
      if (size > maxBody) throw Object.assign(new Error('body too large'), { status: 413 });
      chunks.push(c);
    }
    return Buffer.concat(chunks).toString('utf8');
  }

  const server = http.createServer(async (req, res) => {
    const started = Date.now();
    let principal = '-';
    res.on('finish', () => log(`${req.method} ${(req.url ?? '').split('?')[0]} ${res.statusCode} principal=${principal} ${Date.now() - started}ms`));
    try {
      const path = (req.url ?? '').split('?')[0];
      if (path === '/healthz' && req.method === 'GET') return send(res, 200, { status: 'ok', version });
      if (path === '/readyz' && req.method === 'GET') {
        if (!readiness) return send(res, 404, { error: 'not found' });
        const r = await readiness();
        return send(res, r.ready ? 200 : 503, r.body, r.ready ? {} : { 'retry-after': '5' });
      }
      if (path !== '/mcp') return send(res, 404, { error: 'not found' });

      if (!hostOk(req.headers.host)) return send(res, 403, { error: 'forbidden host' });
      if (!originOk(req.headers.origin)) return send(res, 403, { error: 'forbidden origin' });

      const unauthorized = () => send(res, 401, { error: 'unauthorized' }, { 'www-authenticate': 'Bearer realm="e3d-mcp"' });
      let grant = null; // hook mode: what the service allows this token, recomputed on every request
      if (auth) {
        const bearer = /^Bearer\s+(\S+)$/i.exec(req.headers.authorization ?? '')?.[1];
        const digest = bearer ? sha(bearer).toString('hex') : null;
        // Unknown tokens are checked against a per-IP limit of FAILED attempts before any service call, so unique-token
        // storms never reach the service. Only a rejected token counts: a proxy peer shared by many legitimate new callers
        // is not exhausted by their successful introspections.
        const ip = clientIp(req);
        const failed = () => { slide(ipWindows, ip, Infinity); return unauthorized(); };
        // Attempts still waiting on the service count too (ipPending), so a burst of concurrent unknown tokens cannot all pass
        // the check before any of them has failed.
        let pendingHeld = false;
        if (!digest || !knownActive.has(digest)) {
          const pend = ipPending.get(ip) ?? 0;
          const wait = pend >= ipPerMin ? 1 : slide(ipWindows, ip, ipPerMin - pend, false);
          if (wait) return send(res, 429, { error: 'too many unauthenticated attempts' }, { 'retry-after': String(wait) });
          if (bearer && TOKEN_RE.test(bearer)) { ipPending.set(ip, pend + 1); pendingHeld = true; }
        }
        const settlePending = () => { if (!pendingHeld) return; pendingHeld = false; const n = (ipPending.get(ip) ?? 1) - 1; if (n > 0) ipPending.set(ip, n); else ipPending.delete(ip); };
        if (!bearer || !TOKEN_RE.test(bearer)) return failed();
        let info;
        try { info = await auth.introspect(bearer); } catch {
          settlePending();
          return send(res, 503, { error: 'authentication service unavailable' }, { 'retry-after': '5' });
        }
        // a failure is recorded before the pending slot is given back, so the two never both miss the attempt
        if (!info?.active) { knownActive.delete(digest); dropSessionsOf(digest); const r = failed(); settlePending(); return r; }
        settlePending();
        if (!info?.active) { knownActive.delete(digest); dropSessionsOf(digest); return failed(); }
        knownActive.delete(digest); knownActive.add(digest);
        if (knownActive.size > KNOWN_ACTIVE_MAX) knownActive.delete(knownActive.values().next().value);
        principal = info.principal;
        grant = {
          digest, tools: effectiveTools(info.tools),
          rate: lower(ratePerMin, info.limits?.rate_per_min), inflight: lower(maxInflight, info.limits?.max_inflight),
        };
      } else if (tokens.length) {
        const who = authenticate(tokens, req.headers.authorization);
        if (!who) return send(res, 401, { error: 'unauthorized' }, { 'www-authenticate': 'Bearer realm="e3d-mcp"' });
        principal = who;
      } else {
        principal = 'local';
      }

      if (req.method === 'GET') return send(res, 405, { error: 'this server has no event stream; use POST' }, { allow: 'POST, DELETE' });
      const sid = req.headers['mcp-session-id'];
      const owns = (s) => s && s.principal === principal && (!grant || s.digest === grant.digest);
      if (req.method === 'DELETE') {
        const s = sid && sessions.get(sid);
        if (!owns(s)) return send(res, 404, { error: 'unknown session' });
        sessions.delete(sid);
        return send(res, 204);
      }
      if (req.method !== 'POST') return send(res, 405, { error: 'method not allowed' }, { allow: 'POST, DELETE' });

      const wait = rateLimited(principal, grant ? grant.rate : ratePerMin);
      if (wait) return send(res, 429, { error: 'rate limit exceeded' }, { 'retry-after': String(wait) });
      if (inflight >= maxInflight) return send(res, 503, { error: 'server busy' }, { 'retry-after': '5' });
      if (grant && (principalInflight.get(principal) ?? 0) >= grant.inflight) return send(res, 429, { error: 'too many requests in flight for this account' }, { 'retry-after': '5' });
      // counted from here, before the body is read, so parallel requests cannot all pass the per-account check;
      // given back when the connection closes, or (for work that starts) when that work really ends
      let counted = false; let handedOver = false;
      const giveBack = () => { if (!counted) return; counted = false; const n = (principalInflight.get(principal) ?? 1) - 1; if (n > 0) principalInflight.set(principal, n); else principalInflight.delete(principal); };
      if (grant) { principalInflight.set(principal, (principalInflight.get(principal) ?? 0) + 1); counted = true; res.on('close', () => { if (!handedOver) giveBack(); }); }

      if (!/^application\/json\b/i.test(req.headers['content-type'] ?? '')) return send(res, 415, { error: 'content-type must be application/json' });
      const accept = req.headers.accept;
      if (accept && !/application\/json|\*\/\*/i.test(accept)) return send(res, 406, { error: 'client must accept application/json' });
      const ver = req.headers['mcp-protocol-version'];
      if (ver && !['2025-06-18', '2025-03-26', '2024-11-05'].includes(ver)) return send(res, 400, { error: `unsupported MCP-Protocol-Version ${redact(String(ver)).slice(0, 40)}` });

      let msg;
      try { msg = JSON.parse(await readBody(req)); } catch (e) {
        if (e.status === 413) { res.setHeader('connection', 'close'); return send(res, 413, { error: 'request body too large' }); }
        return rpcError(res, 400, -32700, 'parse error');
      }
      if (Array.isArray(msg) || !msg || msg.jsonrpc !== '2.0') return rpcError(res, 400, -32600, 'send exactly one JSON-RPC 2.0 message per POST');

      const isRequest = msg.id !== undefined && msg.id !== null && typeof msg.method === 'string';
      if (!msg.method) return send(res, 202); // a response to something we never asked: accept and ignore

      let session;
      const headers = {};
      if (msg.method === 'initialize') {
        sweep();
        if (sessions.size >= maxSessions) return send(res, 503, { error: 'too many sessions' }, { 'retry-after': '30' });
        const id = randomBytes(16).toString('hex');
        session = { conn: newConn(principal, grant ? grant.tools : allowedTools), principal, ...(grant ? { digest: grant.digest } : {}), lastSeen: Date.now() };
        sessions.set(id, session);
        headers['mcp-session-id'] = id;
      } else {
        session = sid && sessions.get(sid);
        if (!sid) return rpcError(res, 400, -32600, 'Mcp-Session-Id header required (send initialize first)', msg.id ?? null);
        if (!owns(session)) return rpcError(res, 404, -32600, 'unknown or expired session; initialize again', msg.id ?? null);
        session.lastSeen = Date.now();
      }

      // hook mode: the tool allowlist comes from the latest introspection, not from when the session started
      const conn = grant ? { ...session.conn, principal, allowed: grant.tools } : session.conn;
      if (!isRequest) {
        // only real notifications run without an id: a request-only method (tools/call, ...) sent as a notification would
        // skip the in-flight accounting above
        if (!/^notifications\//.test(msg.method)) return rpcError(res, 400, -32600, `${msg.method} needs an id`, null, headers);
        await handle(msg, { ...conn, send: () => {} }); return send(res, 202);
      }

      inflight++;
      handedOver = true;
      let reply = null;
      const timer = new Promise((resolve) => { const t = setTimeout(resolve, requestTimeoutMs, 'timeout'); t.unref(); });
      const done = handle(msg, { ...conn, send: (m) => { if (m.id === msg.id) reply = m; } });
      // the per-account count drops when the work really ends, not when a timed-out reply is sent
      if (grant) done.catch(() => {}).finally(giveBack);
      try {
        if (await Promise.race([done.then(() => 'done'), timer]) === 'timeout') return rpcError(res, 504, -32000, 'request timed out', msg.id, headers);
      } finally { inflight--; }
      if (!reply) return rpcError(res, 500, -32603, 'no response produced', msg.id, headers);
      return send(res, 200, reply, headers);
    } catch (e) {
      log('http handler error:', redact(e.stack || String(e)));
      if (!res.headersSent) rpcError(res, 500, -32603, 'internal error');
    }
  });
  server.requestTimeout = requestTimeoutMs + 5000;
  server.headersTimeout = 15000;
  server.keepAliveTimeout = 30000;

  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, host, resolve); });
  const actual = server.address().port;
  log(`http listening on ${host}:${actual} (auth: ${auth ? 'external hook' : tokens.length ? `${tokens.length} token(s)` : 'none, loopback only'}; tools: ${allowedTools ? [...allowedTools].join(',') : 'ALL'})`);
  return {
    port: actual, allowedTools, tokens,
    async close() { clearInterval(sweeper); await new Promise((r) => server.close(r)); },
  };
}
