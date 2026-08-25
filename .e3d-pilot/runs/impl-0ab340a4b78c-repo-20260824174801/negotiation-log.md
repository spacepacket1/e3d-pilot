---
run_id: impl-0ab340a4b78c-repo-20260824174801
---

# Negotiation Log

## Round 1

### Draft Before Round

```text
# Fleet Ops: Discord Engagement Signal

## Overview

Extend fleet discovery’s existing `## Live Operations` facts with an optional, independent Discord engagement signal. For each configured Discord account, collect a fresh read-only snapshot of recent bot-authored channel messages and their reaction counts, then expose honest success, empty, and failure states to the cross-repository ideation prompt.

This is Part 2 of the fleet-operations work. Moltbook support remains a separate follow-on so the cumulative implementation stays within five changed files and the repository’s 900-line ceiling.

## Goals

- Support an optional top-level `social_accounts` array containing Discord account definitions.
- Fetch recent channel messages using one authenticated Discord API request per configured account.
- Count the most recent 10 bot-authored messages and sum their reaction counts.
- Distinguish no recent bot messages, zero reactions on real messages, and collection failures.
- Append `### Social Engagement` after `### Live Instance Status` within `## Live Operations`.
- Request operational recommendations for zero-engagement accounts and collection failures.
- Preserve existing fleet cadence, approval gates, provider dispatch, and live-instance behavior.
- Keep credentials exclusively in runtime environment variables.

## Non-Goals

- Moltbook, X/Twitter, Telegram, Farcaster, or other social platforms.
- Posting, replying, reacting, voting, or any other write operation.
- Historical metrics, trends, persistence, or analytics storage.
- Reading or modifying bot-local state such as `discord-state.json`.
- Modifying any file under `/Users/mini/e3d/**`.
- Changing single-repository discovery or ideation.
- Changing candidate scoring, negotiation, execution, review, publication, or ledger schemas.
- Changing `try_stage_provider` or any provider-panel dispatch loop.
- Changing `tests/phase25.sh` or any other pre-existing test.
- Rotating, relocating, or otherwise changing existing Discord credentials.

## Existing Files

- `lib/ops/collect-fleet-health.sh` contains the live-instance validation, collection, and rendering structure. Read it completely and preserve its existing behavior.
- `bin/e3d-pilot` contains `validate_fleet_discover_config`, `build_fleet_discover_facts_markdown`, `build_fleet_discover_prompt`, and `fleet_discover_stage`.
- `examples/sample-fleet-config-with-ops.json` demonstrates the existing live-operations configuration.
- `README.md` documents fleet discovery, `live_instances`, and `## Live Operations`.
- `tests/phase17.sh` and `tests/phase21.sh` demonstrate the test-owned fake-executable-on-`PATH` convention.
- `/Users/mini/e3d/agents/scripts/discord-heartbeat.js` may be read to confirm the real Discord API response shape but must not be modified.

## Shared Constraints

- Change only the five files named by the phase’s `pilot:touches` annotations.
- Keep the cumulative change below 900 changed lines and at no more than five changed files. If necessary, reduce redundant test setup or scenarios without dropping the required behavioral coverage.
- Do not modify `LICENSE`, `docs/build-e3d-pilot.md`, `.github/workflows/**`, `.e3d-pilot/**`, `.git/**`, any pre-existing test, or any file under `/Users/mini/e3d/**`.
- Preserve `try_stage_provider`, `discover_stage`, `ideate_stage`, and the provider-panel dispatch behavior inside `fleet_discover_stage`.
- Preserve byte-identical fleet-discovery output when `social_accounts` is absent or empty.
- Route every outbound request through `curl`, allowing tests to block network access by shadowing it on `PATH`.
- Every request must use `--max-time 10`, `--max-redirs 1`, an HTTP/HTTPS-only restriction supported by the repository’s established curl invocation, and `--` immediately before the URL.
- Perform exactly one request per configured Discord account and never retry, including after HTTP 429.
- Use `GET https://discord.com/api/v10/channels/{channel_id}/messages?limit=50` with `Authorization: Bot <token>`.
- Read the token only from `DISCORD_BOT_TOKEN`. Never accept a token in configuration, log it, place it in facts output, or expose it through an error message.
- Do not enable `set -x`, invoke the collector through `bash -x`, or introduce a debug path that prints the Authorization header.
- A missing or empty token is an account-level collection failure, not a fatal collector error and not a reason to skip the account.
- Configuration errors are fatal and must be detected before any HTTP request for either live instances or social accounts.
- Treat every non-2xx response, including 429, as a collection failure reporting the HTTP status without fabricating counts.
- Treat a missing message `reactions` field as zero reactions.
- Count only messages whose `author.id` matches the authenticated bot user. Derive that bot user ID without an additional request, using the bot-author identity available in the returned messages and the repository’s established Discord response fixture contract; if the response does not provide an unambiguous authenticated-bot identity, report a collection failure rather than counting other authors’ messages or adding another request.
- From the matching bot-authored messages returned in newest-first API order, consider at most the first 10.
- Distinguish “no recent messages found” from a nonzero message count with zero total reactions.
- Render accounts in configuration order.
- All new or edited shell code must work under Bash 3.2. Do not use `declare -g`, `declare -ag`, case-conversion expansions, `mapfile`, `readarray`, associative arrays, or other Bash 4+ features. Use `tr '[:upper:]' '[:lower:]'` for lowercasing.
- Under `set -u`, guard empty or unset array expansion with `"${arr[@]+"${arr[@]}"}"`.
- Use only existing dependencies: Bash, `curl`, and `jq`.

## Phase 1 - Collect and Surface Discord Engagement

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=lib/ops/collect-fleet-health.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=examples/sample-fleet-config-with-ops.json -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=tests/phase27.sh -->
<!-- runner:read=lib/ops/collect-fleet-health.sh -->
<!-- runner:read=tests/phase17.sh -->
<!-- runner:read=tests/phase21.sh -->
<!-- runner:read=/Users/mini/e3d/agents/scripts/discord-heartbeat.js -->
<!-- runner:verify=set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done -->

### Requirements

1. Extend `lib/ops/collect-fleet-health.sh` with separate validation, collection, and rendering functions for `social_accounts`. Follow the existing `live_instances` organization while keeping the two signal implementations independent. Dispatch Discord through a platform-specific function so a later Moltbook ticket can add a sibling branch without changing Discord collection.

2. Accept an optional top-level `social_accounts` field. When present, it must be an array. Each entry must contain exactly:

   - `platform`: the string `discord`;
   - `name`: a non-empty display string;
   - `channel_id`: a non-empty string.

   Reject a wrong top-level type, non-object entry, unsupported or missing platform, missing or empty required field, and every extra field. Emit a clear stderr error and exit nonzero.

3. Integrate social validation into `validate_fleet_discover_config` before collection begins. Validate the complete live-instance and social configuration before issuing any HTTP request, so an error in either signal type causes zero requests overall.

4. For each valid Discord account, read `DISCORD_BOT_TOKEN` from the process environment. If it is unset or empty, record the exact failure reason `DISCORD_BOT_TOKEN not set`, issue no request for that account, continue processing other valid accounts, and never reveal any token value.

5. Make exactly one Discord messages request per credentialed account. Request up to 50 messages, restrict redirects and protocols as described in Shared Constraints, send the bot Authorization header, capture the HTTP status separately from the response body, and do not retry.

6. On a successful 2xx response, require a valid JSON array and identify messages authored by the authenticated bot without counting other authors. Consider at most the 10 newest matching bot messages. Sum every numeric `reactions[].count`, treating an omitted or null `reactions` field as an empty array. If the payload is malformed, reaction counts are invalid, or bot authorship cannot be established honestly, record a collection failure rather than partial or fabricated values.

7. Represent each account as exactly one result with its configured name, `discord` platform, and one of these states:

   - no matching recent bot messages;
   - matching message count plus total reactions, including a legitimate zero total;
   - failure with a clear, credential-safe reason.

   Request failures and non-2xx responses must include a useful reason or HTTP status. HTTP 429 must remain an ordinary non-retried failure.

8. Update `build_fleet_discover_facts_markdown` to append `### Social Engagement` within `## Live Operations`, immediately after `### Live Instance Status`. Render one line per configured account in configuration order. Omit the entire subsection when `social_accounts` is absent or empty; do not render an empty-state placeholder.

9. Update `build_fleet_discover_prompt` so `### Operational Recommendations` requests exactly one recommendation for each social account that reports either:

   - one or more considered messages with zero total reactions; or
   - a collection failure.

   Each requested recommendation must name the account and repeat its exact reported state without guessing a cause. Do not request a recommendation for nonzero engagement or for the “no recent messages found” state. Continue to omit the entire recommendations section when neither live-instance nor social results require a recommendation.

10. Preserve all existing live-instance validation, collection, rendering, recommendation behavior, and output formatting. With `social_accounts` absent or `[]`, fleet-discovery output must remain byte-for-byte identical to the pre-change behavior.

11. Add `tests/phase27.sh` following the test-owned temporary-directory and fake-executable-on-`PATH` conventions from `tests/phase17.sh` and `tests/phase21.sh`. The test must trap cleanup and keep fake curl state, bodies, status files, and traces inside its temporary directory. It must block accidental real network access and require no real credential.

12. In `tests/phase27.sh`, cover:

   - reactions summed across bot-authored messages while other authors are excluded;
   - only the 10 newest matching bot messages being counted;
   - zero reactions, including a message with no `reactions` field;
   - no matching recent bot messages as distinct from zero engagement;
   - missing and empty `DISCORD_BOT_TOKEN`, with zero requests;
   - an ordinary HTTP failure;
   - HTTP 429, with exactly one request and no fabricated zero;
   - malformed successful JSON as a failure;
   - configuration rejection for wrong `social_accounts` type, unsupported platform, missing required field, empty required field, extra field, and non-object entry;
   - validation failure occurring before any live-instance or social HTTP request;
   - account output order;
   - recommendation inclusion for zero engagement and failures;
   - recommendation exclusion for nonzero engagement and no recent messages;
   - absence of `### Social Engagement` when `social_accounts` is absent or empty;
   - token values never appearing in stdout, stderr, generated facts, or test-visible request diagnostics.

13. Add one fictional Discord entry to `examples/sample-fleet-config-with-ops.json`. Use an obviously fake channel ID and do not include any token or secret field.

14. Update the fleet-discover documentation in `README.md` to describe:

   - the optional `social_accounts` schema and currently supported `discord` platform;
   - the `DISCORD_BOT_TOKEN` environment requirement;
   - read-only, one-request-per-account behavior;
   - the meaning of successful, no-message, zero-engagement, and failure output;
   - `### Social Engagement` placement and its omission when configuration is absent or empty;
   - why this omission differs from the existing live-instance empty-state output;
   - zero-engagement and failure recommendation behavior;
   - Moltbook as a planned follow-on rather than current support;
   - credentials never belonging in fleet configuration.

15. Run the configured full repository verification command after implementation. Do not modify an unrelated pre-existing test to make failures pass.

### Acceptance Criteria

- The phase changes exactly the five annotated files and remains below 900 cumulative changed lines.
- Fleet discovery with no `social_accounts`, or with an empty array, produces byte-identical output to the baseline and contains no `### Social Engagement` heading.
- Valid stubbed Discord messages produce the correct bot-only message count and summed reaction count, limited to 10 matching messages.
- A missing `reactions` field contributes zero without causing an error.
- No matching bot messages are reported distinctly from matching messages with zero total reactions.
- Missing or empty `DISCORD_BOT_TOKEN` produces `DISCORD_BOT_TOKEN not set` and issues zero requests for that account.
- Stubbed HTTP 429 produces one failure result, causes no retry, and is never represented as zero engagement.
- Invalid configuration fails clearly before any HTTP request.
- Output contains no configured token value in success or failure cases.
- Each zero-engagement or failed account produces exactly one requested operational recommendation naming the account and repeating its reported state.
- Accounts with nonzero engagement or no matching recent messages produce no social recommendation.
- Social results and recommendations preserve configuration order.
- The sample configuration contains a fictional Discord account and no credential.
- README documents the schema, credential handling, output asymmetry, recommendation rules, and deferred Moltbook support.
- `try_stage_provider`, `discover_stage`, `ideate_stage`, provider-panel dispatch behavior in `fleet_discover_stage`, and every pre-existing test file remain unchanged.
- `set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done` passes under Bash 3.2 without network access or a real Discord token.

```

### Reviewer 1: claude

Status: approved

Reason: Requirements, goals, and acceptance criteria are mutually consistent, edge cases (empty token, 429, malformed JSON, ambiguous bot identity) all have well-defined fallback behaviors, and scope/file/line constraints are enforceable and testable.

Raw Response:

```text
---STATUS---
status: approved
reason: Requirements, goals, and acceptance criteria are mutually consistent, edge cases (empty token, 429, malformed JSON, ambiguous bot identity) all have well-defined fallback behaviors, and scope/file/line constraints are enforceable and testable.
```

### Reviewer 2: codex

Status: revise

Reason: Discord message payloads do not identify which bot is authenticated, so the draft cannot honestly distinguish “no matching messages” from ambiguous bot authorship without an explicit bot user ID.

Replacement Spec:

```spec
# Fleet Ops: Discord Engagement Signal

## Overview

Extend fleet discovery’s existing `## Live Operations` facts with an optional, independent Discord engagement signal. For each configured Discord account, collect a fresh read-only snapshot of recent channel messages and their reaction counts, then expose honest success, empty, and failure states to the cross-repository ideation prompt.

This is Part 2 of the fleet-operations work. Moltbook support remains a separate follow-on so the cumulative implementation stays within five changed files and the repository’s 900-line ceiling.

## Goals

- Support an optional top-level `social_accounts` array containing Discord account definitions.
- Fetch recent channel messages using one authenticated Discord API request per configured account.
- Count the most recent 10 messages authored by the configured bot user and sum their reaction counts.
- Distinguish no recent bot messages, zero reactions on real messages, and collection failures.
- Append `### Social Engagement` after `### Live Instance Status` within `## Live Operations`.
- Request operational recommendations for zero-engagement accounts and collection failures.
- Preserve existing fleet cadence, approval gates, provider dispatch, and live-instance behavior.
- Keep credentials exclusively in runtime environment variables.

## Non-Goals

- Moltbook, X/Twitter, Telegram, Farcaster, or other social platforms.
- Posting, replying, reacting, voting, or any other write operation.
- Historical metrics, trends, persistence, or analytics storage.
- Reading or modifying bot-local state such as `discord-state.json`.
- Modifying any file under `/Users/mini/e3d/**`.
- Changing single-repository discovery or ideation.
- Changing candidate scoring, negotiation, execution, review, publication, or ledger schemas.
- Changing `try_stage_provider` or any provider-panel dispatch loop.
- Changing `tests/phase25.sh` or any other pre-existing test.
- Rotating, relocating, or otherwise changing existing Discord credentials.

## Existing Files

- `lib/ops/collect-fleet-health.sh` contains the live-instance validation, collection, and rendering structure. Read it completely and preserve its existing behavior.
- `bin/e3d-pilot` contains `validate_fleet_discover_config`, `build_fleet_discover_facts_markdown`, `build_fleet_discover_prompt`, and `fleet_discover_stage`.
- `examples/sample-fleet-config-with-ops.json` demonstrates the existing live-operations configuration.
- `README.md` documents fleet discovery, `live_instances`, and `## Live Operations`.
- `tests/phase17.sh` and `tests/phase21.sh` demonstrate the test-owned fake-executable-on-`PATH` convention.
- `/Users/mini/e3d/agents/scripts/discord-heartbeat.js` may be read to confirm the real Discord API response shape but must not be modified.

## Shared Constraints

- Change only the five files named by the phase’s `pilot:touches` annotations.
- Keep the cumulative change below 900 changed lines and at no more than five changed files. If necessary, reduce redundant test setup or scenarios without dropping the required behavioral coverage.
- Do not modify `LICENSE`, `docs/build-e3d-pilot.md`, `.github/workflows/**`, `.e3d-pilot/**`, `.git/**`, any pre-existing test, or any file under `/Users/mini/e3d/**`.
- Preserve `try_stage_provider`, `discover_stage`, `ideate_stage`, and the provider-panel dispatch behavior inside `fleet_discover_stage`.
- Preserve byte-identical fleet-discovery output when `social_accounts` is absent or empty.
- Route every outbound request through `curl`, allowing tests to block network access by shadowing it on `PATH`.
- Every request must use `--max-time 10`, `--max-redirs 1`, an HTTP/HTTPS-only restriction supported by the repository’s established curl invocation, and `--` immediately before the URL.
- Perform exactly one request per configured Discord account and never retry, including after HTTP 429.
- Use `GET https://discord.com/api/v10/channels/{channel_id}/messages?limit=50` with `Authorization: Bot <token>`.
- Read the token only from `DISCORD_BOT_TOKEN`. Never accept a token in configuration, log it, place it in facts output, or expose it through an error message.
- `bot_user_id` is a public Discord user identifier used only for authorship matching; it is not a credential.
- Do not enable `set -x`, invoke the collector through `bash -x`, or introduce a debug path that prints the Authorization header.
- A missing or empty token is an account-level collection failure, not a fatal collector error and not a reason to skip the account result.
- Configuration errors are fatal and must be detected before any HTTP request for either live instances or social accounts.
- Treat every non-2xx response, including 429, as a collection failure reporting the HTTP status without fabricating counts.
- Treat a missing or null message `reactions` field as zero reactions.
- Count only messages whose `author.id` exactly matches the configured `bot_user_id`. Do not infer the authenticated bot from `author.bot`, the set of authors in the response, or the token, and do not add an identity request.
- From the matching bot-authored messages returned in newest-first API order, consider at most the first 10.
- Distinguish “no recent messages found” from a nonzero message count with zero total reactions.
- Render accounts in configuration order.
- All new or edited shell code must work under Bash 3.2. Do not use `declare -g`, `declare -ag`, case-conversion expansions, `mapfile`, `readarray`, associative arrays, or other Bash 4+ features. Use `tr '[:upper:]' '[:lower:]'` for lowercasing.
- Under `set -u`, guard empty or unset array expansion with `"${arr[@]+"${arr[@]}"}"`.
- Use only existing dependencies: Bash, `curl`, and `jq`.

## Phase 1 - Collect and Surface Discord Engagement

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=lib/ops/collect-fleet-health.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=examples/sample-fleet-config-with-ops.json -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=tests/phase27.sh -->
<!-- runner:read=lib/ops/collect-fleet-health.sh -->
<!-- runner:read=tests/phase17.sh -->
<!-- runner:read=tests/phase21.sh -->
<!-- runner:read=/Users/mini/e3d/agents/scripts/discord-heartbeat.js -->
<!-- runner:verify=set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done -->

### Requirements

1. Extend `lib/ops/collect-fleet-health.sh` with separate validation, collection, and rendering functions for `social_accounts`. Follow the existing `live_instances` organization while keeping the two signal implementations independent. Dispatch Discord through a platform-specific function so a later Moltbook ticket can add a sibling branch without changing Discord collection.

