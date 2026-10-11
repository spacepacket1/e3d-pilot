# FutCo Growth Loop: Ad Outcomes → Creative Engine → Revenue

**Status:** Vision/architecture document — not a ticket spec, not authorized for deployment on its own.
**Date:** 2026-10-11
**Owner:** FutCo / E3D

This document is the manifesto: the goal, the architecture, and how the pieces fit together. It does not contain phased tickets. Two documents sit beneath it:

- `docs/e3d-corp-pilot-cast-ad-outcome-loop-spec.md` — the first proving experiment (OppScan HVAC ad), already phased for s2c.
- `docs/e3d-creative-engine-spec.md` — the new creative-direction engine (`e3d-creative`), phased for s2c.

Read this one first. It rarely changes; the two beneath it will, as the proving experiment and the new repo generate real findings.

## 1. The actual goal

FutCo's goal is repeatable product revenue and user acquisition — not a consulting business, not a single good ad. The mechanism is a closed loop that runs **for every FutCo product and service** (OppScan today; e3d-pilot, e3d-trade, e3d.ai, and whatever comes next, once proven): Corp runs campaigns, observes real outcomes — both ad-platform engagement metrics *and* Stripe-side acquired users/revenue — diagnoses what's actually broken (creative, funnel, or measurement), commissions better creative, reruns, and compounds. OppScan's HVAC ad is the first instance of this loop, not the only one it will ever run for.

## 2. The loop, generalized across products

