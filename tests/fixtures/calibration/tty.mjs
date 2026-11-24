// Run a command under a pseudo-terminal (stdin and stdout are a TTY), for the D12 tests of the calibration CLI (plan-calibration-3-mcp.md, threat row C-T16).
// Uses the system `script` (BSD syntax on macOS, util-linux syntax elsewhere). Output is the terminal's: CR LF line ends and stderr mixed in; `clean` removes the
// CRs and the "^D" echo of the closed stdin. Exported: tty(cmd, args, env) -> { rc, out }, ttyJson(out) -> the last JSON object printed.
import { spawnSync } from 'node:child_process';

const quote = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;
export const clean = (s) => s.replace(/\r/g, '').replace(/\^D\x08\x08/g, '');

export function tty(cmd, args, env) {
  const r = process.platform === 'darwin'
    ? spawnSync('script', ['-q', '/dev/null', cmd, ...args], { env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
    : spawnSync('script', ['-qec', [cmd, ...args].map(quote).join(' '), '/dev/null'], { env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  return { rc: r.status, out: clean(r.stdout || '') };
}

// Whether the helper can give a command a terminal on this machine (checked once). When it cannot, the TTY cases SKIP with a message; they never pass vacuously.
export class TtySkip extends Error {}
let avail = null;
export function ttyAvailable() {
  if (avail === null) { try { const r = tty('sh', ['-c', 'test -t 0 && test -t 1 && echo TTY-OK'], { PATH: process.env.PATH }); avail = r.rc === 0 && r.out.includes('TTY-OK'); } catch { avail = false; } }
  return avail;
}
export function needTty() { if (!ttyAvailable()) throw new TtySkip(`the \`script\` helper cannot allocate a pseudo-terminal here (${process.platform}); the terminal (D12) cases were not run`); }

export function ttyJson(out) {
  const end = out.lastIndexOf('}');
  for (let start = out.lastIndexOf('{', end); start >= 0; start = out.lastIndexOf('{', start - 1)) {
    try { return JSON.parse(out.slice(start, end + 1)); } catch { /* not yet the outermost brace */ }
  }
  throw new Error(`no JSON in terminal output: ${out.slice(0, 300)}`);
}

// node tty.mjs <cmd> <args...>: the same, for shell tests; prints the cleaned output and exits with the command's status
if (process.argv[1] && import.meta.url.endsWith(process.argv[1].split('/').pop())) {
  const [cmd, ...args] = process.argv.slice(2);
  if (cmd === '--available') process.exit(ttyAvailable() ? 0 : 1);
  const r = tty(cmd, args, process.env);
  process.stdout.write(r.out);
  process.exit(r.rc ?? 1);
}
