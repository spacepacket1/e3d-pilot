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

write_ideate_config() {
  local repo="$1"
  mkdir -p "$repo/.e3d-pilot"
  jq '.providers.ideate = "claude"' "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
}

write_findings() {
  local repo="$1" run_id="$2" run_dir head_sha
  run_dir="$repo/.e3d-pilot/runs/$run_id"
  mkdir -p "$run_dir"
  head_sha="$(git -C "$repo" rev-parse HEAD)"
  cat > "$run_dir/findings.md" <<EOF
---
head_sha: $head_sha
---

# Findings

## Local State

- README suggests adding feature "Add X" next.

## External Context

- Consider adding X to stay current.
EOF
}

seed_prior_run() {
  local repo="$1" prior_run_id="$2" prior_dir
  prior_dir="$repo/.e3d-pilot/runs/$prior_run_id"
  mkdir -p "$prior_dir"
  cat > "$prior_dir/candidates.md" <<'EOF'
---
selected: none
reason: prior run found nothing to do
---
# Candidates
EOF
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

make_fake_gh_bin_with_pr() {
  local bin_dir="$1" pr_line="$2"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\$1" in
  auth)
    exit 0
    ;;
  repo)
    exit 0
    ;;
  pr)
    printf '%s\n' "$pr_line"
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/gh"
}

ideate_marks_pr_duplicate_and_selects_other() {
  local repo bin_dir prior_run_id run_id response candidates contents
  repo="$(make_repo_with_commit)"
  git -C "$repo" remote add origin https://example.invalid/test/repo.git
  write_ideate_config "$repo"
  prior_run_id="2026-07-01-repo"
  seed_prior_run "$repo" "$prior_run_id"
  run_id="2026-07-26-repo"
  write_findings "$repo" "$run_id"

  bin_dir="$(mktemp -d)"
  make_fake_gh_bin_with_pr "$bin_dir" "123  Add X  feature/add-x"
  response="$(mktemp)"
  cat > "$response" <<'EOF'
### Candidate 1: Add X
Duplicate: yes
Dedup rationale: already open as PR #123 "Add X".
Description: n/a, already covered.

### Candidate 2: Improve error messages
Duplicate: no
Dedup rationale: no matching branch, PR, or past run covers this.
Description: Improve CLI error messages for missing config fields.

---IDEATE-STATUS---
selected: candidate-2
reason: candidate 1 duplicates open PR #123; candidate 2 is net new.
EOF
  make_fake_claude_bin_returning "$bin_dir" "$response"

  PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage ideate --run-id "$run_id" >/dev/null

  candidates="$repo/.e3d-pilot/runs/$run_id/candidates.md"
  contents="$(cat "$candidates")"

  assert_contains "$contents" "selected: candidate-2"
  assert_not_contains "$contents" "selected: candidate-1"
  assert_contains "$contents" 'already open as PR #123 "Add X"'
  assert_contains "$contents" "Duplicate: yes"
  assert_contains "$contents" "123  Add X  feature/add-x"
  [[ -f "$repo/.e3d-pilot/runs/$run_id/ideate-facts.md" ]] || { echo "missing ideate-facts.md" >&2; exit 1; }
  [[ -f "$repo/.e3d-pilot/runs/$run_id/ideate-prompt.md" ]] || { echo "missing ideate-prompt.md" >&2; exit 1; }
  [[ -f "$repo/.e3d-pilot/runs/$run_id/ideate-response.md" ]] || { echo "missing ideate-response.md" >&2; exit 1; }

  rm -rf "$bin_dir" "$response"
}

