#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"

# shellcheck source=../lib/ideas/ledger.sh
source "$ROOT/lib/ideas/ledger.sh"
# shellcheck source=../lib/provenance/graph.sh
source "$ROOT/lib/provenance/graph.sh"

make_repo() {
  local repo
  repo="$(mktemp -d)"
  git init -q "$repo"
  printf '%s' "$repo"
}

new_repo_idea() {
  local repo="$1" candidate_id="$2" title="$3" candidate
  candidate="$(mktemp)"
  jq -ncS --arg title "$title" '{
    title:$title,summary:"Lineage fixture",repos:["repo-a"],
    scores:{attraction:4,retention:3,revenue:2,effort:"low"},
    category:"workflow",provenance:{duplicate:false},implementation:{targets:[]}
  }' > "$candidate"
  "$BIN" ideas ingest --repo "$repo" --run-id run-33 --candidate-id "$candidate_id" --candidate-json "$candidate"
  rm -f "$candidate"
}

make_fleet() {
  local workspace
  workspace="$(mktemp -d)"
  git init -q "$workspace/repo-a"
  git init -q "$workspace/repo-b"
  git init -q "$workspace/repo-c"
  jq -ncS '["repo-a","repo-b","repo-c"]' > "$workspace/fleet.json"
  printf '%s' "$workspace/fleet.json"
}

new_fleet_idea_with_repos() {
  local fleet_file="$1" candidate_id="$2" title="$3" repos_json="$4" candidate
  candidate="$(mktemp)"
  jq -ncS --arg title "$title" --argjson repos "$repos_json" '{
    title:$title,summary:"Fleet propagation fixture",repos:$repos,
    scores:{attraction:4,retention:3,revenue:2,effort:"low"},category:"workflow",
    validation:{approvable:true,eligibility_reason:null,warnings:[]},implementation:{targets:[]}
  }' > "$candidate"
  "$BIN" fleet ideas "$fleet_file" ingest --run-id run-33 --candidate-id "$candidate_id" --candidate-json "$candidate"
  rm -f "$candidate"
}

new_fleet_idea() {
  local fleet_file="$1" candidate_id="$2" title="$3" candidate
  candidate="$(mktemp)"
  jq -ncS --arg title "$title" '{
    title:$title,summary:"Fleet lineage fixture",repos:["repo-a"],
    scores:{attraction:4,retention:3,revenue:2,effort:"low"},category:"workflow",
    validation:{approvable:true,eligibility_reason:null,warnings:[]},implementation:{targets:[]}
  }' > "$candidate"
  "$BIN" fleet ideas "$fleet_file" ingest --run-id run-33 --candidate-id "$candidate_id" --candidate-json "$candidate"
  rm -f "$candidate"
}

append_event() {
  local kind="$1" workspace="$2" idea_id="$3" event="$4" extra_json="$5" extra
  extra="$(mktemp)"
  printf '%s\n' "$extra_json" > "$extra"
  ideas_append_custom_event "$kind" "$workspace" "$idea_id" "$event" fixture "$event fixture" "$extra" >/dev/null
  rm -f "$extra"
}

populate_lineage_fixture() {
  local kind="$1" workspace="$2" no_activity="$3" in_progress="$4" shipped="$5" external="$6" rejected="$7"
  append_event "$kind" "$workspace" "$in_progress" note_appended '{"kind":"decision","text":"continue"}'
  append_event "$kind" "$workspace" "$shipped" implementation_approved '{}'
  append_event "$kind" "$workspace" "$shipped" implementation_started '{}'
  append_event "$kind" "$workspace" "$shipped" implementation_completed \
    '{"outcome":{"targets":[{"repo":"repo-a","final_pr_head_sha":"shipped-sha"}]}}'
  append_event "$kind" "$workspace" "$shipped" forge_sync \
    '{"observations":[{"repo":"repo-a","head_sha":"shipped-sha"}]}'
  append_event "$kind" "$workspace" "$shipped" outcome_recorded \
    '{"outcome":{"type":"metrics","window":"7d","metrics":[{"key":"useful","value":true}]}}'
  append_event "$kind" "$workspace" "$external" implementation_approved '{}'
  append_event "$kind" "$workspace" "$external" implementation_started '{}'
  append_event "$kind" "$workspace" "$external" implementation_completed '{"outcome":{"targets":[]}}'
  append_event "$kind" "$workspace" "$external" forge_sync \
    '{"observations":[{"repo":"repo-a","head_sha":"external-sha"}]}'
  append_event "$kind" "$workspace" "$rejected" idea_rejected '{}'
}

