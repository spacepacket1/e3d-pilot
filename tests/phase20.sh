#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"
SAMPLE_CONFIG="$ROOT/examples/sample-config.json"
PROVIDER="$ROOT/lib/providers/phase20-provider"

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

cleanup() {
  rm -f "$PROVIDER"
}
trap cleanup EXIT

install_provider() {
  cat > "$PROVIDER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
prompt="${1:-}"
if [[ "${E3D_PILOT_CHECK:-0}" == "1" ]]; then
  printf 'available (phase20-provider)\n'
  exit 0
fi
case "$(basename "$prompt")" in
  discover-prompt.md)
    cat <<'OUT'
## External Context

### Monetization Signals

- Paid workflow analytics can expose revenue lift without changing checkout.

### Analogous Patterns

- Fintech dashboards: convert raw activity into operator-ready revenue signals.
OUT
    ;;
  ideate-prompt.md)
    cat <<'OUT'
### Candidate 1: Revenue Signal Snapshot
Duplicate: no
Category: selling
Analogy: Fintech dashboards convert account activity into actionable revenue signals.
Attraction (1-5): 4
Retention (1-5): 4
Revenue (1-5|n/a): 5
Effort: low
Dedup rationale: no existing branch, PR, or prior run records this snapshot.
Description: Add a small revenue signal line to the README so operators can validate the gated workflow.
---IDEATE-STATUS---
selected: candidate-1
reason: highest revenue candidate with low effort
OUT
    ;;
  draft-prompt.md)
    cat <<'OUT'
```spec
# Revenue Signal Snapshot

## Overview

Add a tiny observable revenue signal for the end-to-end safety test.

## Goals

- Update README.md through the approved implementation path.

## Non-Goals

- Do not touch protected paths.

## Existing Files

- `README.md`

## Shared Constraints

- Keep the diff small.

## Phase 1 - Add Revenue Signal

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=README.md -->
<!-- runner:verify=test -f README.md -->

### Requirements

- Append one revenue signal line to README.md.

### Acceptance Criteria

- README.md still exists.
```

---DRAFT-STATUS---
status: ok
reason: scoped to README
OUT
    ;;
  negotiate-*)
    cat <<'OUT'
---STATUS---
status: approved
reason: fixture approved
OUT
    ;;
  review-prompt.md)
    printf 'review ok\n'
    ;;
  *)
    printf 'unexpected prompt: %s\n' "$prompt" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$PROVIDER"
}

make_csr_stub() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex-spec-runner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--list" ]]; then
  exit 0
fi
spec="${1:?spec required}"
stage="${2:?stage required}"
[[ "$stage" == "all" && -f "$spec" ]] || exit 1
mkdir -p .codex-spec-runner
printf '{"phase":1,"status":"ok"}\n' > .codex-spec-runner/manifest.json
printf '\nRevenue signal: gated workflow produced this draft PR.\n' >> README.md
EOF
  chmod +x "$bin_dir/codex-spec-runner"
}