2. Accept an optional top-level `social_accounts` field. When present, it must be an array. Each entry must contain exactly:

   - `platform`: the string `discord`;
   - `name`: a non-empty display string;
   - `channel_id`: a non-empty string;
   - `bot_user_id`: a non-empty string identifying the Discord bot author whose messages should be counted.

   Reject a wrong top-level type, non-object entry, unsupported or missing platform, missing or empty required field, and every extra field. Emit a clear stderr error and exit nonzero.

3. Integrate social validation into `validate_fleet_discover_config` before collection begins. Validate the complete live-instance and social configuration before issuing any HTTP request, so an error in either signal type causes zero requests overall.

4. For each valid Discord account, read `DISCORD_BOT_TOKEN` from the process environment. If it is unset or empty, record the exact failure reason `DISCORD_BOT_TOKEN not set`, issue no request for that account, continue processing other valid accounts, and never reveal any token value.

5. Make exactly one Discord messages request per credentialed account. Request up to 50 messages, restrict redirects and protocols as described in Shared Constraints, send the bot Authorization header, capture the HTTP status separately from the response body, and do not retry.

6. On a successful 2xx response, require a valid JSON array. Select only messages whose `author.id` exactly equals the account’s configured `bot_user_id`, preserving the API’s newest-first order, and consider at most the first 10 matching messages. For each considered message, accept an omitted or null `reactions` field as an empty array; otherwise require `reactions` to be an array whose entries have nonnegative integer `count` values. Sum those counts. If the payload, matching-message structure, reactions array, or reaction counts are invalid, record a collection failure rather than partial or fabricated values.

7. Represent each account as exactly one result with its configured name, `discord` platform, and one of these states:

   - no matching recent bot messages;
   - matching message count plus total reactions, including a legitimate zero total;
   - failure with a clear, credential-safe reason.

   Request failures and non-2xx responses must include a useful reason or HTTP status. HTTP 429 must remain an ordinary non-retried failure.

8. Update `build_fleet_discover_facts_markdown` to append `### Social Engagement` within `## Live Operations`, immediately after `### Live Instance Status`. Render one line per configured account in configuration order. Omit the entire subsection when `social_accounts` is absent or empty; do not render an empty-state placeholder.

9. Update `build_fleet_discover_prompt` so `### Operational Recommendations` requests exactly one recommendation for each social account that reports either:

   - one or more considered messages with zero total reactions; or
   - a collection failure.

   Each requested recommendation must name the account and repeat its exact reported state without guessing a cause. Do not request a recommendation for nonzero engagement or for the “no recent messages found” state. Continue to omit the entire recommendations section when neither live-instance nor social results require a recommendation.

10. Preserve all existing live-instance validation, collection, rendering, recommendation behavior, and output formatting. With `social_accounts` absent or `[]`, fleet-discovery output must remain byte-for-byte identical to the pre-change behavior.

11. Add `tests/phase27.sh` following the test-owned temporary-directory and fake-executable-on-`PATH` conventions from `tests/phase17.sh` and `tests/phase21.sh`. The test must trap cleanup and keep fake curl state, bodies, status files, and traces inside its temporary directory. It must block accidental real network access and require no real credential.

12. In `tests/phase27.sh`, cover:

   - reactions summed across messages matching the configured `bot_user_id` while messages from other users and bots are excluded;
   - only the 10 newest matching bot messages being counted;
   - zero reactions, including a message with no `reactions` field;
   - no matching recent bot messages as distinct from zero engagement;
   - missing and empty `DISCORD_BOT_TOKEN`, with zero requests;
   - an ordinary HTTP failure;
   - HTTP 429, with exactly one request and no fabricated zero;
   - malformed successful JSON as a failure;
   - invalid reaction structures or counts as failures;
   - configuration rejection for wrong `social_accounts` type, unsupported platform, missing required field, empty required field, extra field, and non-object entry;
   - validation failure occurring before any live-instance or social HTTP request;
   - account output order;
   - recommendation inclusion for zero engagement and failures;
   - recommendation exclusion for nonzero engagement and no recent messages;
   - absence of `### Social Engagement` when `social_accounts` is absent or empty;
   - token values never appearing in stdout, stderr, generated facts, or test-visible request diagnostics.

13. Add one fictional Discord entry to `examples/sample-fleet-config-with-ops.json`. Use obviously fake channel and bot user IDs and do not include any token or secret field.

14. Update the fleet-discover documentation in `README.md` to describe:

   - the optional `social_accounts` schema, including `bot_user_id`, and the currently supported `discord` platform;
   - that `bot_user_id` is a public identifier used for exact authorship matching rather than a credential;
   - the `DISCORD_BOT_TOKEN` environment requirement;
   - read-only, one-request-per-account behavior;
   - the meaning of successful, no-message, zero-engagement, and failure output;
   - `### Social Engagement` placement and its omission when configuration is absent or empty;
   - why this omission differs from the existing live-instance empty-state output;
   - zero-engagement and failure recommendation behavior;
   - Moltbook as a planned follow-on rather than current support;
   - credentials never belonging in fleet configuration.

15. Run the configured full repository verification command after implementation. Do not modify an unrelated pre-existing test to make failures pass.

### Acceptance Criteria

- The phase changes exactly the five annotated files and remains below 900 cumulative changed lines.
- Fleet discovery with no `social_accounts`, or with an empty array, produces byte-identical output to the baseline and contains no `### Social Engagement` heading.
- Valid stubbed Discord messages produce the correct configured-bot-only message count and summed reaction count, limited to 10 matching messages.
- A missing or null `reactions` field contributes zero without causing an error.
- Invalid reaction structures or counts produce a failure rather than a partial result.
- No messages matching the configured `bot_user_id` are reported distinctly from matching messages with zero total reactions.
- Missing or empty `DISCORD_BOT_TOKEN` produces `DISCORD_BOT_TOKEN not set` and issues zero requests for that account.
- Stubbed HTTP 429 produces one failure result, causes no retry, and is never represented as zero engagement.
- Invalid configuration fails clearly before any HTTP request.
- Output contains no configured token value in success or failure cases.
- Each zero-engagement or failed account produces exactly one requested operational recommendation naming the account and repeating its reported state.
- Accounts with nonzero engagement or no matching recent messages produce no social recommendation.
- Social results and recommendations preserve configuration order.
- The sample configuration contains a fictional Discord account with fake channel and bot user IDs and no credential.
- README documents the schema, credential handling, exact bot-user matching, output asymmetry, recommendation rules, and deferred Moltbook support.
- `try_stage_provider`, `discover_stage`, `ideate_stage`, provider-panel dispatch behavior in `fleet_discover_stage`, and every pre-existing test file remain unchanged.
- `set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done` passes under Bash 3.2 without network access or a real Discord token.
```

Raw Response:

```text
---STATUS---
status: revise
reason: Discord message payloads do not identify which bot is authenticated, so the draft cannot honestly distinguish “no matching messages” from ambiguous bot authorship without an explicit bot user ID.
```spec
# Fleet Ops: Discord Engagement Signal

## Overview

Extend fleet discovery’s existing `## Live Operations` facts with an optional, independent Discord engagement signal. For each configured Discord account, collect a fresh read-only snapshot of recent channel messages and their reaction counts, then expose honest success, empty, and failure states to the cross-repository ideation prompt.

This is Part 2 of the fleet-operations work. Moltbook support remains a separate follow-on so the cumulative implementation stays within five changed files and the repository’s 900-line ceiling.

## Goals

- Support an optional top-level `social_accounts` array containing Discord account definitions.
- Fetch recent channel messages using one authenticated Discord API request per configured account.
- Count the most recent 10 messages authored by the configured bot user and sum their reaction counts.
- Distinguish no recent bot messages, zero reactions on real messages, and collection failures.
- Append `### Social Engagement` after `### Live Instance Status` within `## Live Operations`.
- Request operational recommendations for zero-engagement accounts and collection failures.
- Preserve existing fleet cadence, approval gates, provider dispatch, and live-instance behavior.
- Keep credentials exclusively in runtime environment variables.

## Non-Goals

- Moltbook, X/Twitter, Telegram, Farcaster, or other social platforms.
- Posting, replying, reacting, voting, or any other write operation.
- Historical metrics, trends, persistence, or analytics storage.
- Reading or modifying bot-local state such as `discord-state.json`.
- Modifying any file under `/Users/mini/e3d/**`.
- Changing single-repository discovery or ideation.
- Changing candidate scoring, negotiation, execution, review, publication, or ledger schemas.
- Changing `try_stage_provider` or any provider-panel dispatch loop.
- Changing `tests/phase25.sh` or any other pre-existing test.
- Rotating, relocating, or otherwise changing existing Discord credentials.

## Existing Files

- `lib/ops/collect-fleet-health.sh` contains the live-instance validation, collection, and rendering structure. Read it completely and preserve its existing behavior.
- `bin/e3d-pilot` contains `validate_fleet_discover_config`, `build_fleet_discover_facts_markdown`, `build_fleet_discover_prompt`, and `fleet_discover_stage`.
- `examples/sample-fleet-config-with-ops.json` demonstrates the existing live-operations configuration.
- `README.md` documents fleet discovery, `live_instances`, and `## Live Operations`.
- `tests/phase17.sh` and `tests/phase21.sh` demonstrate the test-owned fake-executable-on-`PATH` convention.
- `/Users/mini/e3d/agents/scripts/discord-heartbeat.js` may be read to confirm the real Discord API response shape but must not be modified.

## Shared Constraints

- Change only the five files named by the phase’s `pilot:touches` annotations.
- Keep the cumulative change below 900 changed lines and at no more than five changed files. If necessary, reduce redundant test setup or scenarios without dropping the required behavioral coverage.
- Do not modify `LICENSE`, `docs/build-e3d-pilot.md`, `.github/workflows/**`, `.e3d-pilot/**`, `.git/**`, any pre-existing test, or any file under `/Users/mini/e3d/**`.
- Preserve `try_stage_provider`, `discover_stage`, `ideate_stage`, and the provider-panel dispatch behavior inside `fleet_discover_stage`.
- Preserve byte-identical fleet-discovery output when `social_accounts` is absent or empty.
- Route every outbound request through `curl`, allowing tests to block network access by shadowing it on `PATH`.
- Every request must use `--max-time 10`, `--max-redirs 1`, an HTTP/HTTPS-only restriction supported by the repository’s established curl invocation, and `--` immediately before the URL.
- Perform exactly one request per configured Discord account and never retry, including after HTTP 429.
- Use `GET https://discord.com/api/v10/channels/{channel_id}/messages?limit=50` with `Authorization: Bot <token>`.
- Read the token only from `DISCORD_BOT_TOKEN`. Never accept a token in configuration, log it, place it in facts output, or expose it through an error message.
- `bot_user_id` is a public Discord user identifier used only for authorship matching; it is not a credential.
- Do not enable `set -x`, invoke the collector through `bash -x`, or introduce a debug path that prints the Authorization header.
- A missing or empty token is an account-level collection failure, not a fatal collector error and not a reason to skip the account result.
- Configuration errors are fatal and must be detected before any HTTP request for either live instances or social accounts.
- Treat every non-2xx response, including 429, as a collection failure reporting the HTTP status without fabricating counts.
- Treat a missing or null message `reactions` field as zero reactions.
- Count only messages whose `author.id` exactly matches the configured `bot_user_id`. Do not infer the authenticated bot from `author.bot`, the set of authors in the response, or the token, and do not add an identity request.
- From the matching bot-authored messages returned in newest-first API order, consider at most the first 10.
- Distinguish “no recent messages found” from a nonzero message count with zero total reactions.
- Render accounts in configuration order.
- All new or edited shell code must work under Bash 3.2. Do not use `declare -g`, `declare -ag`, case-conversion expansions, `mapfile`, `readarray`, associative arrays, or other Bash 4+ features. Use `tr '[:upper:]' '[:lower:]'` for lowercasing.
- Under `set -u`, guard empty or unset array expansion with `"${arr[@]+"${arr[@]}"}"`.
- Use only existing dependencies: Bash, `curl`, and `jq`.

## Phase 1 - Collect and Surface Discord Engagement

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=lib/ops/collect-fleet-health.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=examples/sample-fleet-config-with-ops.json -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=tests/phase27.sh -->
<!-- runner:read=lib/ops/collect-fleet-health.sh -->
<!-- runner:read=tests/phase17.sh -->
<!-- runner:read=tests/phase21.sh -->
<!-- runner:read=/Users/mini/e3d/agents/scripts/discord-heartbeat.js -->
<!-- runner:verify=set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done -->

### Requirements

1. Extend `lib/ops/collect-fleet-health.sh` with separate validation, collection, and rendering functions for `social_accounts`. Follow the existing `live_instances` organization while keeping the two signal implementations independent. Dispatch Discord through a platform-specific function so a later Moltbook ticket can add a sibling branch without changing Discord collection.

2. Accept an optional top-level `social_accounts` field. When present, it must be an array. Each entry must contain exactly:

   - `platform`: the string `discord`;
   - `name`: a non-empty display string;
   - `channel_id`: a non-empty string;
   - `bot_user_id`: a non-empty string identifying the Discord bot author whose messages should be counted.

   Reject a wrong top-level type, non-object entry, unsupported or missing platform, missing or empty required field, and every extra field. Emit a clear stderr error and exit nonzero.

3. Integrate social validation into `validate_fleet_discover_config` before collection begins. Validate the complete live-instance and social configuration before issuing any HTTP request, so an error in either signal type causes zero requests overall.

4. For each valid Discord account, read `DISCORD_BOT_TOKEN` from the process environment. If it is unset or empty, record the exact failure reason `DISCORD_BOT_TOKEN not set`, issue no request for that account, continue processing other valid accounts, and never reveal any token value.

5. Make exactly one Discord messages request per credentialed account. Request up to 50 messages, restrict redirects and protocols as described in Shared Constraints, send the bot Authorization header, capture the HTTP status separately from the response body, and do not retry.

6. On a successful 2xx response, require a valid JSON array. Select only messages whose `author.id` exactly equals the account’s configured `bot_user_id`, preserving the API’s newest-first order, and consider at most the first 10 matching messages. For each considered message, accept an omitted or null `reactions` field as an empty array; otherwise require `reactions` to be an array whose entries have nonnegative integer `count` values. Sum those counts. If the payload, matching-message structure, reactions array, or reaction counts are invalid, record a collection failure rather than partial or fabricated values.

7. Represent each account as exactly one result with its configured name, `discord` platform, and one of these states:

   - no matching recent bot messages;
   - matching message count plus total reactions, including a legitimate zero total;
   - failure with a clear, credential-safe reason.

   Request failures and non-2xx responses must include a useful reason or HTTP status. HTTP 429 must remain an ordinary non-retried failure.

8. Update `build_fleet_discover_facts_markdown` to append `### Social Engagement` within `## Live Operations`, immediately after `### Live Instance Status`. Render one line per configured account in configuration order. Omit the entire subsection when `social_accounts` is absent or empty; do not render an empty-state placeholder.

9. Update `build_fleet_discover_prompt` so `### Operational Recommendations` requests exactly one recommendation for each social account that reports either:

   - one or more considered messages with zero total reactions; or
   - a collection failure.

   Each requested recommendation must name the account and repeat its exact reported state without guessing a cause. Do not request a recommendation for nonzero engagement or for the “no recent messages found” state. Continue to omit the entire recommendations section when neither live-instance nor social results require a recommendation.

10. Preserve all existing live-instance validation, collection, rendering, recommendation behavior, and output formatting. With `social_accounts` absent or `[]`, fleet-discovery output must remain byte-for-byte identical to the pre-change behavior.

11. Add `tests/phase27.sh` following the test-owned temporary-directory and fake-executable-on-`PATH` conventions from `tests/phase17.sh` and `tests/phase21.sh`. The test must trap cleanup and keep fake curl state, bodies, status files, and traces inside its temporary directory. It must block accidental real network access and require no real credential.

12. In `tests/phase27.sh`, cover:

   - reactions summed across messages matching the configured `bot_user_id` while messages from other users and bots are excluded;
   - only the 10 newest matching bot messages being counted;
   - zero reactions, including a message with no `reactions` field;
   - no matching recent bot messages as distinct from zero engagement;
   - missing and empty `DISCORD_BOT_TOKEN`, with zero requests;
   - an ordinary HTTP failure;
   - HTTP 429, with exactly one request and no fabricated zero;
   - malformed successful JSON as a failure;
   - invalid reaction structures or counts as failures;
   - configuration rejection for wrong `social_accounts` type, unsupported platform, missing required field, empty required field, extra field, and non-object entry;
   - validation failure occurring before any live-instance or social HTTP request;
   - account output order;
   - recommendation inclusion for zero engagement and failures;
   - recommendation exclusion for nonzero engagement and no recent messages;
   - absence of `### Social Engagement` when `social_accounts` is absent or empty;
   - token values never appearing in stdout, stderr, generated facts, or test-visible request diagnostics.

13. Add one fictional Discord entry to `examples/sample-fleet-config-with-ops.json`. Use obviously fake channel and bot user IDs and do not include any token or secret field.

14. Update the fleet-discover documentation in `README.md` to describe:

   - the optional `social_accounts` schema, including `bot_user_id`, and the currently supported `discord` platform;
   - that `bot_user_id` is a public identifier used for exact authorship matching rather than a credential;
   - the `DISCORD_BOT_TOKEN` environment requirement;
   - read-only, one-request-per-account behavior;
   - the meaning of successful, no-message, zero-engagement, and failure output;
   - `### Social Engagement` placement and its omission when configuration is absent or empty;
   - why this omission differs from the existing live-instance empty-state output;
   - zero-engagement and failure recommendation behavior;
   - Moltbook as a planned follow-on rather than current support;
   - credentials never belonging in fleet configuration.

15. Run the configured full repository verification command after implementation. Do not modify an unrelated pre-existing test to make failures pass.

### Acceptance Criteria

- The phase changes exactly the five annotated files and remains below 900 cumulative changed lines.
- Fleet discovery with no `social_accounts`, or with an empty array, produces byte-identical output to the baseline and contains no `### Social Engagement` heading.
- Valid stubbed Discord messages produce the correct configured-bot-only message count and summed reaction count, limited to 10 matching messages.
- A missing or null `reactions` field contributes zero without causing an error.
- Invalid reaction structures or counts produce a failure rather than a partial result.
- No messages matching the configured `bot_user_id` are reported distinctly from matching messages with zero total reactions.
- Missing or empty `DISCORD_BOT_TOKEN` produces `DISCORD_BOT_TOKEN not set` and issues zero requests for that account.
- Stubbed HTTP 429 produces one failure result, causes no retry, and is never represented as zero engagement.
- Invalid configuration fails clearly before any HTTP request.
- Output contains no configured token value in success or failure cases.
- Each zero-engagement or failed account produces exactly one requested operational recommendation naming the account and repeating its reported state.
- Accounts with nonzero engagement or no matching recent messages produce no social recommendation.
- Social results and recommendations preserve configuration order.
- The sample configuration contains a fictional Discord account with fake channel and bot user IDs and no credential.
- README documents the schema, credential handling, exact bot-user matching, output asymmetry, recommendation rules, and deferred Moltbook support.
- `try_stage_provider`, `discover_stage`, `ideate_stage`, provider-panel dispatch behavior in `fleet_discover_stage`, and every pre-existing test file remain unchanged.
- `set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done` passes under Bash 3.2 without network access or a real Discord token.
```
```

