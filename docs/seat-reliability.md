# Seat reliability: retries, dropped seats and the synthesis fallback

A multi-model debate must not fail because one vendor had a bad moment. This is what `bin/e3d-debate` does when a call fails, and what
it reports. Tests: `tests/seat-reliability.sh` (fake vendor, `tests/fixtures/seat-fake.mjs`).

## One retry rule for every call

Every provider call (a round answer, a search call, its no-search fallback, the synthesis) follows the same rule:

| Failure | Retried? | Budget |
|---|---|---|
| HTTP 429, 500, 502, 503, 504, a timeout | yes | `E3D_DEBATE_PROVIDER_RETRIES` (default 2; **0 in a per-token debate**), wait `E3D_DEBATE_PROVIDER_RETRY_DELAY` x attempt |
| 200 with no text (`no_text`: all output spent on thinking, `stop_reason: max_tokens` with no text block, an empty message) | yes | `E3D_DEBATE_NO_TEXT_RETRIES` (0 to 2, default 1), same delay |
| any other 4xx (400, 401, 403, 404, ...), a refused key, a bad request | never | |

The synthesis call had no retry at all before; it now follows the same rule. A retry repeats the **same request with the same output limit**:
`max_tokens` is never raised on a retry.

Web search calls: a search call that returned no text is retried once as a search call (same caps; only the last attempt's record counts,
so searches are not double counted), then asked once without search (flagged in `web_search.flags.unavailable` with reason `no_text`).
In a per-token debate the search call is never repeated (a second request could run another cap's worth of searches); a no-text search
call gets one call without search instead (same output limit, strictly less input, no searches). Every other per-token search failure
still leaves that voice without an answer for the round, with no second call (docs/token-pricing.md, item 5).

### Usage of a retry (per-token debates)

All attempts of one call append their stderr to the call's file, separated by an `e3d_attempt_end` line, so every attempt's
`e3d_provider_usage=` line is kept. `usage.json` still has **one row per key** (billing refuses a repeated key and a report with one is
refused as a whole), so `lib/debate/token-pricing.mjs` `vendorUsage` **sums** the attempts of a call into its row (`input_tokens`,
`output_tokens`, `searches`). Billing clamps each row to that key's bound (`min(row, key bound)`), so a retry can never raise the charge
above the quote; the part above the bound is the operator's cost (and raises billing's over-bound alarm). If an attempt reached the vendor but
left no usage line, the whole call falls back to the byte estimate (never an undercount). A retry is therefore reported per call and
included in the row's sum, not as a separate row.

## Dropped seats

A participant that fails a round after its retries is dropped from every later round (it is not called again), the transcript says so
(`## Seat dropped -- <provider>`), and the failed answer's placeholder carries the reason:
`(provider X failed in round N (no_text) -- see ...)`. Later rounds, the prompts and the convergence check use only the seats still
answering; the rounds stop early when fewer than two remain; when none answers there is no synthesis call and the debate fails
(exit 1). The synthesis prompt says how many seats answered and asks for the consensus to be judged among them only.

`seats.json` (next to `transcript.md`, from `--out-dir`): `seats_requested`, `seats_answered` (seats not dropped),
`seats_unavailable [{provider, round, reason}]` (reasons: `no_text`, `http_<status>`, `timeout`, a search error code, `error`),
`synthesizer`, `synthesizer_fallback`, `synthesis_ok`, `flags {synthesizer_fallback, seats_lost, fewer_than_3_seats}` and, when fewer than three
seats answered, `consensus_note`.

e3d-mcp copies these into the **structured result** of `e3d_debate` (additive; the stored finalize result and the frozen tool definitions are
unchanged): `seats_requested`, `seats_answered`, `seats_unavailable`, `flags`, `synthesizer_fallback`, `consensus_note`, plus a `warnings[]`
line for each (`Only 2 of 3 models answered: ...`, `The summary was written by ...`), which the text result renders as `**WARNING:**` lines
and in the REPORT line. A debate that lost a seat but produced a verdict is a success and is charged for the calls that ran.

## Synthesis fallback

If the synthesizer (default `anthropic-api` for the hosted panel) still fails after its own retry, the next candidate runs **the same
synthesis prompt**:

- `E3D_DEBATE_SYNTH_FALLBACK=auto` (default): the other API participants (`anthropic-api`, `openai-api`, `gemini-api`, `xai-api`) that answered round 1, in panel order.
  A comma list (`gemini-api,openai-api`) sets the order explicitly; `off` disables the fallback (the debate then fails as before).
