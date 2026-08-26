---
selected: candidate-1
reason: approved idea implementation
focus: default
---

# Candidates

## Proposed Candidates

### Candidate 1: Fleet ops: Discord engagement signal (part 2 of 3)
Duplicate: no
Dedup rationale: Hand-authored by human + Claude Code; follow-on to idea-b1644c7c0f66 (live instance health, part 1 of 2 -> renumbered part 1 of 3, merged as PR #1). Split off from a combined Discord+Moltbook ticket after that ticket's draft stage rejected it as too large -- codex-spec-runner measures diff size cumulatively across every phase in one run, so splitting into phases within one ticket does not help; only separate tickets do. This ticket covers Discord only; Moltbook is part 3 of 3.
Category: workflow
Analogy: none
Attraction (1-5): 4
Retention (1-5): 4
Effort: low
Revenue (1-5|n/a): 2
Description: # Feature Ticket: Fleet Ops — Discord Engagement Signal (Part 2 of 3)

## Overview

Part 1 (`e3d-pilot` PR #1, merged) extended `fleet discover` with optional, read-only HTTP health checks for configured production instances, appended as a `## Live Operations` facts section so the daily cross-repo ideation pass can produce concrete operational recommendations. That ticket explicitly deferred social-platform engagement collection as a follow-on, and structured the collector (`lib/ops/collect-fleet-health.sh`) with distinct validation/collection/rendering functions specifically so a `social_accounts` collector could be added later without restructuring live-instance code.

This ticket is that follow-on's first slice. It adds a second, independent, read-only collector that reports how our own bot-posted content is performing on Discord — reactions on messages our bot has posted — appended to the same `## Live Operations` facts section `fleet discover` already produces, so the daily ideation pass can also see "did anyone engage with what we posted" alongside "are our production instances healthy."

**Split from a combined ticket, for a concrete measured reason:** a first draft of this work covered both Discord and Moltbook engagement in one ticket, organized as two phases. That ticket's own draft stage rejected it as too large: `codex-spec-runner` runs every phase of a spec inside one continuous worktree via `all` mode, and `e3d-pilot`'s diff-size ceiling is checked once, against the *cumulative* diff across every phase — not per phase. Splitting into phases inside one ticket does not reduce what gets measured against the ceiling; only splitting into separate tickets (separate `ideas implement` runs, separate worktrees, separate PRs) does. Part 1's real diff, for one signal type on one platform, was already ~870 lines against a 900-line ceiling — this ticket, covering Discord only, is sized to fit comfortably within that same precedent. Moltbook is its own follow-on ticket (Part 3 of 3), submitted once this one merges.

## Goals

- Support an optional `social_accounts` array in the fleet discovery configuration, entries of `{ "platform": "discord", "name": "...", "channel_id": "..." }`. (Only `discord` is a valid `platform` value in this ticket; a follow-on ticket adds `moltbook` to the same array.)
- For each configured Discord entry, fetch the most recent bot-authored messages in a configured channel and sum their reaction counts.
- Represent successful, empty (no recent posts), and failed checks without fabricating data, following the same honesty rule Part 1 established for live-instance health.
- Append a `### Social Engagement` section to the existing `## Live Operations` facts, alongside (not replacing) `### Live Instance Status`. When `social_accounts` is absent or empty, no `### Social Engagement` section is produced at all — no empty-state placeholder line, unlike `live_instances`' explicit "no instances configured" text. (`live_instances` always renders because it was, until now, the only signal in `## Live Operations`; an always-present empty section for every independent signal type would clutter facts a human/model reads daily. Document this asymmetry explicitly in README so it doesn't read as an inconsistency.)
- Extend `### Operational Recommendations` prompt guidance to also cover a social account with zero engagement across its recent posts, or a collection failure — without inventing a cause the collector didn't observe.
- Preserve the existing daily cadence, pipeline, and approval machinery; no new dependency beyond `curl` and `jq`, already required by Part 1.
- Read credentials exclusively from environment variables at runtime — never store a token/secret value in fleet config, matching this repo's and `e3d-corp`'s established convention.

## Non-Goals

- Moltbook, X/Twitter, Telegram, or Farcaster engagement collection — Moltbook is the immediate next ticket (Part 3 of 3), designed to extend `social_accounts`/`### Social Engagement` additively; the fleet runs bots on five platforms total, but Discord and Moltbook are the only two with a self-contained, read-only credential (a bot token that can only read) available today. X's OAuth2 refresh-token flow, Telegram's limited view-count visibility on a plain bot token, and Farcaster's separate Neynar integration each need their own scoping pass.
- Posting, replying, upvoting, or any other write action on any platform. This collector only reads.
- Historical engagement tracking, trend charts, or a persisted metrics store — each `fleet discover` run reports a fresh snapshot, exactly like Part 1's live-instance checks.
- Modifying `/Users/mini/e3d/agents/scripts/*` (the bot scripts themselves) in any way. This collector is a fully independent, external, read-only client of the platform's public API — it does not read or write the bot's local state file (`discord-state.json`) and does not need to, since it identifies "our" posts by querying the platform for content authored by our own account, not by trusting bot-local bookkeeping.
- Changes to single-repository discovery or ideation, or to the live-instance collector added in Part 1. **Explicitly: no changes to `try_stage_provider`, `discover_stage`, `ideate_stage`, or `fleet_discover_stage`'s provider-panel dispatch behavior, and no changes to any pre-existing `tests/phaseN.sh` file this ticket does not itself add.** (Called out explicitly because Part 1's implementation bundled an out-of-scope, reviewer-flagged regression in exactly this code, changing panel dispatch from skip-and-continue to fail-fast and rewriting `tests/phase25.sh` to match — it had to be reverted before merge. Do not repeat that pattern here.)
- Changes to candidate scoring, the idea ledger schema, negotiation, execution, review, or publication.
- Modifications to protected paths.
- Rotating or otherwise touching the Discord bot token currently hardcoded in `/Users/mini/e3d/agents/scripts/discord-ecosystem.config.js` (untracked, not in git history, but not sourced from an env var either) — flagged separately as an existing hygiene gap in a different repo, out of scope for this ticket.

