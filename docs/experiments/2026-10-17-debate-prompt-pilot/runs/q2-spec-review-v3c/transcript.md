# Debate

**Prompt version:** v3c

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

**VERDICT:** (c) Hold until named gaps are closed. Phases 1-3 are reasonably built, but the spec cannot be authorized to run for real, or to lead toward Phase 4, while its safety controls are blind or contradictory. I could not read the repo, so every repo-specific claim below is [unverified].

**KEY REASONS:**
- **Risk 1 (§5 Phase 3, §6, §9.2):** The circuit breaker cannot evaluate the mandates that Phase 2 requires. Phase 2 only auto-decides when `allowed_campaign_ids` is null, but the health check returns "insufficient data" for exactly those product-scoped mandates until the campaign→product mapping exists. Nothing says "insufficient data" raises an alert, so the spend-ceiling and degradation protections could be silently absent. Separately, the kill switch only flips status in the event log and cannot touch real Meta spend (§6). `max_daily_spend_usd` therefore reads like a control that doesn't exist yet.
- **Risk 2 (§4, §9.1):** The hard ceiling is ambiguous and unset. §4 says `AD_RISK_POLICY` is a constant changed only by a human PR. §9.1 describes `adRiskPolicy` as instance config. Config is a weaker guarantee than code, so a mandate could be validated against a ceiling that isn't the non-bypassable one. No real numbers exist either.
- **Risk 3 (§5 Phase 4, §6):** Phase 4 would put real money behind a credential with broad scopes. It would also be sized against a ceiling nobody has set. §5 explicitly refuses to commit to it, which is right, but nothing gates it other than prose.
- **Missing or contradicted:** §6 says the Meta token is "`ads_read`-scoped, read-only, by design." §5 Phase 4 says the credential is "already confirmed to carry `ads_management` and several other broad scopes." Both cannot be true. If the second is correct, the "cannot start real spend" guarantee in §6 rests on convention, not capability. Smaller inconsistency: the test count is 239 in the header and 230 in §9.
- **Smallest change for Risk 1:** Make `activateAdMandate` fail closed unless the mandate's campaigns resolve to real Meta campaigns through the product mapping. Also make any "insufficient data" health result on an active mandate emit a loud, auditable alert event. This is a small validation change and needs no new executor.

**ASSUMPTIONS THAT CARRY THE ANSWER:**
- "Insufficient data" is a silent log line, not an alert or a block. The spec doesn't say otherwise.
- The §6 and Phase 4 token-scope statements describe the same credential.
- The real FutCo instance has no `adRiskPolicy` or campaign `.product` values, as §9 states.

**WHAT WOULD CHANGE MY ANSWER:** If the live Meta token's granted scopes are checked and are strictly `ads_read`, and the health check demonstrably blocks activation or alerts on unresolvable campaigns, I would move to (b), approve with changes, for running Phases 1-3.

**Recommended next action:** The ad budget owner sets real `adRiskPolicy` numbers and the campaign→product mapping, and someone verifies the token's actual scopes in Meta. Then land the activation-guard change and run the breaker observe-only for a defined period before enabling `autoSuspendEnabled`.

## Round 1 -- openai-api

I cannot read the repository here; repo-specific implementation claims are [unverified].

VERDICT: **(c) hold until named gaps are closed.** Do not authorize Phase 4 or any real-money autonomous action until the policy numbers, product mapping, credential/scope story, and real Meta-side stop mechanism are explicitly resolved.

KEY REASONS:
- **Risk 1 — real-money spend may not be truly bounded once Phase 4 exists** *(sections 5 Phase 4, 6, 4)*: the current kill switch only changes e3d-corp event-log state and does not stop Meta delivery. The spec says this is acceptable because Phase 4 is not authorized, but it means Phase 4 cannot be treated as a simple executor add-on.
- **Risk 2 — spend and degradation checks can be blind for product-scoped mandates** *(sections 5 Phase 3, 9)*: `research.meta.campaigns[].product` is unset, so mandates with `allowed_campaign_ids: null` report insufficient data rather than enforcing health checks. That is the right fail-closed behavior, but it blocks safe operation for product-scoped mandates.
- **Risk 3 — financial limits are undefined** *(sections 4, 9)*: `AD_RISK_POLICY` has no real daily/monthly numbers yet. The design correctly requires human-set ceilings, but without them there is no concrete blast-radius bound.
- **Missing/contradicted item:** section 5 says the Meta credential is confirmed to carry `ads_management` and broad scopes, while section 6 says the token is `ads_read`-scoped, read-only, by design. That must be reconciled before any authorization involving Meta writes.

ASSUMPTIONS THAT CARRY THE ANSWER:
- Phases 1–3 are limited to autonomous creative commissioning and observation/suspension inside e3d-corp, not launching ads or changing budgets.
- The spec facts are authoritative, but implementation claims such as tests passing, locks, cron wiring, and validators are [unverified].
- “Next phase” means Phase 4 or any step that can affect real Meta spend.

