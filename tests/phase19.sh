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
  local parent="$1" name="$2" repo
  repo="$parent/$name"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test User"
  printf '# %s\n' "$name" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m init
  mkdir -p "$repo/.e3d-pilot"
  jq -ncS '{pr:{backend:"github",base_branch:"main",draft:true,labels:[]},approval:{implementation_required:true,merge_required:true}}' > "$repo/.e3d-pilot/config.json"
  printf '%s' "$repo"
}

candidate_file() {
  local file="$1" title="$2" repo1="$3" repo2="${4:-}" summary="${5:-Synthetic idea.}"
  if [[ -n "$repo2" ]]; then
    jq -ncS --arg title "$title" --arg summary "$summary" --arg r1 "$repo1" --arg r2 "$repo2" '{
      focus:"revenue",title:$title,summary:$summary,repos:[$r1,$r2],
      scores:{attraction:4,retention:4,revenue:5,effort:"medium"},
      category:"integration",analogy:"marketplace",dedup_rationale:"synthetic",
      provenance:{provider:"stub",model:"qwen-test"},
      content_digests:{findings:"sha256:test"},
      validation:{approvable:true,eligibility_reason:null,warnings:[]}
    }' > "$file"
  else
    jq -ncS --arg title "$title" --arg summary "$summary" --arg r1 "$repo1" '{
      focus:"default",title:$title,summary:$summary,repos:[$r1],
      scores:{attraction:3,retention:3,revenue:2,effort:"low"},
      category:"repo",dedup_rationale:"synthetic",
      validation:{approvable:true,eligibility_reason:null,warnings:[]}
    }' > "$file"
  fi
}

fleet_ingest() {
  local fleet="$1" run="$2" candidate_id="$3" title="$4" repo1="$5" repo2="$6" summary="${7:-Synthetic idea.}" tmp
  tmp="$(mktemp)"
  candidate_file "$tmp" "$title" "$repo1" "$repo2" "$summary"
  "$BIN" fleet ideas "$fleet" ingest --run-id "$run" --candidate-id "$candidate_id" --candidate-json "$tmp"
  rm -f "$tmp"
}

repo_ingest() {
  local repo="$1" run="$2" candidate_id="$3" title="$4" summary="${5:-Repo idea.}" tmp
  tmp="$(mktemp)"
  candidate_file "$tmp" "$title" "$repo" "" "$summary"
  "$BIN" ideas ingest --repo "$repo" --run-id "$run" --candidate-id "$candidate_id" --candidate-json "$tmp"
  rm -f "$tmp"
}

implementation_targets() {
  local out="$1" repo1="$2" repo2="$3" head1="$4" head2="$5"
  jq -ncS --arg repo "$repo1" --arg head "$head1" '{
    repo:$repo,role:"primary",run_id:"run-impl-1",approved_base_sha:"base",actual_start_sha:"base",
    base_branch:"main",branch:"e3d-pilot/run-1",worktree:null,commit_shas:[$head],
    changed_files:["README.md"],changed_lines:1,changed_file_count:1,
    verification:[{command:"test -f README.md",exit_status:0}],review_outcome:"passed",
    publish_backend:"github",pr_url:"https://github.com/example/a/pull/1",pr_number:1,final_pr_head_sha:$head,status:"succeeded"
  }' > "$out"
  jq -ncS --arg repo "$repo2" --arg head "$head2" '{
    repo:$repo,role:"secondary",run_id:"run-impl-2",approved_base_sha:"base",actual_start_sha:"base",
    base_branch:"main",branch:"e3d-pilot/run-2",worktree:null,commit_shas:[$head],
    changed_files:["README.md"],changed_lines:2,changed_file_count:1,
    verification:[{command:"test -f README.md",exit_status:0}],review_outcome:"passed",
    publish_backend:"github",pr_url:"https://github.com/example/b/pull/2",pr_number:2,final_pr_head_sha:$head,status:"succeeded"
  }' >> "$out"
}

