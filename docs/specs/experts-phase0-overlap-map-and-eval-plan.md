# Experts and Auto Councils, Phase 0: overlap map and evaluation plan

**Status:** draft 1, 2026-11-01. Docs only: no runtime change, no flag, no deploy, and **no model was called** to write this (no debates, no credits).
**Parent:** [`experts-auto-councils-marketplace-developer-talent.md`](experts-auto-councils-marketplace-developer-talent.md) (merged in #50), section 4 "Phase 0".
**Evidence tags:** **[E]** read in a file today (path given). **[G]** guess, not tested. **[N]** not verified.

Phase 0 asks three things before any code: what already exists, what each proposed feature should reuse or change, and how we will know the council helps. This page answers them and lists the decisions the owner has to make.

## 1. What already exists, and what it means for Phase 1 and 2

| Proposed in #50 | What exists today | Consequence |
| --- | --- | --- |
| A seat in a council | A seat is only a **provider adapter**. `bin/e3d-debate --providers a,b` and `lib/mcp/voices.js` (`chooseVoices`, `CLI_ORDER`) pick adapters; every participant gets the **same prompt** [E] | An "expert" adds what a seat lacks: a lens, instructions, tools and a version. It is a wrapper around a seat, not a new kind of participant |
| Expert definitions (12 lenses, YAML, presets, precedence) | Already designed in detail in `docs/prompt-review-2026-10.md` Part 3: starter roster of 12, file format, load order (built-in < user < repo), presets `risk-review` and others, `--panel` / `--specialist` flags [E]. Nothing is built | Phase 1 is mostly **implementing that design**, not inventing one. Do not write a second schema without reconciling it (section 2, D2) |
| Which vendors may take part | **Per-account panel** (cloud `docs/panel-config-spec.md`; engine `lib/mcp/panel.js`): an allowlist, the account's chosen vendors, degrade-or-refuse, "never add a vendor the account did not choose" [E] | Experts and Auto Council must work **inside** the account's panel. An expert may narrow a vendor choice, never widen it (D4) |
| Dissent attributed to an expert | Today `dissent` is `{present, summary}` and `positions` is per provider [E: prompt-review 3.5] | Receipts need `specialist_id`, `specialist_version`, provider, model and final action per seat. Additive fields only |
| Decision log and computed agreement | `lib/debate/agreement/` (#20) [E] | The base for `SeatContribution` and for the measurement in Phase 3 |
| Gallery, reactions, handles, forks, challenges, publisher-paid score | Cloud (private repo) [E: earlier sessions]; the public read tool `e3d_gallery` is in the engine since #49 | Public experts and recipes reuse these in Phase 4. The new MCP tool names should follow `e3d_*` and must not collide with `e3d_gallery` |
| `expert_ids`, `council_id`, `panel:"auto"` on `e3d_debate` | Hosted calls go through **billing's agent quote and begin routes**. Those routes do not accept `challenge_of` today, and the same gap would block any new `e3d_debate` parameter [E: gallery work, 2026-10-31] | **Phase 2 over hosted MCP needs a billing-side change** (the open "A or B" decision). Phase 1 (CLI and local engine) does not |
| Price of a panel | The panel spec has its own pricing section (docs/panel-config-spec.md section 5) [E, headings only] | More or different seats change the quote. Phase 2 must define how an expert panel is priced before it can spend |

## 2. Decisions to approve (my recommendation first)

- **D1. Expert, seat and panel.** A *seat* is a provider adapter (as today). An *expert* is a versioned lens plus instructions, tools and model preferences. A *panel* is a list of seats; a *council recipe* is a panel whose seats name experts. Recommendation: adopt these four words exactly and use them in code and docs.
- **D2. One schema.** `expert/v1` in #50 is a superset of the October file format. Keep the October fields (`models`, `tools`, `limits`, `tasks`) and add `owner_id`, `visibility`, `required_evidence`, `tests`, `license`, `provenance`, `content_hash`. **Drop `performance` from the definition**: measured results live only in the append-only `EvaluationRecord`, never hand-edited.
- **D3. Where experts live.** Phase 1: files, in the engine (`lib/specialists/*.yaml`, user and repo overrides as the October design says). No cloud registry before Phase 4.
- **D4. The vendor invariant.** An expert's `models` list is resolved against the account's panel: unavailable or not-allowed vendors are dropped in order, and if none is left the run **refuses** (never substitutes), as `lib/mcp/panel.js` already does for panels. Recorded in the receipt.
- **D5. MCP pass-through.** Settle A or B before Phase 2. A: experts are CLI and local-engine only, and hosted assistants hand the user a link. B: extend billing's agent routes once, for `challenge_of` and the expert parameters together. Recommendation: B, but only when Phase 2 starts, so the change is made once.

## 3. What the October experiment tells us about measuring

`docs/experiments/2026-10-17-debate-prompt-pilot/RESULTS.md` [E]:

- 9 debates (3 questions, 3 prompt variants, one run each), 3 voices, 2 rounds: **45 metered calls, 331,766 input and 65,506 output tokens**, about 44 thousand tokens a debate. grok-build's CLI spend was not measured. I did not look up prices, so there is **no dollar figure here**.
- **Run-to-run noise is large and was not measured.** The same question under three prompt variants gave three different verdicts, and one run per cell cannot separate a prompt effect from chance.
- **Planted errors were too easy**: all three were caught in every variant. A test that every arm passes cannot show lift.

So a Phase 3 that runs each task once per arm cannot support "the council helps". The plan below repeats runs and adds a control.

## 4. Evaluation plan (to pre-register before any result is seen)

**Arms, per task**
- A: the strongest single model, with the same tools and evidence.
- B: today's default panel (same prompt for every seat).
- C: a random eligible expert preset.
- D: the advisory Auto Council.
- E (control): the **same** single model sampled three times and merged. This separates "more voices" from "different vendors and lenses".

**Tasks.** 40 to 50, in bands: spec review, diff review, architecture decision, risk review, claim checking with subtle planted errors, forecasts that will resolve. Prefer our own real artifacts with later-known outcomes (specs that were revised, changes that were reverted) so ground truth exists. Keep private repos out of any public fixture.

**Grading.** Rubric written first. Blind to arm. Two graders: the owner plus a model from a family not used in the arms. Primary measure: **verified unique findings** per task (a person checks each against the source) and **false positives**. Freeze the router before the 20% holdout is opened.

**Repeats.** At least 3 per task per arm, to measure noise.

**Cost, in tokens only.** Using the pilot's ~44 thousand tokens a debate for the multi-seat arms (B, C, D): 45 tasks x 3 arms x 3 repeats is about 405 debates, roughly **18 million tokens**, plus the cheaper A and E arms and grading. The owner approves a cap before any run.

**Stage 0 (cheap, first):** 12 tasks x 3 repeats on arms A and B only. Output: the noise (standard deviation of the per-task difference), which tasks separate the arms, and a real token cost. Decide the full run from this, not from a guess.

**Proposed thresholds (owner to approve; #50's "15% lift, under 3x cost" is a hypothesis, not yet a bar)**
- **Ship:** mean paired lift in verified unique findings over arm A is at least +15%, the 95% bootstrap interval excludes 0, cost per task is at most 3x arm A, and false positives are not worse by more than 10% relative.
- **Inconclusive:** anything else with the interval including 0. Say so; stay in shadow mode; no accuracy claim.
- **Stop or narrow:** point estimate below +5% at 2x cost or more, or arm E matches arm D (the lift is just more samples).
- If 45 tasks cannot exclude 0 at the Stage 0 noise level, we add tasks or declare it inconclusive. We do **not** loosen the bar afterwards.

## 5. Phase 1, narrowed

Engine only, flag off by default: the 12 October lenses as files, the validator, load order and receipt fields (D2, D3, D4), `--panel` and `--specialist` on the CLI, and an additive receipt. **Out:** cloud, billing, hosted MCP parameters, publishing, reactions, any marketplace surface. Existing `e3d_debate` and `e3d-debate` behavior unchanged when no expert is named.

## 6. For the owner

1. Approve D1 to D5 (or change them).
2. A or B for MCP pass-through (D5), and whether to settle it now or at Phase 2.
3. Whether Phase 1 starts now (engine-only, cheap) or waits for the 5-debate Challenge test to show whether strangers participate. My view: Phase 1 can start now because it needs no cloud change and no public surface; **Phase 4 should wait** for the test.
4. A token cap for Stage 0, and your time to grade.

## 7. Not verified

I have not opened the cloud PRs #272, #279, #280, #283, #284, #286, #290 and #291 that #50 cites, so I do not vouch for their descriptions. I read only the headings of the panel spec's pricing and audit-field sections. Nothing here was measured; the token figures are from the October results file.
