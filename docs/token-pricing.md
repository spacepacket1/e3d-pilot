# Token pricing (`per_token_v1`) in e3d-pilot

This is e3d-pilot's half of the billing service's token pricing (`PILOT_PRICING_MODE=per_token`; the contract is the billing repo's
`docs/token-pricing-interface.md`). Nothing here changes the frozen hook protocol (`docs/external-auth/*`, `CONTRACT-VERSION`) or the
Debate contract v1 schemas: the quote and the usage report are versioned side channels, like the panel resolve, and the finalize
answer's new `pricing` field is additive.

`E3D_MCP_PRICING` unset: every behaviour is unchanged, and a run body without the new fields is handled exactly as before (so a billing
service in `per_debate`, or rolled back to it, keeps working against a server that still advertises the capability).

## What `E3D_MCP_PRICING=per_token` does

1. **Capability.** The run listener's health answer (an empty `POST /internal/runs`, `400 {"ok":false,"code":"invalid"}`) adds
   `"capabilities": ["per_token_v1"]`. Startup refuses without the hook, in stdio mode, or without `E3D_MCP_CUSTOMER_LIMITS` stated.
2. **Web runs.** `POST /internal/runs` accepts `rounds`, `max_words`, `max_tokens {provider: n}` and `answer_bytes {provider: n}`: all four
   or none. They are honoured exactly or the body is refused `400 invalid` (never clamped, never defaulted): `rounds` or `max_words` above
   `E3D_MCP_CUSTOMER_LIMITS`, a provider without both limits, a provider that cannot be priced (CLI and sampling voices), `xai-api`
   (see below). The fields are part of the idempotency key. A listener without `E3D_MCP_PRICING=per_token` refuses the fields, because it
   never advertised the capability.
3. **Connector debates.** For a hosted `e3d_debate` or `e3d_debate_start`, after the panel is resolved and before the reserve, the server asks
   `POST /pricing/v1/quote` (`X-E3D-Pricing-Version: 1`) with the request id the reserve will use. A refusal (`unknown_model_rate`,
   `quote_exceeds_limit`) stops the call before anything is reserved. The reserve then carries `units.calls = providers x rounds + 1`, and the
   debate runs under the quote's `max_tokens` and `answer_bytes`.
4. **Enforcement (`bin/e3d-debate`).** `E3D_DEBATE_MAX_TOKENS` makes every adapter send that vendor output limit (Anthropic `max_tokens`, OpenAI
   `max_completion_tokens`, Gemini and xAI `max_tokens`), disables retries (a retry after the vendor may have been reached would be a second,
   unpriced call), web search (unless quoted, see below) and the Jev call (nothing unpriced runs), so at most one vendor call is made per `r<round>:<provider>` and one
   for `synth`. `E3D_DEBATE_ANSWER_BYTES_MAX` cuts every prior answer inserted into a round-N or synthesis prompt to that many UTF-8 bytes of
   its provider's answer, on a character boundary (`transcript.md`, the record, keeps the whole answer).
5. **Usage.** The adapters print normalised `input_tokens` and `output_tokens` in their `e3d_provider_usage=` line (Anthropic: input plus cache
   writes and reads; OpenAI-compatible: `prompt_tokens`, and the larger of `completion_tokens` and `total_tokens - prompt_tokens`, so reasoning and
   thinking tokens are counted). `e3d-debate` writes `usage.json` (an array, rewritten after every round and the synthesis, and on SIGTERM): one row
   per attempted call, `source: "vendor"` with the vendor's counts, or `source: "bytes"` when the usage line is missing: `input_tokens` = UTF-8
   bytes of the prompt sent, `output_tokens` = UTF-8 bytes of the output, or the call's `max_tokens` when the response was lost. A call the vendor
   refused (an HTTP error) or that never left (no key, no connection) has no row. A stopped debate reports its calls that were under way.
   e3d-mcp sends the rows to `POST /usage/v1/report` (`X-E3D-Usage-Version: 1`) before finalize, retrying 5xx, 429 and transport failures with the same body. A 400 or 409,
   or giving up, is logged and the debate is finalized anyway (billing then prices the v1 totals and alarms).
