#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"

make_repo() {
  local repo
  repo="$(mktemp -d)"
  git init -q "$repo"
  printf '%s\n' "$repo"
}

candidate_json() {
  local file="$1" title="${2:-Ledger idea}" repo_name="${3:-repo-a}"
  jq -n \
    --arg title "$title" \
    --arg repo "$repo_name" \
    '{
      focus: "default",
      title: $title,
      summary: "Persist a proposed idea for approval-gated delivery.",
      repos: [$repo],
      scores: {attraction: 4, retention: 3, revenue: 2, effort: "low"},
      category: "workflow",
      analogy: "developer tools -- explicit state",
      dedup_rationale: "synthetic candidate",
      provenance: {provider: "stub", model: "none"},
      content_digests: {"candidates.md": "sha256:test"},
      implementation: {targets: []}
    }' > "$file"
}

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
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

assert_status() {
  local repo="$1" idea_id="$2" expected="$3" actual
  actual="$(jq -r '.status' "$repo/.e3d-pilot/ideas/$idea_id/idea.json")"
  [[ "$actual" == "$expected" ]] || {
    printf 'expected status %s, got %s\n' "$expected" "$actual" >&2
    exit 1
  }
}

transition() {
  local repo="$1" idea_id="$2" event="$3"
  "$BIN" ideas transition --repo "$repo" "$idea_id" "$event" --actor "tester@example.com" >/dev/null
}

reach_status() {
  local repo="$1" idea_id="$2" status="$3"
  case "$status" in
    proposed) ;;
    approved_for_implementation) transition "$repo" "$idea_id" implementation_approved ;;
    rejected) transition "$repo" "$idea_id" idea_rejected ;;
    implementing) transition "$repo" "$idea_id" implementation_approved; transition "$repo" "$idea_id" implementation_started ;;
    implementation_failed) transition "$repo" "$idea_id" implementation_approved; transition "$repo" "$idea_id" implementation_started; transition "$repo" "$idea_id" implementation_failed ;;
    implemented) transition "$repo" "$idea_id" implementation_approved; transition "$repo" "$idea_id" implementation_started; transition "$repo" "$idea_id" implementation_completed ;;
    changes_requested) transition "$repo" "$idea_id" implementation_approved; transition "$repo" "$idea_id" implementation_started; transition "$repo" "$idea_id" implementation_completed; transition "$repo" "$idea_id" changes_requested ;;
    approved_for_merge) transition "$repo" "$idea_id" implementation_approved; transition "$repo" "$idea_id" implementation_started; transition "$repo" "$idea_id" implementation_completed; transition "$repo" "$idea_id" merge_approved ;;
    merge_failed) transition "$repo" "$idea_id" implementation_approved; transition "$repo" "$idea_id" implementation_started; transition "$repo" "$idea_id" implementation_completed; transition "$repo" "$idea_id" merge_approved; transition "$repo" "$idea_id" merge_failed ;;
    partially_merged) transition "$repo" "$idea_id" implementation_approved; transition "$repo" "$idea_id" implementation_started; transition "$repo" "$idea_id" implementation_completed; transition "$repo" "$idea_id" merge_approved; transition "$repo" "$idea_id" merge_partially_completed ;;
    merged) transition "$repo" "$idea_id" implementation_approved; transition "$repo" "$idea_id" implementation_started; transition "$repo" "$idea_id" implementation_completed; transition "$repo" "$idea_id" merge_approved; transition "$repo" "$idea_id" merge_completed ;;
    closed) transition "$repo" "$idea_id" implementation_approved; transition "$repo" "$idea_id" implementation_started; transition "$repo" "$idea_id" implementation_completed; transition "$repo" "$idea_id" idea_closed ;;
    reverted) transition "$repo" "$idea_id" implementation_approved; transition "$repo" "$idea_id" implementation_started; transition "$repo" "$idea_id" implementation_completed; transition "$repo" "$idea_id" merge_approved; transition "$repo" "$idea_id" merge_completed; transition "$repo" "$idea_id" idea_reverted ;;
    *) printf 'unknown setup status %s\n' "$status" >&2; exit 1 ;;
  esac
  assert_status "$repo" "$idea_id" "$status"
}

