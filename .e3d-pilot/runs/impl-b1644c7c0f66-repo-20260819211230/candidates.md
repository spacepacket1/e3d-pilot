---
selected: candidate-1
reason: approved idea implementation
focus: default
---

# Candidates

## Proposed Candidates

### Candidate 1: Fleet ops: live instance health signals (part 1 of 2)
Duplicate: no
Dedup rationale: Hand-authored by human + Claude Code; split off from idea-215ebe946e27 after that candidate's draft stage rejected the combined scope as too large for this repo's 400-line ceiling. This ticket covers live-instance health only; social engagement is a deferred follow-on.
Category: workflow
Analogy: Ops/SRE status dashboards folded into an existing daily research pass rather than a separate monitoring product.
Attraction (1-5): 4
Retention (1-5): 4
Effort: low
Revenue (1-5|n/a): 2
Description: # Fleet Ops: Live Instance Health Signals

## Overview

Extend the existing `~/.e3d-pilot-fleet` cross-repo `fleet discover` pass so that,
alongside its current per-repo README/git digest, it also gathers live operational
signals — HTTP health of the portfolio's deployed production instances
(netdoctor.e3d.ai, cast.e3d.ai, maps.e3d.ai, e3d.ai, futco.ai) — so the same daily
model pass can surface operational recommendations, not just product and
monetization ideas, in the same `candidates.md` ledger it already produces.

This is the first of two tickets. A prior single-ticket attempt covering both live
instance health and social-platform engagement was rejected by this repo's own
`draft` stage as too large for its `max_diff_files=15`/`max_diff_lines=400` ceiling
(4 platform adapters + secret-safe tests + wiring + docs could not plausibly fit in
one PR). This ticket covers live instance health only; social engagement signals are
deferred to a follow-on ticket once this one lands, extending the same collector.

The daily cadence, the `discover` → `ideate` → ledger → (`ideas approve` →
`ideas implement`) pipeline, and the multi-provider `negotiate` consensus step are
all unchanged. This ticket adds a new, purely read-only data source to `discover`
and a new instruction to `ideate`'s prompt; it does not add a new pipeline.

## Goals

- Add an optional `live_instances` array to `.e3d-pilot-fleet/config.json`.
- Add a new collector script that performs one bounded, read-only HTTP check per
  configured live instance — no credentials, no writes, no side effects.
- Feed the collector's output into `fleet_discover_stage`'s existing facts file as a
  new section, alongside the current per-repo digest.
- Extend the fleet discover prompt to request an `### Operational Recommendations`
  section: one entry per non-healthy instance, naming it, its status, and a concrete
  next step.
- Keep the feature strictly read-only end to end.
- Design the collector's config shape and output format so a follow-on ticket can add
  a `social_accounts` array and per-platform checks to the same script without
  reworking this phase's structure.

## Non-Goals

- Social-platform engagement metrics (x/discord/telegram/moltbook) — explicit
  follow-on ticket, not part of this change.
- A fast/near-real-time alerting path for outages (the user explicitly chose to fold
  this into the existing daily cadence rather than add one; a separate fast path can
  be a later, distinct ticket if ever needed).
- Auto-remediation of any kind — restarting a process, rolling back a deploy.
- Changing single-repo `discover`/`ideate` behavior, or `fleet ideas implement`'s
  draft/negotiate/execute/review/publish machinery itself.

## Existing Files

- `bin/e3d-pilot`: `fleet_repo_digest` (~L4476), `build_fleet_discover_facts_markdown`
  (~L4498), `build_fleet_discover_prompt` (~L4509), `fleet_discover_stage` (~L4540),
  `validate_fleet_discover_config` (~L4434), `run_stage_provider` (~L4456).
- `examples/sample-fleet-config.json`: the example `.e3d-pilot-fleet/config.json`
  referenced from `README.md`.
- `README.md`: documents `fleet discover` around L274-300, including the
  `--focus revenue` → `### Monetization Signals` precedent this ticket mirrors.
- `tests/phase*.sh`: one shell test file per implemented phase; the repo's own
  `.e3d-pilot/config.json` verify command is
  `for test_file in tests/phase*.sh; do bash "$test_file"; done`.
- `tests/phase17.sh`, `tests/phase21.sh`: the repo's real convention for stubbing an
  external CLI in tests — a fake executable dropped in a test-owned temp bin
  directory that is prepended to `PATH` (e.g. `PATH="$bin:$PATH"`), with a
  test-controlled state/fixture file and a trace file the fake executable writes
  calls to. This ticket must follow this same pattern for stubbing `curl`, not
  invent a new one.

## Shared Constraints

- Bash-first, dependency-free beyond what the repo already requires (`bash`, `git`,
  `jq`, `curl`) — no new language runtime, no new package dependency.
- Never fabricate a health value. A failed, timed-out, or unconfigured check must
  produce an explicit `down`/`unavailable` status and a real reason, never a guessed
  number.
- Every live HTTP check uses a fixed timeout and at most one redirect
  (`curl --max-time 10 --max-redirs 1`); no retries.
- All outbound HTTP calls go through `curl` exclusively so tests can stub every call
  by shadowing `curl` with a fake executable earlier on `PATH`, per this repo's
  existing `tests/phase17.sh`/`tests/phase21.sh` convention.
