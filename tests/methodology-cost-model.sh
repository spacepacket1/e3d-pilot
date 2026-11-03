#!/usr/bin/env bash
# The token-cost and coverage models (lib/debate/cost-model.mjs) and the paper that quotes them (docs/methodology/expert-councils.md): the model behaves as its
# equations say, and every number in the paper's tables is the model's output, so the paper cannot drift. Pure computation: no model call, no network.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node --input-type=module - "$ROOT" <<'NODE'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const root = process.argv[2];
const { tokens, coverage, DEFAULTS } = await import(`${root}/lib/debate/cost-model.mjs`);
const doc = readFileSync(`${root}/docs/methodology/expert-councils.md`, 'utf8');
const f = (x) => x.toLocaleString('en-US');

// ---- the model does what its equations say ----
const { Q, B1, B2, Bs, L, A, S } = DEFAULTS;
const by = tokens({ n: 4, r: 2 });
assert.equal(by.input, 4 * (Q + B1 + L) + 1 * 4 * (Q + B2 + L + 3 * A) + (Q + Bs + 4 * 2 * A), 'E3 input');
assert.equal(by.output, 4 * 2 * A + S, 'E3 output');
assert.equal(by.total, by.input + by.output);
assert.equal(by.calls, 9, 'seats x rounds + 1');
for (let n = 1; n <= 8; n++) for (let r = 1; r <= 4; r++) {
  const w = tokens({ n, r, lens: true }), wo = tokens({ n, r, lens: false });
  assert.equal(w.total - wo.total, n * r * L, `a lens adds n*r*L tokens (n=${n}, r=${r})`);
  assert.equal(w.calls, n * r + 1);
  if (n > 1) assert.ok(tokens({ n, r }).total > tokens({ n: n - 1, r }).total, 'more seats cost more');
  if (r > 1) assert.ok(tokens({ n, r }).total > tokens({ n, r: r - 1 }).total, 'more rounds cost more');
}
// cost grows faster than the seat count: doubling the seats more than doubles the cost
assert.ok(tokens({ n: 8, r: 2 }).total > 2 * tokens({ n: 4, r: 2 }).total, 'superlinear in seats');
// a round costs the same every time from round 2 on (each reads only the previous round)
const d = [2, 3, 4].map((r) => tokens({ n: 4, r }).total).map((x, i, a) => (i ? x - a[i - 1] : 0));
assert.equal(d[1], d[2], 'each added round after the second costs the same');
// overrides
assert.equal(tokens({ n: 2, r: 1, lens: false, Q: 0, B1: 0, Bs: 0, A: 10, S: 0 }).total, 2 * 0 + (0 + 0 + 2 * 1 * 10) + 2 * 1 * 10, 'overrides apply');
assert.throws(() => tokens({ n: 0, r: 1 }), RangeError);
assert.throws(() => tokens({ n: 1.5, r: 1 }), RangeError);
assert.throws(() => tokens({ n: 2, r: 0 }), RangeError);

// coverage: E4 and E5
assert.equal(coverage({ p: 0.4, n: 4, rho: 0 }).nEff, 4);
assert.ok(Math.abs(coverage({ p: 0.4, n: 4, rho: 0 }).P - (1 - 0.6 ** 4)) < 1e-12, 'independent seats: 1-(1-p)^n');
assert.ok(Math.abs(coverage({ p: 0.4, n: 4, rho: 1 }).P - 0.4) < 1e-12, 'identical seats: no better than one');
assert.ok(coverage({ p: 0.4, n: 4, rho: 0.2 }).P > coverage({ p: 0.4, n: 4, rho: 0.6 }).P, 'less correlated seats catch more');
assert.equal(coverage({ p: 0.4, n: 1, rho: 0.7 }).P, 0.4, 'one seat is just p');
assert.throws(() => coverage({ p: 1.2, n: 2, rho: 0 }), RangeError);
assert.throws(() => coverage({ p: 0.4, n: 2, rho: -0.1 }), RangeError);

// ---- every number in the paper is the model's ----
const base = tokens({ n: 4, r: 2, lens: false }).total;
const rows = [
  ['2 seats, no skills', 2, 2, false], ['4 seats, no skills', 4, 2, false], ['4 seats, a skill each', 4, 2, true], ['3 skills, all on one adapter', 3, 2, true],
  ['6 seats', 6, 2, true], ['8 seats (above the cap)', 8, 2, true], ['8 seats, one round', 8, 1, true], ['4 seats, one round', 4, 1, true],
  ['4 seats, three rounds', 4, 3, true], ['4 seats, four rounds', 4, 4, true],
];
for (const [label, n, r, lens] of rows) {
  const t = tokens({ n, r, lens });
  const line = doc.split('\n').find((l) => l.startsWith(`| ${label}`));
  assert.ok(line, `the paper has a row for "${label}"`);
  const cells = line.split('|').map((c) => c.trim());
  assert.equal(cells[2], String(n), `${label}: seats`);
  assert.equal(cells[3], String(r), `${label}: rounds`);
  assert.equal(cells[4], String(t.calls), `${label}: calls`);
  assert.equal(cells[5], f(t.total), `${label}: total tokens`);
  assert.equal(cells[6], `${(t.total / base).toFixed(1)}x`, `${label}: ratio to the plain council`);
}
for (const [label, rho] of [['fully independent', 0], ['somewhat alike', 0.5], ['very alike (one model)', 0.8]]) {
  const c = coverage({ p: 0.4, n: 4, rho });
  const cells = doc.split('\n').find((l) => l.startsWith(`| ${label}`)).split('|').map((x) => x.trim());
  assert.equal(cells[2], String(rho), `${label}: rho`);
  assert.equal(cells[3], c.nEff.toFixed(1), `${label}: n_eff`);
  assert.equal(cells[4], c.P.toFixed(2), `${label}: P`);
}
// the numbers the spec quotes for the cap
const spec = readFileSync(`${root}/docs/specs/experts-phase2a-seats-and-suggest-spec.md`, 'utf8');
assert.ok(spec.includes('6 seats at about 1.9 times') && spec.includes('8 seats at about 2.8 times'), 'the spec quotes the cap ratios');
assert.equal((tokens({ n: 6, r: 2 }).total / base).toFixed(1), '1.9');
assert.equal((tokens({ n: 8, r: 2 }).total / base).toFixed(1), '2.8');
// the constants stated in the paper are the model's
for (const [k, v] of Object.entries(DEFAULTS)) assert.ok(new RegExp(`\`${k}\`=${v}\\b`).test(doc), `the paper states ${k}=${v}`);
// results are pending or measured, never invented: four comparisons are still pending, and F vs E carries its recorded run
assert.equal((doc.match(/\| pending \| pending \| pending \| not run \|/g) ?? []).length, 4, 'four comparisons are still pending');
const fve = doc.split('\n').find((l) => l.startsWith('| F vs E'));
assert.ok(fve && fve.includes('inconclusive'), 'F vs E carries its run and says inconclusive');
const rj = readFileSync(`${root}/docs/experiments/2026-11-02-fve-planted-errors/RESULTS.md`, 'utf8');
assert.ok(rj.length > 500 && /inconclusive/i.test(rj), 'the F vs E write-up exists and says inconclusive');
// the model uses no network, process or file access
const src = readFileSync(`${root}/lib/debate/cost-model.mjs`, 'utf8');
for (const w of ['fetch(', 'node:fs', 'node:net', 'node:http', 'child_process', 'spawn', 'import(', 'writeFile']) assert.ok(!src.includes(w), `the model must not use ${w}`);
console.log('cost-model: ok');
NODE
echo "methodology-cost-model.sh: PASS"
