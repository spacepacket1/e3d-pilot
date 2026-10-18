# Debate

**Prompt version:** v3b

**Question:** CONTEXT
Below is a spec for letting an autonomous system spend a small ad budget inside human-set limits. It is already partly built. You are reviewing it before the next phase is authorized.

QUESTION
Review this spec. Answer each point:
1. VERDICT. Pick exactly one: (a) approve it as written, (b) approve with specific required changes, (c) hold until named gaps are closed, (d) reject.
2. The three biggest risks, ranked, each with the spec section it comes from.
3. One thing in the spec that is missing or contradicted elsewhere in it.
4. The single smallest change that would reduce the biggest risk.
End with one recommended next action.

SPEC
# FutCo Ad Mandate: Bounded Autonomous Ad Spend

**Status:** Phases 1-3 built and tested, plus the ad-performance Diagnose trigger and the spend-ceiling kill switch, 2026-10-11/12 (239/239 e3d-corp tests passing). The full futco cron schedule is live. What remains before the loop runs for real is listed in section 9 - it is entirely human inputs (real numbers, a product mapping, a mandate), not engineering work. Phase 4 requires separate, explicit authorization before implementation — see Non-goals.
**Date:** 2026-10-11, updated 2026-10-12
**Companion to:** `docs/futco-ad-outcome-loop-manifesto.md`, `docs/e3d-creative-engine-spec.md`

## 1. Problem

The loop described in the manifesto works end to end, but every gate in it is a literal human click: Decide, Build, Produce, and Approve & Distribute all require a person to act before anything moves forward (see `docs/futco-ad-outcome-loop-manifesto.md` and the FutCo Growth Loop diagram built alongside it). The goal stated for this spec: a human sets hard limits once — budget, spend ceilings, pause conditions — and the system then runs the loop continuously inside those limits without per-action approval, while a human can monitor, adjust the limits, or stop everything at any time.

## 2. Precedent: `capital_mandate`, and its one real limit

e3d-corp already has almost exactly this mechanism, built for e3d-trade: a human authors a versioned `capital_mandate` (`e3d-corp/lib/proposals/capitalMandateSchema.js`) with constraints that can only tighten a baseline risk policy, never loosen it (`collectRelaxationSignals` rejects any constraint key or value that relaxes, overrides, bypasses, or raises a limit). Once active, the mandate biases Scout's candidate scoring and constrains the Risk engine (`e3d-trade/scripts/riskEngine.js`) without a human in the loop per trade. Revoking or suspending the mandate (its lifecycle already has both states) stops the bias immediately.

**The one thing this precedent does not prove:** real-money autonomous execution. `validateCapitalMandatePayload`'s own schema hard-rejects `live_execution_allowed` unless it's `false`, and requires `paper_only: true`. Every trade a mandate has ever influenced has been paper. Porting this pattern to ads gives a tested blueprint for *bounding autonomous decisions* — it is not evidence that autonomous *real-money* execution is safe in this codebase yet. That gap is exactly why Phase 4 below is separated out and not authorized by this spec alone.

## 3. `ad_mandate` schema

Mirrors `capital_mandate`'s shape (same file pattern: `lib/proposals/adMandateSchema.js`), adapted for ad spend:

```
mandate_id        string (deterministic hash of the stable fields, like capital_mandate)
version           "1.0"
owner             string
status            proposed | approved | active | completed | expired | revoked | suspended
created_at        ISO timestamp
approved_at       ISO timestamp | null
effective_at      ISO timestamp | null
expires_at        ISO timestamp
revoked_at        ISO timestamp | null
correlation_id    string
proposal_id       string
decision_id       string | null
thesis_refs       string[]        -- why this mandate exists (links to Opportunities/evidence)
objective         string | object
constraints: {
  max_daily_spend_usd        number   -- tightens-only against the hard ceiling (section 4)
  max_monthly_spend_usd      number
  max_cpl_usd                number | null   -- cost-per-lead ceiling, null = no CPL gate
  max_cac_usd                number | null   -- cost-per-acquisition ceiling (needs Stripe attribution, see section 7)
  allowed_products            string[]        -- which FutCo products this mandate covers
  allowed_campaign_ids         string[] | null -- null = any campaign under the allowed products
  pause_on_metric_degradation: {
    metric                   string   -- e.g. "cpl_usd", "landing_page_view_rate"
    window_days               number
    degradation_pct           number   -- e.g. 0.4 = pause if the metric worsens 40% over the window
  }[]
  paper_only_creative          true     -- always true in phases 1-3, see section 8 (commission-creative only, never spend)
}
preferences        object
confidence          number 0-1
invalidation        string | object
```

