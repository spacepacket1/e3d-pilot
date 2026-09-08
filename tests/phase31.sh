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

make_fleet() {
  local workspace member
  workspace="$(mktemp -d)"
  for member in repo-a repo-b repo-c; do
    git init -q "$workspace/$member"
    git -C "$workspace/$member" config user.email fixture@example.test
    git -C "$workspace/$member" config user.name Fixture
    printf '# %s\n' "$member" > "$workspace/$member/README.md"
    git -C "$workspace/$member" add README.md
    git -C "$workspace/$member" commit -q -m init
  done
  jq -ncS '["repo-a","repo-b"]' > "$workspace/fleet.json"
  printf '%s' "$workspace/fleet.json"
}

new_fleet_idea() {
  local fleet_file="$1" candidate_id="$2" title="$3" workspace candidate idea_id
  workspace="$(dirname "$fleet_file")"
  candidate="$(mktemp)"
  jq -ncS --arg title "$title" --arg repo_a "$workspace/repo-a" --arg repo_b "$workspace/repo-b" --arg repo_c "$workspace/repo-c" '{
    title:$title,
    summary:"Fleet provenance fixture",
    repos:[$repo_a,$repo_b,$repo_c],
    scores:{attraction:4,retention:3,revenue:2,effort:"low"},
    category:"workflow",
    provenance:{provider:"fixture",model:"fleet-model"},
    validation:{approvable:true,eligibility_reason:null,warnings:[]},
    implementation:{targets:[]}
  }' > "$candidate"
  idea_id="$("$BIN" fleet ideas "$fleet_file" ingest --run-id run-31 --candidate-id "$candidate_id" --candidate-json "$candidate")"
  rm -f "$candidate"
  printf '%s' "$idea_id"
}

complete_fleet_implementation() {
  local fleet_file="$1" idea_id="$2" workspace outcome
  workspace="$(dirname "$fleet_file")"
  "$BIN" fleet ideas "$fleet_file" approve "$idea_id" --actor approver >/dev/null
  "$BIN" fleet ideas "$fleet_file" transition "$idea_id" implementation_started --actor builder >/dev/null
  outcome="$(mktemp)"
  jq -ncS --arg idea "$idea_id" --arg repo_a "$workspace/repo-a" --arg repo_b "$workspace/repo-b" '{
    type:"implementation",idea_id:$idea,status:"succeeded",targets:[
      {repo:$repo_a,pr_url:"https://example.test/a/31",final_pr_head_sha:"sha-a"},
      {repo:$repo_b,pr_url:"https://example.test/b/31",reviewed_head_sha:"sha-b"}
    ]
  }' > "$outcome"
  ideas_transition fleet "$workspace" "$idea_id" implementation_completed builder "completed" "" "" "$outcome" >/dev/null
  rm -f "$outcome"
}

