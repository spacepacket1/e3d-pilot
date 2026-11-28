// Async resolve hook for Node versions without module.registerHooks (see load-log.mjs). Runs on the hooks thread; env vars are shared with it.
import { appendFileSync } from 'node:fs';

export async function resolve(specifier, context, nextResolve) {
  const r = await nextResolve(specifier, context);
  const log = process.env.E3D_TEST_LOAD_LOG;
  if (log) { try { appendFileSync(log, `${r.url}\n`); } catch { /* best effort */ } }
  return r;
}
