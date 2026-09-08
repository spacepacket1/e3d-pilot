# Feature Ticket: Graph Intelligence Queries (Experiment 2)

## Overview

Experiment 1 (`docs/provenance-graph-experiment.md`) answered "can a graph
faithfully reconstruct e3d-pilot provenance?" — yes, validated against three
real ideas, two real bugs found and fixed by actually running it, all six
phases shipped and regression-tested.

That is a different hypothesis from this one:

> Does the graph structure reveal patterns that are hard or impractical to
> get from the raw ledger?

This ticket is Experiment 2. It does not touch rendering, 3D, or any UI —
that question (Experiment 3) stays explicitly out of scope until this one
has an answer, exactly as Experiment 1 stayed out of Experiment 2's territory
until it had its own answer. The four-experiment progression this project is
following:

```text
Experiment 1: Can a graph faithfully reconstruct Pilot provenance?  -> yes (validated)
Experiment 2: Does graph structure reveal useful patterns?          -> this ticket
Experiment 3: Does visualization make those patterns easier to see? -> not started
Experiment 4: Can AI reason over the graph better than raw events?  -> not started
```

## Motivating Queries

Five were proposed. Four are viable against real data today; the fifth is
explicitly deferred, not built half-way:

1. **Idea -> outcome lineage** — which ideas actually led to commits, merges,
   and reported outcomes, and which didn't?