- `E3D_DEBATE_SYNTH_FALLBACK_MAX`: how many candidates to try (default 2; **1 in a per-token debate**).
- **Per-token debates** only use candidates the quote priced (they have an output limit) and never `xai-api` (see below).

A fallback is marked in the transcript (`## Synthesis (openai-api; fallback for anthropic-api: no_text)`), on stdout
(`SYNTHESIZER FALLBACK: ...`), in `seats.json` (`synthesizer_fallback: {from, to, reason}`), in the decision log (`synthesizer` is the writer),
and in the MCP result (structured `synthesizer_fallback`, `flags.synthesizer_fallback`, a warning, the text). The debate is a success and is
charged normally. If every candidate fails the debate fails exactly as before: no verdict, exit 1, nothing stored as a success.

### Billing contract (per-token)

- The quote's `synth` row has provider `any`, is priced at the highest input and output rate of the panel, and bounds `in`/`out` tokens
  (`outMax = max output ceiling of the panel + reasoningAllowance of the FIRST panel provider`). A synthesis row is priced at the **row's own
  provider rate** (`rateOf(row.provider)`), clamped to the key's bound. A fallback from another panel provider has a rate no greater than the
  highest one, so it fits inside the quote.
- A fallback whose provider has a larger `reasoningAllowance` than the first provider (today only `xai-api`, whose reasoning tokens
  `max_tokens` does not cap) could exceed `outMax`; billing would clamp the charge and raise its over-bound alarm (and the xAI-specific
  `xai_reasoning_overrun`). The safest design is used: **a per-token debate never falls back to `xai-api`**. Outside per-token pricing it can.
