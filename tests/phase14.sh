#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"

assert_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] || {
    printf 'expected to find %q in output\n' "$needle" >&2
    exit 1
  }
}

assert_eq() {
  local actual="$1" expected="$2" msg="${3:-}"
  [[ "$actual" == "$expected" ]] || {
    printf 'expected %q, got %q (%s)\n' "$expected" "$actual" "$msg" >&2
    exit 1
  }
}

make_repo() {
  local repo email="${1:-tester@example.com}"
  repo="$(mktemp -d)"
  git init -q "$repo"
  git -C "$repo" config user.email "$email"
  git -C "$repo" config user.name "Tester"
  printf '%s\n' "$repo"
}

candidate_json() {
  local file="$1" title="${2:-Decision idea}"
  jq -n --arg title "$title" '{
    focus: "default",
    title: $title,
    summary: "Exercise the human decision CLI.",
    repos: ["repo-a"],
    scores: {attraction: 4, retention: 3, revenue: 2, effort: "low"},
    category: "workflow",
    dedup_rationale: "synthetic candidate"
  }' > "$file"
}

new_idea() {
  local repo="$1" run_id="$2" candidate_id="$3" title="$4" candidate
  candidate="$(mktemp)"
  candidate_json "$candidate" "$title"
  "$BIN" ideas ingest --repo "$repo" --run-id "$run_id" --candidate-id "$candidate_id" --candidate-json "$candidate"
  rm -f "$candidate"
}

event_count() {
  wc -l < "$1/.e3d-pilot/events.jsonl" | tr -d '[:space:]'
}

approve_and_reject_append_attributed_events() {
  local repo idea1 idea2 events_before events_after status
  repo="$(make_repo)"
  idea1="$(new_idea "$repo" run-a candidate-1 "Approve me")"
  idea2="$(new_idea "$repo" run-a candidate-2 "Reject me")"

  events_before="$(event_count "$repo")"
  "$BIN" ideas approve --repo "$repo" "$idea1" --actor "approver@example.com" --note "looks good" >/dev/null
  "$BIN" ideas reject --repo "$repo" "$idea2" --reason "not aligned" --actor "rejecter@example.com" >/dev/null
  events_after="$(event_count "$repo")"
  assert_eq "$events_after" "$((events_before + 2))" "expected exactly two new events"

  status="$(jq -r '.status' "$repo/.e3d-pilot/ideas/$idea1/idea.json")"
  assert_eq "$status" "approved_for_implementation" "approve should transition status"
  assert_eq "$(jq -r '.implementation_approval.actor' "$repo/.e3d-pilot/ideas/$idea1/idea.json")" "approver@example.com" "approval actor recorded"
  assert_eq "$(jq -r '.last_decision_actor' "$repo/.e3d-pilot/ideas/$idea1/idea.json")" "approver@example.com" "last decision actor recorded"

  status="$(jq -r '.status' "$repo/.e3d-pilot/ideas/$idea2/idea.json")"
  assert_eq "$status" "rejected" "reject should transition status"
  assert_eq "$(jq -r '.last_decision_actor' "$repo/.e3d-pilot/ideas/$idea2/idea.json")" "rejecter@example.com" "reject actor recorded"
  assert_eq "$(jq -r '.last_event_id' "$repo/.e3d-pilot/ideas/$idea2/idea.json" | wc -l | tr -d ' ')" "1" "sanity: last_event_id present"

  rm -rf "$repo"
}

missing_reason_fails_without_mutation() {
  local repo idea before_count before_file status
  repo="$(make_repo)"
  idea="$(new_idea "$repo" run-b candidate-1 "Needs a reason")"
  before_count="$(event_count "$repo")"
  before_file="$(mktemp)"
  cp "$repo/.e3d-pilot/ideas/$idea/idea.json" "$before_file"

  set +e
  "$BIN" ideas reject --repo "$repo" "$idea" 2>/dev/null
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "expected reject without --reason to fail" >&2; exit 1; }

  set +e
  "$BIN" ideas request-changes --repo "$repo" "$idea" 2>/dev/null
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "expected request-changes without --reason to fail" >&2; exit 1; }

  [[ "$(event_count "$repo")" == "$before_count" ]] || { echo "event stream mutated despite missing reason" >&2; exit 1; }
  cmp -s "$before_file" "$repo/.e3d-pilot/ideas/$idea/idea.json" || { echo "snapshot mutated despite missing reason" >&2; exit 1; }

  rm -rf "$repo"; rm -f "$before_file"
}