allowed_next_status() {
  local from="$1" event="$2"
  case "$from:$event" in
    proposed:implementation_approved) printf 'approved_for_implementation' ;;
    proposed:idea_rejected) printf 'rejected' ;;
    approved_for_implementation:implementation_started) printf 'implementing' ;;
    implementing:implementation_completed) printf 'implemented' ;;
    implementing:implementation_failed) printf 'implementation_failed' ;;
    implemented:merge_approved) printf 'approved_for_merge' ;;
    implemented:changes_requested) printf 'changes_requested' ;;
    implemented:idea_closed) printf 'closed' ;;
    changes_requested:implementation_started) printf 'implementing' ;;
    changes_requested:merge_approved) printf 'approved_for_merge' ;;
    changes_requested:idea_closed) printf 'closed' ;;
    approved_for_merge:merge_completed) printf 'merged' ;;
    approved_for_merge:merge_partially_completed) printf 'partially_merged' ;;
    approved_for_merge:merge_failed) printf 'merge_failed' ;;
    partially_merged:merge_completed) printf 'merged' ;;
    partially_merged:merge_failed) printf 'merge_failed' ;;
    merged:idea_reverted) printf 'reverted' ;;
    implementation_failed:implementation_retry_approved) printf 'implementing' ;;
    merge_failed:merge_retry_approved) printf 'approved_for_merge' ;;
    *) return 1 ;;
  esac
}

idempotent_ingest() {
  local repo candidate first second dirs proposals
  repo="$(make_repo)"
  candidate="$(mktemp)"
  candidate_json "$candidate" "Same candidate"
  first="$("$BIN" ideas ingest --repo "$repo" --run-id run-1 --candidate-id candidate-1 --candidate-json "$candidate")"
  second="$("$BIN" ideas ingest --repo "$repo" --run-id run-1 --candidate-id candidate-1 --candidate-json "$candidate")"
  [[ "$first" == "$second" ]] || { printf 'expected same idea id on re-ingest\n' >&2; exit 1; }
  dirs="$(find "$repo/.e3d-pilot/ideas" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')"
  proposals="$(jq -R -s '[split("\n")[] | select(length>0) | fromjson | select(.event=="idea_proposed")] | length' "$repo/.e3d-pilot/events.jsonl")"
  [[ "$dirs" == 1 && "$proposals" == 1 ]] || { printf 'expected one idea dir and one proposal event\n' >&2; exit 1; }
  rm -rf "$repo"; rm -f "$candidate"
}

distinct_candidates_get_distinct_ids() {
  local repo c1 c2 id1 id2
  repo="$(make_repo)"
  c1="$(mktemp)"; c2="$(mktemp)"
  candidate_json "$c1" "First candidate"
  candidate_json "$c2" "Second candidate"
  id1="$("$BIN" ideas ingest --repo "$repo" --run-id run-1 --candidate-id candidate-1 --candidate-json "$c1")"
  id2="$("$BIN" ideas ingest --repo "$repo" --run-id run-1 --candidate-id candidate-2 --candidate-json "$c2")"
  [[ "$id1" != "$id2" ]] || { printf 'expected different IDs for different candidates\n' >&2; exit 1; }
  rm -rf "$repo"; rm -f "$c1" "$c2"
}

allowed_transitions_succeed() {
  local from event expected repo idea_id index=0
  while read -r from event expected; do
    [[ -n "$from" ]] || continue
    index=$((index + 1))
    repo="$(make_repo)"
    idea_id="$(new_idea "$repo" "run-$index" "candidate-$index" "Allowed $index")"
    reach_status "$repo" "$idea_id" "$from"
    transition "$repo" "$idea_id" "$event"
    assert_status "$repo" "$idea_id" "$expected"
    rm -rf "$repo"
  done <<'EOF'
proposed implementation_approved approved_for_implementation
proposed idea_rejected rejected
approved_for_implementation implementation_started implementing
implementing implementation_completed implemented
implementing implementation_failed implementation_failed
implemented merge_approved approved_for_merge
implemented changes_requested changes_requested
implemented idea_closed closed
changes_requested implementation_started implementing
changes_requested merge_approved approved_for_merge
changes_requested idea_closed closed
approved_for_merge merge_completed merged
approved_for_merge merge_partially_completed partially_merged
approved_for_merge merge_failed merge_failed
partially_merged merge_completed merged
partially_merged merge_failed merge_failed
merged idea_reverted reverted
implementation_failed implementation_retry_approved implementing
merge_failed merge_retry_approved approved_for_merge
EOF
}

