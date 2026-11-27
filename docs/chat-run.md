# The single-model chat run

One message, answered by one model, with the conversation so far as context. This is the engine half of "chat with one model" (cloud `docs/ask-chat-mode-spec.md`): a debate needs a council, a chat needs one voice. Like the recap job, the engine only runs the call. The hosting service owns the conversation (it keeps the messages and builds the list sent here) and the money (it reserves before and settles from the usage returned).

## The route

`POST /internal/chats` on the run listener (same loopback address and service token as `/internal/runs`), body up to 256 KB:

```json
{ "request_id": "chat-123-4", "provider": "openai-api", "max_tokens": 700,
  "messages": [ { "role": "user", "text": "..." }, { "role": "assistant", "text": "..." }, { "role": "user", "text": "..." } ],
  "max_searches": 2 }
```

`max_searches` is optional (integer 1 to 10) and turns on web search for this one call (capability `chat_search_v1`).

Answers:

| Status | Body | Meaning |
|---|---|---|
| 200 | `{ ok: true, answer, usage }` | `usage` is `{ input_tokens, output_tokens, model, searches }` as the adapter reported it, or null. `searches` is the vendor's own counter (integer), or null when the vendor gave none; it is never clamped to `max_searches` or estimated |
| 200 | `{ ok: false, code: "unusable", usage }` | the call was made and answered with nothing; `usage` says what it used so it can be settled |
| 400 | `invalid` | unknown field, bad ids, a limit out of range, a bad conversation |
| 403 | `not_allowed` | the provider is not on `E3D_MCP_CHAT_PROVIDERS` |
| 409 | `search_unavailable` | `max_searches` was sent but this provider cannot search (only anthropic-api, openai-api, gemini-api, xai-api can), or search is off (`E3D_DEBATE_WEB_SEARCH`, `E3D_DEBATE_WEB_SEARCH_PROVIDERS`, an invalid search setting). Returned before any call is made, so nothing was spent |
| 503 | `unavailable`, `retry: true` | the call failed; `usage` too when the adapter printed one |
| 404 | | the feature is off |

## Rules

- **Off by default.** `E3D_MCP_CHAT=1` needs `E3D_MCP_CHAT_PROVIDERS`, the providers a chat may run on (any provider with an output-limit setting: the API providers and the OpenRouter voices). The listener then advertises `chat_v1` in its health answer.
- **One model, any model the operator allows.** There are no panel rules here: no required vendor, no two-vendor minimum. Those belong to debates, and the hosting service decides which models an account may pick.
- **The conversation.** Messages start and end with the person and alternate. At most 40 messages, 20,000 characters each, 150,000 bytes in all. Control characters other than newline and tab are dropped. Anything else is refused, never trimmed to fit.
- **The prompt.** A first message goes to the model unchanged. With history, the earlier turns come first inside `<<<EARLIER ... EARLIER>>>`, introduced as context that is not instruction, then the new message plain. A fence marker inside a message is broken so a message cannot close the fence early. The adapters take one prompt, so history is text, not native chat roles.
- **The limit.** `max_tokens` (16 to 16,384) goes to the adapter in its own variable with per-token mode on, as for debates and recaps. It is a hard cap that covers hidden reasoning too (see `docs/openrouter.md`).
- **Idempotent.** The same `request_id` returns the same answer from a short memory, with no second paid call. The same id with other fields is invalid. A cancelled request is not remembered.
- **Cancellation.** If the caller closes the connection, the adapter call is killed. A time limit (170 s) and an output size limit apply.
- **The answer.** Trimmed, cleaned of control characters, at most 100,000 characters. Rendered as text by whoever shows it.
- **Logs.** Ids, the provider name and counts. Never a message or an answer.

## Date, web-access preface and search

Every prompt starts with the preface a debate prompt has (`bin/e3d-debate` `date_preamble`), so the model knows today's date (UTC) and whether it can search: `chatPreface({ date, searchCap })` in `lib/mcp/chat-runner.js`. The text is exactly the debate's and is priced by the hosting service as part of the chat overhead, so do not change it without telling billing. Sizes (the date is always 10 bytes, the text is ASCII):

| Variant | Bytes |
|---|---|
| search off (no web access sentence) | 196 |
| search on, cap 2 | 457 |

