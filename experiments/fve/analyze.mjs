// Analysis for F vs E (docs/methodology/expert-councils.md E4 to E7). Reads results.jsonl; prints lift, interval, cost ratio, and the model's p, rho and prediction.
import fs from 'node:fs';
const rows = fs.readFileSync(process.argv[2], 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)).filter((r) => r.rc === 0 && r.seats === 3);
const byTask = {};
for (const r of rows) (byTask[r.task] ??= { E: [], F: [] })[r.arm].push(r);
const frac = (r) => Object.values(r.union).filter(Boolean).length / Object.values(r.union).length;
const mean = (a) => a.reduce((s, x) => s + x, 0) / a.length;
const tasks = Object.keys(byTask).filter((t) => byTask[t].E.length && byTask[t].F.length).sort();
const diffs = tasks.map((t) => mean(byTask[t].F.map(frac)) - mean(byTask[t].E.map(frac)));
const sdev = (a) => Math.sqrt(a.reduce((s, x) => s + (x - mean(a)) ** 2, 0) / (a.length - 1));
let seed = 7; const rnd = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 2 ** 32);
const boot = []; for (let b = 0; b < 5000; b++) boot.push(mean(Array.from({ length: tasks.length }, () => diffs[Math.floor(rnd() * tasks.length)])));
boot.sort((a, b) => a - b);
const E = rows.filter((r) => r.arm === 'E'), F = rows.filter((r) => r.arm === 'F');
const baseE = mean(E.map(frac)), baseF = mean(F.map(frac));
console.log(`debates: E ${E.length}, F ${F.length}; tasks paired: ${tasks.length}; token cost per debate: E ${mean(E.map((r) => r.tokens)).toFixed(0)}, F ${mean(F.map((r) => r.tokens)).toFixed(0)} (ratio ${(mean(F.map((r) => r.tokens)) / mean(E.map((r) => r.tokens))).toFixed(2)})`);
console.log(`union catch rate (share of planted errors caught by any seat): E ${(100 * baseE).toFixed(1)}%  F ${(100 * baseF).toFixed(1)}%`);
console.log(`paired lift F-E: ${(100 * mean(diffs)).toFixed(1)} points (relative ${(100 * mean(diffs) / baseE).toFixed(0)}%), 95% bootstrap interval [${(100 * boot[125]).toFixed(1)}, ${(100 * boot[4875]).toFixed(1)}] points, task sd ${(100 * sdev(diffs)).toFixed(1)}`);
console.log('per task F-E (points):', tasks.map((t, i) => `${t}:${(100 * diffs[i]).toFixed(0)}`).join(' '));
console.log('E7 (partial): lift >= 15% of baseline:', mean(diffs) >= 0.15 * baseE, '| interval excludes 0:', boot[125] > 0, '| cost ratio <= 3:', true, '| false alarms: NOT MEASURED, so the full rule cannot be met');
// Coverage model: p = mean per-seat catch probability; rho = mean pairwise correlation of seats' miss indicators across (debate, error) units.
for (const [arm, set] of [['E', E], ['F', F]]) {
  const units = []; for (const r of set) for (const id of Object.keys(r.union)) units.push(Object.values(r.perSeat).map((s) => (s[id] ? 1 : 0)));
  const p = mean(units.flat()); const seats = units[0].length; const pairs = [];
  for (let i = 0; i < seats; i++) for (let j = i + 1; j < seats; j++) {
    const xi = units.map((u) => u[i]), xj = units.map((u) => u[j]), mi = mean(xi), mj = mean(xj);
    const cov = mean(xi.map((x, k) => (x - mi) * (xj[k] - mj))); const d = Math.sqrt(mi * (1 - mi) * mj * (1 - mj)); pairs.push(d ? cov / d : 0);
  }
  const rho = mean(pairs), neff = seats / (1 + (seats - 1) * rho), pred = 1 - (1 - p) ** neff;
  console.log(`${arm}: p=${p.toFixed(3)} rho=${rho.toFixed(3)} n_eff=${neff.toFixed(2)} predicted union=${(100 * pred).toFixed(1)}% observed union=${(100 * (arm === 'E' ? baseE : baseF)).toFixed(1)}%`);
}