ideate_no_remote_skips_pr_list_but_dedups_normally() {
  local repo bin_dir run_id response candidates contents
  repo="$(make_repo_with_commit)"
  git -C "$repo" branch feature/existing-thing
  write_ideate_config "$repo"
  run_id="2026-07-26-repo-norem"
  write_findings "$repo" "$run_id"

  bin_dir="$(mktemp -d)"
  response="$(mktemp)"
  cat > "$response" <<'EOF'
### Candidate 1: Add retry logic
Duplicate: no
Dedup rationale: no existing branch or past run covers retries.
Description: Add retry logic to network calls.

---IDEATE-STATUS---
selected: candidate-1
reason: only candidate, not a duplicate.
EOF
  make_fake_claude_bin_returning "$bin_dir" "$response"

  PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage ideate --run-id "$run_id" >/dev/null

  candidates="$repo/.e3d-pilot/runs/$run_id/candidates.md"
  contents="$(cat "$candidates")"

  assert_contains "$contents" "selected: candidate-1"
  assert_contains "$contents" "## GH PR List (state: all)"
  assert_contains "$contents" "skipped: no git remote configured"
  assert_contains "$contents" "feature/existing-thing"

  rm -rf "$bin_dir" "$response"
}

ideate_nothing_to_do_is_distinguishable_and_stops_all() {
  local repo bin_dir out run_id candidates contents response
  repo="$(make_repo_with_commit)"
  write_ideate_config "$repo"

  bin_dir="$(mktemp -d)"
  response="$(mktemp)"
  cat > "$response" <<'EOF'
### Candidate 1: Add X
Duplicate: yes
Dedup rationale: already covered by a past run's candidates.md.
Description: n/a

---IDEATE-STATUS---
selected: none
reason: every candidate duplicates existing work.
EOF
  make_fake_claude_bin_returning "$bin_dir" "$response"

  out="$(PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage all)"
  run_id="$(cat "$repo/.e3d-pilot/latest-run")"
  candidates="$repo/.e3d-pilot/runs/$run_id/candidates.md"
  contents="$(cat "$candidates")"

  assert_contains "$contents" "selected: none"
  assert_contains "$out" "ideate: nothing to do"
  assert_not_contains "$out" "draft: not yet implemented"

  rm -rf "$bin_dir" "$response"
}

ideate_warns_on_candidate_count_and_missing_rationale() {
  local repo bin_dir run_id response out candidates contents
  repo="$(make_repo_with_commit)"
  write_ideate_config "$repo"
  run_id="2026-07-26-repo-warn"
  write_findings "$repo" "$run_id"

  bin_dir="$(mktemp -d)"
  response="$(mktemp)"
  cat > "$response" <<'EOF'
### Candidate 1: Add retry logic
Duplicate: no
Dedup rationale:
Description: Add retry logic to network calls.

---IDEATE-STATUS---
selected: candidate-1
reason: only candidate proposed.
EOF
  make_fake_claude_bin_returning "$bin_dir" "$response"

  out="$(PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage ideate --run-id "$run_id")"

  candidates="$repo/.e3d-pilot/runs/$run_id/candidates.md"
  contents="$(cat "$candidates")"

  assert_contains "$out" "ideate: warning:"
  assert_contains "$out" "expected 3-5 candidates, got 1"
  assert_contains "$out" "Candidate 1 is missing a Dedup rationale"
  assert_contains "$contents" "## Validation Warnings"
  assert_contains "$contents" "expected 3-5 candidates, got 1"
  # A format warning must not block the pipeline: the stage still selects
  # a candidate and writes candidates.md normally.
  assert_contains "$contents" "selected: candidate-1"

  rm -rf "$bin_dir" "$response"
}