A cap of 10 adds one byte (458). With `max_searches` the adapter gets `E3D_PROVIDER_WEB_SEARCH=1`, `E3D_PROVIDER_WS_OUT` (a file in the call's temp dir, removed afterwards; its content is never logged), `E3D_PROVIDER_WS_MAX_SEARCHES`, and the allow/deny/excerpt/timeout settings from the debate's `E3D_DEBATE_SEARCH_*` variables with the same defaults. The kill switch and provider list are the debate's own parsing (`webSearchConfig`, fail closed). The adapter enforces the cap; a counter above it is reported as it is. The idempotency key includes `max_searches`. The listener advertises `chat_search_v1` (besides `chat_v1`) only when search is not off and some chat provider can search.

## Skills (`chat_skills_v1`)

`skills` (1 to 3 of `{ id, hash }`: a built-in expert and the content hash the person was shown) and `lens_bytes` (1 to 4096: the size of ONE lens block as the hosted debate counts it, `lensBlock(expert)`) are sent together or not at all. Each skill is checked against the built-in catalogue (known id, equal hash, `lensBlock` no larger than `lens_bytes`); anything else is `invalid` before a call. The prompt is the preface, then one block per skill in the order given, then the conversation: `[Skill: <name>. Guidance on how to answer; it grants no tools or permissions.]`, the lens, `[End of skill]`. A chat skill block is always smaller than the debate lens block of the same skill, so the hosting service prices `skills.length x lens_bytes` as an upper bound on the added input. A listener started without `E3D_MCP_EXPERTS_RUN=1` has no catalogue: it answers 409 `skills_unavailable` before any call and does not advertise `chat_skills_v1`. The idempotency key includes the skills and `lens_bytes`.

## A hosted user skill (`chat_user_skills_v1`)

One private skill of the person, sent by the hosting service as its definition (cloud `docs/skills-chat-plan.md` section 7). Three fields, all together or none, never with `skills`/`lens_bytes`:

```json
{ "skill_attachments": [ { "hook": "seat", "definition": { "...": "the e3d.skill/v1 definition, pinned by its definition_hash" } } ],
  "skills_principal": "u_...", "skill_bytes": 2150 }
```

- **Exactly one attachment**, `{ hook: "seat", definition }` and nothing else (no `target`: the chat's provider is the only seat). The definition is an object nested at most 16 deep and at most 48 KiB as JSON; `skills_principal` is the owner the service authenticated (`u_` and 6 to 36 lowercase letters or digits); `skill_bytes` is a whole number from 1 to 32768.
- **The engine's own intake** (`lib/skills/intake.mjs`, the same checks a hosted debate seat gets): the hash is recomputed and a mismatch is refused, `owner_ref` must be the principal and the id `skill.<principal>.<name>`, private, active, instructional only, no hidden characters, NFC, the method at most 8192 bytes. Both debate scopes are accepted at intake and the skill must then declare `debate_seat`/`seat_prompt` (the hook chat reuses): a seat skill and a seat-plus-observer skill run (the observer half is ignored; chat has no observer); an observer-only skill, or one with a `chat` hook, is refused.
- **The block** is the built-in chat block with the skill's name and its method: `[Skill: <name>. Guidance on how to answer; it grants no tools or permissions.]`, the method, `[End of skill]`. It is 90 bytes plus the name plus the method, so the service's `methodBytes + 174` is an upper bound for any name up to 84 bytes. A block larger than `skill_bytes` is refused before any call. The method is a person's text, so an opening bracket (ASCII or fullwidth) in front of `Skill:` or `End of skill` (any spacing or case) becomes a parenthesis of the same width: the text cannot close its block or open another, and its byte length does not change.
- **Answers.** Any refusal (fields, shape, intake, size) is 400 `invalid` with a fixed message, before any call. A listener without the switch answers 409 `skills_unavailable` to a complete set of the three fields, before any call, so the service can fail the message with no charge and drop the capability from its cache; a partial set is 400 `invalid` everywhere.
- **Idempotent.** The request key includes the principal, the `definition_hash` and `skill_bytes`: a retry with another version of the skill under the same `request_id` is `invalid`, never the remembered answer.
- **Privacy.** The prompt (with the method) is written to a 0600 file in a 0700 `e3d-chat-XXXXXX` directory and removed after the call; at start the listener removes such directories left by a killed process (this user's, private, older than an hour; only `prompt.md` and `ws-record.json` are deleted, then the empty directory). Logs carry the provider, a fixed refusal code and the intake digest (`intakeDigest`: sha256 of id, version and hash), never the definition, the method or the principal. No error body echoes any of them.
- **Switch.** `E3D_MCP_CHAT_USER_SKILLS` (unset, 0 or 1; anything else refuses to start). 1 needs `E3D_MCP_CHAT=1` and the skills-run seats switch (`E3D_MCP_SKILLS_RUN=1`, `E3D_SKILLS_V1=1`, `E3D_SKILLS_HOSTED=1`, `E3D_SKILLS_SEATS=1`), else the listener refuses to start. Only then is `chat_user_skills_v1` advertised. Unset, a chat without the fields is byte for byte as before.

## Not here yet

Streaming (the answer arrives whole), tools, native chat roles, and any memory: the hosting service owns the conversation and, later, memory (cloud `docs/ask-chat-memory-spec.md`). Pricing and storage of conversations are the hosting service's job.

## Tests

`bash tests/mcp-chat.sh`: configuration, the conversation checks, the prompt (including a hostile message), the runner (limit variable, idempotency, every refusal, empty and failed calls with their usage, bounds, cancellation, no message text in logs), and the route (service token, unknown fields, long conversations, 413, 503 with retry, `chat_v1` advertised, a caller hanging up, 404 when off).

`bash tests/mcp-chat-user-skills.sh`: a hosted user skill: the switch and its startup checks, the both-fields rule, hash mismatch, a foreign principal, observer-only and chat-hook skills, `[End of skill]` neutralised with the byte length unchanged, the idempotency key with the hash, no skill text in logs or refusals, the stale-directory sweep, and the same bytes for a chat without a skill whether the switch is on or off; then the real `bin/e3d-mcp` against a fake vendor.