- `live_instances` is optional; an absent or empty fleet config must produce today's
  exact `fleet discover` output, unchanged apart from the new section's explicit
  "not configured" state.
- Do not modify `.e3d-pilot/**`, `.git/**`, `LICENSE`, or `docs/build-e3d-pilot.md`
  (already protected in this repo's own `.e3d-pilot/config.json`).
- Keep the aggregate change within this repo's own `max_diff_files=15`/
  `max_diff_lines=400` ceiling — target well under it (roughly 4 files, 250 lines) to
  leave headroom for the negotiate/execute stages' own overhead.
- Run the configured verification command after every phase.

## Phase 1 - Live Instance Health Collector, Wired Into `fleet discover`

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=lib/ops/collect-fleet-health.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=examples/sample-fleet-config-with-ops.json -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=tests/phase24.sh -->
<!-- runner:verify=bash tests/phase24.sh -->

### Requirements

- Add `lib/ops/collect-fleet-health.sh`, invoked as
  `collect-fleet-health.sh <fleet-config.json>`, printing a markdown fragment to
  stdout.
- Config reading: `live_instances` is an array of
  `{ "name": <string>, "url": <string> }`. Missing or empty → print
  `### Live Instance Status\n\nNo live instances configured.\n`.
- Structure the script so a later `social_accounts` array (not present in this
  ticket) can be added as a second, independent code path without restructuring the
  `live_instances` handling — e.g. a top-level dispatch that checks for each
  top-level key's presence separately, not a single monolithic loop assuming only
  one kind of entry.
- Live instance check, per entry:
  - One `curl` GET with `--max-time 10 --max-redirs 1`, no retries.
  - Record wall-clock latency in milliseconds and the resulting HTTP status code, or
    a specific failure reason (`timeout`, `connection-refused`, `dns-error`,
    `unknown-error`).
  - Classify: `healthy` (2xx and latency < 2000ms), `degraded` (2xx and
    latency >= 2000ms, or any 3xx), `down` (4xx, 5xx, or any failure reason).
  - Emit one line per instance under `### Live Instance Status`:
    `- **<name>** (<url>): <classification> — HTTP <status or reason>, <latency>ms`.
- Exit 0 in every case described above (a configured check failing is reported
  inline, not a script failure); exit non-zero only for a malformed config file
  (invalid JSON, or `live_instances` present but not an array).
- In `validate_fleet_discover_config`, accept an optional `live_instances` (array of
  objects with string `name`/`url`) — validate shape when present, exactly as the
  existing `analogy_domains`/`research_topics` optional fields are validated;
  absence must remain valid.
- In `fleet_discover_stage`, after `build_fleet_discover_facts_markdown` writes
  `facts_file`, append the output of
  `lib/ops/collect-fleet-health.sh "$config_file"` to that same file under a
  `## Live Operations` heading, before the prompt is built, so the model sees it as
  part of the same facts document.
- In `build_fleet_discover_prompt`, add a new, unconditional (not focus-gated)
  instruction block directing the model to also return a
  `### Operational Recommendations` section: for each `degraded` or `down` entry in
  the "Live Operations" facts, one entry naming the specific instance, its current
  status, and one concrete recommended next step; explicitly instruct the model to
  omit this section entirely (never fabricate an entry) when every checked entry is
  `healthy` or nothing is configured.
- Add `examples/sample-fleet-config-with-ops.json` alongside the existing
  `examples/sample-fleet-config.json`, showing `live_instances` populated with
  placeholder values.
- Update `README.md`'s existing `fleet discover` section (~L274-300) to document the
  new optional `live_instances` field and the `### Operational Recommendations`
  output section, in the same style already used to document
  `### Monetization Signals` for `--focus revenue`. Note in prose that social
  engagement signals are a planned follow-on, not yet implemented.
- Do not change `candidates.md` scoring/ranking, the idea ledger schema, or any
  single-repo `discover`/`ideate` behavior.

### Acceptance Criteria

- Running the collector against a fixture config with fixture HTTP responses
  (healthy, degraded-slow, down/500, timeout) produces the exact expected markdown.
- Running the collector against a config with no `live_instances` key produces the
  "not configured" line and exits 0.
- No test in `tests/phase24.sh` makes a real network call; every `curl` invocation is
  satisfied by a stub executable shadowing `curl` on `PATH`.
- No test writes to any file outside a test-owned temp directory.
- `e3d-pilot fleet discover <fleet.json>` run against a fleet config with no
  `live_instances` produces byte-identical `fleet-discover-facts.md`/
  `fleet-discover-prompt.md` content to before this change, aside from the added
  (empty-state) "Live Operations" section.
- `e3d-pilot fleet discover <fleet.json>` run against a fixture config with a `down`
  live instance produces a facts file containing that instance's status and a prompt
  file whose instructions request the `### Operational Recommendations` section.
- `validate_fleet_discover_config` rejects a fleet config where `live_instances` is
  present but not an array, or where an entry is missing a required string field,
  with a clear error.
- The configured verification command (`tests/phase*.sh`) passes in full, including
  every pre-existing phase test.
