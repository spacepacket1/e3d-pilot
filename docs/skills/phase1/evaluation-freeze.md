# Skills Phase 1: evaluation freeze (pre-registration)

Status: **PROPOSED. Not frozen until a human approves it.** Every number below is a proposal made before any result exists, so that nothing
is chosen after seeing data. When approved, record the approver, the date and the commit of this file in `../README.md`; after that,
changing a threshold, arm, split or claim wording is a new version of this document with a reason, and results under the old version are still reported.
The spec (13.2, 13.3) requires approval of the quality and cost thresholds in Phase 1, before holdout results exist.

## 1. What is being tested (confirmatory questions)

| Id | Question | Comparison | Primary metric |
| --- | --- | --- | --- |
| H1 | Do skill lenses on council seats find more real problems than the same council without them? | skill seats (A4) vs plain council on the same vendors (A2) | verified issue recall: share of ground-truth issues named by at least one seat, per task |
| H2 | Does a skill council beat the strongest comparable single model at similar cost? | A4 vs A1 (best single vendor, same tools, cost-matched) | same as H1 |
| H3 | Does a metacognition recommendation pick a better route than a fixed route? (recommend-only) | auto route (M3) vs always-debate (M1), always-single (M2), explicit user route (M0) | share of tasks whose route is not dominated, judged against the task's pre-labelled best route; and credits saved at equal quality |
| H4 | Are behavioral observations accurate and properly hedged? | observer output vs graders | precision of observations (share confirmed by graders); plus a rule check: 100% of single-event patterns are labelled `hypothesis` with low sample size and an expiry |
| H5 | Does the no-skill path change? | main before vs after | **not statistical**: zero byte difference in prompts and decision log (`tests/debate-specialists.sh` goldens, `tests/skills-compat.sh`) |

Existing evidence, for context only: the one measured comparison so far (planted errors, 2026-11-02, 12 tasks, 36 errors, 144 debates) found
+2.8 points, 95% interval -4.6 to +10.2, inconclusive. Per-task differences ranged -28 to +33 points (standard deviation about 15). Nothing about
skills improving quality may be claimed from it.

## 2. Arms (pinned model ids, same evidence and tools in every arm)

| Arm | Definition |
| --- | --- |
| A0 | one model, no skill |
| A1 | strongest single vendor of the panel, same tools, token budget matched to the cost of A4 |
| A2 | plain council: same vendors as A4, no skills |
| A3 | fixed recipe: an existing preset (for example `risk-review`) |
| A4 | skill-attached council or composition under test |
| M0..M3 | route arms for H3: explicit user route, always-debate, always-single, auto (recommendation accepted by Pilot's deterministic pre-router) |

Model versions, provider adapters, router and skill content hashes are recorded in each run. A vendor-diversity arm (four vendors vs one) is a separate study and is not part of this freeze.

## 3. Tasks and split

Six categories, 10 tasks each, 60 in total (the spec's minimum is 50 before any effectiveness claim):
(1) planted-error review, (2) spec/architecture review with expert-labelled issues, (3) high-risk decision with known failure modes,
(4) trivial lookup (direct answer expected), (5) missing-evidence task (ask or research expected), (6) deterministic-validation task (no model expected).
Categories 4 to 6 are the metacognition fixtures from spec 10.1 and also serve as controls: skills must not make them worse or dearer.

Ground truth: written by a human, reviewed by a second person, not taken from any public benchmark, no private customer data
(spec 13.2). Tasks authored with model help are marked, because a model grading its own family's tasks is a leakage risk.

Split by a fixed rule so it cannot be adjusted afterwards: `sha256(task_id)` mod 5: 0 to 1 development (about 24), 2 validation (about 12), 3 to 4 holdout (about 24). The holdout task ids and a hash of
their contents are committed before any run on them; contents stay private; each arm runs on the holdout **once**, after the method is final, with no tuning on its results.

## 4. Protocol

3 repeats per task per arm, randomised order, fixed seeds where the provider allows, one retry only for infrastructure failure and reported. Two graders per task grade blind to arm;
inter-rater agreement (Cohen's kappa) must be at least 0.6 on the validation split or the rubric is revised **before** the holdout runs. A model may assist grading only if it is from a different vendor
family than the model being graded, and is never the sole grader. Exclusions are limited to: task found to be flawed before any holdout run (replaced, logged), and outage failures re-run once; no exclusion may depend on an outcome.
Uncertainty: paired bootstrap over tasks (10,000 resamples), 95% interval, reported with sample size, missing data and negative results.

## 5. Decision thresholds (proposed)

A result is labelled with one of three statuses, per question and per category:

- **supported** only if all hold: the paired difference on the primary metric is at least **+5.0 points**; the lower bound of the 95% interval is above **0**; cost is at most **1.25x** the comparison arm's credits; false positives per task are not more than **+5 points** above the comparison arm; and no category shows a loss whose interval lies wholly below -5.
- **unsupported** if the upper bound of the interval is below **+2.0 points**, or cost exceeds 1.25x with no lift, or a category shows the loss above.
- **inconclusive** otherwise, and reported as inconclusive.

Sensitivity, stated honestly: with about 24 holdout tasks and the spread seen so far (about 15 points per task), the interval half-width is roughly 6 points, so this study can only establish lifts of about 6 points or more.
Smaller real effects will be reported as inconclusive. If a larger holdout is wanted, that is an owner decision about cost, not a change after the fact.

Cost estimate for planning: 60 tasks x 5 arms x 3 repeats = 900 debates; at the 2026-11-02 size (about 4,500 tokens per debate) that is about 4.1M tokens plus grading, ceiling proposed at 6M tokens, run on the metered API key, with spend approved by the owner before Phase 6 starts.

## 6. Claim language (frozen)

Allowed: "In a pre-registered study of 60 tasks (24 held out), <arm> found <X> points more verified issues than <arm> (95% interval <a> to <b>), at <Y>x the cost. Perspectives, not a guarantee."
Allowed for any status: "Not yet measured" and "inconclusive in <N> tasks".
Not allowed: "best", "accurate", "verified" or "proven" without the definition and sample basis next to it; "improves quality" without an interval; any claim from the development or validation split; any claim
that treats likes, saves, acceptance, consensus or silence as correctness; calling a one-vendor-family council multi-model.
UI and docs follow `docs/experts.md`: skills are perspectives until a result above says otherwise.

## 7. What Phase 1 freezes and what it does not

Frozen on approval: questions, arms, categories and counts, split rule, protocol, thresholds, claim language. **Not** produced in Phase 1: the 60 tasks, the grader pool, the study itself (Phase 6).
Open for the approver: the +5.0 and 1.25x numbers, the 60-task size, the 6M-token ceiling, who the two graders are.
