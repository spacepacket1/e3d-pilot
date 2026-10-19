// Shared helpers for bin/e3d-mcp and the other lib/mcp modules. Zero dependencies.
import { spawn } from 'node:child_process';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { redact } from './redact.js';

export const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

export const log = (...a) => process.stderr.write(`[e3d-mcp] ${redact(a.join(' '))}\n`);
export const text = (t, isError = false) => ({ content: [{ type: 'text', text: t }], ...(isError ? { isError: true } : {}) });

// signal (optional AbortSignal): stops the child (a cancelled run); the result then has cancelled: true.
export function run(cmd, args, { timeoutMs = 60000, onStderr, cwd = ROOT, env = process.env, input, signal } = {}) {
  return new Promise((res) => {
    const child = spawn(cmd, args, { cwd, env, stdio: [input === undefined ? 'ignore' : 'pipe', 'pipe', 'pipe'] });
    let out = '', err = '', timedOut = false, cancelled = false;
    const timer = setTimeout(() => { timedOut = true; child.kill('SIGTERM'); }, timeoutMs);
    const onAbort = () => { cancelled = true; child.kill('SIGTERM'); };
    if (signal?.aborted) onAbort(); else signal?.addEventListener('abort', onAbort, { once: true });
    const done = () => { clearTimeout(timer); signal?.removeEventListener('abort', onAbort); };
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { err += d; onStderr?.(String(d)); });
    child.on('error', (e) => { done(); res({ code: 127, out, err: String(e), timedOut, ...(cancelled ? { cancelled } : {}) }); });
    child.on('close', (code) => { done(); res({ code, out, err, timedOut, ...(cancelled ? { cancelled } : {}) }); });
    if (input !== undefined) child.stdin.end(input);
  });
}

// `e3d-pilot providers list` prints "name  state  detail"; detail usually starts by repeating the state word.
export async function configuredProviders() {
  const r = await run(join(ROOT, 'bin/e3d-pilot'), ['providers', 'list'], { timeoutMs: 30000 });
  return r.out.split('\n').map((l) => l.trim().split(/\s+/)).filter((p) => p.length >= 2)
    .map(([name, state, ...rest]) => {
      const available = state === 'available';
      const detail = rest.join(' ').replace(/^(available|unavailable)(:\s*|\s+)?/i, '');
      return { name, available, detail };
    });
}

// One wording for both e3d_list_providers and --doctor.
export const providerLine = (p) => `${p.name}: ${p.available ? 'available' : 'unavailable'}${p.detail ? ` (${p.detail.replace(/^\((.*)\)$/, '$1')})` : ''}`;

export const NAME_RE = /^[a-z0-9][a-z0-9_-]*$/;

// Same resolution order as the CLI: PATH (e3d-code, then the old spec2code name), then npm install layouts.
export async function findE3dCode() {
  const r = await run('bash', ['-c', `command -v e3d-code || command -v spec2code || ls "${ROOT}/../e3d-code/bin/e3d-code" "${ROOT}/node_modules/e3d-code/bin/e3d-code" 2>/dev/null | head -1`], { timeoutMs: 5000 });
  const path = r.out.trim().split('\n')[0];
  return r.code === 0 && path ? path : null;
}
