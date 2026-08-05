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
  printf '# Phase 17\n' > "$repo/README.md"
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
state="${PHASE17_GH_STATE:?}"
trace="${PHASE17_GH_TRACE:?}"
cmd="${1:-}"; shift || true
case "$cmd" in
  auth)
    [[ "${1:-}" == "status" ]] && exit 0
    ;;
  pr)
    sub="${1:-}"; shift || true
    case "$sub" in
      list)
        jq -c '[.prs[] | select(.state=="OPEN") | {url,isDraft,headRefName,number}]' "$state"
        exit 0
        ;;
      view)
        url="${1:-}"; shift || true
        jq -c --arg url "$url" '.prs[] | select(.url==$url) | {
          number,url,isDraft,headRefOid,baseRefName,state,
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
      review)
        printf 'REVIEW %s\n' "$*" >> "$trace"
        exit 0
        ;;
      merge)
        url="${1:-}"
        printf 'MERGE %s\n' "$url" >> "$trace"
        if jq -e --arg url "$url" '.fail_merge_url == $url' "$state" >/dev/null; then
          printf 'stub merge failed for %s\n' "$url" >&2
          exit 1
        fi
        sha="$(jq -r --arg url "$url" '.prs[] | select(.url==$url) | .plannedMergeSha' "$state")"
        tmp="${state}.tmp.$$"
        jq --arg url "$url" --arg sha "$sha" '(.prs[] | select(.url==$url) | .state)="MERGED" | (.prs[] | select(.url==$url) | .mergeSha)=$sha' "$state" > "$tmp"
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
  local file="$1"; shift
  jq -ncS --argjson prs "$1" --arg fail "${2:-}" '{prs:$prs} | if $fail != "" then .fail_merge_url=$fail else . end' > "$file"
}

ingest_idea() {
  local repo="$1" run_id="$2" title="$3" candidate
  candidate="$(mktemp)"
  jq -ncS --arg title "$title" '{
    title:$title,summary:"Merge-gated fixture.",scores:{attraction:3,retention:3,revenue:2,effort:"low"},
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

seed_implemented_fleet_idea() {
  local fleet="$1" idea="$2" repo1="$3" repo2="$4" url1="$5" url2="$6" head1="$7" head2="$8"
  local workspace actor="test@example.com" targets_file outcome
  workspace="$(cd "$(dirname "$fleet")" && pwd -P)"
  "$BIN" fleet ideas "$fleet" approve "$idea" --actor "$actor" >/dev/null
  ideas_transition fleet "$workspace" "$idea" implementation_started "$actor" "implementation started" "" "" >/dev/null
  targets_file="$(mktemp)"
  jq -ncS --arg repo "$repo1" --arg url "$url1" --arg head "$head1" '{
    repo:$repo,role:"primary",run_id:"run-1",approved_base_sha:"base",actual_start_sha:"base",
    base_branch:"main",branch:"e3d-pilot/run-1",worktree:null,commit_shas:[$head],
    changed_files:["README.md"],changed_lines:1,changed_file_count:1,
    verification:[{command:"test -f README.md",exit_status:0}],review_outcome:"passed",
    publish_backend:"github",pr_url:$url,pr_number:1,final_pr_head_sha:$head,status:"succeeded"
  }' > "$targets_file"
  jq -ncS --arg repo "$repo2" --arg url "$url2" --arg head "$head2" '{
    repo:$repo,role:"secondary",run_id:"run-2",approved_base_sha:"base",actual_start_sha:"base",
    base_branch:"main",branch:"e3d-pilot/run-2",worktree:null,commit_shas:[$head],
    changed_files:["README.md"],changed_lines:1,changed_file_count:1,
    verification:[{command:"test -f README.md",exit_status:0}],review_outcome:"passed",
    publish_backend:"github",pr_url:$url,pr_number:2,final_pr_head_sha:$head,status:"succeeded"
  }' >> "$targets_file"
  outcome="$(mktemp)"
  jq -ncS --arg idea "$idea" --slurpfile targets "$targets_file" '{type:"implementation",idea_id:$idea,status:"succeeded",targets:$targets}' > "$outcome"
  ideas_transition fleet "$workspace" "$idea" implementation_completed "$actor" "implementation completed" "" "" "$outcome" >/dev/null
  rm -f "$targets_file" "$outcome"
}

