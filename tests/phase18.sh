#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"

# shellcheck source=../lib/ideas/ledger.sh
source "$ROOT/lib/ideas/ledger.sh"

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
  local repo
  repo="$(mktemp -d)"
  git init -q "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test User"
  printf '# Phase 18\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m "initial"
  git -C "$repo" remote add origin "https://github.com/example/$(basename "$repo").git"
  mkdir -p "$repo/.e3d-pilot"
  jq -ncS '{pr:{backend:"github",base_branch:"main"},approval:{implementation_required:true,merge_required:true}}' > "$repo/.e3d-pilot/config.json"
  printf '%s' "$repo"
}

make_gh_stub() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${PHASE18_GH_STATE:?}"
trace="${PHASE18_GH_TRACE:?}"
cmd="${1:-}"; shift || true
case "$cmd" in
  auth)
    [[ "${1:-}" == "status" ]] && exit 0
    ;;
  pr)
    sub="${1:-}"; shift || true
    case "$sub" in
      view)
        url="${1:-}"; shift || true
        jq -c --arg url "$url" '.prs[] | select(.url==$url) | {
          number,url,isDraft,headRefOid,baseRefName,state,closeReason,statusCheckRollup,
          mergeCommit:(if (.mergeSha // "") == "" then null else {oid:.mergeSha} end)
        }' "$state"
        exit 0
        ;;
      ready)
        url="${1:-}"
        printf 'READY %s\n' "$url" >> "$trace"
        tmp="${state}.tmp.$$"
        jq --arg url "$url" '(.prs[] | select(.url==$url) | .isDraft)=false' "$state" > "$tmp"
        mv "$tmp" "$state"
        exit 0
        ;;
    esac
    ;;
esac
printf 'unexpected gh call: %s %s\n' "$cmd" "$*" >&2
exit 1
EOF
  chmod +x "$bin_dir/gh"
}

write_gh_state() {
  local file="$1" prs="$2"
  jq -ncS --argjson prs "$prs" '{prs:$prs}' > "$file"
}

update_pr_state() {
  local file="$1" url="$2" jq_filter="$3"
  local tmp="${file}.tmp.$$"
  jq --arg url "$url" "$jq_filter" "$file" > "$tmp"
  mv "$tmp" "$file"
}

github_pr_json() {
  local url="$1" head="$2" number="$3" draft="${4:-false}" state="${5:-OPEN}" merge_sha="${6:-}" close_reason="${7:-}" checks="${8:-[]}"
  jq -ncS \
    --arg url "$url" \
    --arg head "$head" \
    --argjson number "$number" \
    --argjson draft "$draft" \
    --arg state "$state" \
    --arg merge_sha "$merge_sha" \
    --arg close_reason "$close_reason" \
    --argjson checks "$checks" '
    {
      url:$url,
      number:$number,
      isDraft:$draft,
      headRefName:"e3d-pilot/run-impl",
      headRefOid:$head,
      baseRefName:"main",
      state:$state,
      mergeSha:(if $merge_sha == "" then null else $merge_sha end),
      closeReason:(if $close_reason == "" then null else $close_reason end),
      statusCheckRollup:$checks
    }'
}

ingest_idea() {
  local repo="$1" run_id="$2" title="$3" candidate
  candidate="$(mktemp)"
  jq -ncS --arg title "$title" '{
    title:$title,summary:"Phase 7 fixture.",scores:{attraction:3,retention:3,revenue:2,effort:"low"},
    category:"testing",dedup_rationale:"new",validation:{approvable:true,eligibility_reason:null,warnings:[]}
  }' > "$candidate"
  "$BIN" ideas ingest --repo "$repo" --run-id "$run_id" --candidate-id candidate-1 --candidate-json "$candidate"
  rm -f "$candidate"
}

