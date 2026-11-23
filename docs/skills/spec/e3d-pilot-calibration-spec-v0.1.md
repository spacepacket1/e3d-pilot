# E3D Pilot Calibration — Specification (part 3 of 3)

**Version:** 0.1
**Date:** 2026-11-23
**Scope:** `spacepacket1/e3d-pilot` (public): contracts, local capture, local and stdio-MCP surfaces, evaluation of calibration claims. Hosted storage, remote MCP and aggregation are an adapter in the private repository, specified when this document is approved.
**Builds on:** the engine skills specification (`e3d-pilot-user-defined-skills-spec-v0.1.md`, contracts v1) and its ADRs. Where this document says "skill", "receipt", "hash" or "contract", it means those definitions.
**Status:** Proposal. The facts in section 1 were checked in the four repositories on 2026-11-23; everything else is a proposal. New decisions are in ADR-0015 (Proposed) and the questions listed in section 12.

> **Governing principle:** Skills are the unit. Outcomes are the evidence. Calibration is an honest track record of what happened when a skill was used, shown with its sample size and uncertainty, and offered to the places people already work: their own agent chats, through MCP.

## 0. Executive decision

Calibration is the outcome-scored track record of **versioned skills** (later also models, seats and councils), keyed to the immutable identity `(skill id, version, definition_hash)` and to the kind of task. It answers "when this exact skill was used on this kind of task, what happened?", not "is this skill good".

Three decisions shape everything:

1. **Skills first, then calibration.** An outcome can be attributed only to something that stays fixed. The skills specification supplies that unit (pinned versions, hashes, receipts). Calibration adds no new identity; it adds outcome-linked evidence on top of the one skills already have.
2. **Host mode is the primary surface.** Most skill use happens in the user's own agent chat (Claude Code, Codex and similar), where Pilot does not run the model. Pilot therefore serves skills as data over MCP, issues a server-side `use_id` when a skill is fetched, and accepts a later outcome report against it. Debates, chats and decision records inside Pilot are further sources of the same records, not the only ones.
3. **Evidence is advisory and graded.** Every outcome carries a source tier. Host-reported and user-marked outcomes are never presented as verified. Nothing here changes a default route, a council or a skill automatically.

This keeps the skills spec's invariants (receipts pin versions; learning proposes; likes, saves, acceptance, consensus and silence are not correctness) and adds the ones in section 2.

## 1. Evidence base: what exists and what does not (checked 2026-11-23)

