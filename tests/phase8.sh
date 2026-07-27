#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"
SAMPLE_CONFIG="$ROOT/examples/sample-config.json"
PROVIDER_STUB="$ROOT/lib/providers/phase8-review"

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
  cat > "$repo/AGENTS.md" <<'EOF'
# Repo Notes

E3D Maps integration exists here.
EOF
  git -C "$repo" add README.md AGENTS.md
  git -C "$repo" commit -q -m "initial commit"
  printf '%s' "$repo"
}

install_review_provider_stub() {
  cat > "$PROVIDER_STUB" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
prompt_file="${1:?prompt file required}"
if [[ -n "${PHASE8_REVIEW_TRACE:-}" ]]; then
  cp "$prompt_file" "$PHASE8_REVIEW_TRACE"
fi
printf 'Independent review: scoped correctly and no obvious regression.\n'
EOF
  chmod +x "$PROVIDER_STUB"
}

cleanup_review_provider_stub() {
  rm -f "$PROVIDER_STUB"
}

write_phase8_config() {
  local repo="$1" backend="$2" verify_json="$3" live_verify_json="${4:-null}"
  mkdir -p "$repo/.e3d-pilot"
  jq \
    --arg backend "$backend" \
    --argjson verify "$verify_json" \
    --argjson live_verify "$live_verify_json" \
    '.verify = $verify
     | .pr.backend = $backend
     | .providers.review = "phase8-review"
     | if $live_verify == null then del(.live_verify) else .live_verify = $live_verify end' \
    "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
}

write_phase8_run_artifacts() {
  local repo="$1" run_id="$2"
  local run_dir="$repo/.e3d-pilot/runs/$run_id"
  mkdir -p "$run_dir/csr-state"
  cat > "$run_dir/findings.md" <<'EOF'
---
head_sha: deadbeef
---

# Findings

## Local State

Noisy but acceptable.

## External Context

Current users need a reviewable branch with audit artifacts.
EOF
  cat > "$run_dir/candidates.md" <<'EOF'
---
selected: candidate-1
reason: not already covered by existing branches or prior runs
---

# Candidates

### Candidate 1: Publish review artifacts
Duplicate: no
Dedup rationale: no matching branch or prior run output
Description: Commit the audit trail and prepare publication output.
EOF
  cat > "$run_dir/negotiation-log.md" <<'EOF'
# Negotiation Log

## Final Outcome

Converged in round 1.
EOF
  cat > "$run_dir/spec-final.md" <<'EOF'
# Review And Publish

## Phase 1 - Publish

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=README.md -->

### Requirements

- Exercise publish fixtures.

### Acceptance Criteria

- Audit artifacts are committed.
EOF
  cat > "$run_dir/csr-state/manifest.json" <<'EOF'
{"rows":[{"phase":1,"status":"ok"}]}
EOF
}

make_execute_like_worktree() {
  local repo="$1" run_id="$2" worktree
  worktree="$(mktemp -d)"
  git -C "$repo" worktree add -q -b "e3d-pilot/$run_id" "$worktree" HEAD
  printf '\nphase 8 diff\n' >> "$worktree/README.md"
  printf 'branch-only file\n' > "$worktree/CHANGELOG.md"
  printf 'e3d-pilot/%s\t%s\n' "$run_id" "$worktree" > "$repo/.e3d-pilot/runs/$run_id/execute-worktree.txt"
  printf '%s' "$worktree"
}

make_network_trace_bin_dir() {
  local bin_dir="$1" trace_file="$2" real_git real_gh
  mkdir -p "$bin_dir"
  real_git="$(command -v git)"
  cat > "$bin_dir/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "push" ]]; then
  printf 'git push %s\n' "\$*" >> "$trace_file"
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$bin_dir/git"

  real_gh="$(command -v gh 2>/dev/null || true)"
  cat > "$bin_dir/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "\$*" >> "$trace_file"
${real_gh:+exec "$real_gh" "\$@"}
EOF
  chmod +x "$bin_dir/gh"
}

review_verify_failure_blocks_publish() {
  local repo run_id out status trace_bin_dir trace_file
  repo="$(make_repo_with_commit)"
  run_id="2026-07-27-phase8-fail"
  write_phase8_config "$repo" "github" '["false"]'
  git -C "$repo" remote add origin "https://github.com/example/test-repo.git"
  write_phase8_run_artifacts "$repo" "$run_id"
  make_execute_like_worktree "$repo" "$run_id" >/dev/null

  set +e
  out="$("$BIN" run --repo "$repo" --stage review --run-id "$run_id" 2>&1)"
  status=$?
  set -e
  assert_eq "$status" "5" "verify failure should return review exit code"
  assert_contains "$out" "review: verify failed"

  trace_bin_dir="$(mktemp -d)"
  trace_file="$(mktemp)"
  make_network_trace_bin_dir "$trace_bin_dir" "$trace_file"

  set +e
  out="$(PATH="$trace_bin_dir:$PATH" "$BIN" run --repo "$repo" --stage publish --run-id "$run_id" 2>&1)"
  status=$?
  set -e
  assert_eq "$status" "1" "publish should refuse after verify failure"
  assert_contains "$out" "publish refused because verify did not pass"
  [[ ! -s "$trace_file" ]] || { echo "publish should not have attempted any git push or gh call: $(cat "$trace_file")" >&2; exit 1; }

  rm -rf "$trace_bin_dir"
  rm -f "$trace_file"
}