### Reviewer 3: devin

Status: revise

Reason: `lib/ops/collect-fleet-health.sh` and `examples/sample-fleet-config-with-ops.json` do not exist; the spec incorrectly treats them as pre-existing files to extend. Part 1 (live_instances) was never successfully implemented. All cross-references to existing live-instance structure, byte-identical preservation relative to a live-instances baseline, and the runner:read for a non-existent file are therefore wrong. The 900-line ceiling is insufficient once both signals must be built from scratch with combined test coverage. Full replacement follows.

Replacement Spec:

```spec
# Fleet Ops: Live Instances and Discord Engagement Signal

## Overview

Create `lib/ops/collect-fleet-health.sh` and integrate it into fleet discovery
to surface two independent, read-only operational signals: (1) live-instance
HTTP health checks and (2) Discord channel engagement. Both signals appear
under a new `## Live Operations` facts section. The live-instance infrastructure
was designed but never successfully implemented; this phase delivers both signals
together in a single set of five file changes.

Moltbook support remains a separate follow-on so the combined implementation
stays within the repository's constraints.

## Goals

- Create `lib/ops/collect-fleet-health.sh` implementing validation, collection,
  and rendering for `live_instances` and `social_accounts` (Discord).
- Support an optional top-level `live_instances` array; collect one HTTP health
  check per configured instance; classify each as healthy, degraded, or down.
- Support an optional top-level `social_accounts` array containing Discord
  account definitions.
- Fetch recent channel messages using one authenticated Discord API request per
  configured account.
- Count the most recent 10 messages authored by the configured bot user and sum
  their reaction counts.
- Distinguish no recent bot messages, zero reactions on real messages, and
  collection failures.
- Append `## Live Operations` containing `### Live Instance Status` and
  (conditionally) `### Social Engagement` to the fleet-discover facts when at
  least one signal has configured entries.
- Request operational recommendations for degraded, down, zero-engagement, and
  failed accounts.
- Preserve existing fleet cadence, approval gates, provider dispatch, and all
  other behaviors.
- Keep credentials exclusively in runtime environment variables.
- Create `examples/sample-fleet-config-with-ops.json` demonstrating both
  signals with fictional data.

## Non-Goals

- Moltbook, X/Twitter, Telegram, Farcaster, or other social platforms.
- Posting, replying, reacting, voting, or any other write operation.
- Historical metrics, trends, persistence, or analytics storage.
- Reading or modifying bot-local state such as `discord-state.json`.
- Modifying any file under `/Users/mini/e3d/**`.
- Changing single-repository discovery or ideation.
- Changing candidate scoring, negotiation, execution, review, publication, or
  ledger schemas.
- Changing `try_stage_provider` or any provider-panel dispatch loop.
- Changing `tests/phase25.sh` or any other pre-existing test.
- Rotating, relocating, or otherwise changing existing Discord credentials.

## Existing Files

- `bin/e3d-pilot` contains `validate_fleet_discover_config`,
  `build_fleet_discover_facts_markdown`, `build_fleet_discover_prompt`, and
  `fleet_discover_stage`. Read it completely and understand the integration
  points before modifying.
- `examples/sample-fleet-config.json` demonstrates the existing fleet
  configuration schema (providers, research_topics, analogy_domains, training,
  candidate_scoring).
- `README.md` documents fleet discovery.
- `tests/phase17.sh` and `tests/phase21.sh` demonstrate the test-owned
  fake-executable-on-`PATH` convention.
- `/Users/mini/e3d/agents/scripts/discord-heartbeat.js` may be read to confirm
  the real Discord API response shape but must not be modified.

## Files to Create

- `lib/ops/collect-fleet-health.sh` — new executable script implementing
  validation, collection, and rendering for both live instances and Discord.
  Takes one argument: path to the fleet config JSON. Outputs a `## Live
  Operations` markdown block on stdout. Exits nonzero on configuration errors.
- `examples/sample-fleet-config-with-ops.json` — new JSON file with providers,
  at least one fictional `live_instances` entry, and one fictional Discord
  `social_accounts` entry. No real URLs, tokens, or secrets.
- `tests/phase27.sh` — new test file covering all behaviors in Requirements
  11–12.

## Shared Constraints

- Change only the five files named by the phase's `pilot:touches` annotations.
- Keep the cumulative change below 1400 changed lines and at no more than five
  changed files. If necessary, reduce redundant test setup or scenarios without
  dropping required behavioral coverage.
- Do not modify `LICENSE`, `docs/build-e3d-pilot.md`, `.github/workflows/**`,
  `.e3d-pilot/**`, `.git/**`, any pre-existing test, or any file under
  `/Users/mini/e3d/**`.
- Preserve `try_stage_provider`, `discover_stage`, `ideate_stage`, and the
  provider-panel dispatch behavior inside `fleet_discover_stage`.
- Preserve byte-identical fleet-discovery output when both `live_instances` and
  `social_accounts` are absent or empty from the fleet config (i.e. the current
  behavior: no `## Live Operations` section at all).
- Route every outbound request through `curl`, allowing tests to block network
  access by shadowing it on `PATH`.
- Every request (live-instance or Discord) must use `--max-time 10`,
  `--max-redirs 1`, an HTTP/HTTPS-only restriction
  (`--proto '=http,https' --proto-redir '=http,https'`), and `--` immediately
  before the URL.
- Perform exactly one request per configured live instance or Discord account
  and never retry, including after HTTP 429.
- Do not enable `set -x`, invoke the collector through `bash -x`, or introduce
  a debug path that prints credentials or the Authorization header.
- Configuration errors are fatal and must be detected before any HTTP request
  for either signal type.
- All new or edited shell code must work under Bash 3.2. Do not use
  `declare -g`, `declare -ag`, case-conversion expansions, `mapfile`,
  `readarray`, associative arrays, or other Bash 4+ features. Use
  `tr '[:upper:]' '[:lower:]'` for lowercasing.
- Under `set -u`, guard empty or unset array expansion with
  `"${arr[@]+"${arr[@]}"}"`.
- Use only existing dependencies: Bash, `curl`, and `jq`.

### Discord-specific constraints

- Use `GET https://discord.com/api/v10/channels/{channel_id}/messages?limit=50`
  with `Authorization: Bot <token>`.
- Read the token only from `DISCORD_BOT_TOKEN`. Never accept a token in
  configuration, log it, place it in facts output, or expose it through an
  error message.
- `bot_user_id` is a public Discord user identifier used only for authorship
  matching; it is not a credential.
- A missing or empty token is an account-level collection failure, not a fatal
  error and not a reason to skip the account result.
- Treat every non-2xx response, including 429, as a collection failure reporting
  the HTTP status without fabricating counts.
- Treat a missing or null message `reactions` field as zero reactions.
- Count only messages whose `author.id` exactly matches the configured
  `bot_user_id`. Do not infer the authenticated bot from `author.bot`, the set
  of authors in the response, or the token, and do not add an identity request.
- From the matching bot-authored messages returned in newest-first API order,
  consider at most the first 10.
- Distinguish "no recent messages found" from a nonzero message count with zero
  total reactions.
- Render accounts in configuration order.

## Phase 1 — Collect and Surface Live Instances and Discord Engagement

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=lib/ops/collect-fleet-health.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=examples/sample-fleet-config-with-ops.json -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=tests/phase27.sh -->
<!-- runner:read=bin/e3d-pilot -->
<!-- runner:read=tests/phase17.sh -->
<!-- runner:read=tests/phase21.sh -->
<!-- runner:read=/Users/mini/e3d/agents/scripts/discord-heartbeat.js -->
<!-- runner:verify=set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done -->

### Requirements

1. **Create `lib/ops/collect-fleet-health.sh`** as an executable Bash script.
   It takes one argument: path to the fleet config JSON. It outputs a
   `## Live Operations` markdown block to stdout and exits nonzero on
   configuration errors. Organize it with separate named functions for:
   (a) live-instance config validation, (b) live-instance collection per
   instance, (c) live-instance rendering, (d) social-account config validation,
   (e) Discord collection per account, (f) Discord rendering, and
   (g) platform-dispatch so a future Moltbook ticket can add a sibling branch
   without touching Discord collection. The script is integrated into
   `bin/e3d-pilot` but keeps both signal implementations independent of each
   other.

2. **Accept `live_instances`** as an optional top-level field. When present it
   must be an array. Each entry must contain exactly `name` (non-empty string)
   and `url` (non-empty string; must be http or https scheme, non-empty
   authority, no userinfo component). Reject a wrong top-level type, a
   non-object entry, a missing or empty required field, an invalid URL, and
   every extra field. Emit a clear stderr error and exit nonzero.

3. **For each valid live instance** make exactly one HTTP GET to its configured
   URL. Use `curl` with the shared constraints, plus `-sS -L -o /dev/null
   -w "%{http_code}\t%{time_total}"` (or equivalent) to capture HTTP status
   and elapsed seconds separately from any response body. Convert elapsed
   seconds to integer milliseconds by truncation. Classify the result:

   - **healthy**: curl exits 0, HTTP status is exactly 200, and latency is
     at or below 1500 ms.
   - **degraded**: curl exits 0, and (a) HTTP status is a non-200 2xx or any
     3xx, or (b) HTTP status is 200 but latency exceeds 1500 ms.
   - **down**: curl exits non-zero (exit 28 → label `HTTP timeout`; exit 7 →
     `HTTP connection-refused`; exit 6 → `HTTP dns-error`; any other non-zero
     → `HTTP unknown-error`), or HTTP status is 4xx, 5xx, or otherwise not a
     valid non-negative integer, or the curl time value is not a valid
     non-negative number when curl exits 0 (label `HTTP invalid-curl-output`
     with latency `unavailable`).
   - If the curl time value is not a valid non-negative number but curl exits
     non-zero, still use the appropriate error label and report latency as
     `unavailable`.

   Sanitize `name` and `url` for single-line markdown output (strip or replace
   embedded newlines and carriage returns). Render within `## Live Operations`
   as:

   ```
   ### Live Instance Status
   - **{name}** ({url}): {state} — {status-or-error-label}, {latency}ms
   ```

   For a down instance whose cause is a curl error label, replace the numeric
   HTTP status with that label (e.g., `HTTP timeout`). When `live_instances` is
   absent or `[]`, render:

   ```
   ### Live Instance Status
   No live instances configured.
   ```

4. **Accept `social_accounts`** as an optional top-level field. When present it
   must be an array. Each entry must contain exactly: `platform` (the string
   `"discord"`), `name` (non-empty string), `channel_id` (non-empty string),
   `bot_user_id` (non-empty string). Reject a wrong top-level type, a
   non-object entry, an unsupported or missing `platform`, a missing or empty
   required field, and every extra field. Emit a clear stderr error and exit
   nonzero.

5. **Integrate both validations** into `validate_fleet_discover_config` in
   `bin/e3d-pilot` before any collection begins. Invoke the collector's
   validation path (or inline the same validation logic) so that a
   configuration error in either signal type causes zero HTTP requests for
   both signals. Validation must run before any live-instance or Discord
   request.

6. **For each valid Discord account** read `DISCORD_BOT_TOKEN` from the
   process environment. If it is unset or empty, record the exact failure
   reason `DISCORD_BOT_TOKEN not set`, issue no request for that account,
   continue processing other valid accounts, and never reveal any token value.

7. **Make exactly one Discord messages request** per credentialed account.
   Request up to 50 messages, apply all shared curl constraints, send the bot
   Authorization header, capture the HTTP status separately from the response
   body, and do not retry.

8. **On a successful 2xx response**, require a valid JSON array. Select only
   messages whose `author.id` exactly equals the account's configured
   `bot_user_id`, preserving the API's newest-first order, and consider at most
   the first 10 matching messages. For each considered message, accept an
   omitted or null `reactions` field as an empty array; otherwise require
   `reactions` to be an array whose entries have nonnegative integer `count`
   values. Sum those counts. If the payload, matching-message structure,
   reactions array, or any reaction count is invalid, record a collection
   failure rather than a partial or fabricated result.

9. **Represent each Discord account** as exactly one result with its configured
   name and one of these states:

   - no matching recent bot messages;
   - matching message count plus total reactions (including a legitimate zero
     total);
   - failure with a clear, credential-safe reason.

   Request and non-2xx response failures must include a useful reason or HTTP
   status. HTTP 429 is an ordinary non-retried failure.

10. **Update `build_fleet_discover_facts_markdown`** in `bin/e3d-pilot` to
    invoke `lib/ops/collect-fleet-health.sh` when the fleet config has at
    least one non-empty `live_instances` or `social_accounts` field, and append
    the resulting `## Live Operations` block to the facts file. When both fields
    are absent or empty, skip the collector call entirely so the output remains
    byte-identical to the current baseline.

    Within the collector's `## Live Operations` output:

    - `### Live Instance Status` always appears when `live_instances` is
      present (with "No live instances configured." when empty), or when
      `live_instances` is absent but `social_accounts` has entries (also
      renders "No live instances configured." in that case for structural
      consistency).
    - `### Social Engagement` appears immediately after `### Live Instance
      Status` only when `social_accounts` is non-empty. Omit the subsection
      entirely when `social_accounts` is absent or empty; do not render an
      empty-state placeholder.

11. **Update `build_fleet_discover_prompt`** so `### Operational
    Recommendations` requests exactly one recommendation for each:

    - live instance in **degraded** or **down** state;
    - Discord account with one or more considered messages and zero total
      reactions;
    - Discord account with a collection failure.

    Each requested recommendation must name the instance or account and repeat
    its exact reported state without guessing a cause. Do not request a
    recommendation for healthy live instances, nonzero Discord engagement, or
    the "no recent messages found" state. Continue to omit the entire
    recommendations section when no result requires a recommendation.

12. **Add `tests/phase27.sh`** following the test-owned temporary-directory and
    fake-executable-on-`PATH` conventions from `tests/phase17.sh` and
    `tests/phase21.sh`. The test must trap cleanup, keep all fake curl state,
    bodies, status files, and traces inside its temporary directory, block
    accidental real network access, and require no real credential.

13. **In `tests/phase27.sh`, cover live-instance scenarios:**

    - a healthy instance (HTTP 200, latency ≤ 1500 ms);
    - a degraded instance (HTTP 200, latency > 1500 ms);
    - a degraded instance (non-200 2xx status);
    - a degraded instance (HTTP 3xx redirect);
    - a down instance (HTTP 4xx or 5xx);
    - a down instance (curl exit 28 — timeout);
    - a down instance (curl exit 7 — connection refused);
    - a down instance (curl exit 6 — DNS error);
    - a down instance (other non-zero curl exit);
    - a curl time value that is not a valid number (down, `invalid-curl-output`,
      `unavailable` latency);
    - a non-zero curl exit with non-numeric time (correct error label,
      `unavailable` latency);
    - exactly one curl request per instance with no retries;
    - curl flags include `--max-time 10`, `--max-redirs 1`, protocol
      restriction, and `--` before the URL;
    - configuration rejection for wrong `live_instances` type, non-object
      entry, missing field, empty field, invalid URL scheme, URL with userinfo,
      and extra field;
    - validation failure occurs before any HTTP request (trace is empty after
      a bad config);
    - `No live instances configured.` when `live_instances` is absent or `[]`;
    - recommendation inclusion for degraded and down instances;
    - recommendation exclusion for healthy instances;
    - `## Live Operations` is absent when both `live_instances` and
      `social_accounts` are absent or empty.

14. **In `tests/phase27.sh`, cover Discord scenarios:**

    - reactions summed across messages matching the configured `bot_user_id`
      while messages from other users and bots are excluded;
    - only the 10 newest matching bot messages being counted when more than 10
      are present;
    - zero reactions, including a message with no `reactions` field;
    - no matching recent bot messages reported distinctly from zero engagement;
    - missing `DISCORD_BOT_TOKEN` produces `DISCORD_BOT_TOKEN not set` and
      issues zero requests;
    - empty `DISCORD_BOT_TOKEN` produces `DISCORD_BOT_TOKEN not set` and
      issues zero requests;
    - an ordinary non-2xx HTTP failure includes the HTTP status in the reason;
    - HTTP 429 produces exactly one request, no retry, and is not represented
      as zero engagement;
    - malformed successful JSON body is a collection failure;
    - invalid reaction structure (non-array `reactions`) is a failure;
    - invalid reaction count (non-integer or negative) is a failure;
    - configuration rejection for wrong `social_accounts` type, non-object
      entry, missing `platform`, unsupported `platform`, missing required
      field, empty required field, and extra field;
    - social validation failure occurs before any live-instance or Discord
      HTTP request;
    - account results render in configuration order;
    - recommendation inclusion for zero engagement (nonzero message count,
      zero total reactions) and for collection failures;
    - recommendation exclusion for nonzero total reactions;
    - recommendation exclusion for no matching recent messages;
    - absence of `### Social Engagement` when `social_accounts` is absent;
    - absence of `### Social Engagement` when `social_accounts` is `[]`;
    - token values do not appear in stdout, stderr, generated facts, or
      test-visible request diagnostics.

15. **Add one fictional live_instances entry and one fictional Discord entry**
    to `examples/sample-fleet-config-with-ops.json`. Use obviously fake URLs,
    channel IDs, and bot user IDs. Do not include any token or secret field.

16. **Update the fleet-discover documentation in `README.md`** to describe:

    - the optional `live_instances` schema (name and url fields), URL
      validation rules, and the one-request-per-instance health check;
    - healthy, degraded, and down classification logic including the 1500 ms
      latency threshold;
    - the optional `social_accounts` schema including `bot_user_id` and the
      currently supported `discord` platform;
    - that `bot_user_id` is a public identifier used for exact authorship
      matching rather than a credential;
    - the `DISCORD_BOT_TOKEN` environment requirement;
    - read-only, one-request-per-entry behavior for both signals;
    - the meaning of healthy, degraded, down, no-message, zero-engagement, and
      failure output;
    - `## Live Operations`, `### Live Instance Status`, and `### Social
      Engagement` placement;
    - when `social_accounts` is absent or empty, `### Social Engagement` is
      omitted entirely (no placeholder), while `### Live Instance Status`
      always renders within `## Live Operations` when the section is active;
    - when both signals are absent or empty, `## Live Operations` is omitted
      entirely and fleet-discover output is unchanged;
    - degraded/down and zero-engagement/failure recommendation behavior;
    - Moltbook as a planned follow-on rather than current support;
    - credentials never belonging in fleet configuration.

17. **Run the configured full repository verification command** after
    implementation. Do not modify any pre-existing test to make failures pass.

### Acceptance Criteria

