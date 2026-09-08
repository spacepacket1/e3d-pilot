# Feature Ticket: Provenance Graph Export (Debate Experiment 1)

## Overview

Two rounds of `e3d-debate` (Opus+Codex+Devin+Grok-build) converged unanimously
on rejecting a standalone `e3d-graph` product, and on a specific first
experiment instead: emit node/edge/event provenance from real e3d-pilot runs
and answer real attribution questions from that data alone, with no UI. This
ticket builds exactly that experiment, nothing more.

The motivating questions, verbatim from the debate:

- Which idea ultimately caused a code change?
- Who/what challenged an idea (which actor, which decision)?
- Which failed implementation invalidated which prior assumption?

If a human can answer these from `provenance trace <idea-id>` output alone,
the experiment succeeds and a UI becomes worth considering later. If the
output is not meaningfully more useful than reading `events.jsonl` directly,
kill the idea.

A later, separate UI phase — explicitly not part of this ticket, and only
worth scoping if the above validates — has a real candidate to reuse:
`/Users/mini/e3d-pcap/client/src/components/PcapGraph.jsx` is a
`react-force-graph-2d/3d` renderer that is already ~90% domain-agnostic (a
generic `{id, label, color, totalBytes, linkCount, metaType}` node shape,
cleanly separated from its pcap-specific data-prep layer in
`client/src/pcap/*`, with no crypto/narrative coupling). The `e3d` repo's own
`GraphComponent.js` is not a good candidate — it has crypto-narrative
semantics (story-type coloring, `ETHERSCAN` config) threaded throughout.
Do not start on this until Experiment 1's acceptance criteria pass.