Validation mirrors `validateMandateConstraintsAgainstPolicy`/`collectRelaxationSignals`: every numeric ceiling in `constraints` must be `<=` the matching hard-ceiling value (section 4), never settable higher; `paper_only_creative` must be `true` in phases 1-3 and the validator rejects any payload that tries to set it `false`, the same way `capital_mandate` hard-rejects `live_execution_allowed: true`.

## 4. The hard ceiling — non-bypassable, lives outside the mandate

Exactly like `RISK_POLICY` sits outside and above any individual `capital_mandate`, e3d-corp needs an `AD_RISK_POLICY` constant (checked into code, changed only by a human PR, never by a mandate or any autonomous process):

```js
export const AD_RISK_POLICY = {
  max_daily_spend_usd: /* a human sets this to a real number before Phase 4 ships */,
  max_monthly_spend_usd: /* same */,
  max_active_mandates: /* e.g. 3, to bound blast radius of several mandates running at once */
};
```

**No numbers are proposed here.** They must come from whoever owns FutCo's actual ad budget, not be invented as placeholders that could be mistaken for real limits. Every mandate's constraints are validated against this policy at creation time, the same way `validateMandateConstraintsAgainstPolicy` already works for trade — a mandate can only ask for *less* than the ceiling, never more.

## 5. What becomes autonomous, and when — phased

### Phase 1 — `ad_mandate` schema, lifecycle, hard-ceiling validator (zero risk)
Pure data structure and validation, no executor attached to anything yet. Mirrors `lib/proposals/capitalMandateSchema.js` file-for-file: schema validation, status transitions, deterministic mandate ID, relaxation-signal rejection. A mandate can be proposed, approved, and made active, but nothing consults it yet. Tests mirror the existing `capitalMandateProposal.test.js`/`capitalMandateAction.test.js` pattern.

