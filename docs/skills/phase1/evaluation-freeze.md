# Skills Phase 1: evaluation freeze (pre-registration)

Status: **PROPOSED. Not frozen until a human approves it.** Every number below is a proposal made before any result exists. On approval, record the
approver, the date and the commit of this file in `../README.md` and mark that commit with a signed git tag (`skills-eval-freeze-v1`); a file
without that tag is not frozen. After that, changing a threshold, arm, split, metric or claim wording is a new version of this document with a reason,
and results under the old version are still reported. The spec (13.2, 13.3) requires approval of quality and cost thresholds in Phase 1, before holdout results exist.
This version incorporates the independent review of the first draft (hierarchy of tests, stratified split, effective sample size, defined metrics).

## 1. Hypotheses and their order

| Id | Role | Question | Comparison | Primary metric |
| --- | --- | --- | --- | --- |
| H1 | **the one primary test** | Do skill lenses on council seats find more real problems than the same council without them? | A4 vs A2 (same vendors, same seats, same per-seat output cap) | verified-issue recall per task (section 4) |
| H2 | secondary | Does a skill council beat the strongest single model at matched cost? | A4 vs A1 | same |
| H3 | secondary | Does the metacognition route land in the acceptable set more often than a fixed route? (recommend-only) | auto route M3 vs always-debate M1 | share of tasks whose route is in the task's pre-labelled acceptable set; threshold in section 5 |
| H4 | secondary | Are behavioral observations accurate and hedged? | observer output vs graders | precision of observations; hedging rule |
| H5 | hard gate, not statistical | Does the no-skill path change? | main before and after | zero byte difference in prompts and decision log |

H2 to H4 are tested with Holm correction across the three of them at overall 5%. Categories are **exploratory and descriptive only**: per-category intervals rest on a handful of
tasks and carry no veto and no claim. Only H1 can by itself support a headline claim.

Existing evidence, for context only: the one measured comparison so far (planted errors, 2026-11-02, 12 tasks, 36 errors, 144 debates) found +2.8 points, 95% interval -4.6 to +10.2, inconclusive;
per-task differences ranged -28 to +33 (standard deviation about 15, itself uncertain from 12 tasks). Those tasks are in the repository and are **not reused** (contaminated).

## 2. Arms (pinned model ids; same evidence, tools and per-seat output cap in every arm)

| Arm | Definition |
| --- | --- |
| A0 | one model, no skill |
| A1 | the strongest single vendor, **chosen on the validation split before any holdout run**, same tools, token budget matched to A4's cost |
| A2 | plain council: the same vendors and seat count as A4, no skills |
| A3 | fixed recipe: an existing preset (for example `risk-review`) |
| A4 | the skill council under test: **one pre-specified skill set per task category, chosen on the development split and written down before the validation run**; no other A4 may be reported |
| M0..M3 | H3 route arms: explicit user route, always-debate, always-single, auto (recommendation accepted by the deterministic pre-router) |

Model versions, adapters, router and skill definition hashes are recorded per run. If a pinned model is deprecated during a run, every arm of the affected tasks is re-run on the replacement and reported separately; arms are never mixed across model versions.
Skill `memory_policy` is off, threads and Brain recall are off, so nothing carries content between runs. A vendor-diversity comparison (four vendors vs one) is a separate study.

## 3. Tasks and split

Six categories, 90 tasks in total. Categories with ground-truth issues, 20 tasks each: (1) planted-error review, (2) spec/architecture review with expert-labelled issues, (3) high-risk decision with known failure modes. Control categories, 10 tasks each:
(4) trivial lookup (direct answer expected), (5) missing-evidence task (ask or research expected), (6) deterministic-validation task (no model expected). Issue recall is only defined for categories 1 to 3, so H1 and H2 use those 60 tasks; categories 4 to 6 serve H3 and as no-harm controls.

