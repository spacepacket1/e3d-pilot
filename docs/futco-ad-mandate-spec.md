# FutCo Ad Mandate: Bounded Autonomous Ad Spend

**Status:** Design spec, phased for s2c. Phases 1-3 are zero financial risk and buildable now. Phase 4 requires separate, explicit authorization before implementation — see Non-goals.
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

### Phase 2 — autonomous approval for `commission-creative` only (zero financial risk)
`commission-creative` never spends money or publishes anything — it only produces a creative direction (see the FutCo Growth Loop diagram: Produce is authority level 2, and e3d-creative's own QA gate already rejects weak directions before they go anywhere). This is the safe place to remove the human click first:

- A new decision path, `autoDecideUnderMandate(dataDir, proposalId, mandateId, instanceConfig)`, checks: the mandate is `active` (re-checked live at decision time, never cached — the same discipline `currentMandateStatus` already enforces for trade), the proposal's type and product fall within the mandate's `allowed_products`/`allowed_campaign_ids`, and `paper_only_creative` is `true`.
- On success it appends `proposal.approved` with `source: "decision:autonomous-mandate"` (distinct from `decision:cli`/`decision:web` so the event log always shows which decisions were a human and which were the mandate), then executes exactly like `decideProposal` already does for a human approval.
- A human still creates and approves the `ad_mandate` itself — the autonomy is scoped to "which routine creative variants get commissioned under an already-human-approved mandate," not to mandate creation.

### Phase 3 — circuit breaker (observe-only first, then enabled)
A scheduled job (`ops/reports/checkAdMandateHealth.js`) evaluates each active mandate's `pause_on_metric_degradation` rules against the latest Measure-stage data (Meta insights + Stripe evidence already being polled). Ships in two steps on purpose:
1. **Observe-only**: logs/notifies on a breach, never acts — lets a human confirm the degradation signal is trustworthy before it can take an action.
2. **Enabled**: on a confirmed breach, auto-transitions the mandate to `suspended` (an `ad-mandate.auto-suspended` event, fully auditable) — the same kill-switch state a human can already set manually.

### Phase 4 — real Meta-write executor + autonomous financial actions — **not authorized by this spec**
Launching an ad or changing a budget is `FINANCIAL_ACTION` (authority 3) today with no executor at all behind it (`lib/authority/policy.js`'s `meta-campaign-change` entry has been waiting for one since before this session). Making *that* autonomous — even under a mandate — is the one genuinely new kind of risk in this whole design: real money, via a credential already confirmed to carry `ads_management` and several other broad scopes beyond what its name implies. This phase needs its own explicit go-ahead, its own review of the hard-ceiling numbers against a real budget, and ideally a period of Phase 2/3 running cleanly first. Nothing in Phases 1-3 should be read as a stepping-stone commitment to this phase.

## 6. Kill switch

No new mechanism needed — `revoked`/`suspended` already exist in the lifecycle. What's missing is surfacing it: a one-click "pause this mandate" control in the web UI (`lib/web/server.js`/`render.js`), wired to the same transition `checkAdMandateHealth.js` uses automatically. Revoking mid-cycle must stop autonomous decisions on the *next* check, not require restarting anything — satisfied automatically by `autoDecideUnderMandate` re-checking mandate status live every time, never caching it.

## 7. Dependency on outcome attribution

`max_cac_usd` (cost per *acquisition*, not just cost per lead) only means anything once Stripe revenue is actually attributed to a campaign — which, per the manifesto, requires a product's checkout flow to stamp `metadata.correlationId` on the Stripe object, still unbuilt. Until then, mandates should constrain on `max_cpl_usd` (ad-platform metrics only, already live) and treat `max_cac_usd` as unset.

## 8. Non-goals

- No autonomous real-money spend in Phases 1-3 — `paper_only_creative` stays hard-true.
- No mandate, ever, permitted to exceed `AD_RISK_POLICY`'s hard ceiling — tightening only, same invariant as `capital_mandate`.
- No fabricated budget numbers — `AD_RISK_POLICY`'s values are a human decision, not an engineering one.
- No autonomous mandate *creation* in this spec — a human still proposes and approves each `ad_mandate`; only the routine decisions *inside* an approved mandate become autonomous.
- Phase 4 is out of scope until separately authorized.
