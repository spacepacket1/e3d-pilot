#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"

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

make_repo() {
  local name="$1" tagline="$2" parent repo
  parent="$(mktemp -d)"
  repo="$parent/$name"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test User"
  printf '# %s\n\n%s\n' "$name" "$tagline" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m "initial commit"
  printf '%s' "$repo"
}

# Branches on prompt content: the fleet discover prompt and fleet ideate
# prompt are distinguishable by fixed marker text each build_fleet_*_prompt
# function always emits, so one stub script can serve both provider calls a
# `fleet discover` run makes without needing separate binaries.
make_fake_claude_bin() {
  local bin_dir="$1" ideate_response_file="$2"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/claude" <<EOF
#!/usr/bin/env bash
set -euo pipefail
prompt="\$(cat)"
if grep -q "cross-repo ideate stage" <<<"\$prompt"; then
  cat "$ideate_response_file"
else
  cat <<'DISCOVER_OUT'
### Cross-Repo Opportunities
- repo-a + repo-b: combine repo-a's feed with repo-b's payment rails.
### Analogous Patterns
- marketplace liquidity -- repo-a supplies data, repo-b supplies settlement.
DISCOVER_OUT
fi
EOF
  chmod +x "$bin_dir/claude"
}

write_fleet_config() {
  local fleet_dir="$1"
  mkdir -p "$fleet_dir"
  cp "$ROOT/examples/sample-fleet-config.json" "$fleet_dir/config.json"
}

default_ideate_response() {
  cat <<'EOF'
### Candidate 1: Paid signal API
Repos: repo-a, repo-b
Duplicate: no
Dedup rationale: no prior fleet run covers this.
Analogy: marketplace liquidity -- repo-a supplies data, repo-b supplies settlement.
Attraction (1-5): 4
Retention (1-5): 4
Effort: medium
Revenue (1-5|n/a): 5
Description: Combine repo-a's data feed with repo-b's payment rails.

---IDEATE-STATUS---
selected: candidate-1
reason: only candidate, not a duplicate.
EOF
}

fleet_discover_writes_findings_and_candidates() {
  local repo_a repo_b fleet_dir fleet_file bin_dir response run_id findings candidates
  repo_a="$(make_repo "repo-a" "Data feed service.")"
  repo_b="$(make_repo "repo-b" "Payment rails.")"
  fleet_dir="$(mktemp -d)"
  fleet_file="$fleet_dir/fleet.json"
  jq -n --arg a "$repo_a" --arg b "$repo_b" '[$a,$b]' > "$fleet_file"
  write_fleet_config "$fleet_dir/.e3d-pilot-fleet"

  bin_dir="$(mktemp -d)"
  response="$(mktemp)"
  default_ideate_response > "$response"
  make_fake_claude_bin "$bin_dir" "$response"

  PATH="$bin_dir:$PATH" "$BIN" fleet discover "$fleet_file" >/dev/null

  run_id="$(cat "$fleet_dir/.e3d-pilot-fleet/latest-run")"
  findings="$fleet_dir/.e3d-pilot-fleet/runs/$run_id/findings.md"
  candidates="$fleet_dir/.e3d-pilot-fleet/runs/$run_id/candidates.md"

  [[ -f "$findings" ]] || { echo "missing fleet findings.md" >&2; exit 1; }
  [[ -f "$candidates" ]] || { echo "missing fleet candidates.md" >&2; exit 1; }

  assert_contains "$(cat "$findings")" "## Portfolio"
  assert_contains "$(cat "$findings")" "### repo-a"
  assert_contains "$(cat "$findings")" "### repo-b"
  assert_contains "$(cat "$findings")" "Data feed service."
  assert_contains "$(cat "$findings")" "### Cross-Repo Opportunities"

  assert_contains "$(cat "$candidates")" "selected: candidate-1"
  assert_contains "$(cat "$candidates")" "Repos: repo-a, repo-b"
  assert_contains "$(cat "$candidates")" "focus: default"

  rm -rf "$bin_dir" "$fleet_dir" "$repo_a" "$repo_b"; rm -f "$response"
}

fleet_discover_missing_config_errors_clearly() {
  local repo_a repo_b fleet_dir fleet_file out status
  repo_a="$(make_repo "repo-a" "Data feed service.")"
  repo_b="$(make_repo "repo-b" "Payment rails.")"
  fleet_dir="$(mktemp -d)"
  fleet_file="$fleet_dir/fleet.json"
  jq -n --arg a "$repo_a" --arg b "$repo_b" '[$a,$b]' > "$fleet_file"

  set +e
  out="$("$BIN" fleet discover "$fleet_file" 2>&1)"
  status=$?
  set -e

  [[ $status -ne 0 ]] || { echo "expected non-zero exit without a fleet discover config" >&2; exit 1; }
  assert_contains "$out" "fleet discover config not found"

  rm -rf "$fleet_dir" "$repo_a" "$repo_b"
}

