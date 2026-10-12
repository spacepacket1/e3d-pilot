#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"
SAMPLE_CONFIG="$ROOT/examples/sample-config.json"

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

make_repo_with_commit() {
  local repo
  repo="$(mktemp -d)"
  git init -q "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test User"
  cat > "$repo/README.md" <<'EOF'
# Sample Repo
EOF
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m "initial commit"
  printf '%s' "$repo"
}

write_phase7_config() {
  local repo="$1" max_files="${2:-25}" max_lines="${3:-600}"
  mkdir -p "$repo/.e3d-pilot"
  jq \
    --argjson max_files "$max_files" \
    --argjson max_lines "$max_lines" \
    '.max_diff_files = $max_files | .max_diff_lines = $max_lines
     | .approval.implementation_required = false | .approval.merge_required = false' \
    "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
}

write_phase7_spec_final() {
  local repo="$1" run_id="$2" touches="$3"
  mkdir -p "$repo/.e3d-pilot/runs/$run_id"
  cat > "$repo/.e3d-pilot/runs/$run_id/spec-final.md" <<EOF
# Execute Stage Spec

## Overview

Exercise execute-stage worktree behavior.

## Goals

- Run s2c from an isolated worktree.

## Non-Goals

- No-op beyond execute-stage test fixtures.

## Existing Files

- \`README.md\`

## Shared Constraints

- Keep the fixture minimal.

## Phase 1 - Update Readme

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=$touches -->

### Requirements

- Update files inside the worktree only.

### Acceptance Criteria

- The execute test can observe a branch-local diff.
EOF
}

make_fake_s2c_bin() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/spec2code" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

spec_path="${1:-}"
stage="${2:-}"
[[ -n "$spec_path" ]] || { echo "missing spec path" >&2; exit 1; }
[[ "$stage" == "all" ]] || { echo "expected stage=all" >&2; exit 1; }
[[ -f "$spec_path" ]] || { echo "spec not found: $spec_path" >&2; exit 1; }

if [[ -n "${FAKE_S2C_TRACE_FILE:-}" ]]; then
  printf '%s\n' "$PWD|$spec_path|$stage" >> "$FAKE_S2C_TRACE_FILE"
fi

mkdir -p .spec2code
printf '{"result":"ok"}\n' > .spec2code/manifest.json
printf 's2c summary\n' > .spec2code/summary.md

case "${FAKE_S2C_MODE:-small-diff}" in
  small-diff)
    printf '\nexecute stage touched the worktree\n' >> README.md
    printf 'worktree-only file\n' > CHANGELOG.md
    ;;
  huge-diff)
    i=1
    : > BIG_DIFF.md
    while [[ $i -le 20 ]]; do
      printf 'line %02d\n' "$i" >> BIG_DIFF.md
      i=$((i + 1))
    done
    ;;
  *)
    echo "unknown FAKE_S2C_MODE: ${FAKE_S2C_MODE:-}" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/spec2code"
}

execute_uses_isolated_worktree_and_copies_s2c_artifacts() {
  local repo run_id run_dir bin_dir out branch worktree worktree_record spec_copy trace_line trace_file primary_readme
  local trace_pwd trace_spec trace_stage
  local primary_head_before primary_branch_before primary_head_after primary_branch_after
  repo="$(make_repo_with_commit)"
  printf 'node_modules/\n' > "$repo/.gitignore"
  git -C "$repo" add .gitignore
  git -C "$repo" commit -q -m "ignore dependencies"
  mkdir -p "$repo/node_modules/.bin"
  printf 'installed dependency marker\n' > "$repo/node_modules/.bin/fixture-tool"
  write_phase7_config "$repo" 10 50
  run_id="2026-07-27-repo-execute-worktree"
  run_dir="$repo/.e3d-pilot/runs/$run_id"
  write_phase7_spec_final "$repo" "$run_id" "README.md"

  bin_dir="$(mktemp -d)"
  trace_file="$(mktemp)"
  make_fake_s2c_bin "$bin_dir"

  primary_head_before="$(git -C "$repo" rev-parse HEAD)"
  primary_branch_before="$(git -C "$repo" symbolic-ref --short HEAD)"

  out="$(PATH="$bin_dir:$PATH" FAKE_S2C_MODE="small-diff" FAKE_S2C_TRACE_FILE="$trace_file" "$BIN" run --repo "$repo" --stage execute --run-id "$run_id")"

  primary_head_after="$(git -C "$repo" rev-parse HEAD)"
  primary_branch_after="$(git -C "$repo" symbolic-ref --short HEAD)"

  branch="$(cut -f1 "$run_dir/execute-worktree.txt")"
  worktree_record="$(cut -f2 "$run_dir/execute-worktree.txt")"
  worktree="$(cd "$worktree_record" && pwd -P)"
  spec_copy="$worktree_record/.e3d-pilot/runs/$run_id/spec-final.md"
  trace_line="$(cat "$trace_file")"
  IFS='|' read -r trace_pwd trace_spec trace_stage <<<"$trace_line"
  primary_readme="$(cat "$repo/README.md")"

  assert_eq "$branch" "e3d-pilot/$run_id" "execute branch name"
  [[ -d "$worktree" ]] || { echo "expected execute worktree directory" >&2; exit 1; }
  [[ "$worktree" != "$repo" ]] || { echo "worktree should differ from primary repo checkout" >&2; exit 1; }
  [[ -f "$worktree/CHANGELOG.md" ]] || { echo "expected s2c changes in worktree" >&2; exit 1; }
  [[ -L "$worktree/node_modules" ]] || { echo "expected execute worktree to reuse installed root dependencies" >&2; exit 1; }
  assert_eq "$(cd "$(readlink "$worktree/node_modules")" && pwd -P)" "$(cd "$repo/node_modules" && pwd -P)" "worktree dependency symlink target"
  [[ ! -f "$repo/CHANGELOG.md" ]] || { echo "primary checkout should remain untouched" >&2; exit 1; }
  assert_contains "$primary_readme" "# Sample Repo"
  assert_eq "$primary_head_after" "$primary_head_before" "primary checkout HEAD sha should be unchanged"
  assert_eq "$primary_branch_after" "$primary_branch_before" "primary checkout should remain on its original branch"
  [[ "$primary_branch_after" != "e3d-pilot/$run_id" ]] || { echo "primary checkout should never be switched onto the execute branch" >&2; exit 1; }
  assert_eq "$(cd "$trace_pwd" && pwd -P)" "$worktree" "s2c working directory"
  assert_eq "$(cd "$(dirname "$trace_spec")" && pwd -P)/$(basename "$trace_spec")" "$(cd "$(dirname "$spec_copy")" && pwd -P)/$(basename "$spec_copy")" "s2c spec path"
  assert_eq "$trace_stage" "all" "s2c stage"
  assert_contains "$(cat "$run_dir/execute-s2c.command")" "$spec_copy"
  [[ -f "$run_dir/s2c-state/manifest.json" ]] || { echo "expected s2c manifest copy in run dir" >&2; exit 1; }
  [[ -f "$run_dir/s2c-state/summary.md" ]] || { echo "expected s2c summary copy in run dir" >&2; exit 1; }
  [[ -n "$(git -C "$repo" branch --list "e3d-pilot/$run_id")" ]] || { echo "expected execute branch to exist" >&2; exit 1; }
  assert_contains "$out" "execute: completed s2c run"

  rm -rf "$bin_dir" "$trace_file"
}

execute_reuses_nested_subpackage_node_modules() {
  local repo run_id run_dir bin_dir out worktree_record worktree
  repo="$(make_repo_with_commit)"
  printf 'node_modules/\n' > "$repo/.gitignore"
  git -C "$repo" add .gitignore
  git -C "$repo" commit -q -m "ignore dependencies"
  # No top-level node_modules at all -- a repo laid out as separate
  # sub-packages (server/, client/), the real shape this was written for.
  mkdir -p "$repo/server/node_modules/.bin" "$repo/client/node_modules/.bin"
  printf 'server dependency marker\n' > "$repo/server/node_modules/.bin/fixture-tool"
  printf 'client dependency marker\n' > "$repo/client/node_modules/.bin/fixture-tool"
  write_phase7_config "$repo" 10 50
  run_id="2026-07-27-repo-execute-nested-node-modules"
  run_dir="$repo/.e3d-pilot/runs/$run_id"
  write_phase7_spec_final "$repo" "$run_id" "README.md"

  bin_dir="$(mktemp -d)"
  make_fake_s2c_bin "$bin_dir"

  out="$(PATH="$bin_dir:$PATH" FAKE_S2C_MODE="small-diff" "$BIN" run --repo "$repo" --stage execute --run-id "$run_id")"

  worktree_record="$(cut -f2 "$run_dir/execute-worktree.txt")"
  worktree="$(cd "$worktree_record" && pwd -P)"

  [[ ! -e "$worktree/node_modules" ]] || { echo "no top-level node_modules exists in the repo; the worktree should not invent one" >&2; exit 1; }
  [[ -L "$worktree/server/node_modules" ]] || { echo "expected execute worktree to reuse installed server/node_modules" >&2; exit 1; }
  [[ -L "$worktree/client/node_modules" ]] || { echo "expected execute worktree to reuse installed client/node_modules" >&2; exit 1; }
  assert_eq "$(cd "$(readlink "$worktree/server/node_modules")" && pwd -P)" "$(cd "$repo/server/node_modules" && pwd -P)" "worktree server/node_modules symlink target"
  assert_eq "$(cd "$(readlink "$worktree/client/node_modules")" && pwd -P)" "$(cd "$repo/client/node_modules" && pwd -P)" "worktree client/node_modules symlink target"
  assert_contains "$out" "execute: completed s2c run"

  # The actual bug this symlinking exists to avoid reintroducing: a tracked
  # .gitignore pattern ending in "/" (set above) only matches real
  # directories, never a symlink, so `git add -A` (exactly what publish_stage
  # runs before committing) would otherwise happily stage these symlinks
  # into the real branch diff. ensure_worktree must also record an explicit,
  # non-slash-terminated local exclude entry for each one.
  if git -C "$worktree" add -A --dry-run 2>/dev/null | grep -q "node_modules"; then
    echo "a node_modules symlink would be staged by git add -A -- it must never enter the branch diff" >&2
    git -C "$worktree" add -A --dry-run >&2
    exit 1
  fi

  rm -rf "$bin_dir"
}

execute_rejects_protected_path_before_invoking_s2c() {
  local repo run_id bin_dir trace_file out status
  repo="$(make_repo_with_commit)"
  write_phase7_config "$repo" 10 50
  run_id="2026-07-27-repo-execute-protected"
  write_phase7_spec_final "$repo" "$run_id" "deploy/rollout.sh"

  bin_dir="$(mktemp -d)"
  trace_file="$(mktemp)"
  make_fake_s2c_bin "$bin_dir"

  set +e
  out="$(PATH="$bin_dir:$PATH" FAKE_S2C_TRACE_FILE="$trace_file" "$BIN" run --repo "$repo" --stage execute --run-id "$run_id" 2>&1)"
  status=$?
  set -e

  assert_eq "$status" "4" "protected-path rejection should request human review"
  assert_contains "$out" "rejected spec-final.md before s2c was invoked"
  assert_contains "$out" "protected_paths entry \"deploy/**\""
  [[ ! -s "$trace_file" ]] || { echo "s2c should not have been invoked" >&2; exit 1; }

  rm -rf "$bin_dir" "$trace_file"
}

execute_does_not_link_unignored_dependencies() {
  local repo run_id run_dir bin_dir out worktree
  repo="$(make_repo_with_commit)"
  mkdir -p "$repo/node_modules/.bin"
  printf 'unignored dependency marker\n' > "$repo/node_modules/.bin/fixture-tool"
  write_phase7_config "$repo" 10 50
  run_id="2026-07-27-repo-execute-unignored-dependencies"
  run_dir="$repo/.e3d-pilot/runs/$run_id"
  write_phase7_spec_final "$repo" "$run_id" "README.md"

  bin_dir="$(mktemp -d)"
  make_fake_s2c_bin "$bin_dir"
  out="$(PATH="$bin_dir:$PATH" FAKE_S2C_MODE="small-diff" "$BIN" run --repo "$repo" --stage execute --run-id "$run_id")"
  worktree="$(cut -f2 "$run_dir/execute-worktree.txt")"

  [[ ! -e "$worktree/node_modules" ]] || { echo "unignored dependencies must not be linked into the execute diff" >&2; exit 1; }
  assert_contains "$out" "execute: completed s2c run"

  rm -rf "$bin_dir"
}

execute_stops_when_diff_exceeds_ceiling() {
  local repo run_id run_dir bin_dir out status summary
  repo="$(make_repo_with_commit)"
  write_phase7_config "$repo" 10 5
  run_id="2026-07-27-repo-execute-huge-diff"
  run_dir="$repo/.e3d-pilot/runs/$run_id"
  write_phase7_spec_final "$repo" "$run_id" "README.md"

  bin_dir="$(mktemp -d)"
  make_fake_s2c_bin "$bin_dir"

  set +e
  out="$(PATH="$bin_dir:$PATH" FAKE_S2C_MODE="huge-diff" "$BIN" run --repo "$repo" --stage execute --run-id "$run_id" 2>&1)"
  status=$?
  set -e

  summary="$(cat "$run_dir/execute-diff-summary.txt")"
  assert_eq "$status" "4" "oversized diff should request human review"
  assert_contains "$out" "diff exceeds configured ceiling"
  assert_contains "$summary" "diff_lines:"
  assert_contains "$summary" "max_diff_lines: 5"

  rm -rf "$bin_dir"
}

execute_respects_paused_file() {
  local repo run_id out status
  repo="$(make_repo_with_commit)"
  write_phase7_config "$repo" 10 50
  run_id="2026-07-27-repo-execute-paused"
  write_phase7_spec_final "$repo" "$run_id" "README.md"
  mkdir -p "$repo/.e3d-pilot"
  : > "$repo/.e3d-pilot/paused"

  set +e
  out="$("$BIN" run --repo "$repo" --stage execute --run-id "$run_id" 2>&1)"
  status=$?
  set -e

  assert_eq "$status" "1" "paused repo should refuse execute"
  assert_contains "$out" "execute is paused"
  assert_contains "$out" ".e3d-pilot/paused exists"
  [[ ! -f "$repo/.e3d-pilot/runs/$run_id/execute-worktree.txt" ]] || { echo "paused execute should not create a worktree" >&2; exit 1; }
}

write_phase7_all_stage_config() {
  local repo="$1" max_files="$2" max_lines="$3"
  mkdir -p "$repo/.e3d-pilot"
  jq \
    --argjson max_files "$max_files" \
    --argjson max_lines "$max_lines" \
    '.max_diff_files = $max_files | .max_diff_lines = $max_lines
     | .providers.discover = "claude" | .providers.ideate = "claude"
     | .providers.draft = "claude" | .providers.negotiate = ["claude"]
     | .approval.implementation_required = false | .approval.merge_required = false' \
    "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
}

make_fake_claude_bin_for_full_pipeline() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
prompt="$(cat)"

if grep -q -- 'the negotiate loop' <<<"$prompt"; then
  cat <<'OUT'
---STATUS---
status: approved
reason: fixture spec is already scoped correctly
OUT
elif grep -q -- 'the draft stage' <<<"$prompt"; then
  cat <<'OUT'
```spec
# Touch The Readme

## Overview

Touch the readme so execute has something to diff.

## Goals

- Exercise the full pipeline through execute.

## Non-Goals

- N/A

## Existing Files

- `README.md`

## Shared Constraints

- Keep this fixture minimal.

## Phase 1 - Touch Readme

<!-- runner:model=claude:sonnet -->
<!-- pilot:touches=README.md -->

### Requirements

- Touch the readme.

### Acceptance Criteria

- The readme changed.
```

---DRAFT-STATUS---
status: ok
reason: single small phase touching only the readme.
OUT
elif grep -q -- 'the ideate stage' <<<"$prompt"; then
  cat <<'OUT'
### Candidate 1: Touch the readme
Duplicate: no
Dedup rationale: no existing branch, PR, or past run covers this.
Description: Touch the readme so execute has a diff to enforce ceilings against.

---IDEATE-STATUS---
selected: candidate-1
reason: only candidate, not a duplicate.
OUT
else
  printf -- '- external context placeholder\n'
fi
EOF
  chmod +x "$bin_dir/claude"
}

execute_oversized_diff_halts_stage_all_before_review_and_publish() {
  local repo bin_dir s2c_bin_dir out status run_id run_dir
  repo="$(make_repo_with_commit)"
  write_phase7_all_stage_config "$repo" 10 5
  bin_dir="$(mktemp -d)"
  make_fake_claude_bin_for_full_pipeline "$bin_dir"
  s2c_bin_dir="$(mktemp -d)"
  make_fake_s2c_bin "$s2c_bin_dir"

  set +e
  out="$(PATH="$bin_dir:$s2c_bin_dir:$PATH" DRAFT_LINES_PER_REQUIREMENT_BULLET=0 FAKE_S2C_MODE="huge-diff" "$BIN" run --repo "$repo" --stage all 2>&1)"
  status=$?
  set -e

  run_id="$(cat "$repo/.e3d-pilot/latest-run")"
  run_dir="$repo/.e3d-pilot/runs/$run_id"

  assert_eq "$status" "4" "oversized diff via --stage all should request human review"
  assert_contains "$out" "diff exceeds configured ceiling"
  assert_contains "$out" "execute: human review required; stopping before review"
  [[ -f "$run_dir/spec-final.md" ]] || { echo "expected negotiate to have converged and written spec-final.md" >&2; exit 1; }
  [[ ! -f "$run_dir/review-status.txt" ]] || { echo "review stage should never have run" >&2; exit 1; }
  [[ ! -f "$run_dir/publish-summary.md" ]] || { echo "publish stage should never have run" >&2; exit 1; }
  [[ ! -f "$run_dir/publish-backend.out" ]] || { echo "publish backend should never have been invoked" >&2; exit 1; }

  rm -rf "$bin_dir" "$s2c_bin_dir"
}

main() {
  execute_uses_isolated_worktree_and_copies_s2c_artifacts
  execute_reuses_nested_subpackage_node_modules
  execute_does_not_link_unignored_dependencies
  execute_rejects_protected_path_before_invoking_s2c
  execute_stops_when_diff_exceeds_ceiling
  execute_respects_paused_file
  execute_oversized_diff_halts_stage_all_before_review_and_publish
}

main "$@"
