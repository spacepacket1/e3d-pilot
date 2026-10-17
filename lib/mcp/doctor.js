// `e3d-mcp --doctor`: checks what the tools need, reports editor state without failing on it,
// and ends with a hint that matches what was actually found.
import { existsSync } from 'node:fs';
import { join } from 'node:path';
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
