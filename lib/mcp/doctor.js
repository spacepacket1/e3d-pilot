// `e3d-mcp --doctor`: checks what the tools need, reports editor state without failing on it,
// and ends with a hint that matches what was actually found.
import { existsSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { createExternalAuth, validateConfig } from './external-auth.js';
import { OUTBOX_DEFAULTS, outboxStatus } from './outbox.js';
import { runsUsage, validateRunsConfig } from './runs.js';
import { RUN_FEATURES, validateRunServerConfig } from './run-server.js';
import { validatePanelConfig, familyOf } from './panel.js';
import { createUsage } from './usage.js';
import { ROOT, run, configuredProviders, providerLine, findE3dCode } from './util.js';

const MIN_VSCODE = [1, 99];
const MAC_CODE = '/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code';

const versionAtLeast = (v, min) => {
  const [a = 0, b = 0] = String(v).split('.').map(Number);
  return a > min[0] || (a === min[0] && b >= min[1]);
};

async function findEditor() {
  for (const bin of ['code', 'code-insiders', MAC_CODE]) {
    if (bin.startsWith('/') && !existsSync(bin)) continue;
    const r = await run(bin, ['--version'], { timeoutMs: 15000 });
    if (r.code === 0 && r.out.trim()) {
      const version = r.out.trim().split('\n')[0];
      const ext = await run(bin, ['--list-extensions'], { timeoutMs: 20000 });
      const copilot = ext.code === 0 ? /^github\.copilot(-chat)?$/im.test(ext.out) : null;
      return { bin, version, copilot };
    }
  }
  return null;
}

// The external auth and metering hook (only when E3D_MCP_AUTH_URL is set). Prints the URL's host only, never a path,
// a query or a credential; failures are reported by class, not by message.
async function hookSection(check, note) {
  console.log('\nExternal auth and metering hook:');
  const checked = validateConfig(process.env);
  let host = 'invalid URL';
  try { host = new URL(process.env.E3D_MCP_AUTH_URL).host; } catch { /* reported by the config check */ }
  console.log(`  service host: ${host}`);
  console.log(`  service token: ${process.env.E3D_MCP_AUTH_SERVICE_TOKEN || process.env.E3D_MCP_AUTH_SERVICE_TOKEN_FILE ? 'present' : 'missing'}`);
  console.log(`  cache TTL: ${checked.config.cacheSec}s`);
  const dir = createUsage({ env: process.env }).dir;
  console.log(`  outbox: ${dir}/auth-outbox`);
  check(checked.ok, 'hook configuration is valid', checked.errors.join('; ')); // messages never contain the URL or a token
  if (checked.ok) {
    try { await createExternalAuth({}).health(); check(true, 'auth service health answers'); }
    catch (e) { check(false, `auth service health did not answer (${e.kind ?? 'error'})`, 'check E3D_MCP_AUTH_URL, the service token and that the service is running'); }
  }
  const s = await outboxStatus(dir);
  console.log(`  ${s.lines[0]}`);
  const bad = s.lines.slice(1).filter((l) => /^\s+dead\s/.test(l));
  for (const l of bad) console.log(`  ${l.trim()}`);
  check(s.dead === 0, 'no dead-letter records', 'resolve the conflict with the billing service, then `e3d-mcp --outbox-retry-dead <record_id>` (docs/external-auth.md, runbook)');
  if (/[1-9]\d* stale/.test(s.lines[0])) note('stale outbox records (older than 72 h) exist: settlements are not reaching the billing service');
  // undelivered bytes (finalize records carry the debate result): at the bound, new billed work is refused
  const maxOutbox = Number(process.env.E3D_MCP_OUTBOX_MAX_BYTES) > 0 ? Number(process.env.E3D_MCP_OUTBOX_MAX_BYTES) : OUTBOX_DEFAULTS.maxBytes;
  let outboxBytes = 0;
  for (const kind of ['pending', 'claimed']) {
    let names = [];
    try { names = readdirSync(join(dir, 'auth-outbox', kind)); } catch { /* none yet */ }
    for (const n of names) { try { outboxBytes += statSync(join(dir, 'auth-outbox', kind, n)).size; } catch { /* gone */ } }
  }
  check(outboxBytes < maxOutbox, `outbox bytes ${outboxBytes} of ${maxOutbox}`, 'the billing service is not receiving settlements; new debates are refused until the outbox drains (E3D_MCP_OUTBOX_MAX_BYTES)');

  // Async debates (e3d_debate_start/_status/_result): settings, and the local run store against its byte bound.
  console.log('\nAsync debates:');
  const runsChecked = validateRunsConfig(process.env);
  check(runsChecked.ok, 'async run settings are valid', runsChecked.errors.join('; '));
  const c = runsChecked.config;
  console.log(`  slots: ${c.perPrincipal} per account, ${c.global} in total; kept: ${c.keepPerPrincipal} per account for ${c.ttlSec}s; customer maxima: rounds ${c.customer.rounds}, max_words ${c.customer.max_words}, providers ${c.customer.providers}`);
  const u = runsUsage(dir);
  console.log(`  run store: ${u.root} (${u.runs} run(s))`);
  check(u.bytes < c.maxBytes, `run store bytes ${u.bytes} of ${c.maxBytes}`, 'new async debates are refused until finished runs expire (E3D_MCP_RUNS_TTL_SEC, E3D_MCP_RUNS_MAX_BYTES)');
  note('the async tools appear only while the service advertises both `finalize` and `fetch` in its introspect answers (learned per request; see docs/external-auth.md)');
}

// The internal run listener (web runs): only when E3D_MCP_RUN_PORT or E3D_MCP_RUN_TOKEN is set. Never prints the token.
function runServerSection(check, note) {
  const rs = validateRunServerConfig(process.env);
  if (!rs.enabled) return;
  console.log('\nInternal run listener:');
  console.log(`  address: 127.0.0.1:${rs.config.port ?? 'invalid'} (loopback only; the public listener never serves /internal/*)`);
  console.log(`  run token: ${process.env.E3D_MCP_RUN_TOKEN ? `present, ${process.env.E3D_MCP_RUN_TOKEN.length} characters` : 'missing'}`);
  check(rs.ok, 'internal run listener settings are valid', rs.errors.join('; '));
  note(`new web runs are accepted only while the service advertises ${RUN_FEATURES.join(', ')} (learned from introspect answers)`);
}

// The hosted allowlist and per-account panels: only when E3D_MCP_ALLOWED_PROVIDERS or E3D_MCP_PANEL is set. Prints ids and
// families, to compare with billing's PILOT_PANEL_PROVIDERS (its startup log prints the same; ops/panel-check.js compares).
function panelSection(check, note, providers) {
  if (!process.env.E3D_MCP_ALLOWED_PROVIDERS && !process.env.E3D_MCP_PANEL) return;
  console.log('\nDebate panels:');
  const pc = validatePanelConfig(process.env);
  check(pc.ok, 'panel settings are valid', pc.errors.join('; '));
  if (pc.allowed) {
    console.log(`  allowed providers: ${pc.allowed.map((p) => `${p}:${familyOf(p)}`).join(', ')}`);
    const down = pc.allowed.filter((p) => !providers.some((k) => k.name === p && k.available));
    if (down.length) note(`allowed but not available here: ${down.join(', ')} (accounts that chose them run without them, or are refused)`);
  }
  console.log(`  default (E3D_MCP_PROVIDERS): ${process.env.E3D_MCP_PROVIDERS || 'unset'}`);
  console.log(`  account panels (E3D_MCP_PANEL): ${pc.panel ? 'on: every hosted debate asks billing first' : 'off'}`);
}

export async function doctor() {
  let failed = false;
  const check = (pass, label, fix) => {
    console.log(`${pass ? 'ok  ' : 'FAIL'}  ${label}${pass ? '' : `\n      -> ${fix}`}`);
    if (!pass) failed = true;
  };
  const note = (label) => console.log(`--    ${label}`);

  console.log('Requirements:');
  const major = Number.parseInt(process.versions.node, 10);
  check(major >= 18, `node ${process.versions.node}`, 'install Node 18 or newer');
  const bash = await run('bash', ['-c', 'echo ${BASH_VERSINFO[0]}'], { timeoutMs: 5000 });
  const bashMajor = Number.parseInt(bash.out, 10);
  check(bashMajor >= 4, `bash on PATH is version ${Number.isFinite(bashMajor) ? bashMajor : 'missing'} (needs 4+)`,
    'macOS ships bash 3.2: `brew install bash` and make sure it comes first on PATH');
  const jq = await run('jq', ['--version'], { timeoutMs: 5000 });
  check(jq.code === 0, 'jq installed', 'brew install jq  (or apt install jq)');
  const git = await run('git', ['--version'], { timeoutMs: 5000 });
  check(git.code === 0, 'git installed (the pipeline tools work inside git repos)', 'install git');

  console.log('\nModel providers (a debate needs at least 2):');
  const providers = await configuredProviders();
  for (const p of providers) console.log(`  ${p.available ? 'ok  ' : '--  '} ${providerLine(p)}`);
  const avail = providers.filter((p) => p.available);
  check(avail.length >= 2, `${avail.length} provider(s) available`,
    'install and log in to two model CLIs, e.g. `claude` and `codex`; see README "Providers"');

  if (process.env.E3D_MCP_AUTH_URL) await hookSection(check, note);
  runServerSection(check, note);
  panelSection(check, note, providers);

  console.log('\nOptional:');
  const e3dCode = await findE3dCode();
  if (e3dCode) console.log(`ok    e3d-code found (${e3dCode})`);
  else note('e3d-code not found. It is the tool that writes code phase by phase from a spec. Only the pipeline\'s execute stage needs it; debate and the read-only tools do not. Install: npm install -g e3d-code');

  const editor = await findEditor();
  let editorState = 'none';
  if (!editor) {
    note('VS Code not detected on PATH (fine if you use another MCP client; in VS Code run "Shell Command: Install \'code\' command in PATH")');
  } else if (!versionAtLeast(editor.version, MIN_VSCODE)) {
    editorState = 'old';
    note(`VS Code ${editor.version} is older than ${MIN_VSCODE.join('.')}, which MCP in agent mode needs`);
  } else {
    console.log(`ok    VS Code ${editor.version}`);
    if (editor.copilot === true) { editorState = 'ready'; console.log('ok    GitHub Copilot extension installed'); }
    else if (editor.copilot === false) {
      // Recent VS Code builds ship Copilot Chat built in, so it is no longer listed as an extension.
      editorState = 'ready';
      note('no separate GitHub Copilot extension is listed. Recent VS Code builds include Copilot Chat built in, so this is likely fine; if the Chat view is missing, sign in to GitHub Copilot from the Accounts menu');
    }
    else { editorState = 'ready'; note('could not list VS Code extensions, so Copilot was not checked'); }
  }

  const next = {
    none: 'No VS Code found. For another MCP client, run `e3d-mcp --print-config` and adapt it; for VS Code, install it first.',
    old: 'Update VS Code, then run `e3d-mcp --print-config` and paste it into .vscode/mcp.json.',
    nocopilot: 'Make sure GitHub Copilot Chat is available in VS Code, then run `e3d-mcp --print-config` and paste it into .vscode/mcp.json.',
    ready: 'Next: run `e3d-mcp --print-config`, paste it into .vscode/mcp.json, and start the server from the code lens in that file.',
  }[editorState];
  console.log(failed ? '\nFix the FAIL items above, then re-run.' : `\nRequirements met. ${next}`);
  return failed ? 1 : 0;
}

export const checkoutConfigHint = () => existsSync(join(ROOT, '.git'));
