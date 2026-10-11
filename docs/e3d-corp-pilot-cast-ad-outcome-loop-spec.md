# E3D Corp → Pilot → CAST: Outcome-Driven Advertising Loop

**Status:** Proposed specification for e3d-pilot review — not authorized for deployment  
**Date:** 2026-10-09  
**Owner:** FutCo / E3D  
**First proving use case:** OppScan HVAC advertisement  
**Primary objective:** Improve measurable product-acquisition outcomes, while developing reusable CAST creative-production capabilities.

**Relationship to the broader loop:** this is the first proving instance of the architecture described in `docs/futco-ad-outcome-loop-manifesto.md` — read that first for the full cross-product goal, authority mapping, and what's already built vs. new. The creative-direction work this spec's P1 (§7) originally scoped to "CAST Creative Director" is being extracted into its own repo and spec, `docs/e3d-creative-engine-spec.md`, since it's reusable across every FutCo product, not OppScan-specific.

## 1. Executive intent

Build an auditable loop in which **e3d-corp owns business objectives, campaign decisions, permissions, and measured outcomes**; **e3d-pilot owns engineering investigations, multi-model debate, implementation, and improvements to CAST**; and **e3d-cast owns repeatable creative development and media production**, with **e3d-pod2vid** retained as a rendering/composition engine wherever appropriate.

The founder wants *repeatable product revenue*, **not a consulting business**. OppScan is partly a market-discovery mechanism; its HVAC advertisement is the initial quality and outcomes test for making CAST into an AI creative studio. Better advertising is the immediate experiment; building the reusable capability is the product-development outcome.

**Key clarification:** Pilot may orchestrate CAST during the proving experiment, but routine campaign production must eventually run **Corp → CAST → Corp**. In steady state, Corp invokes Pilot only when an engineering change or novel capability is required. Do not make Pilot a permanent mandatory hop for every ad variant.

## 2. System roles and authority boundaries

| Component | Owns | Must not own |
|---|---|---|
| **e3d-corp** | Business goal, customer/audience, experiment hypothesis, campaign approval, budget/risk policy, creative brief, distribution integration, performance collection, interpretation and next-action decision | Unreviewed changes to production code; creative/rendering internals |
| **e3d-pilot** | Investigating gaps, proposing change, multi-model debate/negotiation, phased feature tickets, coding/testing/reviewing CAST and connector capabilities, reporting evidence | Autonomous ad spending or publishing; inventing business outcomes; final commercial authority |
| **e3d-cast** | Creative treatments, hooks, scripts, shot lists/storyboards, voice/sound/visual orchestration, actual outputs, revision history and QA reports | Self-authorizing campaigns, deciding budgets, independently declaring campaign success |
| **e3d-pod2vid** | Existing video rendering/composition/production contracts | Campaign strategy and performance attribution |
| **External providers** | Optional Higgsfield visual generation, ElevenLabs narration/sound and other interchangeable providers | Strategic decision-making or opaque single-provider lock-in |

Authority is **per action class**, not global: recommend-only → approved execution → bounded autonomy on demonstrated successes. Publishing, account changes, significant spend, external messaging, and changes in strategic targeting require explicit scoped authorization in v1.

## 3. End-to-end lifecycle

1. **Observe:** Corp ingests campaign/account data (where integrations and permissions exist), current creative, landing page, costs and conversions. Each signal retains source, measurement window, freshness and limitations.
2. **Diagnose:** Corp identifies a gap (e.g., low three-second retention, poor click-through, qualified-lead drop-off), distinguishes creative causes from targeting, funnel or measurement issues, and opens a versioned **Creative Improvement Opportunity**.
3. **Decide:** Corp defines hypothesis, audience, constraints, metric, threshold, time window, spend ceiling and approval state. Corp may request either a routine CAST production task or a Pilot engineering task.
4. **Debate for novel work:** Pilot gathers repository facts, evaluates alternatives using its existing multi-model draft → negotiate → review process, and produces a decision record and implementation spec. Debate includes the **do not code** option, a CAST-only alternative and a provider-only alternative.
5. **Build when needed:** Pilot implements and tests missing CAST/Corp integrations. Controlled rollout; no direct production deploy from untrusted output.
6. **Produce:** CAST creates distinct treatments, scripts, storyboards, media, voice, sound, finished renders and a QA report. Preserve the baseline and every variant. Rendering may call pod2vid and optional providers.
7. **Approve and distribute:** Corp validates claims, branding, rights, quality, budget and platform policy; human approval before v1 publication/spend changes. Distribution via approved adapters, otherwise export package for manual launch.
8. **Measure:** Corp attributes performance to creative IDs and campaign windows; computes metrics from observed data, accounting for audience, spend and attribution limitations. Never fabricate ROI or conversions.
9. **Learn and repeat:** Corp compares results with predetermined criteria, creates evidence-linked learnings, requests another CAST treatment or a Pilot capability upgrade, and escalates scope changes to the founder.

