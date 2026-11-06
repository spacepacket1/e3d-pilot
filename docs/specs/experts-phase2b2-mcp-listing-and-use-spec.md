# Experts, Phase 2b.2: listing and using experts through the hosted MCP (specification, docs only)

**Status:** draft 1, 2026-11-06; **owner accepted D19 to D25 as recommended on 2026-11-06** (section 10). No code, no flag, no deploy, no model call. Owner request of 2026-11-06: let people use the hosted experts (skills) from their own AI through the MCP, not only from the web page, and do not do it by pasting skill text into the question.
**Parents:** [Phase 2b.1](experts-phase2b1-hosted-lenses-spec.md) (the web path, live), [Phase 2a](experts-phase2a-seats-and-suggest-spec.md), [Phase 1](experts-phase1-private-experts-spec.md) (section 1b: the free listing tools), [Phase 0](experts-phase0-overlap-map-and-eval-plan.md) (D5, D6, D11). Cloud contract: `e3d-pilot-cloud` `docs/agent-contract-spec.md`.
**Evidence tags:** **[E: path]** read today (engine paths are this repo at 3636ad2; `cloud:` paths are `e3d-pilot-cloud` origin/main at ac57a58, read-only). **[G]** guess. **[N]** not verified.

## 0. Summary

1. **Listing already exists.** `e3d_list_experts` and `e3d_get_expert` are built, free and read-only; they are off in production (`E3D_MCP_EXPERTS` unset) and their text says running experts through the connector is "not available yet" [E: `lib/mcp/experts-read.js`]. Phase 2b.2 turns them on and corrects that text. It is not new code.
2. **Use is one new optional argument: `experts`**, an ordered list of 2 to N expert **names** (N is the account's panel size, at most 4), on both `e3d_quote` and `e3d_debate`. The agent sends names; the server resolves the lens text, pins its hash, prices it in the quote and runs it. **Skill text is never sent by the caller and never placed in the question.**
3. **It reuses the web path's machinery**: the engine already plans, pins and runs experts for a hosted run (`planWebRun`, `--specialist --builtin-only --fill-pool --lens-bytes-max --expert-pin`) [E: `bin/e3d-mcp` lines 590-600, 1277-1293], and billing already prices lenses with the `lensBytes` basis field and `lensBytesMax` [E: Phase 2b.1 section 2]. What is missing is the **agent route** (`cloud:src/agent.js`), whose `runFields` knows nothing about experts [E], and the engine's agent-mode handlers (`toolQuote`, `agentRunBody`, `agentPrepare`) [E].
4. **One hazard this spec exists to close.** Billing's agent quote builds its basis from a fixed list of fields and ignores any other [E: `runFields`]. An engine that sent `experts` to a billing that does not know them would run the lenses on a quote that did not price them, and the settlement clamp makes that **our** loss, not the user's [E: 2b.1 section 1, item 2]. Section 5 makes this fail closed in both directions.
5. **Not in this phase:** user-supplied lens text, an `auto` mode, a preset argument, per-seat pairing in the result, challenge parameters (section 9).
6. Three PRs, each flag-off and mergeable alone (section 8), then an owner-approved release request.

## 1. What exists today (verified)

| Piece | State | Source |
|---|---|---|
| Free listing tools (`e3d_list_experts`, `e3d_get_expert`) | built, flag `E3D_MCP_EXPERTS=1`, **off in prod**; read the engine checkout's eight built-in experts and presets; rate limited 30 a minute per principal | [E: `lib/mcp/experts-read.js`; `docs/specs/experts-phase1-private-experts-spec.md`] |
| Hosted run with experts (web) | live since 2026-11-03: run listener field `experts` + `lens_bytes`, capability `experts_v1`, planner flags | [E: Phase 2b.1 status line] |
| Lens pricing | basis field `lensBytes` = table `lensBytesMax` (640); live delta +1 credit on a standard 4-vendor debate | [E: Phase 2b.1 sections 2 and 10] |
| MCP `e3d_quote` / `e3d_debate` (agent mode) | no `experts` argument; schemas list question, mode, providers, rounds, max_words, web_search | [E: `lib/mcp/agent.js` lines 179-200] |
| Billing agent quote/begin | `runFields` accepts principal, providers, rounds, max_words, question_sha256; request hash and `checkQuote` compare only those and the search flag | [E: `cloud:src/agent.js` lines 61-73, 265-282] |
| Error catalogue | stable codes, `quote_mismatch` carries `mismatch: [field names]` | [E: `lib/mcp/agent.js` CATALOG; `cloud:docs/agent-contract-spec.md` section 6] |

Correction to an earlier chat answer: I said the listing tools were "behind a flag" without saying they were already written. They are; only the flag and the text change.

## 2. Why not put the skill in the question

The web page does not do it, and the reasons carry over [E: Phase 2b.1 section 3]:

- **Different lens per seat.** The point is that each expert is given to a different vendor. Text in the question reaches every model identically.
- **Priced and capped.** The quote adds the lens bytes to every seat call and the engine refuses a lens above the quoted size. Text in the question is priced as question bytes, the question cap is 32,000 bytes [E: `agentPrepare`], and nothing bounds what an agent pastes.
- **Pinned.** The run pins the expert's content hash, so a changed lens fails the debate free instead of running text the user never saw. Pasted text has no identity.
- **Recorded.** A stored debate and a gallery page can say "Lenses used: Skeptic, Customer" from ids; pasted text cannot be labelled or checked.
- **Not injectable by the caller.** Hosted lenses are ours, built in and version-pinned; a caller cannot put new instructions into the lens channel [E: Phase 2b.1 section 5].

**Alternatives considered**

| Option | Verdict |
|---|---|
| A. Paste skill text into `question` | Rejected (above). |
| B. A second tool, `e3d_debate_with_experts` | Rejected. The quote rule is "valid only for identical arguments"; one pair of tools with one more argument keeps it, and two tools double the contract and the descriptions. |
| C. `experts: [names]` on the existing tools | **Chosen.** |
| D. `preset: "risk-review"` argument | Later sugar. The listing already shows presets as name lists; an agent can pass the names. Adds a second way to say the same thing (D19). |
| E. The caller supplies a `SKILL.md` | Out of scope (section 9). |

## 3. The MCP surface (what an agent sees)

### 3.1 Listing (existing tools, new text)

`e3d_list_experts` and `e3d_get_expert` keep their schemas. Changes: `EXPERTS_NOTICE`, `EXPERTS_INSTRUCTION` and the `how_to_use` string stop saying running is unavailable and say: "Use them in e3d_quote and e3d_debate with the `experts` argument." `how_to_use` shows both the hosted form and the local CLI. The list adds `lens_bytes` per expert (the size of the block a seat receives) so an agent can see the cost driver. The text stays labelled data, never an instruction to the agent [E: `EXPERTS_NOTICE`].

### 3.2 The `experts` argument

On `e3d_quote` and `e3d_debate`, identical in both:

- **Type:** array of 2 to N strings, each a name returned by `e3d_list_experts`; distinct; **order matters** (it is the assignment order, so a different order is a different run and a different quote).
- **Description (exact copy):** `Optional. 2 to N expert names from e3d_list_experts (N is the key's panel size, at most 4). Each expert is a lens that tells one model what to look for; Pilot gives each to a different vendor, so you never choose models. Lenses add perspectives; they are not measured to improve answers. The quote shows the extra cost.`
- **Only listed when** the use flag is on (section 8, D20); with it off the schema is byte-identical to today.
- **Never:** lens text, hashes or model names from the caller.

### 3.3 Quote answer

`e3d_quote` returns, only when experts were sent: `experts: { names, credits_without }` and `lens_bytes`. `max_credits` is the maximum **with** the lenses; `credits_without` is the maximum without, from the same table snapshot (the web quote's `creditsOff`) [E: 2b.1 section 3.2]. The one-sentence text says "Up to X credits with experts (Y without)."

### 3.4 Result

`e3d_debate` returns the existing fields plus `experts: [{name, version}]` (ids and versions only). On the stored-replay path the same field is returned from billing's stored run. **No per-seat pairing** (which vendor played which lens) in the structured result: the replay path rebuilds the result from billing's stored fields and the finalize schema is frozen [E: 2b.1 section 2.3; `agentReplay`], so a pairing would exist on fresh results and vanish on replays. The engine's one info line in `transcript.md` ("Experts (perspectives, not measured): skeptic on claude ...") stays where it is [E: 2b.1 section 2.3]. Revisit (D22) when the schema can carry it.

### 3.5 Errors (two new catalogue codes)

| Code | HTTP | Retryable | Meaning |
|---|---|---|---|
| `invalid_experts` | 400 | no | Not 2 to N, unknown or duplicate name, not an array. `reason`: `type`, `too_few`, `too_many`, `unknown`, `duplicate`. Never echoes a value. |
| `experts_unavailable` | 503 | yes | Experts are off or not supported on the path (flag off, billing or engine without support, catalogue drift). Nothing was held or charged; ask again without experts. |

Existing: `quote_mismatch` gains the field name `experts` in `mismatch`. Added to `CATALOG` in `lib/mcp/agent.js` and to billing's catalogue and `docs/site/errors.md`.

### 3.6 Instructions for agents

The server instruction string gains one sentence: "Experts are optional lenses (see e3d_list_experts); pass their names in `experts` on both e3d_quote and e3d_debate. They are perspectives, not measured improvements." Banned in all copy: "smarter", "better", "improves", "accuracy" [E: 2b.1 section 4]. Do not call the feature live in any public copy, directory listing or `llms.txt` until the release request is applied.

## 4. Engine changes (`e3d-pilot`)

- **`lib/mcp/agent.js`:** add `experts` to the `e3d_quote` and `e3d_debate` schemas (flag-gated), add the two catalogue codes.
- **`bin/e3d-mcp` `planDebate`** (agent mode): validate `experts` (count 2 to the plan's provider count, distinct, names in the **built-in catalogue only**), resolve each name's `content_hash` from the built-in folder, and set `plan.experts = { list: [{id, hash}], lensBytes }`, the shape `executeDebate` already consumes [E: line 590-600]. With more experts than providers in the degraded plan the engine refuses (`invalid_experts`, reason `too_many`), as the run listener does [E: 2b.1 section 2.1].
- **`agentRunBody`:** add `experts: [{id, hash}]` when present. Ids and hashes only, never text, as nothing but a hash and a size of the question reaches billing today [E: `QUOTE_DESC` in `agent.js`].
- **`limitsFromAgentQuote` and `agentPrepare`:** read `lens_bytes` from the quote like `max_tokens`. **With experts, the temporary connector-quote fallback is not allowed** [E: `agentPrepare` comment "TEMPORARY FALLBACK"]: it prices the run through `connectorQuote`, which has no lens bytes and would under-price; if the agent quote lacks `lens_bytes`, refuse with `experts_unavailable`.
- **`agentPrepare` begin call:** pass `experts` to `agentBegin` so billing binds it to the key.
- **`executeDebate`:** unchanged; it already adds the planner flags when `plan.experts` is set [E].
- **Result:** add `experts` to the structured result and to the stored-agent fields it reads back on replay.
- **`lib/mcp/experts-read.js`:** text changes and `lens_bytes` in the list summary (section 3.1).

## 5. Cloud changes (billing agent routes, `e3d-pilot-cloud`)

- **`runFields`:** accept optional `experts`: an array of `{id, hash}`, 2 to 16 [G: the web limit], ids matching the catalogue name pattern, distinct; each id in `src/experts-catalogue.json` and each hash equal to the catalogue's. Validate the count against the account's panel size with the existing `debate-experts` check [E: `debates-routes.js` `expertsOf`]. A hash that differs from the catalogue means drift: refuse `experts_unavailable`, free.
- **Quote:** the basis gains `lensBytes: table.lensBytesMax` only when experts are present; the answer carries `experts: {ids, credits_without}` and `lens_bytes`; the quote row stores the ordered ids. `compute()` is unchanged (2b.1 already added the term).
- **Idempotency:** `requestHash` appends `experts` **only when present**, so every existing request hash is byte-identical. A repeat with the same key and the same experts replays; a different list is `idempotency_conflict`.
- **`checkQuote`:** compare the ordered ids; a difference adds `experts` to `mismatch` (`quote_mismatch`).
- **Settlement:** unchanged. Usage rows clamp to the manifest, which now includes the lens term; charge never above the hold [E: 2b.1 section 3.3].
- **Stored result:** the agent run row stores the ordered ids so a replay returns them.
- **Gallery:** if an agent-run debate becomes a `debates` row that can be published, its snapshot lists expert labels only, as the web path does [E: 2b.1 section 3.4]. **[N]** I did not trace whether and how an agent run becomes a `debates` row.
- **New flag `PILOT_AGENT_EXPERTS`** (default false). Startup fails if it is true without `PILOT_PRICING_MODE=per_token`, without `lensBytesMax` in the rate table, or without the catalogue [E: 2b.1 section 3.1 for the web equivalents]. **With the flag off the agent routes refuse `experts` with `400 invalid`**, they do not ignore it (D21).

### The fail-closed rule (the reason for D21)

1. **New engine, old or flag-off billing.** Old billing ignores an unknown field [E: `runFields` builds only from known fields]. So the engine, after asking for a quote **with** experts, checks that the answer echoes `experts` and `lens_bytes` for the same ids. No echo: do not run, return `experts_unavailable`, nothing held. The same check covers a flag-off billing that refuses.
2. **Old engine, new billing.** The old engine never sends `experts`; nothing changes.
3. **Catalogue drift** between the engine's built-in folder and billing's catalogue is caught by the hash comparison in both places (engine pin on the run; billing hash compare at quote), and fails free.

## 6. Security and privacy

- Lens text is ours and built in; a caller cannot supply any. No new untrusted text reaches a model [E: 2b.1 section 5].
- The question is hashed for billing as today; experts add only ids and hashes. Logs carry ids, codes and states, never the question or lens text.
- `e3d_list_experts` output is data, labelled as such, and rate limited per principal; it reads local files only.
- No new third party, no new origin, no analytics.
- A key's caps (`key_cap_per_run`, daily, total) apply to the quote's maximum with lenses; nothing new to configure [E: `cloud:src/agent.js` `precheckCaps`].

## 7. Tests (targeted)

**Engine:** schema byte-identical with the flag off; names validated (count, duplicates, unknown, non-built-in); more experts than providers refused; agent body carries ids and hashes and no text; the **echo check** (a stub billing that ignores `experts` makes the call fail with `experts_unavailable` and no run starts); the connector-quote fallback is refused with experts; a replay returns `experts`; golden prompts and receipts unchanged without experts.

**Cloud:** every existing request hash and quote vector byte-identical without experts; with experts the quote rises by exactly the lens term and `credits_without` equals the no-expert quote; flag off refuses `experts` (`400 invalid`); drifted hash refused; same key + same experts replays, other experts conflicts; `checkQuote` reports `experts` in `mismatch`; settlement at `inMax` never exceeds the hold; per-run cap applies to the with-lens maximum.

**Mutation checks** (each must make a test fail): drop the echo check; allow the fallback with experts; ignore `experts` instead of refusing when the flag is off; drop `experts` from `requestHash`; drop it from `checkQuote`; drop `lensBytes` from the basis; accept a hash different from the catalogue.

## 8. Pull requests, order, rollout, rollback

| PR | Repo | Content | Risk |
|---|---|---|---|
| **2b.2a** | e3d-pilot | listing text, `lens_bytes` in the list, enabling `E3D_MCP_EXPERTS` is a release step | tiny; tests `mcp-experts-read*` |
| **2b.2b** | e3d-pilot-cloud | agent routes: `runFields`, basis, quote answer, `requestHash`, `checkQuote`, stored ids, `PILOT_AGENT_EXPERTS`, error codes, `docs/site/errors.md`, runbook | **the money PR** |
| **2b.2c** | e3d-pilot | agent-mode handlers, schemas, result, echo check, fallback refusal | medium |
| **Release** | both | deploy requests; owner approval | none |

**Order:** 2b.2b first (flag off, refuses `experts`), then 2b.2c (flag off), then the release in this order: cloud with the flag off, engine, then the cloud flag and the engine use flag. Listing (2b.2a) can go out alone but it advertises a feature that is not usable, so I recommend releasing it **with** 2b.2c (D20).
**Release criteria (owner-approved, separate from merging):** all PRs merged flag-off; a deploy with the flags off shows quotes, holds and a real debate unchanged; on the **test instance** a quote with experts shows the expected delta, two real debates (2 and 4 experts) settle at or below the hold, one forced failure refunds, a replay and a SIGKILL drill pass, the echo check fails closed against a billing without the flag; `ops/billing-check.js` is clean.
**Rollback:** `PILOT_AGENT_EXPERTS=false` and restart billing: new `experts` calls are refused with `experts_unavailable`, a run already reserved still finishes and settles; unset the engine use flag to hide the argument. Rows with experts stay valid and inert; nothing needs ledger repair.

## 9. Not in this phase

- **User-supplied skills** (`SKILL.md` or lens text from the caller). That sends untrusted text into every model's prompt, with no price bound, no identity and no provenance, and bypasses the license gate for imported skills [E: owner decisions of 2026-11-01, project notes; not re-read in Phase 0]. If it is built it is a registry: a user publishes an expert, the owner approves, the content hash is pinned, and the MCP names it like a built-in. That is Phase 4 and waits for the Challenge test [E: project notes].
- **`experts: "auto"`.** Phase 0/2a decided "suggest", never "auto" (D11). A free `suggest` input on `e3d_list_experts` (rules, no model) is a possible later addition; the question text would reach the MCP server only, as it does for a debate.
- **`preset` argument** (D19), **per-seat pairing** (D22), **more seats than vendors** (engine limit stays).
- **Challenge parameters** (`challenge_of`). Neither billing's agent routes nor the engine has them [E: 2b.1 section 1, item 1]. See D23.

## 10. Decisions for the owner (my recommendation first)

- **D19. `experts` takes names only; no `preset` argument in v1.** The listing already shows presets; adding a second spelling doubles the contract.
- **D20. Two engine flags and one billing flag:** listing `E3D_MCP_EXPERTS` (existing), use `E3D_MCP_EXPERTS_AGENT` (new, gates the argument), billing `PILOT_AGENT_EXPERTS` (new). Release listing and use together so the public text never advertises half a feature.
- **D21. Billing's agent routes refuse `experts` when the flag is off** (not ignore as the web routes do), and the engine requires the quote to echo it. Reason: an ignored field means lenses run unpriced. This differs deliberately from D16.
- **D22. The result lists expert names and versions, not seat pairings.** Revisit when the finalize schema can carry them.
- **D23. Do not wait for `challenge_of`.** Phase 0 D5 said extend the agent routes "once". Recommend the pattern be shared, not the PR: add `experts` now with the validation helper written so `challenge_of` can follow in the same shape. This revises the wording of D5, so it is your call.
- **D24. No `auto` and no `suggest` in v1.**
- **D25. No user-supplied lens text, ever, in the hosted MCP;** bring-your-own goes through a registry with a license gate.

## 11. Not verified

Whether an agent-run debate becomes a published-capable `debates` row and how its experts would reach a snapshot (section 5, Gallery); whether the engine's agent-mode path reads the panel size the same way `panel.resolveForUser` does for the 2-to-N check; the credit delta through the agent route (expected the same +1 as the web quote, not measured here); how directory listings (Anthropic, OpenAI, MCP registries) treat a tool whose schema changes (a re-review is possible); the exact field names of billing's stored agent result (`agentFieldsOf`); the 16-expert upper bound on the agent route (copied from the web run body, a guess); line and effort estimates, which are not given.
