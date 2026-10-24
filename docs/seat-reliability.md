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
