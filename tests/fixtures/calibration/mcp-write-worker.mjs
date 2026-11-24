// A second writer for the tier-rule race in tests/fixtures/calibration/mcp-write.mjs: argv = dir, use_id, tier, result. Prints {ok} or {ok:false, code}.
// With E3D_CALIBRATION_TEST_HOOKS set it stops at store.mjs's `beforeOutcomeLock` point (after reading the chain, before taking the lock).
import { reportOutcome } from '../../../lib/calibration/store.mjs';
const [dir, use_id, tier, result] = process.argv.slice(2);
try { reportOutcome(dir, { use_id, result, tier, reported_by: tier === 'host_reported' ? 'host' : 'user' }, Date.now()); console.log(JSON.stringify({ ok: true })); } catch (e) { console.log(JSON.stringify({ ok: false, code: e.code ?? 'other' })); }
