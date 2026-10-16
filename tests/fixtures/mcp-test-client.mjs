#!/usr/bin/env node
// Scriptable MCP client for tests. Usage: node mcp-test-client.mjs '<json plan>'
// plan: { server, env, cwd, capabilities, roots:[paths], clientName, elicit:{action,content}, sampling:{text,model},
//         calls:[{name, arguments, progress}] }
// Answers roots/list, elicitation/create and sampling/createMessage from the plan; prints one JSON object:
// { init, results:[...], events:[...] } where events records notifications and server-initiated requests.
import { spawn } from 'node:child_process';

const plan = JSON.parse(process.argv[2]);
const child = spawn(plan.server, [], { env: { ...process.env, ...plan.env }, cwd: plan.cwd, stdio: ['pipe', 'pipe', plan.showStderr ? 'inherit' : 'ignore'] });
const pending = new Map();
const events = [];
let nextId = 1;
let buf = '';
const send = (m) => child.stdin.write(`${JSON.stringify(m)}\n`);
const timer = setTimeout(() => { console.error('test client timed out'); child.kill('SIGKILL'); process.exit(2); }, plan.timeoutMs ?? 180000);

function onMessage(m) {
  if (m.method && m.id !== undefined) {
    events.push({ request: m.method, params: m.params });
    if (m.method === 'roots/list') return send({ jsonrpc: '2.0', id: m.id, result: { roots: (plan.roots ?? []).map((p) => ({ uri: `file://${p}` })) } });
    if (m.method === 'elicitation/create') return send({ jsonrpc: '2.0', id: m.id, result: plan.elicit ?? { action: 'decline' } });
    if (m.method === 'sampling/createMessage') {
      const s = plan.sampling ?? {};
      if (s.error) return send({ jsonrpc: '2.0', id: m.id, error: { code: -1, message: s.error } });
      const n = events.filter((e) => e.request === 'sampling/createMessage').length;
      const model = Array.isArray(s.models) ? s.models[(n - 1) % s.models.length] : (s.model ?? 'fake-model');
      return send({ jsonrpc: '2.0', id: m.id, result: { role: 'assistant', content: { type: 'text', text: s.text ?? 'sampled answer' }, model, stopReason: 'endTurn' } });
    }
    return send({ jsonrpc: '2.0', id: m.id, error: { code: -32601, message: 'unsupported in test client' } });
  }
  if (m.method) { events.push({ notification: m.method, params: m.params }); return; }
  pending.get(m.id)?.(m);
  pending.delete(m.id);
}

child.stdout.on('data', (d) => {
  buf += d;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) { const line = buf.slice(0, i); buf = buf.slice(i + 1); if (line.trim()) onMessage(JSON.parse(line)); }
});
const call = (method, params) => new Promise((res) => { const id = nextId++; pending.set(id, res); send({ jsonrpc: '2.0', id, method, params }); });

const init = await call('initialize', { protocolVersion: '2025-06-18', capabilities: plan.capabilities ?? {}, clientInfo: { name: plan.clientName ?? 'test-client', version: '0' } });
send({ jsonrpc: '2.0', method: 'notifications/initialized' });
const results = [];
for (const c of plan.calls ?? []) {
  const r = await call('tools/call', { name: c.name, arguments: c.arguments ?? {}, ...(c.progress ? { _meta: { progressToken: 'tok' } } : {}) });
  results.push(r.result ?? { rpcError: r.error });
  if (c.sleepMs) await new Promise((res) => setTimeout(res, c.sleepMs));
}
clearTimeout(timer);
console.log(JSON.stringify({ init: init.result, results, events }));
child.stdin.end();
