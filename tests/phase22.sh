#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"
SAMPLE_CONFIG="$ROOT/examples/sample-config.json"

# shellcheck source=../lib/ideas/ledger.sh
source "$ROOT/lib/ideas/ledger.sh"
# shellcheck source=../lib/ideas/project_tracking.sh
source "$ROOT/lib/ideas/project_tracking.sh"

# project_tracking.sh calls this bin/e3d-pilot helper; it's a one-line path
# join, so shim it here rather than sourcing the whole (non-library) entrypoint.
config_path_for_repo() {
  printf '%s/.e3d-pilot/config.json' "$1"
}

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

# Mirrors the real "E3D.ai Roadmap" board's Status field exactly:
# Backlog / Ready / In progress / In review / Done.
make_project_stub() {
  local bin_dir="$1" state="$2"
  mkdir -p "$bin_dir"
  jq -ncS '{
    project_id:"PVT_test",
    status_field_id:"PVTSSF_test",
    status_options:{"Backlog":"opt_backlog","Ready":"opt_ready","In progress":"opt_inprogress","In review":"opt_inreview","Done":"opt_done"},
    items:[]
  }' > "$state"
  cat > "$bin_dir/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${PHASE22_GH_STATE:?}"
trace="${PHASE22_GH_TRACE:?}"
printf '%s\n' "$*" >> "$trace"

get_flag() {
  local name="$1"; shift
  local prev=""
  for a in "$@"; do
    if [[ "$prev" == "$name" ]]; then printf '%s' "$a"; return 0; fi
    prev="$a"
  done
  return 1
}

[[ "${1:-}" == "project" ]] || { echo "unexpected gh call: $*" >&2; exit 1; }
sub="${2:-}"
shift 2

case "$sub" in
  view)
    jq -r '.project_id' "$state"
    ;;
  field-list)
    jq -c '{id:.status_field_id, name:"Status", options:(.status_options | to_entries | map({id:.value, name:.key}))}' "$state"
    ;;
  item-list)
    jqarg="$(get_flag --jq "$@" || true)"
    url="$(printf '%s' "$jqarg" | sed -n 's/.*content\.url=="\([^"]*\)".*/\1/p')"
    if [[ -n "$url" ]]; then
      jq -r --arg url "$url" '.items[] | select(.url==$url and (.archived|not)) | .id' "$state"
    fi
    ;;
  item-create)
    title="$(get_flag --title "$@")"
    body="$(get_flag --body "$@" || true)"
    id="PVTI_draft_$(jq '.items | length' "$state")"
    tmp="${state}.tmp.$$"
    jq --arg id "$id" --arg title "$title" --arg body "$body" \
      '.items += [{id:$id, title:$title, body:$body, url:null, status:null, archived:false}]' "$state" > "$tmp"
    mv "$tmp" "$state"
    printf '%s\n' "$id"
    ;;
  item-add)
    url="$(get_flag --url "$@")"
    id="PVTI_pr_$(jq '.items | length' "$state")"
    tmp="${state}.tmp.$$"
    jq --arg id "$id" --arg url "$url" \
      '.items += [{id:$id, title:null, url:$url, status:null, archived:false}]' "$state" > "$tmp"
    mv "$tmp" "$state"
    printf '%s\n' "$id"
    ;;
  item-edit)
    id="$(get_flag --id "$@")"
    option_id="$(get_flag --single-select-option-id "$@")"
    status_name="$(jq -r --arg oid "$option_id" '.status_options | to_entries[] | select(.value==$oid) | .key' "$state")"
    tmp="${state}.tmp.$$"
    jq --arg id "$id" --arg status "$status_name" \
      '(.items[] | select(.id==$id) | .status) = $status' "$state" > "$tmp"
    mv "$tmp" "$state"
    ;;
  item-archive)
    id="$(get_flag --id "$@")"
    tmp="${state}.tmp.$$"
    jq --arg id "$id" '(.items[] | select(.id==$id) | .archived) = true' "$state" > "$tmp"
    mv "$tmp" "$state"
    ;;
  item-delete)
    id="$(get_flag --id "$@")"
    tmp="${state}.tmp.$$"
    jq --arg id "$id" '.items = [.items[] | select(.id!=$id)]' "$state" > "$tmp"
    mv "$tmp" "$state"
    ;;
  *)
    echo "unexpected gh project subcommand: $sub" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/gh"
}

make_repo() {
  local repo project_url="${1:-}"
  repo="$(mktemp -d)"
  git init -q "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test User"
  printf '# Phase 22 Repo\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m init
  mkdir -p "$repo/.e3d-pilot"
  if [[ -n "$project_url" ]]; then
    jq --arg url "$project_url" '.tracking = {project_url:$url} | .approval.implementation_required=false | .approval.merge_required=false' "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  else
    jq '.approval.implementation_required=false | .approval.merge_required=false' "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  fi
  printf '%s' "$repo"
}

