// Loaded with NODE_OPTIONS=--import=<this file> by tests/calibration-mcp-write.sh: logs every module URL the process resolves to $E3D_TEST_LOAD_LOG, so the
// test can show that with the calibration flags off none of the calibration code is loaded. Test-only; nothing in the product imports it.
// Node 22.15+/23.5+ has the synchronous registerHooks; older Node (20.6+) falls back to the async module.register hooks in load-log-hooks.mjs.
import * as nodeModule from 'node:module';
import { appendFileSync } from 'node:fs';

const LOG = process.env.E3D_TEST_LOAD_LOG;
if (LOG) {
  if (typeof nodeModule.registerHooks === 'function') {
    nodeModule.registerHooks({ resolve(specifier, context, next) { const r = next(specifier, context); try { appendFileSync(LOG, `${r.url}\n`); } catch { /* best effort */ } return r; } });
  } else if (typeof nodeModule.register === 'function') {
    nodeModule.register('./load-log-hooks.mjs', import.meta.url);
  }
}