This is also the concrete next step already recorded as a decision on
`idea-3696511eaabe` (this repo's own ledger) from the prior Discovery Mode
debate: prefer structural, grep-resolvable provenance over any model-assigned
confidence score.

## Running This Spec

Run with `codex-spec-runner`'s default provider (`codex`), matching every
prior phase run in this repo (`.codex-spec-runner/manifest.tsv`):

```bash
codex-spec-runner docs/provenance-graph-experiment.md all
```

As of this writing, `gpt-5.5` (this runner's default high-tier Codex model)
has been deprecated on the API side — verified directly (`codex exec --model
gpt-5.5` returns a 404). Use `HIGH_MODEL=gpt-5.6-sol` (verified working)
until `codex-spec-runner`'s own defaults catch up:

```bash
HIGH_MODEL=gpt-5.6-sol codex-spec-runner docs/provenance-graph-experiment.md all
```

Phases 1-3 (Experiment 1 itself) already ran and validated successfully.
Phases 4-5 (fleet-mode parity and safe schema extensions, added after
validation) can be run alone:

```bash
HIGH_MODEL=gpt-5.6-sol MAX_PROVIDER_TOKENS_PER_PHASE=300000 \
  codex-spec-runner docs/provenance-graph-experiment.md all --from 4 --to 5
```

Phase 3 used 290k provider tokens against the default 120k ceiling — that's a
`codex-spec-runner` policy failure, not a code defect (the work still landed
and verified correct); raise the ceiling rather than be surprised by it
again.

## Goals

- Derive a domain-neutral provenance graph (nodes + edges) from e3d-pilot's
  existing `events.jsonl`/`idea.json` ledger, with zero new source of truth.
- Every edge must cite the exact ledger `event_id` it was derived from
  (grep-resolvable), never a heuristic or model-inferred link. Chronological
  proximity is never treated as a causal or invalidation claim — see Phase 3.
- Answer three concrete attribution questions from one idea's derived graph:
  what evidence/decisions influenced it, what code/PR it produced, and — only
  where the ledger records an explicit structural link — what it invalidated.
- Keep the export read-only, deterministic, and regenerable (same input
  produces byte-identical output, like `fleet train export`'s manifest
  hashing).

## Non-Goals

- No UI, no rendering, no 3D, no 2D. This ticket is data + CLI query output
  only. A future UI phase, if this experiment validates, is a separate
  ticket — see Overview for the `e3d-pcap` reuse candidate noted for later.
- No changes to `/Users/mini/e3d` or `/Users/mini/e3d-pcap` in this ticket.
- No fleet-mode support (`fleet provenance ...`). Single-repo only, matching
  how `ideas note/context/handoff` shipped repo-only first.
- No new persistent ledger, database, or storage layer. The provenance graph
  is a derived, regenerable export — `events.jsonl` remains the only
  append-only source of truth.
- No model-assigned confidence, novelty, or relevance scores anywhere in this
  export. Every edge's `confidence` field is the fixed value `"observed"` —
  it is a structural fact read off an existing event, never an inference.
- No cross-idea similarity/clustering/embedding. Nodes and edges come only
  from fields already present in `idea.json`/`events.jsonl`.
- No invalidation, causation, or "led to" claims inferred from timestamp
  proximity or ordering. A `failed` edge's nearest-in-time preceding
  decision/finding is surfaced as context only, explicitly labeled as
  unproven — never as "this is what the failure invalidated." That claim may
  only be made once the ledger records an explicit structural link (a future,
  separate change — e.g. an `invalidates_event_id`/`caused_by_event_id` field
  written at the time the relationship is actually known, not reconstructed
  afterward from this export).
- No node/edge type in this ticket claims more than its source event
  structurally establishes. `forge_sync` observes external PR/commit state
  (a passive poll — confirmed by reading `ideas_do_sync` in `bin/e3d-pilot`,
  which labels it "sync observed forge updates"); it is never treated as
  e3d-pilot having produced that commit.

## Existing Files (read first)

- `lib/ideas/ledger.sh` — event schema, `ideas_apply_event`'s per-event-type
  data shapes (this is the source data every node/edge derives from),
  `ideas_events_for_idea_json`.
- `bin/e3d-pilot` — `cmd_ideas`, `ideas_do_show`, `ideas_do_context`,
  `ideas_do_handoff` (existing precedent for read-only, JSON+human-rendered
  commands over the same ledger).
- `lib/training/export.sh` — precedent for a deterministic, hash-verified,
  regenerable derived export over the same event stream.
- `tests/phase28.sh` — precedent test structure (`make_repo`, `new_idea`
  helpers) to extend rather than duplicate.
- `README.md` — `ideas note/context/handoff` section, to extend with a
  matching `provenance` section.

## Shared Constraints

- All timestamps RFC 3339 UTC, matching the existing ledger.
- The export never writes to `.e3d-pilot/events.jsonl` or any `idea.json`
  snapshot. It only reads.
- Running the export twice against an unchanged ledger produces
  byte-identical output (same discipline as `fleet train export`'s
  manifest/file SHA-256 hashing).
- Node and edge IDs are deterministic functions of their source data (stable
  across reruns), not random or timestamp-based.
- Canonical serialization, required for byte-identical reruns to mean
  anything: every JSON object is written with `jq -cS` (sorted keys, matching
  every other export in this codebase). Lines are written nodes-then-edges;
  nodes sorted by `(type, node_id)`; edges sorted by `(timestamp, event_id,
  edge_id)`.
- Every edge's `source` field is a repo-relative path,
  `.e3d-pilot/events.jsonl#<event_id>` — never the absolute `--repo` path.
  Two clones of the same repo on different machines/paths must produce
  identical `provenance.jsonl` content.

## Phase 1 - Core Schema, Nodes, and Lifecycle-Decision Edges

<!-- runner:model=high -->
<!-- runner:read=lib/ideas/ledger.sh -->
<!-- runner:verify=bash tests/phase29.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=lib/provenance/graph.sh -->
<!-- pilot:touches=tests/phase29.sh -->

### Requirements

- Add `lib/provenance/graph.sh` implementing the derivation, and wire a new
  top-level command:

  ```text
  e3d-pilot provenance export --repo <path> [--out <file>]
  ```

- Node types, derived only from fields already present on `idea.json`/events:
  - `idea` — one per `idea_id`. `label` = title, `external_id` = `idea_id`.
  - `actor` — one per distinct `actor` string seen across that idea's
    events (e.g. `chris`, `claude-code`, `e3d-debate:opus,codex,devin,grok-build`).
  - `model` — one per distinct `candidate.provenance.model` value present on
    the idea's `idea_proposed` event, when set. **Ground truth check: as of
    this writing, no real discover/ideate candidate in this repo's own
    `.e3d-pilot/events.jsonl` populates `provenance.model`** (`bin/e3d-pilot`
    has zero references to constructing it; real candidates' `provenance`
    field is dedup-tracking — `{duplicate, raw_repos, source_candidate}` —
    not `{provider, model}`). Build this node type as specified (it costs
    nothing extra and may be populated by future ideate changes or synthetic
    fixtures), but do not assume it fires against today's real data, and do
    not add new instrumentation to discover/ideate to populate it — that
    would broaden this experiment beyond its scope.

- Edge relations for this phase, one edge per qualifying event, each
  carrying the exact source `event_id`:
  - `idea_proposed` -> edge `proposed_by` (actor -> idea) and, if a model is
    present, `proposed_by_model` (idea -> model) — named for exactly what the
    field establishes (which model proposed the candidate), not
    "selected," which would imply a ranking/decision that this field does not
    record.
  - `note_appended` -> edge `decision` (actor -> idea) if `kind == "decision"`,
    else `finding` (actor -> idea).
  - `implementation_approved`, `idea_rejected`, `changes_requested`,
    `merge_approved` -> edge `decided:<event>` (actor -> idea).

  Phase 2 adds `target_commit` nodes and the remaining edge types
  (`produced_commit`, `failed`, `reported_outcome`) — do not build those yet.

- Every node: `{node_id, type, label, external_id, first_seen, last_seen}`.
  Every edge: `{edge_id, from, to, relation, event_id, timestamp, source,
  confidence:"observed", data}` where `source` is a literal, grep-resolvable
  string of the form `.e3d-pilot/events.jsonl#<event_id>` (repo-relative, per
  Shared Constraints).
- `data` is `null` on every edge except `reported_outcome` (Phase 2), which
  alone carries the outcome's `window`/metrics. Do not attach the raw event's
  other fields to every edge "for completeness" — **found via dogfooding
  after implementation:** an earlier build of this attached the full
  `idea_proposed` event (including the entire `candidate` object — title,
  summary, scores, dedup_rationale, everything) to every `proposed_by` edge's
  `data` field. That alone bloated a 9-idea export from 23KB to 240KB and
  duplicates content the `idea` node and `idea.json` already carry — exactly
  the "index, not a second source of truth" violation this ticket exists to
  avoid. `data: null` is correct on every relation this phase defines.
- `target_commit` node IDs must not embed the absolute `--repo` path passed
  on the command line — **also found via dogfooding:** an earlier build
  produced node IDs like `target_commit:/Users/mini/e3d-pilot@<sha>`, which
  breaks the byte-identical-across-clones requirement in Shared Constraints
  (a different absolute path on a different machine produces a different
  node ID for the same real commit). When a target's `repo` field equals the
  canonical `--repo` value being exported, normalize it to the literal string
  `.` before building the node ID/label; otherwise fall back to the
  basename. (Phase 1 only ever sees the self-repo case; the fallback exists
  for defensiveness, not because this phase's scope produces cross-repo
  targets.)

- `provenance export` writes one JSONL file (default
  `<repo>/.e3d-pilot/provenance.jsonl`, override with `--out`) containing
  every node then every edge, each line tagged `{"kind":"node",...}` or
  `{"kind":"edge",...}`. It must be safe to regenerate at any time (no
  incremental/append state) and must never be read by any other e3d-pilot
  command as an input.

### Acceptance Criteria

- Running `provenance export` against a repo with a mix of proposed,
  rejected, and approved ideas produces a nodes+edges JSONL where every
  `event_id` referenced by an edge is present and identical in that repo's
  real `events.jsonl`.
- Every edge's `confidence` is exactly `"observed"`; no other value ever
  appears.
- Every edge's `data` is `null` except `reported_outcome` edges (Phase 2).
- No `node_id`, `label`, or `external_id` anywhere in the output contains an
  absolute filesystem path; the self-repo case renders as `.`.
- Running the export twice with no intervening ledger changes produces
  byte-identical output.
- The export never modifies `events.jsonl` or any `idea.json` file
  (checksum both before and after).
- `bash tests/phase29.sh` passes.

## Phase 2 - Implementation, Outcome, and Failure Edges

<!-- runner:model=high -->
<!-- runner:read=lib/provenance/graph.sh -->
<!-- runner:verify=bash tests/phase29.sh -->
<!-- pilot:touches=lib/provenance/graph.sh -->
<!-- pilot:touches=tests/phase29.sh -->

### Requirements

- Extend `lib/provenance/graph.sh` (do not change Phase 1's node/edge shapes
  or command surface) to add:
  - `target_commit` node — one per distinct `(repo, reviewed_head_sha|
    head_sha)` pair found in any event's `targets`/`observations` array
    (implementation approval, `forge_sync`, merge events).
  - `implementation_completed`, `merge_completed`, `merge_partially_completed`
    -> edge `produced_commit` (idea -> target_commit). These three events are
    e3d-pilot's own execute/publish/merge pipeline reporting its own
    completed action (confirmed via the `ideas_transition ... 
    implementation_completed`/merge call sites in `bin/e3d-pilot`) — the verb
    is earned.
  - `forge_sync` (with a resolvable target) -> edge `observed_commit` (idea ->
    target_commit), never `produced_commit`. `forge_sync` is a passive poll of
    external GitHub state (`ideas_do_sync`'s own note field says "sync
    observed forge updates") — it does not mean e3d-pilot produced anything,
    only that it later observed a target's PR/commit state.
  - `implementation_failed` -> edge `failed` (idea -> idea, self-referential
    marker event used by Phase 3 to locate the point of failure in the
    idea's own timeline).
  - `outcome_recorded` -> edge `reported_outcome` (idea -> idea, carrying the
    outcome's `window`/metrics in the edge's `data` field).

### Acceptance Criteria

- Running `provenance export` against a repo that also includes
  implemented, merged, and failed ideas produces the additional node/edge
  types above, with every `event_id` still resolving to a real event in
  `events.jsonl`.
- All of Phase 1's acceptance criteria still hold (idempotency, read-only,
  `confidence` always `"observed"`).
- `bash tests/phase29.sh` passes (extended to cover implementation/merge/
  outcome/failure fixtures, not just proposed/rejected/approved).

## Phase 3 - Trace Query and Dogfood Validation

<!-- runner:model=high -->
<!-- runner:read=lib/provenance/graph.sh -->
<!-- runner:verify=bash tests/phase30.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=lib/provenance/graph.sh -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=tests/phase30.sh -->

### Requirements

- Add:

  ```text
  e3d-pilot provenance trace --repo <path> <idea-id> [--json]
  ```

  It re-derives that one idea's nodes/edges directly from `events.jsonl`
  (does not require `provenance export` to have been run first) and renders,
  in chronological order:

  - **Proposed**: actor, model (if any), timestamp, event_id.
  - **Decisions**: every `decided:<event>`/`decision`-kind edge, actor,
    event_id, in order.
  - **Findings**: every `finding`-kind edge, actor, event_id, in order.
  - **Produced**: every `target_commit` node reached via `produced_commit`
    (repo, commit/PR, event_id) — e3d-pilot's own completed work.
  - **Observed**: every `target_commit` node reached only via
    `observed_commit` (repo, commit/PR, event_id) — external state Pilot
    later polled, kept visibly separate from Produced.
  - **Outcome**: every `reported_outcome` edge's data, if any.
  - **Failure** (only if a `failed` edge exists): the event_id of the
    failure, plus a `nearest_prior_context` field naming the single most
    recent decision or finding edge with a timestamp before it. This is
    presented strictly as temporal context, never as a claim — the rendered
    output must include the literal sentence "no invalidation is claimed;
    this is the nearest preceding entry in time only" next to it. No
    "invalidated" language appears anywhere in this command's output.

  `--json` emits the same structure as JSON instead of the rendered text
  form. Every section item includes its source `event_id` — no summary line
  may omit it. The JSON failure object's key is `nearest_prior_context`, not
  `invalidated` or any synonym implying a proven causal claim.

- Extend `README.md`'s `ideas note/context/handoff` section with a
  `provenance export`/`provenance trace` subsection, stating plainly that
  this is an experiment to validate before any visualization work, per the
  e3d-graph debate.

### Acceptance Criteria

- Add `tests/phase30.sh` covering: a rejected idea's trace shows the
  rejection decision and actor; an implemented idea's trace shows its
  produced commit/PR under **Produced**, not **Observed**; an idea with a
  recorded `implementation_failed` shows a Failure section whose
  `nearest_prior_context` names the correct preceding decision/finding by
  event_id and whose rendered text never contains the word "invalidat*" in
  any form; `--json` output round-trips through `jq` and contains an
  `event_id` on every item in every section.
- Dogfood check — three real ideas already in this repo's own
  `.e3d-pilot/events.jsonl`, one per motivating question, not synthetic
  fixtures:
  - **Challenged**: `idea-3696511eaabe` (shared-cognition/Discovery Mode) —
    confirm by hand that Decisions/Findings match its six real notes (three
    decisions, three findings).
  - **Caused a code change**: `idea-b1644c7c0f66` ("Fleet ops: live instance
    health signals (part 1 of 2)", real merged PR #1) — confirm Produced
    shows the actual merged commit/PR.
  - **Failure**: `idea-0ab340a4b78c` ("Fleet ops: Discord engagement signal
    (part 2 of 3)") — this idea has both a real `implementation_failed` and a
    later `implementation_completed`; confirm the Failure section's
    `nearest_prior_context` is accurate and that Produced still correctly
    shows the eventual successful commit.
  - For each: a human answers, in a `note` recorded back onto that idea via
    `ideas note`, "did `provenance trace` let me understand what happened
    faster and more accurately than manually reading `events.jsonl`, yes or
    no" — this is the actual product experiment, not just a schema
    correctness check.
- `bash tests/phase30.sh` passes.
- Full existing suite (`bash tests/phase*.sh`, all files) still passes.

---

Experiment 1 (Phases 1-3) validated: `provenance trace` beat manual ledger
reading on all three real dogfood ideas, and two real bugs (candidate-data
bloat on `proposed_by` edges, absolute-path leakage in `target_commit` node
IDs) were found by actually running it against real data and fixed. Phases 4
and 5 below extend the same tool, deliberately narrow: fleet-mode parity
(the fleet's own idea ledger currently has zero provenance support at all)
plus two additions chosen specifically because they don't reopen any of the
Non-Goals above — no GitHub PR comment/CI polling, no file/diff-level detail,
no heuristic-inferred idea-to-idea links, no conversation transcripts. Those
four remain deliberately out of scope; each would need its own explicit
decision (new instrumentation, unbounded-size risk, or real privacy
exposure), not a default "sure, why not."

## Phase 4 - Fleet-Mode Parity

<!-- runner:model=high -->
<!-- runner:read=lib/provenance/graph.sh -->
<!-- runner:verify=bash tests/phase29.sh tests/phase30.sh tests/phase31.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=lib/provenance/graph.sh -->
<!-- pilot:touches=tests/phase31.sh -->

### Requirements

- Generalize `provenance_export_repo`/`provenance_trace_json`/
  `provenance_trace_render`/`provenance_trace_repo` in
  `lib/provenance/graph.sh` to take a `kind` (`repo`|`fleet`) parameter, the
  same way every function in `lib/ideas/ledger.sh` already does
  (`ideas_events_file "$kind" "$canonical"`, etc.). This must be a pure
  refactor for the `repo` case — existing repo-mode output is byte-identical
  before and after, verified by rerunning `tests/phase29.sh`/`phase30.sh`
  unchanged.
- Wire new subcommands, mirroring exactly how `fleet ideas` mirrors `ideas`
  today:

  ```text
  e3d-pilot fleet provenance export <fleet.json> [--out <file>]
  e3d-pilot fleet provenance trace <fleet.json> <idea-id> [--json]
  ```

- Portability for the fleet case: a fleet workspace has no single "self
  repo" the way a single-repo export does (it's a directory of member
  repos, not one repo). `normalize_repo` must never emit `.` for fleet-mode
  exports — every target repo path normalizes to its basename, always, with
  no self-repo special case. Repo-mode's `.`-for-self behavior (Phase 1) is
  unchanged.
- Default fleet output path: `<fleet-workspace>/.e3d-pilot-fleet/provenance.jsonl`,
  matching the repo-mode default's shape (`<repo>/.e3d-pilot/provenance.jsonl`).
  Same read-only, regenerable, never-overwrite-the-ledger guarantees as
  Phase 1.

### Acceptance Criteria

- `tests/phase29.sh` and `tests/phase30.sh` still pass, completely unchanged,
  proving the refactor didn't alter repo-mode behavior.
- Add `tests/phase31.sh`: build a fleet fixture (2+ member repos, at least
  one proposed, one approved, one rejected fleet idea) and verify
  `fleet provenance export`/`fleet provenance trace` produce the same
  node/edge shapes Phase 1-3 defined, with every `target_commit` node using
  a basename (never `.`, never an absolute path, never the literal fleet
  workspace path).
- `bash tests/phase29.sh tests/phase30.sh tests/phase31.sh` all pass.
- Full existing suite still passes.

## Phase 5 - Proposed-Repo Edges and Debate Evidence Links

<!-- runner:model=high -->
<!-- runner:read=lib/provenance/graph.sh -->
<!-- runner:verify=bash tests/phase29.sh tests/phase30.sh tests/phase31.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=lib/provenance/graph.sh -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=tests/phase31.sh -->

### Requirements

- **Proposed-repo edges** (fleet-kind exports only — repo-mode ideas' own
  `.repos` field carries no information beyond the one repo already being
  exported, so skip this entirely when `kind == repo`):
  - New node type `repo` — one per distinct, basename-normalized repo string
    appearing in a fleet idea's `.candidate.repos` array at `idea_proposed`
    time. `node_id: "repo:" + <basename>`.
  - New edge `proposes_repo` (idea -> repo), one per entry in `.repos`,
    sourced from the same `idea_proposed` event as `proposed_by` — this
    records *intent* at proposal time, distinct from `produced_commit`/
    `observed_commit`, which record what actually happened later at
    approval/completion time. Do not conflate the two.
- **Debate/evidence links** (repo-mode only, matching where `ideas note`
  already exists — do not add fleet-mode `note` support here, that stays
  out of scope):
  - Add an optional `--evidence <path-or-url>` flag to `ideas note`,
    stored as an additional `evidence_ref` field on the `note_appended`
    event (a single string, not a file's contents — this must never read
    or embed the referenced file/URL, only record the pointer, exactly like
    every other `source`/`event_id` reference in this schema).
  - `provenance trace`'s Decisions/Findings sections render `evidence_ref=`
    after `event_id=` when present, omitted entirely when absent.
  - `provenance export`'s `decision`/`finding` edges get `data.evidence_ref`
    (only that one field, only when present) — this is the one addition to
    the "data is null except reported_outcome" rule from Phase 1, and it
    must stay a single bounded string, never the full note text or event.
- **Bloat guard, given what Phase 1 dogfooding just caught:** add an explicit
  regression test asserting no single line in any `provenance export` output
  (across repo-mode and fleet-mode) exceeds 2KB serialized. This is a
  permanent tripwire against the exact bug just fixed recurring under a
  different name.

### Acceptance Criteria

- A fleet idea proposing 3 repos produces exactly 3 `repo` nodes and 3
  `proposes_repo` edges, each citing the same `idea_proposed` `event_id` as
  `proposed_by`.
- A repo-mode idea's export contains zero `repo` nodes and zero
  `proposes_repo` edges, ever.
- `ideas note --evidence <ref>` round-trips through both `provenance trace`
  (rendered and `--json`) and `provenance export`'s edge `data.evidence_ref`;
  omitting `--evidence` produces no `evidence_ref` key anywhere (not `null`,
  absent).
- No exported line (any repo, any fleet, any test fixture) exceeds 2KB.
- `bash tests/phase29.sh tests/phase30.sh tests/phase31.sh` all pass.
- Full existing suite still passes.
- Extend `README.md`'s provenance section with the two new commands and the
  `--evidence` flag, one short paragraph, matching the existing section's
  register — no new top-level heading needed.

## Phase 6 - Graph Health Metrics (Implemented Directly, Not via codex-spec-runner)

Small and well-understood enough, after Phases 1-5, to implement directly
rather than round-trip through another codex-spec-runner phase. Documented
here for the same reason every other phase is: so the spec matches what's
actually built.

**What it adds:** `provenance_manifest_json` in `lib/provenance/graph.sh`,
called automatically by `provenance_export_repo` after every export (repo-
and fleet-mode both). Writes a sibling `<name>.manifest.json` next to
`<name>.jsonl` (default `provenance.manifest.json` next to
`provenance.jsonl`) with:

```json
{
  "nodes": 28, "edges": 59,
  "nodes_by_type": {"idea": 10, "actor": 8, "model": 1, "target_commit": 9},
  "edges_by_relation": {"proposed_by": 10, "finding": 14, "...": "..."},
  "orphan_nodes": 8,
  "max_degree": {"node_id": "idea:idea-b1644c7c0f66", "degree": 32},
  "graph_size_bytes": 26739,
  "source_events_count": 141,
  "graph_events_ratio": 0.617
}
```

`graph_events_ratio` is `(nodes + edges) / source_events_count` — how many
derived graph lines exist per source ledger event. This is the concrete
number that would have caught the 240KB bloat bug immediately (it moved from
~0.6 to several times higher once the full candidate object leaked onto
every `proposed_by` edge) — engineering telemetry, not product analytics,
exactly per the motivating ask.

Both `cmd_provenance` and `cmd_fleet_provenance`'s `export` subcommands now
print two lines (`provenance: exported <path>` / `provenance: manifest
<path>`) instead of one. The manifest is fully derived from
`provenance.jsonl` + `events.jsonl` — never a new source of truth, never read
by any other command as an input, safe to regenerate any time, subject to
the same never-overwrite-the-ledger guard as the main export.

**Verified:** `tests/phase32.sh` (5 cases — shape/counts, orphan/max_degree
accuracy, determinism + ledger-overwrite guard, fleet-mode `repo` node
counts, empty-ledger zeroed manifest). Real run against this repo's own
141-event ledger: 28 nodes, 59 edges, 8 orphans (7 unreached `target_commit`
snapshots + one `system-tracking` actor that only appears on an event type
this schema doesn't edge), `graph_events_ratio` 0.617. Real run against the
60-idea fleet ledger: `graph_events_ratio` **5.0** — the fleet's
`proposes_repo` fan-out (each idea names 2+ repos) dominates the graph size,
exactly the kind of ratio spike this metric exists to surface, confirmed on
the first real use.
