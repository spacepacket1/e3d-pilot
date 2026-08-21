#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"
SAMPLE_CONFIG="$ROOT/examples/sample-config.json"

assert_contains() { [[ "$1" == *"$2"* ]] || { printf 'expected to find %q in:\n%s\n' "$2" "$1" >&2; exit 1; }; }
assert_eq() { [[ "$1" == "$2" ]] || { printf 'expected %q, got %q (%s)\n' "$2" "$1" "${3:-}" >&2; exit 1; }; }

make_repo() {
  local repo
  repo="$(mktemp -d)"
  git init -q "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name 'Test User'
  printf '# Fixture\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m initial
  printf '%s' "$repo"
}

make_fake_claude() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
prompt="$(cat)"
if grep -q 'ideate stage' <<<"$prompt"; then
  cat <<'OUT'
### Candidate 1: Claude idea
Duplicate: no
Dedup rationale: not covered.
Category: other
Analogy: none
Attraction (1-5): 3
Retention (1-5): 3
Effort: low
Description: From claude.

---IDEATE-STATUS---
selected: candidate-1
reason: claude pick
OUT
elif grep -q 'review stage' <<<"$prompt"; then
  printf 'claude review comment\n'
else
  printf 'claude external context\n'
fi
EOF
  chmod +x "$dir/claude"
}

make_fake_codex() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# e3d-pilot's codex adapter execs `codex ... -` with prompt on stdin after flags.
prompt="$(cat)"
if grep -q 'ideate stage' <<<"$prompt"; then
  cat <<'OUT'
### Candidate 1: Codex idea
Duplicate: no
Dedup rationale: not covered.
Category: workflow
Analogy: none
Attraction (1-5): 5
Retention (1-5): 4
Effort: medium
Description: From codex.

---IDEATE-STATUS---
selected: candidate-1
reason: codex pick
OUT
elif grep -q 'review stage' <<<"$prompt"; then
  printf 'codex review comment\n'
else
  printf 'codex external context\n'
fi
EOF
  chmod +x "$dir/codex"
}

write_findings() {
  local repo="$1" run_id="$2"
  mkdir -p "$repo/.e3d-pilot/runs/$run_id"
  cat > "$repo/.e3d-pilot/runs/$run_id/findings.md" <<EOF
---
head_sha: $(git -C "$repo" rev-parse HEAD)
focus: default
---
# Findings
## Local State
- fixture
## External Context
- fixture
EOF
}

config_accepts_string_or_array_providers() {
  local repo
  repo="$(make_repo)"; mkdir -p "$repo/.e3d-pilot"
  jq '.providers.discover="claude"' "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  "$BIN" config validate "$repo" >/dev/null
  jq '.providers.discover=["claude","codex"] | .providers.ideate=["claude"] | .providers.review=["devin","claude"]' \
    "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  "$BIN" config validate "$repo" >/dev/null
  jq '.providers.discover=[]' "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  set +e
  out="$("$BIN" config validate "$repo" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo 'empty discover array should fail' >&2; exit 1; }
  assert_contains "$out" 'discover'
  rm -rf "$repo"
}

discover_runs_every_configured_provider() {
  local repo bin_dir run_id findings
  repo="$(make_repo)"; mkdir -p "$repo/.e3d-pilot"
  jq '.providers.discover=["claude","codex"]' "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  bin_dir="$(mktemp -d)"
  make_fake_claude "$bin_dir"
  make_fake_codex "$bin_dir"
  run_id=phase25-discover
  PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage discover --run-id "$run_id" >/dev/null
  findings="$repo/.e3d-pilot/runs/$run_id/findings.md"
  assert_contains "$(<"$findings")" '### Provider: claude'
  assert_contains "$(<"$findings")" 'claude external context'
  assert_contains "$(<"$findings")" '### Provider: codex'
  assert_contains "$(<"$findings")" 'codex external context'
  rm -rf "$repo" "$bin_dir"
}

ideate_merges_candidates_from_every_provider() {
  local repo bin_dir run_id candidates
  repo="$(make_repo)"; mkdir -p "$repo/.e3d-pilot"
  jq '.providers.ideate=["claude","codex"]' "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  run_id=phase25-ideate
  write_findings "$repo" "$run_id"
  bin_dir="$(mktemp -d)"
  make_fake_claude "$bin_dir"
  make_fake_codex "$bin_dir"
  PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage ideate --run-id "$run_id" >/dev/null
  candidates="$repo/.e3d-pilot/runs/$run_id/candidates.md"
  assert_contains "$(<"$candidates")" '### Candidate 1: Claude idea'
  assert_contains "$(<"$candidates")" 'Provider: claude'
  assert_contains "$(<"$candidates")" '### Candidate 2: Codex idea'
  assert_contains "$(<"$candidates")" 'Provider: codex'
  assert_contains "$(<"$candidates")" 'selected: candidate-1'
  rm -rf "$repo" "$bin_dir"
}

unavailable_provider_in_array_fails_fast() {
  local repo bin_dir run_id out status
  repo="$(make_repo)"; mkdir -p "$repo/.e3d-pilot"
  jq '.providers.discover=["claude","grok-build"]' "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  run_id=phase25-missing
  bin_dir="$(mktemp -d)"
  make_fake_claude "$bin_dir"
  set +e
  out="$(PATH="$bin_dir:$PATH" GROK_BUILD_BIN=/definitely/missing/grok "$BIN" run --repo "$repo" --stage discover --run-id "$run_id" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo 'missing array member should fail' >&2; exit 1; }
  assert_contains "$out" 'grok-build'
  assert_contains "$out" 'unavailable'
  rm -rf "$repo" "$bin_dir"
}

main() {
  config_accepts_string_or_array_providers
  discover_runs_every_configured_provider
  ideate_merges_candidates_from_every_provider
  unavailable_provider_in_array_fails_fast
  echo 'phase25: all tests passed'
}
main "$@"
