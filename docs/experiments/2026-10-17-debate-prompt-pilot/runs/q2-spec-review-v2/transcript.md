# Debate

**Prompt version:** v2

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

**1. Verdict: (c) Hold until named gaps are closed.**

Phases 1-3 are reasonable. They fail closed, are auditable, and spend no money. The hold applies to authorizing anything beyond them, especially Phase 4. The spec's own §2, §5 and §6 say the precedent is paper-only, there is no executor, and the controls guard nothing real yet.

**2. Top three risks, ranked**

1. **The kill switch and spend ceiling give false assurance (§5 Phase 3, §6).** The "spend-ceiling kill switch" only flips an internal status that gates creative commissioning. It cannot stop real spend, and §6 admits this. Anyone reading "kill switch built" or "spend-ceiling check always on" could assume protection exists. Autosuspend is also off by default. If Phase 4 ships on this basis, the first real overspend is also the first real test of the mechanism.
2. **The hard ceiling and the campaign-to-product mapping are unset (§4, §9.1, §9.2).** The ceiling is a placeholder, and the mapping is empty on the real instance. Product-scoped mandates return "insufficient data", so the breaker silently provides no protection for exactly the mandates that use `allowed_campaign_ids: null`. Unevaluable must not look the same as healthy.
3. **The autonomous chain has no volume or cost bound (§5 Phase 2).** The chain runs from pursuing opportunity to brief to proposal to auto-decide to commission, scanning all pending proposals against all mandates on cron. The mandate limits only spend, but there is no cap on commissions per day or per mandate. Because Phase 2 is zero-dollar, nothing bounds the commissioning volume or its downstream compute cost. The full cron schedule is already live with no cap.

**3. Contradiction.** §5 Phase 4 says the Meta credential is "confirmed to carry `ads_management` and several other broad scopes." §6 says the token is "`ads_read`-scoped, read-only, by design." Both cannot be true. If the first is true, "this system cannot spend" rests on the absence of code, not on a capability limit.

Smaller inconsistencies:
- The header says 239 tests and §9 says 230.
- §4 puts `AD_RISK_POLICY` in code, changed only by PR. §9 describes `adRiskPolicy` as an unset instance config value. These are different trust models, and the instance config is looser.

**4. Smallest change for risk #1.** Check the token's actual scopes against Meta's debug_token endpoint. If it carries `ads_management`, reissue it as `ads_read` only. Then record "verified read-only token" as a hard precondition for any Phase 4 discussion. Also rename the §6 control to "mandate status suspend", so it doesn't read as a spend limit.

**Load-bearing assumptions**
- Humans still run the real Meta campaigns directly in Ads Manager.
- `activateAdMandate` really does fail closed without a policy, which I haven't verified.

**Recommended next action:** The budget owner reconciles the token scope this week, then supplies the real ceiling numbers and the campaign-to-product mapping. After that, re-review. Phase 4 should not be scoped until the breaker has run in observe-only mode on real data and its signals have been checked against Ads Manager.

## Round 1 -- openai-api

1. **VERDICT: (c) hold until named gaps are closed.**  
   Phases 1–3 look reasonable for non-spending automation, but this spec is not sufficient to authorize autonomous real-money ad spend. The Phase 4 boundary is correctly called out, but the actual spend-control design is not yet specified enough.

2. **Three biggest risks, ranked**

   1. **Spend controls are mostly after-the-fact, not pre-execution** — Sections 4, 5 Phase 3, 6, Phase 4.  
      The hard ceiling and health check detect spend from Meta evidence and can suspend the mandate, but the spec does not yet define a Meta-write executor that checks projected spend before every budget-changing action. For real spend, a post-hoc circuit breaker can still overspend between polls or due to attribution/reporting delay.

   2. **Credential/scope ambiguity around Meta write access** — Sections 5 Phase 4 and 6.  
      Section 5 says the credential is already confirmed to carry `ads_management` and broad scopes. Section 6 says the Meta token is `ads_read`-scoped, read-only, by design. That contradiction is load-bearing: the risk profile is completely different depending on which is true.

   3. **Product-to-campaign mapping is missing, weakening monitoring and suspension** — Sections 5 Phase 3 and 9.  
      Mandates with `allowed_campaign_ids: null` depend on `research.meta.campaigns[].product`, but the real FutCo config lacks it. The health check then reports “insufficient data,” meaning product-scoped mandates cannot be reliably evaluated against campaign spend/performance.