### Phase 2 — autonomous approval for `commission-creative` only (zero financial risk) — **Built, 2026-10-11**
`commission-creative` never spends money or publishes anything — it only produces a creative direction (see the FutCo Growth Loop diagram: Produce is authority level 2, and e3d-creative's own QA gate already rejects weak directions before they go anywhere). This is the safe place to remove the human click first:

- A new decision path, `autoDecideUnderMandate(dataDir, proposalId, mandateProposalId, instanceConfig)` (`e3d-corp/lib/decisions/autoDecideUnderMandate.js`), checks: the mandate is `active` (re-checked live at decision time via `currentAdMandateStatus`, never cached — the same discipline `currentMandateStatus` already enforces for trade), the proposal's product falls within the mandate's `allowed_products`, `allowed_campaign_ids` is `null` (fails closed otherwise — commission-creative proposals carry no campaignId to check against yet), and `paper_only_creative` is `true`. The pure predicate behind this (`evaluateMandateCoverage`) is exported separately so a scan can check many pairs without using exceptions for control flow.
- On success it appends `proposal.approved` with `source: "decision:autonomous-mandate"` (distinct from `decision:cli`/`decision:web` so the event log always shows which decisions were a human and which were the mandate), then executes exactly like `decideProposal` already does for a human approval — inside the same event-log write lock, re-checking both the proposal and the mandate from scratch before acting, so a revoke/decide racing in between is never missed.
- The actual autonomous loop is `ops/reports/autoDecideCommissionCreative.js` (run by cron via `ops/run/run-auto-decide.sh`, same shape as the Meta/Stripe polls): it scans every pending `commission-creative` proposal against every `ad_mandate` proposal and auto-decides each covered match. `autoDecideUnderMandate` is also exposed as `proposals auto-decide <id> --mandate <mandateProposalId>` in the CLI, for an operator to inspect or force a single decision — that command is not itself the autonomous path.
- A human still creates and approves the `ad_mandate` itself — the autonomy is scoped to "which routine creative variants get commissioned under an already-human-approved mandate," not to mandate creation.
- **Built, 2026-10-11 — the upstream half**: two more autonomous scans close the hops that were still manual: `lib/roles/autoDraftCreativeBriefs.js` (CLI: `opportunities auto-draft-creative-briefs`; ops: `ops/reports/autoDraftCreativeBriefs.js`) runs `creative.brief` over every "pursuing" opportunity that doesn't have a drafted brief yet, mirroring `pursueCommand`'s existing scan for outreach. `lib/proposals/autoProposeFromBrief.js` (CLI: `proposals auto-propose-from-briefs`; ops: `ops/reports/autoProposeCommissionCreative.js`) then turns every un-proposed `creative-brief.drafted` event into a pending `commission-creative` proposal, keyed off a new `payload.sourceBriefEventId` field on the proposal for exact, non-fuzzy idempotency. The full chain is now: pursuing opportunity → brief drafted → proposal created → proposal auto-decided under an active mandate → e3d-creative commissioned — with no human click anywhere in that chain except the one-time act of approving the `ad_mandate` itself.

### Phase 3 — circuit breaker (observe-only first, then enabled) — **Built, 2026-10-11**
A scheduled job (`ops/reports/checkAdMandateHealth.js`, logic in `lib/health/adMandateHealth.js` + `lib/health/runAdMandateHealthCheck.js`) evaluates, for every active mandate, both:
- its `pause_on_metric_degradation` rules against the latest Meta-insights evidence already being polled (summed-ratio aggregation over a current vs. prior window of the same length; refuses to evaluate a metric name it has no real evaluator for rather than guessing), and
- its own `max_daily_spend_usd`/`max_monthly_spend_usd` ceiling against real summed Meta spend for today/this month (`evaluateSpendCeilings`) — **built 2026-10-12**, this is the literal answer to "what happens if we spend more than $X/day": unlike the degradation rules, the spend-ceiling check is always on and never configurable away, because every mandate already declares these numbers as hard limits.

Ships in the two steps the spec asked for, both implemented, switched by one config flag, applying identically to both kinds of check:
1. **Observe-only (the default - `adMandateHealthCheck.autoSuspendEnabled` absent or `false`)**: appends an auditable `ad-mandate.health-check.breach-observed` event and logs the breach, never acts — lets a human confirm the signal is trustworthy before it can take an action.
2. **Enabled (`adMandateHealthCheck.autoSuspendEnabled: true`)**: on a confirmed breach, auto-transitions the mandate to `suspended` via the same kill-switch function a human uses (an `ad-mandate.auto-suspended` event, fully auditable and distinguishable from a human-triggered suspension).

One real, not-yet-closeable gap: evaluating a mandate with `allowed_campaign_ids: null` ("any campaign under the allowed products") requires knowing which Meta campaigns belong to which product. `research.meta.campaigns[]` now has an optional `product` field for this (`lib/config.js` validates its shape); the real `futco` instance config does not have it filled in yet (its two campaigns, `hvac_v3` and `free_v2`, have no `.product` set), so the health check currently reports "insufficient data" for any mandate scoped by product rather than by explicit `allowed_campaign_ids` — correctly, since guessing the mapping would risk suspending (or failing to suspend) the wrong campaign. A human who knows which product each campaign actually belongs to needs to fill this in.

### Diagnose trigger for ad performance — **Built, 2026-10-12**
A gap found separately from the phased rollout above, but part of the same loop: nothing ever turned a degrading Meta campaign metric into an Opportunity - evidence just accumulated with no one looking at it (unlike the oppscan feed, which already had `ops/reports/promoteOppscanFitSignals.js` for this). `lib/event-sources/adPerformanceSignal.js` + `ops/reports/promoteAdPerformanceSignals.js` close this: they re-derive degradation candidates from the full Meta-insights evidence history every run (reusing the circuit breaker's own `evaluateDegradationRule`, not a second implementation), raise one signal per (campaign, metric, window period) the first time it breaches a threshold, and hand it through `opportunity.prospect` like every other trigger in this instance - never proposing or activating anything itself, same "a human still decides" boundary as everywhere else. The default threshold (`cost_per_landing_page_view` degrading 30% over 7 days) is overridable via `research.meta.opportunitySignalRules`; unlike `adRiskPolicy`, this is a review-timing heuristic, not a dollar ceiling, so a documented engineering default is fine here.

### Phase 4 — real Meta-write executor + autonomous financial actions — **not authorized by this spec**
Launching an ad or changing a budget is `FINANCIAL_ACTION` (authority 3) today with no executor at all behind it (`lib/authority/policy.js`'s `meta-campaign-change` entry has been waiting for one since before this session). Making *that* autonomous — even under a mandate — is the one genuinely new kind of risk in this whole design: real money, via a credential already confirmed to carry `ads_management` and several other broad scopes beyond what its name implies. This phase needs its own explicit go-ahead, its own review of the hard-ceiling numbers against a real budget, and ideally a period of Phase 2/3 running cleanly first. Nothing in Phases 1-3 should be read as a stepping-stone commitment to this phase.

## 6. Kill switch — **Built, 2026-10-11/12**

`lib/actions/adMandateLifecycle.js`'s `transitionAdMandateLifecycle` is the one implementation behind every way to stop a mandate:
- **Manual, always available**: CLI (`proposals suspend-mandate`/`revoke-mandate`), or a one-click "Suspend"/"Revoke" form right on the mandate's own proposal page in the web UI (only shown while `currentAdMandateStatus` reports it's actually live).
- **Automatic**: the circuit breaker's auto-suspend path, triggered by either a `pause_on_metric_degradation` breach or - the literal "spend more than $X/day" case - a `max_daily_spend_usd`/`max_monthly_spend_usd` breach (section 5, Phase 3), tagged with the distinct `ad-mandate.auto-suspended` event type so the log always shows a transition wasn't a human.

All paths re-derive the mandate's live status inside the same event-log write lock `autoDecideUnderMandate` uses, so pulling it mid-cycle is guaranteed to stop autonomous decisions on the very next check, never racing a decision that's already in flight.

**What the kill switch does *not* do, and why that matters:** every path above only ever flips `ad_mandate.status` in e3d-corp's own event log. That status is consulted by `autoDecideUnderMandate` (stops commissioning new creative) and nothing else, because nothing else exists yet - there is no Meta-write executor (Phase 4, not authorized). Suspending or revoking a mandate today cannot pause a real Meta campaign's budget or stop real ad delivery, because this system has never been able to start either: its Meta token is `ads_read`-scoped, read-only, by design. If FutCo's real, human-managed Meta campaigns are overspending right now, the only lever that actually touches real money is Meta's own campaign/ad-set budget controls in Ads Manager, used directly - completely outside this system. This system's kill switch becomes a real spend-stopping lever only if/when Phase 4 ships, which is exactly why Phase 4 needs its own explicit, separate authorization rather than being treated as a natural extension of Phases 1-3.

## 7. Dependency on outcome attribution

`max_cac_usd` (cost per *acquisition*, not just cost per lead) only means anything once Stripe revenue is actually attributed to a campaign — which, per the manifesto, requires a product's checkout flow to stamp `metadata.correlationId` on the Stripe object, still unbuilt. Until then, mandates should constrain on `max_cpl_usd` (ad-platform metrics only, already live) and treat `max_cac_usd` as unset.

## 8. Non-goals

- No autonomous real-money spend in Phases 1-3 — `paper_only_creative` stays hard-true.
- No mandate, ever, permitted to exceed `AD_RISK_POLICY`'s hard ceiling — tightening only, same invariant as `capital_mandate`.
- No fabricated budget numbers — `AD_RISK_POLICY`'s values are a human decision, not an engineering one.
- No autonomous mandate *creation* in this spec — a human still proposes and approves each `ad_mandate`; only the routine decisions *inside* an approved mandate become autonomous.
- Phase 4 is out of scope until separately authorized.

## 9. What's left — all human inputs, not engineering

Every mechanism Phases 1-3 describe is built and tested (230/230 e3d-corp tests). The loop does not yet run for real on FutCo's actual Meta account, and every reason why is a deliberate human decision this system is designed to require, not a missing feature:

1. **`adRiskPolicy` is unset on the real `futco` instance.** No `ad_mandate` can activate without it (`activateAdMandate` fails closed) - a human who owns the real ad budget has to set `max_daily_spend_usd`/`max_monthly_spend_usd` to real numbers.
2. **`research.meta.campaigns[].product` is unset on the real instance.** The circuit breaker (Phase 3) and the ad-performance Diagnose trigger both need it to resolve which campaigns a product covers; until someone who knows FutCo's actual campaign-to-product mapping fills it in, both report "insufficient data" rather than guessing.
3. **No `ad_mandate` has ever been proposed or approved.** By design (section 8) - a human has to author one, citing real `thesis_refs`, before any of Phase 2's autonomy has anything to act on.
4. **Phase 4 remains categorically unauthorized** (section 5, section 8) - nothing above launches an ad or moves a dollar, and the kill switch (section 6) only ever stops *this system's own* behavior, never real Meta spend.

**Resolved, 2026-10-12**: every ops script this spec describes, plus the pre-existing `run-oppscan-fitsignal.sh` (built earlier, never scheduled) and the previously-nonexistent `run-discover.sh`/`run-pursue.sh` wrappers for `bin/e3d-corp run`/`pursue` (found to have real, populated config but no wrapper at all), are now live on the futco crontab, offset in dependency order (evidence polls → diagnose/promotion → draft/propose/decide → health check → digest/anchor).

## Round 1 -- anthropic-api

VERDICT: (b) Approve with specific required changes. Phases 1-3 can proceed to the human-input steps in §9, and Phase 4 stays unauthorized. I could not read the repo, so every repo-specific claim below is [unverified] and rests on the spec's own text.

KEY REASONS:
- **Risks, ranked:**
  1. **False assurance from the spend-ceiling kill switch (§5 Phase 3, §6).** A ceiling breach only flips `ad_mandate.status`, and the Meta token is read-only. The spec says this itself, but the name "spend-ceiling kill switch" invites someone to rely on it for real money. The §5 text that the check is "always on and never configurable away" also conflicts with the shared `autoSuspendEnabled` flag, which defaults to observe-only.
  2. **The health check fails open (§5 Phase 3, §9.2).** Product-scoped mandates return "insufficient data" until the campaign-to-product mapping is filled in. That outcome suspends nothing and, as described, alerts no one. The Diagnose trigger has the same blind spot.
  3. **Autonomous chain with no volume or cost cap (§5 Phase 2).** Pursuing opportunity → brief → proposal → auto-decide → commission has no per-mandate or per-day limit. The spend ceilings bound ad dollars, not commissioning volume or creative-production cost. "No human click anywhere" also looks overstated, because the spec never says what moves an opportunity to "pursuing".
- **Missing or contradicted:** §4 says `AD_RISK_POLICY` is a code constant changed only by a human PR. §9.1 and the Diagnose section call it instance config (`adRiskPolicy`, "unset on the real futco instance"). Those are different trust models, and the spec must say which one is real. Smaller inconsistency: the header says 239 tests pass and §9 says 230.
- **Smallest change for the biggest risk:** make any spend-ceiling or degradation breach, and any "insufficient data" result, send an out-of-band alert to a named human. This must happen regardless of `autoSuspendEnabled`. Label the status flip "does not stop Meta spend" in the web UI and in the event text.

ASSUMPTIONS THAT CARRY THE ANSWER:
- The spec's account of its own limits is accurate: the token is `ads_read` only and no Meta-write executor exists. If a write path exists, risk 1 becomes a real-money risk and the verdict should become (c).
- A human actually reviews the `breach-observed` events during the observe-only period. Nothing in the spec guarantees that.
- The "pursuing" transition is human-driven. If it is automated, risk 3 gets worse.

WHAT WOULD CHANGE MY ANSWER: Grep for any Meta write call or `ads_management` use outside `lib/authority/policy.js`, and for any code path that sets an opportunity to "pursuing" without a human. A write path would change the verdict to (c). An automated "pursuing" transition would raise risk 3.

RECOMMENDED NEXT ACTION: Have the FutCo budget owner set real `adRiskPolicy` values and the campaign-to-product mapping, and resolve the §4 vs §9 contradiction. Add the out-of-band breach and insufficient-data alert. Run observe-only (`autoSuspendEnabled` false) for a defined period, reviewing breach events. Do not authorize Phase 4 until that period is clean.

## Round 1 -- openai-api

I cannot read the repository here; repo-specific implementation claims are [unverified].

VERDICT: (c) hold until named gaps are closed. Do not authorize Phase 4 or any real-money autonomy until the hard-budget numbers, campaign/product mapping, and Meta-write safety model are explicitly reviewed and tested.

KEY REASONS:
- **Risk 1 — real-money overspend / ineffective kill switch** from sections 5–6. The spec says the kill switch only changes internal mandate status and cannot stop real Meta delivery today; Phase 4 would add real Meta writes but does not yet specify atomic pre-write checks, post-write reconciliation, Meta-side caps, or rollback behavior. [unverified]
- **Risk 2 — ambiguous campaign-to-product mapping** from sections 5 and 9. `allowed_campaign_ids: null` depends on `research.meta.campaigns[].product`, which is currently unset, so health checks and Diagnose signals report insufficient data rather than enforce product-scoped controls. [unverified]
- **Risk 3 — broad credential / privilege risk** from section 5 Phase 4. The spec notes a credential with `ads_management` and other broad scopes; that increases blast radius if Phase 4 is enabled incorrectly or if executor logic has a bug. [unverified]
- Missing/contradicted item: section 5 says the Meta credential has `ads_management` and broad scopes, while section 6 says the Meta token is `ads_read`-scoped, read-only. That must be reconciled before relying on the safety boundary. [unverified]

ASSUMPTIONS THAT CARRY THE ANSWER:
- Phases 1–3 truly do not launch ads, change budgets, or spend money; they only automate creative/proposal flow and observe/suspend internal mandates. [unverified]
- `activateAdMandate` fails closed when `adRiskPolicy` is unset, and no active mandate exists yet. [unverified]
- Phase 4 is the “next phase” under consideration, not merely activation of the already-built Phase 2/3 cron jobs.

WHAT WOULD CHANGE MY ANSWER: A reviewed Phase 4 design/test showing least-privilege Meta credentials, real `AD_RISK_POLICY` values, campaign-product mapping, mandatory Meta-side spend caps, pre-write ceiling checks, post-write spend reconciliation, and a kill switch that stops or reduces actual Meta delivery.

Recommended next action: reconcile the Meta credential/scope contradiction and require a Phase 4 safety checklist before any Meta-write executor is authorized.

## Round 1 -- grok-build

The spec contradicts itself on the Meta token and on what a spend ceiling actually stops. I'll check those two claims in the repo before giving a verdict.VERDICT: (b) Approve with specific required changes. Phases 1–3 are a sound paper-creative loop and Phase 4 stays unauthorized. A budget owner must not complete section 9 until the spec stops calling a local status flip a spend stop.

KEY REASONS:
- Risk 1, sections 4, 5 (Phase 3), and 6. A `max_daily_spend_usd` or `max_monthly_spend_usd` breach suspends the mandate and stops new `commission-creative`. Live Meta campaigns keep delivering. Section 5 calls `evaluateSpendCeilings` the literal answer to overspending, section 4 calls that ceiling non-bypassable, and section 9 asks a human to enter the real numbers. Section 6 explains the gap by saying the token is `ads_read`-only. Section 5 says that same credential already has `ads_management` and broader scopes. The companion manifesto records that 2026-10-11 introspection [read: docs/futco-ad-outcome-loop-manifesto.md]. The fence that blocks spend is the missing write executor [unverified in e3d-corp].
- Risk 2, section 5 Phases 2–3 and section 9. `autoDecideUnderMandate` runs only when `allowed_campaign_ids` is null. That product-wide shape is the one the health check marks "insufficient data" until `research.meta.campaigns[].product` is set on `hvac_v3` and `free_v2`. The futco cron is already live. `autoSuspendEnabled` defaults to false, and section 9 never lists turning it on.
- Risk 3, sections 3, 4, and 7. Every numeric ceiling must be `<=` the matching `AD_RISK_POLICY` value, but the policy lists only daily spend, monthly spend, and `max_active_mandates`. `max_cpl_usd` and `max_cac_usd` have no baseline, null CPL means no gate, and Phase 3 never evaluates them. Three mandates can each sit at the full daily cap. The spec never says whether summed spend is shared or split by product.
- Contradicted in-spec: section 6’s read-only token versus section 5’s `ads_management` confirmation. The header says 239/239 tests; section 9 still says 230/230. Section 4 puts the ceiling in a PR-only constant; section 9 puts it in futco instance config.

Smallest change: in section 5 Phase 3, replace “the literal answer to what happens if we spend more than $X/day” with “a breach suspends this mandate and stops new commission-creative; Meta delivery keeps running.”

ASSUMPTIONS THAT CARRY THE ANSWER:
- The decision on the table is section 9 go-live for Phases 1–3. Phase 4 remains unauthorized.
- `commission-creative` spends no money, as sections 2 and 8 state.
- No current cron job writes to Meta [unverified].

WHAT WOULD CHANGE MY ANSWER: A fresh token introspection showing only `ads_read`, plus a test that `activateAdMandate` refuses `allowed_campaign_ids: null` while any allowed product lacks `campaign.product`. A Meta write call reachable from the futco cron would move this to (c).

Next action: Patch the section 5 ceiling sentence and the section 6 token sentence so both match the manifesto, add that activation fail-closed, then re-review before anyone sets `adRiskPolicy` or approves a mandate.

## Round 2 -- anthropic-api

**1. STEELMAN.** The strongest opposing position is openai's (c). The spec says the same Meta credential is both read-only and confirmed to carry `ads_management`. Its "spend-ceiling kill switch" only flips an internal status flag. No real budget numbers or campaign-to-product mapping exist. Going live on the cron before those are settled means nobody can say what actually bounds real money, so the review should hold until they are.

**2. CHECK.** The claim that hurts me most is openai's: "section 5 says the Meta credential has `ads_management` and broad scopes". It is TRUE as a reading of the spec. §5 Phase 4 says "a credential already confirmed to carry `ads_management`", while §6 says the token is "`ads_read`-scoped, read-only, by design." Both cannot describe the same token. Which one is accurate is UNVERIFIABLE from here. My last answer took §6 at face value and listed the contradiction only as a hypothetical, so that was a gap. It matters because "no write path" currently rests on the absence of an executor, not on the credential's scope. One bug or one future PR would close that gap.

**3. HOLD OR REVISE.** I keep (b), with one revision. Phases 1–3 write nothing to Meta by the spec's own account, so holding them adds little safety. The cron is already live and the only autonomous output is a creative direction. But the token contradiction moves up my list. It becomes required change #1, ahead of the alert fix I previously led with.

My revised smallest change for the biggest risk has two parts:
- Run a fresh token introspection, and record the result in the spec.
- If the token carries `ads_management`, rotate to an `ads_read`-only token before any `ad_mandate` is approved. That turns "the fence is a missing executor" into "the fence is the credential."

The out-of-band alert on breach and insufficient-data results stays as the second required change. It is still needed because the status flip stops no real spend.

The sentence that shifted my emphasis is grok's: "The fence that blocks spend is the missing write executor." I had treated that as settled, and it should not be.

My remaining required changes are unchanged:
- Decide whether `AD_RISK_POLICY` is a code constant (§4) or instance config (§9.1).
- Reword the "literal answer to what happens if we spend more than $X/day" sentence so it says Meta delivery keeps running.
- Make activation refuse `allowed_campaign_ids: null` while any allowed product lacks a campaign mapping.

**4. WHAT WOULD CHANGE MY MIND.** If token introspection shows `ads_management` on the token the futco cron uses, and any code path outside `lib/authority/policy.js` can reach a Meta write call, I move to (c). A clean `ads_read`-only introspection, with a grep showing no write call, would raise my confidence in (b).

ACTION: Run token introspection on the credential the futco cron uses, record the scopes in the spec, and rotate to `ads_read`-only if `ads_management` is present, before anyone approves an `ad_mandate`.
AGREES_WITH: grok-build
CONFIDENCE: medium

[derived by e3d-debate from ACTION / AGREES_WITH]
POSITION: Run token introspection on the credential the futco cron uses, record the scopes in the spec, and rotate to `ads_read`-only if `ads_management` is present, before anyone approves an `ad_mandate`.
status: revise

## Round 2 -- openai-api

STEELMAN: The strongest approve-with-changes position is that this spec authorizes only Phases 1–3, which automate creative/proposal handling but do not launch ads, change budgets, or spend real money. Because Phase 4 is explicitly excluded, the right response is to fix misleading wording and config gaps without blocking the already-bounded non-spend loop.

CHECK: TRUE from the spec: “Phase 4 stays unauthorized.” That weakens my prior hold position because the most severe real-money execution risks are not actually authorized here.

HOLD OR REVISE: I revise from (c) hold to (b) approve with specific required changes for Phases 1–3 only. The sentence that changed my mind most was grok-build’s: “Phases 1–3 are a sound paper-creative loop and Phase 4 stays unauthorized.”

Required changes remain: reconcile the Meta token/scope contradiction, stop describing the spend-ceiling suspension as if it stops Meta delivery, clarify whether `AD_RISK_POLICY` is code or instance config, and add out-of-band alerts for breaches and insufficient-data states before any mandate is activated.

WHAT WOULD CHANGE MY MIND: A reachable futco cron path or executor that writes to Meta—campaign launch, budget change, pause, or ad-set modification—without a separately reviewed Phase 4 safety design would move me back to (c) hold.

ACTION: Patch the spec contradictions and warning language, add breach/insufficient-data alerts, and require re-review before activating the first mandate.
AGREES_WITH: anthropic-api, grok-build
CONFIDENCE: medium

[derived by e3d-debate from ACTION / AGREES_WITH]
POSITION: Patch the spec contradictions and warning language, add breach/insufficient-data alerts, and require re-review before activating the first mandate.
status: approved

## Round 2 -- grok-build

The claim that would move this from a wording fix to a hold is whether anything on the live path can write to Meta. I'll check that against the repo before answering.STEELMAN: The spec is the document a person will use to authorize the next step, and it asserts both that no Meta-write executor exists and that the live token is read-only. Holding every authorization until the real scopes, the campaign mapping, and a tested write-safety model are on the page is what keeps section 9 from being read as permission to approach real money on an unsettled boundary.

CHECK: FALSE. The claim is "the token is `ads_read` only and no Meta-write executor exists." `setMetaCampaignStatus` in `lib/research/metaCampaignControl.js` POSTs `ACTIVE` or `PAUSED` to `graph.facebook.com`, and `lib/cli.js` registers `changeMetaCampaignStatus`. The companion manifesto records that `META_ADS_READ_TOKEN` carries `ads_management`. That POST is absent from `ops/`. `autoDecideUnderMandate` allowlists only `commission-creative` and requires a separate human `confirmAndExecute` at `FINANCIAL_ACTION` for the status change.

HOLD OR REVISE: Verdict stays (b). Phases 1–3 can proceed only after the spec is corrected, and autonomous spend stays unauthorized. The sentence that changed is my own: the pause/start executor is already in the tree. Sections 5 and 6 are false where they say there is no executor and that the token is read-only by design. A `max_daily_spend_usd` or `max_monthly_spend_usd` breach still only flips `ad_mandate.status` and stops new `commission-creative`. Live Meta delivery continues, and the kill switch never calls `setMetaCampaignStatus`. I keep (b) because the futco cron cannot reach that POST.

WHAT WOULD CHANGE MY MIND: A crontab line or health-check path that calls `setMetaCampaignStatus` or `changeMetaCampaignStatus` without a separate human confirm.

ACTION: Rewrite sections 5 and 6 to match `metaCampaignControl.js` and the 2026-10-11 token introspection, and leave `adRiskPolicy` unset until that rewrite is reviewed.
AGREES_WITH: none
CONFIDENCE: high

[derived by e3d-debate from ACTION / AGREES_WITH]
POSITION: Rewrite sections 5 and 6 to match `metaCampaignControl.js` and the 2026-10-11 token introspection, and leave `adRiskPolicy` unset until that rewrite is reviewed.
status: revise


## Synthesis (anthropic-api)

FINAL ANSWER: Verdict (b), approve with specific required changes, applying to Phases 1-3 only. Phase 4 stays unauthorized.

**Risks, ranked:**
1. The "spend-ceiling kill switch" only flips `ad_mandate.status` and stops new commission-creative proposals. It does not stop Meta delivery (§5 Phase 3, §6). The spec also describes the ceiling check as "the literal answer" to overspend, and it still runs under the observe-only default.
2. The Meta credential boundary is unsettled (§5 Phase 4 vs §6). One section says the token carries `ads_management`, the other says it is read-only. Grok-build reports that `setMetaCampaignStatus` already exists in the repo. This is unverified, and the only fence is the human-confirm step, not the credential.
3. The health check and Diagnose trigger fail open on "insufficient data" until campaign-to-product mapping is set (§5 Phase 3, §9.2). A mandate with `allowed_campaign_ids: null` can be auto-decided while nothing alerts a human.

**Contradicted or missing:** §4 says `AD_RISK_POLICY` is a PR-only code constant, while §9.1 treats `adRiskPolicy` as unset instance config. Also, §6 says there is no write executor, but one reportedly exists. The test count also differs (239 in the header vs 230 in §9).

**Smallest change:** Rewrite the §5 and §6 sentences to say a breach suspends the mandate and stops new commission-creative, while Meta delivery keeps running. Add that the token's scopes were introspected and recorded.

**Next action:** Introspect the token's scopes, correct §§4-6 to match the code, and add an out-of-band alert for breach and insufficient-data states. Only then should the budget owner set `adRiskPolicy`.

CONSENSUS: majority

DISSENT: Anthropic and OpenAI treat the token/executor contradiction as unverified, while grok-build says it is confirmed in the repo. They also differ on whether a reachable Meta write path would move the verdict to (c).