pending_and_rejected_are_visibly_distinct() {
  local repo pending rejected list_out list_json pending_status rejected_status
  repo="$(make_repo)"
  pending="$(new_idea "$repo" run-c candidate-1 "Still pending")"
  rejected="$(new_idea "$repo" run-c candidate-2 "Already rejected")"
  "$BIN" ideas reject --repo "$repo" "$rejected" --reason "no" >/dev/null

  list_out="$("$BIN" ideas list --repo "$repo")"
  assert_contains "$list_out" "$pending"
  assert_contains "$list_out" "proposed"
  assert_contains "$list_out" "$rejected"
  assert_contains "$list_out" "rejected"

  list_json="$("$BIN" ideas list --repo "$repo" --json)"
  pending_status="$(jq -r --arg id "$pending" '.[] | select(.idea_id==$id) | .status' <<<"$list_json")"
  rejected_status="$(jq -r --arg id "$rejected" '.[] | select(.idea_id==$id) | .status' <<<"$list_json")"
  assert_eq "$pending_status" "proposed" "pending status distinct"
  assert_eq "$rejected_status" "rejected" "rejected status distinct"

  local filtered
  filtered="$("$BIN" ideas list --repo "$repo" --status proposed --json)"
  assert_eq "$(jq 'length' <<<"$filtered")" "1" "status filter narrows to one idea"
  assert_eq "$(jq -r '.[0].idea_id' <<<"$filtered")" "$pending" "status filter returns the pending idea"

  rm -rf "$repo"
}

list_is_deterministic_newest_first_then_id() {
  local repo id_a id_b id_c out first second third
  repo="$(make_repo)"
  id_a="$(new_idea "$repo" run-d candidate-1 "First")"
  id_b="$(new_idea "$repo" run-d candidate-2 "Second")"
  id_c="$(new_idea "$repo" run-d candidate-3 "Third")"

  local out1 out2
  out1="$("$BIN" ideas list --repo "$repo" --json | jq -r '.[].idea_id')"
  out2="$("$BIN" ideas list --repo "$repo" --json | jq -r '.[].idea_id')"
  assert_eq "$out1" "$out2" "list ordering must be deterministic across invocations"

  # All three ideas share the same (or nearly the same) created_at second, so
  # the tiebreak must be idea_id ascending within that group.
  local expected_tail
  expected_tail="$(printf '%s\n%s\n%s\n' "$id_a" "$id_b" "$id_c" | sort)"
  local actual_sorted
  actual_sorted="$(printf '%s\n' "$out1" | sort)"
  assert_eq "$actual_sorted" "$expected_tail" "list should contain exactly the three ideas"

  rm -rf "$repo"
}

