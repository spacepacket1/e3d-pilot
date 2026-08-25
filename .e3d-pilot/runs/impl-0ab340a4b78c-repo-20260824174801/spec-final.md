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
