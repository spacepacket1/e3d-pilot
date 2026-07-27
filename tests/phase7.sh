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
    '.max_diff_files = $max_files | .max_diff_lines = $max_lines' \
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

- Run csr from an isolated worktree.

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

make_fake_csr_bin() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex-spec-runner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

spec_path="${1:-}"
stage="${2:-}"
[[ -n "$spec_path" ]] || { echo "missing spec path" >&2; exit 1; }
[[ "$stage" == "all" ]] || { echo "expected stage=all" >&2; exit 1; }
[[ -f "$spec_path" ]] || { echo "spec not found: $spec_path" >&2; exit 1; }

if [[ -n "${FAKE_CSR_TRACE_FILE:-}" ]]; then
  printf '%s\n' "$PWD|$spec_path|$stage" >> "$FAKE_CSR_TRACE_FILE"
fi

mkdir -p .codex-spec-runner
printf '{"result":"ok"}\n' > .codex-spec-runner/manifest.json
printf 'csr summary\n' > .codex-spec-runner/summary.md

case "${FAKE_CSR_MODE:-small-diff}" in
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
    echo "unknown FAKE_CSR_MODE: ${FAKE_CSR_MODE:-}" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/codex-spec-runner"
}

execute_uses_isolated_worktree_and_copies_csr_artifacts() {
  local repo run_id run_dir bin_dir out branch worktree spec_copy trace_line trace_file primary_readme
  repo="$(make_repo_with_commit)"
  write_phase7_config "$repo" 10 50
  run_id="2026-07-27-repo-execute-worktree"
  run_dir="$repo/.e3d-pilot/runs/$run_id"
  write_phase7_spec_final "$repo" "$run_id" "README.md"

  bin_dir="$(mktemp -d)"
  trace_file="$(mktemp)"
  make_fake_csr_bin "$bin_dir"

  out="$(PATH="$bin_dir:$PATH" FAKE_CSR_MODE="small-diff" FAKE_CSR_TRACE_FILE="$trace_file" "$BIN" run --repo "$repo" --stage execute --run-id "$run_id")"

  branch="$(cut -f1 "$run_dir/execute-worktree.txt")"
  worktree="$(cut -f2 "$run_dir/execute-worktree.txt")"
  spec_copy="$worktree/.e3d-pilot/runs/$run_id/spec-final.md"
  trace_line="$(cat "$trace_file")"
  primary_readme="$(cat "$repo/README.md")"

  assert_eq "$branch" "e3d-pilot/$run_id" "execute branch name"
  [[ -d "$worktree" ]] || { echo "expected execute worktree directory" >&2; exit 1; }
  [[ "$worktree" != "$repo" ]] || { echo "worktree should differ from primary repo checkout" >&2; exit 1; }
  [[ -f "$worktree/CHANGELOG.md" ]] || { echo "expected csr changes in worktree" >&2; exit 1; }
  [[ ! -f "$repo/CHANGELOG.md" ]] || { echo "primary checkout should remain untouched" >&2; exit 1; }
  assert_contains "$primary_readme" "# Sample Repo"
  assert_contains "$trace_line" "$worktree|$spec_copy|all"
  assert_contains "$(cat "$run_dir/execute-csr.command")" "$spec_copy"
  [[ -f "$run_dir/csr-state/manifest.json" ]] || { echo "expected csr manifest copy in run dir" >&2; exit 1; }
  [[ -f "$run_dir/csr-state/summary.md" ]] || { echo "expected csr summary copy in run dir" >&2; exit 1; }
  [[ -n "$(git -C "$repo" branch --list "e3d-pilot/$run_id")" ]] || { echo "expected execute branch to exist" >&2; exit 1; }
  assert_contains "$out" "execute: completed csr run"

  rm -rf "$bin_dir" "$trace_file"
}

execute_rejects_protected_path_before_invoking_csr() {
  local repo run_id bin_dir trace_file out status
  repo="$(make_repo_with_commit)"
  write_phase7_config "$repo" 10 50
  run_id="2026-07-27-repo-execute-protected"
  write_phase7_spec_final "$repo" "$run_id" "deploy/rollout.sh"

  bin_dir="$(mktemp -d)"
  trace_file="$(mktemp)"
  make_fake_csr_bin "$bin_dir"

  set +e
  out="$(PATH="$bin_dir:$PATH" FAKE_CSR_TRACE_FILE="$trace_file" "$BIN" run --repo "$repo" --stage execute --run-id "$run_id" 2>&1)"
  status=$?
  set -e

  assert_eq "$status" "4" "protected-path rejection should request human review"
  assert_contains "$out" "rejected spec-final.md before csr was invoked"
  assert_contains "$out" "protected_paths entry \"deploy/**\""
  [[ ! -s "$trace_file" ]] || { echo "csr should not have been invoked" >&2; exit 1; }

  rm -rf "$bin_dir" "$trace_file"
}

execute_stops_when_diff_exceeds_ceiling() {
  local repo run_id run_dir bin_dir out status summary
  repo="$(make_repo_with_commit)"
  write_phase7_config "$repo" 10 5
  run_id="2026-07-27-repo-execute-huge-diff"
  run_dir="$repo/.e3d-pilot/runs/$run_id"
  write_phase7_spec_final "$repo" "$run_id" "README.md"

  bin_dir="$(mktemp -d)"
  make_fake_csr_bin "$bin_dir"

  set +e
  out="$(PATH="$bin_dir:$PATH" FAKE_CSR_MODE="huge-diff" "$BIN" run --repo "$repo" --stage execute --run-id "$run_id" 2>&1)"
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

main() {
  execute_uses_isolated_worktree_and_copies_csr_artifacts
  execute_rejects_protected_path_before_invoking_csr
  execute_stops_when_diff_exceeds_ceiling
  execute_respects_paused_file
}

main "$@"