- The phase changes exactly the five annotated files and remains below 1400
  cumulative changed lines.
- Fleet discovery with both `live_instances` and `social_accounts` absent or
  empty produces byte-identical output to the current baseline (no
  `## Live Operations` section).
- When `live_instances` is non-empty, each instance is classified healthy,
  degraded, or down according to HTTP status, latency relative to 1500 ms, and
  curl exit code.
- Exactly one curl request per live instance; no retries.
- Invalid `live_instances` configuration fails clearly before any HTTP request.
- `No live instances configured.` appears when `live_instances` is absent or
  `[]` and `## Live Operations` is otherwise being rendered.
- Valid stubbed Discord messages produce the correct configured-bot-only message
  count and summed reaction count, limited to 10 matching messages.
- A missing or null `reactions` field contributes zero without causing an error.
- Invalid reaction structures or counts produce a failure rather than a partial
  result.
- No messages matching the configured `bot_user_id` are reported distinctly
  from matching messages with zero total reactions.
- Missing or empty `DISCORD_BOT_TOKEN` produces `DISCORD_BOT_TOKEN not set`
  and issues zero requests for that account.
- Stubbed HTTP 429 produces one failure result, causes no retry, and is never
  represented as zero engagement.
- Invalid Discord configuration fails clearly before any HTTP request.
- Output contains no configured token value in success or failure cases.
- Each degraded or down live instance produces exactly one requested
  operational recommendation naming the instance and repeating its state.
- Healthy live instances produce no recommendation.
- Each zero-engagement or failed Discord account produces exactly one requested
  operational recommendation naming the account and repeating its state.
- Discord accounts with nonzero engagement or no matching recent messages
  produce no social recommendation.
- Social results and recommendations preserve configuration order.
- The sample configuration contains fictional live_instances and Discord entries
  with fake data and no real secrets.
- README documents both schemas, credential handling, exact bot-user matching,
  output behavior, recommendation rules, and deferred Moltbook support.
- `try_stage_provider`, `discover_stage`, `ideate_stage`, provider-panel
  dispatch behavior in `fleet_discover_stage`, and every pre-existing test
  file remain unchanged.
- `set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done` passes
  under Bash 3.2 without network access or a real Discord token.
```

Raw Response:

```text
---STATUS---
status: revise
reason: `lib/ops/collect-fleet-health.sh` and `examples/sample-fleet-config-with-ops.json` do not exist; the spec incorrectly treats them as pre-existing files to extend. Part 1 (live_instances) was never successfully implemented. All cross-references to existing live-instance structure, byte-identical preservation relative to a live-instances baseline, and the runner:read for a non-existent file are therefore wrong. The 900-line ceiling is insufficient once both signals must be built from scratch with combined test coverage. Full replacement follows.

```spec
# Fleet Ops: Live Instances and Discord Engagement Signal

## Overview

Create `lib/ops/collect-fleet-health.sh` and integrate it into fleet discovery
to surface two independent, read-only operational signals: (1) live-instance
HTTP health checks and (2) Discord channel engagement. Both signals appear
under a new `## Live Operations` facts section. The live-instance infrastructure
was designed but never successfully implemented; this phase delivers both signals
together in a single set of five file changes.

Moltbook support remains a separate follow-on so the combined implementation
stays within the repository's constraints.

## Goals

- Create `lib/ops/collect-fleet-health.sh` implementing validation, collection,
  and rendering for `live_instances` and `social_accounts` (Discord).
- Support an optional top-level `live_instances` array; collect one HTTP health
  check per configured instance; classify each as healthy, degraded, or down.
- Support an optional top-level `social_accounts` array containing Discord
  account definitions.
- Fetch recent channel messages using one authenticated Discord API request per
  configured account.
- Count the most recent 10 messages authored by the configured bot user and sum
  their reaction counts.
- Distinguish no recent bot messages, zero reactions on real messages, and
  collection failures.
- Append `## Live Operations` containing `### Live Instance Status` and
  (conditionally) `### Social Engagement` to the fleet-discover facts when at
  least one signal has configured entries.
- Request operational recommendations for degraded, down, zero-engagement, and
  failed accounts.
- Preserve existing fleet cadence, approval gates, provider dispatch, and all
  other behaviors.
- Keep credentials exclusively in runtime environment variables.
- Create `examples/sample-fleet-config-with-ops.json` demonstrating both
  signals with fictional data.

## Non-Goals

- Moltbook, X/Twitter, Telegram, Farcaster, or other social platforms.
- Posting, replying, reacting, voting, or any other write operation.
- Historical metrics, trends, persistence, or analytics storage.
- Reading or modifying bot-local state such as `discord-state.json`.
- Modifying any file under `/Users/mini/e3d/**`.
- Changing single-repository discovery or ideation.
- Changing candidate scoring, negotiation, execution, review, publication, or
  ledger schemas.
- Changing `try_stage_provider` or any provider-panel dispatch loop.
- Changing `tests/phase25.sh` or any other pre-existing test.
- Rotating, relocating, or otherwise changing existing Discord credentials.

## Existing Files

- `bin/e3d-pilot` contains `validate_fleet_discover_config`,
  `build_fleet_discover_facts_markdown`, `build_fleet_discover_prompt`, and
  `fleet_discover_stage`. Read it completely and understand the integration
  points before modifying.
- `examples/sample-fleet-config.json` demonstrates the existing fleet
  configuration schema (providers, research_topics, analogy_domains, training,
  candidate_scoring).
- `README.md` documents fleet discovery.
- `tests/phase17.sh` and `tests/phase21.sh` demonstrate the test-owned
  fake-executable-on-`PATH` convention.
- `/Users/mini/e3d/agents/scripts/discord-heartbeat.js` may be read to confirm
  the real Discord API response shape but must not be modified.

## Files to Create

- `lib/ops/collect-fleet-health.sh` — new executable script implementing
  validation, collection, and rendering for both live instances and Discord.
  Takes one argument: path to the fleet config JSON. Outputs a `## Live
  Operations` markdown block on stdout. Exits nonzero on configuration errors.
- `examples/sample-fleet-config-with-ops.json` — new JSON file with providers,
  at least one fictional `live_instances` entry, and one fictional Discord
  `social_accounts` entry. No real URLs, tokens, or secrets.
- `tests/phase27.sh` — new test file covering all behaviors in Requirements
  11–12.

## Shared Constraints

- Change only the five files named by the phase's `pilot:touches` annotations.
- Keep the cumulative change below 1400 changed lines and at no more than five
  changed files. If necessary, reduce redundant test setup or scenarios without
  dropping required behavioral coverage.
- Do not modify `LICENSE`, `docs/build-e3d-pilot.md`, `.github/workflows/**`,
  `.e3d-pilot/**`, `.git/**`, any pre-existing test, or any file under
  `/Users/mini/e3d/**`.
- Preserve `try_stage_provider`, `discover_stage`, `ideate_stage`, and the
  provider-panel dispatch behavior inside `fleet_discover_stage`.
- Preserve byte-identical fleet-discovery output when both `live_instances` and
  `social_accounts` are absent or empty from the fleet config (i.e. the current
  behavior: no `## Live Operations` section at all).
- Route every outbound request through `curl`, allowing tests to block network
  access by shadowing it on `PATH`.
- Every request (live-instance or Discord) must use `--max-time 10`,
  `--max-redirs 1`, an HTTP/HTTPS-only restriction
  (`--proto '=http,https' --proto-redir '=http,https'`), and `--` immediately
  before the URL.
- Perform exactly one request per configured live instance or Discord account
  and never retry, including after HTTP 429.
- Do not enable `set -x`, invoke the collector through `bash -x`, or introduce
  a debug path that prints credentials or the Authorization header.
- Configuration errors are fatal and must be detected before any HTTP request
  for either signal type.
- All new or edited shell code must work under Bash 3.2. Do not use
  `declare -g`, `declare -ag`, case-conversion expansions, `mapfile`,
  `readarray`, associative arrays, or other Bash 4+ features. Use
  `tr '[:upper:]' '[:lower:]'` for lowercasing.
- Under `set -u`, guard empty or unset array expansion with
  `"${arr[@]+"${arr[@]}"}"`.
- Use only existing dependencies: Bash, `curl`, and `jq`.

### Discord-specific constraints

- Use `GET https://discord.com/api/v10/channels/{channel_id}/messages?limit=50`
  with `Authorization: Bot <token>`.
- Read the token only from `DISCORD_BOT_TOKEN`. Never accept a token in
  configuration, log it, place it in facts output, or expose it through an
  error message.
- `bot_user_id` is a public Discord user identifier used only for authorship
  matching; it is not a credential.
- A missing or empty token is an account-level collection failure, not a fatal
  error and not a reason to skip the account result.
- Treat every non-2xx response, including 429, as a collection failure reporting
  the HTTP status without fabricating counts.
- Treat a missing or null message `reactions` field as zero reactions.
- Count only messages whose `author.id` exactly matches the configured
  `bot_user_id`. Do not infer the authenticated bot from `author.bot`, the set
  of authors in the response, or the token, and do not add an identity request.
- From the matching bot-authored messages returned in newest-first API order,
  consider at most the first 10.
- Distinguish "no recent messages found" from a nonzero message count with zero
  total reactions.
- Render accounts in configuration order.

## Phase 1 — Collect and Surface Live Instances and Discord Engagement

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=lib/ops/collect-fleet-health.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=examples/sample-fleet-config-with-ops.json -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=tests/phase27.sh -->
<!-- runner:read=bin/e3d-pilot -->
<!-- runner:read=tests/phase17.sh -->
<!-- runner:read=tests/phase21.sh -->
<!-- runner:read=/Users/mini/e3d/agents/scripts/discord-heartbeat.js -->
<!-- runner:verify=set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done -->

### Requirements

1. **Create `lib/ops/collect-fleet-health.sh`** as an executable Bash script.
   It takes one argument: path to the fleet config JSON. It outputs a
   `## Live Operations` markdown block to stdout and exits nonzero on
   configuration errors. Organize it with separate named functions for:
   (a) live-instance config validation, (b) live-instance collection per
   instance, (c) live-instance rendering, (d) social-account config validation,
   (e) Discord collection per account, (f) Discord rendering, and
   (g) platform-dispatch so a future Moltbook ticket can add a sibling branch
   without touching Discord collection. The script is integrated into
   `bin/e3d-pilot` but keeps both signal implementations independent of each
   other.

2. **Accept `live_instances`** as an optional top-level field. When present it
   must be an array. Each entry must contain exactly `name` (non-empty string)
   and `url` (non-empty string; must be http or https scheme, non-empty
   authority, no userinfo component). Reject a wrong top-level type, a
   non-object entry, a missing or empty required field, an invalid URL, and
   every extra field. Emit a clear stderr error and exit nonzero.

3. **For each valid live instance** make exactly one HTTP GET to its configured
   URL. Use `curl` with the shared constraints, plus `-sS -L -o /dev/null
   -w "%{http_code}\t%{time_total}"` (or equivalent) to capture HTTP status
   and elapsed seconds separately from any response body. Convert elapsed
   seconds to integer milliseconds by truncation. Classify the result:

   - **healthy**: curl exits 0, HTTP status is exactly 200, and latency is
     at or below 1500 ms.
   - **degraded**: curl exits 0, and (a) HTTP status is a non-200 2xx or any
     3xx, or (b) HTTP status is 200 but latency exceeds 1500 ms.
   - **down**: curl exits non-zero (exit 28 → label `HTTP timeout`; exit 7 →
     `HTTP connection-refused`; exit 6 → `HTTP dns-error`; any other non-zero
     → `HTTP unknown-error`), or HTTP status is 4xx, 5xx, or otherwise not a
     valid non-negative integer, or the curl time value is not a valid
     non-negative number when curl exits 0 (label `HTTP invalid-curl-output`
     with latency `unavailable`).
   - If the curl time value is not a valid non-negative number but curl exits
     non-zero, still use the appropriate error label and report latency as
     `unavailable`.

   Sanitize `name` and `url` for single-line markdown output (strip or replace
   embedded newlines and carriage returns). Render within `## Live Operations`
   as:

   ```
   ### Live Instance Status
   - **{name}** ({url}): {state} — {status-or-error-label}, {latency}ms
   ```

   For a down instance whose cause is a curl error label, replace the numeric
   HTTP status with that label (e.g., `HTTP timeout`). When `live_instances` is
   absent or `[]`, render:

   ```
   ### Live Instance Status
   No live instances configured.
   ```

4. **Accept `social_accounts`** as an optional top-level field. When present it
   must be an array. Each entry must contain exactly: `platform` (the string
   `"discord"`), `name` (non-empty string), `channel_id` (non-empty string),
   `bot_user_id` (non-empty string). Reject a wrong top-level type, a
   non-object entry, an unsupported or missing `platform`, a missing or empty
   required field, and every extra field. Emit a clear stderr error and exit
   nonzero.

5. **Integrate both validations** into `validate_fleet_discover_config` in
   `bin/e3d-pilot` before any collection begins. Invoke the collector's
   validation path (or inline the same validation logic) so that a
   configuration error in either signal type causes zero HTTP requests for
   both signals. Validation must run before any live-instance or Discord
   request.

6. **For each valid Discord account** read `DISCORD_BOT_TOKEN` from the
   process environment. If it is unset or empty, record the exact failure
   reason `DISCORD_BOT_TOKEN not set`, issue no request for that account,
   continue processing other valid accounts, and never reveal any token value.

7. **Make exactly one Discord messages request** per credentialed account.
   Request up to 50 messages, apply all shared curl constraints, send the bot
   Authorization header, capture the HTTP status separately from the response
   body, and do not retry.

8. **On a successful 2xx response**, require a valid JSON array. Select only
   messages whose `author.id` exactly equals the account's configured
   `bot_user_id`, preserving the API's newest-first order, and consider at most
   the first 10 matching messages. For each considered message, accept an
   omitted or null `reactions` field as an empty array; otherwise require
   `reactions` to be an array whose entries have nonnegative integer `count`
   values. Sum those counts. If the payload, matching-message structure,
   reactions array, or any reaction count is invalid, record a collection
   failure rather than a partial or fabricated result.

9. **Represent each Discord account** as exactly one result with its configured
   name and one of these states:

   - no matching recent bot messages;
   - matching message count plus total reactions (including a legitimate zero
     total);
   - failure with a clear, credential-safe reason.

   Request and non-2xx response failures must include a useful reason or HTTP
   status. HTTP 429 is an ordinary non-retried failure.

10. **Update `build_fleet_discover_facts_markdown`** in `bin/e3d-pilot` to
    invoke `lib/ops/collect-fleet-health.sh` when the fleet config has at
    least one non-empty `live_instances` or `social_accounts` field, and append
    the resulting `## Live Operations` block to the facts file. When both fields
    are absent or empty, skip the collector call entirely so the output remains
    byte-identical to the current baseline.

    Within the collector's `## Live Operations` output:

    - `### Live Instance Status` always appears when `live_instances` is
      present (with "No live instances configured." when empty), or when
      `live_instances` is absent but `social_accounts` has entries (also
      renders "No live instances configured." in that case for structural
      consistency).
    - `### Social Engagement` appears immediately after `### Live Instance
      Status` only when `social_accounts` is non-empty. Omit the subsection
      entirely when `social_accounts` is absent or empty; do not render an
      empty-state placeholder.

11. **Update `build_fleet_discover_prompt`** so `### Operational
    Recommendations` requests exactly one recommendation for each:

    - live instance in **degraded** or **down** state;
    - Discord account with one or more considered messages and zero total
      reactions;
    - Discord account with a collection failure.

    Each requested recommendation must name the instance or account and repeat
    its exact reported state without guessing a cause. Do not request a
    recommendation for healthy live instances, nonzero Discord engagement, or
    the "no recent messages found" state. Continue to omit the entire
    recommendations section when no result requires a recommendation.

12. **Add `tests/phase27.sh`** following the test-owned temporary-directory and
    fake-executable-on-`PATH` conventions from `tests/phase17.sh` and
    `tests/phase21.sh`. The test must trap cleanup, keep all fake curl state,
    bodies, status files, and traces inside its temporary directory, block
    accidental real network access, and require no real credential.

13. **In `tests/phase27.sh`, cover live-instance scenarios:**

    - a healthy instance (HTTP 200, latency ≤ 1500 ms);
    - a degraded instance (HTTP 200, latency > 1500 ms);
    - a degraded instance (non-200 2xx status);
    - a degraded instance (HTTP 3xx redirect);
    - a down instance (HTTP 4xx or 5xx);
    - a down instance (curl exit 28 — timeout);
    - a down instance (curl exit 7 — connection refused);
    - a down instance (curl exit 6 — DNS error);
    - a down instance (other non-zero curl exit);
    - a curl time value that is not a valid number (down, `invalid-curl-output`,
      `unavailable` latency);
    - a non-zero curl exit with non-numeric time (correct error label,
      `unavailable` latency);
    - exactly one curl request per instance with no retries;
    - curl flags include `--max-time 10`, `--max-redirs 1`, protocol
      restriction, and `--` before the URL;
    - configuration rejection for wrong `live_instances` type, non-object
      entry, missing field, empty field, invalid URL scheme, URL with userinfo,
      and extra field;
    - validation failure occurs before any HTTP request (trace is empty after
      a bad config);
    - `No live instances configured.` when `live_instances` is absent or `[]`;
    - recommendation inclusion for degraded and down instances;
    - recommendation exclusion for healthy instances;
    - `## Live Operations` is absent when both `live_instances` and
      `social_accounts` are absent or empty.

14. **In `tests/phase27.sh`, cover Discord scenarios:**

    - reactions summed across messages matching the configured `bot_user_id`
      while messages from other users and bots are excluded;
    - only the 10 newest matching bot messages being counted when more than 10
      are present;
    - zero reactions, including a message with no `reactions` field;
    - no matching recent bot messages reported distinctly from zero engagement;
    - missing `DISCORD_BOT_TOKEN` produces `DISCORD_BOT_TOKEN not set` and
      issues zero requests;
    - empty `DISCORD_BOT_TOKEN` produces `DISCORD_BOT_TOKEN not set` and
      issues zero requests;
    - an ordinary non-2xx HTTP failure includes the HTTP status in the reason;
    - HTTP 429 produces exactly one request, no retry, and is not represented
      as zero engagement;
    - malformed successful JSON body is a collection failure;
    - invalid reaction structure (non-array `reactions`) is a failure;
    - invalid reaction count (non-integer or negative) is a failure;
    - configuration rejection for wrong `social_accounts` type, non-object
      entry, missing `platform`, unsupported `platform`, missing required
      field, empty required field, and extra field;
    - social validation failure occurs before any live-instance or Discord
      HTTP request;
    - account results render in configuration order;
    - recommendation inclusion for zero engagement (nonzero message count,
      zero total reactions) and for collection failures;
    - recommendation exclusion for nonzero total reactions;
    - recommendation exclusion for no matching recent messages;
    - absence of `### Social Engagement` when `social_accounts` is absent;
    - absence of `### Social Engagement` when `social_accounts` is `[]`;
    - token values do not appear in stdout, stderr, generated facts, or
      test-visible request diagnostics.

