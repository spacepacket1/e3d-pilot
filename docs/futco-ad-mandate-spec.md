# FutCo Ad Mandate: Bounded Autonomous Ad Spend

**Status:** Phases 1-3 built and tested, 2026-10-11 (230/230 e3d-corp tests passing). What remains before the loop runs for real is listed in section 9 - it is entirely human inputs (real numbers, a product mapping, a mandate, cron registration), not engineering work. Phase 4 requires separate, explicit authorization before implementation — see Non-goals.
**Date:** 2026-10-11
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
A scheduled job (`ops/reports/checkAdMandateHealth.js`, logic in `lib/health/adMandateHealth.js` + `lib/health/runAdMandateHealthCheck.js`) evaluates each active mandate's `pause_on_metric_degradation` rules against the latest Meta-insights evidence already being polled (summed-ratio aggregation over a current vs. prior window of the same length; refuses to evaluate a metric name it has no real evaluator for rather than guessing). Ships in the two steps the spec asked for, both implemented, switched by one config flag:
1. **Observe-only (the default - `adMandateHealthCheck.autoSuspendEnabled` absent or `false`)**: appends an auditable `ad-mandate.health-check.breach-observed` event and logs the breach, never acts — lets a human confirm the degradation signal is trustworthy before it can take an action.
2. **Enabled (`adMandateHealthCheck.autoSuspendEnabled: true`)**: on a confirmed breach, auto-transitions the mandate to `suspended` via the same kill-switch function a human uses (an `ad-mandate.auto-suspended` event, fully auditable and distinguishable from a human-triggered suspension).

One real, not-yet-closeable gap: evaluating a mandate with `allowed_campaign_ids: null` ("any campaign under the allowed products") requires knowing which Meta campaigns belong to which product. `research.meta.campaigns[]` now has an optional `product` field for this (`lib/config.js` validates its shape); the real `futco` instance config does not have it filled in yet (its two campaigns, `hvac_v3` and `free_v2`, have no `.product` set), so the health check currently reports "insufficient data" for any mandate scoped by product rather than by explicit `allowed_campaign_ids` — correctly, since guessing the mapping would risk suspending (or failing to suspend) the wrong campaign. A human who knows which product each campaign actually belongs to needs to fill this in.

### Phase 4 — real Meta-write executor + autonomous financial actions — **not authorized by this spec**
Launching an ad or changing a budget is `FINANCIAL_ACTION` (authority 3) today with no executor at all behind it (`lib/authority/policy.js`'s `meta-campaign-change` entry has been waiting for one since before this session). Making *that* autonomous — even under a mandate — is the one genuinely new kind of risk in this whole design: real money, via a credential already confirmed to carry `ads_management` and several other broad scopes beyond what its name implies. This phase needs its own explicit go-ahead, its own review of the hard-ceiling numbers against a real budget, and ideally a period of Phase 2/3 running cleanly first. Nothing in Phases 1-3 should be read as a stepping-stone commitment to this phase.

## 6. Kill switch — **Built, 2026-10-11**

`lib/actions/adMandateLifecycle.js`'s `transitionAdMandateLifecycle` is the one implementation behind every way to stop a mandate: CLI (`proposals suspend-mandate`/`revoke-mandate`), a one-click "Suspend"/"Revoke" form right on the mandate's own proposal page in the web UI (only shown while `currentAdMandateStatus` reports it's actually live), and the circuit breaker's auto-suspend path (tagged with the distinct `ad-mandate.auto-suspended` event type so the log always shows a transition wasn't a human). All three re-derive the mandate's live status inside the same event-log write lock `autoDecideUnderMandate` uses, so revoking mid-cycle is guaranteed to stop autonomous decisions on the very next check, never racing a decision that's already in flight.

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
2. **`research.meta.campaigns[].product` is unset on the real instance.** The circuit breaker (Phase 3) can't resolve which campaigns a product-scoped mandate covers until someone who knows FutCo's actual campaign-to-product mapping fills it in.
3. **No `ad_mandate` has ever been proposed or approved.** By design (section 8) - a human has to author one, citing real `thesis_refs`, before any of Phase 2's autonomy has anything to act on.
4. **The new autonomous scans aren't on a cron schedule yet.** `ops/run/run-auto-draft-briefs.sh`, `run-auto-propose.sh`, `run-auto-decide.sh`, and `run-ad-mandate-health.sh` exist but need to be added to the crontab (alongside `run-stripe-poll.sh`, built earlier and also not yet scheduled) for the loop to actually run continuously rather than only on manual invocation. Editing the live crontab is a persistent, system-level change this session deliberately did not make unilaterally - see the chat for the exact lines to add.
5. **Phase 4 remains categorically unauthorized** (section 5, section 8) - nothing above launches an ad or moves a dollar.
