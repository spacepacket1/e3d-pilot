#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"

# shellcheck source=../lib/ideas/ledger.sh
source "$ROOT/lib/ideas/ledger.sh"

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

snapshots_digest() {
  local root="$1" file
  while IFS= read -r file; do
    printf '%s  %s\n' "$(sha256_file "$file")" "$file"
  done < <(find "$root" -name idea.json -type f | sort)
}

assert_export_lines_bounded() {
  local out="$1"
  LC_ALL=C awk 'length($0) > 2048 { exit 1 }' "$out"
}

make_repo() {
  local repo
  repo="$(mktemp -d)"
  git init -q "$repo"
  printf '%s\n' "$repo"
}

new_idea() {
  local repo="$1" candidate_id="$2" title="$3" model="${4:-}" candidate
  candidate="$(mktemp)"
  jq -n --arg title "$title" --arg model "$model" '
    {
      title: $title,
      summary: "Provenance graph fixture",
      repos: ["repo-a"],
      scores: {attraction: 4, retention: 3, revenue: 2, effort: "low"},
      category: "workflow",
      provenance: (if $model == "" then {duplicate:false} else {provider:"fixture", model:$model} end),
      implementation: {targets: []}
    }
  ' > "$candidate"
  "$BIN" ideas ingest --repo "$repo" --run-id run-29 --candidate-id "$candidate_id" --candidate-json "$candidate"
  rm -f "$candidate"
}

append_custom_event() {
  local repo="$1" idea_id="$2" event="$3" extra_json="$4" extra
  extra="$(mktemp)"
  printf '%s\n' "$extra_json" > "$extra"
  ideas_append_custom_event repo "$repo" "$idea_id" "$event" fixture "$event fixture" "$extra"
  rm -f "$extra"
}

complete_implementation() {
  local repo="$1" idea_id="$2" target_json="$3" targets outcome
  targets="$(mktemp)"
  outcome="$(mktemp)"
  printf '%s\n' "$target_json" > "$targets"
  "$BIN" ideas transition --repo "$repo" "$idea_id" implementation_approved --actor approver --targets-json "$targets" >/dev/null
  "$BIN" ideas transition --repo "$repo" "$idea_id" implementation_started --actor builder >/dev/null
  jq -ncS --arg idea "$idea_id" --argjson target "$target_json" \
    '{type:"implementation",idea_id:$idea,status:"succeeded",targets:[$target]}' > "$outcome"
  ideas_transition repo "$repo" "$idea_id" implementation_completed builder "implementation completed" "" "" "$outcome" >/dev/null
  rm -f "$targets" "$outcome"
}

complete_merge() {
  local repo="$1" idea_id="$2" target_json="$3" event="$4" targets outcome status
  targets="$(mktemp)"
  outcome="$(mktemp)"
  printf '%s\n' "$target_json" | jq -s -cS 'map({repo,pr_url,head_sha})' > "$targets"
  "$BIN" ideas transition --repo "$repo" "$idea_id" merge_approved --actor merger --targets-json "$targets" >/dev/null
  [[ "$event" == "merge_completed" ]] && status="succeeded" || status="partial"
  jq -ncS --arg idea "$idea_id" --arg status "$status" --argjson target "$target_json" \
    '{type:"merge",idea_id:$idea,status:$status,targets:[{repo:$target.repo,pr_url:$target.pr_url,head_sha:$target.final_pr_head_sha,status:"merged",merge_sha:"merge-sha"}]}' > "$outcome"
  ideas_transition repo "$repo" "$idea_id" "$event" merger "merge $status" "" "" "$outcome" >/dev/null
  rm -f "$targets" "$outcome"
}