### Example decision logic

- **Creative performs poorly but CAST can make a distinct variant:** Corp commissions CAST directly after required approval; no software ticket.
- **CAST cannot produce coherent cross-shot characters / desired sound:** Corp creates an engineering opportunity; Pilot debates and implements provider/QA improvement, then invokes CAST.
- **CTR rises but qualified leads do not:** Corp investigates offer/landing-page/targeting; do *not* automatically commission more cinematic footage.
- **No reliable measurement:** Fix instrumentation first rather than optimizing an unobservable metric.

## 4. Pilot's first experiment: OppScan HVAC Ad 2.0

**Baseline is mandatory.** Retrieve actual current ad from the OppScan sites, campaign asset store, or repositories (with authorized access). Extract exact transcript and timecoded scene list; inspect render, music/sound, hook, pacing, credibility and CTA. **Do not assume the original ad is a generic product demo**: the founder says it already leads with a lost-opportunity story. If source media remains inaccessible, mark the audit blocked and request the asset; do not fabricate a critique.

### Creative deliverables

- A baseline creative audit separating **concept/script** from **production polish** (cinematography, voice, sound, pacing, continuity and editing).
- **Three truly distinct creative strategies** with audience psychology, premise, first-three-second hook, storyboard, visual language and CTA; avoid mere synonym rewrites.
- A multi-model debate with explicit creative dissent and a rationale that preserves bold ideas rather than averaging toward blandness.
- At least one **high-quality premium treatment** using vendor capabilities as appropriate. Compare ElevenLabs/Higgsfield against simpler approaches; provider selection based on achieved quality, control, latency, rights and cost *recorded*, not necessarily minimized for this first experiment.
- A **timed, shot-by-shot storyboard**, word-accurate voice script, on-screen text, sound-design cues, prompt/asset provenance, rough cut, final cut, captions and platform-appropriate exports.
- A blinded or independent review rubric covering stop-scroll hook, narrative arc, clarity of OppScan value, authenticity, production quality, factual defensibility, brand fit, CTA and expected fit to HVAC owner audience.
- Test plan for baseline vs production-only improvement vs materially different creative (A/B/C), with consistent targeting and measurement wherever feasible.

### Creative QA guardrails

- The narrative must not imply OppScan actually knows a particular contractor's lost-call counts, revenue leakage or competitive conversions unless it verifiably does.
- Require consent and rights for voice likenesses, images, music and generated assets; honor vendor/platform commercial-use terms.
- Platform-compliant claims and transparent promotion; no deceptive testimonials, invented product screens or unsupported earnings claims.
- A storyboard or critic score is a heuristic—not evidence that an ad will convert.

## 5. Interfaces and minimum event schema

Implement as versioned contracts, adopting existing e3d-corp event-sourcing vocabulary and e3d-pilot/CAST APIs rather than inventing incompatible duplicates. Suggested envelope:

```json
{
  "schema_version": "1.0",
  "event_id": "uuid",
  "event_type": "creative.opportunity.created",
  "occurred_at": "ISO-8601",
  "correlation_id": "uuid",
  "causation_id": "uuid-or-null",
  "business_id": "futco",
  "product_id": "oppscan-hvac",
  "campaign_id": "opaque-id",
  "experiment_id": "opaque-id",
  "creative_id": "opaque-id-or-null",
  "actor": "corp|pilot|cast|human",
  "approval_state": "proposed|approved|rejected|revoked|completed",
  "evidence_refs": ["uri-or-content-hash"],
  "payload": {}
}
```

Proposed records/events (map to existing structures): `campaign.goal.set`, `campaign.evidence.observed`, `creative.opportunity.created`, `experiment.proposed`, `experiment.approved`, `pilot.capability.requested`, `pilot.debate.completed`, `cast.brief.accepted`, `cast.treatment.proposed`, `cast.render.completed`, `creative.qa.completed`, `campaign.publish.approved`, `campaign.published`, `campaign.metrics.observed`, `experiment.evaluated`, `autonomy.permission.changed`.