assert_lineage() {
  local json="$1" events_file="$2" no_activity="$3" in_progress="$4" shipped="$5" external="$6" rejected="$7"
  jq -e \
    --arg no_activity "$no_activity" --arg in_progress "$in_progress" \
    --arg shipped "$shipped" --arg external "$external" --arg rejected "$rejected" '
    length == 5
    and (map({key:.idea_id,value:.}) | from_entries) as $by_id
    | ($by_id[$no_activity].status_summary == "no_activity"
       and ($by_id[$no_activity].has_produced_commit | not)
       and ($by_id[$no_activity].has_observed_commit | not)
       and ($by_id[$no_activity].has_outcome | not))
    and ($by_id[$in_progress].status_summary == "in_progress")
    and ($by_id[$shipped].status_summary == "shipped"
         and $by_id[$shipped].has_produced_commit
         and $by_id[$shipped].has_observed_commit
         and $by_id[$shipped].has_outcome)
    and ($by_id[$external].status_summary == "shipped_externally"
         and ($by_id[$external].has_produced_commit | not)
         and $by_id[$external].has_observed_commit)
    and ($by_id[$rejected].status_summary == "rejected")
    and all(.[]; (.title | type == "string" and length > 0) and (.evidence | length > 0))
  ' <<<"$json" >/dev/null

  jq -n -e --argjson results "$json" --slurpfile events "$events_file" '
    all($results[]; . as $item
      | all($item.evidence[]; . as $event_id
        | any($events[]; .event_id == $event_id and .idea_id == $item.idea_id)))
  ' >/dev/null
}

repo_lineage_classifies_all_statuses() {
  local repo no_activity in_progress shipped external rejected json text out direct
  repo="$(make_repo)"
  no_activity="$(new_repo_idea "$repo" no-activity "No activity")"
  in_progress="$(new_repo_idea "$repo" in-progress "In progress")"
  shipped="$(new_repo_idea "$repo" shipped "Shipped")"
  external="$(new_repo_idea "$repo" external "Shipped externally")"
  rejected="$(new_repo_idea "$repo" rejected "Rejected")"
  populate_lineage_fixture repo "$repo" "$no_activity" "$in_progress" "$shipped" "$external" "$rejected"

  json="$("$BIN" provenance query lineage --repo "$repo" --json)"
  assert_lineage "$json" "$repo/.e3d-pilot/events.jsonl" "$no_activity" "$in_progress" "$shipped" "$external" "$rejected"
  text="$("$BIN" provenance query lineage --repo "$repo")"
  grep -q "$no_activity.*no_activity.*evidence=" <<<"$text"
  grep -q "$external.*shipped_externally.*evidence=" <<<"$text"

  out="$repo/provenance.jsonl"
  "$BIN" provenance export --repo "$repo" --out "$out" >/dev/null
  direct="$repo/direct.jsonl"
  provenance_build_graph repo "$repo" "$repo/.e3d-pilot/events.jsonl" > "$direct"
  cmp -s "$out" "$direct"
  rm -rf "$repo"
}

fleet_lineage_classifies_all_statuses() {
  local fleet_file workspace no_activity in_progress shipped external rejected json
  fleet_file="$(make_fleet)"
  workspace="$(dirname "$fleet_file")"
  no_activity="$(new_fleet_idea "$fleet_file" no-activity "No activity")"
  in_progress="$(new_fleet_idea "$fleet_file" in-progress "In progress")"
  shipped="$(new_fleet_idea "$fleet_file" shipped "Shipped")"
  external="$(new_fleet_idea "$fleet_file" external "Shipped externally")"
  rejected="$(new_fleet_idea "$fleet_file" rejected "Rejected")"
  populate_lineage_fixture fleet "$workspace" "$no_activity" "$in_progress" "$shipped" "$external" "$rejected"

  json="$("$BIN" fleet provenance query lineage "$fleet_file" --json)"
  assert_lineage "$json" "$workspace/.e3d-pilot-fleet/events.jsonl" "$no_activity" "$in_progress" "$shipped" "$external" "$rejected"
  "$BIN" fleet provenance query lineage "$fleet_file" | grep -q "$rejected.*rejected.*evidence="
  rm -rf "$workspace"
}

empty_repo_returns_an_empty_result() {
  local repo
  repo="$(make_repo)"
  [[ "$("$BIN" provenance query lineage --repo "$repo" --json)" == "[]" ]]
  [[ "$("$BIN" provenance query lineage --repo "$repo")" == "No ideas found." ]]
  [[ "$("$BIN" provenance query reversals --repo "$repo" --json)" == "[]" ]]
  [[ "$("$BIN" provenance query reversals --repo "$repo")" == "No decision reversals found." ]]
  [[ "$("$BIN" provenance query failures --repo "$repo" --json)" == "[]" ]]
  [[ "$("$BIN" provenance query failures --repo "$repo")" == "No implementation failures found." ]]
  [[ "$("$BIN" provenance query cross-repo --repo "$repo" --json)" == "[]" ]]
  [[ "$("$BIN" provenance query cross-repo --repo "$repo")" == "No cross-repo propagation found." ]]
  rm -rf "$repo"
}