seed_implemented_repo_idea() {
  local repo="$1" idea="$2" pr_url="$3" pr_number="$4" head="$5"
  local actor="test@example.com" target outcome targets_file
  "$BIN" ideas approve --repo "$repo" "$idea" --actor "$actor" >/dev/null
  ideas_transition repo "$repo" "$idea" implementation_started "$actor" "implementation started" "" "" >/dev/null
  target="$(jq -ncS --arg repo "$repo" --arg pr_url "$pr_url" --arg head "$head" --argjson pr "$pr_number" '{
    repo:$repo,role:"primary",run_id:"run-impl",approved_base_sha:"base",actual_start_sha:"base",
    base_branch:"main",branch:"e3d-pilot/run-impl",worktree:null,commit_shas:[$head],
    changed_files:["README.md"],changed_lines:1,changed_file_count:1,
    verification:[{command:"test -f README.md",exit_status:0}],review_outcome:"passed",
    publish_backend:"github",pr_url:$pr_url,pr_number:$pr,final_pr_head_sha:$head,status:"succeeded"
  }')"
  targets_file="$(mktemp)"
  printf '%s\n' "$target" > "$targets_file"
  outcome="$(mktemp)"
  jq -ncS --arg idea "$idea" --slurpfile targets "$targets_file" '{type:"implementation",idea_id:$idea,status:"succeeded",targets:$targets}' > "$outcome"
  ideas_transition repo "$repo" "$idea" implementation_completed "$actor" "implementation completed" "" "" "$outcome" >/dev/null
  rm -f "$targets_file" "$outcome"
}

sync_noop_is_idempotent() {
  local repo idea url head state trace bin out again state_json idea_json
  repo="$(make_repo)"
  idea="$(ingest_idea "$repo" run-a "Sync noop")"
  url="https://github.com/example/repo/pull/1"
  head="1111111111111111111111111111111111111111"
  seed_implemented_repo_idea "$repo" "$idea" "$url" 1 "$head"
  state="$(mktemp)"; trace="$(mktemp)"; bin="$(mktemp -d)"
  make_gh_stub "$bin"
  state_json="$(jq -ncS --argjson pr "$(github_pr_json "$url" "$head" 1 false OPEN "" "" '[]')" '[$pr]')"
  write_gh_state "$state" "$state_json"
  out="$(PHASE18_GH_STATE="$state" PHASE18_GH_TRACE="$trace" PATH="$bin:$PATH" "$BIN" ideas sync --repo "$repo" "$idea")"
  assert_contains "$out" "changed=1"
  again="$(PHASE18_GH_STATE="$state" PHASE18_GH_TRACE="$trace" PATH="$bin:$PATH" "$BIN" ideas sync --repo "$repo" "$idea")"
  assert_contains "$again" "changed=0"
  assert_contains "$again" "noop=1"
  idea_json="$("$BIN" ideas show --repo "$repo" "$idea" --json)"
  assert_eq "$(jq -r '.forge.targets[0].head_sha' <<<"$idea_json")" "$head" "forge head materialized"
}

request_changes_and_sync_restore_changes_requested() {
  local repo idea url head state trace bin state_json current
  repo="$(make_repo)"
  idea="$(ingest_idea "$repo" run-b "Request changes")"
  url="https://github.com/example/repo/pull/2"
  head="2222222222222222222222222222222222222222"
  seed_implemented_repo_idea "$repo" "$idea" "$url" 2 "$head"
  state="$(mktemp)"; trace="$(mktemp)"; bin="$(mktemp -d)"
  make_gh_stub "$bin"
  state_json="$(jq -ncS --argjson pr "$(github_pr_json "$url" "$head" 2 false OPEN "" "" '[]')" '[$pr]')"
  write_gh_state "$state" "$state_json"
  PHASE18_GH_STATE="$state" PHASE18_GH_TRACE="$trace" PATH="$bin:$PATH" "$BIN" ideas approve-merge --repo "$repo" "$idea" >/dev/null
  "$BIN" ideas request-changes --repo "$repo" "$idea" --reason "needs revision" >/dev/null
  current="$("$BIN" ideas show --repo "$repo" "$idea" --json)"
  assert_eq "$(jq -r '.status' <<<"$current")" "changes_requested" "request changes status"
  assert_eq "$(jq -r '.merge_approval == null' <<<"$current")" "true" "merge approval cleared"
  assert_eq "$(jq -r '.changes_requested_review.reviewed_head_sha' <<<"$current")" "$head" "reviewed head recorded"
  PHASE18_GH_STATE="$state" PHASE18_GH_TRACE="$trace" PATH="$bin:$PATH" "$BIN" ideas approve-merge --repo "$repo" "$idea" >/dev/null
  update_pr_state "$state" "$url" '(.prs[] | select(.url==$url) | .headRefOid)="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
  PHASE18_GH_STATE="$state" PHASE18_GH_TRACE="$trace" PATH="$bin:$PATH" "$BIN" ideas sync --repo "$repo" "$idea" >/dev/null
  current="$("$BIN" ideas show --repo "$repo" "$idea" --json)"
  assert_eq "$(jq -r '.status' <<<"$current")" "changes_requested" "stale head restored source status"
  assert_eq "$(jq -r '.merge_approval == null' <<<"$current")" "true" "stale head invalidated merge approval"
}

