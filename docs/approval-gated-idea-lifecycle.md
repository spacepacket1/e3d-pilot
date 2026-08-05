# Feature Ticket: Approval-Gated Ideas, Delivery, and Training Ledger

## Overview

Change e3d-pilot's default operating model from "ideate and immediately continue into implementation" to a two-gate lifecycle:

1. Discovery and ideation run autonomously and produce durable idea records. A human must approve an exact idea before e3d-pilot may draft, negotiate, execute, commit, or publish work for it.
2. Approved ideas may be implemented, verified, committed, and published as draft PRs automatically. A human must separately approve the exact reviewed PR head SHA before e3d-pilot may merge it into the configured base branch.

Persist every proposal, decision, implementation result, PR state, merge result, and later outcome as structured data. The same ledger must support auditable operations and deterministic weekly JSONL exports suitable for training or evaluating the local Qwen model.

This ticket replaces implicit authorization with explicit, durable approval records. Absence of a decision means `proposed`, never `rejected`. Approval is scoped to immutable content: editing an idea after implementation approval or pushing a new PR head after merge approval invalidates the corresponding approval.

## Goals

- Make approval-before-implementation the default for both single-repo and fleet-originated ideas.
- Keep discover and ideate fully autonomous, including revenue-focused portfolio ideation.
- Allow approved ideas to proceed unattended through draft, negotiate, execute, review, commit, and draft-PR publication.
- Require a second explicit approval before any merge into a base branch.
- Represent cross-repo ideas and their per-repo implementation/merge progress without claiming atomicity across repositories.
- Preserve an append-only, machine-readable decision history with stable idea IDs and materialized current state.
- Export weekly, versioned Qwen training datasets containing positive, negative, and outcome evidence without treating pending ideas as rejected.
- Keep existing safety rails: worktree isolation, protected paths, diff ceilings, verification, draft PRs, pause files, and no force pushes.

## Non-Goals

- Do not train, fine-tune, deploy, or restart Qwen in this ticket. Produce validated datasets and readiness reports only.
- Do not infer approval from a GitHub review, issue label, merged branch, elapsed time, lack of response, or model score.
- Do not automatically approve ideas or merges under any configuration.
- Do not promise atomic cross-repo merges. Record `partially_merged` when only some targets merge.
- Do not automatically roll back a merge. Record reverts and failures as outcomes.
- Do not add a database service, YAML dependency, or hosted control plane. JSON/JSONL plus the existing `jq` dependency remain sufficient.
- Do not include credentials, full environment dumps, provider auth files, or arbitrary untracked repository content in training exports.
- Do not remove the existing low-level stage commands. Direct stage invocation remains possible for debugging, but authorization checks must still guard every source-mutating stage.

## Existing Files (read first)

- `bin/e3d-pilot` — current stage dispatcher, fleet discover, fleet PR actions, run lifecycle, and provider orchestration.
- `config.schema.json` — strict per-repo configuration schema.
- `examples/sample-config.json` — sample per-repo defaults.
- `examples/sample-fleet-config.json` — fleet discover provider/research configuration.
- `lib/publish/github` — draft PR creation contract.
- `lib/publish/local` — no-forge publication contract.
- `tests/phase4.sh` — candidate parsing, selection, and dedup behavior.
- `tests/phase7.sh` — execute/worktree integration and safety behavior.
- `tests/phase8.sh` — review/publish behavior.
- `tests/phase9.sh` — fleet execution behavior.
- `tests/phase10.sh` — revenue-focus behavior.
- `tests/phase11.sh` — cross-repo fleet ideation behavior.
- `README.md` — public CLI and operational documentation.

## Shared Constraints

