# The single-model chat run

One message, answered by one model, with the conversation so far as context. This is the engine half of "chat with one model" (cloud `docs/ask-chat-mode-spec.md`): a debate needs a council, a chat needs one voice. Like the recap job, the engine only runs the call. The hosting service owns the conversation (it keeps the messages and builds the list sent here) and the money (it reserves before and settles from the usage returned).

## The route

`POST /internal/chats` on the run listener (same loopback address and service token as `/internal/runs`), body up to 256 KB:

```json
{ "request_id": "chat-123-4", "provider": "openai-api", "max_tokens": 700,
  "messages": [ { "role": "user", "text": "..." }, { "role": "assistant", "text": "..." }, { "role": "user", "text": "..." } ] }
```

Answers:

| Status | Body | Meaning |
|---|---|---|
| 200 | `{ ok: true, answer, usage }` | `usage` is `{ input_tokens, output_tokens, model }` as the adapter reported it, or null |
| 200 | `{ ok: false, code: "unusable", usage }` | the call was made and answered with nothing; `usage` says what it used so it can be settled |
| 400 | `invalid` | unknown field, bad ids, a limit out of range, a bad conversation |
| 403 | `not_allowed` | the provider is not on `E3D_MCP_CHAT_PROVIDERS` |
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

## Not here yet

Streaming (the answer arrives whole), tools or web search, native chat roles, and any memory: the hosting service owns the conversation and, later, memory (cloud `docs/ask-chat-memory-spec.md`). Pricing and storage of conversations are the hosting service's job.

## Tests

`bash tests/mcp-chat.sh`: configuration, the conversation checks, the prompt (including a hostile message), the runner (limit variable, idempotency, every refusal, empty and failed calls with their usage, bounds, cancellation, no message text in logs), and the route (service token, unknown fields, long conversations, 413, 503 with retry, `chat_v1` advertised, a caller hanging up, 404 when off).