external_merge_and_close_are_recorded() {
  local repo merged_idea closed_idea url1 url2 head1 head2 state trace bin merged_json closed_json state_json
  repo="$(make_repo)"
  merged_idea="$(ingest_idea "$repo" run-c "Merged outside pilot")"
  closed_idea="$(ingest_idea "$repo" run-d "Closed outside pilot")"
  url1="https://github.com/example/repo/pull/3"
  url2="https://github.com/example/repo/pull/4"
  head1="3333333333333333333333333333333333333333"
  head2="4444444444444444444444444444444444444444"
  seed_implemented_repo_idea "$repo" "$merged_idea" "$url1" 3 "$head1"
  seed_implemented_repo_idea "$repo" "$closed_idea" "$url2" 4 "$head2"
  state="$(mktemp)"; trace="$(mktemp)"; bin="$(mktemp -d)"
  make_gh_stub "$bin"
  state_json="$(jq -ncS \
    --argjson a "$(github_pr_json "$url1" "$head1" 3 false MERGED "merge-three" "" '[{"status":"COMPLETED","conclusion":"SUCCESS"}]')" \
    --argjson b "$(github_pr_json "$url2" "$head2" 4 false CLOSED "" "NOT_PLANNED" '[{"status":"COMPLETED","conclusion":"FAILURE"}]')" \
    '[$a,$b]')"
  write_gh_state "$state" "$state_json"
  update_pr_state "$state" "$url1" '(.prs[] | select(.url==$url) | .state)="OPEN" | (.prs[] | select(.url==$url) | .mergeSha)=null'
  PHASE18_GH_STATE="$state" PHASE18_GH_TRACE="$trace" PATH="$bin:$PATH" "$BIN" ideas approve-merge --repo "$repo" "$merged_idea" >/dev/null
  update_pr_state "$state" "$url1" '(.prs[] | select(.url==$url) | .state)="MERGED" | (.prs[] | select(.url==$url) | .mergeSha)="merge-three"'
  PHASE18_GH_STATE="$state" PHASE18_GH_TRACE="$trace" PATH="$bin:$PATH" "$BIN" ideas sync --repo "$repo" "$merged_idea" >/dev/null
  PHASE18_GH_STATE="$state" PHASE18_GH_TRACE="$trace" PATH="$bin:$PATH" "$BIN" ideas sync --repo "$repo" "$closed_idea" >/dev/null
  merged_json="$("$BIN" ideas show --repo "$repo" "$merged_idea" --json)"
  closed_json="$("$BIN" ideas show --repo "$repo" "$closed_idea" --json)"
  assert_eq "$(jq -r '.status' <<<"$merged_json")" "merged" "external merge status"
  assert_eq "$(jq -r '.outcomes[-1].type' <<<"$merged_json")" "merge_external" "external merge evidence"
  assert_eq "$(jq -r '.outcomes[-1].approval_present' <<<"$merged_json")" "true" "approval presence preserved"
  assert_eq "$(jq -r '.outcomes[-1].approval_matched_head' <<<"$merged_json")" "true" "approval exact head preserved"
  assert_eq "$(jq -r '.status' <<<"$closed_json")" "closed" "external closure status"
  assert_eq "$(jq -r '.outcomes[-1].prior_status' <<<"$closed_json")" "implemented" "closure prior status"
}

