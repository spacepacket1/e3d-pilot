// The derived track record (calibration spec sections 3.4, 4 and 9; ADR-0017, ADR-0018). Pure: no file, no clock, no network. Everything here describes
// what was recorded; nothing here scores, ranks or judges a skill. A record is DERIVED from uses and outcomes each time and is never stored.
//
// Formulas (a reviewer can check each one against this file):
//   Wilson 95% interval for x successes in n resolved uses, z = 1.959963984540054:
//     p = x / n;  d = 1 + z^2 / n;  centre = (p + z^2 / (2n)) / d;  half = z * sqrt(p(1-p)/n + z^2 / (4n^2)) / d;  interval = [centre - half, centre + half]
//     clamped to [0, 1]; every reported number is rounded to 4 decimals (the spec's example precision).
//   resolution_rate = n_resolved / n_uses;  reminded_share = reminded uses / n_uses;  success.rate = worked / n_resolved.
//   A use is RESOLVED when it is past its horizon (when one is known), has a current outcome, the outcome tier is not `inferred`, and the result is
//   `worked` or `failed`. `unknown` is stored but is not resolved. A use younger than its horizon is unresolved, never a failure, and its outcome is not
//   counted yet (right-censoring, spec section 4).
//   Below MIN_RESOLVED (10) resolved uses: status `insufficient_evidence`, and no rate, interval, baseline or calibration.
//   Reliability bins (only when predictions exist): equal-width bins of 0.1 over the stated confidence (the last bin includes 1.0); the block is produced
//   only when every non-empty bin holds at least BIN_MIN (30) resolved predictions; brier = mean((confidence - outcome)^2), outcome 1 for worked, 0 for failed.
export const MIN_RESOLVED = 10;
export const BIN_MIN = 30;
export const Z95 = 1.959963984540054;
const DAY_MS = 86400000;

export const round4 = (x) => Math.round(x * 1e4) / 1e4;
const clamp01 = (x) => Math.min(1, Math.max(0, x));

// Wilson score interval. n >= 1 and 0 <= x <= n. -> [lo, hi] rounded to 4 decimals.
export function wilson95(x, n) {
  if (!Number.isInteger(x) || !Number.isInteger(n) || n < 1 || x < 0 || x > n) throw new RangeError('wilson95 needs integers with n >= 1 and 0 <= x <= n');
  const p = x / n;
  const z2 = Z95 * Z95;
  const d = 1 + z2 / n;
  const centre = (p + z2 / (2 * n)) / d;
  const half = (Z95 * Math.sqrt((p * (1 - p)) / n + z2 / (4 * n * n))) / d;
  return [round4(clamp01(centre - half)), round4(clamp01(centre + half))];
}

const keyOf = (u) => JSON.stringify([u.skill.id, u.skill.version, u.skill.hash, u.task_class, u.mode, u.host.model_family]);
export const strataOf = (uses) => {
  const m = new Map();
  for (const u of uses) { const k = keyOf(u); if (!m.has(k)) m.set(k, []); m.get(k).push(u); }
  return [...m.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).map(([, v]) => v);
};

export const isResolved = (o) => !!o && o.tier !== 'inferred' && (o.result === 'worked' || o.result === 'failed');

// Reliability bins from [{ confidence, worked }] of resolved predictions. -> { bins, brier } or null (fewer than BIN_MIN in some non-empty bin, or none).
export function calibrationBlock(pairs) {
  if (!pairs.length) return null;
  const bins = new Map();
  for (const { confidence, worked } of pairs) {
    if (!(confidence >= 0 && confidence <= 1)) throw new RangeError('confidence must be within 0 and 1');
    const i = Math.min(9, Math.floor(confidence * 10));
    const b = bins.get(i) || { n: 0, w: 0 };
    b.n += 1; b.w += worked ? 1 : 0; bins.set(i, b);
  }
  if ([...bins.values()].some((b) => b.n < BIN_MIN)) return null;
  const out = [...bins.entries()].sort(([a], [b]) => a - b).map(([i, b]) => ({ stated_mid: round4(i / 10 + 0.05), n: b.n, realised: round4(b.w / b.n) }));
  const brier = pairs.reduce((s, { confidence, worked }) => s + (confidence - (worked ? 1 : 0)) ** 2, 0) / pairs.length;
  return { bins: out, brier: round4(brier) };
}

// uses: the SkillUse documents of ONE (skill, version, hash, stratum) group; current: Map use_id -> its current Outcome; now: ms.
// opts.horizons: Map use_id -> days (from a Prediction); opts.predictions: Map use_id -> confidence. Neither exists in the local store in phase 2.
export function computeTrackRecord(uses, current, now, opts = {}) {
  if (!uses.length) throw new RangeError('computeTrackRecord needs at least one use');
  const u0 = uses[0];
  const horizons = opts.horizons || new Map();
  const predictions = opts.predictions || new Map();
  const by_tier = { verified: 0, user_marked: 0, host_reported: 0 };
  let worked = 0; let resolved = 0; let reminded = 0;
  const pairs = [];
  for (const u of uses) {
    if (u.reminder_enabled) reminded += 1;
    const o = current.get(u.use_id);
    const h = horizons.get(u.use_id);
    const pastHorizon = h === undefined || Date.parse(u.issued_at) + h * DAY_MS <= now;
    if (!pastHorizon || !isResolved(o)) continue;
    resolved += 1; by_tier[o.tier] += 1;
    if (o.result === 'worked') worked += 1;
    if (predictions.has(u.use_id)) pairs.push({ confidence: predictions.get(u.use_id), worked: o.result === 'worked' });
  }
  const n = uses.length;
  const enough = resolved >= MIN_RESOLVED;
  const cal = enough ? calibrationBlock(pairs) : null;
  return {
    schema_version: 'e3d.track-record/v1',
    subject: { id: u0.skill.id, version: u0.skill.version, hash: u0.skill.hash },
    stratum: { task_class: u0.task_class, mode: u0.mode, model_family: u0.host.model_family },
    scope: 'principal',
    n_uses: n,
    n_resolved: resolved,
    resolution_rate: round4(resolved / n),
    reminded_share: round4(reminded / n),
    by_tier,
    success: enough ? { count: worked, rate: round4(worked / resolved), interval95: wilson95(worked, resolved), method: 'wilson' } : null,
    baseline: null, // the local store holds only uses of skills, so there are no uses without the skill to compare with
    calibration: cal,
    status: !enough ? 'insufficient_evidence' : cal ? 'calibrated' : 'descriptive',
    computed_at: new Date(now).toISOString().replace(/\.\d{3}Z$/, 'Z'),
  };
}

// The sentence a person reads (the shape ADR-0021 allows). Describes what was recorded; it makes no claim about the skill.
export function describeRecord(r) {
  const s = `${r.subject.id} ${r.subject.version} on ${r.stratum.task_class} (${r.stratum.mode}, ${r.stratum.model_family})`;
  if (r.status === 'insufficient_evidence') return `${s}: not enough resolved outcomes (${r.n_resolved} of ${MIN_RESOLVED} needed; ${r.n_uses} uses recorded)`;
  const pct = (x) => `${Math.round(x * 100)}%`;
  return `${s}: in your ${r.n_resolved} resolved uses, ${r.success.count} were marked worked (95% interval ${pct(r.success.interval95[0])} to ${pct(r.success.interval95[1])}); ${pct(r.resolution_rate)} of ${r.n_uses} uses had a recorded outcome`;
}