disallowed_transitions_do_not_mutate() {
  local statuses events status event repo idea_id before_count before_file after_count index=0
  statuses="proposed approved_for_implementation rejected implementing implementation_failed implemented changes_requested approved_for_merge merge_failed partially_merged merged closed reverted"
  events="implementation_approved idea_rejected implementation_started implementation_completed implementation_failed merge_approved changes_requested idea_closed merge_completed merge_partially_completed merge_failed idea_reverted implementation_retry_approved merge_retry_approved arbitrary_status"
  for status in $statuses; do
    index=$((index + 1))
    repo="$(make_repo)"
    idea_id="$(new_idea "$repo" "bad-run-$index" "candidate-$index" "Disallowed $index")"
    reach_status "$repo" "$idea_id" "$status"
    for event in $events; do
      if allowed_next_status "$status" "$event" >/dev/null; then
        continue
      fi
      before_count="$(event_count "$repo")"
      before_file="$(mktemp)"
      cp "$repo/.e3d-pilot/ideas/$idea_id/idea.json" "$before_file"
      if "$BIN" ideas transition --repo "$repo" "$idea_id" "$event" --actor "tester@example.com" >/dev/null 2>&1; then
        printf 'expected transition %s + %s to fail\n' "$status" "$event" >&2
        exit 1
      fi
      after_count="$(event_count "$repo")"
      [[ "$before_count" == "$after_count" ]] || { printf 'event stream mutated on invalid transition\n' >&2; exit 1; }
      cmp -s "$before_file" "$repo/.e3d-pilot/ideas/$idea_id/idea.json" || { printf 'snapshot mutated on invalid transition\n' >&2; exit 1; }
      rm -f "$before_file"
    done
    rm -rf "$repo"
  done
}

rebuild_recovers_after_append_before_snapshot() {
  local repo idea_id before after
  repo="$(make_repo)"
  idea_id="$(new_idea "$repo" run-recover candidate-1 "Recoverable")"
  before="$(jq -r '.status' "$repo/.e3d-pilot/ideas/$idea_id/idea.json")"
  set +e
  E3D_PILOT_CRASH_AFTER_EVENT=1 "$BIN" ideas transition --repo "$repo" "$idea_id" implementation_approved --actor tester@example.com >/dev/null 2>&1
  status=$?
  set -e
  [[ $status -eq 99 ]] || { printf 'expected simulated crash exit 99\n' >&2; exit 1; }
  [[ "$(jq -r '.status' "$repo/.e3d-pilot/ideas/$idea_id/idea.json")" == "$before" ]] || { printf 'snapshot should still reflect pre-crash state\n' >&2; exit 1; }
  "$BIN" ideas rebuild --repo "$repo" >/dev/null
  after="$(jq -r '.status' "$repo/.e3d-pilot/ideas/$idea_id/idea.json")"
  [[ "$after" == "approved_for_implementation" ]] || { printf 'rebuild did not recover appended event\n' >&2; exit 1; }
  rm -rf "$repo"
}

approval_digest_excludes_status_and_timestamps() {
  local repo idea_id digest_before digest_recorded digest_after
  repo="$(make_repo)"
  idea_id="$(new_idea "$repo" run-digest candidate-1 "Digest scoped")"
  digest_before="$(jq -cS '{
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
  }' "$repo/.e3d-pilot/ideas/$idea_id/idea.json" | sha256_stdin)"
  transition "$repo" "$idea_id" implementation_approved
  digest_recorded="$(jq -r '.implementation_approval.digest' "$repo/.e3d-pilot/ideas/$idea_id/idea.json")"
  digest_after="$(jq -cS '{
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
  }' "$repo/.e3d-pilot/ideas/$idea_id/idea.json" | sha256_stdin)"
  [[ "$digest_recorded" == "$digest_before" && "$digest_after" == "$digest_before" ]] || {
    printf 'approval digest changed across status/timestamp mutation\n' >&2
    exit 1
  }
  rm -rf "$repo"
}