outcomes_are_typed_and_append_history() {
  local repo idea out json status url head
  repo="$(make_repo)"
  idea="$(ingest_idea "$repo" run-e "Outcome metrics")"
  url="https://github.com/example/repo/pull/6"
  head="6666666666666666666666666666666666666666"
  seed_implemented_repo_idea "$repo" "$idea" "$url" 6 "$head"
  "$BIN" ideas outcome --repo "$repo" "$idea" --window 7d --metric retained=true --metric installs=12 --metric segment=beta --note "week one" >/dev/null
  "$BIN" ideas outcome --repo "$repo" "$idea" --window 30d --metric installs=18 --metric retained=false >/dev/null
  set +e
  out="$("$BIN" ideas outcome --repo "$repo" "$idea" --window 7d --metric installs=1 --metric installs=2 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "duplicate metric keys should fail" >&2; exit 1; }
  assert_contains "$out" "duplicate metric keys"
  json="$("$BIN" ideas show --repo "$repo" "$idea" --json)"
  assert_eq "$(jq -r '.outcomes | map(select(.type=="metrics")) | length' <<<"$json")" "2" "metrics appended"
  assert_eq "$(jq -r '.outcomes_latest.installs.value' <<<"$json")" "18" "latest numeric outcome"
  assert_eq "$(jq -r '.outcomes_latest.retained.value' <<<"$json")" "false" "latest boolean outcome"
  assert_eq "$(jq -r '.outcomes_latest.segment.value' <<<"$json")" "beta" "string outcome retained"
}

mark_reverted_discovers_revert_commit() {
  local repo idea revert_sha idea_json url head state trace bin state_json
  repo="$(make_repo)"
  idea="$(ingest_idea "$repo" run-f "Reverted idea")"
  url="https://github.com/example/repo/pull/5"
  head="5555555555555555555555555555555555555555"
  seed_implemented_repo_idea "$repo" "$idea" "$url" 5 "$head"
  state="$(mktemp)"; trace="$(mktemp)"; bin="$(mktemp -d)"
  make_gh_stub "$bin"
  state_json="$(jq -ncS --argjson pr "$(github_pr_json "$url" "$head" 5 false OPEN "" "" '[]')" '[$pr]')"
  write_gh_state "$state" "$state_json"
  PHASE18_GH_STATE="$state" PHASE18_GH_TRACE="$trace" PATH="$bin:$PATH" "$BIN" ideas approve-merge --repo "$repo" "$idea" >/dev/null
  update_pr_state "$state" "$url" '(.prs[] | select(.url==$url) | .state)="MERGED" | (.prs[] | select(.url==$url) | .mergeSha)="merge-five"'
  PHASE18_GH_STATE="$state" PHASE18_GH_TRACE="$trace" PATH="$bin:$PATH" "$BIN" ideas sync --repo "$repo" "$idea" >/dev/null
  printf 'reverted change\n' >> "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m "Revert merge-five"
  revert_sha="$(git -C "$repo" rev-parse HEAD)"
  "$BIN" ideas mark-reverted --repo "$repo" "$idea" --reason "bad metrics" >/dev/null
  idea_json="$("$BIN" ideas show --repo "$repo" "$idea" --json)"
  assert_eq "$(jq -r '.status' <<<"$idea_json")" "reverted" "reverted status"
  assert_eq "$(jq -r '.outcomes[-1].revert_commit' <<<"$idea_json")" "$revert_sha" "revert commit discovered"
}

bash -n "$ROOT/bin/e3d-pilot"
bash -n "$ROOT/lib/ideas/ledger.sh"
sync_noop_is_idempotent
request_changes_and_sync_restore_changes_requested
external_merge_and_close_are_recorded
outcomes_are_typed_and_append_history
mark_reverted_discovers_revert_commit

printf 'phase18 ok\n'