ingest_idea() {
  local repo="$1" run_id="$2" title="$3" candidate
  candidate="$(mktemp)"
  jq -ncS --arg title "$title" '{
    title:$title,summary:"Phase 22 fixture.",scores:{attraction:3,retention:3,revenue:2,effort:"low"},
    category:"testing",dedup_rationale:"new",validation:{approvable:true,eligibility_reason:null,warnings:[]}
  }' > "$candidate"
  "$BIN" ideas ingest --repo "$repo" --run-id "$run_id" --candidate-id candidate-1 --candidate-json "$candidate"
  rm -f "$candidate"
}

state_item() {
  local state="$1" item_id="$2"
  jq -c --arg id "$item_id" '.items[] | select(.id==$id)' "$state"
}

tracking_not_configured_makes_no_gh_calls() {
  local repo idea bin_dir state trace
  repo="$(make_repo)"
  bin_dir="$(mktemp -d)"
  state="$(mktemp)"
  trace="$(mktemp)"
  make_project_stub "$bin_dir" "$state"

  idea="$(PHASE22_GH_STATE="$state" PHASE22_GH_TRACE="$trace" PATH="$bin_dir:$PATH" ingest_idea "$repo" run-1 "No tracking configured")"
  [[ ! -s "$trace" ]] || { echo "expected no gh calls when tracking is unconfigured: $(cat "$trace")" >&2; exit 1; }
  assert_eq "$(jq -r '.tracking.project_item_id // "null"' "$repo/.e3d-pilot/ideas/$idea/idea.json")" "null" "tracking stays unset"

  rm -rf "$bin_dir"; rm -f "$state" "$trace"
}

proposal_through_merge_updates_status_and_reuses_pr_item() {
  local repo bin_dir state trace idea idea_file
  bin_dir="$(mktemp -d)"
  state="$(mktemp)"
  trace="$(mktemp)"
  make_project_stub "$bin_dir" "$state"
  repo="$(make_repo "https://github.com/users/spacepacket1/projects/1")"

  idea="$(PHASE22_GH_STATE="$state" PHASE22_GH_TRACE="$trace" PATH="$bin_dir:$PATH" ingest_idea "$repo" run-2 "Full lifecycle idea")"
  idea_file="$repo/.e3d-pilot/ideas/$idea/idea.json"

  local item_id
  item_id="$(jq -r '.tracking.project_item_id' "$idea_file")"
  [[ "$item_id" == PVTI_draft_* ]] || { echo "expected a draft item on proposal, got $item_id" >&2; exit 1; }
  assert_eq "$(jq -r '.tracking.project_status' "$idea_file")" "Backlog" "proposed maps to Backlog"
  assert_eq "$(jq -r '.status' <<<"$(state_item "$state" "$item_id")")" "Backlog" "board reflects Backlog"

  PHASE22_GH_STATE="$state" PHASE22_GH_TRACE="$trace" PATH="$bin_dir:$PATH" \
    "$BIN" ideas approve --repo "$repo" "$idea" --actor approver@example.com >/dev/null
  assert_eq "$(jq -r '.tracking.project_status' "$idea_file")" "Ready" "approved maps to Ready"
  assert_eq "$(jq -r '.tracking.project_item_id' "$idea_file")" "$item_id" "same draft item reused across the whole pre-PR lifecycle"

  # Simulate implementation reaching a real PR: append the outcome directly
  # (implement's own execute/review pipeline is exercised in tests/phase16.sh
  # and tests/phase21.sh; this test is only about the tracking sync layer).
  local canonical outcome pr_url
  canonical="$(ideas_canonical_path "$repo")"
  pr_url="https://github.com/spacepacket1/e3d-applied/pull/1"
  ideas_transition repo "$canonical" "$idea" implementation_started approver@example.com "implementation started" "" "" >/dev/null
  outcome="$(mktemp)"
  jq -ncS --arg idea "$idea" --arg pr_url "$pr_url" '{
    type:"implementation", idea_id:$idea, status:"succeeded",
    targets:[{repo:"x", role:"primary", run_id:"run-x", status:"succeeded", publish_backend:"github", pr_url:$pr_url}]
  }' > "$outcome"
  ideas_transition repo "$canonical" "$idea" implementation_completed approver@example.com "implementation completed" "" "" "$outcome" >/dev/null
  rm -f "$outcome"
  PHASE22_GH_STATE="$state" PHASE22_GH_TRACE="$trace" PATH="$bin_dir:$PATH" project_tracking_sync_idea repo "$canonical" "$idea"

  local new_item_id
  new_item_id="$(jq -r '.tracking.project_item_id' "$idea_file")"
  [[ "$new_item_id" == PVTI_pr_* ]] || { echo "expected the draft to be swapped for a PR item, got $new_item_id" >&2; exit 1; }
  [[ "$new_item_id" != "$item_id" ]] || { echo "expected a different item id after the PR swap" >&2; exit 1; }
  assert_eq "$(jq -r '.tracking.project_status' "$idea_file")" "In review" "implemented maps to In review"
  assert_eq "$(jq -r --arg url "$pr_url" 'select(.url==$url) | .status' <<<"$(state_item "$state" "$new_item_id")")" "In review" "PR item carries the right status"
  assert_eq "$(jq -c --arg id "$item_id" '[.items[] | select(.id==$id)] | length' "$state")" "0" "stale draft item was deleted, not left behind"

  # implemented -> approved_for_merge -> merged; a plain array of targets is
  # sufficient here since this test drives the ledger directly to reach
  # "merged" and is only exercising the tracking-sync layer on top of it
  # (the real approve-merge/merge orchestration is covered by phase17.sh).
  ideas_transition repo "$canonical" "$idea" merge_approved approver@example.com "approve merge" "" "" >/dev/null
  local merge_outcome
  merge_outcome="$(mktemp)"
  jq -ncS --arg idea "$idea" '{type:"merge",idea_id:$idea,status:"succeeded",targets:[]}' > "$merge_outcome"
  ideas_transition repo "$canonical" "$idea" merge_completed approver@example.com "merge succeeded" "" "" "$merge_outcome" >/dev/null
  rm -f "$merge_outcome"
  PHASE22_GH_STATE="$state" PHASE22_GH_TRACE="$trace" PATH="$bin_dir:$PATH" project_tracking_sync_idea repo "$canonical" "$idea"
  assert_eq "$(jq -r '.tracking.project_status' "$idea_file")" "Done" "merged maps to Done"
  assert_eq "$(jq -r --arg url "$pr_url" 'select(.url==$url) | .status' <<<"$(state_item "$state" "$new_item_id")")" "Done" "board reflects Done"

  rm -rf "$bin_dir"; rm -f "$state" "$trace"
}