assert_graph() {
  local repo="$1" out="$2" event_count edge_count
  jq -e -s 'all(.[]; .kind == "node" or .kind == "edge")' "$out" >/dev/null
  jq -e -s 'all(.[] | select(.kind == "edge"); .confidence == "observed")' "$out" >/dev/null
  jq -e -s '
    [ .[] | select(.kind == "node") | .type ] as $types
    | ($types | index("idea")) != null
      and ($types | index("actor")) != null
      and ($types | index("model")) != null
      and ($types | index("target_commit")) != null
  ' "$out" >/dev/null
  jq -e -s '
    [ .[] | select(.kind == "edge") | .relation ] as $relations
    | ["proposed_by", "proposed_by_model", "finding", "decision",
       "decided:implementation_approved", "decided:idea_rejected",
       "decided:changes_requested", "decided:merge_approved",
       "produced_commit", "observed_commit", "failed", "reported_outcome"]
      | all(.[]; $relations | index(.) != null)
  ' "$out" >/dev/null
  jq -e -s 'all(.[] | select(.kind == "edge"); .source == (".e3d-pilot/events.jsonl#" + .event_id))' "$out" >/dev/null
  jq -e -s 'all(.[] | select(.kind == "node"); has("node_id") and has("type") and has("label") and has("external_id") and has("first_seen") and has("last_seen"))' "$out" >/dev/null
  jq -e -s 'all(.[] | select(.kind == "edge"); has("edge_id") and has("from") and has("to") and has("relation") and has("event_id") and has("timestamp") and has("source") and has("confidence") and has("data"))' "$out" >/dev/null
  jq -e -s '([.[] | .node_id? // .edge_id] | length) == ([.[] | .node_id? // .edge_id] | unique | length)' "$out" >/dev/null

  jq -e -s '
    ([.[] | select(.kind == "node" and .type == "target_commit")] | length) == 3
    and ([.[] | select(.kind == "edge" and .relation == "produced_commit")] | length) == 4
    and ([.[] | select(.kind == "edge" and .relation == "observed_commit")] | length) == 1
    and ([.[] | select(.kind == "edge" and .relation == "failed" and .from == .to)] | length) == 1
    and ([.[] | select(.kind == "edge" and .relation == "reported_outcome"
                      and .from == .to and .data.outcome.window == "7d"
                      and .data.outcome.metrics[0].key == "retained"
                      and .data.outcome.metrics[0].value == true)] | length) == 1
    and all(.[] | select(.kind == "edge" and (.relation == "produced_commit" or .relation == "observed_commit"));
            .from | startswith("idea:"))
    and all(.[] | select(.kind == "edge" and (.relation == "produced_commit" or .relation == "observed_commit"));
            .to | startswith("target_commit:"))
  ' "$out" >/dev/null

  # A passive forge poll must never be labeled as production.
  jq -e -s '
    ([.[] | select(.kind == "edge" and .relation == "observed_commit") | .event_id]) as $sync_ids
    | all(.[] | select(.kind == "edge" and .relation == "produced_commit"); .event_id as $id | $sync_ids | index($id) == null)
  ' "$out" >/dev/null

  event_count="$(jq -s 'length' "$repo/.e3d-pilot/events.jsonl")"
  edge_count="$(jq -s '[.[] | select(.kind == "edge")] | length' "$out")"
  [[ "$edge_count" -gt 0 && "$event_count" -gt 0 ]]
  jq -s --slurpfile graph "$out" '
    ([.[].event_id] | unique) as $event_ids
    | all($graph[] | select(.kind == "edge"); . as $edge | $event_ids | index($edge.event_id) != null)
  ' "$repo/.e3d-pilot/events.jsonl" | grep -qx true
}