fleet_cross_repo_compares_proposed_and_actual_sets() {
  local fleet_file workspace mismatch matched proposed_only json text events_file
  fleet_file="$(make_fleet)"
  workspace="$(dirname "$fleet_file")"
  mismatch="$(new_fleet_idea_with_repos "$fleet_file" mismatch 'Mismatched repos' '["repo-a","repo-b","repo-c"]')"
  matched="$(new_fleet_idea_with_repos "$fleet_file" matched 'Matched repos' '["repo-a","repo-b"]')"
  proposed_only="$(new_fleet_idea_with_repos "$fleet_file" proposed-only 'Still proposed' '["repo-c"]')"

  append_event fleet "$workspace" "$mismatch" implementation_approved '{}'
  append_event fleet "$workspace" "$mismatch" implementation_started '{}'
  append_event fleet "$workspace" "$mismatch" implementation_completed \
    '{"outcome":{"targets":[{"repo":"repo-a","final_pr_head_sha":"mismatch-a"}]}}'
  append_event fleet "$workspace" "$matched" implementation_approved '{}'
  append_event fleet "$workspace" "$matched" implementation_started '{}'
  append_event fleet "$workspace" "$matched" implementation_completed \
    '{"outcome":{"targets":[]}}'
  append_event fleet "$workspace" "$matched" forge_sync \
    '{"observations":[{"repo":"repo-a","head_sha":"matched-a"},{"repo":"repo-b","head_sha":"matched-b"}]}'

  json="$("$BIN" fleet provenance query cross-repo "$fleet_file" --json)"
  jq -e --arg mismatch "$mismatch" --arg matched "$matched" --arg proposed_only "$proposed_only" '
    length == 2
    and (map({key:.idea_id,value:.}) | from_entries) as $by_id
    | ($by_id[$mismatch].proposed_repos == ["repo-a","repo-b","repo-c"]
       and $by_id[$mismatch].actual_repos == ["repo-a"]
       and ($by_id[$mismatch].matches | not))
    and ($by_id[$matched].proposed_repos == ["repo-a","repo-b"]
         and $by_id[$matched].actual_repos == ["repo-a","repo-b"]
         and $by_id[$matched].matches)
    and (map(.idea_id) | index($proposed_only) == null)
    and all(.[]; (.title | length > 0) and (.evidence | length >= 2))
  ' <<<"$json" >/dev/null

  events_file="$workspace/.e3d-pilot-fleet/events.jsonl"
  jq -n -e --argjson results "$json" --slurpfile events "$events_file" '
    all($results[]; . as $item
      | all($item.evidence[]; . as $event_id
        | any($events[]; .event_id == $event_id and .idea_id == $item.idea_id)))
  ' >/dev/null
  text="$("$BIN" fleet provenance query cross-repo "$fleet_file")"
  grep -q "$mismatch.*matches=false.*proposed=repo-a,repo-b,repo-c actual=repo-a" <<<"$text"
  grep -q "$matched.*matches=true.*proposed=repo-a,repo-b actual=repo-a,repo-b" <<<"$text"
  ! grep -q "$proposed_only" <<<"$text"
  rm -rf "$workspace"
}

populate_phase2_fixture() {
  local kind="$1" workspace="$2" contested="$3" limited="$4" failed="$5" outcome cycle
  ideas_transition "$kind" "$workspace" "$contested" implementation_approved approver "approved" "" "" >/dev/null
  for cycle in first second third; do
    ideas_transition "$kind" "$workspace" "$contested" implementation_started builder "started" "" "" >/dev/null
    ideas_transition "$kind" "$workspace" "$contested" implementation_completed builder "completed" "" "" >/dev/null
    ideas_transition "$kind" "$workspace" "$contested" changes_requested reviewer "$cycle review" "" "" >/dev/null
  done
  ideas_transition "$kind" "$workspace" "$limited" implementation_approved approver "approved" "" "" >/dev/null
  ideas_transition "$kind" "$workspace" "$limited" implementation_started builder "started" "" "" >/dev/null
  ideas_transition "$kind" "$workspace" "$limited" implementation_completed builder "completed" "" "" >/dev/null
  ideas_transition "$kind" "$workspace" "$limited" changes_requested reviewer "single review" "" "" >/dev/null

  ideas_transition "$kind" "$workspace" "$failed" implementation_approved approver "approved" "" "" >/dev/null
  ideas_transition "$kind" "$workspace" "$failed" implementation_started builder "started" "" "" >/dev/null
  append_event "$kind" "$workspace" "$failed" note_appended \
    '{"kind":"finding","text":"nearest observed context"}'
  sleep 1
  outcome="$(mktemp)"
  jq -ncS --arg idea "$failed" \
    '{type:"implementation",idea_id:$idea,status:"failed",targets:[],failure_reason:"fixture"}' > "$outcome"
  ideas_transition "$kind" "$workspace" "$failed" implementation_failed builder "failed" "" "" "$outcome" >/dev/null
  rm -f "$outcome"
}

