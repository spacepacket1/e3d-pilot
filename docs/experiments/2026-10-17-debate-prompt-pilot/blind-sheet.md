# Blind rating sheet — debate prompt pilot

For each question, three verdicts (X, Y, Z) from the same debate setup. They are shown as FINAL ANSWER + CONSENSUS + DISSENT only, in random order. Rank them by **which would you rather act on** (best first) and add a one-line reason. About 30 minutes. The key to which variant is which is in `blind-key.json`; please do not open it until you have rated all three.

## Q1 — Should the Federated Intelligence note go into e3d-brain, and how?

### Q1-X

FINAL ANSWER: Choose (d) for this document as written: do not copy the Living Idea into e3d-brain, because its personal context (Joel Do(OS), IteraWorks, JEEVIS), broken wiki links and unenforced `visibility`/`authority` fields do not belong in MIT specs and would collide with the single-principal design. First check that `docs/ideas/federated-intelligence.md` exists and states "relevance does not imply disclosure", the single-trust vault, the non-goals and the trigger "a second vault needs owner-run one-way publish". If it does, change nothing. If it is missing, write a one-page trimmed (b)-style note instead, with no new frontmatter fields and nothing built.

CONSENSUS: majority

DISSENT:
grok-build: Would skip the verification step and leave the repo unchanged, treating the existing ideas note as already confirmed. | "Leave the e3d-brain repo unchanged."

### Q1-Y

FINAL ANSWER: Choose (b): add a cut-down one-page note in `docs/ideas/` (or `docs/design-notes/`) and leave both specs unchanged. Add no new frontmatter fields and build nothing now. The note should keep the boundary principles that hold up: relevance is not disclosure, share a bounded and reviewed contribution rather than vault access, and do not dedupe two valid projections of one event. It should also warn that cognition output must never quote content from another scope, and tie any future work to G19 (an owner-run, one-way, scrubbed, provenance-preserving publish that the destination reviews again). Cut the Joel-specific material (JEEVIS, Life Flywheel, IteraWorks POC), drop links to notes outside the repo, say "second brain" instead of "Group OS", rename the document's `origin` to `source_domain` (e3d-brain's `origin` already means `mcp|hook|import|cli`), mark the YAML as illustrative, and turn the open questions into explicit out-of-scope items. Next action: write that note with a stated revisit trigger, namely a real second vault that needs a one-way publish, which would first get its own security review.
CONSENSUS: full
DISSENT: Minor: openai-api would allow future metadata after a security review, whereas grok-build rejects adding `visibility` and `authority` fields outright. Both agree on no fields or spec changes now.

### Q1-Z

FINAL ANSWER: Choose (c), defer. Keep the Living Idea in the vault and add no docs/ essay or spec requirement. e3d-brain v1 is one principal and one vault, its `origin` field already means capture channel (`mcp|hook|import|cli`), and G19 already records the only compatible mechanism: a one-way, owner-run, sanitized publish into another brain's `_inbox/`. The document's sound ideas (relevance is not disclosure, contributions are objects rather than vault access, origin/relevance/visibility/authority are separate axes) mostly restate ACLs, ABAC and capability delegation, and its hard questions (revocation, departure, private-evidence convergence) are unanswered. Next action: at the next cognition-spec edit, append one sentence to G19: "Revisit when two named vaults need a sanitized owner-run publish and hand-copy into `_inbox/` is insufficient; classification does not imply publish." If a doc is ever written, trim it to about one page, rename `origin` to `source_context` and `authority` to `epistemic_status`, and state the non-goals: no shared server, no reciprocal access, no auto-approve, no MCP cross-read.
CONSENSUS: majority
DISSENT: anthropic-api still prefers (b), a one-page non-binding docs note linked from G19, so the "classification is not publish" rule is recorded with its rationale. grok-build and openai-api chose (c). anthropic-api said it would accept folding the rule into G19 instead.

**Your ranking (best first):** ______   **Why:** ______

## Q2 — Review the FutCo Ad Mandate spec

### Q2-X

FINAL ANSWER: Verdict (c): hold. Do not authorize go-live or Phase 4 until the token owner runs Meta's debug_token on the exact credential the futco cron loads and rotates it to read-only (`ads_read`) if any write scope shows up. Also confirm whether a `meta-campaign-change` executor is registered. The biggest reason is that §6 ("cannot start real delivery") contradicts §5 and the manifesto, so the "no real spend" guarantee may rest on code absence rather than on the credential. Then fix the other contradictions (§4 vs §9.1 ceiling location, 239 vs 230 tests) and set the real ceiling numbers and the campaign-to-product mapping.

CONSENSUS: majority

DISSENT:
grok-build: Would go further and unregister the `meta-campaign-change` executor on the futco CLI until suspend and revoke actually pause campaigns. Grok-build says a Meta write path already exists and bypasses the mandate controls. | "Unregister the meta-campaign-change executor on the futco CLI until suspend and revoke pause those campaigns through setMetaCampaignStatus"

### Q2-Y

