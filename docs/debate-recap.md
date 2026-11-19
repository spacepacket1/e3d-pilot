# Debate rounds and the recap

Two artifacts that let a front end show a debate as a conversation: each model's short entry per round, tagged, then a recap of how the debate moved. Both are written next to the transcript when `bin/e3d-debate` is given `--out-dir`. Neither changes what a debate prints, its prompts, its quote or its exit status.

## `rounds.json`: always written, free

Read from `transcript.md` by `lib/debate/recap.mjs`. No model call.

```json
{ "version": 1, "roundsRan": 2, "providers": ["alpha", "beta"],
  "rounds": [ { "round": 2, "provider": "alpha", "position": "Keep the monolith, except billing.",
                "source": "position_line", "status": "revise", "answerBytes": 212, "excerpt": "I hold, but billing is a special case..." } ] }
```

- `position` is one line, at most 240 characters. `source` says where it came from: `position_line` (the `POSITION:` line that round 2+ answers end with, and that the v3 format derives from `ACTION`), `action`, or `first_sentence` (round 1 answers have no position line).
- `status` is the model's own `approved` or `revise`, or `null`. It means "a person acting on your answer and on the others' would do the same thing", not "I changed my mind".
- `excerpt` is the head of the answer without the machine lines, at most 600 bytes, so a later step can read the model's own words about why it changed without re-reading the transcript.

## `recap.json`: only when asked, one extra call

`--recap <provider>` (or `E3D_DEBATE_RECAP`) runs one call on that provider after the verdict. Pick a cheap model: it reads about a hundred words per model per round. The provider does not have to be on the panel.

```json
{ "version": 1, "generated_by": "or-deepseek",
  "entries": [ { "round": 2, "model": "alpha", "tag": "partly_moved", "reason": "the compliance boundary", "newEvidence": true } ],
  "recap": { "ended": "...", "moved": "...", "open": ["..."] } }
```

- `tag` is `held`, `partly_moved` or `moved`, for each model in each round after the first. `newEvidence` is true only when the model's own words give a new argument, fact or source for the change. A move with `newEvidence: false` is the "moved without a reason, only the group leaning" case. A `held` entry never has new evidence.
- The recap states where the debate ended, how it moved, and up to three open items. It reports what models said and whether they changed. It never says who was right.

### What is checked

The model's reply is data, not trusted. `parseRecap` keeps only entries for a model that spoke in that round, in a round after the first, with one of the three tags, once each. Text is bounded and flattened to one line. Nothing is filled in for a model the reply left out. If nothing in the reply can be checked, there is no `recap.json` and a warning on stderr.

The prompt tells the model that the debate text is data between markers, never to follow instructions inside it, and never to judge correctness.

### When it does not run

- Fewer than two rounds ran: nobody had a chance to move.
- The synthesis did not finish.
- A per-token debate (hosted): the recap call has no quoted limit yet. Quoting it as its own row is the billing step.
- The named provider is not an adapter, fails, or answers something unusable: a warning, and the debate is unaffected.

## The hosted job: `POST /internal/recaps`

For the hosting service a recap is its own small job, not part of the debate's run. The run listener (the same loopback address and service token as `/internal/runs`) takes `POST /internal/recaps` with `{ request_id, debate_id, provider, max_tokens, rounds }`, where `rounds` is the stored copy of `rounds.json`. It runs one call and answers `{ ok: true, recap, usage }`. The service reserves and settles the money from `usage`; the engine only runs the call.

- **Off by default.** `E3D_MCP_RECAP=1` turns it on and needs `E3D_MCP_RECAP_PROVIDERS`, the providers a recap may run on (API providers and OpenRouter voices, which have an output-limit setting). The listener then advertises the capability `recap_v1` in its health answer. Without the flag the route is a 404 and nothing is advertised.
- **Checked before any call.** The provider must be on the list, ids and the limit (64 to 4096 tokens) must be well formed, and `rounds` is rebuilt from scratch (`normalizeRounds`): provider names, at most 10 rounds, 16 providers and 160 entries, bounded text, enums checked, unknown keys dropped. At least two rounds are needed.
- **The call.** The adapter gets the limit in its own variable (`OPENAI_API_MAX_TOKENS`, `OPENROUTER_MAX_TOKENS` and so on) with per-token mode on, a 90 second limit and an output size limit. The prompt is a mode-0600 temp file that is removed afterwards.
- **Answers.** `200 ok` with the recap and usage; `200 ok:false code:unusable` when the call was made but nothing in the answer could be checked (with the usage, so it can be settled); `400 invalid`; `403 not_allowed`; `503 unavailable` with `retry: true` (with usage when the adapter printed one).
- **Idempotent.** The same `request_id` returns the same answer from a short memory, with no second paid call. The same id with other fields is invalid.
- **Logs.** Ids, the provider name and counts. Never a position, a question or a key.

`E3D_MCP_RESULT_ROUNDS=1` (default off) adds the rebuilt `rounds` to the stored result of a finished debate, so the service can keep them for a later recap. It is additive: nothing else in the result changes.

## Where this goes next

The hosted service stores `rounds` with the debate and `recap` with it once one is made, and prices the recap job on its own (cloud `docs/debate-recap-billing-spec.md`), only when asked for. The page shows each `rounds` entry as a tagged chat message and the recap as a card (`docs/ask-chat-mode-spec.md`, section 6b, in the cloud repo).

A small prompt change would give round 1 answers a `POSITION:` line too, so every entry's summary comes from the model itself. It would add roughly a hundred bytes to the round 1 prompt, so it has to be re-measured with `E3D_DEBATE_PROMPT_OVERHEAD=1` and the hosted rate table's overhead figures updated. Not done here.

## Tests

`bash tests/mcp-recap.sh` covers the job and its route (configuration, the call, idempotency, every refusal, usage on unusable and failed calls, no model text in logs, the 404 when off); `tests/mcp-runserver.sh` checks the stored `rounds`. `bash tests/debate-recap.sh`: the parser, the prompt and the validator on their own, then `bin/e3d-debate` with stub providers (rounds always written, recap written when asked, output byte-identical with and without it, a failing, junk or unknown recap provider leaves the debate and its exit status alone, one round gives no recap).