github_prs_json() {
  jq -ncS --arg url "$1" --arg head "$2" --argjson number "$3" --argjson draft "${4:-false}" '[{
    url:$url,number:$number,isDraft:$draft,headRefName:"e3d-pilot/run-impl",
    headRefOid:$head,baseRefName:"main",state:"OPEN",plannedMergeSha:("merge" + ($number|tostring))
  }]'
}

merge_without_approval_fails_before_gh_merge() {
  local repo idea state trace bin out status url head
  repo="$(make_repo)"; idea="$(ingest_idea "$repo" run-a "Needs merge approval")"
  url="https://github.com/example/repo/pull/1"; head="1111111111111111111111111111111111111111"
  seed_implemented_repo_idea "$repo" "$idea" "$url" 1 "$head"
  state="$(mktemp)"; trace="$(mktemp)"; bin="$(mktemp -d)"; make_gh_stub "$bin"; write_gh_state "$state" "$(github_prs_json "$url" "$head" 1 false)"
  set +e
  out="$(PHASE17_GH_STATE="$state" PHASE17_GH_TRACE="$trace" PATH="$bin:$PATH" "$BIN" ideas merge --repo "$repo" "$idea" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "merge without approval should fail" >&2; exit 1; }
  assert_contains "$out" "without current ledger approval"
  assert_eq "$(grep -c '^MERGE ' "$trace" || true)" "0" "no merge call without approval"
}

approved_unchanged_head_merges_and_records_sha() {
  local repo idea state trace bin url head out status_json
  repo="$(make_repo)"; idea="$(ingest_idea "$repo" run-b "Approved merge")"
  url="https://github.com/example/repo/pull/2"; head="2222222222222222222222222222222222222222"
  seed_implemented_repo_idea "$repo" "$idea" "$url" 2 "$head"
  state="$(mktemp)"; trace="$(mktemp)"; bin="$(mktemp -d)"; make_gh_stub "$bin"; write_gh_state "$state" "$(github_prs_json "$url" "$head" 2 true)"
  PHASE17_GH_STATE="$state" PHASE17_GH_TRACE="$trace" PATH="$bin:$PATH" "$BIN" ideas approve-merge --repo "$repo" "$idea" --actor reviewer@example.com >/dev/null
  out="$(PHASE17_GH_STATE="$state" PHASE17_GH_TRACE="$trace" PATH="$bin:$PATH" "$BIN" ideas merge --repo "$repo" "$idea")"
  assert_contains "$out" "ideas: merged $idea"
  status_json="$("$BIN" ideas show --repo "$repo" "$idea" --json)"
  assert_eq "$(jq -r '.status' <<<"$status_json")" "merged" "merged status"
  assert_eq "$(jq -r '.outcomes[-1].targets[0].merge_sha' <<<"$status_json")" "merge2" "observed merge sha"
  assert_eq "$(grep -c '^READY ' "$trace" || true)" "1" "draft marked ready during approval"
  assert_eq "$(grep -c '^MERGE ' "$trace" || true)" "1" "one merge call"
}

stale_head_blocks_before_merge_call() {
  local repo idea state trace bin url head out status
  repo="$(make_repo)"; idea="$(ingest_idea "$repo" run-c "Stale merge")"
  url="https://github.com/example/repo/pull/3"; head="3333333333333333333333333333333333333333"
  seed_implemented_repo_idea "$repo" "$idea" "$url" 3 "$head"
  state="$(mktemp)"; trace="$(mktemp)"; bin="$(mktemp -d)"; make_gh_stub "$bin"; write_gh_state "$state" "$(github_prs_json "$url" "$head" 3 false)"
  PHASE17_GH_STATE="$state" PHASE17_GH_TRACE="$trace" PATH="$bin:$PATH" "$BIN" ideas approve-merge --repo "$repo" "$idea" >/dev/null
  jq --arg url "$url" '(.prs[] | select(.url==$url) | .headRefOid)="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$state" > "$state.tmp"
  mv "$state.tmp" "$state"
  set +e
  out="$(PHASE17_GH_STATE="$state" PHASE17_GH_TRACE="$trace" PATH="$bin:$PATH" "$BIN" ideas merge --repo "$repo" "$idea" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "stale approval should fail" >&2; exit 1; }
  assert_contains "$out" "approval-stale"
  assert_eq "$(grep -c '^MERGE ' "$trace" || true)" "0" "no merge call after stale head"
}

