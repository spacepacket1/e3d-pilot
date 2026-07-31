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

assert_not_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" != *"$needle"* ]] || {
    printf 'did not expect to find %q in output\n' "$needle" >&2
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

write_config() {
  local repo="$1"
  mkdir -p "$repo/.e3d-pilot"
  jq '.providers.discover = "claude" | .providers.ideate = "claude"' "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
}

write_findings() {
  local repo="$1" run_id="$2" run_dir head_sha
  run_dir="$repo/.e3d-pilot/runs/$run_id"
  mkdir -p "$run_dir"
  head_sha="$(git -C "$repo" rev-parse HEAD)"
  cat > "$run_dir/findings.md" <<EOF
---
head_sha: $head_sha
focus: default
---

# Findings

## Local State

- README suggests adding feature "Add X" next.

## External Context

- Consider adding X to stay current.
EOF
}

make_fake_claude_bin_capturing_prompt() {
  local bin_dir="$1" capture_file="$2"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/claude" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cat > "$capture_file"
cat <<'OUT'
- stub external context
OUT
EOF
  chmod +x "$bin_dir/claude"
}

make_fake_claude_bin_returning() {
  local bin_dir="$1" body_file="$2"
  mkdir -p "$bin_dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'cat >/dev/null\n'
    printf "cat <<'CLAUDE_STUB_OUT'\n"
    cat "$body_file"
    printf '\nCLAUDE_STUB_OUT\n'
  } > "$bin_dir/claude"
  chmod +x "$bin_dir/claude"
}

discover_focus_default_omits_monetization_section() {
  local repo bin_dir capture_file run_id findings contents
  repo="$(make_repo_with_commit)"
  write_config "$repo"
  bin_dir="$(mktemp -d)"
  capture_file="$(mktemp)"
  make_fake_claude_bin_capturing_prompt "$bin_dir" "$capture_file"

  PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage discover >/dev/null
  run_id="$(cat "$repo/.e3d-pilot/latest-run")"
  findings="$repo/.e3d-pilot/runs/$run_id/findings.md"
  contents="$(cat "$findings")"

  assert_contains "$contents" "focus: default"
  assert_not_contains "$(cat "$capture_file")" "Monetization Signals"
  [[ "$(cat "$repo/.e3d-pilot/runs/$run_id/focus")" == "default" ]] || { echo "expected persisted focus file to be default" >&2; exit 1; }

  rm -rf "$bin_dir"; rm -f "$capture_file"
}

discover_focus_revenue_adds_monetization_prompt_and_persists() {
  local repo bin_dir capture_file run_id findings contents prompt
  repo="$(make_repo_with_commit)"
  write_config "$repo"
  bin_dir="$(mktemp -d)"
  capture_file="$(mktemp)"
  make_fake_claude_bin_capturing_prompt "$bin_dir" "$capture_file"

  PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage discover --focus revenue >/dev/null
  run_id="$(cat "$repo/.e3d-pilot/latest-run")"
  findings="$repo/.e3d-pilot/runs/$run_id/findings.md"
  contents="$(cat "$findings")"
  prompt="$(cat "$capture_file")"

  assert_contains "$contents" "focus: revenue"
  assert_contains "$prompt" "### Monetization Signals"
  [[ "$(cat "$repo/.e3d-pilot/runs/$run_id/focus")" == "revenue" ]] || { echo "expected persisted focus file to be revenue" >&2; exit 1; }

  rm -rf "$bin_dir"; rm -f "$capture_file"
}

invalid_focus_value_errors() {
  local repo out status
  repo="$(make_repo_with_commit)"
  write_config "$repo"

  set +e
  out="$("$BIN" run --repo "$repo" --stage discover --focus bogus 2>&1)"
  status=$?
  set -e

  [[ $status -ne 0 ]] || { echo "expected non-zero exit for invalid --focus value" >&2; exit 1; }
  assert_contains "$out" "invalid --focus value: bogus"
}

ideate_inherits_revenue_focus_from_discover_without_flag() {
  local repo bin_dir run_id response prompt candidates contents
  repo="$(make_repo_with_commit)"
  write_config "$repo"
  bin_dir="$(mktemp -d)"

  # discover establishes revenue focus for this run, persisted to disk.
  local capture_file; capture_file="$(mktemp)"
  make_fake_claude_bin_capturing_prompt "$bin_dir" "$capture_file"
  PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage discover --focus revenue >/dev/null
  run_id="$(cat "$repo/.e3d-pilot/latest-run")"
  rm -f "$capture_file"

  # ideate is invoked in a separate call with no --focus at all.
  response="$(mktemp)"
  cat > "$response" <<'EOF'
### Candidate 1: Paid tier for feature X
Duplicate: no
Dedup rationale: no existing branch or past run covers this.
Category: selling
Analogy: fintech trust and verification UX -- a paid verified badge mirrors KYC tiers.
Attraction (1-5): 3
Retention (1-5): 3
Effort: medium
Revenue (1-5): 5
Description: Add a paid verification tier.

---IDEATE-STATUS---
selected: candidate-1
reason: only candidate, not a duplicate.
EOF
  make_fake_claude_bin_returning "$bin_dir" "$response"

  PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage ideate --run-id "$run_id" >/dev/null

  prompt="$(cat "$repo/.e3d-pilot/runs/$run_id/ideate-prompt.md")"
  candidates="$repo/.e3d-pilot/runs/$run_id/candidates.md"
  contents="$(cat "$candidates")"

  assert_contains "$prompt" "explicitly focused on revenue-generating ideas"
  assert_contains "$prompt" "Rank non-duplicate candidates primarily by Revenue"
  assert_contains "$contents" "focus: revenue"

  rm -rf "$bin_dir"; rm -f "$response"
}

ideate_focus_revenue_requires_numeric_revenue_field() {
  local repo bin_dir run_id response out
  repo="$(make_repo_with_commit)"
  write_config "$repo"
  run_id="2026-07-30-repo-revwarn"
  write_findings "$repo" "$run_id"

  bin_dir="$(mktemp -d)"
  response="$(mktemp)"
  cat > "$response" <<'EOF'
### Candidate 1: Paid tier for feature X
Duplicate: no
Dedup rationale: no existing branch or past run covers this.
Category: selling
Analogy: fintech trust and verification UX -- a paid verified badge mirrors KYC tiers.
Attraction (1-5): 3
Retention (1-5): 3
Effort: medium
Revenue (1-5|n/a): n/a
Description: Add a paid verification tier.

---IDEATE-STATUS---
selected: candidate-1
reason: only candidate, not a duplicate.
EOF
  make_fake_claude_bin_returning "$bin_dir" "$response"

  out="$(PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage ideate --run-id "$run_id" --focus revenue)"

  assert_contains "$out" "Candidate 1 is missing a numeric Revenue score (required in a revenue-focused run)"

  rm -rf "$bin_dir"; rm -f "$response"
}

main() {
  discover_focus_default_omits_monetization_section
  discover_focus_revenue_adds_monetization_prompt_and_persists
  invalid_focus_value_errors
  ideate_inherits_revenue_focus_from_discover_without_flag
  ideate_focus_revenue_requires_numeric_revenue_field
  echo "phase10: all tests passed"
}

main "$@"