concurrent_writers_append_complete_records() {
  local repo c1 c2 id1 id2
  repo="$(make_repo)"
  c1="$(mktemp)"; c2="$(mktemp)"
  candidate_json "$c1" "Concurrent one"
  candidate_json "$c2" "Concurrent two"
  "$BIN" ideas ingest --repo "$repo" --run-id run-concurrent --candidate-id candidate-1 --candidate-json "$c1" > "$repo/id1.out" &
  p1=$!
  "$BIN" ideas ingest --repo "$repo" --run-id run-concurrent --candidate-id candidate-2 --candidate-json "$c2" > "$repo/id2.out" &
  p2=$!
  wait "$p1"; wait "$p2"
  id1="$(cat "$repo/id1.out")"; id2="$(cat "$repo/id2.out")"
  [[ "$id1" != "$id2" ]] || { printf 'concurrent writers produced duplicate ids\n' >&2; exit 1; }
  [[ "$(event_count "$repo")" == 2 ]] || { printf 'expected two concurrent event records\n' >&2; exit 1; }
  jq -R -s -e 'split("\n")[:-1] | length == 2 and all(.[]; (fromjson | .event_id and .idea_id))' "$repo/.e3d-pilot/events.jsonl" >/dev/null
  [[ -f "$repo/.e3d-pilot/ideas/$id1/idea.json" && -f "$repo/.e3d-pilot/ideas/$id2/idea.json" ]] || {
    printf 'missing concurrent snapshots\n' >&2
    exit 1
  }
  rm -rf "$repo"; rm -f "$c1" "$c2"
}

malformed_stream_blocks_append() {
  local repo candidate before
  repo="$(make_repo)"
  candidate="$(mktemp)"
  candidate_json "$candidate" "Malformed guard"
  "$BIN" ideas ingest --repo "$repo" --run-id run-1 --candidate-id candidate-1 --candidate-json "$candidate" >/dev/null
  printf 'not-json\n' >> "$repo/.e3d-pilot/events.jsonl"
  before="$(event_count "$repo")"
  if "$BIN" ideas ingest --repo "$repo" --run-id run-2 --candidate-id candidate-2 --candidate-json "$candidate" >/dev/null 2>&1; then
    printf 'expected malformed stream to reject append\n' >&2
    exit 1
  fi
  [[ "$(event_count "$repo")" == "$before" ]] || { printf 'malformed stream append changed line count\n' >&2; exit 1; }
  rm -rf "$repo"; rm -f "$candidate"
}

fleet_root_materializes_under_fleet_workspace() {
  local fleet_dir fleet_file candidate idea_id
  fleet_dir="$(mktemp -d)"
  fleet_file="$fleet_dir/fleet.json"
  jq -n '[]' > "$fleet_file"
  candidate="$(mktemp)"
  candidate_json "$candidate" "Fleet ledger" "repo-a"
  idea_id="$("$BIN" fleet ideas "$fleet_file" ingest --run-id fleet-run --candidate-id candidate-1 --candidate-json "$candidate")"
  [[ -f "$fleet_dir/.e3d-pilot-fleet/events.jsonl" ]] || { printf 'missing fleet events stream\n' >&2; exit 1; }
  [[ -f "$fleet_dir/.e3d-pilot-fleet/ideas/$idea_id/idea.json" ]] || { printf 'missing fleet snapshot\n' >&2; exit 1; }
  [[ "$(jq -r '.workspace_kind' "$fleet_dir/.e3d-pilot-fleet/ideas/$idea_id/idea.json")" == "fleet" ]] || {
    printf 'wrong fleet workspace kind\n' >&2
    exit 1
  }
  rm -rf "$fleet_dir"; rm -f "$candidate"
}

main() {
  bash -n "$BIN"
  bash -n "$ROOT/lib/ideas/ledger.sh"
  idempotent_ingest
  distinct_candidates_get_distinct_ids
  allowed_transitions_succeed
  disallowed_transitions_do_not_mutate
  rebuild_recovers_after_append_before_snapshot
  approval_digest_excludes_status_and_timestamps
  concurrent_writers_append_complete_records
  malformed_stream_blocks_append
  fleet_root_materializes_under_fleet_workspace
  echo "phase12: all tests passed"
}

main "$@"