github_review_does_not_authorize_merge() {
  local dir repo fleet idea state trace bin url head out status
  dir="$(mktemp -d)"; repo="$(make_repo)"; fleet="$dir/fleet.json"; jq -ncS --arg repo "$repo" '[$repo]' > "$fleet"
  idea="$(ingest_idea "$repo" run-d "Review is not approval")"
  url="https://github.com/example/repo/pull/4"; head="4444444444444444444444444444444444444444"
  seed_implemented_repo_idea "$repo" "$idea" "$url" 4 "$head"
  state="$(mktemp)"; trace="$(mktemp)"; bin="$(mktemp -d)"; make_gh_stub "$bin"; write_gh_state "$state" "$(github_prs_json "$url" "$head" 4 false)"
  PHASE17_GH_STATE="$state" PHASE17_GH_TRACE="$trace" PATH="$bin:$PATH" "$BIN" fleet prs "$fleet" --approve "$(basename "$repo")" >/dev/null
  set +e
  out="$(PHASE17_GH_STATE="$state" PHASE17_GH_TRACE="$trace" PATH="$bin:$PATH" "$BIN" ideas merge --repo "$repo" "$idea" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "GitHub review approval should not authorize merge" >&2; exit 1; }
  assert_contains "$out" "without current ledger approval"
}

fleet_second_merge_failure_records_partial() {
  local dir repo1 repo2 fleet idea state trace bin url1 url2 head1 head2 state_json out status idea_json candidate
  dir="$(mktemp -d)"; repo1="$(make_repo)"; repo2="$(make_repo)"; fleet="$dir/fleet.json"; jq -ncS --arg r1 "$repo1" --arg r2 "$repo2" '[$r1,$r2]' > "$fleet"
  candidate="$(mktemp)"
  jq -ncS --arg r1 "$repo1" --arg r2 "$repo2" '{title:"Fleet partial merge",summary:"Two targets.",repos:[$r1,$r2],scores:{attraction:3,retention:3,revenue:3,effort:"m"},category:"testing",dedup_rationale:"new",validation:{approvable:true,eligibility_reason:null,warnings:[]}}' > "$candidate"
  idea="$("$BIN" fleet ideas "$fleet" ingest --run-id fleet-run --candidate-id candidate-1 --candidate-json "$candidate")"
  rm -f "$candidate"
  url1="https://github.com/example/repo1/pull/1"; url2="https://github.com/example/repo2/pull/2"
  head1="5555555555555555555555555555555555555555"; head2="6666666666666666666666666666666666666666"
  seed_implemented_fleet_idea "$fleet" "$idea" "$repo1" "$repo2" "$url1" "$url2" "$head1" "$head2"
  state_json="$(jq -ncS --argjson a "$(github_prs_json "$url1" "$head1" 1 false)" --argjson b "$(github_prs_json "$url2" "$head2" 2 false)" '$a + $b')"
  state="$(mktemp)"; trace="$(mktemp)"; bin="$(mktemp -d)"; make_gh_stub "$bin"; write_gh_state "$state" "$state_json" "$url2"
  PHASE17_GH_STATE="$state" PHASE17_GH_TRACE="$trace" PATH="$bin:$PATH" "$BIN" fleet ideas "$fleet" approve-merge "$idea" >/dev/null
  set +e
  out="$(PHASE17_GH_STATE="$state" PHASE17_GH_TRACE="$trace" PATH="$bin:$PATH" "$BIN" fleet ideas "$fleet" merge "$idea" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "partial merge should return nonzero" >&2; exit 1; }
  assert_contains "$out" "merge partial"
  idea_json="$("$BIN" fleet ideas "$fleet" show "$idea" --json)"
  assert_eq "$(jq -r '.status' <<<"$idea_json")" "partially_merged" "partial status"
  assert_eq "$(jq -r '.outcomes[-1].targets[0].merge_sha' <<<"$idea_json")" "merge1" "first merge sha"
  assert_eq "$(jq -r '.outcomes[-1].targets[1].failure.stage' <<<"$idea_json")" "gh-pr-merge" "second failure recorded"
}