1. **Observe** — ad-platform metrics (impressions, clicks, spend, landing-page views) and Stripe-side signals (new customers, revenue, churn) for a given product/campaign.
2. **Diagnose** — Corp distinguishes a creative problem from a targeting/funnel/measurement problem. Don't commission new creative to fix a landing-page or pricing problem.
3. **Decide** — Corp opens a creative Opportunity with hypothesis, audience, constraints, metric, threshold, spend ceiling.
4. **Debate/Build (only when novel)** — if the gap needs new engineering capability (CAST can't produce something, a new ad-platform integration is needed), Pilot debates and builds it. If CAST can already produce a distinct variant, skip Pilot entirely — Corp commissions CAST directly.
5. **Produce** — `e3d-creative` (new) produces concept, script, storyboard, shot list, and visual-style direction; `e3d-cast`/`e3d-pod2vid` render it.
6. **Approve & distribute** — human approval before spend/publish in v1, always.
7. **Measure** — ad-platform metrics *and* Stripe outcomes, attributed to the specific creative/campaign.
8. **Learn & repeat** — across whichever product this cycle was for, and eventually across all of them.

## 3. What already exists vs. what's genuinely new

Checked against the real repos on 2026-10-11, not assumed from the spec:

| Capability | State | Where |
|---|---|---|
| Opportunity → Proposal → Decision → Outcome lifecycle | **Exists, generic** — `type` is an open string, zero schema changes needed for a creative Opportunity | `e3d-corp/lib/{opportunities,proposals,decisions,outcomes}` |
| Authority ladder (0 observe → 4 irreversible) with per-action-type policy table | **Exists** — already anticipates a Meta-write executor at `FINANCIAL_ACTION`, same tier as `capital_mandate`/`issue-invoice` | `e3d-corp/lib/authority/policy.js` |
| Corp → Pilot handoff for novel engineering work | **Exists, generic**, targets any repo | `e3d-corp/lib/proposals/pilotHandoff.js` |
| Ad-platform read access (Meta Insights: impressions/clicks/spend/landing-page views) | **Exists, real**, polled on a schedule | `e3d-corp/lib/research/metaInsights.js`, `ops/reports/pollMetaInsights.js` |
| External-signal adapter pattern | **Exists, established** — precedent to follow for new adapters | `e3d-corp/lib/event-sources/*.js` |
| Stripe adapter (acquired users, revenue) | **Missing** | new `e3d-corp/lib/event-sources/stripeRevenue.js`, observe-level (authority 0), same pattern as existing adapters |
| "Commission creative directly" (no Pilot hop) proposal type | **Missing** | new, same shape as `pilotHandoff.js`, targets `e3d-creative` instead of a repo to engineer |
| Ad-platform *write* access (launch creative, change budget) | **Missing**, and risky — gate at `FINANCIAL_ACTION`, human-approved in v1 | new executor behind the existing policy gate |
| Outcome attribution to a specific creative/campaign ID | **Unverified** — needs a read of `e3d-corp/lib/outcomes/record.js` before assuming it's supported | — |
| e3d-pilot idea lifecycle (discover/ideate/draft/negotiate/review/execute) | **Exists, reusable as-is** for building `e3d-creative` | `e3d-pilot/lib/ideas/*`, `bin/e3d-pilot` |
| Hosted job pipeline (billing, tiers, upload, worker, webhook) | **Exists**, unchanged role, dispatches to pod2vid today | `e3d-cast/src/{server,worker}` |
| Per-product rendering | **Exists**, but visually dated — needs a provider-abstraction upgrade (modern AI video-gen, not 80s-looking output) | `e3d-pod2vid/make_*_short.py` |
| Creative concept/debate/storyboard/visual-direction generation | **Does not exist anywhere** | new repo, `e3d-creative` — see companion spec |

The upshot: most of Corp's plumbing for this loop already exists, built for unrelated purposes (trade proposals, capital mandates) but generic enough to reuse without modification. The real new work is narrow: a Stripe adapter, a "commission creative directly" path, an ad-write executor (gated, human-approved), and the creative engine itself.

## 4. Component ownership

| Component | Owns | Must not own |
|---|---|---|
| **e3d-corp** | Business goal, campaign decisions, approvals, budget/risk policy, Stripe/ad-platform outcome observation, next-action decisions | Creative/rendering internals, unreviewed production changes |
| **e3d-pilot** | Investigating gaps, multi-model debate, phased tickets, building/testing `e3d-creative`/CAST/pod2vid/Corp integrations | Autonomous spend or publishing, inventing business outcomes |
| **e3d-creative** (new) | Creative concept, script, debate/critique, storyboard, shot list, visual-style direction (prompts, not pixels) — product-agnostic, reusable across every FutCo product | Rendering, hosting, billing, campaign decisions |
| **e3d-cast** | Hosted job pipeline — billing/tiers/upload/worker/webhook — dispatching to pod2vid | Creative-direction generation, campaign strategy |
| **e3d-pod2vid** | Actual rendering/composition, modern provider adapters (Higgsfield/ElevenLabs/etc.) | Campaign strategy, creative-direction decisions |

Authority is per action class, reusing **e3d-corp's existing 0-4 ladder** (`lib/authority/policy.js`), not a new scheme invented for this loop:

- **0 (observe):** ad-platform/Stripe polling, creative Opportunity creation — autonomous.
- **1 (internal write):** drafting a creative Proposal, invoking `e3d-creative` for a routine variant — autonomous.
- **2 (external action):** Pilot handoff for a genuine capability gap — autonomous (approval and execution are the same call, as today).
- **3 (financial action):** launching an ad, changing budget — approval required, human-executed in v1. This is the slot `policy.js` already anticipated for a "Meta-write executor."
- **4 (irreversible):** declaring a campaign won/lost and stopping it, public announcement — approval required.

## 5. Generalizing beyond OppScan

OppScan's HVAC ad is the proving instance, not the ceiling. Once the loop and `e3d-creative` are validated there, the same Opportunity type, Proposal plumbing, and authority gates apply unmodified to e3d-pilot's own marketing, e3d-trade, e3d.ai, or any future product — each needs only its own ad-platform/Stripe event-source adapters, not new architecture. Do not build for this generalization prematurely; prove it once, then copy the pattern.

## 6. Non-goals

- Not a consulting-engagement pipeline.
- Not making Pilot a standing hop for every routine ad variant.
- Not granting autonomous ad spend, publishing, or budget changes in v1 — always human-approved at authority level 3+.
- Not replacing pod2vid before a validated migration.
- Not building the multi-product generalization before OppScan proves the loop works.
- Not fabricating conversion/ROI claims before real data exists.

## 7. Open question carried into the companion specs

`e3d-corp/lib/outcomes/record.js` needs to be read before assuming outcome-to-creative attribution works out of the box — flagged here, to be resolved in the first phase of whichever spec touches outcome recording.