approval_digest_matches_gate_expectation() {
  local repo idea digest recomputed
  repo="$(make_repo)"
  idea="$(new_idea "$repo" run-e candidate-1 "Digest bound")"
  "$BIN" ideas approve --repo "$repo" "$idea" --actor "approver@example.com" >/dev/null

  digest="$(jq -r '.implementation_approval.digest' "$repo/.e3d-pilot/ideas/$idea/idea.json")"
  [[ -n "$digest" && "$digest" != "null" ]] || { echo "expected a non-empty approval digest" >&2; exit 1; }

  recomputed="$(jq -cS '{
    title: (.title // null),
    summary: (.summary // null),
    repos: (.repos // []),
    scores: {
      attraction: (.scores.attraction // null),
      retention: (.scores.retention // null),
      revenue: (.scores.revenue // null),
      effort: (.scores.effort // null)
    },
    category: (.category // null),
    dedup_rationale: (.dedup_rationale // null),
    implementation_target_plan: (.implementation.targets // [])
  }' "$repo/.e3d-pilot/ideas/$idea/idea.json" | { command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum; } | awk '{print $1}')"
  assert_eq "$digest" "$recomputed" "approval digest must match the decision-bearing content digest"

  rm -rf "$repo"
}

idempotent_reapproval_is_a_no_op() {
  local repo idea digest_before events_before events_after digest_after
  repo="$(make_repo)"
  idea="$(new_idea "$repo" run-f candidate-1 "Reapprove me")"
  "$BIN" ideas approve --repo "$repo" "$idea" --actor "approver@example.com" >/dev/null
  digest_before="$(jq -r '.implementation_approval.digest' "$repo/.e3d-pilot/ideas/$idea/idea.json")"
  events_before="$(event_count "$repo")"

  "$BIN" ideas approve --repo "$repo" "$idea" --actor "approver@example.com" >/dev/null
  events_after="$(event_count "$repo")"
  digest_after="$(jq -r '.implementation_approval.digest' "$repo/.e3d-pilot/ideas/$idea/idea.json")"

  assert_eq "$events_after" "$events_before" "idempotent re-approval must not append an event"
  assert_eq "$digest_after" "$digest_before" "idempotent re-approval must not change the recorded digest"

  rm -rf "$repo"
}

actor_resolves_from_git_config_when_not_explicit() {
  local repo idea actor
  repo="$(make_repo "configured@example.com")"
  idea="$(new_idea "$repo" run-g candidate-1 "Actor from config")"
  "$BIN" ideas approve --repo "$repo" "$idea" >/dev/null
  actor="$(jq -r '.implementation_approval.actor' "$repo/.e3d-pilot/ideas/$idea/idea.json")"
  assert_eq "$actor" "configured@example.com" "actor should default to git config user.email"
  rm -rf "$repo"
}

fleet_list_show_approve_reject_work() {
  local parent repo_a repo_b fleet_dir fleet_file idea1 idea2 candidate
  parent="$(mktemp -d)"
  repo_a="$parent/repo-a"; repo_b="$parent/repo-b"
  for name in repo-a repo-b; do
    mkdir -p "$parent/$name"
    git init -q "$parent/$name"
    git -C "$parent/$name" config user.email "fleet@example.com"
    git -C "$parent/$name" config user.name "Fleet"
    printf '# %s\n' "$name" > "$parent/$name/README.md"
    git -C "$parent/$name" add README.md
    git -C "$parent/$name" commit -q -m init
  done
  fleet_dir="$(mktemp -d)"
  fleet_file="$fleet_dir/fleet.json"
  jq -n --arg a "$repo_a" --arg b "$repo_b" '[$a,$b]' > "$fleet_file"

  candidate="$(mktemp)"
  jq -n --arg a "$repo_a" --arg b "$repo_b" '{
    focus: "default", title: "Fleet decision", summary: "cross repo idea",
    repos: [$a, $b],
    scores: {attraction: 4, retention: 4, revenue: 5, effort: "medium"},
    category: "integration", dedup_rationale: "none"
  }' > "$candidate"
  idea1="$("$BIN" fleet ideas "$fleet_file" ingest --run-id fleet-run --candidate-id candidate-1 --candidate-json "$candidate")"

  jq -n --arg a "$repo_a" '{
    focus: "default", title: "Fleet reject me", summary: "cross repo idea",
    repos: [$a],
    scores: {attraction: 1, retention: 1, revenue: 1, effort: "low"},
    category: "integration", dedup_rationale: "none"
  }' > "$candidate"
  idea2="$("$BIN" fleet ideas "$fleet_file" ingest --run-id fleet-run --candidate-id candidate-2 --candidate-json "$candidate")"

  "$BIN" fleet ideas "$fleet_file" approve "$idea1" --actor "fleet-approver@example.com" >/dev/null
  "$BIN" fleet ideas "$fleet_file" reject "$idea2" --reason "not now" >/dev/null

  local shown targets status1 status2
  shown="$("$BIN" fleet ideas "$fleet_file" show "$idea1" --json)"
  status1="$(jq -r '.status' <<<"$shown")"
  assert_eq "$status1" "approved_for_implementation" "fleet approve should transition status"
  targets="$(jq -c '.implementation.targets' <<<"$shown")"
  assert_eq "$(jq 'length' <<<"$targets")" "2" "fleet approval should bind a two-target plan"
  assert_eq "$(jq -r '.[0].role' <<<"$targets")" "primary" "first fleet target role"
  assert_eq "$(jq -r '.[1].role' <<<"$targets")" "secondary" "second fleet target role"

  status2="$(jq -r '.status' <<<"$("$BIN" fleet ideas "$fleet_file" show "$idea2" --json)")"
  assert_eq "$status2" "rejected" "fleet reject should transition status"

  local list_out
  list_out="$("$BIN" fleet ideas "$fleet_file" list)"
  assert_contains "$list_out" "$idea1"
  assert_contains "$list_out" "$idea2"

  rm -rf "$parent" "$fleet_dir"; rm -f "$candidate"
}

main() {
  bash -n "$BIN"
  bash -n "$ROOT/lib/ideas/ledger.sh"
  approve_and_reject_append_attributed_events
  missing_reason_fails_without_mutation
  pending_and_rejected_are_visibly_distinct
  list_is_deterministic_newest_first_then_id
  approval_digest_matches_gate_expectation
  idempotent_reapproval_is_a_no_op
  actor_resolves_from_git_config_when_not_explicit
  fleet_list_show_approve_reject_work
  echo "phase14: all tests passed"
}

main "$@"