seed_implemented_fleet() {
  local fleet="$1" workspace="$2" idea="$3" repo1="$4" repo2="$5" targets outcome merge_targets merge_out
  "$BIN" fleet ideas "$fleet" approve "$idea" --actor "approver@example.com" >/dev/null
  ideas_transition fleet "$workspace" "$idea" implementation_started "impl@example.com" "implementation started" "" "" >/dev/null
  targets="$(mktemp)"
  implementation_targets "$targets" "$repo1" "$repo2" "1111111111111111111111111111111111111111" "2222222222222222222222222222222222222222"
  outcome="$(mktemp)"
  jq -ncS --arg idea "$idea" --slurpfile targets "$targets" '{type:"implementation",idea_id:$idea,status:"succeeded",targets:$targets}' > "$outcome"
  ideas_transition fleet "$workspace" "$idea" implementation_completed "impl@example.com" "implementation completed" "" "" "$outcome" >/dev/null
  merge_targets="$(mktemp)"
  jq -s -cS 'map({repo,role,publish_backend,pr_url,pr_number,base_branch,head_sha:.final_pr_head_sha})' "$targets" > "$merge_targets"
  ideas_transition fleet "$workspace" "$idea" merge_approved "merger@example.com" "ship it" "$merge_targets" "" >/dev/null
  merge_out="$(mktemp)"
  jq -ncS --arg idea "$idea" --slurpfile targets "$merge_targets" '{type:"merge",idea_id:$idea,status:"succeeded",targets:($targets[0] | map(. + {status:"merged",merge_sha:"merge-sha"}))}' > "$merge_out"
  ideas_transition fleet "$workspace" "$idea" merge_completed "merger@example.com" "merge succeeded" "" "" "$merge_out" >/dev/null
  "$BIN" fleet ideas "$fleet" outcome "$idea" --window 7d --metric retained=true >/dev/null
  "$BIN" fleet ideas "$fleet" outcome "$idea" --window 30d --metric revenue=12 >/dev/null
  rm -f "$targets" "$outcome" "$merge_targets" "$merge_out"
}

mixed_synthetic_export_and_readiness() {
  local dir repo1 repo2 fleet workspace approved rejected pending repoidea export1 export2 out ready
  dir="$(mktemp -d)"
  repo1="$(make_repo "$dir" repo-a)"
  repo2="$(make_repo "$dir" repo-b)"
  fleet="$dir/fleet.json"
  jq -ncS --arg r1 "$repo1" --arg r2 "$repo2" '{
    repos:[$r1,$r2],
    training:{min_reviewed_ideas:2,min_implemented_ideas:1,require_negative_examples:true,outcome_windows:["7d","30d"]}
  }' > "$fleet"
  workspace="$(cd "$(dirname "$fleet")" && pwd -P)"

  approved="$(fleet_ingest "$fleet" fleet-run candidate-1 "Approved dataset idea" "$repo1" "$repo2" "Summary with api_key=sk-testsecret12345678901234567890")"
  rejected="$(fleet_ingest "$fleet" fleet-run candidate-2 "Rejected dataset idea" "$repo1" "$repo2")"
  pending="$(fleet_ingest "$fleet" fleet-run candidate-3 "Pending dataset idea" "$repo1" "$repo2" "-----BEGIN PRIVATE KEY----- abc -----END PRIVATE KEY-----")"
  seed_implemented_fleet "$fleet" "$workspace" "$approved" "$repo1" "$repo2"
  "$BIN" fleet ideas "$fleet" reject "$rejected" --reason "not aligned" --actor "rejecter@example.com" >/dev/null
  repoidea="$(repo_ingest "$repo1" repo-run candidate-1 "Repo ledger idea")"
  "$BIN" ideas reject --repo "$repo1" "$repoidea" --reason "repo negative" >/dev/null

  ready="$("$BIN" fleet train readiness "$fleet" --since 1970-01-01T00:00:00Z)"
  assert_eq "$(jq -r '.ready' <<<"$ready")" "true" "readiness should satisfy low thresholds"
  assert_eq "$(jq -r '.counts.proposed' <<<"$ready")" "4" "fleet plus repo proposals counted"
  assert_eq "$(jq -r '.counts.implementation_successes' <<<"$ready")" "1" "implementation success counted"
  assert_eq "$(jq -r '.counts.outcomes_7d' <<<"$ready")" "1" "7d outcome counted"

  export1="$dir/export-one"
  out="$("$BIN" fleet train export "$fleet" --week 2026-W32 --output "$export1")"
  assert_contains "$out" "ready=true"
  [[ -f "$export1/ideation.jsonl" && -f "$export1/preferences.jsonl" && -f "$export1/implementation.jsonl" && -f "$export1/manifest.json" ]] || {
    printf 'missing exported dataset files\n' >&2
    exit 1
  }
  assert_eq "$(jq -R -s --arg id "$pending" '[split("\n")[] | select(length>0) | fromjson | select(.idea_id==$id and (.label.decision // null)=="rejected")] | length' "$export1/ideation.jsonl")" "0" "pending must not be rejected"
  [[ "$(jq -R -s 'split("\n")[] | select(length>0) | fromjson | select(.idea_id|length>0) | .split' "$export1/ideation.jsonl" | sort -u | wc -l | tr -d ' ')" -ge 1 ]] || {
    printf 'expected split assignments\n' >&2
    exit 1
  }
  assert_eq "$(jq -R -s --arg id "$approved" '[split("\n")[] | select(length>0) | fromjson | select(.idea_id==$id) | .split] | unique | length' "$export1/ideation.jsonl" "$export1/implementation.jsonl")" "1" "cross-repo records stay in one split"
  [[ "$(wc -l < "$export1/preferences.jsonl" | tr -d ' ')" -ge 1 ]] || { printf 'expected explicit preference pair\n' >&2; exit 1; }
  [[ "$(wc -l < "$export1/implementation.jsonl" | tr -d ' ')" -ge 1 ]] || { printf 'expected implementation record\n' >&2; exit 1; }
  ! grep -R -E 'sk-testsecret|BEGIN PRIVATE KEY' "$export1" >/dev/null || { printf 'secret material leaked into dataset\n' >&2; exit 1; }
  [[ "$(jq -r '.files["ideation.jsonl"].sha256' "$export1/manifest.json")" == "$(shasum -a 256 "$export1/ideation.jsonl" | awk '{print $1}')" ]] || {
    printf 'manifest hash mismatch\n' >&2
    exit 1
  }

  export2="$dir/export-two"
  "$BIN" fleet train export "$fleet" --week 2026-W32 --output "$export2" >/dev/null
  for name in ideation.jsonl preferences.jsonl implementation.jsonl; do
    cmp -s "$export1/$name" "$export2/$name" || {
      printf 'non-reproducible export for %s\n' "$name" >&2
      exit 1
    }
  done
}

