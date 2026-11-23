// A writer for the append-race test of tests/fixtures/calibration/local.mjs: argv = dir, mode, count, tag.
//   mode "distinct": count outcomes, each for its own use (all must land)
//   mode "same":     count reports for ONE use (the chain of corrections must stay a single linear chain)
import { reportOutcome } from '../../../lib/calibration/store.mjs';
const [dir, mode, count, tag] = process.argv.slice(2);
const n = Number(count);
let done = 0;
for (let i = 0; i < n; i++) {
  const use_id = mode === 'same' ? 'use_race0001' : `use_${tag}${String(i).padStart(4, '0')}`;
  try { reportOutcome(dir, { use_id, result: i % 2 ? 'worked' : 'failed' }, Date.parse('2026-12-01T00:00:00Z')); done += 1; } catch (e) { console.error(e.code || e.message); }
}
console.log(done);
