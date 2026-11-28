// execFile that ends a provider adapter with SIGTERM first, so the adapter's TERM trap (lib/providers/common.sh) can stop its curl and remove its prompt
// directory, then SIGKILL a few seconds later if it is still running. Resolves like the runners' own helper: { error, stdout, stderr }.
import { execFile } from 'node:child_process';

export const KILL_GRACE_MS = 5000;

export function execFileTerm(file, args, opts = {}, graceMs = KILL_GRACE_MS) {
  return new Promise((resolve) => {
    let done = false, timer = null;
    const child = execFile(file, args, { ...opts, killSignal: 'SIGTERM' }, (error, stdout, stderr) => {
      done = true; if (timer) clearTimeout(timer);
      resolve({ error, stdout: String(stdout ?? ''), stderr: String(stderr ?? '') });
    });
    const escalate = () => {
      if (done || timer) return;
      timer = setTimeout(() => { if (!done) { try { child.kill('SIGKILL'); } catch { /* already gone */ } } }, graceMs);
      timer.unref?.();
    };
    if (opts.timeout > 0) { const t = setTimeout(escalate, opts.timeout); t.unref?.(); child.once('close', () => clearTimeout(t)); }
    if (opts.signal) { if (opts.signal.aborted) escalate(); else opts.signal.addEventListener('abort', escalate, { once: true }); }
  });
}