2. ~~Actor/model influence~~ — **deferred, not part of this ticket.** Verified
   during Experiment 1 (Phase 1's ground-truth check): zero real
   `idea_proposed` events in this repo's ledger populate
   `candidate.provenance.model`. This query would return no signal against
   real data regardless of how the graph is queried — it needs real
   ideate-stage model attribution first, which is a discover/ideate pipeline
   change, not a graph query. Revisit only after that instrumentation exists
   elsewhere.
3. **Decision reversals** — which ideas went through more than one
   `changes_requested` cycle before completion (or rejection)?
4. **Failure neighborhoods** — for every idea with a recorded
   `implementation_failed`, what decisions, findings, and eventual
   `produced_commit`/`observed_commit` surround it?
5. **Cross-repo propagation** — which fleet ideas ended up touching a
   different set of repos than the ones they originally proposed
   (`proposes_repo` vs. `produced_commit`/`observed_commit`)? Fleet-only —
   `proposes_repo` edges don't exist in repo-mode exports.

## Goals

- Answer, with real fleet/repo history, whether each of the four viable
  queries above surfaces something a human would find genuinely harder to
  get by reading `events.jsonl` or `idea.json` files directly.
- Implement each as a fixed, named, bounded query — not a general graph
  query language. If canned queries don't reveal signal, a query language
  wouldn't either; building one first would be solving a harder problem
  before validating the easier one.
- Reuse the exact node/edge derivation Experiment 1 already built and
  validated. No new event types, no new node/edge relations, no schema
  changes — this ticket asks questions of the existing graph, it doesn't
  grow it.

## Non-Goals

- No actor/model influence query (see above — explicitly deferred, not
  quietly dropped).
- No general-purpose graph query language or DSL.
- No UI, no rendering, no visualization of query results beyond text/JSON
  (same discipline as Experiment 1 — Experiment 3 is a separate, later
  decision).
- No new node/edge types, no new confidence semantics, no heuristic
  inference. Every query is a traversal/aggregation over edges that already
  exist with `confidence: "observed"` — it does not invent new
  relationships.
- No changes to `provenance export`'s on-disk output format or
  `provenance.manifest.json` (Phase 6 of Experiment 1). Queries read the same
  in-memory node/edge derivation `provenance_export_repo` already builds;
  they do not require `provenance export` to have been run first, matching
  how `provenance trace` already works.

## Existing Files (read first)

- `lib/provenance/graph.sh` — `provenance_export_repo` (the node/edge
  derivation to reuse), `provenance_trace_json` (precedent for re-deriving
  directly from `events.jsonl` without requiring a prior export),
  `provenance_manifest_json` (precedent for a read-only aggregation pass over
  already-derived nodes/edges).
- `docs/provenance-graph-experiment.md` — full schema reference: node types
  (`idea`, `actor`, `model`, `target_commit`, `repo`), edge relations
  (`proposed_by`, `decision`, `finding`, `decided:*`, `produced_commit`,
  `observed_commit`, `failed`, `reported_outcome`, `proposes_repo`), and the
  `normalize_repo`/portability rules.
- `bin/e3d-pilot` — `cmd_provenance`, `cmd_fleet_provenance` (existing
  `export`/`trace` subcommand wiring, to extend with `query`).
- `tests/phase29.sh`, `tests/phase31.sh`, `tests/phase32.sh` — precedent
  test structure and fixture helpers (`make_repo`, `new_idea`, `make_fleet`,
  `new_fleet_idea`) to extend rather than duplicate.

## Shared Constraints

- Every query result item must cite the real `event_id`(s) it derives from
  — same grep-resolvable discipline as Experiment 1. A query surfaces
  existing edges/nodes; it never adds new inferred facts.
- Queries work identically in repo-mode and fleet-mode (via `kind`), except
  cross-repo propagation, which is fleet-only and returns an empty result
  (not an error) in repo-mode, since `proposes_repo` edges never exist there.
- `--json` on every query emits the same structure as JSON instead of a
  rendered text form, matching `provenance trace`.
- Extract the shared node/edge-building jq logic out of
  `provenance_export_repo` into a reusable internal function
  (`provenance_build_graph`) that both the exporter and every query call,
  rather than duplicating derivation logic four more times. This must not
  change `provenance_export_repo`'s own output at all — verified by rerunning
  `tests/phase29.sh`/`phase31.sh`/`phase32.sh` unchanged.

## Phase 1 - Shared Graph Builder Refactor and Idea-Outcome Lineage

<!-- runner:model=high -->
<!-- runner:read=lib/provenance/graph.sh -->
<!-- runner:verify=bash tests/phase29.sh tests/phase30.sh tests/phase31.sh tests/phase32.sh tests/phase33.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=lib/provenance/graph.sh -->
<!-- pilot:touches=tests/phase33.sh -->

### Requirements

- Refactor: extract `provenance_build_graph(kind, workspace, events_file)` —
  returns the same `$nodes`/`$edges` JSONL stream `provenance_export_repo`
  currently builds inline. `provenance_export_repo` calls it and writes the
  file; nothing about its own output changes.
- Add:

  ```text
  e3d-pilot provenance query lineage --repo <path> [--json]
  e3d-pilot fleet provenance query lineage <fleet.json> [--json]
  ```

  For every `idea` node: `{idea_id, title, has_produced_commit: bool,
  has_observed_commit: bool, has_outcome: bool, status_summary}`, where
  `status_summary` is one of `no_activity` (proposed_by only),
  `in_progress` (has a decision but no produced/observed/outcome),
  `shipped` (has produced_commit), `shipped_externally` (has observed_commit
  but no produced_commit), or `rejected` (has a `decided:idea_rejected`
  edge). Every item cites the idea's own relevant edge `event_id`s in a
  `evidence` array (not just a boolean) — the whole point is these must be
  grep-resolvable, not an aggregate summary you have to trust blindly.

### Acceptance Criteria

- Add `tests/phase33.sh`: a fixture with one idea of each `status_summary`
  category; `provenance query lineage` classifies each correctly, every item
  has a non-empty `evidence` array of real event_ids.
- `tests/phase29.sh`/`phase30.sh`/`phase31.sh`/`phase32.sh` all still pass,
  completely unchanged, proving the refactor didn't alter existing behavior.
- `bash tests/phase29.sh tests/phase30.sh tests/phase31.sh tests/phase32.sh tests/phase33.sh` all pass.

## Phase 2 - Decision Reversals and Failure Neighborhoods

<!-- runner:model=high -->
<!-- runner:read=lib/provenance/graph.sh -->
<!-- runner:verify=bash tests/phase33.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=lib/provenance/graph.sh -->
<!-- pilot:touches=tests/phase33.sh -->

### Requirements

- Add:

  ```text
  e3d-pilot provenance query reversals --repo <path> [--json]
  e3d-pilot fleet provenance query reversals <fleet.json> [--json]
  ```

  For every idea with 2 or more `decided:changes_requested` edges: `{idea_id,
  title, changes_requested_count, event_ids: [...], final_status}`. Ideas
  with 0 or 1 `changes_requested` are omitted entirely — this is a
  "which ideas were contested" report, not a full listing.

- Add:

  ```text
  e3d-pilot provenance query failures --repo <path> [--json]
  e3d-pilot fleet provenance query failures <fleet.json> [--json]
  ```

  For every idea with a `failed` edge: reuse `provenance_trace_json`'s
  existing failure/`nearest_prior_context` logic (do not reimplement it),
  aggregated across every failed idea rather than one. Same "no invalidation
  claimed" discipline applies — this is a listing of failures and their
  nearest prior context, never a claim about what caused what.

### Acceptance Criteria

- Add to `tests/phase33.sh`: an idea with 3 `changes_requested` cycles shows
  up in `reversals` with the correct count; an idea with 0-1 does not appear
  at all. An idea with a real `implementation_failed` appears in `failures`
  with the same `nearest_prior_context` value `provenance trace` would
  produce for that same idea (cross-check against the existing trace logic,
  don't just assert a hardcoded expected value).
- `bash tests/phase33.sh` passes; full existing suite still passes.

## Phase 3 - Cross-Repo Propagation and Real-Data Evaluation

<!-- runner:model=high -->
<!-- runner:read=lib/provenance/graph.sh -->
<!-- runner:verify=bash tests/phase33.sh -->
<!-- pilot:touches=bin/e3d-pilot -->
<!-- pilot:touches=lib/provenance/graph.sh -->
<!-- pilot:touches=README.md -->
<!-- pilot:touches=tests/phase33.sh -->

### Requirements

- Add:

  ```text
  e3d-pilot fleet provenance query cross-repo <fleet.json> [--json]
  ```

  (`provenance query cross-repo --repo <path>` also exists for symmetry with
  every other query, but always returns an empty result in repo-mode — no
  error, since `proposes_repo` never exists there.)

  For every fleet idea: `{idea_id, title, proposed_repos: [...],
  actual_repos: [...], matches: bool}` where `actual_repos` comes from
  `produced_commit`/`observed_commit` target repos. Only include ideas that
  actually have at least one `produced_commit`/`observed_commit` edge — an
  idea that's still `proposed` has no "actual" to compare against yet, and
  showing every idea with an empty `actual_repos` would just be noise.

- **Real-data evaluation, not just tests.** Run all four queries against
  this repo's own real ledger and the real fleet ledger
  (`/Users/mini/e3d-fleet.json`). For each query, a human (not a model)
  answers, recorded as a `note` on the idea created for this experiment
  (mirroring how Experiment 1 recorded its own dogfood verdicts): "did this
  query surface something genuinely harder to get from the raw ledger, or
  did it just restate what a `grep`/`jq` one-liner over `events.jsonl` would
  have shown just as fast?" Be honest if a query is a bust — that's a valid,
  useful outcome, not a failure to hide.

### Acceptance Criteria

- Add to `tests/phase33.sh`: a fleet idea proposing 3 repos but only
  producing a commit in 1 of them shows `matches: false` with the correct
  `proposed_repos`/`actual_repos` sets; an idea where they match shows
  `matches: true`; a still-`proposed` idea is absent from the result
  entirely.
- All four real-data evaluation notes are recorded (one per query) with an
  honest yes/no/partial verdict, not a rubber-stamped "yes" for all four —
  if any come back "no signal," say so plainly in the note and in the
  synthesis at the end of this ticket's implementation.
- `bash tests/phase33.sh` passes; full existing suite still passes.
- Extend `README.md`'s provenance section with the `provenance query`
  subcommands, one short paragraph.

## What Happens After This Ticket

If most of the four queries come back "yes, genuinely useful, hard to get
from the raw ledger" — that's the actual signal that this stops being "a
provenance feature" and starts being something worth a name and a real
positioning decision (what the earlier debate called, informally, "E3D AI
Map"). That naming/positioning decision should wait for this ticket's real
verdicts, not precede them.

If most queries come back "no, not meaningfully better than a `jq` one-liner"
— that's also a legitimate, useful result. It would mean the value of this
whole effort was Experiment 1's provenance/trace primitive on its own, not a
"graph intelligence" layer on top of it, and Experiment 3/4 should not be
pursued.

Either way, do not start Experiment 3 (visualization) or Experiment 4 (AI
reasoning over the graph) until this ticket's real-data evaluation is done
and its verdicts are recorded.
