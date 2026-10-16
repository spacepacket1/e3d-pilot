// MCP sampling bridge: lets provider scripts (which run as child processes) use the *client's* own models,
// e.g. GitHub Copilot's in VS Code. The server listens on a private unix socket; the `mcp-sampling` provider
// adapter sends it a prompt, the server asks the client via sampling/createMessage, and relays the answer.
// Sampling needs a connected client, so this only works while the editor is attached to the server.
import net from 'node:net';
import { mkdtemp, chmod, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { redact } from './redact.js';

export function createSampling({ rpc, env = process.env, log = () => {} }) {
  // Model-name hints per voice; the client maps them onto models the user allows (VS Code: "Configure Model Access").
  const hints = (env.E3D_MCP_SAMPLING_HINTS || 'claude,gpt').split(',').map((s) => s.trim()).filter(Boolean);
  let server = null;
  let dir = null;
  let sockPath = null;
  const records = new Map(); // tag -> [{ voice, model }]

  async function handle(conn) {
    let buf = '';
    conn.setEncoding('utf8');
    conn.on('error', () => {});
    conn.on('data', async (chunk) => {
      buf += chunk;
      const i = buf.indexOf('\n');
      if (i < 0) return;
      const line = buf.slice(0, i);
      buf = '';
      let req;
      try { req = JSON.parse(line); } catch { conn.end(`${JSON.stringify({ ok: false, error: 'bad request' })}\n`); return; }
      if (req.ping) { conn.end(`${JSON.stringify({ ok: true, pong: true })}\n`); return; }
      try {
        const hint = hints[req.voice === 'b' ? 1 : 0] ?? hints[0];
        const result = await rpc.request('sampling/createMessage', {
          messages: [{ role: 'user', content: { type: 'text', text: String(req.prompt ?? '') } }],
          modelPreferences: { hints: hint ? [{ name: hint }] : [], intelligencePriority: 0.8, speedPriority: 0.3, costPriority: 0.3 },
          includeContext: 'none',
          maxTokens: Math.min(Math.max(Number(req.maxTokens) || 1500, 100), 8000),
        }, 5 * 60 * 1000);
        const answer = result?.content?.type === 'text' ? result.content.text : '';
        const model = result?.model ?? 'unknown';
        if (!records.has(req.tag)) records.set(req.tag, []);
        records.get(req.tag).push({ voice: req.voice === 'b' ? 'b' : 'a', model, hint: hint ?? null });
        conn.end(`${JSON.stringify({ ok: true, text: answer, model })}\n`);
      } catch (e) {
        log('sampling request failed:', redact(e.message));
        conn.end(`${JSON.stringify({ ok: false, error: redact(e.message) })}\n`);
      }
    });
  }

  async function ensure() {
    if (server) return sockPath;
    dir = await mkdtemp(join(tmpdir(), 'e3d-mcp-'));
    await chmod(dir, 0o700);
    sockPath = join(dir, 's.sock');
    server = net.createServer(handle);
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(sockPath, resolve); });
    await chmod(sockPath, 0o600);
    return sockPath;
  }

  return {
    hints,
    available: (session) => Boolean(session?.capabilities?.sampling),
    // Environment for a child process that may use the mcp-sampling providers.
    async env(session, { tag, maxTokens = 1500 }) {
      if (!session?.capabilities?.sampling) return {};
      await ensure();
      return { E3D_MCP_SAMPLING_SOCKET: sockPath, E3D_MCP_SAMPLING_TAG: tag, E3D_MCP_SAMPLING_MAX_TOKENS: String(maxTokens) };
    },
    // Which models actually answered for a tag (and forget them).
    drain(tag) { const r = records.get(tag) ?? []; records.delete(tag); return r; },
    async stop() {
      if (server) await new Promise((r) => server.close(r));
      if (dir) await rm(dir, { recursive: true, force: true });
      server = null; dir = null; sockPath = null;
    },
  };
}