threshold_failures_do_not_block_export() {
  local dir repo fleet ready export_dir
  dir="$(mktemp -d)"
  repo="$(make_repo "$dir" repo)"
  fleet="$dir/fleet.json"
  jq -ncS --arg r "$repo" '{repos:[$r],training:{min_reviewed_ideas:30,min_implemented_ideas:10,require_negative_examples:true,outcome_windows:["7d","30d"]}}' > "$fleet"
  repo_ingest "$repo" repo-run candidate-1 "Only pending" >/dev/null
  ready="$("$BIN" fleet train readiness "$fleet" --since 1970-01-01T00:00:00Z)"
  assert_eq "$(jq -r '.ready' <<<"$ready")" "false" "high thresholds should fail"
  assert_contains "$ready" "min_reviewed_ideas"
  export_dir="$dir/threshold-export"
  "$BIN" fleet train export "$fleet" --week 2026-W32 --output "$export_dir" >/dev/null
  assert_eq "$(jq -r '.readiness.ready' "$export_dir/manifest.json")" "false" "export should include false readiness"
}

default_export_refuses_completed_dataset() {
  local dir repo fleet out status
  dir="$(mktemp -d)"
  repo="$(make_repo "$dir" repo)"
  fleet="$dir/fleet.json"
  jq -ncS --arg r "$repo" '{repos:[$r],training:{min_reviewed_ideas:0,min_implemented_ideas:0,require_negative_examples:false,outcome_windows:[]}}' > "$fleet"
  repo_ingest "$repo" repo-run candidate-1 "Default export" >/dev/null
  "$BIN" fleet train export "$fleet" --week 2026-W32 >/dev/null
  set +e
  out="$("$BIN" fleet train export "$fleet" --week 2026-W32 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { printf 'default export overwrite should fail\n' >&2; exit 1; }
  assert_contains "$out" "dataset already exists"
}

conflicting_ledgers_block_export() {
  local dir repo1 repo2 fleet tmp event out status
  dir="$(mktemp -d)"
  repo1="$(make_repo "$dir" repo-a)"
  repo2="$(make_repo "$dir" repo-b)"
  fleet="$dir/fleet.json"
  jq -ncS --arg r1 "$repo1" --arg r2 "$repo2" '{repos:[$r1,$r2],training:{min_reviewed_ideas:0,min_implemented_ideas:0,require_negative_examples:false,outcome_windows:[]}}' > "$fleet"
  repo_ingest "$repo1" repo-run candidate-1 "Conflict A" >/dev/null
  tmp="$(mktemp)"
  candidate_file "$tmp" "Conflict B" "$repo2"
  event="$(head -n1 "$repo1/.e3d-pilot/events.jsonl" | jq -cS --arg idea "idea-000000000000" --arg workspace "$repo2" '.idea_id=$idea | .workspace_path=$workspace | .candidate.title="Conflict B"')"
  printf '%s\n' "$event" > "$repo2/.e3d-pilot/events.jsonl"
  rm -f "$tmp"
  set +e
  out="$("$BIN" fleet train export "$fleet" --week 2026-W32 --output "$dir/conflict-export" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { printf 'conflicting ledgers should block export\n' >&2; exit 1; }
  assert_contains "$out" "conflicting records"
}

mixed_synthetic_export_and_readiness
threshold_failures_do_not_block_export
default_export_refuses_completed_dataset
conflicting_ledgers_block_export

printf 'phase19: ok\n'