- `usage.json` allows one `synth` row. The row is the call that wrote the verdict (the fallback provider, or the synthesizer when only its
  retry was needed, with the retry's usage merged). The failed synthesizer's attempts may have been billed by its vendor: they are kept in
  `usage-unreported.json` next to `usage.json` for the operator and are **not** sent as a second row (a repeated key would make billing refuse the
  whole report and price the debate from the v1 estimates with an alarm). That cost is the operator's, bounded by the failed attempts' own output limit.
- The panel contract's `required` list and `synthesizer` field describe who is *asked* to write the summary
  (`panel.synthesizer` is unchanged); a fallback is visible only in the new fields above and the transcript. The stored finalize result
  is not changed (Debate contract v1 schemas are frozen); async results carry the marker in the stored transcript only.

## Measured on the real API (2026-10-24, `claude-sonnet-5-5`, `thinking: {type: "between_tools"}`)

The real `lib/providers/anthropic-api` adapter, short decision questions, 30 calls (6 per cell; search questions needed a current fact so the
model actually searched), plus 3 confirming calls after the truncation check below. Search cells use cap 2 searches; "per-token" = one request per call
(`E3D_PROVIDER_PER_TOKEN=1`). Tokens are the vendor's own `usage` (thinking from `output_tokens_details.thinking_tokens`).

| Cell | max_tokens | Search | Calls | Text returned | no_text | Stop reasons | Output tokens avg (min-max) | Thinking tokens | Over the cap | Input avg |
|---|---|---|---|---|---|---|---|---|---|---|
| A | 288 | off | 6 | 6 | 0 | end_turn x6 | 199 (174-219) | 0 | never | 130 |
| B | 728 | off | 6 | 6 | 0 | end_turn x6 | 687 (611-725) | 0 | never | 130 |
| C | 288 | on, per-token | 6 | 6 (2 are only the pre-search sentence) | 0 | end_turn x4, max_tokens x2 | 335 (273-377) | 288 on each of the 2 capped calls | 5 of 6, up to +89 | 14,029 |
| D | 728 | on, per-token | 6 | 6 (5 are only the pre-search sentence) | 0 | end_turn x1, max_tokens x5 | 817 (802-870) | 728 on each of the 5 capped calls | 6 of 6, +74 to +142 | 17,192 |
| E | 288 | on, continuations allowed | 6 | 6 (3 are only the pre-search sentence) | 0 | end_turn x3, max_tokens x3 | 333 (278-376) | 288 on each of the 3 capped calls | 5 of 6, up to +88 | 14,208 |

- Without search the thinking fix works: 12 of 12 calls answered, 0 thinking tokens, never over the cap.
- With search it does not fully work. `between_tools` allows thinking between tool calls, i.e. after the search results, and the model
  spent exactly the whole cap on it (thinking tokens = max_tokens) in 10 of 18 search calls. Those responses end at `max_tokens`
  with, as text, only the sentence written before the search ("I'll check the current PostgreSQL release status."). The
  adapter used to return that sentence as the answer (it is not empty, so the `no_text` check passed); it now counts as `no_text`
  (retry, then a call without search). Re-run against the real API after the change: 3 of 3 truncated search calls were flagged `no_text`.
- Output above the cap comes from the search query blocks and the pre-search sentence, which are counted after the thinking budget: about
  +75 to +90 tokens with one search and +142 with two. No `pause_turn` continuation occurred in these runs (every call was one request), so the
  earlier 338-443 over a cap of 288 (+50 to +155) are consistent with the same effect rather than with continuations.
- Search calls carry about 3,000 input tokens for the tool alone (a search call that did not search: 3,166 in vs 135 without the tool) and roughly
  another 8,000 to 11,000 per search that ran (1 search: 12.7k to 14.5k; 2 searches: 22.4k).

## Follow-up: how to make Anthropic search calls finish (2026-10-24, real API, `claude-sonnet-5-5`)

Question: with search on, post-search thinking eats the whole `max_tokens` (above). Is there a knob, or does the cap have to rise?
A note on the cloud side: `reasoningAllowanceTokens` is accounting headroom only (manifest `outMax = outCeil + allowance`); the `max_tokens`
the engine sends comes from the quote's `max_tokens` map (= `outCeil`), so an allowance alone does not let Claude finish.

### 1. Probes (deliberately invalid values, error text read, nothing guessed)
| Probe | Result |
|---|---|
| `thinking.type: "zzz"` | 400: valid tags are `adaptive`, `between_tools`, `disabled`, `enabled` |
| `thinking.type: "disabled"` | 400: "To turn thinking off on this model, send `between_tools` ... The short updates it writes between tool calls come back as thinking blocks." |
| `thinking: {enabled, budget_tokens}` | 400: not supported; "Use `thinking.type.adaptive` and `output_config.effort`" |
| `between_tools` / `adaptive` with `budget_tokens`, `effort`, or any extra key | 400: extra inputs not permitted (no budget knob inside `thinking`) |
| `output_config: {zzz}` | 400: extra inputs not permitted |
| `output_config.effort: "zzz"` | 400: valid values `low`, `medium`, `high`, `xhigh`, `max` |
| top-level `effort` | 400: extra inputs not permitted |
| `thinking: adaptive` + `effort: low`, with and without the search tool | 200 |
| `thinking: between_tools` + `effort: low` | 200 |
| `tool_choice.type: "zzz"` | 400: valid `auto`, `any`, `tool`, `none` (`none` just turns search off) |

So the only documented knobs are `thinking.type` (`adaptive` or `between_tools`) and `output_config.effort`. Tried at max_tokens 728, 300-word answer, one search allowed:

| Variant | Calls | Searched | Final answer after the search | Thinking tokens on searched calls |
|---|---|---|---|---|
| `between_tools` + effort low | 3 | 1 | 0 of 1 (the 2 unsearched calls answered) | 728 (= cap) |
| `adaptive` + effort low | 3 | 2 | 0 of 2 | 728 (= cap) |
| `between_tools` + system line "after the search results arrive, do not deliberate" | 3 | 3 | 0 of 3 | 728 (= cap) |

No knob helped (n is small, but 0 of 6 searched calls finished, against 1 of 6 for the unmodified call at 728 in the main matrix). Raising the cap is the cure.

### 2. Completion rate by max_tokens (search on, one search allowed, per-token style, `between_tools`, 6 short current-fact decision questions, 300-word answers)
| max_tokens | Calls | Real final answer | Searched | Stop reasons | Output avg (max) | Thinking tokens |
|---|---|---|---|---|---|---|
| 728 (earlier matrix, 2 searches allowed) | 6 | 1 | 6 | end_turn 1, max_tokens 5 | 817 (870) | = cap on the 5 capped |
| 1024 | 6 | **6** | 6 | end_turn x6 | 850 (958) | 0 |
| 1536 | 6 | 6 | 6 | end_turn x6 | 854 (1018) | 0 |
| 2048 | 6 | 6 | 6 | end_turn x6 | 863 (1148) | 0 |
| 3072 | 6 | 6 | 6 | end_turn x6 | 867 (1001) | 0 |

Quick-sized answers (80 words, 3 calls each): max_tokens 1024: 3 of 3 final, output 380-397; 768: 3 of 3, output 352-443. (Earlier at 288, 4 of 6.)
Output is about 850 tokens for a 300-word search answer whatever the cap; once the cap clears that, thinking is not reported and the call ends normally.
So the need is about the post-search total (answer plus whatever the model deliberates), not a fixed thinking size. Margin at 1024 is thin for 300-word
answers (max seen 958); 1536 had max 1018.

### 3. Recommendation: ONE design: raise the Anthropic search-call output ceiling to 1024 (already the table's `maxOutputTokens`)
Smallest tested size that completes at least 5 of 6: **1024** (6 of 6 at 300 words, 3 of 3 at 80 words). Do not go below 1024 for Standard; Quick-sized answers also completed at 768 (3 of 3, too few to promise).

Cost, at the rate table's selling prices (anthropic-api out 1,000,000 micro/K = 1.0 credit per 1K output tokens, in 200,000 micro/K = 0.2 credit per 1K input), assuming a 3-provider panel with Anthropic as the highest output rate, one search, allowance 192:
- Quick (1 round, 80 words, outCeil 288 to 1024): Anthropic round row +736 out tokens = +0.74; `synth` row (outMax = max outCeil, highest rate) +0.74; `answerBytes` for Anthropic 1,152 to 4,096 bytes adds 2,944 to the synthesis input bound = +0.59; allowance 192 on 2 rows = +0.38. About **+2.5 credits**: Quick+search 15-17 becomes about **18-20**, under the 25-credit starter-grant rule.
- Standard/thorough (2 rounds, 200 words, outCeil 528 to 1024): two Anthropic rows +0.99, synth +0.50, round-2 and synthesis input bounds (+1,984 bytes per answer, 3 providers, 2 rounds) about +1.98, allowance about +0.58: about **+4 credits**. Standard's current quote was not given; add this to it.
- Separate finding: `searchInTokensPerSearch` is 6000 in the table, but a one-search Anthropic call measured 12.7k-14.5k input (3k for the tool, 8-11k for the results). If the table is not raised to about 12,000 per search, the input bound is exceeded (clamped, alarmed). Raising it costs +1.2 credits per Anthropic search row per search at 0.2 credit/K. That is a quote increase that comes with, but is independent of, this change.

What must change:
- **Cloud (not changed here):** add a provider field (for example `searchOutputTokens: 1024`) so that when search is effective for anthropic-api, `outputCeiling` returns `max(formula, searchOutputTokens)` for that provider (the quote's `max_tokens` map and `answerBytes = 4 x outCeil`), and the manifest bound is that value plus `reasoningAllowanceTokens` (192, sized from the +142 maximum overrun; the overrun can still happen in the first call if the cap is reached). Keep `maxOutputTokens` at 1024 (the deploy ceiling `ANTHROPIC_API_MAX_TOKENS=1024`). Without search nothing changes (A/B cells: never over the cap, 12 of 12 answered). Raise `searchInTokensPerSearch` for anthropic-api to about 12,000 (measured; the table says 6,000).
- **Engine/adapter (this repo):** nothing new is needed to send the larger limit: e3d-debate already sends the quote's per-provider `max_tokens` (`E3D_DEBATE_MAX_TOKENS`) for every call of that provider, and the answer-bytes cut already follows `E3D_DEBATE_ANSWER_BYTES_MAX`. One caveat to decide with the cloud change: the limit is per provider, not per call, so the Anthropic *synthesis* call (no search) and no-search retries also get 1024; harmless (the answer still ends at `end_turn`) but it is why the synthesis bound is raised too. The truncation-is-no_text check and the retry/fallback in this PR stay as the safety net.
- **Tests:** cloud: quote vectors for anthropic-api with and without search (outCeil 1024 only with search), manifest bound = 1024 + 192, Quick+search under 25 credits, a settle with an output of 1024+142 clamped without alarm up to the allowance, `searchInTokensPerSearch` input bound. This repo: `tests/pertoken-search.sh` already asserts the per-provider limit reaches the adapter; add a case with `E3D_DEBATE_MAX_TOKENS` anthropic-api 1024 (no change expected) if the cloud adds the field.

Spend for this follow-up: 39 real calls; about $1.34 at the documented $2/$10 per million tokens (about $2.0 at a conservative $3/$15). No production calls.