15. **Add one fictional live_instances entry and one fictional Discord entry**
    to `examples/sample-fleet-config-with-ops.json`. Use obviously fake URLs,
    channel IDs, and bot user IDs. Do not include any token or secret field.

16. **Update the fleet-discover documentation in `README.md`** to describe:

    - the optional `live_instances` schema (name and url fields), URL
      validation rules, and the one-request-per-instance health check;
    - healthy, degraded, and down classification logic including the 1500 ms
      latency threshold;
    - the optional `social_accounts` schema including `bot_user_id` and the
      currently supported `discord` platform;
    - that `bot_user_id` is a public identifier used for exact authorship
      matching rather than a credential;
    - the `DISCORD_BOT_TOKEN` environment requirement;
    - read-only, one-request-per-entry behavior for both signals;
    - the meaning of healthy, degraded, down, no-message, zero-engagement, and
      failure output;
    - `## Live Operations`, `### Live Instance Status`, and `### Social
      Engagement` placement;
    - when `social_accounts` is absent or empty, `### Social Engagement` is
      omitted entirely (no placeholder), while `### Live Instance Status`
      always renders within `## Live Operations` when the section is active;
    - when both signals are absent or empty, `## Live Operations` is omitted
      entirely and fleet-discover output is unchanged;
    - degraded/down and zero-engagement/failure recommendation behavior;
    - Moltbook as a planned follow-on rather than current support;
    - credentials never belonging in fleet configuration.

17. **Run the configured full repository verification command** after
    implementation. Do not modify any pre-existing test to make failures pass.

### Acceptance Criteria

- The phase changes exactly the five annotated files and remains below 1400
  cumulative changed lines.
- Fleet discovery with both `live_instances` and `social_accounts` absent or
  empty produces byte-identical output to the current baseline (no
  `## Live Operations` section).
- When `live_instances` is non-empty, each instance is classified healthy,
  degraded, or down according to HTTP status, latency relative to 1500 ms, and
  curl exit code.
- Exactly one curl request per live instance; no retries.
- Invalid `live_instances` configuration fails clearly before any HTTP request.
- `No live instances configured.` appears when `live_instances` is absent or
  `[]` and `## Live Operations` is otherwise being rendered.
- Valid stubbed Discord messages produce the correct configured-bot-only message
  count and summed reaction count, limited to 10 matching messages.
- A missing or null `reactions` field contributes zero without causing an error.
- Invalid reaction structures or counts produce a failure rather than a partial
  result.
- No messages matching the configured `bot_user_id` are reported distinctly
  from matching messages with zero total reactions.
- Missing or empty `DISCORD_BOT_TOKEN` produces `DISCORD_BOT_TOKEN not set`
  and issues zero requests for that account.
- Stubbed HTTP 429 produces one failure result, causes no retry, and is never
  represented as zero engagement.
- Invalid Discord configuration fails clearly before any HTTP request.
- Output contains no configured token value in success or failure cases.
- Each degraded or down live instance produces exactly one requested
  operational recommendation naming the instance and repeating its state.
- Healthy live instances produce no recommendation.
- Each zero-engagement or failed Discord account produces exactly one requested
  operational recommendation naming the account and repeating its state.
- Discord accounts with nonzero engagement or no matching recent messages
  produce no social recommendation.
- Social results and recommendations preserve configuration order.
- The sample configuration contains fictional live_instances and Discord entries
  with fake data and no real secrets.
- README documents both schemas, credential handling, exact bot-user matching,
  output behavior, recommendation rules, and deferred Moltbook support.
- `try_stage_provider`, `discover_stage`, `ideate_stage`, provider-panel
  dispatch behavior in `fleet_discover_stage`, and every pre-existing test
  file remain unchanged.
- `set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done` passes
  under Bash 3.2 without network access or a real Discord token.
```
```

Round Result: not converged

At least one reviewer requested revision in round 1.

## Round 2

### Draft Before Round

```text
# Fleet Ops: Live Instances and Discord Engagement Signal

## Overview

Create `lib/ops/collect-fleet-health.sh` and integrate it into fleet discovery
to surface two independent, read-only operational signals: (1) live-instance
HTTP health checks and (2) Discord channel engagement. Both signals appear
under a new `## Live Operations` facts section. The live-instance infrastructure
was designed but never successfully implemented; this phase delivers both signals
together in a single set of five file changes.

Moltbook support remains a separate follow-on so the combined implementation
stays within the repository's constraints.

## Goals

- Create `lib/ops/collect-fleet-health.sh` implementing validation, collection,
  and rendering for `live_instances` and `social_accounts` (Discord).
- Support an optional top-level `live_instances` array; collect one HTTP health
  check per configured instance; classify each as healthy, degraded, or down.
- Support an optional top-level `social_accounts` array containing Discord
  account definitions.
- Fetch recent channel messages using one authenticated Discord API request per
  configured account.
- Count the most recent 10 messages authored by the configured bot user and sum
  their reaction counts.
- Distinguish no recent bot messages, zero reactions on real messages, and
  collection failures.
- Append `## Live Operations` containing `### Live Instance Status` and
  (conditionally) `### Social Engagement` to the fleet-discover facts when at
  least one signal has configured entries.
- Request operational recommendations for degraded, down, zero-engagement, and
  failed accounts.
- Preserve existing fleet cadence, approval gates, provider dispatch, and all
  other behaviors.
- Keep credentials exclusively in runtime environment variables.
- Create `examples/sample-fleet-config-with-ops.json` demonstrating both
  signals with fictional data.

## Non-Goals

- Moltbook, X/Twitter, Telegram, Farcaster, or other social platforms.
- Posting, replying, reacting, voting, or any other write operation.
- Historical metrics, trends, persistence, or analytics storage.
- Reading or modifying bot-local state such as `discord-state.json`.
- Modifying any file under `/Users/mini/e3d/**`.
- Changing single-repository discovery or ideation.
- Changing candidate scoring, negotiation, execution, review, publication, or
  ledger schemas.
- Changing `try_stage_provider` or any provider-panel dispatch loop.
- Changing `tests/phase25.sh` or any other pre-existing test.
- Rotating, relocating, or otherwise changing existing Discord credentials.

## Existing Files

- `bin/e3d-pilot` contains `validate_fleet_discover_config`,
  `build_fleet_discover_facts_markdown`, `build_fleet_discover_prompt`, and
  `fleet_discover_stage`. Read it completely and understand the integration
  points before modifying.
- `examples/sample-fleet-config.json` demonstrates the existing fleet
  configuration schema (providers, research_topics, analogy_domains, training,
  candidate_scoring).
- `README.md` documents fleet discovery.
- `tests/phase17.sh` and `tests/phase21.sh` demonstrate the test-owned
  fake-executable-on-`PATH` convention.
- `/Users/mini/e3d/agents/scripts/discord-heartbeat.js` may be read to confirm
  the real Discord API response shape but must not be modified.

## Files to Create

- `lib/ops/collect-fleet-health.sh` — new executable script implementing
  validation, collection, and rendering for both live instances and Discord.
  Takes one argument: path to the fleet config JSON. Outputs a `## Live
  Operations` markdown block on stdout. Exits nonzero on configuration errors.
- `examples/sample-fleet-config-with-ops.json` — new JSON file with providers,
  at least one fictional `live_instances` entry, and one fictional Discord
  `social_accounts` entry. No real URLs, tokens, or secrets.
- `tests/phase27.sh` — new test file covering all behaviors in Requirements
  11–12.

## Shared Constraints

- Change only the five files named by the phase's `pilot:touches` annotations.
- Keep the cumulative change below 1400 changed lines and at no more than five
  changed files. If necessary, reduce redundant test setup or scenarios without
  dropping required behavioral coverage.
- Do not modify `LICENSE`, `docs/build-e3d-pilot.md`, `.github/workflows/**`,
  `.e3d-pilot/**`, `.git/**`, any pre-existing test, or any file under
  `/Users/mini/e3d/**`.
- Preserve `try_stage_provider`, `discover_stage`, `ideate_stage`, and the
  provider-panel dispatch behavior inside `fleet_discover_stage`.
- Preserve byte-identical fleet-discovery output when both `live_instances` and
  `social_accounts` are absent or empty from the fleet config (i.e. the current
  behavior: no `## Live Operations` section at all).
- Route every outbound request through `curl`, allowing tests to block network
  access by shadowing it on `PATH`.
- Every request (live-instance or Discord) must use `--max-time 10`,
  `--max-redirs 1`, an HTTP/HTTPS-only restriction
  (`--proto '=http,https' --proto-redir '=http,https'`), and `--` immediately
  before the URL.
- Perform exactly one request per configured live instance or Discord account
  and never retry, including after HTTP 429.
- Do not enable `set -x`, invoke the collector through `bash -x`, or introduce
  a debug path that prints credentials or the Authorization header.
- Configuration errors are fatal and must be detected before any HTTP request
  for either signal type.
- All new or edited shell code must work under Bash 3.2. Do not use
  `declare -g`, `declare -ag`, case-conversion expansions, `mapfile`,
  `readarray`, associative arrays, or other Bash 4+ features. Use
  `tr '[:upper:]' '[:lower:]'` for lowercasing.
- Under `set -u`, guard empty or unset array expansion with
  `"${arr[@]+"${arr[@]}"}"`.
- Use only existing dependencies: Bash, `curl`, and `jq`.

### Discord-specific constraints

- Use `GET https://discord.com/api/v10/channels/{channel_id}/messages?limit=50`
  with `Authorization: Bot <token>`.
- Read the token only from `DISCORD_BOT_TOKEN`. Never accept a token in
  configuration, log it, place it in facts output, or expose it through an
  error message.
- `bot_user_id` is a public Discord user identifier used only for authorship
  matching; it is not a credential.
- A missing or empty token is an account-level collection failure, not a fatal
  error and not a reason to skip the account result.
- Treat every non-2xx response, including 429, as a collection failure reporting
  the HTTP status without fabricating counts.
- Treat a missing or null message `reactions` field as zero reactions.
- Count only messages whose `author.id` exactly matches the configured
  `bot_user_id`. Do not infer the authenticated bot from `author.bot`, the set
  of authors in the response, or the token, and do not add an identity request.
- From the matching bot-authored messages returned in newest-first API order,
  consider at most the first 10.
- Distinguish "no recent messages found" from a nonzero message count with zero
  total reactions.
- Render accounts in configuration order.

## Phase 1 — Collect and Surface Live Instances and Discord Engagement

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=lib/ops/collect-fleet-health.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=examples/sample-fleet-config-with-ops.json -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=tests/phase27.sh -->
<!-- runner:read=bin/e3d-pilot -->
<!-- runner:read=tests/phase17.sh -->
<!-- runner:read=tests/phase21.sh -->
<!-- runner:read=/Users/mini/e3d/agents/scripts/discord-heartbeat.js -->
<!-- runner:verify=set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done -->

### Requirements

1. **Create `lib/ops/collect-fleet-health.sh`** as an executable Bash script.
   It takes one argument: path to the fleet config JSON. It outputs a
   `## Live Operations` markdown block to stdout and exits nonzero on
   configuration errors. Organize it with separate named functions for:
   (a) live-instance config validation, (b) live-instance collection per
   instance, (c) live-instance rendering, (d) social-account config validation,
   (e) Discord collection per account, (f) Discord rendering, and
   (g) platform-dispatch so a future Moltbook ticket can add a sibling branch
   without touching Discord collection. The script is integrated into
   `bin/e3d-pilot` but keeps both signal implementations independent of each
   other.

2. **Accept `live_instances`** as an optional top-level field. When present it
   must be an array. Each entry must contain exactly `name` (non-empty string)
   and `url` (non-empty string; must be http or https scheme, non-empty
   authority, no userinfo component). Reject a wrong top-level type, a
   non-object entry, a missing or empty required field, an invalid URL, and
   every extra field. Emit a clear stderr error and exit nonzero.

3. **For each valid live instance** make exactly one HTTP GET to its configured
   URL. Use `curl` with the shared constraints, plus `-sS -L -o /dev/null
   -w "%{http_code}\t%{time_total}"` (or equivalent) to capture HTTP status
   and elapsed seconds separately from any response body. Convert elapsed
   seconds to integer milliseconds by truncation. Classify the result:

   - **healthy**: curl exits 0, HTTP status is exactly 200, and latency is
     at or below 1500 ms.
   - **degraded**: curl exits 0, and (a) HTTP status is a non-200 2xx or any
     3xx, or (b) HTTP status is 200 but latency exceeds 1500 ms.
   - **down**: curl exits non-zero (exit 28 → label `HTTP timeout`; exit 7 →
     `HTTP connection-refused`; exit 6 → `HTTP dns-error`; any other non-zero
     → `HTTP unknown-error`), or HTTP status is 4xx, 5xx, or otherwise not a
     valid non-negative integer, or the curl time value is not a valid
     non-negative number when curl exits 0 (label `HTTP invalid-curl-output`
     with latency `unavailable`).
   - If the curl time value is not a valid non-negative number but curl exits
     non-zero, still use the appropriate error label and report latency as
     `unavailable`.

   Sanitize `name` and `url` for single-line markdown output (strip or replace
   embedded newlines and carriage returns). Render within `## Live Operations`
   as:

   ```
   ### Live Instance Status
   - **{name}** ({url}): {state} — {status-or-error-label}, {latency}ms
   ```

   For a down instance whose cause is a curl error label, replace the numeric
   HTTP status with that label (e.g., `HTTP timeout`). When `live_instances` is
   absent or `[]`, render:

   ```
   ### Live Instance Status
   No live instances configured.
   ```

4. **Accept `social_accounts`** as an optional top-level field. When present it
   must be an array. Each entry must contain exactly: `platform` (the string
   `"discord"`), `name` (non-empty string), `channel_id` (non-empty string),
   `bot_user_id` (non-empty string). Reject a wrong top-level type, a
   non-object entry, an unsupported or missing `platform`, a missing or empty
   required field, and every extra field. Emit a clear stderr error and exit
   nonzero.

5. **Integrate both validations** into `validate_fleet_discover_config` in
   `bin/e3d-pilot` before any collection begins. Invoke the collector's
   validation path (or inline the same validation logic) so that a
   configuration error in either signal type causes zero HTTP requests for
   both signals. Validation must run before any live-instance or Discord
   request.

6. **For each valid Discord account** read `DISCORD_BOT_TOKEN` from the
   process environment. If it is unset or empty, record the exact failure
   reason `DISCORD_BOT_TOKEN not set`, issue no request for that account,
   continue processing other valid accounts, and never reveal any token value.

7. **Make exactly one Discord messages request** per credentialed account.
   Request up to 50 messages, apply all shared curl constraints, send the bot
   Authorization header, capture the HTTP status separately from the response
   body, and do not retry.

8. **On a successful 2xx response**, require a valid JSON array. Select only
   messages whose `author.id` exactly equals the account's configured
   `bot_user_id`, preserving the API's newest-first order, and consider at most
   the first 10 matching messages. For each considered message, accept an
   omitted or null `reactions` field as an empty array; otherwise require
   `reactions` to be an array whose entries have nonnegative integer `count`
   values. Sum those counts. If the payload, matching-message structure,
   reactions array, or any reaction count is invalid, record a collection
   failure rather than a partial or fabricated result.

9. **Represent each Discord account** as exactly one result with its configured
   name and one of these states:

   - no matching recent bot messages;
   - matching message count plus total reactions (including a legitimate zero
     total);
   - failure with a clear, credential-safe reason.

   Request and non-2xx response failures must include a useful reason or HTTP
   status. HTTP 429 is an ordinary non-retried failure.

10. **Update `build_fleet_discover_facts_markdown`** in `bin/e3d-pilot` to
    invoke `lib/ops/collect-fleet-health.sh` when the fleet config has at
    least one non-empty `live_instances` or `social_accounts` field, and append
    the resulting `## Live Operations` block to the facts file. When both fields
    are absent or empty, skip the collector call entirely so the output remains
    byte-identical to the current baseline.

    Within the collector's `## Live Operations` output:

    - `### Live Instance Status` always appears when `live_instances` is
      present (with "No live instances configured." when empty), or when
      `live_instances` is absent but `social_accounts` has entries (also
      renders "No live instances configured." in that case for structural
      consistency).
    - `### Social Engagement` appears immediately after `### Live Instance
      Status` only when `social_accounts` is non-empty. Omit the subsection
      entirely when `social_accounts` is absent or empty; do not render an
      empty-state placeholder.

11. **Update `build_fleet_discover_prompt`** so `### Operational
    Recommendations` requests exactly one recommendation for each:

    - live instance in **degraded** or **down** state;
    - Discord account with one or more considered messages and zero total
      reactions;
    - Discord account with a collection failure.

    Each requested recommendation must name the instance or account and repeat
    its exact reported state without guessing a cause. Do not request a
    recommendation for healthy live instances, nonzero Discord engagement, or
    the "no recent messages found" state. Continue to omit the entire
    recommendations section when no result requires a recommendation.

12. **Add `tests/phase27.sh`** following the test-owned temporary-directory and
    fake-executable-on-`PATH` conventions from `tests/phase17.sh` and
    `tests/phase21.sh`. The test must trap cleanup, keep all fake curl state,
    bodies, status files, and traces inside its temporary directory, block
    accidental real network access, and require no real credential.

13. **In `tests/phase27.sh`, cover live-instance scenarios:**

    - a healthy instance (HTTP 200, latency ≤ 1500 ms);
    - a degraded instance (HTTP 200, latency > 1500 ms);
    - a degraded instance (non-200 2xx status);
    - a degraded instance (HTTP 3xx redirect);
    - a down instance (HTTP 4xx or 5xx);
    - a down instance (curl exit 28 — timeout);
    - a down instance (curl exit 7 — connection refused);
    - a down instance (curl exit 6 — DNS error);
    - a down instance (other non-zero curl exit);
    - a curl time value that is not a valid number (down, `invalid-curl-output`,
      `unavailable` latency);
    - a non-zero curl exit with non-numeric time (correct error label,
      `unavailable` latency);
    - exactly one curl request per instance with no retries;
    - curl flags include `--max-time 10`, `--max-redirs 1`, protocol
      restriction, and `--` before the URL;
    - configuration rejection for wrong `live_instances` type, non-object
      entry, missing field, empty field, invalid URL scheme, URL with userinfo,
      and extra field;
    - validation failure occurs before any HTTP request (trace is empty after
      a bad config);
    - `No live instances configured.` when `live_instances` is absent or `[]`;
    - recommendation inclusion for degraded and down instances;
    - recommendation exclusion for healthy instances;
    - `## Live Operations` is absent when both `live_instances` and
      `social_accounts` are absent or empty.