| Area | What exists | What does not |
| --- | --- | --- |
| Engine receipt | `decision-log.json` with consensus, dissent and a `panel` block (name, version, hash, tier); the debate recap tags each model's move as `held`, `partly_moved` or `moved` with a `new_evidence` flag (`lib/debate/recap.mjs`) | a `use_id`; any outcome field |
| Engine outcomes | `ideas outcome` metrics, `negotiate_dissent` and `gate_fired` findings, `ideas list --pending-outcome` (added 2026-09-16 after `ideas outcome` had never been used) | evidence of use at scale; any link from an outcome to a skill |
| Case mode | questions and answers carried between runs, framed as untrusted data (`lib/debate/case.mjs`) | a recorded real-world result |
| Jev council | an opt-in signal with provisional bands that the doc says "must be recalibrated on outcomes" and may not vote until "a calibrated, outcome-checked signal" exists | the outcomes to calibrate it |
| Hosted decisions | a decision record with `outcome: worked | failed | unknown` plus a private note and timestamps; 365-day retention; a no-prompt rule (outcome marking is never nudged); instrumentation with kill criteria ("drop outcome work if under 15-20% of decided records get an outcome") | the resolved-outcome count in production (unknown to this audit; counting it needs the owner's approval to query production); any link to skills |
| Hosted Gallery | reactions (like, save), reports, appeals, forks, assessments per debate | any rule that makes these evidence (and the skills spec forbids it) |
| MCP today | `e3d_list_experts`, `e3d_get_expert` (flagged), `e3d_debate`, `e3d_chat`, `e3d_usage`, `e3d_gallery`, `e3d_provenance_trace`, `e3d_ideas_list` and others | any skill tool, any outcome tool; OAuth has one scope, `debates:run` |
| Measurement | a planted-error study on expert lenses: +2.8 points, 95% interval -4.6 to +10.2, inconclusive (12 tasks) | calibration of any kind; a probability forecast in any receipt |

Prior decisions this specification must respect: the 2026-11-17 council verdict named Calibration the next layer (majority; recorded dissent: governance first, or too few resolved outcomes to score); the vision document puts "verified outcome measurement" before any curated public catalogue; `docs/methodology/expert-councils.md` makes no quality claim until its measurement matrix has numbers.

**The unchecked risk is the resolved-outcome count.** Phase 1 of this document records it, with the owner's approval for any production query, and states the data gates in section 9.

## 2. Goals, non-goals and invariants

### 2.1 Goals

1. Let a user, and the agent working for them, read a skill's track record for a kind of task, with sample size and uncertainty.
2. Capture skill use and outcomes wherever skills run: the user's own agent chat over MCP, Pilot chat, debates, decision records.
3. Keep every record attached to an immutable skill version and a task class, so a new version starts a new record.
4. Feed advisory, explainable recommendations (which skill, which seats) once evidence supports it.
5. Give Jev and any later signal an outcome-checked calibration target.

### 2.2 Non-goals

- Scoring people. Records are about skills, models, seats and councils, never about a user, a teammate or an employee. No leaderboard, no per-person ranking.
- Causal claims from observational data. A track record is an association, labelled so.
- Prompting users for outcomes by default (the hosted decision-record rule stands; see section 5.4).
- Automatic changes to defaults, routing, councils or skill text.
- A public marketplace ranking. Public track records are a later, gated phase.

### 2.3 Invariants (in addition to the skills spec's)

1. **Graded sources.** Every outcome has a tier: `verified` (a downstream result Pilot can check against an artifact digest, such as a test or measured metric), `user_marked`, `host_reported`, or `inferred`. `inferred` is stored but never counted as resolved.
2. **Not evidence.** Likes, saves, forks, views, acceptance of an answer, model consensus and silence never create an outcome.
3. **Immutable key.** A record is keyed to `(skill id, version, definition_hash)` plus a stratum. A new version never inherits a record.
4. **Show the uncertainty.** A rate is shown only with its count and interval. Below the minimum (section 9) the answer is "not enough resolved outcomes".
5. **Private by default.** Records belong to the user who produced them. Aggregation across users needs explicit, revocable opt-in and a minimum group size.
6. **Correct by appending.** A corrected outcome supersedes the earlier one and keeps it; deletion by the user removes its contribution and recomputes.
7. **Advisory only.** Using calibration to change a default needs a prospective shadow evaluation, human approval and an instant rollback, as in the skills spec.
8. **No raw content.** Records hold identifiers, enums, counts and timestamps. Questions, answers, notes and skill text are not copied into calibration records.

## 3. Contracts (calibration contracts v1)

These extend the skills contracts. The Phase 1 deliverable commits their JSON Schemas and fixtures; the examples here are the intended shape.

### 3.1 `SkillUse`

Created by Pilot (never by the client) when a skill is fetched for use, or by the engine when it runs one.

```json
{
  "schema_version": "e3d.skill-use/v1",
  "use_id": "use_01...",
  "skill": {"id": "skill.e3d.skeptic", "version": "2.0.0", "definition_hash": "sha256:..."},
  "mode": "host_chat",
  "host": {"family": "claude-code", "model_family": "anthropic"},
  "task_class": "architecture-review",
  "task_class_source": "declared",
  "principal_ref": "pseudonymous-or-private-id",
  "run_ref": null,
  "issued_at": "2026-11-23T00:00:00Z",
  "expires_at": "2026-12-23T00:00:00Z"
}
```

`mode` is `host_chat`, `pilot_chat`, `debate_seat` or `observer`. `run_ref` links an engine receipt when Pilot ran it. `task_class_source` is `declared` (the host or user said), `derived` (a deterministic rule) or `none`. A use expires; an outcome after expiry is refused with `skill_use_expired`.

### 3.2 `Prediction` (optional)

A stated expectation made before the result is known, needed for calibration in the strict sense (stated confidence against realised rate).

```json
{
  "schema_version": "e3d.prediction/v1",
  "prediction_id": "prd_01...",
  "use_id": "use_01...",
  "claim": {"type": "recommendation_will_work", "horizon_days": 30},
  "confidence": 0.7,
  "source": "council_verdict_band",
  "stated_at": "2026-11-23T00:00:00Z"
}
```

Pilot does not invent a probability from a consensus level (`full`, `majority`, `split`, `unknown`). A mapping from consensus to confidence is itself calibrated later and is not assumed. Until a prediction exists, the record reports success rates only and says so.

### 3.3 `Outcome`

```json
{
  "schema_version": "e3d.outcome/v1",
  "outcome_id": "out_01...",
  "use_id": "use_01...",
  "result": "worked",
  "tier": "user_marked",
  "reported_by": "host",
  "evidence_ref": null,
  "supersedes": null,
  "reported_at": "2026-11-30T00:00:00Z"
}
```

`result` is `worked`, `failed` or `unknown` (the words the hosted decision record already uses). `evidence_ref` is a digest of an artifact for `verified` outcomes. `supersedes` links a correction. Free-text notes are not part of the record; a private note stays in the decision record or the user's own notes.

### 3.4 `TrackRecord` (derived, never stored as truth)

```json
{
  "schema_version": "e3d.track-record/v1",
  "subject": {"id": "skill.e3d.skeptic", "version": "2.0.0", "definition_hash": "sha256:..."},
  "stratum": {"task_class": "architecture-review", "mode": "host_chat", "model_family": "anthropic"},
  "scope": "principal",
  "n_uses": 41,
  "n_resolved": 17,
  "resolution_rate": 0.41,
  "by_tier": {"verified": 2, "user_marked": 11, "host_reported": 4},
  "success": {"count": 12, "rate": 0.71, "interval95": [0.47, 0.87], "method": "wilson"},
  "baseline": {"n_resolved": 9, "success_rate": 0.56, "basis": "same principal, same task class, uses without this skill", "label": "observational"},
  "calibration": null,
  "status": "descriptive",
  "computed_at": "2026-12-01T00:00:00Z"
}
```

`status` is `insufficient_evidence` below the minimum, `descriptive` above it, and `calibrated` only when predictions exist and the reliability bins meet the minimum. The `baseline` is shown only when the same principal has resolved uses without the skill on the same task class; it is always labelled observational. `calibration` (when present) holds reliability bins and a proper scoring rule (Brier), never a single "accuracy" number.

### 3.5 Errors

New lower-case codes in the skills registry of codes: `skill_use_not_found`, `skill_use_expired`, `skill_outcome_invalid`, `skill_outcome_conflict`, `skill_record_insufficient`, `skill_scope_denied`. Codes are never renamed or reused.

## 4. Attribution and statistics

- **Unit and stratum.** A record is per skill version and per stratum (task class, mode, model family and version, and whether tools or evidence were available). A change of model version starts a new stratum; older strata decay in weight and are shown separately.
- **Resolution rate is reported beside the success rate.** Most uses will have no outcome. Reporting a success rate without the share resolved would hide selection bias, since people may report mostly extreme results.
- **Intervals.** Wilson 95% intervals for rates. Partial pooling toward a stratum prior is allowed later and is disclosed.
- **Baseline.** Only the same principal's uses count, to avoid comparing different people. This is observational. A controlled comparison (the user alternates skill and no skill on matching tasks) is an opt-in experiment, reported as such.
- **No credit-splitting.** When several skills were active in one use, each gets the use and the record notes the co-active set; no model apportions credit between them.
- **Right-censoring.** Uses younger than the outcome horizon are `unresolved`, not failures; rates use only uses past their horizon.
- **Strict calibration** needs predictions with stated confidence. Reliability bins are shown only when each bin meets the minimum count; otherwise only the descriptive record is shown.

## 5. Surfaces

### 5.1 MCP tools (stdio engine first; hosted remote later)

| Tool | Reads or writes | Spend | Notes |
| --- | --- | --- | --- |
| `e3d_skill_record` | reads a `TrackRecord` for a skill version and task class | none | returns `insufficient_evidence` when under the minimum |
| `e3d_skill_report_use` | writes nothing the client chooses: it records that a fetched skill was used, against the server-issued `use_id` | none | idempotent |
| `e3d_skill_report_outcome` | writes an `Outcome` for a `use_id` | none | needs the user's confirmation or a policy that allows host-reported outcomes; idempotent; rate-limited |
| `e3d_my_calibration` | reads the principal's own records, grouped by skill | none | never other users' records |

Tool names avoid the Brain MCP's existing `report_use`. Skill delivery to the host (list, get, export of the skill content) is ADR-0015. The hosted remote server adds OAuth scopes beyond today's single `debates:run` (proposed: `skills:read`, `skills:write`, `outcomes:write`), decided in the hosted adapter.

### 5.2 CLI

`e3d-debate --skill-record <skill>`, `--report-outcome <use_id> --result worked|failed|unknown`, `--my-calibration`; local only, flagged, no network.

### 5.3 Hosted API and UI (adapter)

A skill's detail page shows its track record next to its definition; the decision record's existing `outcome` becomes one source and gains an optional link to the skill uses behind it. Exact routes and screens are the hosted adapter's.

### 5.4 Asking for outcomes

The hosted decision-record spec forbids prompting for outcomes so that the outcome rate stays an honest signal. Calibration needs outcomes. Default stays **no prompting**. An opt-in setting ("remind me to record how this went") is proposed in section 12 and, if approved, applies only to users who turn it on; the resolution rate is always reported so the effect is visible.

## 6. Trust, privacy and retention

- **Host-reported data is self-asserted.** The server-issued `use_id` stops reports against skills that were never fetched, but it cannot prove the host used the skill or that the result is true. That is why the tier is displayed.
- **Data class.** Records are identifiers, enums, counts and timestamps. They are private to the principal. Retention follows the owner-approved numbers (proposed: the same 365-day default as decision records, `use_id` expiry 30 days); deleting a decision, a skill or an account removes the linked records and recomputes derived records.
- **Aggregation.** Cross-user views (a skill's pooled record, a public catalogue) need explicit opt-in per user, a minimum group size, no exposure of strata small enough to identify a person, and a documented opt-out. Aggregates are never fed back as another user's private record.
- **Export, correction and deletion** are available to the user for every record about their uses.

## 7. Uses of calibration (levels, each gated)

| Level | Use | Gate |
| --- | --- | --- |
| L0 | descriptive track record shown with count and interval | data gate (section 9) |
| L1 | explainable recommendation ("skills you used on this kind of task, with their records") | L0 stable; recommendation shown with its evidence and an override |
| L2 | suggested seats or council composition | shadow study (below) |
| L3 | any influence on a default route, council or skill | prospective shadow evaluation, human approval, instant rollback flag |

Jev (`docs/jev-council.md`) is a consumer: its thresholds are recalibrated against `verified` and `user_marked` outcomes before it may influence anything. Authors receive their own skill's record and, through the skills spec's `LearningProposal`, evidence-linked suggestions; nothing edits a published skill.

## 8. Threats specific to calibration

| # | Threat | Control |
| --- | --- | --- |
| C-T1 | Outcome poisoning and fake reports (sybil accounts boosting a skill) | records are per principal; aggregation needs opt-in plus minimum group size and source diversity; reactions and counts never feed records; rate limits; anomaly flags |
| C-T2 | Selection bias (people report only extremes) | always show resolution rate; tier mix; `insufficient_evidence` |
| C-T3 | Goodhart (authors tune a skill to look good) | records keyed to immutable versions; a new version starts empty; evaluation, not reports, backs any claim |
| C-T4 | Re-identification from small strata | minimum group size; coarse task classes; no free text |
| C-T5 | Served skill as a prompt-injection vector into the user's agent (see ADR-0015) | skills are served as labelled data, instructional only, hash and source shown, never auto-installed, scanner on import and publish, host owns the tool permissions |
| C-T6 | Feedback loops (recommendations change which skills get used, which changes the records) | recommendations show their evidence; shadow study before any default; hold-out of random non-recommended uses in the shadow study |
| C-T7 | Model drift makes old records misleading | stratum includes model version; decay; separate display |
| C-T8 | Right-censoring and regression to the mean read as skill effects | horizon rule; intervals; baseline labelled observational |
| C-T9 | Memory or notes leaking into records | records hold no free text; the decision-record note stays private |

## 9. Evaluation and data gates

Claims follow `docs/skills/phase1/evaluation-freeze.md`: no "improves", "best", "accurate" or "verified" without the definition and sample basis. Allowed language: "In your 17 resolved uses of this skill on architecture reviews, 12 were marked worked (95% interval 47% to 87%); 41% of uses had a recorded outcome." The track record is a description of what was recorded, not a claim about the skill.

**Data gates (proposed numbers; the owner decides them in Phase 1):**

- Show a per-skill record only at 10 or more resolved uses in a stratum.
- Show reliability bins only at 30 or more resolved predictions per bin.
- Do not start phase 6 (recommendations) before 200 resolved outcomes across at least 20 principals, with at least 3 skills each having 30 or more.
- Stop expanding capture work if, 60 days after phase 3, fewer than 15% of reported uses have an outcome (the same kill criterion the decision-record spec uses).

## 10. Compatibility

- The no-skill and legacy expert paths are unchanged. The receipt gains `use_id` only when the skill path is used.
- No existing MCP tool is renamed or changed. New tools are additive and flagged off.
- Decision records keep their schema; the optional link to skill uses is additive.

## 11. Detailed implementation phases

Each phase is independently reviewable and ends in one or more PRs, one repository per PR, merged in dependency order. Rules, review and approval protocol are those of the skills spec section 17. Nothing is deployed, no production flag is enabled and no billing changes without explicit approval. The runner notes of the skills spec apply: no heading other than a phase heading may contain the word "Phase" followed by a number. Phase numbers in this file are this file's own; references to the skills specification's phases are written "skills phase N" in body text.

## Phase 1 - Grounding, data gates, ADRs and contracts

<!-- runner:model=high -->
<!-- runner:read=docs/skills/README.md -->
<!-- runner:read=docs/skills/spec/e3d-pilot-calibration-spec-v0.1.md -->
<!-- runner:read=docs/skills/phase1/adr/0015-mcp-first-skills.md -->
<!-- runner:verify=bash tests/skills-schemas.sh -->

**Dependencies:** skills phase 1 approved. **Runtime change:** none.

### Work

1. Measure the resolved-outcome count: local ledger (`ideas list --pending-outcome`), and for production a single aggregate count query only with the owner's explicit approval; record the numbers and the date.
2. Decide the owner questions in section 12 and record them as ADRs.
3. Commit JSON Schemas and valid/invalid fixtures for `SkillUse`, `Prediction`, `Outcome`, `TrackRecord`, and the new error codes, validated by the existing harness.
4. Extend the threat model with C-T1 to C-T9 and the privacy inventory with the calibration data classes.
5. Write the calibration claim language and the evaluation protocol for the data gates.
6. Reconcile with the decision-record rules (no prompting, banned copy words) and record any conflict.

### Acceptance criteria

- Every claim in section 1 is labelled with evidence; the resolved-outcome count is recorded or explicitly unknown.
- Schemas validate their valid fixtures and reject their invalid ones with stable codes.
- The owner has approved or changed each proposed number.

### Exit gate

Architecture, security/privacy and evaluation reviewers approve; no runtime work starts before.

## Phase 2 - Local capture

<!-- runner:model=high -->
<!-- runner:read=docs/skills/README.md -->
<!-- runner:read=docs/skills/spec/e3d-pilot-calibration-spec-v0.1.md -->
<!-- runner:verify=bash tests/skills-schemas.sh -->
<!-- runner:verify=bash tests/skills-compat.sh -->
<!-- runner:verify=bash tests/debate-specialists.sh -->

**Dependencies:** skills phase 2 merged; calibration phase 1 approved. **Flag:** `E3D_CALIBRATION_V1`, off by default (strict unset/0/1).

### Work

1. Add `use_id` to the receipt, only on the skill path.
2. Local store for outcomes (a file in the state directory), append-only with supersession, no free text.
3. CLI verbs from section 5.2.
4. Local `TrackRecord` computation with the intervals and the minimum rule.

### Acceptance criteria

- With the flag off, receipts and outputs are byte-identical to today (goldens unchanged).
- A recorded outcome changes the derived record and nothing else; deletion recomputes.
- No network or model call.

### Exit gate

Compatibility sign-off; flag stays off in release defaults.

## Phase 3 - Skills in the user's own agent, over MCP (stdio)

<!-- runner:model=high -->
<!-- runner:read=docs/skills/README.md -->
<!-- runner:read=docs/skills/spec/e3d-pilot-calibration-spec-v0.1.md -->
<!-- runner:read=docs/skills/phase1/adr/0015-mcp-first-skills.md -->
<!-- runner:read=docs/skills/phase1/threat-model.md -->
<!-- runner:verify=bash tests/skills-schemas.sh -->
<!-- runner:verify=bash tests/skills-compat.sh -->

**Dependencies:** skills phase 2 and calibration phase 2 merged; ADR-0015 approved. **Flags:** `E3D_MCP_SKILLS=1` and `E3D_CALIBRATION_V1=1`, each off by default.

### Work

1. Add the MCP tools of section 5.1 and the skill read/export tools of ADR-0015 to the stdio server, behind the flags; the tool-name baseline test is updated deliberately, and still shows no skill tool with the flags unset.
2. Serve skill content as labelled data with id, version and hash; issue server-side `use_id`; accept reports against it.
3. Adversarial tests: a served skill that tries to instruct the host to widen its own tools or exfiltrate; reports for unknown, expired or foreign `use_id`; replay; rate limits.
4. Documentation for connecting Claude Code and Codex, with the trust rules in plain language.

### Acceptance criteria

- A skill fetched over MCP carries its hash, source and an explicit "data, not instructions from Pilot" label; nothing is installed or run by Pilot.
- Outcome reports are idempotent and bound to the issuing principal.
- No existing tool, schema or receipt changes with the flags off.

### Exit gate

Independent security review of the served-skill threat (C-T5); internal use only.

## Phase 4 - Hosted capture and remote MCP

<!-- runner:model=high -->
<!-- runner:read=docs/skills/README.md -->
<!-- runner:read=docs/skills/spec/e3d-pilot-calibration-spec-v0.1.md -->
<!-- runner:verify=bash tests/skills-schemas.sh -->

**Dependencies:** calibration phase 3; skills phase 7 (hosted registry). **PRs:** the engine adapter here; the hosted adapter in the private repository, merged after it.

### Work

1. Engine side of the hosted contract: the fields and codes the hosted service needs, no hosted code.
2. Hosted adapter (separate PR, private repository): collections, remote MCP tools, OAuth scopes, link from a decision record's outcome to skill uses, deletion and retention steps.
3. Consent and settings for the optional outcome reminder, if approved.

### Acceptance criteria

- Cross-account negative tests; deletion removes records and recomputes; scopes are least-privilege.
- Existing hosted debate, chat and decision flows unchanged with the flags off.

### Exit gate

Hosted security and privacy review; canary accounts only.

## Phase 5 - Track records on read surfaces

<!-- runner:model=high -->
<!-- runner:read=docs/skills/README.md -->
<!-- runner:read=docs/skills/spec/e3d-pilot-calibration-spec-v0.1.md -->
<!-- runner:verify=bash tests/skills-schemas.sh -->

**Dependencies:** phases 2 to 4 and the data gate for L0.

### Work

1. Show the descriptive record on the skill detail view and in `e3d_skill_record`, with count, interval, tier mix, resolution rate and the labelled baseline.
2. Copy review against the banned-word rules and the claim language.

### Acceptance criteria

- Below the minimum, the surface says "not enough resolved outcomes" and shows no rate.
- Every number on a surface is reproducible from the records by a documented command.

### Exit gate

Product and evaluation review.

## Phase 6 - Advisory recommendations and shadow study

<!-- runner:model=high -->
<!-- runner:read=docs/skills/README.md -->
<!-- runner:read=docs/skills/spec/e3d-pilot-calibration-spec-v0.1.md -->
<!-- runner:read=docs/skills/phase1/evaluation-freeze.md -->
<!-- runner:verify=bash tests/skills-schemas.sh -->

**Dependencies:** phase 5 and the phase 6 data gate (section 9).

### Work

1. Explainable recommendation (L1) from the principal's own records, always showing the evidence and an override.
2. Prospective shadow study of L2 suggestions with a randomised hold-out; pre-registered like the skills evaluation.
3. Recalibrate the Jev bands against recorded outcomes; no voting role.

### Acceptance criteria

- Recommendations never change a default; every one records the recommendation and what the user did.
- The study report includes negative and inconclusive results.

### Exit gate

Human review; any L3 influence needs a separate approval and an instant rollback flag.

## Phase 7 - Opt-in aggregation and public track records

<!-- runner:model=high -->
<!-- runner:read=docs/skills/README.md -->
<!-- runner:read=docs/skills/spec/e3d-pilot-calibration-spec-v0.1.md -->
<!-- runner:verify=bash tests/skills-schemas.sh -->

**Dependencies:** phases 5 and 6; skills phase 8; a separate go/no-go ADR.

### Work

1. Per-user opt-in and opt-out, minimum group size, source-diversity checks, pooled records labelled as such.
2. Public skill pages may show a pooled record only with count, interval, tier mix and the pooling disclosure.

### Acceptance criteria

- Re-identification and poisoning fixtures pass; opting out removes a user's contribution and recomputes.
- Public copy contains no unqualified quality claim.

### Exit gate

Security, privacy, moderation, legal and evaluation reviews.

## 12. Questions for the owner

1. **Outcome reminder.** Keep "never prompt" (default), or allow an opt-in reminder?
2. **Numbers.** The minimum counts and the data gates in section 9.
3. **Retention.** Calibration record and `use_id` retention (proposed 365 days and 30 days).
4. **Aggregation.** Whether cross-user pooling is ever wanted, and the minimum group size.
5. **Copy.** The decision-record spec bans "learn", "memory", "truth", "audit", "governance", "knowledge" and "better outcomes" in feature copy. Confirm that "track record" and "calibration" are allowed and that the ban applies here.
6. **Production count.** Approval for one aggregate, read-only query of resolved-outcome counts.
7. **Host modes.** Which hosts are supported first (Claude Code, Codex) and how skills are delivered to them (ADR-0015).

## 13. Definition of done

- A user can see, in their own agent chat, the versioned skills Pilot manages, fetch one with its hash, and report how it went.
- Track records are honest: counts, intervals, tiers and resolution rates are always shown, and nothing is presented as verified when it is self-reported.
- Records are private by default, deletable, and keyed to immutable skill versions.
- Nothing changes a default, a council or a skill without a shadow evaluation, human approval and a rollback.
- The no-skill, legacy expert and decision-record behaviours are unchanged.

## Appendix A - Amendments this document needs in the skills specification

Applied together with this document: the receipt carries `use_id`; skills phase 2 includes read-only stdio MCP tools behind `E3D_MCP_SKILLS` (ADR-0015 replaces the "no new MCP tool before phase 7" rule of ADR-0005 for local, read-only tools); the threat model gains T24 (a served skill injecting the host agent) and T25 (outcome poisoning); the hosted companion lists the remote MCP tools and OAuth scopes as a hosted-phase item.

## Appendix B - Sources

`docs/skills/**` (contracts v1, ADRs, threat model, evaluation freeze); `docs/jev-council.md`; `docs/methodology/expert-councils.md`; `docs/e3d-pilot-vision.md`; `docs/e3d-pilot-experts-feature-spec.md`; `lib/debate/recap.mjs`, `lib/debate/case.mjs`; the hosted decision-record specification (private repository); the 2026-11-17 council verdict on the next layer; the 2026-09-16 outcome-capture work.