review_auto_detects_make_test_when_verify_empty() {
  local repo run_id worktree out
  repo="$(make_repo_with_commit)"
  run_id="2026-07-27-phase8-autodetect"
  write_phase8_config "$repo" "local" '[]'
  cat > "$repo/Makefile" <<'EOF'
test:
	@test -f README.md
EOF
  git -C "$repo" add Makefile
  git -C "$repo" commit -q -m "add make test"
  write_phase8_run_artifacts "$repo" "$run_id"
  worktree="$(make_execute_like_worktree "$repo" "$run_id")"

  out="$("$BIN" run --repo "$repo" --stage review --run-id "$run_id")"
  assert_contains "$out" "review: verification and independent review passed"
  assert_contains "$(cat "$repo/.e3d-pilot/runs/$run_id/review-verify-summary.md")" "make test"
  [[ -d "$worktree" ]] || { echo "expected worktree to remain for inspection" >&2; exit 1; }
}

local_publish_commits_audit_artifacts() {
  local repo run_id worktree bin_dir out tree summary commands status_text trace_bin_dir trace_file
  repo="$(make_repo_with_commit)"
  run_id="2026-07-27-phase8-local"
  write_phase8_config "$repo" "local" '["test -f README.md"]' '{"command":"e3d-agent verify-live"}'
  write_phase8_run_artifacts "$repo" "$run_id"
  worktree="$(make_execute_like_worktree "$repo" "$run_id")"

  bin_dir="$(mktemp -d)"
  cat > "$bin_dir/e3d-agent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'live verify\n' > .live-verify.txt
EOF
  chmod +x "$bin_dir/e3d-agent"

  PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage review --run-id "$run_id" >/dev/null
  status_text="$(cat "$repo/.e3d-pilot/runs/$run_id/review-status.txt")"
  commands="$(cat "$repo/.e3d-pilot/runs/$run_id/review-verify-summary.md")"
  assert_contains "$status_text" "live_verify: included"
  assert_contains "$commands" "e3d-agent verify-live"
  [[ -f "$worktree/.live-verify.txt" ]] || { echo "expected live verify marker in worktree" >&2; exit 1; }

  trace_bin_dir="$(mktemp -d)"
  trace_file="$(mktemp)"
  make_network_trace_bin_dir "$trace_bin_dir" "$trace_file"

  out="$(PATH="$bin_dir:$trace_bin_dir:$PATH" "$BIN" run --repo "$repo" --stage publish --run-id "$run_id")"
  assert_contains "$out" "mode: local"
  [[ ! -s "$trace_file" ]] || { echo "local publish should never push or call gh: $(cat "$trace_file")" >&2; exit 1; }
  rm -rf "$trace_bin_dir"
  rm -f "$trace_file"
  summary="$(cat "$repo/.e3d-pilot/runs/$run_id/publish-summary.md")"
  assert_contains "$summary" ".e3d-pilot/runs/$run_id/findings.md"
  assert_contains "$summary" ".e3d-pilot/runs/$run_id/candidates.md"
  assert_contains "$summary" ".e3d-pilot/runs/$run_id/negotiation-log.md"
  assert_contains "$summary" ".e3d-pilot/runs/$run_id/spec-final.md"
  assert_contains "$summary" ".e3d-pilot/runs/$run_id/csr-manifest-rows.json"
  tree="$(git -C "$worktree" ls-tree -r --name-only HEAD)"
  assert_contains "$tree" ".e3d-pilot/runs/$run_id/findings.md"
  assert_contains "$tree" ".e3d-pilot/runs/$run_id/candidates.md"
  assert_contains "$tree" ".e3d-pilot/runs/$run_id/negotiation-log.md"
  assert_contains "$tree" ".e3d-pilot/runs/$run_id/spec-final.md"
  assert_contains "$tree" ".e3d-pilot/runs/$run_id/csr-manifest-rows.json"
}

github_publish_dry_run_prints_exact_commands() {
  local repo run_id worktree out tree
  repo="$(make_repo_with_commit)"
  run_id="2026-07-27-phase8-github"
  write_phase8_config "$repo" "auto" '["test -f README.md"]'
  git -C "$repo" remote add origin "https://github.com/example/test-repo.git"
  write_phase8_run_artifacts "$repo" "$run_id"
  worktree="$(make_execute_like_worktree "$repo" "$run_id")"

  "$BIN" run --repo "$repo" --stage review --run-id "$run_id" >/dev/null
  out="$(E3D_PILOT_GITHUB_DRY_RUN=1 "$BIN" run --repo "$repo" --stage publish --run-id "$run_id")"
  assert_contains "$out" "mode: dry-run"
  assert_contains "$out" "push_command: git -C"
  assert_contains "$out" "gh_command: gh pr create --draft"
  assert_contains "$out" "--base main"
  assert_contains "$out" "--head e3d-pilot/$run_id"
  tree="$(git -C "$worktree" ls-tree -r --name-only HEAD)"
  assert_contains "$tree" ".e3d-pilot/runs/$run_id/findings.md"
  assert_contains "$tree" ".e3d-pilot/runs/$run_id/csr-manifest-rows.json"
}

main() {
  install_review_provider_stub
  trap cleanup_review_provider_stub EXIT
  review_verify_failure_blocks_publish
  review_auto_detects_make_test_when_verify_empty
  local_publish_commits_audit_artifacts
  github_publish_dry_run_prints_exact_commands
}

main "$@"