WHAT WOULD CHANGE MY ANSWER: A checkable Phase 4 preflight showing: least-privilege Meta write credentials, real `AD_RISK_POLICY` values, completed campaign-to-product mapping, and a tested Meta-side pause/budget-cap action that fires on mandate suspension.

Recommended next action: reconcile the Meta credential contradiction and add one hard Phase 4 gate: **no Meta budget/launch write may run unless Meta-side daily/lifetime caps are already set at or below the active mandate and `AD_RISK_POLICY` ceilings.**

## Round 1 -- grok-build

The spec contradicts itself on the Meta token and on test counts. I'll check those claims in the repo before the verdict.The spec disagrees with itself on token scope and on where the spend ceiling lives. I'll check those two claims in the code before ranking the risks.VERDICT: (c) Hold until named gaps are closed. Do not authorize section 9's go-live or Phase 4 on this text. Phases 1–3 can stay built; they are not yet a bounded spend system.

KEY REASONS:
- Risk 1, sections 5 and 6. Section 5 says the live credential already carries `ads_management` and broader scopes. Section 6 says the token is `ads_read`-only by design and that this system cannot start real delivery. The companion manifesto records a 2026-10-11 introspection: `META_ADS_READ_TOKEN` carries `ads_management` [read: docs/futco-ad-outcome-loop-manifesto.md]. The futco cron is already live (status, section 9). The section 6 kill switch only changes `ad_mandate.status` in the event log, so Meta delivery has no stop inside this system. A write-capable token is what turns "no executor yet" into a spend.
- Risk 2, sections 4, 5, and 9. `max_daily_spend_usd` and `max_monthly_spend_usd` compare observed Meta spend and can suspend the mandate. They never write a Meta budget. Auto-suspend defaults off (section 5). Phase 2 auto-decides only when `allowed_campaign_ids` is null, and that is the scope the health check cannot score until `research.meta.campaigns[].product` is filled. The numbers section 9 asks for do not cap the account.
- Risk 3, section 5 Phase 2. After one human mandate approval, the live chain runs from a pursuing opportunity through brief, proposal, auto-decision, and an e3d-creative commission. The campaign allowlist cannot bind that path. The diagnose trigger in the same section still says a human decides whether a prospect is pursued, while section 9 schedules pursue on the same cron.
- Contradiction: section 6's "ads_read-scoped, read-only, by design" contradicts section 5 and the manifesto. Section 4 also puts `AD_RISK_POLICY` in code, changed only by a human PR, while section 9 puts `adRiskPolicy` on the futco instance. Status says 239/239 tests; section 9 says 230/230. Smallest change for the biggest risk: remove `ads_management` and every non-read scope from the token the futco cron loads, and replace the section 6 read-only sentence with that fresh scope list. Next action: hold. The token owner pastes a current Meta debug of the cron credential into the spec and rotates it down to `ads_read`. Leave `adRiskPolicy` unset and leave Phase 4 unauthorized in that step.

ASSUMPTIONS THAT CARRY THE ANSWER:
- The 2026-10-11 introspection still names the token this cron uses. I did not call Meta debug myself [read: docs/futco-ad-outcome-loop-manifesto.md].
- "Next phase" means authorizing real FutCo running (section 9) or Phase 4.
- e3d-corp behavior past that manifesto line is [unverified]. The verdict uses the spec's own words plus that file.

WHAT WOULD CHANGE MY ANSWER: A current debug of the credential the futco cron loads showing no `ads_management` and no other write scope. I would then move to (b) and require only that the status line and section 9 say those spend figures suspend creative commissioning and leave Meta delivery untouched.

## Round 2 -- anthropic-api

**1. STEELMAN.** The position I disagree with most is grok-build's: the biggest risk is the live credential, not the monitoring gaps. In its words: every control in this spec is event-log state, and a write-capable token is the only thing that could turn "no executor yet" into real spend. Rotating the token down to `ads_read` is a cheap, checkable change that makes §6's "cannot start real delivery" true by capability rather than by convention.

**2. CHECK.** The claim that hurts my ranking most is: "`META_ADS_READ_TOKEN` carries `ads_management`". My Risk 1 was the blind circuit breaker. If the cron token can write, that outranks it.
- **Verdict:** UNVERIFIABLE for the manifesto citation, since I can't read the repo.
- **What I can see:** §5 Phase 4 says independently that the credential is "already confirmed to carry `ads_management`", so the spec supports the claim.
- **What I can't tell:** whether the token the futco cron loads is that same credential.

**3. HOLD OR REVISE.** I'm keeping (c) but reordering the risks. The sentence that changed my mind is grok-build's point that the cron is already live (status line, §9).