rejected_idea_gets_archived() {
  local repo bin_dir state trace idea idea_file item_id
  bin_dir="$(mktemp -d)"
  state="$(mktemp)"
  trace="$(mktemp)"
  make_project_stub "$bin_dir" "$state"
  repo="$(make_repo "https://github.com/users/spacepacket1/projects/1")"

  idea="$(PHASE22_GH_STATE="$state" PHASE22_GH_TRACE="$trace" PATH="$bin_dir:$PATH" ingest_idea "$repo" run-3 "Rejected idea")"
  idea_file="$repo/.e3d-pilot/ideas/$idea/idea.json"
  item_id="$(jq -r '.tracking.project_item_id' "$idea_file")"

  PHASE22_GH_STATE="$state" PHASE22_GH_TRACE="$trace" PATH="$bin_dir:$PATH" \
    "$BIN" ideas reject --repo "$repo" "$idea" --reason "not aligned" >/dev/null
  assert_eq "$(jq -r '.tracking.project_status' "$idea_file")" "Archived" "rejected archives the card"
  assert_eq "$(jq -r 'if .archived then "true" else "false" end' <<<"$(state_item "$state" "$item_id")")" "true" "board item is archived, not deleted"

  rm -rf "$bin_dir"; rm -f "$state" "$trace"
}

resync_is_idempotent_after_no_change() {
  local repo bin_dir state trace idea idea_file before after
  bin_dir="$(mktemp -d)"
  state="$(mktemp)"
  trace="$(mktemp)"
  make_project_stub "$bin_dir" "$state"
  repo="$(make_repo "https://github.com/users/spacepacket1/projects/1")"

  idea="$(PHASE22_GH_STATE="$state" PHASE22_GH_TRACE="$trace" PATH="$bin_dir:$PATH" ingest_idea "$repo" run-4 "Idempotent resync")"
  idea_file="$repo/.e3d-pilot/ideas/$idea/idea.json"
  before="$(wc -l < "$repo/.e3d-pilot/events.jsonl" | tr -d '[:space:]')"

  local canonical
  canonical="$(ideas_canonical_path "$repo")"
  PHASE22_GH_STATE="$state" PHASE22_GH_TRACE="$trace" PATH="$bin_dir:$PATH" project_tracking_sync_idea repo "$canonical" "$idea"
  after="$(wc -l < "$repo/.e3d-pilot/events.jsonl" | tr -d '[:space:]')"
  # Still appends a project_tracking_synced event (harmless metadata churn),
  # but must not issue another item-edit call when status is unchanged.
  local edit_calls
  edit_calls="$(grep -c '^project item-edit' "$trace" || true)"
  assert_eq "$edit_calls" "1" "no redundant status edit on an unchanged resync"

  rm -rf "$bin_dir"; rm -f "$state" "$trace"
}

