// The token-cost and coverage models of docs/methodology/expert-councils.md. Zero dependencies, pure functions: no file, network or process access.
// The constants are ASSUMPTIONS for a typical short question (about 100 tokens), a 200-word answer (about 300 tokens) and the engine's fixed prompt
// text; real debates are heavier, the ratios between setups are what the model is for. `--show-panel` (Phase 2a.2) uses the same function.
export const DEFAULTS = Object.freeze({ Q: 100, B1: 300, B2: 500, Bs: 400, L: 130, A: 300, S: 400 });

const posInt = (v, name) => { if (!Number.isInteger(v) || v < 1) throw new RangeError(`${name} must be a whole number of at least 1`); };

// n seats, r rounds. Every seat answers once per round; from round 2 each seat reads the other n-1 answers of the previous round; the synthesis reads the
// whole transcript. lens: whether each prompt carries an expert's lens block (L tokens, repeated every round).
export function tokens({ n, r, lens = true, ...override }) {
  posInt(n, 'n'); posInt(r, 'r');
  const { Q, B1, B2, Bs, L, A, S } = { ...DEFAULTS, ...override };
  const l = lens ? L : 0;
  const input = n * (Q + B1 + l) + (r - 1) * n * (Q + B2 + l + (n - 1) * A) + (Q + Bs + n * r * A);
  const output = n * r * A + S;
  return { input, output, total: input + output, calls: n * r + 1 };
}

// p: the chance one seat finds a given problem. rho: the average correlation between seats' misses (0 independent, 1 identical).
// n_eff = n / (1 + (n-1) rho); P = 1 - (1-p)^n_eff. A rough model, not an exact one.
export function coverage({ p, n, rho }) {
  posInt(n, 'n');
  if (!(p >= 0 && p <= 1)) throw new RangeError('p must be between 0 and 1');
  if (!(rho >= 0 && rho <= 1)) throw new RangeError('rho must be between 0 and 1');
  const nEff = n / (1 + (n - 1) * rho);
  return { nEff, P: 1 - Math.pow(1 - p, nEff) };
}
