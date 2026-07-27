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

TODO: replace this placeholder with actual content.
EOF
  cat > "$repo/AGENTS.md" <<'EOF'
# Repo Guidance

Follow the existing conventions.
EOF
  git -C "$repo" add README.md AGENTS.md
  git -C "$repo" commit -q -m "initial commit"
  printf '%s' "$repo"
}

write_discover_config() {
  local repo="$1"
  mkdir -p "$repo/.e3d-pilot"
  jq '.providers.discover = "claude" | .research_topics = "AI-assisted codebase research, repository triage"' \
    "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
}

make_fake_claude_bin() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
cat <<'OUT'
- Code search assistants are commonly paired with retrieval over repo-local context.
- Current practice favors concise, source-grounded summaries.
OUT
EOF
  chmod +x "$bin_dir/claude"
}

discover_writes_findings_and_skips_gh_without_remote() {
  local repo bin_dir out run_id findings contents head_sha
  repo="$(make_repo_with_commit)"
  write_discover_config "$repo"
  bin_dir="$(mktemp -d)"
  make_fake_claude_bin "$bin_dir"

  out="$(PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage discover)"
  run_id="$(cat "$repo/.e3d-pilot/latest-run")"
  findings="$repo/.e3d-pilot/runs/$run_id/findings.md"
  contents="$(cat "$findings")"
  head_sha="$(git -C "$repo" rev-parse HEAD)"

  assert_contains "$out" "$run_id"
  assert_contains "$contents" "head_sha: $head_sha"
  assert_contains "$contents" "## Local State"
  assert_contains "$contents" "## External Context"
  assert_contains "$contents" "skipped: no git remote configured"
  assert_contains "$contents" "TODO: replace this placeholder"
  assert_contains "$contents" "Code search assistants are commonly paired"
  [[ "$contents" != *"### gh issue list"* ]] || { echo "did not expect gh issue subsection without a remote" >&2; exit 1; }
  [[ "$contents" != *"### gh pr list"* ]] || { echo "did not expect gh pr subsection without a remote" >&2; exit 1; }
  rm -rf "$bin_dir"
}

discover_second_run_uses_previous_head_sha() {
  local repo bin_dir first_run_id second_run_id first_findings second_findings first_head_sha second_head_sha contents
  repo="$(make_repo_with_commit)"
  write_discover_config "$repo"
  bin_dir="$(mktemp -d)"
  make_fake_claude_bin "$bin_dir"

  PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage discover >/dev/null
  first_run_id="$(cat "$repo/.e3d-pilot/latest-run")"
  first_findings="$repo/.e3d-pilot/runs/$first_run_id/findings.md"
  first_head_sha="$(sed -n 's/^head_sha: //p' "$first_findings")"

  printf 'second commit\n' > "$repo/second.txt"
  git -C "$repo" add second.txt
  git -C "$repo" commit -q -m "second commit"

  PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage discover >/dev/null
  second_run_id="$(cat "$repo/.e3d-pilot/latest-run")"
  second_findings="$repo/.e3d-pilot/runs/$second_run_id/findings.md"
  second_head_sha="$(git -C "$repo" rev-parse HEAD)"
  contents="$(cat "$second_findings")"

  [[ "$first_run_id" != "$second_run_id" ]] || { echo "expected a new run id on the second discover run" >&2; exit 1; }
  [[ -d "$repo/.e3d-pilot/runs/$first_run_id" ]] || { echo "first run directory missing" >&2; exit 1; }
  [[ -d "$repo/.e3d-pilot/runs/$second_run_id" ]] || { echo "second run directory missing" >&2; exit 1; }
  assert_contains "$contents" "head_sha: $second_head_sha"
  assert_contains "$contents" "range: \`$first_head_sha..HEAD\`"
  assert_eq "$(cat "$repo/.e3d-pilot/latest-run")" "$second_run_id" "latest-run should point at the second discover run"
  rm -rf "$bin_dir"
}

main() {
  discover_writes_findings_and_skips_gh_without_remote
  discover_second_run_uses_previous_head_sha
  echo "phase3: all tests passed"
}

main "$@"