All events should carry stable identifiers, immutable evidence/artifact references, deduplication keys, actor provenance, timestamps and policy decisions. Metrics include numerator, denominator, sample size, window, source and data freshness. Don't assume every platform provides usable conversions or attribution.

## 6. Security, reliability, and spending controls

- **Default: recommend-only.** No automatic live ads, paid calls above approved ceilings, credential changes, customer messaging, or external publication.
- Provider calls and test runs use a dedicated per-experiment budget; premium quality is the creative priority, but calls remain **authorized and capped**. Track actual charges and prevent runaway regeneration loops.
- Separately scoped permissions for source-account read, creative generation, publishing and ad-budget modification. Store credentials in the existing secret store; no secrets in prompts/logs/commits.
- Idempotent events/jobs, retries with backoff, explicit states, dead-letter handling, timeout and cancel; persist artifacts and provenance.
- Human-approved claims compliance, model/asset licensing, brand safety and personal/voice likeness consent.
- Attribution and measurement sanity checks, holdouts where feasible, and alerting on spend anomaly or broken tracking.
- Rollback to prior creative, paused campaign, and previous integration build; kill switches at Corp and provider-adapter level.
- Periodic regression checks to ensure pod2vid's existing workflow still works.

## 7. Implementation phases and spec-runner-ready tickets

**P0 — Discovery, audit and contract reconciliation (no new external spend)**

- **T01 Inventory actual repositories/contracts:** Inspect current e3d-corp, e3d-pilot, e3d-cast, e3d-pod2vid, e3d-oppscan, campaign assets, deployment topology and existing approval/event patterns. Produce `ARCHITECTURE_BASELINE.md` with confirmed facts, unknowns, ownership boundaries and proposed API additions.
  - **Accept:** Traceable current-state architecture, no invented adapters/endpoints; existing stage and safety contracts mapped.
- **T02 Source and analyze baseline OppScan ad:** Locate/export media, exact timed transcript, current landing page, historical ad creative and available campaign data. Generate `BASELINE_AD_AUDIT.md` and asset manifest.
  - **Accept:** Audit references the real footage; missing assets/metrics explicitly blocked instead of guessed; no false claims about ad performance.
- **T03 Establish creative/experiment schemas and policy:** Define versioned brief, candidate, artifact, QA, approval, outcome and ledger events compatible with Corp/Pilot.
  - **Accept:** Round-trip contract tests, idempotency tests, permission-denial tests, written boundary decision.

**P1 — CAST Creative Director (recommend-only; offline tests)**

- **T04 Creative concept agent:** From objective, audience, offer and verified product capabilities produce >=3 distinct creative directions, each with hook, narrative thesis, script, timeline and shot list.
  - **Accept:** Reproducible structured outputs; valid duration; scripts distinguish fact/claim/hypothesis; separate concept diversity evaluation.
- **T05 Independent critique and debate:** Adapt existing Pilot debate process to challenge concepts and storyboards; consider competing treatments and 'retain existing creative' option; avoid endless loops and homogenization.
  - **Accept:** Bounded debate rounds, recorded dissent, explicit quality criteria and rationale, deterministic termination/fallback.
- **T06 Storyboard preview and audit:** Build shot-by-shot preview, VO script, caption text, transitions and sound plan before expensive rendering; generate reviewable comparison to baseline.
  - **Accept:** Reviewer can inspect exact scene order and approve/decline without generating premium media.

**P2 — Premium production and quality gates (approved experimental spend only)**

- **T07 Provider abstraction:** Integrate optional ElevenLabs voice/sound and Higgsfield cinematic generation via capability adapters, with provider-independent job manifests and pod2vid integration. Verify current API, licensing, pricing and supported features before implementation; do not assume Ads Engine API access.
  - **Accept:** Mocked adapter contract tests, approved-budget enforcement, fallback, provenance/rights metadata, unchanged legacy pod2vid regression suite.
- **T08 Render and inspect:** Produce rough/final cuts, captions and platform exports; automate technical validation and add independent narrative/visual QA with human checkpoint.
  - **Accept:** Artifacts for A baseline, B polish, C new direction; reproducible manifests, no broken audio/subtitles, no unverified factual claims.

**P3 — Corp campaign/outcome control (supervised)**