- All timestamps are RFC 3339 UTC strings. Human-facing output may also show local time.
- All persisted JSON is valid UTF-8 and written atomically using a temporary file in the destination directory followed by `mv`.
- Mutations to an idea workspace serialize through a `mkdir`-based lock with stale-PID recovery, following the existing local-model lock pattern. Concurrent cron/manual commands must not interleave JSONL lines or lose state.
- `events.jsonl` is append-only. Never edit, reorder, or delete prior events through normal CLI operations.
- `idea.json` is a derived current-state snapshot. Every mutation appends the event first and then atomically rematerializes `idea.json`; a rebuild command can reproduce snapshots solely from the event stream.
- Event payloads carry `schema_version`, `event_id`, `idea_id`, `event`, `timestamp`, `actor`, and event-specific data.
- An approval records both the approving actor and the digest/head SHA it authorizes. No mutable "approved: true" flag without this binding is acceptable.
- Every rejection, changes-requested decision, closure, failure, partial merge, merge, and revert remains queryable and exportable.
- Pending/unreviewed proposals are never emitted as negative preference labels.
- Tests must use temporary repositories, stub providers, and a stub `gh`; they must not make network calls, consume model quota, push, or merge real repositories.
- Existing successful Phase 1-11 behavior remains covered and passing unless this spec explicitly changes the default `all` stopping point or merge authorization semantics.

## Canonical Lifecycle

Allowed materialized statuses are:

```text
proposed
approved_for_implementation
rejected
implementing
implementation_failed
implemented
changes_requested
approved_for_merge
merge_failed
partially_merged
merged
closed
reverted
```

Required high-level transitions are:

```text
proposed -> approved_for_implementation | rejected
approved_for_implementation -> implementing
implementing -> implemented | implementation_failed
implemented -> approved_for_merge | changes_requested | closed
changes_requested -> implementing | closed
approved_for_merge -> merged | partially_merged | merge_failed
partially_merged -> merged | merge_failed
merged -> reverted
```

Retry events may transition `implementation_failed -> implementing` and `merge_failed -> approved_for_merge` only through an explicit new approval/retry command described below. Invalid transitions fail without appending an event.

## Phase 1 - Idea Ledger and State Machine

