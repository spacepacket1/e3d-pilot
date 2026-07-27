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

make_repo() {
  local repo
  repo="$(mktemp -d)"
  git init -q "$repo"
  printf '%s\n' "$repo"
}

# Phase 3's discover_stage requires a valid .e3d-pilot/config.json (to pick a
# provider and research_topics) and at least one commit (to have a HEAD sha).
# Bare make_repo() is intentionally still used by the config-validation tests
# above, which specifically exercise the *absence* of a config file.
make_repo_with_config() {
  local repo
  repo="$(mktemp -d)"
  git init -q "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test User"
  git -C "$repo" commit -q --allow-empty -m "initial commit"
  mkdir -p "$repo/.e3d-pilot"
  cp "$SAMPLE_CONFIG" "$repo/.e3d-pilot/config.json"
  printf '%s' "$repo"
}

make_fake_claude_bin() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
cat <<'OUT'
stubbed external context
---IDEATE-STATUS---
selected: candidate-1
reason: stubbed candidate
OUT
EOF
  chmod +x "$bin_dir/claude"
}

validate_missing_config() {
  local repo out
  repo="$(make_repo)"
  set +e
  out="$("$BIN" config validate "$repo" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { printf 'expected missing config to fail\n' >&2; exit 1; }
  assert_contains "$out" ".e3d-pilot/config.json"
}

validate_sample_config() {
  local repo config_path
  repo="$(make_repo)"
  mkdir -p "$repo/.e3d-pilot"
  cp "$SAMPLE_CONFIG" "$repo/.e3d-pilot/config.json"
  "$BIN" config validate "$repo" >/dev/null
}

help_lists_commands() {
  local out
  out="$("$BIN" --help)"
  assert_contains "$out" "config validate"
  assert_contains "$out" "run --repo"
  assert_contains "$out" "providers list"
  assert_contains "$out" "fleet <repos.json>"
}

discover_creates_distinct_runs() {
  local repo bin_dir first second
  repo="$(make_repo_with_config)"
  bin_dir="$(mktemp -d)"
  make_fake_claude_bin "$bin_dir"
  PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage discover >/dev/null
  first="$(cat "$repo/.e3d-pilot/latest-run")"
  [[ -d "$repo/.e3d-pilot/runs/$first" ]]
  PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage discover >/dev/null
  second="$(cat "$repo/.e3d-pilot/latest-run")"
  [[ -d "$repo/.e3d-pilot/runs/$second" ]]
  [[ "$first" != "$second" ]]
  rm -rf "$bin_dir"
}

explicit_run_id_resolves_latest() {
  local repo bin_dir older newer after
  repo="$(make_repo_with_config)"
  bin_dir="$(mktemp -d)"
  make_fake_claude_bin "$bin_dir"
  PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage discover >/dev/null
  older="$(cat "$repo/.e3d-pilot/latest-run")"
  PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage discover >/dev/null
  newer="$(cat "$repo/.e3d-pilot/latest-run")"
  PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage ideate --run-id "$older" >/dev/null
  after="$(cat "$repo/.e3d-pilot/latest-run")"
  [[ "$after" == "$newer" ]]
  [[ -d "$repo/.e3d-pilot/runs/$older" ]]
  rm -rf "$bin_dir"
}

explicit_run_id_on_new_discover_updates_latest() {
  local repo bin_dir chosen_id after
  repo="$(make_repo_with_config)"
  bin_dir="$(mktemp -d)"
  make_fake_claude_bin "$bin_dir"
  chosen_id="custom-run-id"
  PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage discover --run-id "$chosen_id" >/dev/null
  after="$(cat "$repo/.e3d-pilot/latest-run")"
  [[ "$after" == "$chosen_id" ]]
  [[ -d "$repo/.e3d-pilot/runs/$chosen_id" ]]
  rm -rf "$bin_dir"
}

main() {
  validate_missing_config
  validate_sample_config
  help_lists_commands
  discover_creates_distinct_runs
  explicit_run_id_resolves_latest
  explicit_run_id_on_new_discover_updates_latest
}

main "$@"
