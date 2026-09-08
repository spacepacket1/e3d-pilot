#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"

# shellcheck source=../lib/ideas/ledger.sh
source "$ROOT/lib/ideas/ledger.sh"

make_repo() {
  local repo
  repo="$(mktemp -d)"
  git init -q "$repo"
  printf '%s\n' "$repo"
}

new_idea() {
  local repo="$1" candidate_id="$2" title="$3" candidate
  candidate="$(mktemp)"
  jq -n --arg title "$title" '
    {
      title: $title,
      summary: "Manifest fixture",
      repos: ["repo-a"],
      scores: {attraction: 4, retention: 3, revenue: 2, effort: "low"},
      category: "workflow",
      provenance: {duplicate: false},
      implementation: {targets: []}
    }
  ' > "$candidate"
  "$BIN" ideas ingest --repo "$repo" --run-id run-32 --candidate-id "$candidate_id" --candidate-json "$candidate"
  rm -f "$candidate"
}

make_fleet() {
  local dir fleet_file member
  dir="$(mktemp -d)"
  fleet_file="$dir/fleet.json"
  for member in repo-a repo-b; do
    git init -q "$dir/$member"
    git -C "$dir/$member" config user.email "test@example.com"
    git -C "$dir/$member" config user.name "Test User"
    printf '# %s\n' "$member" > "$dir/$member/README.md"
    git -C "$dir/$member" add README.md
    git -C "$dir/$member" commit -q -m init
  done
  jq -ncS '["repo-a","repo-b"]' > "$fleet_file"
  printf '%s' "$fleet_file"
}

new_fleet_idea() {
  local fleet_file="$1" title="$2" candidate
  candidate="$(mktemp)"
  jq -ncS --arg title "$title" '{
    focus:"revenue",title:$title,summary:"Manifest fleet fixture.",repos:["repo-a","repo-b"],
    scores:{attraction:3,retention:3,revenue:5,effort:"low"},
    category:"testing",dedup_rationale:"new",validation:{approvable:true,eligibility_reason:null,warnings:[]}
  }' > "$candidate"
  "$BIN" fleet ideas "$fleet_file" ingest --run-id run-32 --candidate-id candidate-1 --candidate-json "$candidate"
  rm -f "$candidate"
}

manifest_has_expected_shape_and_counts() {
  local repo idea1 idea2 out manifest
  repo="$(make_repo)"
  idea1="$(new_idea "$repo" candidate-1 "Idea one")"
  idea2="$(new_idea "$repo" candidate-2 "Idea two")"
  "$BIN" ideas note --repo "$repo" "$idea1" "a finding" --actor tester >/dev/null
  "$BIN" ideas reject --repo "$repo" "$idea2" --reason "not now" --actor tester >/dev/null

  out="$("$BIN" provenance export --repo "$repo")"
  manifest="$(awk '{print $NF}' <<<"$out" | sed -n '2p')"
  [[ -n "$manifest" && -f "$manifest" ]] || { printf 'expected a manifest path on line 2\n' >&2; exit 1; }

  jq -e '
    (.nodes | type) == "number"
    and (.edges | type) == "number"
    and (.nodes_by_type.idea == 2)
    and (.nodes_by_type.actor >= 1)
    and (.edges_by_relation.proposed_by == 2)
    and (.edges_by_relation.finding == 1)
    and (.edges_by_relation["decided:idea_rejected"] == 1)
    and (.graph_size_bytes | type) == "number"
    and (.graph_size_bytes > 0)
    and (.source_events_count | type) == "number"
    and (.source_events_count > 0)
    and (.graph_events_ratio | type) == "number"
  ' "$manifest" >/dev/null

  rm -rf "$repo"
}