## Existing Files

- `lib/ops/collect-fleet-health.sh` (Part 1) — has distinct validate/collect/render functions per signal type specifically so a second signal type (`social_accounts`) can be added as sibling functions without touching the `live_instances` code path. Read in full before starting.
- `bin/e3d-pilot` — `validate_fleet_discover_config`, `build_fleet_discover_facts_markdown`, `build_fleet_discover_prompt`, and `fleet_discover_stage` are where Part 1 wired `live_instances` in; this ticket wires `social_accounts` in the same three places. Do not touch `try_stage_provider` or any `*_stage` function's provider-panel dispatch loop (see Non-Goals).
- `examples/sample-fleet-config-with-ops.json` (Part 1) — demonstrates `live_instances`; this ticket adds a fictional `social_accounts` (Discord) entry to the same file.
- `README.md` — documents `live_instances` and the `## Live Operations` facts section Part 1 added; this ticket extends that same documentation.
- `tests/phase17.sh` and `tests/phase21.sh` — demonstrate the repository convention for stubbing external executables through a test-owned directory prepended to `PATH`; the new test file follows the same convention. **`tests/phase25.sh` is out of scope — do not modify it (see Non-Goals).**
- `/Users/mini/e3d/agents/scripts/discord-heartbeat.js` — read for the real API shape (below), not modified.

## Shared Constraints

### Verified platform API shape (real endpoint, checked while writing this spec)

Discord — `GET https://discord.com/api/v10/channels/{channel_id}/messages?limit=50`, header `Authorization: Bot <token>`. Returns a JSON array of message objects; each has `id`, `author.id`, `timestamp`, and an optional `reactions` array of `{ emoji, count, ... }`. A message with no reactions omits the `reactions` field entirely (not an empty array) — the collector must treat a missing field as zero, not error. Discord returns HTTP 429 with a `Retry-After` value on rate limit; treat this exactly like any other non-2xx response (a reported collection failure with the HTTP status), never retried, never fabricated as zero engagement.

### Read-only, credential-safe, honest reporting