fleet_prs_merge_cannot_bypass_ledger() {
  local dir repo fleet idea state trace bin url head out status
  dir="$(mktemp -d)"; repo="$(make_repo)"; fleet="$dir/fleet.json"; jq -ncS --arg repo "$repo" '[$repo]' > "$fleet"
  idea="$(ingest_idea "$repo" run-e "Old merge bypass")"
  url="https://github.com/example/repo/pull/5"; head="7777777777777777777777777777777777777777"
  seed_implemented_repo_idea "$repo" "$idea" "$url" 5 "$head"
  state="$(mktemp)"; trace="$(mktemp)"; bin="$(mktemp -d)"; make_gh_stub "$bin"; write_gh_state "$state" "$(github_prs_json "$url" "$head" 5 false)"
  set +e
  out="$(PHASE17_GH_STATE="$state" PHASE17_GH_TRACE="$trace" PATH="$bin:$PATH" "$BIN" fleet prs "$fleet" --merge "$(basename "$repo")" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "fleet prs --merge should refuse without ledger approval" >&2; exit 1; }
  assert_contains "$out" "approve-merge"
  assert_eq "$(grep -c '^MERGE ' "$trace" || true)" "0" "old path should not merge"
}

merge_approved_only_processes_valid_approvals() {
  local dir repo1 repo2 fleet approved pending state trace bin url head out
  dir="$(mktemp -d)"; repo1="$(make_repo)"; repo2="$(make_repo)"; fleet="$dir/fleet.json"; jq -ncS --arg r1 "$repo1" --arg r2 "$repo2" '[$r1,$r2]' > "$fleet"
  approved="$(ingest_idea "$repo1" run-f "Approved queue")"
  pending="$(ingest_idea "$repo2" run-g "Implemented but not merge approved")"
  url="https://github.com/example/repo/pull/6"; head="8888888888888888888888888888888888888888"
  seed_implemented_repo_idea "$repo1" "$approved" "$url" 6 "$head"
  seed_implemented_repo_idea "$repo2" "$pending" "https://github.com/example/repo/pull/7" 7 "9999999999999999999999999999999999999999"
  state="$(mktemp)"; trace="$(mktemp)"; bin="$(mktemp -d)"; make_gh_stub "$bin"; write_gh_state "$state" "$(github_prs_json "$url" "$head" 6 false)"
  PHASE17_GH_STATE="$state" PHASE17_GH_TRACE="$trace" PATH="$bin:$PATH" "$BIN" ideas approve-merge --repo "$repo1" "$approved" >/dev/null
  out="$(PHASE17_GH_STATE="$state" PHASE17_GH_TRACE="$trace" PATH="$bin:$PATH" "$BIN" fleet ideas "$fleet" merge-approved)"
  assert_contains "$out" "no merge-approved"
  assert_eq "$(grep -c '^MERGE ' "$trace" || true)" "0" "repo approvals are not fleet approvals"
}

bash -n "$ROOT/bin/e3d-pilot"
bash -n "$ROOT/lib/ideas/ledger.sh"
merge_without_approval_fails_before_gh_merge
approved_unchanged_head_merges_and_records_sha
stale_head_blocks_before_merge_call
github_review_does_not_authorize_merge
fleet_second_merge_failure_records_partial
fleet_prs_merge_cannot_bypass_ledger
merge_approved_only_processes_valid_approvals

printf 'phase17 ok\n'
