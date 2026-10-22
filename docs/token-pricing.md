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
   unpriced call), web search and the Jev call (nothing unpriced runs), so at most one vendor call is made per `r<round>:<provider>` and one
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

## Prompt overhead for the rate table

`E3D_DEBATE_PROMPT_OVERHEAD=1 bin/e3d-debate --providers anthropic-api,openai-api --rounds 2` prints the byte counts of the fixed text of each
prompt kind (round 1, round N, synthesis), built with an empty question and empty answers, as `promptOverheadBytes`. The counts include the
per-answer headers, so they depend on the providers, rounds and prompt version; the owner copies the deployed panel's numbers into the rate table.
A prompt change is a new `prompt_version`.

## Known limits

- xAI reasoning tokens are billed but not capped by `max_tokens`, so `xai-api` is refused per token unless `E3D_MCP_PER_TOKEN_ALLOW_XAI=1`.
  Gemini thinking tokens and OpenAI reasoning tokens do count against the limit the adapters send.
- Web search is off in a per-token debate (it is not priced).
- A debate process killed with SIGKILL (not SIGTERM) leaves only the rows of finished rounds; the missing calls fall to billing's fallback.
- The usage report is sent from memory, not through the outbox: a crash between the report and finalize finalizes without a report.
