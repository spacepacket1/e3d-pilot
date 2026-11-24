// A stub MCP client for tests/calibration-mcp-write.sh: runs bin/e3d-mcp over stdio with a clean environment, declares (or not) elicitation, answers the server's
// elicitation/create the way the mode says, and prints one JSON summary. No model, no network.
//   node mcp-write-client.mjs <mode> <store dir> <home dir> [ENV=VALUE ...]
//   mode: accept (the user picks "failed"), decline, cancel, noelicit (no elicitation capability)
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '../../..');
const [mode, store, home, ...extra] = process.argv.slice(2);
const env = { PATH: process.env.PATH, HOME: home, E3D_MCP_STATE_DIR: join(home, 'state'), E3D_CALIBRATION_DIR: store, E3D_MCP_SKILLS: '1', E3D_CALIBRATION_V1: '1', E3D_CALIBRATION_MCP: '1' };
for (const kv of extra) { const i = kv.indexOf('='); env[kv.slice(0, i)] = kv.slice(i + 1); }
const srv = spawn(join(ROOT, 'bin/e3d-mcp'), [], { env, stdio: ['pipe', 'pipe', 'pipe'] });
const send = (m) => srv.stdin.write(`${JSON.stringify(m)}\n`);
const waiting = new Map();
const elicitations = [];
createInterface({ input: srv.stdout }).on('line', (line) => {
  const m = JSON.parse(line);
  if (m.method === 'elicitation/create') {
    elicitations.push(m.params);
    const result = mode === 'accept' ? { action: 'accept', content: { result: 'failed' } } : mode === 'cancel' ? { action: 'cancel' } : { action: 'decline' };
    return send({ jsonrpc: '2.0', id: m.id, result });
  }
  if (m.id !== undefined && waiting.has(m.id)) { waiting.get(m.id)(m); waiting.delete(m.id); }
});
let n = 0;
const req = (method, params) => new Promise((res) => { n += 1; waiting.set(n, res); send({ jsonrpc: '2.0', id: n, method, params }); });
const call = async (name, args) => (await req('tools/call', { name, arguments: args })).result;
const timer = setTimeout(() => { console.error('client: the server did not answer in 20 s'); srv.kill(); process.exit(3); }, 20000);

const init = await req('initialize', { protocolVersion: '2025-06-18', capabilities: mode === 'noelicit' ? {} : { elicitation: { form: {}, url: {} } }, clientInfo: { name: 'Claude Code', version: '9' } });
send({ jsonrpc: '2.0', method: 'notifications/initialized' });
const tools = (await req('tools/list', {})).result.tools;
const got = await call('e3d_get_skill', { id: 'skeptic', task_class: 'code-review' });
const useId = got.structuredContent?.use?.use_id;
const outcome = await call('e3d_skill_report_outcome', { use_id: useId, result: 'worked' });
const again = await call('e3d_skill_report_use', { use_id: useId });
const mine = await call('e3d_my_calibration', {});
clearTimeout(timer);
srv.stdin.end();
await new Promise((r) => srv.on('exit', r));
console.log(JSON.stringify({ instructions: init.result.instructions, tools: tools.map((t) => ({ name: t.name, annotations: t.annotations, _meta: t._meta ?? null })), use_id: useId, outcome, again, mine, elicitations }));