make_gh_stub() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${PHASE20_GH_STATE:?}"
trace="${PHASE20_GH_TRACE:?}"
cmd="${1:-}"; shift || true
case "$cmd" in
  auth)
    [[ "${1:-}" == "status" ]] && exit 0
    ;;
  pr)
    sub="${1:-}"; shift || true
    case "$sub" in
      create)
        base=""; head=""; title=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --base) base="${2:-}"; shift 2 ;;
            --head) head="${2:-}"; shift 2 ;;
            --title) title="${2:-}"; shift 2 ;;
            --body-file) shift 2 ;;
            --draft) shift ;;
            --label) shift 2 ;;
            *) shift ;;
          esac
        done
        number="$(jq '.prs | length + 1' "$state")"
        url="https://github.com/example/e2e/pull/${number}"
        oid="$(git rev-parse HEAD)"
        tmp="${state}.tmp.$$"
        jq --arg url "$url" --arg title "$title" --arg head "$head" --arg oid "$oid" --arg base "$base" --argjson number "$number" '
          .prs += [{
            url:$url,number:$number,title:$title,isDraft:true,headRefName:$head,
            headRefOid:$oid,baseRefName:$base,state:"OPEN",mergeSha:null,
            closeReason:null,statusCheckRollup:[],
            plannedMergeSha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
          }]
        ' "$state" > "$tmp"
        mv "$tmp" "$state"
        printf '%s\n' "$url"
        ;;
      view)
        url="${1:-}"; shift || true
        jq -c --arg url "$url" '.prs[] | select(.url==$url) | {
          number,url,isDraft,headRefOid,baseRefName,state,closeReason,statusCheckRollup,
          mergeCommit:(if (.mergeSha // "") == "" then null else {oid:.mergeSha} end)
        }' "$state"
        ;;
      ready)
        url="${1:-}"
        printf 'READY %s\n' "$url" >> "$trace"
        tmp="${state}.tmp.$$"
        jq --arg url "$url" '(.prs[] | select(.url==$url) | .isDraft)=false' "$state" > "$tmp"
        mv "$tmp" "$state"
        ;;
      merge)
        url="${1:-}"
        printf 'MERGE %s\n' "$url" >> "$trace"
        sha="$(jq -r --arg url "$url" '.prs[] | select(.url==$url) | .plannedMergeSha' "$state")"
        tmp="${state}.tmp.$$"
        jq --arg url "$url" --arg sha "$sha" '(.prs[] | select(.url==$url) | .state)="MERGED" | (.prs[] | select(.url==$url) | .mergeSha)=$sha' "$state" > "$tmp"
        mv "$tmp" "$state"
        ;;
      *)
        printf 'unexpected gh pr subcommand: %s\n' "$sub" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    printf 'unexpected gh call: %s %s\n' "$cmd" "$*" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/gh"
}

make_repo() {
  local dir="$1" repo="$dir/repo" remote="$dir/origin.git"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" checkout -q -b main
  git -C "$repo" config user.email "phase20@example.com"
  git -C "$repo" config user.name "Phase 20"
  printf '# Phase 20 Repo\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m initial
  git init -q --bare "$remote"
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push -q -u origin main
  mkdir -p "$repo/.e3d-pilot"
  jq '.verify=["test -f README.md"]
      | .providers.discover="phase20-provider"
      | .providers.ideate="phase20-provider"
      | .providers.draft="phase20-provider"
      | .providers.negotiate=["phase20-provider"]
      | .providers.review="phase20-provider"
      | .pr.backend="github"
      | .pr.base_branch="main"
      | .pr.draft=true
      | .pr.labels=["e3d-pilot"]
      | del(.live_verify)' "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  printf '%s' "$repo"
}

selected_idea_id() {
  local repo="$1"
  "$BIN" ideas list --repo "$repo" --status proposed --json | jq -r 'map(select(.selected_by_model == true))[0].idea_id'
}

