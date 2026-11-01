# Feature ticket: E3D Experts, Dynamic Councils, Reputation & Developer Talent Evidence

**Status:** Proposal for council-informed review; docs only; no implementation or deployment authorized by this ticket.  
**Date:** 2026-11-01  
**Primary repository:** `spacepacket1/e3d-pilot` (expert definitions, debate orchestration, MCP interface)  
**Companion repository:** `spacepacket1/e3d-pilot-cloud` (identity, registry, publication, moderation, billing, Gallery)  
**Product principle:** *Experts are reusable. Councils are dynamically composed. Verified outcomes, not popularity, determine competence.*

## 0. Decision summary and vision

E3D Pilot began as a way for developers to put architecture, code, and product decisions before multiple independent AIs. One compelling destination is an **evidence-based developer recruiting assistant**: help candidates demonstrate their work and help human interviewers examine job-relevant technical evidence. We will **not** start with automated candidate ranking or hiring decisions. First, build the **horizontal expert infrastructure** that developer recruiting and many other workflows need.

The market has many copy-and-paste prompt threads and scattered skill files. E3D should let anyone create, test, version, privately use, publish, fork, and share AI *experts* through natural language. An expert is a reusable, explicitly permissioned task capability—not merely a clever prompt. An **Auto Council** can assemble experts from different model families for a question, explain its selection, and track what actually helped. The existing Debate Gallery becomes the discovery/lineage surface, while ChatGPT, Claude, Copilot and other MCP hosts remain primary usage surfaces. Public reactions help discovery; verified results inform selection.

This proposal extends existing functionality and design documents rather than reopening or replacing merged PRs. No claim that the new expert features already exist is permitted.

### 0.1 Debate receipt (2026-11-01)

Four independent families (`anthropic-api`, `openai-api`, `gemini-api`, `xai-api`) ran two rounds of the existing `e3d_debate` tool. Debate receipt `dbt_ac4fbb944a3d2e2a43b3dfc2`; **consensus: majority**.

- Shared recommendation: ship narrowly scoped, MCP-native expert definitions, dynamic councils and verifiable measurement in existing repos; postpone open marketplace monetization and deployment into hiring workflows until evidence and safeguards exist.
- **Recorded dissent:** OpenAI initially preferred an earlier public Gallery; Anthropic and Gemini favored measurement before marketplace; Anthropic suggested a candidate-controlled self-assessment precursor to hiring (not explicitly endorsed by peers).
- Do not portray unanimous approval, guaranteed value, or measured improvement. These recommendations are advisory; no model authorizes spending, publication, configuration changes or deployment.

### 0.2 Related work: preserve and extend, do not duplicate