14. **In `tests/phase27.sh`, cover Discord scenarios:**

    - reactions summed across messages matching the configured `bot_user_id`
      while messages from other users and bots are excluded;
    - only the 10 newest matching bot messages being counted when more than 10
      are present;
    - zero reactions, including a message with no `reactions` field;
    - no matching recent bot messages reported distinctly from zero engagement;
    - missing `DISCORD_BOT_TOKEN` produces `DISCORD_BOT_TOKEN not set` and
      issues zero requests;
    - empty `DISCORD_BOT_TOKEN` produces `DISCORD_BOT_TOKEN not set` and
      issues zero requests;
    - an ordinary non-2xx HTTP failure includes the HTTP status in the reason;
    - HTTP 429 produces exactly one request, no retry, and is not represented
      as zero engagement;
    - malformed successful JSON body is a collection failure;
    - invalid reaction structure (non-array `reactions`) is a failure;
    - invalid reaction count (non-integer or negative) is a failure;
    - configuration rejection for wrong `social_accounts` type, non-object
      entry, missing `platform`, unsupported `platform`, missing required
      field, empty required field, and extra field;
    - social validation failure occurs before any live-instance or Discord
      HTTP request;
    - account results render in configuration order;
    - recommendation inclusion for zero engagement (nonzero message count,
      zero total reactions) and for collection failures;
    - recommendation exclusion for nonzero total reactions;
    - recommendation exclusion for no matching recent messages;
    - absence of `### Social Engagement` when `social_accounts` is absent;
    - absence of `### Social Engagement` when `social_accounts` is `[]`;
    - token values do not appear in stdout, stderr, generated facts, or
      test-visible request diagnostics.

15. **Add one fictional live_instances entry and one fictional Discord entry**
    to `examples/sample-fleet-config-with-ops.json`. Use obviously fake URLs,
    channel IDs, and bot user IDs. Do not include any token or secret field.

16. **Update the fleet-discover documentation in `README.md`** to describe:

    - the optional `live_instances` schema (name and url fields), URL
      validation rules, and the one-request-per-instance health check;
    - healthy, degraded, and down classification logic including the 1500 ms
      latency threshold;
    - the optional `social_accounts` schema including `bot_user_id` and the
      currently supported `discord` platform;
    - that `bot_user_id` is a public identifier used for exact authorship
      matching rather than a credential;
    - the `DISCORD_BOT_TOKEN` environment requirement;
    - read-only, one-request-per-entry behavior for both signals;
    - the meaning of healthy, degraded, down, no-message, zero-engagement, and
      failure output;
    - `## Live Operations`, `### Live Instance Status`, and `### Social
      Engagement` placement;
    - when `social_accounts` is absent or empty, `### Social Engagement` is
      omitted entirely (no placeholder), while `### Live Instance Status`
      always renders within `## Live Operations` when the section is active;
    - when both signals are absent or empty, `## Live Operations` is omitted
      entirely and fleet-discover output is unchanged;
    - degraded/down and zero-engagement/failure recommendation behavior;
    - Moltbook as a planned follow-on rather than current support;
    - credentials never belonging in fleet configuration.

17. **Run the configured full repository verification command** after
    implementation. Do not modify any pre-existing test to make failures pass.

### Acceptance Criteria

- The phase changes exactly the five annotated files and remains below 1400
  cumulative changed lines.
- Fleet discovery with both `live_instances` and `social_accounts` absent or
  empty produces byte-identical output to the current baseline (no
  `## Live Operations` section).
- When `live_instances` is non-empty, each instance is classified healthy,
  degraded, or down according to HTTP status, latency relative to 1500 ms, and
  curl exit code.
- Exactly one curl request per live instance; no retries.
- Invalid `live_instances` configuration fails clearly before any HTTP request.
- `No live instances configured.` appears when `live_instances` is absent or
  `[]` and `## Live Operations` is otherwise being rendered.
- Valid stubbed Discord messages produce the correct configured-bot-only message
  count and summed reaction count, limited to 10 matching messages.
- A missing or null `reactions` field contributes zero without causing an error.
- Invalid reaction structures or counts produce a failure rather than a partial
  result.
- No messages matching the configured `bot_user_id` are reported distinctly
  from matching messages with zero total reactions.
- Missing or empty `DISCORD_BOT_TOKEN` produces `DISCORD_BOT_TOKEN not set`
  and issues zero requests for that account.
- Stubbed HTTP 429 produces one failure result, causes no retry, and is never
  represented as zero engagement.
- Invalid Discord configuration fails clearly before any HTTP request.
- Output contains no configured token value in success or failure cases.
- Each degraded or down live instance produces exactly one requested
  operational recommendation naming the instance and repeating its state.
- Healthy live instances produce no recommendation.
- Each zero-engagement or failed Discord account produces exactly one requested
  operational recommendation naming the account and repeating its state.
- Discord accounts with nonzero engagement or no matching recent messages
  produce no social recommendation.
- Social results and recommendations preserve configuration order.
- The sample configuration contains fictional live_instances and Discord entries
  with fake data and no real secrets.
- README documents both schemas, credential handling, exact bot-user matching,
  output behavior, recommendation rules, and deferred Moltbook support.
- `try_stage_provider`, `discover_stage`, `ideate_stage`, provider-panel
  dispatch behavior in `fleet_discover_stage`, and every pre-existing test
  file remain unchanged.
- `set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done` passes
  under Bash 3.2 without network access or a real Discord token.

```

### Reviewer 1: claude

Status: approved

Reason: Spec is internally consistent, covers validation-before-collection ordering, classification/rendering rules, Bash 3.2 and credential-safety constraints, and scopes test coverage against the five-file/1400-line ceiling.

Raw Response:

```text
---STATUS---
status: approved
reason: Spec is internally consistent, covers validation-before-collection ordering, classification/rendering rules, Bash 3.2 and credential-safety constraints, and scopes test coverage against the five-file/1400-line ceiling.
```

### Reviewer 2: codex

Status: revise

Reason: The draft has conflicting request-count rules, leaves valid HTTP statuses such as 000/1xx/6xx unclassified, and ambiguously renders unavailable latency as “unavailablems.”

Replacement Spec:

```spec
# Fleet Ops: Live Instances and Discord Engagement Signal

## Overview

Create `lib/ops/collect-fleet-health.sh` and integrate it into fleet discovery to surface two independent, read-only operational signals: live-instance HTTP health and Discord channel engagement. Both signals appear under a new `## Live Operations` facts section.

Moltbook support remains a separate follow-on.

## Goals

- Validate, collect, and render `live_instances` and Discord `social_accounts`.
- Classify every live-instance result as healthy, degraded, or down.
- Fetch recent Discord messages using one authenticated request per credentialed account.
- Count at most the 10 newest messages authored by the configured bot user and sum their reactions.
- Distinguish no matching messages, genuine zero engagement, and collection failure.
- Request recommendations only for degraded/down instances, zero-engagement accounts, and failed accounts.
- Preserve existing fleet cadence, approval gates, provider dispatch, and all unrelated behavior.
- Keep credentials exclusively in runtime environment variables.
- Add a fictional example configuration.

## Non-Goals

- Moltbook, X/Twitter, Telegram, Farcaster, or other social platforms.
- Posting, replying, reacting, voting, or any other write operation.
- Historical metrics, trends, persistence, or analytics storage.
- Reading or modifying bot-local state such as `discord-state.json`.
- Modifying anything under `/Users/mini/e3d/**`.
- Changing single-repository discovery or ideation.
- Changing candidate scoring, negotiation, execution, review, publication, or ledger schemas.
- Changing `try_stage_provider` or any provider-panel dispatch loop.
- Changing any pre-existing test.
- Rotating, relocating, or changing existing Discord credentials.

## Existing Files

- `bin/e3d-pilot` contains `validate_fleet_discover_config`, `build_fleet_discover_facts_markdown`, `build_fleet_discover_prompt`, and `fleet_discover_stage`. Read it completely before modifying it.
- `examples/sample-fleet-config.json` demonstrates the existing fleet schema.
- `README.md` documents fleet discovery.
- `tests/phase17.sh` and `tests/phase21.sh` demonstrate the test-owned fake-executable-on-`PATH` convention.
- `/Users/mini/e3d/agents/scripts/discord-heartbeat.js` may be read to confirm the Discord response shape but must not be modified.

## Files to Change

Exactly these five files may change:

- Create executable `lib/ops/collect-fleet-health.sh`.
- Modify `bin/e3d-pilot`.
- Create `examples/sample-fleet-config-with-ops.json`.
- Modify `README.md`.
- Create `tests/phase27.sh`.

## Shared Constraints

- Keep the cumulative change below 1400 changed lines.
- Do not modify `LICENSE`, `docs/build-e3d-pilot.md`, `.github/workflows/**`, `.e3d-pilot/**`, `.git/**`, any pre-existing test, or anything under `/Users/mini/e3d/**`.
- Preserve `try_stage_provider`, `discover_stage`, `ideate_stage`, and provider-panel dispatch behavior inside `fleet_discover_stage`.
- Preserve byte-identical fleet-discovery output when both `live_instances` and `social_accounts` are absent or empty.
- Route every outbound request through `curl` so tests can block network access by shadowing it on `PATH`.
- Every request must use `--max-time 10`, `--max-redirs 1`, `--proto '=http,https'`, `--proto-redir '=http,https'`, and `--` immediately before the URL.
- Make exactly one request per valid live instance.
- Make exactly one request per valid Discord account when `DISCORD_BOT_TOKEN` is non-empty. Make zero requests for a Discord account when the token is unset or empty.
- Never retry, including after HTTP 429.
- Do not enable `set -x`, invoke the collector through `bash -x`, or add a debug path that prints credentials or an Authorization header.
- Detect all configuration errors before making any live-instance or Discord request.
- All new or edited shell code must work under Bash 3.2. Do not use `declare -g`, `declare -ag`, case-conversion expansions, `mapfile`, `readarray`, associative arrays, or other Bash 4+ features. Use `tr '[:upper:]' '[:lower:]'` for lowercasing.
- Under `set -u`, guard empty or unset array expansion with `"${arr[@]+"${arr[@]}"}"`.
- Use only Bash, `curl`, and `jq`.

## Discord Constraints

- Use `GET https://discord.com/api/v10/channels/{channel_id}/messages?limit=50` with `Authorization: Bot <token>`.
- Read the token only from `DISCORD_BOT_TOKEN`.
- Never accept a token in configuration, log it, render it, or expose it in an error or test diagnostic.
- `bot_user_id` is a public identifier used only for exact authorship matching.
- An unset or empty token is an account-level collection failure with the exact reason `DISCORD_BOT_TOKEN not set`; it is not a fatal configuration error.
- Treat every non-2xx response, including 429, as a collection failure reporting the HTTP status without fabricated counts.
- Treat an omitted or null `reactions` field as an empty array.
- Match only messages whose `author.id` exactly equals the configured `bot_user_id`.
- Do not infer identity from `author.bot`, other authors, or the token, and do not make an identity request.
- Preserve the API’s newest-first order and consider at most the first 10 matching messages.
- Distinguish no matching messages from a nonzero matching-message count with zero reactions.
- Render accounts in configuration order.

## Phase 1 — Collect and Surface Live Instances and Discord Engagement

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=lib/ops/collect-fleet-health.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=examples/sample-fleet-config-with-ops.json -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=tests/phase27.sh -->
<!-- runner:read=bin/e3d-pilot -->
<!-- runner:read=tests/phase17.sh -->
<!-- runner:read=tests/phase21.sh -->
<!-- runner:read=/Users/mini/e3d/agents/scripts/discord-heartbeat.js -->
<!-- runner:verify=set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done -->

### Requirements

1. Create executable `lib/ops/collect-fleet-health.sh`. It takes one fleet-config JSON path and outputs a `## Live Operations` Markdown block. It exits nonzero on configuration errors. Provide separate named functions for:

   - live-instance validation;
   - collection of one live instance;
   - live-instance rendering;
   - social-account validation;
   - collection of one Discord account;
   - Discord rendering;
   - platform dispatch.

   Keep live-instance and Discord collection independent so a future Moltbook implementation can add a sibling dispatch branch.

2. Accept optional top-level `live_instances`. If present, it must be an array. Every entry must be an object containing exactly:

   - `name`: non-empty string;
   - `url`: non-empty string with an HTTP or HTTPS scheme, non-empty authority, and no userinfo component.

   Reject a wrong top-level type, non-object entry, missing or empty required field, invalid URL, or extra field. Emit a clear stderr error and exit nonzero.

3. For each valid live instance, make exactly one HTTP GET to its configured URL. Use the shared curl constraints plus `-sS -L -o /dev/null -w "%{http_code}\t%{time_total}"`, or an equivalent method that captures status and elapsed seconds separately from the body.

   Validate the elapsed value as a nonnegative decimal number and truncate it to integer milliseconds.

   Classify every possible result as follows:

   - `healthy`: curl exits 0, status is exactly 200, and latency is at most 1500 ms.
   - `degraded`: curl exits 0, latency is valid, and either the status is 201–399 or the status is 200 with latency above 1500 ms.
   - `down`: curl exits nonzero; latency is invalid; status is not a three-digit decimal HTTP status; or status is outside 200–399, including 000, 1xx, 4xx, 5xx, and 6xx–9xx.

   Map nonzero curl exits to:

   - 28: `HTTP timeout`;
   - 7: `HTTP connection-refused`;
   - 6: `HTTP dns-error`;
   - any other nonzero exit: `HTTP unknown-error`.

   If curl exits 0 but status or elapsed output is invalid, use `HTTP invalid-curl-output`.

   If elapsed output is invalid, render latency as `unavailable`, regardless of curl exit. Otherwise render the truncated integer followed by `ms`.

   Sanitize `name` and `url` for single-line Markdown by stripping or replacing carriage returns and newlines. Render:

   ```
   ## Live Operations

   ### Live Instance Status
   - **{name}** ({url}): {state} — {numeric-status-or-error-label}, {integer}ms
   ```

   When latency is unavailable, render:

   ```
   - **{name}** ({url}): {state} — {numeric-status-or-error-label}, unavailable
   ```

   For a curl failure, replace the numeric status with the mapped curl error label. For invalid successful curl output, use `HTTP invalid-curl-output`.

   When no live instances are configured but the collector is invoked because social accounts exist, render:

   ```
   ### Live Instance Status
   No live instances configured.
   ```

4. Accept optional top-level `social_accounts`. If present, it must be an array. Every entry must be an object containing exactly:

   - `platform`: the string `discord`;
   - `name`: non-empty string;
   - `channel_id`: non-empty string;
   - `bot_user_id`: non-empty string.

   Reject a wrong top-level type, non-object entry, missing or unsupported platform, missing or empty required field, or extra field. Emit a clear stderr error and exit nonzero.

5. Integrate both validations into `validate_fleet_discover_config` in `bin/e3d-pilot`, either by invoking a validation-only collector path or by using equivalent validation logic. Complete validation of both signal types before any collection. An error in either type must result in zero HTTP requests across both types.

6. For every valid Discord account, read `DISCORD_BOT_TOKEN` from the process environment. If it is unset or empty, record exactly one account result with failure reason `DISCORD_BOT_TOKEN not set`, make no request for that account, and continue rendering all configured accounts. Never reveal a token value.

7. For each credentialed Discord account, make exactly one messages request. Request up to 50 messages, use all shared curl constraints, send the bot Authorization header, capture HTTP status separately from the body, and do not retry.

8. On a 2xx response, require the body to be a valid JSON array. Select messages whose `author.id` exactly equals `bot_user_id`, preserve response order, and take at most the first 10 matches.

   Every considered matching message must be an object with an object-valued `author` and string-valued `author.id`. An omitted or null `reactions` field is equivalent to `[]`. Any present non-null `reactions` value must be an array, and every reaction entry must be an object with a nonnegative integer `count`. Sum all accepted counts.

   Invalid payload shape, invalid matching-message structure, invalid reactions structure, or an invalid count produces a collection failure, never a partial result.

9. Render each Discord account exactly once, using its configured name, in one of these states:

   - `no recent messages found`;
   - `{N} recent messages, {R} total reactions`, where `N` is 1–10 and `R` may be zero;
   - `collection failure — {credential-safe reason}`.

   A curl request failure must include a useful credential-safe reason. A non-2xx response must include its HTTP status. HTTP 429 is a single, non-retried failure and must not be represented as zero engagement.

10. Update `build_fleet_discover_facts_markdown` to invoke the collector only if at least one of `live_instances` or `social_accounts` is a non-empty array. Append its output to the facts file.

   If both fields are absent or empty, skip the collector entirely and preserve byte-identical existing output.

   When the collector is invoked:

   - output one `## Live Operations` section;
   - output `### Live Instance Status` first;
   - if no live instances exist, output `No live instances configured.`;
   - output `### Social Engagement` immediately afterward only when `social_accounts` is non-empty;
   - omit `### Social Engagement` entirely when `social_accounts` is absent or empty.

11. Update `build_fleet_discover_prompt` so `### Operational Recommendations` requests exactly one recommendation for every:

   - degraded live instance;
   - down live instance;
   - Discord account with at least one considered message and zero total reactions;
   - Discord account with a collection failure.

   Every requested recommendation must name the instance or account and repeat its exact reported state without guessing a cause. Preserve configuration order within each signal and render social recommendations in social-account configuration order.

   Do not request recommendations for healthy instances, nonzero Discord engagement, or `no recent messages found`. Omit the entire recommendations section when no result qualifies.

12. Add `tests/phase27.sh` using test-owned temporary directories and fake executables on `PATH`, following `tests/phase17.sh` and `tests/phase21.sh`. The test must trap cleanup; keep fake curl state, bodies, status files, and traces inside its temporary directory; block accidental real network access; and require no real credential.

13. Cover these live-instance cases:

   - HTTP 200 at or below 1500 ms is healthy;
   - HTTP 200 above 1500 ms is degraded;
   - non-200 2xx is degraded;
   - 3xx is degraded;
   - 000, 1xx, 4xx, 5xx, and a representative 6xx status are down;
   - curl exits 28, 7, 6, and another nonzero value with the required labels;
   - invalid elapsed output with curl exit 0 produces `HTTP invalid-curl-output` and unavailable latency;
   - invalid status output with curl exit 0 produces `HTTP invalid-curl-output`;
   - nonzero curl exit with invalid elapsed output retains the mapped curl label and uses unavailable latency;
   - exactly one request occurs per instance, with no retry;
   - required curl flags are present and `--` immediately precedes the URL;
   - invalid `live_instances` type, non-object entry, missing field, empty field, invalid scheme, userinfo, and extra field are rejected;
   - a validation failure occurs before any request;
   - absent or empty live instances produce `No live instances configured.` when social accounts activate the section;
   - degraded and down results receive recommendations;
   - healthy results do not;
   - `## Live Operations` is absent when both arrays are absent or empty.