approval_gated_e2e() {
  local dir repo bin_dir state trace out status idea main_before main_after implemented pr_url head export_dir fleet
  dir="$(mktemp -d)"
  repo="$(make_repo "$dir")"
  bin_dir="$dir/bin"
  state="$dir/gh-state.json"
  trace="$dir/gh-trace.txt"
  jq -ncS '{prs:[]}' > "$state"
  : > "$trace"
  make_csr_stub "$bin_dir"
  make_gh_stub "$bin_dir"

  main_before="$(git -C "$repo" rev-parse main)"
  out="$(PHASE20_GH_STATE="$state" PHASE20_GH_TRACE="$trace" PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage all --focus revenue)"
  assert_contains "$out" "pending-approval"
  idea="$(selected_idea_id "$repo")"
  [[ "$idea" == idea-* ]] || { printf 'expected selected idea\n' >&2; exit 1; }
  assert_eq "$(jq -r '.status' "$repo/.e3d-pilot/ideas/$idea/idea.json")" "proposed" "autonomous run stops at proposal"
  assert_eq "$(git -C "$repo" rev-parse main)" "$main_before" "main unchanged before approval"
  assert_eq "$(jq '.prs | length' "$state")" "0" "no draft PR before approval"

  set +e
  out="$(PHASE20_GH_STATE="$state" PHASE20_GH_TRACE="$trace" PATH="$bin_dir:$PATH" "$BIN" ideas implement --repo "$repo" "$idea" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { printf 'implementation should require approval\n' >&2; exit 1; }
  assert_contains "$out" "cannot enter implementation from status: proposed"
  assert_eq "$(git -C "$repo" rev-parse main)" "$main_before" "main unchanged after refused implementation"

  "$BIN" ideas approve --repo "$repo" "$idea" --actor "operator@example.com" >/dev/null
  PHASE20_GH_STATE="$state" PHASE20_GH_TRACE="$trace" PATH="$bin_dir:$PATH" "$BIN" ideas implement --repo "$repo" "$idea" >/dev/null
  implemented="$("$BIN" ideas show --repo "$repo" "$idea" --json)"
  assert_eq "$(jq -r '.status' <<<"$implemented")" "implemented" "approved implementation reaches implemented"
  pr_url="$(jq -r '.outcomes[] | select(.type=="implementation") | .targets[0].pr_url' <<<"$implemented")"
  head="$(jq -r '.outcomes[] | select(.type=="implementation") | .targets[0].final_pr_head_sha' <<<"$implemented")"
  [[ "$pr_url" == https://github.com/*/pull/* ]] || { printf 'expected recorded PR URL\n' >&2; exit 1; }
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || { printf 'expected recorded head SHA\n' >&2; exit 1; }
  assert_eq "$(git -C "$repo" rev-parse main)" "$main_before" "main unchanged after draft PR publication"

  set +e
  out="$(PHASE20_GH_STATE="$state" PHASE20_GH_TRACE="$trace" PATH="$bin_dir:$PATH" "$BIN" ideas merge --repo "$repo" "$idea" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { printf 'merge should require approval\n' >&2; exit 1; }
  assert_contains "$out" "without current ledger approval"
  assert_eq "$(grep -c '^MERGE ' "$trace" || true)" "0" "no merge before merge approval"

  PHASE20_GH_STATE="$state" PHASE20_GH_TRACE="$trace" PATH="$bin_dir:$PATH" "$BIN" ideas approve-merge --repo "$repo" "$idea" --actor "merger@example.com" >/dev/null
  assert_eq "$(jq -r '.merge_approval.targets[0].head_sha' "$repo/.e3d-pilot/ideas/$idea/idea.json")" "$head" "merge approval is head-bound"
  jq --arg url "$pr_url" '(.prs[] | select(.url==$url) | .headRefOid)="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$state" > "$state.tmp"
  mv "$state.tmp" "$state"
  PHASE20_GH_STATE="$state" PHASE20_GH_TRACE="$trace" PATH="$bin_dir:$PATH" "$BIN" ideas sync --repo "$repo" "$idea" >/dev/null
  assert_eq "$(jq -r '.merge_approval == null' "$repo/.e3d-pilot/ideas/$idea/idea.json")" "true" "sync invalidates stale head approval"
  assert_eq "$(grep -c '^MERGE ' "$trace" || true)" "0" "stale head did not merge"

  PHASE20_GH_STATE="$state" PHASE20_GH_TRACE="$trace" PATH="$bin_dir:$PATH" "$BIN" ideas approve-merge --repo "$repo" "$idea" --actor "merger@example.com" >/dev/null
  PHASE20_GH_STATE="$state" PHASE20_GH_TRACE="$trace" PATH="$bin_dir:$PATH" "$BIN" ideas merge --repo "$repo" "$idea" >/dev/null
  main_after="$(git -C "$repo" rev-parse main)"
  assert_eq "$main_after" "$main_before" "local base branch remains untouched by stubbed forge merge"
  assert_eq "$(jq -r '.status' "$repo/.e3d-pilot/ideas/$idea/idea.json")" "merged" "merge recorded"
  "$BIN" ideas outcome --repo "$repo" "$idea" --window 7d --metric revenue_lift=12 --metric retained=true --note "week one" >/dev/null

  fleet="$dir/fleet.json"
  jq -ncS --arg repo "$repo" '{repos:[$repo],training:{min_reviewed_ideas:1,min_implemented_ideas:1,require_negative_examples:false,outcome_windows:["7d"]}}' > "$fleet"
  export_dir="$dir/export"
  "$BIN" fleet train export "$fleet" --week 2026-W32 --output "$export_dir" >/dev/null
  assert_eq "$(jq -R -s --arg id "$idea" '[split("\n")[] | select(length>0) | fromjson | select(.idea_id==$id and .label.decision=="approved")] | length' "$export_dir/ideation.jsonl")" "1" "export includes approved ideation label"
  assert_eq "$(jq -R -s --arg id "$idea" '[split("\n")[] | select(length>0) | fromjson | select(.idea_id==$id and (.delivery.merge | length > 0) and (.delivery.outcomes | length > 0))] | length' "$export_dir/implementation.jsonl")" "1" "export includes complete implementation history"
}

legacy_materialization_stays_proposed() {
  local repo run_id idea
  repo="$(mktemp -d)"
  git init -q "$repo"
  git -C "$repo" checkout -q -b main
  git -C "$repo" config user.email "legacy@example.com"
  git -C "$repo" config user.name "Legacy"
  printf '# Legacy\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m initial
  mkdir -p "$repo/.e3d-pilot/runs/legacy-run" "$repo/.e3d-pilot"
  jq '.providers.discover="phase20-provider" | .providers.ideate="phase20-provider" | .pr.backend="local" | del(.live_verify)' "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  run_id="legacy-run"
  printf -- '---\nhead_sha: %s\n---\n\n# Findings\n' "$(git -C "$repo" rev-parse HEAD)" > "$repo/.e3d-pilot/runs/$run_id/findings.md"
  cat > "$repo/.e3d-pilot/runs/$run_id/candidates.md" <<'EOF'
---
selected: candidate-1
reason: legacy selected candidate
focus: revenue
---

# Candidates

## Proposed Candidates

### Candidate 1: Legacy Selected Candidate
Duplicate: no
Category: selling
Analogy: migration record
Attraction (1-5): 3
Retention (1-5): 3
Revenue (1-5|n/a): 4
Effort: low
Dedup rationale: legacy candidate materialized explicitly
Description: Existing selected candidate from before approval gates.
EOF
  "$BIN" run --repo "$repo" --stage ideate --run-id "$run_id" >/dev/null
  idea="$(selected_idea_id "$repo")"
  assert_eq "$(jq -r '.status' "$repo/.e3d-pilot/ideas/$idea/idea.json")" "proposed" "legacy materialization remains proposed"
  assert_eq "$(jq -r '.implementation_approval == null' "$repo/.e3d-pilot/ideas/$idea/idea.json")" "true" "legacy materialization does not approve"
}

spec_runner_parses_phase_tiers() {
  if command -v codex-spec-runner >/dev/null 2>&1; then
    local out
    out="$(codex-spec-runner "$ROOT/docs/approval-gated-idea-lifecycle.md" --list)"
    assert_contains "$out" "Phase 9"
  fi
}

install_provider
bash -n "$ROOT/bin/e3d-pilot"
bash -n "$ROOT/lib/ideas/ledger.sh"
bash -n "$ROOT/lib/ideas/materialize.sh"
bash -n "$ROOT/lib/training/export.sh"
bash -n "$0"
approval_gated_e2e
legacy_materialization_stays_proposed
spec_runner_parses_phase_tiers

printf 'phase20 ok\n'
