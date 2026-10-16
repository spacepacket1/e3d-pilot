// Remote MCP over streamable HTTP (spec 2025-06-18), JSON responses only. Zero dependencies.
//
//   POST /mcp      one JSON-RPC message; requests get application/json, notifications and responses get 202
//   GET  /mcp      405 (no server-initiated stream: sampling, elicitation and progress are unavailable over HTTP)
//   DELETE /mcp    ends a session
//   GET  /healthz  liveness (no auth, no internals)
//
// TLS is NOT handled here: terminate it at a reverse proxy or load balancer. Binding anywhere other than
// loopback refuses to start without auth tokens. Tokens are never logged.
import http from 'node:http';
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { redact } from './redact.js';

const envInt = (env, name, dflt) => { const n = Number.parseInt(env[name] ?? '', 10); return Number.isFinite(n) && n > 0 ? n : dflt; };
const LOOPBACK = new Set(['127.0.0.1', '::1', 'localhost']);
export const isLoopback = (host) => LOOPBACK.has(host) || host.startsWith('127.');
const sha = (s) => createHash('sha256').update(s).digest();
const DEFAULT_TOOLS = ['e3d_debate', 'e3d_list_providers', 'e3d_usage'];

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

export async function startHttpServer({ host, port, env = process.env, log, handle, newConn, version }) {
  const tokens = parseTokens(env.E3D_MCP_AUTH_TOKENS);
  const loopback = isLoopback(host);
  if (!loopback && tokens.length === 0) {
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

  const sessions = new Map(); // id -> { conn, principal, lastSeen }
  const windows = new Map(); // principal -> [timestamps within the last minute]
  let inflight = 0;

  const rateLimited = (principal) => {
    const now = Date.now();
    const recent = (windows.get(principal) ?? []).filter((t) => now - t < 60000);
    if (recent.length >= ratePerMin) { windows.set(principal, recent); return Math.ceil((60000 - (now - recent[0])) / 1000); }
    recent.push(now);
    windows.set(principal, recent);
    return 0;
  };
  const sweep = () => { const now = Date.now(); for (const [id, s] of sessions) if (now - s.lastSeen > sessionTtlMs) sessions.delete(id); };
  const sweeper = setInterval(sweep, 60000); sweeper.unref();

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
      if (path !== '/mcp') return send(res, 404, { error: 'not found' });

      if (!hostOk(req.headers.host)) return send(res, 403, { error: 'forbidden host' });
      if (!originOk(req.headers.origin)) return send(res, 403, { error: 'forbidden origin' });

      if (tokens.length) {
        const who = authenticate(tokens, req.headers.authorization);
        if (!who) return send(res, 401, { error: 'unauthorized' }, { 'www-authenticate': 'Bearer realm="e3d-mcp"' });
        principal = who;
      } else {
        principal = 'local';
      }

      if (req.method === 'GET') return send(res, 405, { error: 'this server has no event stream; use POST' }, { allow: 'POST, DELETE' });
      const sid = req.headers['mcp-session-id'];
      if (req.method === 'DELETE') {
        const s = sid && sessions.get(sid);
        if (!s || s.principal !== principal) return send(res, 404, { error: 'unknown session' });
        sessions.delete(sid);
        return send(res, 204);
      }
      if (req.method !== 'POST') return send(res, 405, { error: 'method not allowed' }, { allow: 'POST, DELETE' });

      const wait = rateLimited(principal);
      if (wait) return send(res, 429, { error: 'rate limit exceeded' }, { 'retry-after': String(wait) });
      if (inflight >= maxInflight) return send(res, 503, { error: 'server busy' }, { 'retry-after': '5' });

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
        session = { conn: newConn(principal, allowedTools), principal, lastSeen: Date.now() };
        sessions.set(id, session);
        headers['mcp-session-id'] = id;
      } else {
        session = sid && sessions.get(sid);
        if (!sid) return rpcError(res, 400, -32600, 'Mcp-Session-Id header required (send initialize first)', msg.id ?? null);
        if (!session || session.principal !== principal) return rpcError(res, 404, -32600, 'unknown or expired session; initialize again', msg.id ?? null);
        session.lastSeen = Date.now();
      }

      if (!isRequest) { await handle(msg, { ...session.conn, send: () => {} }); return send(res, 202); }

      inflight++;
      let reply = null;
      const timer = new Promise((resolve) => { const t = setTimeout(resolve, requestTimeoutMs, 'timeout'); t.unref(); });
      try {
        const done = handle(msg, { ...session.conn, send: (m) => { if (m.id === msg.id) reply = m; } });
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
  log(`http listening on ${host}:${actual} (auth: ${tokens.length ? `${tokens.length} token(s)` : 'none, loopback only'}; tools: ${allowedTools ? [...allowedTools].join(',') : 'ALL'})`);
  return {
    port: actual, allowedTools, tokens,
    async close() { clearInterval(sweeper); await new Promise((r) => server.close(r)); },
  };
}