- Route every outbound request exclusively through `curl` so tests can prevent real network access by shadowing it on `PATH`, exactly as Part 1 requires for the live-instance collector.
- Apply `--max-time 10` and `--max-redirs 1` to every request; restrict to HTTP/HTTPS.
- The collector reads `DISCORD_BOT_TOKEN` directly from the process environment — never from fleet config, never logged, never included in collector output (facts markdown must never contain a token value, even on a request failure — error messages report the HTTP status/reason, not request headers). The collector script itself must never run with `set -x`/`bash -x` tracing enabled — bash's own xtrace would print the literal `curl ... -H "Authorization: Bot $TOKEN" ...` command line, leaking the token value even though it never appears in stdout/the facts file. If a debug-trace mode is ever added to this script, it must redact the Authorization header value, not just avoid printing the token elsewhere.
- A configured `social_accounts` entry whose required environment variable is unset or empty is reported as a collection failure with a clear reason ("DISCORD_BOT_TOKEN not set"), not silently skipped and not a fatal error for the rest of the run — consistent with Part 1's "a failed instance check is collected data, not a collector process failure."
- Never fabricate a reaction count or message count. Zero recent messages and zero engagement on real messages are different, distinguishable facts and must be reported as such (e.g. "no recent messages found" vs. "5 messages, 0 total reactions").
- Perform exactly one request per configured account, with no retry on failure.
- Do not modify `LICENSE`, `docs/build-e3d-pilot.md`, `.github/workflows/**`, `.e3d-pilot/**`, `.git/**`, or any file under `/Users/mini/e3d/**`.
- Run the configured repository verification command after the phase.
- All new/edited shell scripts must run correctly under Bash 3.2 (macOS's default `/bin/bash`), which this repo's tests execute under via a login shell (`bash -lc`, which resolves differently than an interactive shell's `$PATH`). Do not use `declare -g`/`declare -ag`, `${var,,}`/`${var^^}`, `mapfile`/`readarray`, `local -A` (associative arrays), or any other Bash 4+-only construct. Lowercase strings with `tr '[:upper:]' '[:lower:]'`. Guard every `"${arr[@]}"` expansion against an empty/unset array under `set -u` using the `"${arr[@]+"${arr[@]}"}"` idiom.
- Keep the complete change within five files, comfortably under this repo's `max_diff_lines` ceiling (currently 900 — check `.e3d-pilot/config.json` for the live value). This ceiling applies to the *entire* run's cumulative diff (see the Overview's split rationale) — if the real diff approaches it, trim test scenarios rather than asking for a higher ceiling mid-execution.

## Phase 1 — Collect and Surface Discord Engagement Signal

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=lib/ops/collect-fleet-health.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=examples/sample-fleet-config-with-ops.json -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=tests/phase27.sh -->
<!-- runner:read=tests/phase17.sh -->
<!-- runner:read=tests/phase21.sh -->
<!-- runner:read=lib/ops/collect-fleet-health.sh -->
<!-- runner:verify=set -e; for test_file in tests/phase*.sh; do bash "$test_file"; done -->

### Requirements

1. Extend `lib/ops/collect-fleet-health.sh` (Part 1's collector) with a second, independent signal type. Add distinct validation, collection, and rendering functions for `social_accounts`, mirroring the existing `live_instances` functions' structure but not sharing code that would couple the two signal types together. Structure this so a future ticket can add a `moltbook` platform as a sibling code path without editing Discord's.

2. Accept an optional top-level `social_accounts` field: an array of objects. Each entry requires `platform` and `name` (a non-empty display string). Only `platform: "discord"` is valid in this ticket, requiring `channel_id` (non-empty string) as its platform-specific field. An entry naming any other platform value, missing a required field, or containing an extra field beyond `platform`/`name`/`channel_id` is invalid. Missing or empty `social_accounts` produces no `### Social Engagement` section (Goals).

3. Exit nonzero with a clear stderr message when `social_accounts` is present but not an array, or contains an invalid entry per requirement 2. Do not issue any HTTP request when configuration validation fails — for either signal type.

4. For each valid `discord` entry: call the Discord API (Shared Constraints) with the `DISCORD_BOT_TOKEN` environment variable, using `--` immediately before the URL. Sum `reactions[].count` across the most recent 10 messages (or fewer if the channel has fewer). Report: account name, message count considered, total reaction count, and — if `DISCORD_BOT_TOKEN` is unset, the request fails, or returns a non-2xx status (including 429) — a clear failure reason instead of fabricated numbers.

5. Render a `### Social Engagement` section under `## Live Operations`, after `### Live Instance Status`. One line per configured account: name, platform, and either its counts or its failure reason, in configured order.

6. Extend `build_fleet_discover_prompt` so `### Operational Recommendations` guidance also covers a Discord account with zero engagement across all considered messages, or a collection failure — one recommendation per such account, naming the account and repeating its exact reported state. Do not request a recommendation for an account with nonzero engagement. Preserve Part 1's existing rule: omit the entire `### Operational Recommendations` section when there is nothing to recommend on, across every signal type.

7. Add `tests/phase27.sh` using the established fake-executable-on-`PATH` convention (stub `curl` for Discord's API). Cover: valid entry with reactions, valid entry with zero reactions (including a message with no `reactions` field at all), missing/empty `DISCORD_BOT_TOKEN`, HTTP failure (including a 429), invalid config (bad platform, missing field, extra field, wrong type), and that `### Social Engagement` never appears when `social_accounts` is absent. All files created by the test, including fake curl state and trace files, must remain inside a test-owned temporary directory removed by a trap. Tests must not contact the network and must never require a real `DISCORD_BOT_TOKEN` value.

8. Add a fictional `social_accounts` (Discord) entry to `examples/sample-fleet-config-with-ops.json` — no real channel IDs or tokens.

9. Update `README.md`'s fleet-discover section to document `social_accounts`, `DISCORD_BOT_TOKEN`, and the `### Social Engagement` output, noting Moltbook support is a planned follow-on.

### Acceptance Criteria

- `e3d-pilot fleet discover <fleet.json>` run against a config with no `social_accounts` produces byte-identical output to Part 1's behavior.
- A fixture Discord entry with a stubbed `curl` returning messages with reaction counts produces a facts file reporting the correct summed total.
- A fixture Discord entry with `DISCORD_BOT_TOKEN` unset produces a clear failure line and issues zero HTTP requests.
- A fixture Discord entry receiving a stubbed 429 response is reported as a failure, not retried, not reported as zero engagement.
- An account with zero engagement produces exactly one `### Operational Recommendations` entry naming it; an account with nonzero engagement produces none.
- `validate_fleet_discover_config` rejects a `social_accounts` entry with an unrecognized platform, a missing required field, an extra field, or a non-array `social_accounts` value, with a clear error, before any HTTP request is attempted.
- `try_stage_provider`, `discover_stage`, `ideate_stage`, `fleet_discover_stage`'s panel-dispatch behavior, and `tests/phase25.sh` are byte-identical to `main` before this phase started.
- The configured verification command (`tests/phase*.sh`) passes in full, including every pre-existing phase test, under Bash 3.2.