- **Risk 1 (§5 Phase 4, §6):** The write-scoped credential contradicts §6's "read-only, by design." The only barrier to real spend is that no executor exists. That is a code-absence guarantee, not a credential guarantee, and it is the only path to real money.
- **Risk 2 (§5 Phase 3, §9.2):** The breaker is blind for product-scoped mandates. Phase 2 auto-decides only when `allowed_campaign_ids` is null, and that is exactly the case the breaker reports "insufficient data" for. Because Phases 1-3 spend nothing, this is a latent risk, but it would become live the moment Phase 4 relies on it.
- **Risk 3 (§4 vs §9.1):** The ceiling is ambiguous. It is a code constant in §4 and instance config in §9.1, and no values are set.

**Contradictions I now count:**
- The token scope (§5 vs §6).
- The ceiling location (§4 vs §9.1).
- 239 tests in the status line vs 230 in §9.
- §5 says a human decides whether a diagnose prospect is pursued, while §9 schedules `pursue` on cron. This is grok-build's catch; I hadn't noticed it, and I can't verify it beyond the spec text.

My earlier smallest change (an activation guard plus an alert on "insufficient data") is still good, but it addresses my old Risk 1. For the new biggest risk, the smallest change is to rotate the futco cron credential to `ads_read` only, and to paste a fresh Meta debug of its scopes into §6. It needs no code change, and a Phase 4 executor would then need a separate, deliberately issued credential.

**4. WHAT WOULD CHANGE MY MIND.** A current Meta debug-token output for the exact credential the futco cron loads, showing only `ads_read` (plus `read_insights`-type read scopes) and no `ads_management`. With that, and the activation guard landing, I'd move to (b) for running Phases 1-3.

ACTION: Have the token owner run Meta's debug_token on the credential the futco cron loads, rotate it to read-only scopes, and paste the result into §6.
AGREES_WITH: grok-build
CONFIDENCE: medium

[derived by e3d-debate from ACTION / AGREES_WITH]
POSITION: Have the token owner run Meta's debug_token on the credential the futco cron loads, rotate it to read-only scopes, and paste the result into §6.
status: revise

## Round 2 -- openai-api

STEELMAN: The strongest narrower-approval position is that Phases 1–3 still do not launch ads, change budgets, or spend money, so the spec can be approved for non-financial autonomy once the human-owned inputs are supplied. On that view, the mandate validator, live status recheck, event-log kill switch, and explicit Phase 4 exclusion are adequate for creative commissioning, while real Meta spend remains separately gated.

CHECK: TRUE from the spec: “commission-creative proposals carry no campaignId”. If campaign IDs are unavailable at the proposal being auto-approved, then campaign allowlists cannot actually constrain Phase 2 autonomy; only product scoping can.

HOLD OR REVISE: I still believe the verdict is **(c) hold until named gaps are closed**, but I revise the emphasis: the biggest immediate blocker is not just future Phase 4 spend, but the combination of write-capable credential ambiguity, product/campaign mapping gaps, and a Phase 2 path that cannot enforce campaign IDs. The sentence that most changed my weighting was grok-build’s: “The campaign allowlist cannot bind that path.”

WHAT WOULD CHANGE MY MIND: A current credential debug for the exact token loaded by FutCo cron showing no write scopes, plus an activation test proving product-scoped mandates cannot become active unless every covered Meta campaign resolves to exactly one allowed product.

ACTION: Verify and paste the current Meta token scopes for the FutCo cron credential, then rotate it to read-only if any write scope is present.
AGREES_WITH: anthropic-api, grok-build
CONFIDENCE: medium

[derived by e3d-debate from ACTION / AGREES_WITH]
POSITION: Verify and paste the current Meta token scopes for the FutCo cron credential, then rotate it to read-only if any write scope is present.
status: approved

## Round 2 -- grok-build

I'll verify the token-scope and health-check claims in the repo before I lock the verdict.The debate text is in this folder. I'll check the manifesto and the e3d-corp code those claims point at.STEELMAN
Phases 1–3 only commission creative and, at most, mark a mandate suspended. Once the cron token is strictly `ads_read` and an unmapped product mandate cannot activate, the `ads_management` sentence is paperwork, and the built loop can be approved with an activation guard and a loud insufficient-data alert.

CHECK
The claim that would hurt this most is openai-api’s “not launching ads or changing budgets.” FALSE. `setMetaCampaignStatus` POSTs `status=ACTIVE` or `status=PAUSED` to `graph.facebook.com` with `META_ADS_READ_TOKEN` after `proposals confirm` (`lib/actions/metaCampaignChange.js`). The futco CLI registers that executor.