3. **One thing missing or contradicted elsewhere**

   The Meta credential scope is contradicted. Section 5 says Phase 4 would use a credential already carrying `ads_management`; Section 6 says the system’s Meta token is read-only `ads_read` “by design.” Before any spend authorization, the spec must name the actual credential, its scopes, where it is stored, and which executor can use it.

4. **Single smallest change that would reduce the biggest risk**

   Add one explicit Phase 4 gating requirement: **no Meta-write action may execute unless a synchronous pre-write budget check confirms that current Meta spend plus the proposed change cannot exceed both `AD_RISK_POLICY` and the active mandate’s daily/monthly ceilings; otherwise fail closed.**  
   This should be enforced inside the Meta-write executor, not only by the scheduled health check.

**Recommended next action:** do not authorize Phase 4 yet; open a blocking Phase 4 design PR that resolves the Meta credential contradiction and specifies/test-enforces the pre-write spend guard.

## Round 1 -- grok-build

The spec makes strong safety claims. I'll check the ones that decide the verdict against the code and the companion docs before answering.The status block says the live loop is only waiting on human inputs. I'll check the two claims that would make that unsafe: token scope, and whether cron already closes the human gate.**1. Verdict: (c) hold until named gaps are closed.**

Phases 1–3 are a real bounding pattern: mandates only tighten ceilings, `paper_only_creative` stays hard-true, a human still approves each mandate, and Phase 4 is split out. Keep that code. Do not authorize the live loop. The status block and section 9 say the cron is already on and the only leftovers are budget numbers, a product mapping, and a mandate. Filling those in arms the loop on top of a write-capable credential and a ceiling that leaves Meta delivery running.

**2. Three biggest risks**

1. **Write credential under a read-only safety story (sections 5 and 6).** Phase 4 says the credential already carries `ads_management` and other broad scopes. Section 6 says the token is `ads_read`-only by design, and that this is why the system cannot start delivery and why suspend only flips an internal status. The companion manifesto records a 2026-10-11 introspection of `META_ADS_READ_TOKEN` that matches section 5. Suspend, revoke, and the spend check leave live Meta delivery running, and any new caller of that token can start spend.

2. **The spend ceiling does not stop spending, and by default it does not stop the loop (section 5 Phase 3, section 6, status).** `autoSuspendEnabled` defaults to false, so a breach only appends `breach-observed`. With the flag on, suspend stops new `commission-creative` decisions. `autoDecideUnderMandate` checks active status, product, `allowed_campaign_ids === null`, and `paper_only_creative`. It never reads daily or monthly spend, `max_cpl_usd`, or `expires_at`. Section 5 still calls this the answer to spending more than $X/day.

3. **The mandates Phase 2 can act on are the ones Phase 3 cannot measure (section 5, section 9).** Auto-decide fails closed unless `allowed_campaign_ids` is null. The health check then needs `research.meta.campaigns[].product`. On the live instance, `hvac_v3` and `free_v2` have none, so the check returns "insufficient data." Draft, propose, and decide are already on the crontab. The first active mandate can commission creative while the always-on ceiling has no campaign set to enforce.

**3. What is contradicted**

Section 6 says the Meta token is `ads_read`-scoped and read-only by design. Section 5 says that same credential carries `ads_management`. Those two sentences cannot both be the safety premise for a go-ahead.

**4. Smallest change that cuts the biggest risk**

Revoke every scope on the live Meta token except `ads_read`, and make `activateAdMandate` refuse to activate until a scope probe confirms that list.

**Next action:** Hold the mandate, the budget numbers, and Phase 4. Have the token owner revoke the extra scopes and replace the section 6 sentence with the probe result before any `ad_mandate` is proposed.

Assumption: the manifesto's 2026-10-11 introspection is what section 5 means by "already confirmed." I did not re-probe the token in this session.

## Round 2 -- anthropic-api

**Position held: verdict (c).** All three of us reach (c) and name the same scope contradiction (§5 Phase 4 versus §6). The disagreement is about ordering and what to do first.

**Where I update.** Grok has two points I underweighted.
- **Phase 2 auto-decide ignores spend and expiry.** `autoDecideUnderMandate` checks active status, product, null campaign IDs, and `paper_only_creative`. It does not read spend, CPL, or `expires_at`, as far as the spec describes. So §5 calling the spend-ceiling check "the literal answer to spending more than $X/day" overstates it. I rated this under false assurance, but it deserves explicit mention.
- **Phase 2 only acts on null-campaign mandates, which Phase 3 cannot yet measure.** This is sharper than my risk #2. Because cron for draft, propose, and decide is already live, the first approved mandate would run with its ceiling check returning "insufficient data."

