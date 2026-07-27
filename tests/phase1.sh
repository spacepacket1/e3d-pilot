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
  local repo first second
  repo="$(make_repo)"
  "$BIN" run --repo "$repo" --stage discover >/dev/null
  first="$(cat "$repo/.e3d-pilot/latest-run")"
  [[ -d "$repo/.e3d-pilot/runs/$first" ]]
  "$BIN" run --repo "$repo" --stage discover >/dev/null
  second="$(cat "$repo/.e3d-pilot/latest-run")"
  [[ -d "$repo/.e3d-pilot/runs/$second" ]]
  [[ "$first" != "$second" ]]
}

explicit_run_id_resolves_latest() {
  local repo older newer after
  repo="$(make_repo)"
  "$BIN" run --repo "$repo" --stage discover >/dev/null
  older="$(cat "$repo/.e3d-pilot/latest-run")"
  "$BIN" run --repo "$repo" --stage discover >/dev/null
  newer="$(cat "$repo/.e3d-pilot/latest-run")"
  "$BIN" run --repo "$repo" --stage ideate --run-id "$older" >/dev/null
  after="$(cat "$repo/.e3d-pilot/latest-run")"
  [[ "$after" == "$newer" ]]
  [[ -d "$repo/.e3d-pilot/runs/$older" ]]
}

explicit_run_id_on_new_discover_updates_latest() {
  local repo chosen_id after
  repo="$(make_repo)"
  chosen_id="custom-run-id"
  "$BIN" run --repo "$repo" --stage discover --run-id "$chosen_id" >/dev/null
  after="$(cat "$repo/.e3d-pilot/latest-run")"
  [[ "$after" == "$chosen_id" ]]
  [[ -d "$repo/.e3d-pilot/runs/$chosen_id" ]]
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