| Existing artifact | Status / relevance | Integration rule |
| --- | --- | --- |
| [`docs/prompt-review-2026-10.md`](https://github.com/spacepacket1/e3d-pilot/blob/main/docs/prompt-review-2026-10.md), committed [2026-10-17](https://github.com/spacepacket1/e3d-pilot/commit/39b652207040bcd991655c1c8f66cb726ccbc77d) | Proposed 12 lenses, specialist YAML format, 5 panels, phased router, internal AI-roster recruiter | Starting design; update with evolution and testable contracts; do **not** confuse internal agent-roster recruitment with screening human candidates |
| [`e3d-pilot` PR #20](https://github.com/spacepacket1/e3d-pilot/pull/20) | Merged: debate decision logging and computed agreement | Extend telemetry; preserve existing log compatibility, privacy and fallback semantics |
| [`e3d-pilot-cloud` PR #272](https://github.com/spacepacket1/e3d-pilot-cloud/pull/272) | Merged: Gallery audit / stacked implementation plan | Follow existing cloud architecture, auth and deployment process |
| [`e3d-pilot-cloud` PRs #279](https://github.com/spacepacket1/e3d-pilot-cloud/pull/279) and [#280](https://github.com/spacepacket1/e3d-pilot-cloud/pull/280) | Merged historical house-wallet Council scoring design | **Historical only**: do not reinstate house funding; newer #283 superseded payment choice |
| [`e3d-pilot-cloud` PR #283](https://github.com/spacepacket1/e3d-pilot-cloud/pull/283) | Merged: publish immediately, optional Council score paid by publisher | Preserve opt-in quote/reserve/settle, failure semantics, no moderation by score |
| [`e3d-pilot-cloud` PR #284](https://github.com/spacepacket1/e3d-pilot-cloud/pull/284) | Merged: Gallery likes/saves/search/sort | Reuse reaction, identity, counter and pagination patterns; do not let popularity modify verified scores |
| [`e3d-pilot-cloud` PR #286](https://github.com/spacepacket1/e3d-pilot-cloud/pull/286) | Merged: opt-in creator handles | Reuse opt-in identity/publication and account deletion behavior |
| [`e3d-pilot-cloud` PRs #290](https://github.com/spacepacket1/e3d-pilot-cloud/pull/290) and [#291](https://github.com/spacepacket1/e3d-pilot-cloud/pull/291) | Merged: Council score rationale and owner appeals | Reuse audit/appeal patterns without overwriting historical assessments |
| [`e3d-pilot-cloud` human-contributions spec](https://github.com/spacepacket1/e3d-pilot-cloud/blob/main/docs/human-contributions-conversation-continuations-spec.md) | Existing Gallery/challenge/contribution strategy | Experts and council recipes become attributable, linkable participants in this graph—not a replacement social feed |

Re-audit current `main` and active PRs **at the start of each implementation phase**; this ticket records research performed on 2026-11-01, not a claim about future deployment state.

## 1. Product goals and non-goals

### Goals

1. A user creates a specialized expert conversationally, previews its exact behavior, runs tests, and privately reuses it without editing prompts or skill files.
2. Expert = domain/task expertise + role/lens + versioned instructions + model preferences + declared tools/evidence + data/output contract + test fixtures. Separate these axes; a role is not a model and a prompt does not confer expertise.
3. A user chooses an expert, a curated council recipe, or `auto`. Auto maps task/risk/evidence/budget to eligible experts and model-diverse providers, with a readable explanation and override.
4. A run records complete provenance, per-seat contributions and disagreement, structured verifiable evaluations, cost and reliability; measuring team lift against a strong single-model baseline is mandatory before accuracy marketing.
5. Published experts/recipes are discoverable, forkable and rateable with separately displayed community signals and evaluated performance. Host-driven MCP access is first-class.
6. A later, explicitly gated **developer talent evidence** use case turns candidate-authorized work samples plus a job description into an evidence map and interviewer questions for human judgment.

### Non-goals (this ticket)

- A replacement for OpenAI/Claude/Copilot chat UIs, generic social comment platform, or standalone ATS.
- An automated employment-screening, reject/accept, candidate-score, candidate-rank or interview-routing engine; no hidden eligibility score or proxies.
- Automatically publishing an expert inferred from a conversation; **explicit creator confirmation** required.
- Claiming specialists have real-world credentials or verified domain knowledge simply because their prompt says so.
- Unrestricted execution of third-party skills, remote fetching on install, autonomous tool escalation or cross-account data access.
- Paid expert marketplace, revenue sharing, payouts and automated agent-roster 'hiring/firing' before the applicable gates.

## 2. Core data contracts (schema v1, to be finalized in Phase 0)

### 2.1 `ExpertDefinition`

Required immutable version fields:

```yaml
schema_version: expert/v1
id: expert.<namespace>.<slug>
version: 1.0.0
owner_id: opaque-account-id
visibility: private                # private | team | public
name: Smart Contract Skeptic
description: Finds evidence-backed Ethereum contract risks
domain_tags: [solidity, security]
task_contracts: [review-code, review-spec]
lens: skeptic
personality: skeptical-but-evidence-led
instructions:
  method: "Identify exploit hypotheses and the cheapest verifying test."
  avoid: "Do not invent vulnerabilities or present unverified issues as proven."
model_preferences:
  - { family: independent-first, effort: high }
required_evidence: [source-code]
requested_capabilities: [repository-read]
output_schema: expert-findings/v1
tests:
  - { fixture_id: synthetic-contract-001, assertion_set: security-v1 }
license: creator-selected-license
provenance: { parent_expert_version: null, skill_source: null }
moderation_status: draft
content_hash: computed-from-canonical-definition
```

- All executables, credentials, MCP endpoints, retrieved content and external attachments are **untrusted inputs**; this schema must never grant permissions. Enforcement is done by the calling host/cloud policy, not the expert prompt.
- Prompt revisions create new immutable versions; previously published versions and run receipts remain addressable. Public fork links to exact parent hash/version. User data is not embedded in public definitions by default.
- Distinguish `creator_claims`, `verified_capabilities`, `benchmark_results`, and `community_reactions`. No inferred professional certification.
- Import/export of compatible Agent Skills (and skill references) is opt-in, sanitized and allow-listed, with license/attribution preservation. Disallow auto-executed install hooks.

### 2.2 `CouncilRecipe`

A recipe references **expert IDs + pinned versions or explicit update policy**, task fit, participant count, diversity constraints, synthesizer/judge, evidence requirements, permitted budgets and fallback. Recipes are forkable independently of expert versions.

Sample presets from existing October proposal: `risk-review`, `spec-review`, `creative-writers-room`, `forecast`, `gap-finding`; retain working default provider lists until feature-enabled. Users can also run `auto` without storing a recipe.

### 2.3 `SelectionReceipt`, `SeatContribution`, `EvaluationRecord`

- `SelectionReceipt`: task class and risk flags; available eligible expert versions; chosen/declined seats with reasons; resolved model family; required tool/evidence availability; user overrides; budget estimate/approval; router version and confidence; no hidden candidate attributes.
- `SeatContribution`: expert ID/hash, provider/model identifier, round, evidence refs, claim IDs, action, disagreement, runtime status/cost/latency; preserved separately from synthesized verdict.
- `EvaluationRecord`: dataset/fixture version, grader protocol, blind judgment provenance, *verified* findings and false positives, baseline run IDs, task category, evaluation date, confidence/coverage, estimated or actual cost. Append-only audit trail; corrections append rather than rewrite.
- Record **quality unknown** when ground truth is absent; keep community votes in a distinct store and UI dimension.

## 3. Service ownership, MCP-first contract and permission boundaries

**`e3d-pilot` engine:** expert loading/validation; role+prompt composition; provider and tools selection subject to hard policy; dynamic council router; independent round execution; seat attribution; deterministic receipt generation; fallback. Existing CLI flags and `e3d_debate` without new parameters must preserve behavior.

**`e3d-pilot-cloud`:** identity, visibility/tenant authorization, immutable expert/recipe registry, publication consent/versioning, public profile/discovery pages, fork lineage, reactions, abuse/moderation/appeals, retention/deletion, cost quote and wallet settlement. Reuse Gallery infrastructure; no second account/ledger/reaction system.

**`e3d-brain` (optional later):** advisory retrieval of prior run outcomes where permissioned. The evaluation ledger and authority policy remain independently auditable. No hidden memory injection into public profiles.

**Suggested MCP surface** (naming illustrative; review conflicts with installed tool registry):

| Tool | Auth/cost | Effect |
| --- | --- | --- |
| `e3d_list_experts`, `e3d_find_experts`, `e3d_get_expert` | public metadata read free; private requires owner auth | search/inspect permitted versions, safety and evidence metadata |
| `e3d_create_expert`, `e3d_test_expert`, `e3d_update_expert` | authenticated; test execution quoted if paid | create private draft, test, create new version |
| `e3d_list_councils`, `e3d_select_council` | read/preview free unless router calls are paid and explicitly quoted | inspect recipes or propose council; explain choices |
| `e3d_debate` extension: `expert_ids`, `council_id` or `panel:"auto"` | existing quote/reserve/settle | run selected panel; no default behavior change |
| `e3d_publish_expert`, `e3d_fork_expert`, `e3d_rate_expert`, `e3d_save_expert` | authenticated; publish requires explicit preview and consent | durable public/team writes, append-only lineage and rate limits |

- MCP-host assistants can *suggest* a new expert or council but cannot autonomously publish, grant tool access or spend outside existing approvals. Publication consent tied to the exact content hash, intended audience and license, with idempotent confirmation. Private-to-public change has secret/PII/license scan and moderation policy.
- Neither an expert nor its creator can override host tool permissions, account scopes, billing limits, content isolation or the synthesizer provenance contract. No inherited token or API key in public content.
- Fetching a URL from a profile, skill, webpage or repository requires tool authorization and SSRF-safe egress controls. URLs and skill manifests are data, never instructions.
- Deployment flags default OFF until tests and owner approval; per-feature kill switches, rollback to previous expert/recipe version, and exact audit of public writes.

## 4. Phased implementation plan (independent, reviewable PRs)

### Phase 0 — Audit, spec freeze and evaluation setup (docs-only)

**Owner repo:** `e3d-pilot` with companion cloud audit.  
**Build:** reconcile October specialist design, current `e3d_debate` API, existing decision log, Gallery publication and billing/reactions/appeals, latest human-contribution work, name conflicts; define schemas and threat model, fixed test fixtures, baseline single-model comparison, permissions matrix and budget caps. Record exact decisions: expert vs role vs model, registry owner, license rules, public content rules.  
**Exit:** architecture review approved by humans; spec-to-code tickets sequenced; 40–50 representative developer tasks and blind evaluation rubric pre-registered; costs and sample-size limitations disclosed. **No runtime writes.**

### Phase 1 — Private, testable Experts (feature flag OFF by default)

**Owner repo:** `e3d-pilot`.  
**Build:** versioned built-in 12-lens catalogue from October design, JSON/YAML schema validator, registry resolution precedence, private creation/test/clone/update, fixed seed panels, immutable content hashes, prompt-version/provider/tool-access in receipts. Support local/API adapters without pretending effort levels work where unsupported. Controlled import/export of inert skill definitions.  
**Acceptance:** existing default `e3d_debate` unchanged; deterministic fixtures cover malformed expert, conflicting versions, prompt injection, missing provider, unauthorized tool requests, disabled feature; at least five diverse synthetic expert tests pass; preview shows exact capabilities and cost. No third-party publication yet.

### Phase 2 — Auto Council routing + MCP discovery

**Owner repo:** `e3d-pilot`; cloud only for authenticated account-specific resolution if needed.  
**Build:** task/risk/evidence classifier proposes expert set + family diversity + fallback + budget; start in `advisory`/shadow mode with human override, then opt-in `auto`; rationale and considered alternatives in receipt. Add list/get/select MCP tools and opt-in `e3d_debate` panel selection. Include zero/low-confidence fallback; prohibit silent escalation to privileged tools and paid calls.  
**Acceptance:** seeded test questions route to defensible task-relevant panels; every selection reproducible from receipt and version; model outages degrade transparently; cost quote respected; no cross-account access; no change to existing MCP defaults.

### Phase 3 — Measurement, hard baselines and council-learning experiment

**Owner repo:** `e3d-pilot`, with cloud analytics read models only.  
**Build:** extend merged PR #20 decision log without removing fields; collect per-expert/role/model/version/task verified unique findings, rejected claims, corrections, dissent, human grading, cost, latency, reliability. Baselines: best available single model **with same tools/evidence**, fixed preset, random eligible preset, proposed auto panel. Blind grade where possible, data split to prevent fixture leakage, freeze router before holdout test. Store uncertainty and sample counts. Selection must not treat engagement as truth.
**Acceptance / go-no-go:** run at least 40–50 representative tasks with documented graders and complexity bands; demonstrate meaningful verified unique finding lift at acceptable cost (initial hypothesis >15% lift and <3x single-model cost, **threshold to approve in Phase 0**), with false-positive rate not worse and no material privacy or auth failures. If inconclusive, label as such and continue shadow-only; do not market accuracy gains.

### Phase 4 — Curated public Expert/Recipe Gallery and creation workflow

**Owner repo:** `e3d-pilot-cloud` plus new MCP write adapters in `e3d-pilot`.  
**Build:** conversational `create -> preview -> test -> publish` with explicit consent; shareable expert and recipe permalink; search/categories; creator handle (reuse #286); like/dislike/save/fork (reuse #284 patterns), version lineage, moderation/report/appeal (reuse #290/#291 practices), opt-out and removal. Link each public debate's consenting expert versions/recipe to canonical page; preserve Gallery public/private boundary. Public ranking explicitly distinguishes *community appreciation* from *validated effectiveness*. Implement anti-sybil vote throttles, manipulation flags and minimum-sample disclosures.  
**Acceptance:** creator can publish and a different authenticated user can fork with attribution; anonymous visitor can read public metadata only; private drafts never leak; author can request removal; moderation does not alter verified history silently; votes cannot change evaluation scores; publisher-paid optional scoring/billing behavior from #283 remains intact. **Gate:** Phase 3 establishes credible measurement or public release is labeled explicitly experimental/uncertified.

### Phase 5 — Developer Talent Evidence pilot (separate go/no-go; NOT an automatic hiring tool)

**Owner:** companion proposal and separate security/legal review; cross-repo, **not bundled into the initial engine PRs**.  
**First pilot:** candidate-controlled **self-assessment** with opt-in résumé and GitHub/work samples, and job requirements supplied by candidate or human reviewer. Generate linked evidence-by-requirement, verified repo contribution references, gaps, contradictory sources, and suggested technical interview questions. No inferred protected traits, personality, trustworthiness, age, gender, ethnicity or health; no numerical fit score, ranking, automatic reject/advance, or invisible filtering. Profiles and scraped social content are not blanket consent; LinkedIn requires authorized content acquisition.  
**Next gate:** if employer-facing, human operators must commission jurisdiction-specific legal review (including CA employment automated-decision regulations and NYC Local Law 144), assess bias/adverse impact, accessibility/accommodation, candidate notices and meaningful challenge/correction, retention/deletion, model-vendor data processing and whether even substantial decision support qualifies as regulated AEDT. Explicitly verify every geography before any launch; “human in the loop” alone does not guarantee exemption.  
**Acceptance:** at least several consenting developers/interviewers find traceable, useful technical questions vs existing workflow; source references are checkable; unsupported claims called unknown; no automatic employment decision; deletion/revocation works and access is logged. Gate off employer-facing use until external review and measurable benefit.

### Phase 6 — Marketplace economics and verified specialization (deferred)

**Owner:** new business-model decision and security/finance review.  
**Build only after demand:** premium expert bundles, enterprise/team libraries, paid evaluation or hosted execution, optional creator payouts, anti-fraud and dispute/chargeback processes, commercial-use licenses. No paid public skill execution without explicit quotes, per-tenant limits, abuse enforcement and clear cost/revenue attribution.  
**Acceptance:** verified retention and paid willingness-to-use; no incentives to trade likes, fabricate reviews, hide failed tests, or privilege creators in Auto selection.

## 5. Cross-cutting safeguards and migration invariants

- **Backward compatibility:** existing `e3d_debate` default provider selection, rounds, synthesis, CLI and MCP output stable unless new parameters explicitly supplied; additive schema versioning with migration tests.
- **Truth and dissent:** preserve independent model positions and attributable dissent; same model in several roles is **not** multiple independent vendor families; present structural agreement separately from factual verification.
- **Privacy:** no raw questions, candidates, repository contents or transcripts in public telemetry by default; hashes alone are not a substitute for adequate access controls. Tenant isolation, minimization, retention, deletion, encryption, audit and data export policies required.
- **Tool authority:** community expert manifest is **never** an authorization token; default deny, scoped capabilities, per-run permission checks, network allowlist, executable restrictions, prompt-injection tests, and explicit paid actions.
- **Reputation:** unique account reaction controls, rate limiting, abuse review, separate displayed dimensions; never equate like-rate with objective correctness or use popularity as a safety decision.
- **Billing:** keep existing quote/reserve/settle and idempotency; adhere to PR #283's publisher-funded *optional* Gallery assessment, not earlier #279/#280 house-funding proposal.
- **Safe rollout:** owner-approved enablement, staggered tenant canary, observability, cost ceilings, error alarms, documented rollback; do not claim production availability because a PR merges.
- **Legal source-of-truth:** [CA Civil Rights Department regulations](https://calcivilrights.ca.gov/civilrightscouncil/rulemaking-actions/) (effective 2025-10-01) and [NYC DCWP Local Law 144 FAQ](https://www.nyc.gov/site/dca/businesses/faq-automated-employment-decision-tools.page); verify current law and product behavior at time of pilot, not from this static document.

## 6. Metrics, experiment gates and falsification

Track per task class, independent family count, expert version, model version and evidence/tool availability:

- **Correctness:** independently verified unique findings, false positives, accepted fixes with eventual outcome, measured task coverage, abstentions and calibration. Set eval protocols before reviewing outcomes.
- **Lift and cost:** auto vs strongest comparable single-model and best fixed preset; dollars/credits, latency and context overhead per verified useful finding.
- **Real usage:** 7/14/30-day expert reuse, user-initiated forks, successful test-to-publish rate, verified repeat councils; do not optimize raw signups or likes alone.
- **Creator supply:** percent of conversationally generated experts passing test suites and permission review; time to first useful expert; abandonment and correction rates.
- **Talent pilot:** consent rate, evidence traceability, interviewer usefulness of generated questions, correction requests and privacy incidents. No hiring-outcome optimization absent separate lawful evaluation.

**Suggested hypotheses to reject or revise the vision:** (a) no clear verified council advantage at acceptable cost; (b) users do not reuse experts after first novelty exposure; (c) experts are not reliably testable; (d) moderation/permission costs exceed feasible bootstrap budget; (e) talent briefs do not beat a careful human review in time or evidence quality. Stop or narrow if thresholds fail; do not redefine a failed metric into a success metric after the fact.

## 7. PR breakdown and engineering handoff

This **new docs-only PR** does not merge or replace previous PRs. After approving Phase 0, open discrete, testable implementation PRs against fresh `main`:

1. `e3d-pilot`: expert schema, 12 seed lenses, fixtures, immutable versions (Phase 1).
2. `e3d-pilot`: advisory router + MCP read/select + opt-in debate expansion (Phase 2).
3. `e3d-pilot`: versioned telemetry, blind baseline harness and report (Phase 3).
4. `e3d-pilot-cloud`: public registry, safe publication, reactions, fork lineage, moderation and Gallery links (Phase 4); alongside a separate MCP publication adapter PR.
5. **Separate gated proposal**: developer self-assessment evidence workflow, legal/privacy review, pilot evaluation (Phase 5).
6. **Future decision only**: premium marketplace / payouts (Phase 6).

Every implementation PR must include: explicit exclusions; added/modified data contracts; backwards-compatibility tests; tenant security checks; financial cap if applicable; rollback; and documentation showing which prior subsystem was reused. Require human code review and no implicit deployment.

## 8. Open decisions for owner and council

1. Should public experts pin exact models, use model-family constraints, or permit a hybrid with provenance? Proposal: hybrid, but always record resolved provider/model.
2. What is the exact expert test certification protocol and who may publish a “verified” badge? Proposal: tests must be inspectable and reproducible; no self-attested badges.
3. Is marketplace launching curated/experimental before Phase 3 evidence worth the distribution upside? Council **majority** says no; GPT initially dissented. Resolve after evaluation pilot.
4. What is the minimal permissioned Agent Skill import boundary, with no execution privileges on import?
5. Should Phase 5 remain entirely candidate-controlled until a jurisdictional employment assessment is completed? Proposal: yes.

**Review instruction:** challenge this proposal as a strategy and architecture decision. Record remaining dissent, especially around the recruiting wedge, marketplace sequencing, evidence quality, and cost. A multi-model consensus is not itself proof of market fit.