Ground truth is written by a human and reviewed by a second person, not taken from a public benchmark, no private customer data (spec 13.2). Tasks written with model help are marked (leakage risk: a model grading its own family's tasks).
For H3, the **acceptable-route set** of every task (all six categories, not only the obvious ones) is written by someone other than the task's author, before any run.

**Split, fixed in advance and stratified.** Task ids are random (assigned before authoring, so authors cannot choose them). A secret salt is generated once; its sha256 is committed with this freeze and the salt is revealed when the holdout is run. Within each category, tasks are ordered by `sha256(salt || task_id)` (UTF-8 bytes, lowercase hex);
for the 20-task categories the first 8 are development, the next 4 validation, the last 8 holdout; for the 10-task categories 4, 2, 4. That gives exactly 36 development, 18 validation and 36 holdout tasks, of which 24 holdout tasks have ground-truth issues (H1, H2).
The holdout ids and a hash of their contents are committed before any run on them; contents stay private. A task found flawed **before** the first validation run is replaced by the next id in the same stratum and logged; after the first validation run starts, the task set is locked.
Each arm runs on the holdout **once**, after the method and the analysis script are final, with no tuning on its results.

## 4. Protocol and metrics

3 repeats per task per arm, randomised order, fixed seeds where the provider allows, one retry only for infrastructure failure, reported. Repeats are averaged to one number per task before any test.
**Verified-issue recall** of a task = ground-truth issues named by at least one seat divided by ground-truth issues. Because a union rewards volume, volume is controlled: every seat has the same output token cap in every arm and A1 is cost-matched. **False-claim share** = claims graded not real divided by all graded claims, in percentage points; it is reported for every arm and enters the thresholds below.
Two graders grade blind to arm; inter-rater agreement (Cohen's kappa) must reach at least 0.6 on the validation split or the rubric is revised **before** the holdout runs. A model may assist grading only if it is from a different vendor family than the model graded, and is never the sole grader. The grader pool (who the two graders are) is open and is an input to approval.
Exclusions are limited to the flawed-task replacement above and outage re-runs; no exclusion may depend on an outcome.
**Analysis (frozen as a script at the freeze commit):** paired difference per task; two-sided paired sign-flip permutation test for the p-value; 95% interval by BCa bootstrap over tasks (10,000 resamples; a percentile bootstrap undercovers at this size). Cost ratio = mean credits of the arm over the comparison arm, point estimate with its bootstrap interval reported.

## 5. Decision thresholds (proposed)

**H1/H2 `supported`** only if all hold: paired recall difference of at least **+5.0 points**; lower bound of the 95% interval above **0**; permutation p below 0.05 (H2 after Holm); cost-ratio point estimate at most **1.25**; false-claim share not more than **5 points** above the comparison arm.
**`unsupported`** only if the point estimate is at or below **0** or the upper bound is below **+3.0 points**; with intervals this wide that happens only for null or negative results.
**`inconclusive`** otherwise, and reported as inconclusive. There is no veto from a category.
**H3 `supported`:** the auto route is in the acceptable set for at least **10 points** more tasks than M1, and credits are at most **0.8x** M1's, with recall not more than **3 points** below M1's on categories 1 to 3.
**H4 `supported`:** at least 40 graded observations, precision at least **0.80** with the lower bound of its 95% interval (Wilson) at least **0.60**, and **zero** violations of the hedging rule (every single-event pattern is labelled `hypothesis`, low sample size, with an expiry); one violation fails H4.

**Power, stated honestly.** H1 has 24 holdout tasks. With a per-task standard deviation of 15 the standard error is 3.1 and the interval half-width about 6.3. At 80% power the minimum detectable lift is about **+8.6 points** (2.8 x SE); a true +6 lift would reach "supported" about half the time. The standard deviation itself is uncertain (plausibly 10 to 25, giving a minimum detectable lift of about 6 to 14).
Smaller real effects will be reported as inconclusive. A larger holdout is an owner decision about cost, not something changed after results.

Cost estimate for planning: 90 tasks x 5 arms x 3 repeats = 1,350 debates; at about 4,500 tokens each, about 6.1M tokens plus grading; ceiling proposed at **9M tokens** on the metered API key, spend approved by the owner before Phase 6 starts.

## 6. Claim language (frozen)

Allowed: "In a pre-registered study of 90 tasks (36 held out; 24 with ground-truth issues), <arm> found <X> points more verified issues than <arm> (95% interval <a> to <b>), at <Y>x the cost. Perspectives, not a guarantee."
Allowed for any status: "Not yet measured" and "inconclusive in <N> tasks".
Not allowed: "best", "accurate", "verified" or "proven" without the definition and sample basis beside it; "improves quality" without an interval; any claim from development or validation data; any claim that treats likes, saves, acceptance, consensus or silence as correctness; calling a one-vendor-family council multi-model.
UI and docs follow `docs/experts.md`: skills are perspectives until a result above says otherwise.

## 7. Risks and open inputs

Leakage: holdout text is sent to vendor APIs whose retention and training terms must be checked and recorded before the run; model-assisted tasks are marked. Pinned models can deprecate mid-study (section 2).
Immutability of this freeze rests on the signed tag in the header, not on this file's history alone.
**Open for the approver:** the +5.0 point and 1.25x thresholds, the 90-task size and the 36/18/36 split, the 9M-token ceiling, who the two graders are, and the H3 and H4 thresholds.
Not produced in Phase 1: the tasks, the acceptable-route labels, the salt, the grader pool and the analysis script (Phase 6).