fleet_discover_focus_revenue_flows_into_ideate_prompt() {
  local repo_a repo_b fleet_dir fleet_file bin_dir response run_id prompt
  repo_a="$(make_repo "repo-a" "Data feed service.")"
  repo_b="$(make_repo "repo-b" "Payment rails.")"
  fleet_dir="$(mktemp -d)"
  fleet_file="$fleet_dir/fleet.json"
  jq -n --arg a "$repo_a" --arg b "$repo_b" '[$a,$b]' > "$fleet_file"
  write_fleet_config "$fleet_dir/.e3d-pilot-fleet"

  bin_dir="$(mktemp -d)"
  response="$(mktemp)"
  cat > "$response" <<'EOF'
### Candidate 1: Paid signal API
Repos: repo-a, repo-b
Duplicate: no
Dedup rationale: no prior fleet run covers this.
Analogy: marketplace liquidity -- repo-a supplies data, repo-b supplies settlement.
Attraction (1-5): 4
Retention (1-5): 4
Effort: medium
Revenue (1-5): 5
Description: Combine repo-a's data feed with repo-b's payment rails.

---IDEATE-STATUS---
selected: candidate-1
reason: only candidate, not a duplicate.
EOF
  make_fake_claude_bin "$bin_dir" "$response"

  PATH="$bin_dir:$PATH" "$BIN" fleet discover "$fleet_file" --focus revenue >/dev/null
  run_id="$(cat "$fleet_dir/.e3d-pilot-fleet/latest-run")"
  prompt="$(cat "$fleet_dir/.e3d-pilot-fleet/runs/$run_id/fleet-discover-prompt.md")"
  assert_contains "$prompt" "### Monetization Signals"
  prompt="$(cat "$fleet_dir/.e3d-pilot-fleet/runs/$run_id/fleet-ideate-prompt.md")"
  assert_contains "$prompt" "explicitly focused on revenue-generating ideas"
  assert_contains "$(cat "$fleet_dir/.e3d-pilot-fleet/runs/$run_id/candidates.md")" "focus: revenue"

  rm -rf "$bin_dir" "$fleet_dir" "$repo_a" "$repo_b"; rm -f "$response"
}

fleet_ideate_warns_on_missing_repos_field() {
  local repo_a repo_b fleet_dir fleet_file bin_dir response out
  repo_a="$(make_repo "repo-a" "Data feed service.")"
  repo_b="$(make_repo "repo-b" "Payment rails.")"
  fleet_dir="$(mktemp -d)"
  fleet_file="$fleet_dir/fleet.json"
  jq -n --arg a "$repo_a" --arg b "$repo_b" '[$a,$b]' > "$fleet_file"
  write_fleet_config "$fleet_dir/.e3d-pilot-fleet"

  bin_dir="$(mktemp -d)"
  response="$(mktemp)"
  cat > "$response" <<'EOF'
### Candidate 1: Paid signal API
Duplicate: no
Dedup rationale: no prior fleet run covers this.
Analogy: marketplace liquidity -- repo-a supplies data, repo-b supplies settlement.
Attraction (1-5): 4
Retention (1-5): 4
Effort: medium
Revenue (1-5|n/a): 5
Description: Combine repo-a's data feed with repo-b's payment rails.

---IDEATE-STATUS---
selected: candidate-1
reason: only candidate, not a duplicate.
EOF
  make_fake_claude_bin "$bin_dir" "$response"

  out="$(PATH="$bin_dir:$PATH" "$BIN" fleet discover "$fleet_file" 2>&1)"
  assert_contains "$out" "Candidate 1 is missing a Repos field"

  rm -rf "$bin_dir" "$fleet_dir" "$repo_a" "$repo_b"; rm -f "$response"
}

fleet_discover_backward_compat_old_fleet_still_works() {
  local repo_a repo_b fleet_dir fleet_file bin_dir out status
  repo_a="$(make_repo "repo-a" "Data feed service.")"
  repo_b="$(make_repo "repo-b" "Payment rails.")"
  fleet_dir="$(mktemp -d)"
  fleet_file="$fleet_dir/fleet.json"
  jq -n --arg a "$repo_a" --arg b "$repo_b" '[$a,$b]' > "$fleet_file"

  bin_dir="$(mktemp -d)"
  cat > "$bin_dir/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${E3D_PILOT_CHECK:-0}" == 1 ]] && { echo available; exit; }
cat >/dev/null
cat <<'OUT'
### Candidate 1: Existing work
Duplicate: yes
Dedup rationale: test stop
Description: none
---IDEATE-STATUS---
selected: none
reason: all duplicate
OUT
EOF
  chmod +x "$bin_dir/claude"

  mkdir -p "$repo_a/.e3d-pilot" "$repo_b/.e3d-pilot"
  jq '.providers.discover="claude" | .providers.ideate="claude"' "$ROOT/examples/sample-config.json" > "$repo_a/.e3d-pilot/config.json"
  cp "$repo_a/.e3d-pilot/config.json" "$repo_b/.e3d-pilot/config.json"

  set +e
  out="$(PATH="$bin_dir:$PATH" "$BIN" fleet "$fleet_file" 2>&1)"
  status=$?
  set -e

  [[ $status -eq 0 ]] || { echo "expected old-style fleet run to succeed, got exit $status: $out" >&2; exit 1; }
  assert_contains "$out" "fleet: PASS $repo_a"
  assert_contains "$out" "fleet: PASS $repo_b"
  assert_not_contains "$out" ".e3d-pilot-fleet"

  rm -rf "$bin_dir" "$fleet_dir" "$repo_a" "$repo_b"
}

main() {
  fleet_discover_writes_findings_and_candidates
  fleet_discover_missing_config_errors_clearly
  fleet_discover_focus_revenue_flows_into_ideate_prompt
  fleet_ideate_warns_on_missing_repos_field
  fleet_discover_backward_compat_old_fleet_still_works
  echo "phase11: all tests passed"
}

main "$@"