fleet_export_and_trace_have_parity() {
  local fleet_file workspace proposed approved rejected implemented out first trace
  local events_before events_after snapshots_before snapshots_after
  fleet_file="$(make_fleet)"
  workspace="$(dirname "$fleet_file")"
  proposed="$(new_fleet_idea "$fleet_file" proposed "Proposed fleet idea")"
  approved="$(new_fleet_idea "$fleet_file" approved "Approved fleet idea")"
  rejected="$(new_fleet_idea "$fleet_file" rejected "Rejected fleet idea")"
  implemented="$(new_fleet_idea "$fleet_file" implemented "Implemented fleet idea")"
  "$BIN" fleet ideas "$fleet_file" approve "$approved" --actor approver >/dev/null
  "$BIN" fleet ideas "$fleet_file" reject "$rejected" --reason "not now" --actor rejector >/dev/null
  complete_fleet_implementation "$fleet_file" "$implemented"

  events_before="$(sha256_file "$workspace/.e3d-pilot-fleet/events.jsonl")"
  snapshots_before="$(snapshots_digest "$workspace/.e3d-pilot-fleet/ideas")"
  out="$workspace/custom/provenance.jsonl"
  "$BIN" fleet provenance export "$fleet_file" --out "$out" >/dev/null
  assert_export_lines_bounded "$out"
  first="$workspace/first.jsonl"
  cp "$out" "$first"
  "$BIN" fleet provenance export "$fleet_file" --out "$out" >/dev/null
  cmp -s "$first" "$out"
  events_after="$(sha256_file "$workspace/.e3d-pilot-fleet/events.jsonl")"
  snapshots_after="$(snapshots_digest "$workspace/.e3d-pilot-fleet/ideas")"
  [[ "$events_before" == "$events_after" ]]
  [[ "$snapshots_before" == "$snapshots_after" ]]

  jq -e -s --arg workspace "$workspace" '
    ([.[] | select(.kind == "node" and .type == "idea")] | length) == 4
    and ([.[] | select(.kind == "node" and .type == "repo")] | length) == 3
    and ([.[] | select(.kind == "node" and .type == "repo") | .external_id] | sort == ["repo-a","repo-b","repo-c"])
    and ([.[] | select(.kind == "node" and .type == "target_commit")] | length) == 2
    and ([.[] | select(.kind == "node" and .type == "target_commit") | .external_id] | sort == ["repo-a@sha-a","repo-b@sha-b"])
    and all(.[] | select(.kind == "node" and .type == "target_commit");
      (.node_id + .label + .external_id) as $values
      | ($values | contains($workspace) | not)
        and ($values | startswith("target_commit:.") | not)
        and ($values | contains("/repo-") | not))
    and ([.[] | select(.kind == "edge") | .relation] | index("proposed_by") != null)
    and ([.[] | select(.kind == "edge" and .relation == "proposes_repo")] | length) == 12
    and ([.[] | select(.kind == "edge" and .relation == "proposes_repo")]
         | group_by(.event_id)
         | all(.[]; length == 3
                    and ([.[].to] | sort == ["repo:repo-a","repo:repo-b","repo:repo-c"])
                    and all(.[]; (.from | startswith("idea:")))))
    and ([.[] | select(.kind == "edge" and .relation == "proposes_repo")] as $repo_edges
         | [.[] | select(.kind == "edge" and .relation == "proposed_by")] as $proposal_edges
         | all($repo_edges[]; . as $repo_edge
               | any($proposal_edges[];
                     .event_id == $repo_edge.event_id and .source == $repo_edge.source)))
    and ([.[] | select(.kind == "edge") | .relation] | index("decided:implementation_approved") != null)
    and ([.[] | select(.kind == "edge") | .relation] | index("decided:idea_rejected") != null)
    and ([.[] | select(.kind == "edge") | .relation] | index("produced_commit") != null)
    and all(.[] | select(.kind == "edge");
      .confidence == "observed" and .source == (".e3d-pilot-fleet/events.jsonl#" + .event_id))
  ' "$out" >/dev/null

  "$BIN" fleet provenance export "$fleet_file" >/dev/null
  assert_export_lines_bounded "$workspace/.e3d-pilot-fleet/provenance.jsonl"
  cmp -s "$out" "$workspace/.e3d-pilot-fleet/provenance.jsonl"

  trace="$("$BIN" fleet provenance trace "$fleet_file" "$implemented" --json)"
  jq -e '
    (.decisions | any(.relation == "decided:implementation_approved" and .actor == "approver"))
    and ([.produced[].repo] | sort == ["repo-a","repo-b"])
    and all(.produced[]; (.repo != "." and (.repo | contains("/") | not)))
  ' <<<"$trace" >/dev/null
  "$BIN" fleet provenance trace "$fleet_file" "$rejected" | grep -q 'relation=decided:idea_rejected actor=rejector'

  if "$BIN" fleet provenance export "$fleet_file" --out "$workspace/.e3d-pilot-fleet/events.jsonl" >/dev/null 2>&1; then
    printf 'expected fleet ledger overwrite attempt to fail\n' >&2
    exit 1
  fi
  if "$BIN" fleet provenance export "$fleet_file" --out "$workspace/.e3d-pilot-fleet/ideas/$proposed/idea.json" >/dev/null 2>&1; then
    printf 'expected fleet idea snapshot overwrite attempt to fail\n' >&2
    exit 1
  fi
  rm -rf "$workspace"
}

main() {
  bash -n "$BIN"
  bash -n "$ROOT/lib/provenance/graph.sh"
  fleet_export_and_trace_have_parity
  echo "phase31: all tests passed"
}

main "$@"