<!-- runner:model=high -->
<!-- runner:read=bin/e3d-pilot -->
<!-- runner:verify=bash tests/phase12.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=lib/ideas/* -->
<!-- pilot:touches=tests/phase12.sh -->

### Requirements

- Add provider-independent idea ledger helpers under `lib/ideas/`; keep CLI dispatch in `bin/e3d-pilot` and do not bury all behavior in the monolithic entrypoint.
- Define workspace roots without adding a global daemon:
  - A single-repo idea lives under `<repo>/.e3d-pilot/ideas/<idea-id>/idea.json`, with repository events in `<repo>/.e3d-pilot/events.jsonl`.
  - A fleet idea lives under `<fleet-dir>/.e3d-pilot-fleet/ideas/<idea-id>/idea.json`, with fleet events in `<fleet-dir>/.e3d-pilot-fleet/events.jsonl`.
- Generate stable IDs as `idea-<12 lowercase hex>` from a canonical source identity containing workspace kind, canonical workspace path, source run ID, and candidate identifier. Re-ingesting the same candidate is idempotent and returns the same ID. Different candidates from one run receive different IDs.
- Store at minimum in each materialized `idea.json`:
  - `schema_version`, `idea_id`, `workspace_kind`, `workspace_path`, `source_run_id`, `source_candidate`, `created_at`, `updated_at`, and `status`.
  - `focus`, `title`, `summary`, `repos`, `scores` (`attraction`, `retention`, `revenue`, `effort`), `category`, `analogy`, `dedup_rationale`, provider/model provenance when known, and content digests for source artifacts.
  - `implementation_approval`, `implementation.targets[]`, `merge_approval`, `outcomes`, and `last_event_id`, using `null`/empty collections before data exists.
- Append one compact JSON object per line to `events.jsonl`. Generate collision-resistant event IDs and reject malformed or schema-incompatible existing streams rather than appending corrupt data.
- Implement the lifecycle transitions in one shared validator. No command may set arbitrary status strings or skip required intermediate authorization.
- Approval digests use SHA-256 over the canonicalized decision-bearing idea fields: title, summary, repos, scores, category, dedup rationale, and implementation target plan. Cosmetic timestamps and current status are excluded.
- Add a rebuild function/CLI seam that deletes no source data and rematerializes all `idea.json` snapshots from `events.jsonl` into a temporary directory before replacing derived snapshots only after full validation succeeds.

### Acceptance Criteria

- Two ingestions of the same synthetic candidate produce one idea directory, one `idea_proposed` event, and the same idea ID.
- Two candidates in the same run produce different IDs.
- Every allowed transition succeeds in a table-driven test; every disallowed transition fails and leaves both the JSONL line count and `idea.json` unchanged.
- Killing a writer after event append but before snapshot materialization is recoverable by rebuild, with the correct final state.
- Two concurrent writers produce valid, complete JSONL records without truncation or interleaving.
- `bash tests/phase12.sh` passes without provider/network access.

## Phase 2 - Materialize Autonomous Ideation as Proposed Ideas

<!-- runner:model=default -->
<!-- runner:read=tests/phase4.sh -->
<!-- runner:read=tests/phase11.sh -->
<!-- runner:verify=bash tests/phase13.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=lib/ideas/* -->
<!-- pilot:touches=tests/phase13.sh -->

### Requirements

- After a successful single-repo ideate stage, materialize every non-duplicate candidate as a `proposed` idea, not only the selected candidate. Preserve the model's rank and mark which candidate the model selected.
- After a successful `fleet discover`, materialize every non-duplicate fleet candidate in the fleet workspace. Preserve its `Repos:` set and require at least two resolvable fleet repositories for it to be eligible for approval; malformed candidates remain visible with validation warnings but cannot be approved.
- Parse existing candidate Markdown defensively. Missing optional fields become `null`; missing title, description/summary, duplicate status, or candidate identity creates a warning and makes the record ineligible rather than crashing the entire ideation run.
- Persist source artifact paths and SHA-256 digests for `findings.md`, `candidates.md`, prompt files, and provider responses that exist. Paths must be workspace-relative when possible.
- Do not implement, draft, negotiate, execute, review, commit, publish, or merge as a side effect of materialization.
- Dedup must include all prior idea records:
  - `proposed` remains a possible duplicate but may be superseded by a materially different idea.
  - `rejected`, `closed`, `implementation_failed`, and `reverted` remain negative history and must not be silently reproposed unchanged.
  - `implemented`, `approved_for_merge`, `partially_merged`, and `merged` are completed/existing work for dedup purposes.
- Re-running ideation against unchanged output must not append duplicate proposal events.

### Acceptance Criteria

- A three-candidate single-repo response with one duplicate produces two proposed idea records with rank/selection metadata and no implementation artifacts.
- A two-candidate fleet response produces two fleet idea records with resolved canonical repository paths.
- An unchanged rerun is idempotent.
- A missing required candidate field produces an ineligible proposed record plus a warning; approval fails with the exact eligibility reason.
- Existing candidate artifacts remain byte-for-byte unchanged.
- `bash tests/phase13.sh` passes.

## Phase 3 - Human Decision CLI

<!-- runner:model=default -->
<!-- runner:read=bin/e3d-pilot -->
<!-- runner:verify=bash tests/phase14.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=lib/ideas/* -->
<!-- pilot:touches=tests/phase14.sh -->

### Requirements

- Add exact CLI surfaces and document them in `--help`:

  ```text
  e3d-pilot ideas list --repo <path> [--status <status>] [--json]
  e3d-pilot ideas show --repo <path> <idea-id> [--json]
  e3d-pilot ideas approve --repo <path> <idea-id> [--actor <actor>] [--note <text>]
  e3d-pilot ideas reject --repo <path> <idea-id> --reason <text> [--actor <actor>]
  e3d-pilot ideas request-changes --repo <path> <idea-id> --reason <text> [--actor <actor>]
  e3d-pilot fleet ideas <fleet.json> list [--status <status>] [--json]
  e3d-pilot fleet ideas <fleet.json> show <idea-id> [--json]
  e3d-pilot fleet ideas <fleet.json> approve <idea-id> [--actor <actor>] [--note <text>]
  e3d-pilot fleet ideas <fleet.json> reject <idea-id> --reason <text> [--actor <actor>]
  ```

- Default actor resolution order: explicit `--actor`, `git config user.email` for the controlling repo when available, then `$USER`. Store the resolved actor in every decision event.
- `approve` transitions only eligible `proposed` ideas to `approved_for_implementation` and records the canonical idea digest. Repeated approval of the same digest by the same actor is idempotent; approval after decision-bearing content changes creates no event and requires the idea to be returned to `proposed` through an explicit revision event.
- `reject` requires a non-empty reason and transitions only from `proposed`. A rejected idea cannot be implemented.
- List output includes ID, status, selected marker, title, repos, revenue/attraction/retention, age, and latest decision actor. `--json` returns a JSON array with stable field names.
- `show` displays source provenance, complete event history, approvals, targets, PRs, tests, merge state, and outcomes without requiring GitHub access.
- Commands operate correctly when invoked from outside the repository and never depend on the caller's current directory for workspace identity.

### Acceptance Criteria

- Approval and rejection append correctly attributed events and produce expected materialized states.
- Missing rejection/change reason fails without mutation.
- Pending ideas are visibly distinct from rejected ideas.
- Human and JSON list modes are deterministic and sort newest first, then by idea ID.
- An approval event contains the exact idea digest later checked by the implementation gate.
- `bash tests/phase14.sh` passes.

## Phase 4 - Default Stop Before Implementation

<!-- runner:model=high -->
<!-- runner:read=tests/phase7.sh -->
<!-- runner:read=tests/phase9.sh -->
<!-- runner:verify=bash tests/phase15.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=config.schema.json -->
<!-- pilot:touches=examples/sample-config.json -->
<!-- pilot:touches=tests/phase15.sh -->

### Requirements

- Change `e3d-pilot run --stage all` so an unapproved selected idea stops successfully immediately after ideate/materialization, before draft. Print the idea ID and exact approval command. Exit zero because waiting for product approval is a normal outcome, not a pipeline failure.
- Add a defense-in-depth authorization check to `draft`, `negotiate`, `execute`, `review`, and `publish`: each stage must resolve the run's linked idea and require a valid `approved_for_implementation` event whose digest still matches. `execute`, `review`, and `publish` additionally accept ideas already in implementation states. Direct manual stage invocation must not bypass the gate.
- Runs created before this feature have no implicit approval. Attempting a mutating stage on a legacy run fails clearly and explains how to adopt/materialize and approve it; never silently grandfather it in.
- Add per-repo config `approval` with strict defaults:

  ```json
  {
    "implementation_required": true,
    "merge_required": true
  }
  ```

  Both fields are required when `approval` is present. The sample config includes the block. `false` may be accepted only for explicit backwards-compatible operator configuration, but defaults and missing config always behave as `true`.
- Fleet `e3d-pilot fleet <repos.json>` inherits each repo's gate. A waiting-for-approval result is reported as `PENDING`, not `PASS` or `FAIL`, and does not make the fleet command exit nonzero.
- `fleet discover` remains discover+ideate only and always stops after materialization regardless of approval state.

### Acceptance Criteria

- A default `--stage all` run calls discover and ideate stubs, creates proposed ideas, prints an approval command, exits zero, and proves draft/execute providers were never invoked.
- Direct draft and execute attempts without approval fail before creating a worktree or modifying tracked files.
- Editing decision-bearing idea content after approval causes a digest mismatch and blocks implementation.
- A fleet with one pending repo and one failed repo prints separate `PENDING` and `FAIL` totals and exits nonzero only because of the failure.
- Existing config validation tests cover default/malformed `approval` behavior.
- `bash tests/phase15.sh` passes.

## Phase 5 - Implement Approved Ideas and Record Delivery

<!-- runner:model=high -->
<!-- runner:read=tests/phase5.sh -->
<!-- runner:read=tests/phase6.sh -->
<!-- runner:read=tests/phase7.sh -->
<!-- runner:read=tests/phase8.sh -->
<!-- runner:verify=bash tests/phase16.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=lib/ideas/* -->
<!-- pilot:touches=lib/publish/* -->
<!-- pilot:touches=tests/phase16.sh -->

### Requirements

- Add implementation commands:

  ```text
  e3d-pilot ideas implement --repo <path> <idea-id>
  e3d-pilot ideas implement-approved --repo <path>
  e3d-pilot fleet ideas <fleet.json> implement <idea-id>
  e3d-pilot fleet ideas <fleet.json> implement-approved
  ```

- `implement` accepts only `approved_for_implementation`, `changes_requested`, or explicitly retried `implementation_failed` ideas with a current valid approval. It appends `implementation_started` before provider execution and transitions to `implementing`.
- For a single-repo idea, link or create a run carrying the approved candidate and resume at draft, then negotiate, execute, review, and publish through existing implementations and safety rails.
- For a fleet idea:
  - The approval-bearing idea record contains an ordered `implementation.targets[]`, one entry per affected repository with canonical path, role, base SHA at approval, base branch, and candidate context.
  - Create a separate per-repo run linked to the same fleet idea ID. Generate repo-specific draft/spec work only after approval.
  - Process targets sequentially in the approved order. Never run shared local-model reviewers concurrently.
  - A failure stops remaining targets unless `--continue-on-target-failure` is explicitly passed; record every attempted and skipped target.
- Record per target: run ID, approved base SHA, actual start SHA, worktree/branch, commit SHAs, changed files/lines, verification commands/results, review outcome, publish backend, PR URL/number, and final PR head SHA.
- If a target base SHA changed since approval, stop before draft and require refreshed human approval unless the only differences are e3d-pilot audit artifacts. Do not silently implement against a materially different repository snapshot.
- An idea becomes `implemented` only when every required target has a successful verified commit and publication result (`github` draft PR or local review branch). Any target failure yields `implementation_failed` with structured failure details.
- `implement-approved` processes a deterministic oldest-approved-first queue, continues to the next idea after a recorded failure, and returns nonzero if any idea failed.
- Provider output alone never establishes success; observed commits, verification, and publication artifacts do.

### Acceptance Criteria

- An approved single-repo idea flows through stubbed draft/negotiate/execute/review/publish and records exact branch, commit, tests, and PR head.
- An unapproved/rejected idea cannot enter implementation.
- A changed base SHA blocks before provider invocation and records no false implementation result.
- A two-repo fleet idea produces two linked per-repo runs and reaches `implemented` only after both succeed.
- A second-target failure records the first target success, second target failure, remaining skips, and overall `implementation_failed` without losing evidence.
- `bash tests/phase16.sh` passes.

## Phase 6 - Merge Approval Bound to Reviewed Code

<!-- runner:model=high -->
<!-- runner:read=lib/publish/github -->
<!-- runner:read=tests/phase8.sh -->
<!-- runner:verify=bash tests/phase17.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=lib/ideas/* -->
<!-- pilot:touches=tests/phase17.sh -->

### Requirements

- Add exact commands:

  ```text
  e3d-pilot ideas approve-merge --repo <path> <idea-id> [--actor <actor>] [--note <text>]
  e3d-pilot ideas merge --repo <path> <idea-id>
  e3d-pilot fleet ideas <fleet.json> approve-merge <idea-id> [--actor <actor>] [--note <text>]
  e3d-pilot fleet ideas <fleet.json> merge <idea-id>
  e3d-pilot fleet ideas <fleet.json> merge-approved
  ```

- `approve-merge` accepts only `implemented` or `changes_requested` ideas whose required targets have passing review/verification and open PRs (or local review branches). It refreshes forge state and records the exact ordered set of target repo, PR URL/number, base branch, and head SHA being approved.
- Any new commit/head SHA after approval invalidates merge authorization. `merge` must fetch current PR metadata immediately before acting and compare every head SHA and base branch to the approval event.
- `merge` refuses draft PRs until the approval command has marked them ready or an explicit ready action is recorded. It must never infer approval from GitHub's review state alone.
- For GitHub targets, use squash merge and branch deletion only after all preflight checks for all targets pass. Then merge sequentially in approved order, appending a result event after each target.
- For local-backend targets, merge approval records authorization but the tool must not merge a local review branch into the base branch unless a separately tested local merge backend is explicitly implemented in this phase. If not implemented, fail clearly and leave the approval intact.
- A multi-repo idea becomes:
  - `merged` only after every required target merges and merge SHAs are observed.
  - `partially_merged` if at least one target merged and a later target failed or changed.
  - `merge_failed` if none merged and the operation failed.
- Update/deprecate existing `fleet prs --merge` so it cannot bypass the ledger. It must resolve the PR to an idea with current merge approval or refuse with the exact `approve-merge` command. Existing `fleet prs --approve` must not silently create idea implementation approval.
- `merge-approved` processes only valid approvals, never proposals or merely implemented ideas.

### Acceptance Criteria

- Merge without merge approval fails before any `gh pr merge` call.
- Approval followed by an unchanged head merges through the stub and records the observed merge SHA.
- Approval followed by a pushed commit fails with an approval-stale message and zero merge calls.
- GitHub review approval without a ledger event does not authorize merge.
- A two-repo merge where the second fails records `partially_merged`, including the first merge SHA and second failure.
- Existing `fleet prs --merge` is covered by a regression test proving it cannot bypass authorization.
- `bash tests/phase17.sh` passes.

## Phase 7 - Synchronization, Changes, Closures, and Outcomes

<!-- runner:model=default -->
<!-- runner:read=bin/e3d-pilot -->
<!-- runner:verify=bash tests/phase18.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=lib/ideas/* -->
<!-- pilot:touches=tests/phase18.sh -->

### Requirements

- Add lifecycle maintenance commands:

  ```text
  e3d-pilot ideas sync --repo <path> [<idea-id>]
  e3d-pilot fleet ideas <fleet.json> sync [<idea-id>]
  e3d-pilot ideas outcome --repo <path> <idea-id> --window <7d|30d|custom> --metric <key=value>... [--note <text>]
  e3d-pilot fleet ideas <fleet.json> outcome <idea-id> --window <7d|30d|custom> --metric <key=value>... [--note <text>]
  e3d-pilot ideas mark-reverted --repo <path> <idea-id> --reason <text>
  ```

- `sync` reads forge state and appends events only for observed changes: head updates, draft/ready, closed, merged, merge SHA, and CI/check summary when available. It never approves anything.
- Closing/rejecting a PR records `closed` with the prior state and reason when available. A merged PR observed outside e3d-pilot is recorded as `merged_external` evidence but must also record whether a matching merge approval existed; never rewrite history to pretend the gate was followed.
- `request-changes` invalidates prior merge approval, records the reviewed head SHA, and moves the idea to `changes_requested`. Reimplementation requires a new implementation-start event and later a new head-bound merge approval.
- `outcome` accepts typed boolean, numeric, and string values; rejects duplicate keys within one invocation; and appends rather than overwrites observations. Materialized state exposes the latest value per key plus history.
- `mark-reverted` requires a reason and observed revert commit when discoverable. Reverted ideas remain strong negative/outcome examples rather than disappearing from dedup or training history.
- Include scheduled-operation-friendly summaries and nonzero exits for malformed data, but absence of new forge changes is a successful no-op.

### Acceptance Criteria

- Sync is idempotent when forge state is unchanged.
- A new PR head invalidates an existing merge approval and moves the idea back to `implemented` or `changes_requested` as appropriate.
- External merge, closure, and revert scenarios preserve whether approvals existed.
- Multiple 7d/30d metrics remain in history and materialize predictably.
- `bash tests/phase18.sh` passes.

## Phase 8 - Weekly Qwen Dataset Export and Readiness

<!-- runner:model=high -->
<!-- runner:read=config.schema.json -->
<!-- runner:verify=bash tests/phase19.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=lib/training/* -->
<!-- pilot:touches=examples/sample-fleet-config.json -->
<!-- pilot:touches=tests/phase19.sh -->

### Requirements

- Add commands:

  ```text
  e3d-pilot fleet train readiness <fleet.json> [--since <RFC3339>]
  e3d-pilot fleet train export <fleet.json> [--week <YYYY-Www>] [--output <dir>]
  ```

- Aggregate the fleet workspace ledger plus every repository ledger named by the fleet file. Deduplicate by event ID and idea ID; fail on conflicting records for the same ID.
- `readiness` reports counts since the previous successful export (or `--since`): proposed, reviewed, approved, rejected, implementation successes/failures, merge approvals, merged, partially merged, closed, reverted, and ideas with 7d/30d outcomes.
- Support optional fleet config:

  ```json
  {
    "training": {
      "min_reviewed_ideas": 30,
      "min_implemented_ideas": 10,
      "require_negative_examples": true,
      "outcome_windows": ["7d", "30d"]
    }
  }
  ```

  Missing training config uses these defaults. Readiness says `ready: true|false` and lists every unmet threshold. It never starts training.
- Export to `<fleet-workspace>/datasets/<YYYY-Www>/` by default, using a temporary sibling directory and atomic rename. Refuse to overwrite a completed dataset unless `--output` points elsewhere; reproducible reruns with the same cutoff must produce identical content hashes.
- Produce:
  - `ideation.jsonl`: source context/provenance, candidate fields, model selection, and human decision labels. Pending ideas may appear as unlabeled inference/evaluation records but never as negative labels.
  - `preferences.jsonl`: explicit approved-vs-rejected/changes-requested preference pairs only when candidates share a comparable source run/context. Include human reasons and never fabricate a comparison.
  - `implementation.jsonl`: approved idea/target context, generated spec references, observed diff summary, tests, review, publication, merge, failures, and outcomes.
  - `manifest.json`: schema versions, cutoff, fleet file digest, source event-stream digests, record counts, filters/redactions, per-file SHA-256, and readiness result.
- Keep training/validation separation deterministic and leakage-resistant:
  - Split by stable hash of idea ID, with the newest configured time window reserved for evaluation.
  - Keep every record for one idea and its cross-repo targets in one split.
  - Record split assignment in each line and manifest counts.
- Redact secrets before writing output. At minimum detect common API/token/private-key patterns and replace values with `[REDACTED]`; exclude provider credentials, environment dumps, `.env`, auth configs, and protected-path contents entirely. Record redaction counts without recording secret values.
- Normalize large source artifacts to bounded excerpts plus digests. Do not dump entire repositories or raw diffs above configured limits into JSONL.
- Validate every JSONL line against the exporter schema using `jq`, ensure no pending idea has a negative label, and fail atomically on any violation.

### Acceptance Criteria

- A mixed synthetic ledger exports all three JSONL files and a manifest with correct counts/hashes.
- Pending ideas are not labeled rejected; explicit rejections and reversions remain available as negative/outcome evidence.
- Cross-repo records stay in one deterministic split.
- Identical inputs and cutoff produce byte-identical dataset files.
- A planted token/private key is redacted and absent from every output file.
- Threshold failures report `ready: false` without blocking export; malformed/conflicting ledgers do block export.
- `bash tests/phase19.sh` passes.

## Phase 9 - Documentation, Migration, and End-to-End Safety

<!-- runner:model=high -->
<!-- runner:read=README.md -->
<!-- runner:read=docs/build-e3d-pilot.md -->
<!-- runner:verify=bash tests/phase20.sh -->
<!-- runner:verify=set -e; for test_file in tests/phase{1..20}.sh; do bash "$test_file"; done -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=docs/* -->
<!-- pilot:touches=tests/phase20.sh -->

### Requirements

- Update `README.md` as the operator source of truth for:
  - Autonomous ideation and the implementation approval boundary.
  - How to list/show/approve/reject ideas.
  - How approved ideas are implemented and checked in as draft PRs.
  - The separate head-SHA-bound merge approval and merge commands.
  - Multi-repo partial-merge semantics.
  - Ledger locations, event immutability, rebuild, sync, outcomes, and weekly exports.
  - Cron examples separating autonomous ideation, approved-idea implementation, sync, and weekly dataset export.
- Clearly distinguish `fleet ideas approve` from GitHub review approval and from `approve-merge`. Avoid the overloaded old `fleet prs --approve` terminology in recommended workflows.
- Document a safe migration path:
  - Existing run artifacts remain readable.
  - A command may materialize a legacy selected candidate as `proposed`, but never auto-approve it.
  - Existing open e3d-pilot PRs may be adopted into an idea only through an explicit command that records provenance and starts at `implemented`, still requiring merge approval.
- Add an end-to-end test with stubbed providers and forge:
  1. Autonomous revenue-focused ideation creates a proposal and stops.
  2. Implementation is impossible before approval.
  3. Human approval enables implementation and a draft PR with recorded head SHA.
  4. Merge is impossible before the second approval.
  5. Merge approval enables merge only for that head SHA.
  6. Sync records the merge and an outcome can be appended.
  7. Weekly export includes the complete labeled history.
- Run all Phase 1-20 tests fail-fast. No test may call a live provider or forge.

### Acceptance Criteria

- A new operator can understand and execute the full two-gate workflow from `README.md` alone.
- The end-to-end test proves there is no source mutation before implementation approval and no base-branch merge before head-bound merge approval.
- Legacy adoption never creates approval implicitly.
- `codex-spec-runner docs/approval-gated-idea-lifecycle.md --list` parses all phases with the intended model tiers.
- All Phase 1-20 tests pass in one fail-fast invocation.