6. **Result.** The finalize answer's `pricing` object becomes `billing.quote_credits`, `billing.charged_credits` and `billing.usage {input_tokens,
   output_tokens, source}` in the tool result, and the text says "Charged N credits (at most M were held)". `usage.estimate` is true unless the source is `vendor`.

## Web search inside per-token pricing (`per_token_search_v1`)

Billing prices web search inside the quote (its `docs/token-pricing-search-spec.md`; the contract is its section 22.1). Everything here is
dark until `E3D_MCP_PER_TOKEN_SEARCH=1` (with `E3D_MCP_PRICING=per_token`, and web search on here: `E3D_DEBATE_WEB_SEARCH`, `E3D_DEBATE_WEB_SEARCH_PROVIDERS`;
startup refuses otherwise). Unset: PR #30's behaviour exactly (search off, version 1 everywhere, the old health answer).

1. **Capability.** The health answer becomes `"capabilities": ["per_token_v1", "per_token_search_v1"]`.
2. **Web runs.** `POST /internal/runs` accepts `max_searches {provider: k}` (1..10, searching providers only) and `cite_bytes` (0..20000): both or neither,
   only with the four token fields. Honoured exactly or refused `400 invalid`, never clamped or defaulted (also by a listener without the capability, and for
   a provider this server does not search with); part of the idempotency key; `web_search: false` with them is refused. A `400` releases nothing on this side.
3. **Connector debates.** With search wanted (the call's `web_search` is not `false`), the quote request is `X-E3D-Pricing-Version: 2` with `searches {provider: k}`
   (cap 2 on every searching API provider of the panel; `E3D_DEBATE_SEARCH_MAX_PER_CALL` overrides the requested cap). The answer's `search` object
   (`max_searches`, `cite_bytes`, `credits_off`) is what runs; a missing, disabled or unusable one means search off. Without search the request is the version 1 one.
4. **Enforcement (`bin/e3d-debate`).** `E3D_DEBATE_MAX_SEARCHES` and `E3D_DEBATE_CITE_BYTES_MAX` (both or neither) replace the forced search-off: a provider searches
   only if the map names it (and the allowlist and kill switches agree); the number in its prompt and the adapter's cap are its own priced cap, not
   `E3D_DEBATE_SEARCH_MAX_PER_CALL`. Native caps: Anthropic `max_uses`, OpenAI `max_tool_calls`; xAI `max_turns` is only a reducer and Gemini has none, so an
   over-cap count there is detected after the fact (`ALARM web_search_cap_exceeded`, raw count reported). The synthesizer never searches.
5. **One request per call.** A search call is exactly one vendor request: no retry, no Anthropic `pause_turn` continuation (the text that came back is the
   answer), and no second call without search (a failed search call leaves that voice without an answer for the round). The adapters are `curl` with no
   retry flags; they are told by `E3D_PROVIDER_PER_TOKEN=1`. A response that arrived is reported even when our own checks refuse it (the vendor billed it).
6. **Usage.** Search-call usage lines carry `input_tokens` (search-result tokens included as the vendor reports them) and `output_tokens`. Rows gain `searches`
   under `X-E3D-Usage-Version: 2`: the vendor's raw counter (never clamped here), `0` for a call made without the search tool, `null` for a lost or
   byte-estimated response. Gemini's usage field names are best-effort until the dry run (`null` falls back to bytes, never an undercount).
7. **Citations.** The citation list that starts a searched answer is cut to `cite_bytes` UTF-8 bytes in later prompts, separately from the answer's own
   answer-bytes limit; `transcript.md` keeps it whole.
8. **Result.** The finalize `pricing.search {searches, charged_credits_search}` becomes `billing.searches` and `billing.search_credits`; the text says
   "includes N web searches". `E3D_MCP_DAILY_SEARCHES` defaults to 160 on a server that advertises the capability.
9. **Truthful tool text.** The tool descriptions, `e3d_list_providers` and the per-debate result line state whether web search is on or off on this server
   (the privacy notice appears only where search can be on), and the listing's default panel is the deployment's effective one.

`E3D_DEBATE_PROMPT_OVERHEAD=1 E3D_DEBATE_PROMPT_OVERHEAD_SEARCH=1` also prints the prompt overhead of a searching call and the longest citation list a
searching answer can start with (for the rate table's `searchCiteBytes`). Tests: `tests/pertoken-search.sh`, shared vectors in `tests/fixtures/search-vectors/`
(a copy of billing's; sync and update `MANIFEST.sha256`).

## Prompt overhead for the rate table

`E3D_DEBATE_PROMPT_OVERHEAD=1 bin/e3d-debate --providers anthropic-api,openai-api --rounds 2` prints the byte counts of the fixed text of each
prompt kind (round 1, round N, synthesis), built with an empty question and empty answers, as `promptOverheadBytes`. The counts include the
per-answer headers, so they depend on the providers, rounds and prompt version; the owner copies the deployed panel's numbers into the rate table.
A prompt change is a new `prompt_version`.

## Known limits

- xAI reasoning tokens are billed but not capped by `max_tokens`. The owner has allowed `xai-api` per token (a daily vendor-cost alarm and a kill switch, billing's
  spec 12), so the gate stays but is set: `xai-api` is offered only with `E3D_MCP_PER_TOKEN_ALLOW_XAI=1`; unset it to drop xAI at once.
  Gemini thinking tokens and OpenAI reasoning tokens do count against the limit the adapters send.
- Web search is off in a per-token debate unless the quote priced it (see the section above).
- A debate process killed with SIGKILL (not SIGTERM) leaves only the rows of finished rounds; the missing calls fall to billing's fallback.
- The usage report is sent from memory, not through the outbox: a crash between the report and finalize finalizes without a report.