ideate_prompt_requires_scoring_fields_and_ranking_rule() {
  local repo bin_dir run_id prompt response
  repo="$(make_repo_with_commit)"
  write_ideate_config "$repo"
  run_id="2026-07-27-repo-prompt"
  write_findings "$repo" "$run_id"

  bin_dir="$(mktemp -d)"
  response="$(mktemp)"
  cat > "$response" <<'EOF'
### Candidate 1: Add retry logic
Duplicate: no
Dedup rationale: no existing branch or past run covers retries.
Category: workflow
Analogy: fintech trust and verification UX -- retry confirmations build user confidence
Attraction (1-5): 3
Retention (1-5): 3
Effort: low
Revenue (1-5|n/a): n/a
Description: Add retry logic to network calls.

---IDEATE-STATUS---
selected: candidate-1
reason: only candidate, not a duplicate.
EOF
  make_fake_claude_bin_returning "$bin_dir" "$response"

  PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage ideate --run-id "$run_id" >/dev/null
  prompt="$(cat "$repo/.e3d-pilot/runs/$run_id/ideate-prompt.md")"

  assert_contains "$prompt" "attracting and retaining users"
  assert_contains "$prompt" "Category: data|workflow|social|gamification|testing|marketing|selling|other"
  assert_contains "$prompt" "Attraction (1-5):"
  assert_contains "$prompt" "Retention (1-5):"
  assert_contains "$prompt" "Rank non-duplicate candidates primarily by Attraction + Retention"

  rm -rf "$bin_dir" "$response"
}

ideate_warns_on_missing_scoring_fields() {
  local repo bin_dir run_id response out candidates contents
  repo="$(make_repo_with_commit)"
  write_ideate_config "$repo"
  run_id="2026-07-27-repo-scorewarn"
  write_findings "$repo" "$run_id"

  bin_dir="$(mktemp -d)"
  response="$(mktemp)"
  cat > "$response" <<'EOF'
### Candidate 1: Add retry logic
Duplicate: no
Dedup rationale: no existing branch or past run covers retries.
Description: Add retry logic to network calls.

### Candidate 2: Add progress bar
Duplicate: no
Dedup rationale: no existing branch or past run covers this.
Category: workflow
Analogy: game progression and reward loops -- a visible progress bar mirrors a game quest tracker
Attraction (1-5): 4
Retention (1-5): 3
Effort: low
Revenue (1-5|n/a): n/a
Description: Show a progress bar during long-running operations.

### Candidate 3: Add leaderboard
Duplicate: no
Dedup rationale: no existing branch or past run covers this.
Category: gamification
Analogy: game progression and reward loops -- leaderboards drive repeat visits
Attraction (1-5): 5
Retention (1-5): 5
Effort: medium
Revenue (1-5|n/a): n/a
Description: Add a leaderboard for contributors.

---IDEATE-STATUS---
selected: candidate-3
reason: highest Attraction + Retention among non-duplicates.
EOF
  make_fake_claude_bin_returning "$bin_dir" "$response"

  out="$(PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage ideate --run-id "$run_id")"
  candidates="$repo/.e3d-pilot/runs/$run_id/candidates.md"
  contents="$(cat "$candidates")"

  assert_contains "$out" "Candidate 1 is missing a Category field"
  assert_contains "$out" "Candidate 1 is missing an Analogy field"
  assert_contains "$out" "Candidate 1 is missing an Attraction score"
  assert_contains "$out" "Candidate 1 is missing a Retention score"
  assert_contains "$out" "Candidate 1 is missing an Effort field"
  assert_not_contains "$out" "Candidate 2 is missing"
  assert_not_contains "$out" "Candidate 3 is missing"
  # Selection still follows the ranking rule (highest Attraction + Retention
  # among non-duplicates) even though a format warning was raised elsewhere.
  assert_contains "$contents" "selected: candidate-3"

  rm -rf "$bin_dir" "$response"
}

main() {
  ideate_marks_pr_duplicate_and_selects_other
  ideate_no_remote_skips_pr_list_but_dedups_normally
  ideate_nothing_to_do_is_distinguishable_and_stops_all
  ideate_warns_on_candidate_count_and_missing_rationale
  ideate_prompt_requires_scoring_fields_and_ranking_rule
  ideate_warns_on_missing_scoring_fields
  echo "phase4: all tests passed"
}

main "$@"