I would therefore gate `activateAdMandate` on three things, not just a policy being set:
- a token-scope probe
- a populated campaign-to-product mapping
- the health check returning evaluable, not "insufficient data"

**Where I disagree with openai-api.** Its pre-write synchronous budget guard is a correct Phase 4 requirement, and I would add it as a one-line precondition. But it is not the smallest change for the biggest risk, and its next action ("open a blocking Phase 4 design PR") pulls the wrong way. §5 says Phase 4 needs its own review, a period of clean Phase 2/3 running, and that nothing in Phases 1-3 is a stepping-stone. Designing the executor now, before the credential is reconciled and before the breaker has run on real data, reverses that ordering. A guard inside an executor that does not exist reduces no present risk. The present risk is that "cannot spend" rests on missing code, not on a capability limit.

**Where I disagree with grok-build, mildly.** Revoking all scopes except `ads_read` is the right remedy if the probe confirms the broad scopes. But I would verify first with Meta's debug_token, because neither of us re-probed the token. Grok also says to hold the budget numbers. That is fine as sequencing, but I would not hold the mapping, because it is a harmless read-only config that the observe-only breaker needs.

**Contradiction (unchanged).** §5 says the credential carries `ads_management`; §6 says it is `ads_read` only. The other inconsistencies are minor:
- 239 tests in the header versus 230 in §9.
- `AD_RISK_POLICY` is a code constant in §4 but an instance config in §9.

**Smallest change for the biggest risk.** Probe the token. If it carries write scopes, reissue it as `ads_read` only. Make "verified read-only" a precondition for activating any mandate and for any Phase 4 discussion. Rename the §6 control to "mandate status suspend" so it does not read as a spend limit.

**Next action.** The token owner runs debug_token this week and reissues the token as `ads_read` if needed. Then the budget owner sets the ceiling and the mapping. Run the breaker in observe-only mode, and compare its output with Ads Manager before any mandate is activated. Phase 4 design waits until that is done.

POSITION: Hold (c): verify and reduce the Meta token to read-only first, gate mandate activation on the scope probe and an evaluable breaker, run observe-only on real data, and defer Phase 4 design until then.
status: revise

## Round 2 -- openai-api

My prior position mostly holds, with one refinement: the **credential contradiction is the immediate blocker**, while the **lack of synchronous pre-write spend enforcement is the core Phase 4 design blocker**. Both must be closed before any real-money autonomy.

**Verdict remains: (c) hold until named gaps are closed.**

I agree with anthropic-api and grok-build on the main outcome: do not authorize the live spend phase. The spec is acceptable as a non-spending creative-automation scaffold, but not as a basis for autonomous financial action.

Where I think the other answers are strongest:
- Both correctly identify the `ads_management` vs `ads_read` contradiction as load-bearing. If the token is write-capable, the spec’s “cannot spend by design” claim is false or at least incomplete.
- Both correctly flag that the “kill switch” does not stop real Meta delivery today. It stops internal mandate-driven actions only.
- Both correctly treat unset `adRiskPolicy` and missing campaign/product mapping as blockers for real operation.

Where I differ:
- Anthropic’s “false assurance from kill switch” is a good framing, but its proposed smallest change—token scope verification and renaming the control—reduces confusion more than it solves the eventual spend-control problem. For Phase 4, a write token will necessarily exist somewhere; the design must say how every write is budget-guarded before execution.
- Grok’s claim that “filling those in arms the loop on top of a write-capable credential” may overstate the current spec if there is truly no Meta-write executor. Filling the human inputs appears to arm autonomous creative commissioning, not ad launch or budget mutation. The concern is still valid as a latent capability/safety-boundary problem, but the spec’s own Phase 4 separation matters.
- Grok’s proposed scope probe on `activateAdMandate` is useful for Phases 1–3, but would be insufficient for Phase 4 unless paired with executor-level pre-write checks.

My ranked risks now:

1. **No specified pre-execution spend guard for Phase 4** — §§4, 5 Phase 3/4, 6. The ceiling is validated at mandate creation and monitored after the fact, but no executor-level rule prevents a budget-changing write that would exceed daily/monthly limits.

2. **Contradictory Meta credential safety premise** — §§5, 6. The spec cannot simultaneously rely on a read-only token and acknowledge an `ads_management` credential.

3. **Product-scoped monitoring is not enforceable yet** — §§5 Phase 3, 9. `allowed_campaign_ids: null` depends on campaign/product mapping that is absent on the real instance, causing “insufficient data.”

Missing/contradicted item: the Meta credential scope.