export_is_complete_deterministic_and_read_only() {
  local repo proposed rejected lifecycle implemented partial failed out copy events_before events_after snapshots_before snapshots_after
  local implemented_target partial_target failure_outcome sync_extra outcome_extra
  repo="$(make_repo)"
  proposed="$(new_idea "$repo" proposed "Proposed by a model" model-29)"
  rejected="$(new_idea "$repo" rejected "Rejected idea")"
  lifecycle="$(new_idea "$repo" lifecycle "Approved lifecycle idea")"
  implemented="$(new_idea "$repo" implemented "Implemented and merged idea")"
  partial="$(new_idea "$repo" partial "Partially merged idea")"
  failed="$(new_idea "$repo" failed "Failed implementation idea")"

  "$BIN" ideas note --repo "$repo" "$proposed" "observed evidence" --actor researcher --evidence "docs/research.md#result" >/dev/null
  "$BIN" ideas note --repo "$repo" --decision "$proposed" "keep scope narrow" --actor reviewer >/dev/null
  "$BIN" ideas transition --repo "$repo" "$rejected" idea_rejected --actor rejector >/dev/null
  "$BIN" ideas transition --repo "$repo" "$lifecycle" implementation_approved --actor approver >/dev/null
  "$BIN" ideas transition --repo "$repo" "$lifecycle" implementation_started --actor builder >/dev/null
  "$BIN" ideas transition --repo "$repo" "$lifecycle" implementation_completed --actor builder >/dev/null
  "$BIN" ideas transition --repo "$repo" "$lifecycle" changes_requested --actor reviewer >/dev/null
  "$BIN" ideas transition --repo "$repo" "$lifecycle" merge_approved --actor merger >/dev/null

  implemented_target="$(jq -ncS '{repo:"repo-a",pr_url:"https://example.test/a/1",reviewed_head_sha:"sha-a",final_pr_head_sha:"sha-a"}')"
  complete_implementation "$repo" "$implemented" "$implemented_target"
  sync_extra="$(jq -ncS '{observations:[{repo:"repo-a",pr_url:"https://example.test/a/1",head_sha:"sha-observed"}]}')"
  append_custom_event "$repo" "$implemented" forge_sync "$sync_extra"
  outcome_extra="$(jq -ncS '{outcome:{type:"metrics",window:"7d",metrics:[{key:"retained",type:"boolean",value:true,window:"7d",observed_at:"2026-01-01T00:00:00Z"}]}}')"
  append_custom_event "$repo" "$implemented" outcome_recorded "$outcome_extra"
  complete_merge "$repo" "$implemented" "$implemented_target" merge_completed

  partial_target="$(jq -ncS '{repo:"repo-b",pr_url:"https://example.test/b/2",head_sha:"sha-b",final_pr_head_sha:"sha-b"}')"
  complete_implementation "$repo" "$partial" "$partial_target"
  complete_merge "$repo" "$partial" "$partial_target" merge_partially_completed

  "$BIN" ideas transition --repo "$repo" "$failed" implementation_approved --actor approver >/dev/null
  "$BIN" ideas transition --repo "$repo" "$failed" implementation_started --actor builder >/dev/null
  failure_outcome="$(mktemp)"
  jq -ncS --arg idea "$failed" '{type:"implementation",idea_id:$idea,status:"failed",targets:[],failure_reason:"fixture failure"}' > "$failure_outcome"
  ideas_transition repo "$repo" "$failed" implementation_failed builder "implementation failed" "" "" "$failure_outcome" >/dev/null
  rm -f "$failure_outcome"

  events_before="$(sha256_file "$repo/.e3d-pilot/events.jsonl")"
  snapshots_before="$(snapshots_digest "$repo/.e3d-pilot/ideas")"
  out="$repo/export/provenance.jsonl"
  "$BIN" provenance export --repo "$repo" --out "$out" >/dev/null
  assert_graph "$repo" "$out"
  assert_export_lines_bounded "$out"
  jq -e -s '
    ([.[] | select(.kind == "node" and .type == "repo")] | length) == 0
    and ([.[] | select(.kind == "edge" and .relation == "proposes_repo")] | length) == 0
    and ([.[] | select(.kind == "edge" and .relation == "finding"
                      and .data == {evidence_ref:"docs/research.md#result"})] | length) == 1
    and all(.[] | select(.kind == "edge" and .relation == "decision");
            .data == null and (has("evidence_ref") | not))
  ' "$out" >/dev/null
  jq -e '
    (select(.event == "note_appended" and .kind == "finding")
     | .evidence_ref == "docs/research.md#result"),
    (select(.event == "note_appended" and .kind == "decision")
     | has("evidence_ref") | not)
  ' "$repo/.e3d-pilot/events.jsonl" >/dev/null
  copy="$repo/export/first.jsonl"
  cp "$out" "$copy"
  "$BIN" provenance export --repo "$repo" --out "$out" >/dev/null
  cmp -s "$copy" "$out"

  events_after="$(sha256_file "$repo/.e3d-pilot/events.jsonl")"
  snapshots_after="$(snapshots_digest "$repo/.e3d-pilot/ideas")"
  [[ "$events_before" == "$events_after" ]]
  [[ "$snapshots_before" == "$snapshots_after" ]]

  "$BIN" provenance export --repo "$repo" >/dev/null
  [[ -f "$repo/.e3d-pilot/provenance.jsonl" ]]
  cmp -s "$out" "$repo/.e3d-pilot/provenance.jsonl"
  rm -rf "$repo"
}

oversized_evidence_is_rejected() {
  local repo idea oversized before after
  repo="$(make_repo)"
  idea="$(new_idea "$repo" evidence-limit "Evidence limit")"
  oversized="$(printf '%1025s' x)"
  before="$(wc -l < "$repo/.e3d-pilot/events.jsonl")"
  if "$BIN" ideas note --repo "$repo" "$idea" "bounded pointer" --evidence "$oversized" >/dev/null 2>&1; then
    printf 'expected oversized evidence reference to fail\n' >&2
    exit 1
  fi
  after="$(wc -l < "$repo/.e3d-pilot/events.jsonl")"
  [[ "$before" == "$after" ]]
  rm -rf "$repo"
}

empty_repo_and_ledger_overwrite_guard() {
  local repo out
  repo="$(make_repo)"
  out="$repo/empty.jsonl"
  "$BIN" provenance export --repo "$repo" --out "$out" >/dev/null
  [[ -f "$out" && ! -s "$out" ]]

  new_idea "$repo" guarded "Guarded ledger" >/dev/null
  if "$BIN" provenance export --repo "$repo" --out "$repo/.e3d-pilot/events.jsonl" >/dev/null 2>&1; then
    printf 'expected ledger overwrite attempt to fail\n' >&2
    exit 1
  fi
  rm -rf "$repo"
}

main() {
  bash -n "$BIN"
  bash -n "$ROOT/lib/provenance/graph.sh"
  export_is_complete_deterministic_and_read_only
  empty_repo_and_ledger_overwrite_guard
  oversized_evidence_is_rejected
  echo "phase29: all tests passed"
}

main "$@"