14. Cover these Discord cases:

   - reactions are summed only across messages exactly matching `bot_user_id`;
   - messages from other users, including other bots, are excluded;
   - only the 10 newest matching messages count when more than 10 match;
   - zero reactions work with empty, omitted, and null `reactions`;
   - no matching messages are distinct from zero engagement;
   - unset and empty `DISCORD_BOT_TOKEN` produce `DISCORD_BOT_TOKEN not set` and zero requests;
   - an ordinary non-2xx response includes the HTTP status;
   - HTTP 429 produces one request, no retry, and a failure rather than zero engagement;
   - malformed successful JSON is a failure;
   - invalid message, author, reactions, reaction-entry, non-integer count, and negative count structures are failures;
   - wrong `social_accounts` type, non-object entry, missing platform, unsupported platform, missing field, empty field, and extra field are rejected;
   - social validation failure occurs before any live-instance or Discord request;
   - account results render in configuration order;
   - zero engagement and collection failures receive recommendations;
   - nonzero engagement and no matching messages do not;
   - `### Social Engagement` is absent when `social_accounts` is absent or empty;
   - token values never appear in stdout, stderr, facts, or test-visible request diagnostics.

15. Add `examples/sample-fleet-config-with-ops.json` containing providers, at least one fictional live instance, and one fictional Discord account. Use obviously fake URLs and identifiers. Include no token or secret field.

16. Update `README.md` to document:

   - optional `live_instances`, its exact fields and URL validation;
   - one-request-per-instance behavior;
   - healthy, degraded, and down classification, including the 1500 ms threshold;
   - optional `social_accounts`, its exact fields, and Discord as the only supported platform;
   - `bot_user_id` as a public exact-authorship identifier rather than a credential;
   - the `DISCORD_BOT_TOKEN` environment requirement;
   - one request per credentialed Discord account and zero requests when the token is missing;
   - read-only behavior and no retries;
   - healthy, degraded, down, no-message, zero-engagement, and failure meanings;
   - placement and conditional presence of `## Live Operations`, `### Live Instance Status`, and `### Social Engagement`;
   - omission of all live-operations output when both signals are absent or empty;
   - recommendation rules;
   - Moltbook as a planned follow-on;
   - credentials never belonging in fleet configuration.

17. Run:

   ```
   set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done
   ```

   Do not modify any pre-existing test to make failures pass.

## Acceptance Criteria

- Exactly the five annotated files change, with fewer than 1400 cumulative changed lines.
- Baseline fleet-discovery output remains byte-identical when both signals are absent or empty.
- Every live-instance outcome is deterministically classified, including 000, 1xx, 4xx, 5xx, out-of-range three-digit statuses, invalid status text, invalid elapsed text, and curl failures.
- Each live instance receives exactly one request and no retry.
- Each credentialed Discord account receives exactly one request and no retry; accounts without a token receive zero requests.
- All configuration is validated before any request.
- Discord aggregation uses exact configured-user matching, newest-first order, a maximum of 10 matches, and validated nonnegative integer reaction counts.
- Missing or null reactions contribute zero.
- No-message, zero-engagement, and failure states remain distinct.
- HTTP 429 is a single failure result with no retry.
- Tokens never appear in output, errors, facts, configuration examples, or test-visible diagnostics.
- Recommendations are emitted exactly for degraded/down instances and zero-engagement/failed Discord accounts, preserving applicable configuration order.
- The example contains only fictional operational data and no secret.
- README documents both schemas, credentials, collection behavior, states, output placement, recommendations, and deferred Moltbook support.
- Preserved functions, provider dispatch behavior, and every pre-existing test remain unchanged.
- The full repository verification passes under Bash 3.2 without network access or a real Discord token.
```

Raw Response:

```text
---STATUS---
status: revise
reason: The draft has conflicting request-count rules, leaves valid HTTP statuses such as 000/1xx/6xx unclassified, and ambiguously renders unavailable latency as “unavailablems.”
```spec
# Fleet Ops: Live Instances and Discord Engagement Signal

## Overview

Create `lib/ops/collect-fleet-health.sh` and integrate it into fleet discovery to surface two independent, read-only operational signals: live-instance HTTP health and Discord channel engagement. Both signals appear under a new `## Live Operations` facts section.

Moltbook support remains a separate follow-on.

## Goals

- Validate, collect, and render `live_instances` and Discord `social_accounts`.
- Classify every live-instance result as healthy, degraded, or down.
- Fetch recent Discord messages using one authenticated request per credentialed account.
- Count at most the 10 newest messages authored by the configured bot user and sum their reactions.
- Distinguish no matching messages, genuine zero engagement, and collection failure.
- Request recommendations only for degraded/down instances, zero-engagement accounts, and failed accounts.
- Preserve existing fleet cadence, approval gates, provider dispatch, and all unrelated behavior.
- Keep credentials exclusively in runtime environment variables.
- Add a fictional example configuration.

## Non-Goals

- Moltbook, X/Twitter, Telegram, Farcaster, or other social platforms.
- Posting, replying, reacting, voting, or any other write operation.
- Historical metrics, trends, persistence, or analytics storage.
- Reading or modifying bot-local state such as `discord-state.json`.
- Modifying anything under `/Users/mini/e3d/**`.
- Changing single-repository discovery or ideation.
- Changing candidate scoring, negotiation, execution, review, publication, or ledger schemas.
- Changing `try_stage_provider` or any provider-panel dispatch loop.
- Changing any pre-existing test.
- Rotating, relocating, or changing existing Discord credentials.

## Existing Files

- `bin/e3d-pilot` contains `validate_fleet_discover_config`, `build_fleet_discover_facts_markdown`, `build_fleet_discover_prompt`, and `fleet_discover_stage`. Read it completely before modifying it.
- `examples/sample-fleet-config.json` demonstrates the existing fleet schema.
- `README.md` documents fleet discovery.
- `tests/phase17.sh` and `tests/phase21.sh` demonstrate the test-owned fake-executable-on-`PATH` convention.
- `/Users/mini/e3d/agents/scripts/discord-heartbeat.js` may be read to confirm the Discord response shape but must not be modified.

## Files to Change

Exactly these five files may change:

- Create executable `lib/ops/collect-fleet-health.sh`.
- Modify `bin/e3d-pilot`.
- Create `examples/sample-fleet-config-with-ops.json`.
- Modify `README.md`.
- Create `tests/phase27.sh`.

## Shared Constraints

- Keep the cumulative change below 1400 changed lines.
- Do not modify `LICENSE`, `docs/build-e3d-pilot.md`, `.github/workflows/**`, `.e3d-pilot/**`, `.git/**`, any pre-existing test, or anything under `/Users/mini/e3d/**`.
- Preserve `try_stage_provider`, `discover_stage`, `ideate_stage`, and provider-panel dispatch behavior inside `fleet_discover_stage`.
- Preserve byte-identical fleet-discovery output when both `live_instances` and `social_accounts` are absent or empty.
- Route every outbound request through `curl` so tests can block network access by shadowing it on `PATH`.
- Every request must use `--max-time 10`, `--max-redirs 1`, `--proto '=http,https'`, `--proto-redir '=http,https'`, and `--` immediately before the URL.
- Make exactly one request per valid live instance.
- Make exactly one request per valid Discord account when `DISCORD_BOT_TOKEN` is non-empty. Make zero requests for a Discord account when the token is unset or empty.
- Never retry, including after HTTP 429.
- Do not enable `set -x`, invoke the collector through `bash -x`, or add a debug path that prints credentials or an Authorization header.
- Detect all configuration errors before making any live-instance or Discord request.
- All new or edited shell code must work under Bash 3.2. Do not use `declare -g`, `declare -ag`, case-conversion expansions, `mapfile`, `readarray`, associative arrays, or other Bash 4+ features. Use `tr '[:upper:]' '[:lower:]'` for lowercasing.
- Under `set -u`, guard empty or unset array expansion with `"${arr[@]+"${arr[@]}"}"`.
- Use only Bash, `curl`, and `jq`.

## Discord Constraints

- Use `GET https://discord.com/api/v10/channels/{channel_id}/messages?limit=50` with `Authorization: Bot <token>`.
- Read the token only from `DISCORD_BOT_TOKEN`.
- Never accept a token in configuration, log it, render it, or expose it in an error or test diagnostic.
- `bot_user_id` is a public identifier used only for exact authorship matching.
- An unset or empty token is an account-level collection failure with the exact reason `DISCORD_BOT_TOKEN not set`; it is not a fatal configuration error.
- Treat every non-2xx response, including 429, as a collection failure reporting the HTTP status without fabricated counts.
- Treat an omitted or null `reactions` field as an empty array.
- Match only messages whose `author.id` exactly equals the configured `bot_user_id`.
- Do not infer identity from `author.bot`, other authors, or the token, and do not make an identity request.
- Preserve the API’s newest-first order and consider at most the first 10 matching messages.
- Distinguish no matching messages from a nonzero matching-message count with zero reactions.
- Render accounts in configuration order.

## Phase 1 — Collect and Surface Live Instances and Discord Engagement

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=lib/ops/collect-fleet-health.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=examples/sample-fleet-config-with-ops.json -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=tests/phase27.sh -->
<!-- runner:read=bin/e3d-pilot -->
<!-- runner:read=tests/phase17.sh -->
<!-- runner:read=tests/phase21.sh -->
<!-- runner:read=/Users/mini/e3d/agents/scripts/discord-heartbeat.js -->
<!-- runner:verify=set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done -->

### Requirements

1. Create executable `lib/ops/collect-fleet-health.sh`. It takes one fleet-config JSON path and outputs a `## Live Operations` Markdown block. It exits nonzero on configuration errors. Provide separate named functions for:

   - live-instance validation;
   - collection of one live instance;
   - live-instance rendering;
   - social-account validation;
   - collection of one Discord account;
   - Discord rendering;
   - platform dispatch.

   Keep live-instance and Discord collection independent so a future Moltbook implementation can add a sibling dispatch branch.

2. Accept optional top-level `live_instances`. If present, it must be an array. Every entry must be an object containing exactly:

   - `name`: non-empty string;
   - `url`: non-empty string with an HTTP or HTTPS scheme, non-empty authority, and no userinfo component.

   Reject a wrong top-level type, non-object entry, missing or empty required field, invalid URL, or extra field. Emit a clear stderr error and exit nonzero.

3. For each valid live instance, make exactly one HTTP GET to its configured URL. Use the shared curl constraints plus `-sS -L -o /dev/null -w "%{http_code}\t%{time_total}"`, or an equivalent method that captures status and elapsed seconds separately from the body.

   Validate the elapsed value as a nonnegative decimal number and truncate it to integer milliseconds.

   Classify every possible result as follows:

   - `healthy`: curl exits 0, status is exactly 200, and latency is at most 1500 ms.
   - `degraded`: curl exits 0, latency is valid, and either the status is 201–399 or the status is 200 with latency above 1500 ms.
   - `down`: curl exits nonzero; latency is invalid; status is not a three-digit decimal HTTP status; or status is outside 200–399, including 000, 1xx, 4xx, 5xx, and 6xx–9xx.

   Map nonzero curl exits to:

   - 28: `HTTP timeout`;
   - 7: `HTTP connection-refused`;
   - 6: `HTTP dns-error`;
   - any other nonzero exit: `HTTP unknown-error`.

   If curl exits 0 but status or elapsed output is invalid, use `HTTP invalid-curl-output`.

   If elapsed output is invalid, render latency as `unavailable`, regardless of curl exit. Otherwise render the truncated integer followed by `ms`.

   Sanitize `name` and `url` for single-line Markdown by stripping or replacing carriage returns and newlines. Render:

   ```
   ## Live Operations

   ### Live Instance Status
   - **{name}** ({url}): {state} — {numeric-status-or-error-label}, {integer}ms
   ```

   When latency is unavailable, render:

   ```
   - **{name}** ({url}): {state} — {numeric-status-or-error-label}, unavailable
   ```

   For a curl failure, replace the numeric status with the mapped curl error label. For invalid successful curl output, use `HTTP invalid-curl-output`.

   When no live instances are configured but the collector is invoked because social accounts exist, render:

   ```
   ### Live Instance Status
   No live instances configured.
   ```

4. Accept optional top-level `social_accounts`. If present, it must be an array. Every entry must be an object containing exactly:

   - `platform`: the string `discord`;
   - `name`: non-empty string;
   - `channel_id`: non-empty string;
   - `bot_user_id`: non-empty string.

   Reject a wrong top-level type, non-object entry, missing or unsupported platform, missing or empty required field, or extra field. Emit a clear stderr error and exit nonzero.

5. Integrate both validations into `validate_fleet_discover_config` in `bin/e3d-pilot`, either by invoking a validation-only collector path or by using equivalent validation logic. Complete validation of both signal types before any collection. An error in either type must result in zero HTTP requests across both types.

6. For every valid Discord account, read `DISCORD_BOT_TOKEN` from the process environment. If it is unset or empty, record exactly one account result with failure reason `DISCORD_BOT_TOKEN not set`, make no request for that account, and continue rendering all configured accounts. Never reveal a token value.

7. For each credentialed Discord account, make exactly one messages request. Request up to 50 messages, use all shared curl constraints, send the bot Authorization header, capture HTTP status separately from the body, and do not retry.

8. On a 2xx response, require the body to be a valid JSON array. Select messages whose `author.id` exactly equals `bot_user_id`, preserve response order, and take at most the first 10 matches.

   Every considered matching message must be an object with an object-valued `author` and string-valued `author.id`. An omitted or null `reactions` field is equivalent to `[]`. Any present non-null `reactions` value must be an array, and every reaction entry must be an object with a nonnegative integer `count`. Sum all accepted counts.

   Invalid payload shape, invalid matching-message structure, invalid reactions structure, or an invalid count produces a collection failure, never a partial result.

9. Render each Discord account exactly once, using its configured name, in one of these states:

   - `no recent messages found`;
   - `{N} recent messages, {R} total reactions`, where `N` is 1–10 and `R` may be zero;
   - `collection failure — {credential-safe reason}`.

   A curl request failure must include a useful credential-safe reason. A non-2xx response must include its HTTP status. HTTP 429 is a single, non-retried failure and must not be represented as zero engagement.

10. Update `build_fleet_discover_facts_markdown` to invoke the collector only if at least one of `live_instances` or `social_accounts` is a non-empty array. Append its output to the facts file.

   If both fields are absent or empty, skip the collector entirely and preserve byte-identical existing output.

   When the collector is invoked:

   - output one `## Live Operations` section;
   - output `### Live Instance Status` first;
   - if no live instances exist, output `No live instances configured.`;
   - output `### Social Engagement` immediately afterward only when `social_accounts` is non-empty;
   - omit `### Social Engagement` entirely when `social_accounts` is absent or empty.

11. Update `build_fleet_discover_prompt` so `### Operational Recommendations` requests exactly one recommendation for every:

   - degraded live instance;
   - down live instance;
   - Discord account with at least one considered message and zero total reactions;
   - Discord account with a collection failure.

   Every requested recommendation must name the instance or account and repeat its exact reported state without guessing a cause. Preserve configuration order within each signal and render social recommendations in social-account configuration order.

   Do not request recommendations for healthy instances, nonzero Discord engagement, or `no recent messages found`. Omit the entire recommendations section when no result qualifies.

12. Add `tests/phase27.sh` using test-owned temporary directories and fake executables on `PATH`, following `tests/phase17.sh` and `tests/phase21.sh`. The test must trap cleanup; keep fake curl state, bodies, status files, and traces inside its temporary directory; block accidental real network access; and require no real credential.

13. Cover these live-instance cases:

   - HTTP 200 at or below 1500 ms is healthy;
   - HTTP 200 above 1500 ms is degraded;
   - non-200 2xx is degraded;
   - 3xx is degraded;
   - 000, 1xx, 4xx, 5xx, and a representative 6xx status are down;
   - curl exits 28, 7, 6, and another nonzero value with the required labels;
   - invalid elapsed output with curl exit 0 produces `HTTP invalid-curl-output` and unavailable latency;
   - invalid status output with curl exit 0 produces `HTTP invalid-curl-output`;
   - nonzero curl exit with invalid elapsed output retains the mapped curl label and uses unavailable latency;
   - exactly one request occurs per instance, with no retry;
   - required curl flags are present and `--` immediately precedes the URL;
   - invalid `live_instances` type, non-object entry, missing field, empty field, invalid scheme, userinfo, and extra field are rejected;
   - a validation failure occurs before any request;
   - absent or empty live instances produce `No live instances configured.` when social accounts activate the section;
   - degraded and down results receive recommendations;
   - healthy results do not;
   - `## Live Operations` is absent when both arrays are absent or empty.

14. Cover these Discord cases:

   - reactions are summed only across messages exactly matching `bot_user_id`;
   - messages from other users, including other bots, are excluded;
   - only the 10 newest matching messages count when more than 10 match;
   - zero reactions work with empty, omitted, and null `reactions`;
   - no matching messages are distinct from zero engagement;
   - unset and empty `DISCORD_BOT_TOKEN` produce `DISCORD_BOT_TOKEN not set` and zero requests;
   - an ordinary non-2xx response includes the HTTP status;
   - HTTP 429 produces one request, no retry, and a failure rather than zero engagement;
   - malformed successful JSON is a failure;
   - invalid message, author, reactions, reaction-entry, non-integer count, and negative count structures are failures;
   - wrong `social_accounts` type, non-object entry, missing platform, unsupported platform, missing field, empty field, and extra field are rejected;
   - social validation failure occurs before any live-instance or Discord request;
   - account results render in configuration order;
   - zero engagement and collection failures receive recommendations;
   - nonzero engagement and no matching messages do not;
   - `### Social Engagement` is absent when `social_accounts` is absent or empty;
   - token values never appear in stdout, stderr, facts, or test-visible request diagnostics.

15. Add `examples/sample-fleet-config-with-ops.json` containing providers, at least one fictional live instance, and one fictional Discord account. Use obviously fake URLs and identifiers. Include no token or secret field.

16. Update `README.md` to document:

   - optional `live_instances`, its exact fields and URL validation;
   - one-request-per-instance behavior;
   - healthy, degraded, and down classification, including the 1500 ms threshold;
   - optional `social_accounts`, its exact fields, and Discord as the only supported platform;
   - `bot_user_id` as a public exact-authorship identifier rather than a credential;
   - the `DISCORD_BOT_TOKEN` environment requirement;
   - one request per credentialed Discord account and zero requests when the token is missing;
   - read-only behavior and no retries;
   - healthy, degraded, down, no-message, zero-engagement, and failure meanings;
   - placement and conditional presence of `## Live Operations`, `### Live Instance Status`, and `### Social Engagement`;
   - omission of all live-operations output when both signals are absent or empty;
   - recommendation rules;
   - Moltbook as a planned follow-on;
   - credentials never belonging in fleet configuration.

17. Run:

   ```
   set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done
   ```

   Do not modify any pre-existing test to make failures pass.

## Acceptance Criteria