FINAL ANSWER: Verdict (c), hold until named gaps are closed. Phases 1-3 are sound as non-spending scaffolding, but the live loop and Phase 4 should not proceed. The ranked risks are:
1. A write-capable Meta token sits under a "read-only by design" safety story (§5 Phase 4 contradicts §6).
2. The spend-ceiling "kill switch" only flips an internal status, and auto-suspend is off by default, so it cannot stop real spend or even creative commissioning on a spend breach (§5 Phase 3, §6).
3. Auto-decide only acts on null-campaign mandates, which the breaker cannot evaluate because the campaign-to-product mapping is unset, so cron could commission creative while the health check returns "insufficient data" (§5, §9).

The contradiction is the token scope (§5 says `ads_management`, §6 says `ads_read` only). The smallest change is to probe the token with Meta's debug_token, strip it to `ads_read`, and make `activateAdMandate` refuse to activate until that probe passes. The recommended next action is for the token owner to run the probe and reissue the token as `ads_read` and rewrite §6 from the result. Only then should the budget owner set the real ceilings and the mapping, and the breaker should run observe-only against Ads Manager before any mandate is proposed.

CONSENSUS: majority

DISSENT: openai-api ranks the missing synchronous pre-write spend guard for Phase 4 as the top risk and wants a Phase 4 design PR opened now. The other two say to fix the token first and defer Phase 4 design until the breaker has run cleanly on real data.

### Q2-Z

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

**Your ranking (best first):** ______   **Why:** ______

## Q3 — Raise the guest limit from 20 to 40 calls/day?

### Q3-X

FINAL ANSWER: Verdict is (c), lower below 20, and do not raise guest1 and guest2 to 40. The fact sheet's $30 worst case is wrong: the current worst case is 3 × 20 × 30 × $0.05 = $90, which already exceeds the $60 budget, and the proposed 20+40+40 = 100 calls/day gives 100 × 30 × $0.05 = $150. The other fact-sheet errors are that a debate is 3×2+1 = 7 calls, not 4, so one token at 20 calls runs 2 debates per day (14 calls, 6 unused). The token cap is 100,000 per token per day per the 2026-10-15 changelog, and the 150,000 in the limits table is stale. Next action: cap guest1 and guest2 at 10 calls/day and keep chris at 20 (40 calls/day × 30 × $0.05 = $60 exactly), then correct the fact sheet to $90 worst case, 7 calls per debate and a 100,000 token cap. Equal caps of 13 per token ($58.50) are an alternative that fits the budget.
CONSENSUS: majority
DISSENT: Anthropic-api first favored (b) keep at 20 on the grounds that actual spend is unknown and the budget may be soft, then moved to (c) with equal caps of 13 per token. Openai-api and grok-build prefer guests at 10 and chris at 20. All three agree on rejecting the raise to 40 and on the corrected figures.

### Q3-Y

FINAL ANSWER: Choose (c) and do not raise guest1 and guest2 to 40. The sheet's own formula gives a worst case of 3×20×30×$0.05 = $90 under current limits (the sheet's $30 is one token's spend), and (20+40+40)×30×$0.05 = $150 under the proposed limits, against a $60 budget. One debate is 3×2+1 = 7 calls, not 4, so a 20-call limit allows 2 full debates per token per day (14 calls, 6 left over). The sheet's wrong figures are therefore 4 calls per debate (correct: 7), $30 worst case (correct: $90), and the 150,000 token cap (correct: 100,000 per the 2026-10-15 changelog). Next action: cut the call limits to fit the budget (13 per token gives $58.50, 7 per token gives $31.50 and exactly one debate) and correct the fact sheet.

CONSENSUS: majority

DISSENT: All three models agree on (c), the $90 and $150 worst cases, 7 calls per debate, and the 100,000 cap, but they differ on the new limit: 7 each (grok-build), 13 each (anthropic-api), or 20/10/10 (openai-api).

### Q3-Z

FINAL ANSWER: Lower the daily limit to 13 calls per token for chris, guest1 and guest2, and do not raise guests to 40. The corrected worst case at 20/20/20 is already $90 against a $60 budget, and the proposal would push it to $150. At 13 calls the worst case is 3 × 13 × 30 × $0.05 = $58.50, and each token still completes one 7-call debate a day. If the service has a verified hard $60 monthly spend cutoff, keeping 20 would also be defensible.

CONSENSUS: majority. All three analysts reject raising to 40 and agree on the corrected figures. Two choose option (c) but with different limits (13 for everyone vs. 10 for guests only), and one chooses (b) with a spend cutoff.

DISSENT:
- anthropic-api: Keeps all three tokens at 20 and adds a hard $60 monthly spend cutoff, because the $90 worst case is unlikely in a small beta and cutting to 13 costs usability. | "Keep all three tokens at 20 calls per day, add a hard $60 monthly spend cutoff"
- openai-api: Caps guest1 and guest2 at 10 and leaves chris at 20, which also totals exactly $60. | "Set guest1 and guest2 to 10 calls per day while leaving chris at 20, then correct the fact sheet."

**Your ranking (best first):** ______   **Why:** ______