HOLD OR REVISE
I hold (c). Do not authorize section 9 go-live or Phase 4 on this text. No sentence above changed the verdict. The spend path is the registered pause/start executor: section 5 still says nothing writes to Meta, and section 6 still says the token is `ads_read`-only and that every stop only flips `ad_mandate.status`. `transitionAdMandateLifecycle` never calls that POST, so a suspend leaves delivery running, and `changeMetaCampaignStatus` does not read `adRiskPolicy`. Risk 2 is the one anthropic-api named: Phase 2 auto-decides only when `allowed_campaign_ids` is null, and that shape returns `insufficient-campaign-mapping` with no event and no `evaluateSpendCeilings` call. Risk 3: activation checks instance `adRiskPolicy` (`lib/actions/adMandate.js`), while section 4 describes a PR-only constant; the header says 239 tests and section 9 says 230. The manifesto still records that `META_ADS_READ_TOKEN` carries `ads_management` (2026-10-11). I have not repeated that debug today.

WHAT WOULD CHANGE MY MIND
A futco boot showing `meta-campaign-change` has no registered executor, and a current Meta debug of the cron token with no `ads_management` and no other write scope.

ACTION: Unregister the meta-campaign-change executor on the futco CLI until suspend and revoke pause those campaigns through setMetaCampaignStatus, and paste a fresh debug of META_ADS_READ_TOKEN into section 6.
AGREES_WITH: none
CONFIDENCE: high

[derived by e3d-debate from ACTION / AGREES_WITH]
POSITION: Unregister the meta-campaign-change executor on the futco CLI until suspend and revoke pause those campaigns through setMetaCampaignStatus, and paste a fresh debug of META_ADS_READ_TOKEN into section 6.
status: revise


## Synthesis (anthropic-api)

FINAL ANSWER: Verdict (c): hold. Do not authorize go-live or Phase 4 until the token owner runs Meta's debug_token on the exact credential the futco cron loads and rotates it to read-only (`ads_read`) if any write scope shows up. Also confirm whether a `meta-campaign-change` executor is registered. The biggest reason is that §6 ("cannot start real delivery") contradicts §5 and the manifesto, so the "no real spend" guarantee may rest on code absence rather than on the credential. Then fix the other contradictions (§4 vs §9.1 ceiling location, 239 vs 230 tests) and set the real ceiling numbers and the campaign-to-product mapping.

CONSENSUS: majority

DISSENT:
grok-build: Would go further and unregister the `meta-campaign-change` executor on the futco CLI until suspend and revoke actually pause campaigns. Grok-build says a Meta write path already exists and bypasses the mandate controls. | "Unregister the meta-campaign-change executor on the futco CLI until suspend and revoke pause those campaigns through setMetaCampaignStatus"

POSITIONS:
anthropic-api: Run debug_token on the cron credential, rotate it to read-only, and paste the result into §6. | "the smallest change is to rotate the futco cron credential to `ads_read` only"
openai-api: Verify the cron token's scopes and rotate to read-only if any write scope is present. | "Verify and paste the current Meta token scopes for the FutCo cron credential"
grok-build: Unregister the Meta write executor until suspend and revoke pause campaigns, and paste a fresh token debug. | "Unregister the meta-campaign-change executor on the futco CLI until suspend and revoke pause those campaigns through setMetaCampaignStatus"

CLAIMS CHECKED:
- Token scope: §6 says "ads_read-scoped, read-only" and §5 Phase 4 says the credential carries `ads_management`. This is a real contradiction inside the spec, and all three analysts noted it. Grok-build cites the manifesto's 2026-10-11 introspection as showing `ads_management`; the others could not verify this. Not resolvable from the transcript.
- Existing Meta write path: grok-build (round 2) claims `setMetaCampaignStatus` in `lib/actions/metaCampaignChange.js` POSTs ACTIVE/PAUSED to Meta. The spec says "no executor at all behind it". No other analyst could confirm or refute this, so it is not resolvable, but it is serious if true.
- Test counts: the status line says 239/239 and §9 says 230/230. Confirmed from the spec text.
- Ceiling location: §4 says `AD_RISK_POLICY` is a code constant changed only by PR, and §9.1 says `adRiskPolicy` is instance config. Confirmed from the spec text; grok-build also cites `lib/actions/adMandate.js` for the config version, which is unverified.
- Campaign IDs in Phase 2: openai-api checked that commission-creative proposals carry no campaignId, so campaign allowlists cannot constrain Phase 2. Confirmed from the spec text.
- Pursue vs human decision: grok-build says §5 claims a human decides whether a prospect is pursued while §9 schedules `pursue` on cron. This is plausible from the spec but is not confirmed by the others.

OPEN QUESTIONS:
- Does the token the futco cron loads currently carry `ads_management` or other write scopes?
- Is a `meta-campaign-change` executor registered on the futco CLI, and does it respect `adRiskPolicy` or mandate status?
- Is the ceiling a code constant (§4) or instance config (§9.1), and which one does activation actually validate against?
