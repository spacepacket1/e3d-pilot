#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"
SAMPLE_CONFIG="$ROOT/examples/sample-config.json"
SAMPLE_FLEET_CONFIG="$ROOT/examples/sample-fleet-config.json"

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

make_named_repo_with_commit() {
  local parent="$1" name="$2" repo
  repo="$parent/$name"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test User"
  cat > "$repo/README.md" <<EOF
# $name
EOF
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m "initial commit"
  printf '%s' "$repo"
}

write_repo_config() {
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

- Existing repo context.

## External Context

- External signal.
EOF
}

write_fleet_config() {
  local fleet_dir="$1"
  mkdir -p "$fleet_dir"
  cp "$SAMPLE_FLEET_CONFIG" "$fleet_dir/config.json"
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

make_fake_fleet_claude_bin() {
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
- repo-a + repo-b: shared opportunity.
### Analogous Patterns
- pattern: combine both repos.
DISCOVER_OUT
fi
EOF
  chmod +x "$bin_dir/claude"
}

single_repo_materializes_all_non_duplicate_candidates() {
  local repo run_id response bin_dir ideas_dir events_file idea_count event_count
  local selected_json other_json candidates_hash_before candidates_hash_after
  repo="$(make_repo_with_commit)"
  write_repo_config "$repo"
  run_id="2026-07-31-repo"
  write_findings "$repo" "$run_id"

  response="$(mktemp)"
  cat > "$response" <<'EOF'
### Candidate 1: Existing work
Duplicate: yes
Dedup rationale: already covered by a prior idea.
Category: other
Analogy: none
Attraction (1-5): 2
Retention (1-5): 2
Effort: low
Revenue (1-5|n/a): n/a
Description: Already done.

### Candidate 2: Improve onboarding
Duplicate: no
Dedup rationale: no prior idea matches this scope.
Category: workflow
Analogy: game progression -- reduce first-run friction.
Attraction (1-5): 4
Retention (1-5): 4
Effort: medium
Revenue (1-5|n/a): n/a
Description: Add guided first-run onboarding.

### Candidate 3: Add diagnostics
Duplicate: no
Dedup rationale: no prior idea matches this scope.
Category: testing
Analogy: developer tooling -- surface failure context quickly.
Attraction (1-5): 3
Retention (1-5): 5
Effort: medium
Revenue (1-5|n/a): n/a
Description: Add focused diagnostics for failing runs.

---IDEATE-STATUS---
selected: candidate-2
reason: candidate 2 is the strongest non-duplicate option.
EOF

  bin_dir="$(mktemp -d)"
  make_fake_claude_bin_returning "$bin_dir" "$response"
  PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage ideate --run-id "$run_id" >/dev/null

  ideas_dir="$repo/.e3d-pilot/ideas"
  events_file="$repo/.e3d-pilot/events.jsonl"
  idea_count="$(find "$ideas_dir" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  event_count="$(wc -l < "$events_file" | tr -d ' ')"
  assert_eq "$idea_count" "2" "single-repo idea count"
  assert_eq "$event_count" "2" "single-repo event count"

  selected_json="$(find "$ideas_dir" -name idea.json -print0 | xargs -0 jq -c 'select(.title=="Improve onboarding")')"
  other_json="$(find "$ideas_dir" -name idea.json -print0 | xargs -0 jq -c 'select(.title=="Add diagnostics")')"
  [[ -n "$selected_json" ]] || { echo "missing selected idea snapshot" >&2; exit 1; }
  [[ -n "$other_json" ]] || { echo "missing secondary idea snapshot" >&2; exit 1; }

  assert_eq "$(jq -r '.status' <<<"$selected_json")" "proposed" "selected idea status"
  assert_eq "$(jq -r '.rank' <<<"$selected_json")" "2" "selected idea rank"
  assert_eq "$(jq -r '.selected_by_model' <<<"$selected_json")" "true" "selected marker"
  assert_eq "$(jq -r '.implementation.targets | length' <<<"$selected_json")" "0" "no implementation targets"
  assert_eq "$(jq -r '.implementation_approval == null' <<<"$selected_json")" "true" "no implementation approval"
  assert_eq "$(jq -r '.merge_approval == null' <<<"$selected_json")" "true" "no merge approval"
  assert_eq "$(jq -r '.content_digests.source_artifacts | map(.path) | index(".e3d-pilot/runs/'"$run_id"'/candidates.md") != null' <<<"$selected_json")" "true" "candidates artifact tracked"

  candidates_hash_before="$(shasum -a 256 "$repo/.e3d-pilot/runs/$run_id/candidates.md" | awk '{print $1}')"
  PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage ideate --run-id "$run_id" >/dev/null
  candidates_hash_after="$(shasum -a 256 "$repo/.e3d-pilot/runs/$run_id/candidates.md" | awk '{print $1}')"
  event_count="$(wc -l < "$events_file" | tr -d ' ')"
  assert_eq "$event_count" "2" "unchanged rerun remains idempotent"
  assert_eq "$candidates_hash_after" "$candidates_hash_before" "candidates markdown unchanged"

  rm -rf "$bin_dir" "$repo"
  rm -f "$response"
}

fleet_discover_materializes_all_non_duplicate_candidates() {
  local repo_a repo_b repos_parent fleet_dir fleet_file response bin_dir run_id ideas_dir idea_count snapshot
  repos_parent="$(mktemp -d)"
  repo_a="$(make_named_repo_with_commit "$repos_parent" "repo-a")"
  repo_b="$(make_named_repo_with_commit "$repos_parent" "repo-b")"

  fleet_dir="$(mktemp -d)"
  fleet_file="$fleet_dir/fleet.json"
  jq -n --arg a "$repo_a" --arg b "$repo_b" '[$a,$b]' > "$fleet_file"
  write_fleet_config "$fleet_dir/.e3d-pilot-fleet"

  response="$(mktemp)"
  cat > "$response" <<'EOF'
### Candidate 1: Shared billing
Repos: repo-a, repo-b
Duplicate: no
Dedup rationale: no prior fleet idea matches this scope.
Analogy: marketplace liquidity -- package both capabilities.
Attraction (1-5): 4
Retention (1-5): 4
Effort: medium
Revenue (1-5|n/a): 5
Description: Combine both repos into a shared billing surface.

### Candidate 2: Portfolio analytics
Repos: repo-a, repo-b
Duplicate: no
Dedup rationale: no prior fleet idea matches this scope.
Analogy: fintech trust -- show end-to-end portfolio metrics.
Attraction (1-5): 3
Retention (1-5): 5
Effort: medium
Revenue (1-5|n/a): 4
Description: Build analytics that require data from both repos.

---IDEATE-STATUS---
selected: candidate-1
reason: candidate 1 has the highest value.
EOF

  bin_dir="$(mktemp -d)"
  make_fake_fleet_claude_bin "$bin_dir" "$response"
  PATH="$bin_dir:$PATH" "$BIN" fleet discover "$fleet_file" --run-id "2026-07-31-fleet" >/dev/null

  run_id="2026-07-31-fleet"
  ideas_dir="$fleet_dir/.e3d-pilot-fleet/ideas"
  idea_count="$(find "$ideas_dir" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  assert_eq "$idea_count" "2" "fleet idea count"

  snapshot="$(find "$ideas_dir" -name idea.json -print0 | xargs -0 jq -c 'select(.title=="Shared billing")')"
  [[ -n "$snapshot" ]] || { echo "missing fleet idea snapshot" >&2; exit 1; }
  assert_eq "$(jq -r '.repos | length' <<<"$snapshot")" "2" "fleet repo resolution count"
  assert_eq "$(jq -r --arg a "$(cd "$repo_a" && pwd -P)" --arg b "$(cd "$repo_b" && pwd -P)" '(.repos | index($a) != null) and (.repos | index($b) != null)' <<<"$snapshot")" "true" "fleet repos resolved canonically"
  assert_eq "$(jq -r '.validation.approvable' <<<"$snapshot")" "true" "fleet idea approvable"

  rm -rf "$bin_dir" "$fleet_dir" "$repos_parent"
  rm -f "$response"
}

missing_required_field_creates_ineligible_idea_and_blocks_approval() {
  local repo run_id response bin_dir out status snapshot
  repo="$(make_repo_with_commit)"
  write_repo_config "$repo"
  run_id="2026-07-31-ineligible"
  write_findings "$repo" "$run_id"

  response="$(mktemp)"
  cat > "$response" <<'EOF'
### Candidate 1: Incomplete idea
Duplicate: no
Dedup rationale: no prior idea matches this scope.
Category: other
Analogy: none
Attraction (1-5): 3
Retention (1-5): 3
Effort: low
Revenue (1-5|n/a): n/a

---IDEATE-STATUS---
selected: candidate-1
reason: only candidate.
EOF

  bin_dir="$(mktemp -d)"
  make_fake_claude_bin_returning "$bin_dir" "$response"
  PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage ideate --run-id "$run_id" >/dev/null

  snapshot="$(find "$repo/.e3d-pilot/ideas" -name idea.json -print -quit)"
  [[ -f "$snapshot" ]] || { echo "missing ineligible snapshot" >&2; exit 1; }
  assert_eq "$(jq -r '.validation.approvable' "$snapshot")" "false" "ineligible idea"
  assert_contains "$(jq -r '.validation.warnings[]' "$snapshot")" "Candidate 1 is missing a description/summary"

  set +e
  out="$("$BIN" ideas transition --repo "$repo" "$(jq -r '.idea_id' "$snapshot")" implementation_approved 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "expected approval to fail for ineligible idea" >&2; exit 1; }
  assert_contains "$out" "Candidate 1 is missing a description/summary"

  rm -rf "$bin_dir" "$repo"
  rm -f "$response"
}

main() {
  single_repo_materializes_all_non_duplicate_candidates
  fleet_discover_materializes_all_non_duplicate_candidates
  missing_required_field_creates_ineligible_idea_and_blocks_approval
}

main "$@"