- Exactly the five annotated files change, with fewer than 1400 cumulative changed lines.
- Baseline fleet-discovery output remains byte-identical when both signals are absent or empty.
- Every live-instance outcome is deterministically classified, including 000, 1xx, 4xx, 5xx, out-of-range three-digit statuses, invalid status text, invalid elapsed text, and curl failures.
- Each live instance receives exactly one request and no retry.
- Each credentialed Discord account receives exactly one request and no retry; accounts without a token receive zero requests.
- All configuration is validated before any request.
- Discord aggregation uses exact configured-user matching, newest-first order, a maximum of 10 matches, and validated nonnegative integer reaction counts.
- Missing or null reactions contribute zero.
- No-message, zero-engagement, and failure states remain distinct.
- HTTP 429 is a single failure result with no retry.
- Tokens never appear in output, errors, facts, configuration examples, or test-visible diagnostics.
- Recommendations are emitted exactly for degraded/down instances and zero-engagement/failed Discord accounts, preserving applicable configuration order.
- The example contains only fictional operational data and no secret.
- README documents both schemas, credentials, collection behavior, states, output placement, recommendations, and deferred Moltbook support.
- Preserved functions, provider dispatch behavior, and every pre-existing test remain unchanged.
- The full repository verification passes under Bash 3.2 without network access or a real Discord token.
```
```

### Reviewer 3: devin

Status: approved

Reason: Spec is internally consistent, technically complete, and all edge cases (3xx with -L, invalid elapsed with curl-0, 429 as single failure, token exposure prevention) are explicitly covered.

Raw Response:

```text
---STATUS---
status: approved
reason: Spec is internally consistent, technically complete, and all edge cases (3xx with -L, invalid elapsed with curl-0, 429 as single failure, token exposure prevention) are explicitly covered.
```

Round Result: not converged

At least one reviewer requested revision in round 2.

## Round 3

### Draft Before Round

```text
# Fleet Ops: Live Instances and Discord Engagement Signal

## Overview

Create `lib/ops/collect-fleet-health.sh` and integrate it into fleet discovery to surface two independent, read-only operational signals: live-instance HTTP health and Discord channel engagement. Both signals appear under a new `## Live Operations` facts section.

Moltbook support remains a separate follow-on.

## Goals

- Validate, collect, and render `live_instances` and Discord `social_accounts`.
- Classify every live-instance result as healthy, degraded, or down.
- Fetch recent Discord messages using one authenticated request per credentialed account.
- Count at most the 10 newest messages authored by the configured bot user and sum their reactions.
- Distinguish no matching messages, genuine zero engagement, and collection failure.
- Request recommendations only for degraded/down instances, zero-engagement accounts, and failed accounts.
- Preserve existing fleet cadence, approval gates, provider dispatch, and all unrelated behavior.
- Keep credentials exclusively in runtime environment variables.
- Add a fictional example configuration.

## Non-Goals

- Moltbook, X/Twitter, Telegram, Farcaster, or other social platforms.
- Posting, replying, reacting, voting, or any other write operation.
- Historical metrics, trends, persistence, or analytics storage.
- Reading or modifying bot-local state such as `discord-state.json`.
- Modifying anything under `/Users/mini/e3d/**`.
- Changing single-repository discovery or ideation.
- Changing candidate scoring, negotiation, execution, review, publication, or ledger schemas.
- Changing `try_stage_provider` or any provider-panel dispatch loop.
- Changing any pre-existing test.
- Rotating, relocating, or changing existing Discord credentials.

## Existing Files

- `bin/e3d-pilot` contains `validate_fleet_discover_config`, `build_fleet_discover_facts_markdown`, `build_fleet_discover_prompt`, and `fleet_discover_stage`. Read it completely before modifying it.
- `examples/sample-fleet-config.json` demonstrates the existing fleet schema.
- `README.md` documents fleet discovery.
- `tests/phase17.sh` and `tests/phase21.sh` demonstrate the test-owned fake-executable-on-`PATH` convention.
- `/Users/mini/e3d/agents/scripts/discord-heartbeat.js` may be read to confirm the Discord response shape but must not be modified.

## Files to Change

Exactly these five files may change:

- Create executable `lib/ops/collect-fleet-health.sh`.
- Modify `bin/e3d-pilot`.
- Create `examples/sample-fleet-config-with-ops.json`.
- Modify `README.md`.
- Create `tests/phase27.sh`.

## Shared Constraints

- Keep the cumulative change below 1400 changed lines.
- Do not modify `LICENSE`, `docs/build-e3d-pilot.md`, `.github/workflows/**`, `.e3d-pilot/**`, `.git/**`, any pre-existing test, or anything under `/Users/mini/e3d/**`.
- Preserve `try_stage_provider`, `discover_stage`, `ideate_stage`, and provider-panel dispatch behavior inside `fleet_discover_stage`.
- Preserve byte-identical fleet-discovery output when both `live_instances` and `social_accounts` are absent or empty.
- Route every outbound request through `curl` so tests can block network access by shadowing it on `PATH`.
- Every request must use `--max-time 10`, `--max-redirs 1`, `--proto '=http,https'`, `--proto-redir '=http,https'`, and `--` immediately before the URL.
- Make exactly one request per valid live instance.
- Make exactly one request per valid Discord account when `DISCORD_BOT_TOKEN` is non-empty. Make zero requests for a Discord account when the token is unset or empty.
- Never retry, including after HTTP 429.
- Do not enable `set -x`, invoke the collector through `bash -x`, or add a debug path that prints credentials or an Authorization header.
- Detect all configuration errors before making any live-instance or Discord request.
- All new or edited shell code must work under Bash 3.2. Do not use `declare -g`, `declare -ag`, case-conversion expansions, `mapfile`, `readarray`, associative arrays, or other Bash 4+ features. Use `tr '[:upper:]' '[:lower:]'` for lowercasing.
- Under `set -u`, guard empty or unset array expansion with `"${arr[@]+"${arr[@]}"}"`.
- Use only Bash, `curl`, and `jq`.

## Discord Constraints

- Use `GET https://discord.com/api/v10/channels/{channel_id}/messages?limit=50` with `Authorization: Bot <token>`.
- Read the token only from `DISCORD_BOT_TOKEN`.
- Never accept a token in configuration, log it, render it, or expose it in an error or test diagnostic.
- `bot_user_id` is a public identifier used only for exact authorship matching.
- An unset or empty token is an account-level collection failure with the exact reason `DISCORD_BOT_TOKEN not set`; it is not a fatal configuration error.
- Treat every non-2xx response, including 429, as a collection failure reporting the HTTP status without fabricated counts.
- Treat an omitted or null `reactions` field as an empty array.
- Match only messages whose `author.id` exactly equals the configured `bot_user_id`.
- Do not infer identity from `author.bot`, other authors, or the token, and do not make an identity request.
- Preserve the API’s newest-first order and consider at most the first 10 matching messages.
- Distinguish no matching messages from a nonzero matching-message count with zero reactions.
- Render accounts in configuration order.

## Phase 1 — Collect and Surface Live Instances and Discord Engagement

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=lib/ops/collect-fleet-health.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=examples/sample-fleet-config-with-ops.json -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=tests/phase27.sh -->
<!-- runner:read=bin/e3d-pilot -->
<!-- runner:read=tests/phase17.sh -->
<!-- runner:read=tests/phase21.sh -->
<!-- runner:read=/Users/mini/e3d/agents/scripts/discord-heartbeat.js -->
<!-- runner:verify=set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done -->

### Requirements

1. Create executable `lib/ops/collect-fleet-health.sh`. It takes one fleet-config JSON path and outputs a `## Live Operations` Markdown block. It exits nonzero on configuration errors. Provide separate named functions for:

   - live-instance validation;
   - collection of one live instance;
   - live-instance rendering;
   - social-account validation;
   - collection of one Discord account;
   - Discord rendering;
   - platform dispatch.

   Keep live-instance and Discord collection independent so a future Moltbook implementation can add a sibling dispatch branch.

2. Accept optional top-level `live_instances`. If present, it must be an array. Every entry must be an object containing exactly:

   - `name`: non-empty string;
   - `url`: non-empty string with an HTTP or HTTPS scheme, non-empty authority, and no userinfo component.

   Reject a wrong top-level type, non-object entry, missing or empty required field, invalid URL, or extra field. Emit a clear stderr error and exit nonzero.

3. For each valid live instance, make exactly one HTTP GET to its configured URL. Use the shared curl constraints plus `-sS -L -o /dev/null -w "%{http_code}\t%{time_total}"`, or an equivalent method that captures status and elapsed seconds separately from the body.

   Validate the elapsed value as a nonnegative decimal number and truncate it to integer milliseconds.

   Classify every possible result as follows:

   - `healthy`: curl exits 0, status is exactly 200, and latency is at most 1500 ms.
   - `degraded`: curl exits 0, latency is valid, and either the status is 201–399 or the status is 200 with latency above 1500 ms.
   - `down`: curl exits nonzero; latency is invalid; status is not a three-digit decimal HTTP status; or status is outside 200–399, including 000, 1xx, 4xx, 5xx, and 6xx–9xx.

   Map nonzero curl exits to:

   - 28: `HTTP timeout`;
   - 7: `HTTP connection-refused`;
   - 6: `HTTP dns-error`;
   - any other nonzero exit: `HTTP unknown-error`.

   If curl exits 0 but status or elapsed output is invalid, use `HTTP invalid-curl-output`.

   If elapsed output is invalid, render latency as `unavailable`, regardless of curl exit. Otherwise render the truncated integer followed by `ms`.

   Sanitize `name` and `url` for single-line Markdown by stripping or replacing carriage returns and newlines. Render:

   ```
   ## Live Operations

   ### Live Instance Status
   - **{name}** ({url}): {state} — {numeric-status-or-error-label}, {integer}ms
   ```

   When latency is unavailable, render:

   ```
   - **{name}** ({url}): {state} — {numeric-status-or-error-label}, unavailable
   ```

   For a curl failure, replace the numeric status with the mapped curl error label. For invalid successful curl output, use `HTTP invalid-curl-output`.

   When no live instances are configured but the collector is invoked because social accounts exist, render:

   ```
   ### Live Instance Status
   No live instances configured.
   ```

4. Accept optional top-level `social_accounts`. If present, it must be an array. Every entry must be an object containing exactly:

   - `platform`: the string `discord`;
   - `name`: non-empty string;
   - `channel_id`: non-empty string;
   - `bot_user_id`: non-empty string.

   Reject a wrong top-level type, non-object entry, missing or unsupported platform, missing or empty required field, or extra field. Emit a clear stderr error and exit nonzero.

5. Integrate both validations into `validate_fleet_discover_config` in `bin/e3d-pilot`, either by invoking a validation-only collector path or by using equivalent validation logic. Complete validation of both signal types before any collection. An error in either type must result in zero HTTP requests across both types.

6. For every valid Discord account, read `DISCORD_BOT_TOKEN` from the process environment. If it is unset or empty, record exactly one account result with failure reason `DISCORD_BOT_TOKEN not set`, make no request for that account, and continue rendering all configured accounts. Never reveal a token value.

7. For each credentialed Discord account, make exactly one messages request. Request up to 50 messages, use all shared curl constraints, send the bot Authorization header, capture HTTP status separately from the body, and do not retry.

8. On a 2xx response, require the body to be a valid JSON array. Select messages whose `author.id` exactly equals `bot_user_id`, preserve response order, and take at most the first 10 matches.

   Every considered matching message must be an object with an object-valued `author` and string-valued `author.id`. An omitted or null `reactions` field is equivalent to `[]`. Any present non-null `reactions` value must be an array, and every reaction entry must be an object with a nonnegative integer `count`. Sum all accepted counts.

   Invalid payload shape, invalid matching-message structure, invalid reactions structure, or an invalid count produces a collection failure, never a partial result.

9. Render each Discord account exactly once, using its configured name, in one of these states:

   - `no recent messages found`;
   - `{N} recent messages, {R} total reactions`, where `N` is 1–10 and `R` may be zero;
   - `collection failure — {credential-safe reason}`.

   A curl request failure must include a useful credential-safe reason. A non-2xx response must include its HTTP status. HTTP 429 is a single, non-retried failure and must not be represented as zero engagement.

10. Update `build_fleet_discover_facts_markdown` to invoke the collector only if at least one of `live_instances` or `social_accounts` is a non-empty array. Append its output to the facts file.

   If both fields are absent or empty, skip the collector entirely and preserve byte-identical existing output.

   When the collector is invoked:

   - output one `## Live Operations` section;
   - output `### Live Instance Status` first;
   - if no live instances exist, output `No live instances configured.`;
   - output `### Social Engagement` immediately afterward only when `social_accounts` is non-empty;
   - omit `### Social Engagement` entirely when `social_accounts` is absent or empty.

11. Update `build_fleet_discover_prompt` so `### Operational Recommendations` requests exactly one recommendation for every:

   - degraded live instance;
   - down live instance;
   - Discord account with at least one considered message and zero total reactions;
   - Discord account with a collection failure.

   Every requested recommendation must name the instance or account and repeat its exact reported state without guessing a cause. Preserve configuration order within each signal and render social recommendations in social-account configuration order.

   Do not request recommendations for healthy instances, nonzero Discord engagement, or `no recent messages found`. Omit the entire recommendations section when no result qualifies.

12. Add `tests/phase27.sh` using test-owned temporary directories and fake executables on `PATH`, following `tests/phase17.sh` and `tests/phase21.sh`. The test must trap cleanup; keep fake curl state, bodies, status files, and traces inside its temporary directory; block accidental real network access; and require no real credential.

13. Cover these live-instance cases:

   - HTTP 200 at or below 1500 ms is healthy;
   - HTTP 200 above 1500 ms is degraded;
   - non-200 2xx is degraded;
   - 3xx is degraded;
   - 000, 1xx, 4xx, 5xx, and a representative 6xx status are down;
   - curl exits 28, 7, 6, and another nonzero value with the required labels;
   - invalid elapsed output with curl exit 0 produces `HTTP invalid-curl-output` and unavailable latency;
   - invalid status output with curl exit 0 produces `HTTP invalid-curl-output`;
   - nonzero curl exit with invalid elapsed output retains the mapped curl label and uses unavailable latency;
   - exactly one request occurs per instance, with no retry;
   - required curl flags are present and `--` immediately precedes the URL;
   - invalid `live_instances` type, non-object entry, missing field, empty field, invalid scheme, userinfo, and extra field are rejected;
   - a validation failure occurs before any request;
   - absent or empty live instances produce `No live instances configured.` when social accounts activate the section;
   - degraded and down results receive recommendations;
   - healthy results do not;
   - `## Live Operations` is absent when both arrays are absent or empty.

14. Cover these Discord cases:

   - reactions are summed only across messages exactly matching `bot_user_id`;
   - messages from other users, including other bots, are excluded;
   - only the 10 newest matching messages count when more than 10 match;
   - zero reactions work with empty, omitted, and null `reactions`;
   - no matching messages are distinct from zero engagement;
   - unset and empty `DISCORD_BOT_TOKEN` produce `DISCORD_BOT_TOKEN not set` and zero requests;
   - an ordinary non-2xx response includes the HTTP status;
   - HTTP 429 produces one request, no retry, and a failure rather than zero engagement;
   - malformed successful JSON is a failure;
   - invalid message, author, reactions, reaction-entry, non-integer count, and negative count structures are failures;
   - wrong `social_accounts` type, non-object entry, missing platform, unsupported platform, missing field, empty field, and extra field are rejected;
   - social validation failure occurs before any live-instance or Discord request;
   - account results render in configuration order;
   - zero engagement and collection failures receive recommendations;
   - nonzero engagement and no matching messages do not;
   - `### Social Engagement` is absent when `social_accounts` is absent or empty;
   - token values never appear in stdout, stderr, facts, or test-visible request diagnostics.

15. Add `examples/sample-fleet-config-with-ops.json` containing providers, at least one fictional live instance, and one fictional Discord account. Use obviously fake URLs and identifiers. Include no token or secret field.

16. Update `README.md` to document:

   - optional `live_instances`, its exact fields and URL validation;
   - one-request-per-instance behavior;
   - healthy, degraded, and down classification, including the 1500 ms threshold;
   - optional `social_accounts`, its exact fields, and Discord as the only supported platform;
   - `bot_user_id` as a public exact-authorship identifier rather than a credential;
   - the `DISCORD_BOT_TOKEN` environment requirement;
   - one request per credentialed Discord account and zero requests when the token is missing;
   - read-only behavior and no retries;
   - healthy, degraded, down, no-message, zero-engagement, and failure meanings;
   - placement and conditional presence of `## Live Operations`, `### Live Instance Status`, and `### Social Engagement`;
   - omission of all live-operations output when both signals are absent or empty;
   - recommendation rules;
   - Moltbook as a planned follow-on;
   - credentials never belonging in fleet configuration.

17. Run:

   ```
   set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done
   ```

   Do not modify any pre-existing test to make failures pass.

## Acceptance Criteria

- Exactly the five annotated files change, with fewer than 1400 cumulative changed lines.
- Baseline fleet-discovery output remains byte-identical when both signals are absent or empty.
- Every live-instance outcome is deterministically classified, including 000, 1xx, 4xx, 5xx, out-of-range three-digit statuses, invalid status text, invalid elapsed text, and curl failures.
- Each live instance receives exactly one request and no retry.
- Each credentialed Discord account receives exactly one request and no retry; accounts without a token receive zero requests.
- All configuration is validated before any request.
- Discord aggregation uses exact configured-user matching, newest-first order, a maximum of 10 matches, and validated nonnegative integer reaction counts.
- Missing or null reactions contribute zero.
- No-message, zero-engagement, and failure states remain distinct.
- HTTP 429 is a single failure result with no retry.
- Tokens never appear in output, errors, facts, configuration examples, or test-visible diagnostics.
- Recommendations are emitted exactly for degraded/down instances and zero-engagement/failed Discord accounts, preserving applicable configuration order.
- The example contains only fictional operational data and no secret.
- README documents both schemas, credentials, collection behavior, states, output placement, recommendations, and deferred Moltbook support.
- Preserved functions, provider dispatch behavior, and every pre-existing test remain unchanged.
- The full repository verification passes under Bash 3.2 without network access or a real Discord token.

```

### Reviewer 1: claude

Status: approved

Reason: Spec is internally consistent, fully scoped across all five files, deterministic on classification/validation/recommendation edge cases, and enforces Bash 3.2/no-network testability — ready to implement.

Raw Response:

```text
---STATUS---
status: approved
reason: Spec is internally consistent, fully scoped across all five files, deterministic on classification/validation/recommendation edge cases, and enforces Bash 3.2/no-network testability — ready to implement.
```

### Reviewer 2: codex

Status: approved

Reason: The draft is complete, internally consistent, testable, and sufficiently precise to implement the two operational signals while preserving existing behavior.

Raw Response:

```text
---STATUS---
status: approved
reason: The draft is complete, internally consistent, testable, and sufficiently precise to implement the two operational signals while preserving existing behavior.
```

### Reviewer 3: devin

Status: approved

Reason: Spec is internally consistent, edge cases fully enumerated, security constraints repeated at every boundary, and Bash 3.2 restrictions are explicit and complete.

Raw Response:

```text
---STATUS---
status: approved
reason: Spec is internally consistent, edge cases fully enumerated, security constraints repeated at every boundary, and Bash 3.2 restrictions are explicit and complete.
```

## Final Outcome

Converged in round 3.