assert_phase2_queries() {
  local kind="$1" workspace="$2" fleet_file="$3" contested="$4" limited="$5" failed="$6"
  local reversals failures trace text events_file
  if [[ "$kind" == "repo" ]]; then
    reversals="$("$BIN" provenance query reversals --repo "$workspace" --json)"
    failures="$("$BIN" provenance query failures --repo "$workspace" --json)"
    trace="$("$BIN" provenance trace --repo "$workspace" "$failed" --json)"
    text="$("$BIN" provenance query failures --repo "$workspace")"
    events_file="$workspace/.e3d-pilot/events.jsonl"
  else
    reversals="$("$BIN" fleet provenance query reversals "$fleet_file" --json)"
    failures="$("$BIN" fleet provenance query failures "$fleet_file" --json)"
    trace="$("$BIN" fleet provenance trace "$fleet_file" "$failed" --json)"
    text="$("$BIN" fleet provenance query failures "$fleet_file")"
    events_file="$workspace/.e3d-pilot-fleet/events.jsonl"
  fi

  jq -e --arg contested "$contested" --arg limited "$limited" '
    length == 1
    and .[0].idea_id == $contested
    and .[0].changes_requested_count == 3
    and .[0].final_status == "changes_requested"
    and (.[0].event_ids | length) == 3
    and (map(.idea_id) | index($limited) == null)
  ' <<<"$reversals" >/dev/null
  jq -n -e --argjson results "$reversals" --slurpfile events "$events_file" '
    all($results[].event_ids[]; . as $event_id
      | any($events[]; .event_id == $event_id and .event == "changes_requested"))
  ' >/dev/null

  jq -e --arg failed "$failed" --argjson trace "$trace" '
    length == 1
    and .[0].idea_id == $failed
    and (.[0].title | length > 0)
    and .[0].failure == $trace.failure
    and .[0].decisions == $trace.decisions
    and .[0].findings == $trace.findings
    and (.[0].failure | length) == 1
    and (.[0].failure[0].nearest_prior_context | type == "string")
    and (.[0].failure[0] | has("invalidated") | not)
  ' <<<"$failures" >/dev/null
  grep -q 'no invalidation is claimed; this is the nearest preceding entry in time only' <<<"$text"
}

repo_reversals_and_failures_are_reported() {
  local repo contested limited failed
  repo="$(make_repo)"
  contested="$(new_repo_idea "$repo" contested "Contested repo idea")"
  limited="$(new_repo_idea "$repo" limited "Single review repo idea")"
  failed="$(new_repo_idea "$repo" failed "Failed repo idea")"
  populate_phase2_fixture repo "$repo" "$contested" "$limited" "$failed"
  assert_phase2_queries repo "$repo" "" "$contested" "$limited" "$failed"
  "$BIN" provenance query reversals --repo "$repo" | grep -q "$contested.*changes_requested=3"
  rm -rf "$repo"
}

fleet_reversals_and_failures_are_reported() {
  local fleet_file workspace contested limited failed
  fleet_file="$(make_fleet)"
  workspace="$(dirname "$fleet_file")"
  contested="$(new_fleet_idea "$fleet_file" contested "Contested fleet idea")"
  limited="$(new_fleet_idea "$fleet_file" limited "Single review fleet idea")"
  failed="$(new_fleet_idea "$fleet_file" failed "Failed fleet idea")"
  populate_phase2_fixture fleet "$workspace" "$contested" "$limited" "$failed"
  assert_phase2_queries fleet "$workspace" "$fleet_file" "$contested" "$limited" "$failed"
  "$BIN" fleet provenance query reversals "$fleet_file" | grep -q "$contested.*changes_requested=3"
  rm -rf "$workspace"
}

main() {
  bash -n "$BIN"
  bash -n "$ROOT/lib/provenance/graph.sh"
  repo_lineage_classifies_all_statuses
  fleet_lineage_classifies_all_statuses
  empty_repo_returns_an_empty_result
  repo_reversals_and_failures_are_reported
  fleet_reversals_and_failures_are_reported
  fleet_cross_repo_compares_proposed_and_actual_sets
  echo "phase33: all tests passed"
}

main "$@"