- **T09 Corp opportunity and experiment orchestration:** Create objective → opportunity → approved experiment → CAST/Pilot dispatch → artifact review → publication handoff. Reuse Corp's existing event/proposal/decision/action/outcome model.
  - **Accept:** End-to-end dry run; refusal and revocation work; Pilot called only for engineering need, CAST called for routine creative work.
- **T10 Distribution and metrics ingestion:** Read authorized ad-platform metrics and landing-page analytics if access exists. If there is no safe integration, provide a human-launch export and CSV/manual metric import. Track creative IDs, spend, impressions, hook hold/3-second views where supported, CTR, qualified leads, conversion rates and attribution confidence.
  - **Accept:** No invented metrics, documented denominators/freshness, controlled A/B/C testing, test-data integration passes.
- **T11 Outcome evaluator and recommendation:** Corp compares to pre-registered goals, considers sample sufficiency, confounders and operational cost; proposes keep/revise/stop/escalate, with evidence-linked decision record.
  - **Accept:** Transparent evaluation; zero-conversion and insufficient-data cases handled; campaign success not self-certified by CAST/Pilot.

**P4 — Learning, generalization, and autonomy (future gated work)**

- **T12 Lessons-to-capabilities loop:** Translate recurring creative failures into capability requests back to Pilot, and observed winning treatments into reusable CAST templates/brand memory, respecting customer isolation.
  - **Accept:** Traceable evidence → recommendation → implementation → result history; no unreviewed production changes.
- **T13 Per-action-class autonomy ladder:** Recommend → supervised → bounded autonomy, with minimum evidence, spending limits, rollback, auto-demotion, anomaly alerts and manual override.
  - **Accept:** Red-team approval-bypass tests; no promotion based on LLM confidence; thresholds set by founder, not invented by model.
- **T14 Productization review:** Determine whether CAST can sell this as repeatable SaaS, not consulting; evaluate customer acquisition, workflow time saved, quality, gross margin/provider costs and retention. Avoid premature platform generalization.
  - **Accept:** Evidence-backed go/no-go memo for further CAST investment and advertising.

## 8. Success metrics and experiment design

**Quality (pre-launch):** Independent ratings of first-three-second impact, concept distinctiveness, coherence, visual continuity, natural narration and sound, product clarity, factual accuracy and CTA. Compare baseline and variants blind where possible.

**Business (after approved launch):** Qualified leads or completed HVAC OppScan scans per dollar, landing-page completion rate, cost per qualified scan, and downstream product interest where measurable. CTR/retention are diagnostic, not the sole business objective. Pre-register primary metric and minimum practical lift before campaign starts; sample size and platform constraints may prevent statistical conclusions.

**Engineering:** Reduction in human creative revision time, successful reuse of templates/capabilities, production reliability, credits/production costs, regression pass rate, prompt and asset provenance completeness.

**Success condition for first milestone:** A reviewed, premium OppScan ad variant of demonstrably higher creative quality than the baseline, with preserved assets, reproducible production process and a ready-to-run controlled campaign test. **Do not claim conversion superiority until data exists.**

## 9. Non-goals / scope restrictions

- Not building a generic consulting engagement pipeline or optimizing consulting revenue.
- Not making Pilot the standing ad campaign manager.
- Not granting autonomous live ad spending, publication or strategy changes in v1.
- Not assuming ElevenLabs Ads Engine is publicly exposed as an API.
- Not replacing or breaking pod2vid before a validated migration plan.
- Not using speculative lost revenue or imaginary testimonials as factual campaign claims.

## 10. Required response from e3d-pilot

On intake, **do not immediately execute all phases**. First:

1. Review the architecture assumptions against actual repos and deployments, naming any discrepancies.
2. Propose the minimal integration seams and which existing components already satisfy tickets.
3. Run the existing draft/negotiation/debate flow (including a *simpler alternative* and a *no-new-code* alternative) and produce risks/tradeoffs.
4. Return phased, independently executable feature tickets with dependencies, tests, estimated effort, reversible rollout plan and required approvals.
5. Identify where the original OppScan ad assets and real campaign metrics live, or list precise blockers.
6. Recommend **the smallest executable first slice** that materially improves the real OppScan ad and proves reusable CAST capability.
7. Request founder approval before paid provider experiments, public publishing, ad spend or consequential production changes.

**North star:** Corp manages business outcomes; Pilot evolves capabilities; CAST produces the creative; Corp measures real results and decides the next move.