Smallest change to reduce the biggest risk: add a mandatory Phase 4 executor invariant: before every Meta write, synchronously compute current spend plus proposed effect against both `AD_RISK_POLICY` and active mandate ceilings, and fail closed.

Recommended next action: open a blocking Phase 4 design PR resolving credential scope and adding tested pre-write budget enforcement before any spend authorization.

POSITION: Hold until the credential contradiction, campaign mapping, real budget ceilings, and Phase 4 pre-write spend guard are closed.
status: revise

## Round 2 -- grok-build

The three answers agree on a hold, but they would authorize different next steps. I'll check the token-scope and ceiling claims those steps depend on.**1. Verdict: (c) hold.** Unchanged. Keep Phases 1–3. Do not authorize the live loop or Phase 4.

Checked this round: `activateAdMandate` does fail closed without `instanceConfig.adRiskPolicy`. `evaluateMandateCoverage` ignores spend, CPL, and `expires_at`. The 2026-10-11 manifesto still says `META_ADS_READ_TOKEN` carries `ads_management`. An insufficient-data health result is its own outcome kind, appends no event, and does not block auto-decide.

**2. Risks**

1. Write-capable token under a read-only story (§5 Phase 4, §6). The manifesto matches §5. §6’s “`ads_read` by design” is the sentence a go-ahead would trust, and that record says it is false. Suspend only flips an internal status.
2. The ceiling does not stop spend, and by default it does not stop the loop (§5 Phase 3, §6). `autoSuspendEnabled` acts only when exactly `true`; otherwise a breach writes `breach-observed`. With the flag on, suspend stops new creative commissions, not Meta delivery. §5 still calls this the answer to spending more than $X/day.
3. Mandates Phase 2 can run are the ones Phase 3 cannot price (§5, §9). Coverage requires `allowed_campaign_ids === null`. Those need `campaigns[].product`, unset on `hvac_v3` and `free_v2`, so the check returns insufficient data while cron can still commission.

**3. Contradiction.** §6 says the token is read-only by design. §5 and the manifesto say it carries `ads_management`. Both cannot be the safety premise.

§4’s PR-only `AD_RISK_POLICY` constant versus §9’s instance `adRiskPolicy` is a smaller contradiction. The code implements the looser one. That was underweighted last round. It still sits below the token: there is no writer.

**4. Smallest change.** Strip the live token to `ads_read`, and make `activateAdMandate` refuse until a scope probe confirms that list.

OpenAI’s pre-write guard is the right rule for a future executor. No executor exists, so that sentence does not shrink a token that can already write. Anthropic’s `debug_token` check is the probe half; “reissue if `ads_management`” is optional after a document that already says the scope is there. Renaming the kill switch fixes a label and leaves the scopes. Setting ceiling numbers after a token meeting is the step that lets `activateAdMandate` succeed.

**Next action:** Hold the budget numbers, the mandate, and Phase 4. The token owner revokes every scope except `ads_read` and replaces the §6 sentence with the probe result before anyone proposes an `ad_mandate`.

POSITION: Hold the live loop and Phase 4 until the Meta token is stripped to ads_read and section 6 is rewritten from a scope probe, and do not set budget numbers or open a Phase 4 design PR before that.
status: revise


## Synthesis (anthropic-api)

FINAL ANSWER: Verdict (c), hold until named gaps are closed. Phases 1-3 are sound as non-spending scaffolding, but the live loop and Phase 4 should not proceed. The ranked risks are:
1. A write-capable Meta token sits under a "read-only by design" safety story (§5 Phase 4 contradicts §6).
2. The spend-ceiling "kill switch" only flips an internal status, and auto-suspend is off by default, so it cannot stop real spend or even creative commissioning on a spend breach (§5 Phase 3, §6).
3. Auto-decide only acts on null-campaign mandates, which the breaker cannot evaluate because the campaign-to-product mapping is unset, so cron could commission creative while the health check returns "insufficient data" (§5, §9).

The contradiction is the token scope (§5 says `ads_management`, §6 says `ads_read` only). The smallest change is to probe the token with Meta's debug_token, strip it to `ads_read`, and make `activateAdMandate` refuse to activate until that probe passes. The recommended next action is for the token owner to run the probe and reissue the token as `ads_read` and rewrite §6 from the result. Only then should the budget owner set the real ceilings and the mapping, and the breaker should run observe-only against Ads Manager before any mandate is proposed.

CONSENSUS: majority

DISSENT: openai-api ranks the missing synchronous pre-write spend guard for Phase 4 as the top risk and wants a Phase 4 design PR opened now. The other two say to fix the token first and defer Phase 4 design until the breaker has run cleanly on real data.
