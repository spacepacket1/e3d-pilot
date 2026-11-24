// A writer for the append-race test of tests/fixtures/calibration/local.mjs: argv = dir, mode, count, tag.
//   mode "distinct": count outcomes, each for its own use (all must land)
//   mode "same":     count reports for ONE use (the chain of corrections must stay a single linear chain)
import { compact, reportOutcome, withLock } from '../../../lib/calibration/store.mjs';
const [dir, mode, count, tag] = process.argv.slice(2);
const n = Number(count);
if (mode === 'take') { try { withLock(dir, () => console.log('got')); } catch (e) { console.log(`err:${e.code}`); } process.exit(0); } // take the lock once and report
if (mode === 'compact') { try { console.log(JSON.stringify(compact(dir, Date.now()))); } catch (e) { console.log(`err:${e.code}`); } process.exit(0); }
if (mode === 'hold') { // take the lock and keep it for `count` milliseconds (a slow or suspended holder that is still alive)
  withLock(dir, () => { console.log('held'); Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, n); });
  process.exit(0);
}
let done = 0;
for (let i = 0; i < n; i++) {
  const use_id = mode === 'same' ? 'use_race0001' : `use_${tag}${String(i).padStart(4, '0')}`;
  try { reportOutcome(dir, { use_id, result: i % 2 ? 'worked' : 'failed' }, Date.parse('2026-12-01T00:00:00Z')); done += 1; } catch (e) { console.error(e.code || e.message); }
}
console.log(done);
