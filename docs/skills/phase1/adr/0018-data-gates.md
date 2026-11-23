# ADR-0018: Calibration data gates

Status: **Owner-decided 2026-11-23; recorded here and awaiting reviewer sign-off like the other ADRs.** Phase: calibration 1. Spec: `spec/e3d-pilot-calibration-spec-v0.1.md`.

## Context

Showing a rate from three uses, or recommending on thin evidence, would overstate what is known. The resolved-outcome count in production is unknown (no decision-metrics window was ever opened, checked 2026-11-23).

## Decision

1. Show a per-skill record only at **10** or more resolved uses in a stratum; below it the answer is "not enough resolved outcomes" and the record carries no rate (`skill_record_insufficient`). 2. Show a personal recommendation (L1) only at **20** or more of the principal's own resolved uses of that skill on that kind of task. 3. Show reliability bins only at **30** or more resolved predictions per bin. 4. Do not start recommendations (calibration phase 6) before **200** resolved outcomes across at least **20** principals, with at least **3** skills each at 30 or more. 5. Stop expanding capture work if fewer than **15%** of reported uses have an outcome 60 days after the host phase ships. Changing a number needs an ADR.

## Consequences

The 10 is enforced by the reference check in `tests/skills-schemas.mjs` (`MIN_RESOLVED`); the engine implements the same rule in calibration phase 2.

## Alternatives considered

Stricter numbers (record at 20, 300 outcomes) delay everything; looser (record at 5) shows meaningless intervals.