tracking_survives_rebuild() {
  local repo bin_dir state trace idea idea_file item_id_before item_id_after
  bin_dir="$(mktemp -d)"
  state="$(mktemp)"
  trace="$(mktemp)"
  make_project_stub "$bin_dir" "$state"
  repo="$(make_repo "https://github.com/users/spacepacket1/projects/1")"

  idea="$(PHASE22_GH_STATE="$state" PHASE22_GH_TRACE="$trace" PATH="$bin_dir:$PATH" ingest_idea "$repo" run-5 "Rebuild-safe tracking")"
  idea_file="$repo/.e3d-pilot/ideas/$idea/idea.json"
  item_id_before="$(jq -r '.tracking.project_item_id' "$idea_file")"
  [[ -n "$item_id_before" && "$item_id_before" != "null" ]] || { echo "expected a tracked item before rebuild" >&2; exit 1; }

  "$BIN" ideas rebuild --repo "$repo" >/dev/null
  item_id_after="$(jq -r '.tracking.project_item_id' "$idea_file")"
  assert_eq "$item_id_after" "$item_id_before" "tracking state must survive ideas rebuild (it is event-sourced, not bolted on)"

  rm -rf "$bin_dir"; rm -f "$state" "$trace"
}

env_var_provides_default_project_url() {
  local repo bin_dir state trace idea
  bin_dir="$(mktemp -d)"
  state="$(mktemp)"
  trace="$(mktemp)"
  make_project_stub "$bin_dir" "$state"
  repo="$(make_repo)"

  idea="$(E3D_PILOT_TRACKING_PROJECT_URL="https://github.com/orgs/spacepacket1/projects/1" \
    PHASE22_GH_STATE="$state" PHASE22_GH_TRACE="$trace" PATH="$bin_dir:$PATH" ingest_idea "$repo" run-6 "Env var default")"
  assert_eq "$(jq -r '.tracking.project_status' "$repo/.e3d-pilot/ideas/$idea/idea.json")" "Backlog" "env var alone is enough to enable tracking"

  rm -rf "$bin_dir"; rm -f "$state" "$trace"
}

config_project_url_overrides_env_var() {
  local repo bin_dir state trace idea
  bin_dir="$(mktemp -d)"
  state="$(mktemp)"
  trace="$(mktemp)"
  make_project_stub "$bin_dir" "$state"
  repo="$(make_repo "https://github.com/users/spacepacket1/projects/1")"

  idea="$(E3D_PILOT_TRACKING_PROJECT_URL="https://github.com/users/someone-else/projects/9" \
    PHASE22_GH_STATE="$state" PHASE22_GH_TRACE="$trace" PATH="$bin_dir:$PATH" ingest_idea "$repo" run-7 "Config wins")"
  assert_contains "$(cat "$trace")" "--owner spacepacket1"
  [[ "$(cat "$trace")" != *"someone-else"* ]] || { echo "config.tracking.project_url must win over the env var default" >&2; exit 1; }

  rm -rf "$bin_dir"; rm -f "$state" "$trace"
}

malformed_project_url_warns_and_does_not_die() {
  local repo bin_dir state trace out status
  bin_dir="$(mktemp -d)"
  state="$(mktemp)"
  trace="$(mktemp)"
  make_project_stub "$bin_dir" "$state"
  repo="$(make_repo "not-a-valid-project-url")"

  set +e
  out="$(PHASE22_GH_STATE="$state" PHASE22_GH_TRACE="$trace" PATH="$bin_dir:$PATH" ingest_idea "$repo" run-8 "Bad url" 2>&1)"
  status=$?
  set -e
  [[ $status -eq 0 ]] || { echo "a malformed tracking URL must not fail the ingest command" >&2; exit 1; }
  [[ ! -s "$trace" ]] || { echo "no gh calls should be attempted for an unparseable url" >&2; exit 1; }

  rm -rf "$bin_dir"; rm -f "$state" "$trace"
}

main() {
  bash -n "$BIN"
  bash -n "$ROOT/lib/ideas/project_tracking.sh"
  tracking_not_configured_makes_no_gh_calls
  proposal_through_merge_updates_status_and_reuses_pr_item
  rejected_idea_gets_archived
  resync_is_idempotent_after_no_change
  tracking_survives_rebuild
  env_var_provides_default_project_url
  config_project_url_overrides_env_var
  malformed_project_url_warns_and_does_not_die
  echo "phase22: all tests passed"
}

main "$@"