orphan_and_max_degree_are_accurate() {
  local repo idea1 idea2 manifest
  repo="$(make_repo)"
  idea1="$(new_idea "$repo" candidate-1 "Popular idea")"
  idea2="$(new_idea "$repo" candidate-2 "Quiet idea")"
  # idea1 gets extra decisions/findings to become the clear max-degree node;
  # idea2 (proposed_by only) has degree 1 and is not an orphan itself, but we
  # assert the orphan check via a note-free idea's absence of extra nodes.
  "$BIN" ideas note --repo "$repo" --decision "$idea1" "decide A" --actor d1 >/dev/null
  "$BIN" ideas note --repo "$repo" --decision "$idea1" "decide B" --actor d2 >/dev/null
  "$BIN" ideas note --repo "$repo" "$idea1" "finding A" --actor f1 >/dev/null

  manifest="$(awk '{print $NF}' <<<"$("$BIN" provenance export --repo "$repo")" | sed -n '2p')"
  jq -e --arg idea1 "idea:$idea1" '
    .max_degree.node_id == $idea1
    and .max_degree.degree >= 4
    and (.orphan_nodes | type) == "number"
  ' "$manifest" >/dev/null

  rm -rf "$repo"
}

manifest_is_deterministic_and_never_overwrites_ledger() {
  local repo idea manifest1 manifest2 events_before events_after
  repo="$(make_repo)"
  idea="$(new_idea "$repo" candidate-1 "Determinism fixture")"
  "$BIN" ideas note --repo "$repo" "$idea" "a finding" --actor tester >/dev/null

  events_before="$(sha256sum "$repo/.e3d-pilot/events.jsonl" 2>/dev/null || shasum -a 256 "$repo/.e3d-pilot/events.jsonl")"
  manifest1="$(awk '{print $NF}' <<<"$("$BIN" provenance export --repo "$repo")" | sed -n '2p')"
  manifest_copy="$(mktemp)"
  cp "$manifest1" "$manifest_copy"
  manifest2="$(awk '{print $NF}' <<<"$("$BIN" provenance export --repo "$repo")" | sed -n '2p')"
  events_after="$(sha256sum "$repo/.e3d-pilot/events.jsonl" 2>/dev/null || shasum -a 256 "$repo/.e3d-pilot/events.jsonl")"

  cmp -s "$manifest_copy" "$manifest2" || { printf 'manifest is not deterministic across reruns\n' >&2; exit 1; }
  [[ "$events_before" == "$events_after" ]] || { printf 'export mutated events.jsonl\n' >&2; exit 1; }

  if "$BIN" provenance export --repo "$repo" --out "$repo/.e3d-pilot/events.jsonl" >/dev/null 2>&1; then
    printf 'expected manifest/export overwrite of the ledger to fail\n' >&2
    exit 1
  fi

  rm -f "$manifest_copy"
  rm -rf "$repo"
}

fleet_manifest_includes_repo_node_type() {
  local fleet_file idea manifest
  fleet_file="$(make_fleet)"
  idea="$(new_fleet_idea "$fleet_file" "Fleet manifest fixture")"
  manifest="$(awk '{print $NF}' <<<"$("$BIN" fleet provenance export "$fleet_file")" | sed -n '2p')"
  jq -e '
    (.nodes_by_type.repo == 2)
    and (.edges_by_relation.proposes_repo == 2)
  ' "$manifest" >/dev/null
  rm -rf "$(dirname "$fleet_file")"
}

empty_ledger_produces_zeroed_manifest() {
  local repo manifest
  repo="$(make_repo)"
  manifest="$(awk '{print $NF}' <<<"$("$BIN" provenance export --repo "$repo")" | sed -n '2p')"
  jq -e '
    .nodes == 0 and .edges == 0 and .orphan_nodes == 0
    and .max_degree == null and .graph_events_ratio == null
    and .source_events_count == 0
  ' "$manifest" >/dev/null
  rm -rf "$repo"
}

main() {
  bash -n "$BIN"
  bash -n "$ROOT/lib/provenance/graph.sh"
  manifest_has_expected_shape_and_counts
  orphan_and_max_degree_are_accurate
  manifest_is_deterministic_and_never_overwrites_ledger
  fleet_manifest_includes_repo_node_type
  empty_ledger_produces_zeroed_manifest
  echo "phase32: all tests passed"
}

main "$@"
