#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"
SAMPLE_CONFIG="$ROOT/examples/sample-config.json"
CSR_BIN="/home/ubuntu/codex-spec-runner/bin/codex-spec-runner"

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

write_draft_config() {
  local repo="$1"
  mkdir -p "$repo/.e3d-pilot"
  jq '.providers.discover = "claude" | .providers.ideate = "claude" | .providers.draft = "claude"
     | .approval.implementation_required = false | .approval.merge_required = false' "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
}

write_candidates() {
  local repo="$1" run_id="$2" selected="$3" run_dir
  run_dir="$repo/.e3d-pilot/runs/$run_id"
  mkdir -p "$run_dir"
  cat > "$run_dir/candidates.md" <<EOF
---
selected: $selected
reason: candidate-1 is the highest ranked non-duplicate idea.
---

# Candidates

### Candidate 1: Add retry logic to the HTTP client
Duplicate: no
Dedup rationale: no existing branch, PR, or past run covers retries.
Description: Add retry logic with backoff to outbound HTTP calls.
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

ok_response_file() {
  local out="$1"
  cat > "$out" <<'EOF'
```spec
# Add Retry Logic to the HTTP Client

## Overview

Add retry-with-backoff behavior to the HTTP client used for outbound calls.

## Goals

- Retry transient network failures instead of failing the first request.

## Non-Goals

- Do not add a circuit breaker.

## Existing Files

- `src/http-client.js`

## Shared Constraints

- Keep changes scoped to the HTTP client, its tests, and the README.

## Phase 1 - Add Retry Wrapper

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=src/http-client.js -->
<!-- pilot:touches=tests/http-client.test.js -->

### Requirements

- Wrap outbound requests in a retry helper with exponential backoff.

### Acceptance Criteria

- A simulated transient failure is retried and eventually succeeds.

## Phase 2 - Document Retry Behavior

<!-- runner:model=claude:sonnet -->
<!-- pilot:touches=README.md -->

### Requirements

- Document the new retry behavior in the README.

### Acceptance Criteria

- README mentions the retry/backoff behavior.
```

---DRAFT-STATUS---
status: ok
reason: candidate scoped to two small phases touching only the http client, its tests, and the README.
EOF
}

draft_produces_spec_that_csr_can_list() {
  local repo run_id bin_dir response out spec contents
  repo="$(make_repo_with_commit)"
  write_draft_config "$repo"
  run_id="2026-07-26-repo-draft-ok"
  write_candidates "$repo" "$run_id" "candidate-1"

  bin_dir="$(mktemp -d)"
  response="$(mktemp)"
  ok_response_file "$response"
  make_fake_claude_bin_returning "$bin_dir" "$response"

  out="$(PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage draft --run-id "$run_id")"
  spec="$repo/.e3d-pilot/runs/$run_id/spec-draft.md"
  [[ -f "$spec" ]] || { echo "expected spec-draft.md to be written" >&2; exit 1; }
  contents="$(cat "$spec")"

  assert_contains "$contents" "## Phase 1 - Add Retry Wrapper"
  assert_contains "$contents" "## Phase 2 - Document Retry Behavior"
  assert_contains "$contents" "pilot:touches=src/http-client.js"
  assert_contains "$contents" "pilot:touches=README.md"
  assert_not_contains "$contents" "runner:model=local"

  if [[ -x "$CSR_BIN" ]]; then
    local list_out
    list_out="$("$CSR_BIN" "$spec" --list)"
    assert_contains "$list_out" "Phase 1"
    assert_contains "$list_out" "codex"
    assert_contains "$list_out" "Add Retry Wrapper"
    assert_contains "$list_out" "Phase 2"
    assert_contains "$list_out" "claude"
    assert_contains "$list_out" "Document Retry Behavior"
  fi

  assert_contains "$out" "$run_id"
  rm -rf "$bin_dir" "$response"
}

draft_rejects_protected_path_touch_before_writing() {
  local repo run_id bin_dir response out spec rejected contents
  repo="$(make_repo_with_commit)"
  write_draft_config "$repo"
  run_id="2026-07-26-repo-draft-protected"
  write_candidates "$repo" "$run_id" "candidate-1"

  bin_dir="$(mktemp -d)"
  response="$(mktemp)"
  cat > "$response" <<'EOF'
```spec
# Update Deploy Pipeline

## Overview

Change the deploy pipeline configuration.

## Goals

- Speed up deploys.

## Non-Goals

- N/A

## Existing Files

- `deploy/rollout.sh`

## Shared Constraints

- N/A

## Phase 1 - Rework Rollout Script

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=deploy/rollout.sh -->

### Requirements

- Rework the rollout script.

### Acceptance Criteria

- Rollout script still exits zero on success.
```

---DRAFT-STATUS---
status: ok
reason: single small phase touching only the deploy rollout script.
EOF
  make_fake_claude_bin_returning "$bin_dir" "$response"

  out="$(PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage draft --run-id "$run_id")"
  spec="$repo/.e3d-pilot/runs/$run_id/spec-draft.md"
  rejected="$repo/.e3d-pilot/runs/$run_id/draft-rejected.md"

  [[ ! -f "$spec" ]] || { echo "expected spec-draft.md NOT to be written for a protected-path violation" >&2; exit 1; }
  [[ -f "$rejected" ]] || { echo "expected draft-rejected.md to record the rejection reason" >&2; exit 1; }
  contents="$(cat "$rejected")"
  assert_contains "$contents" "protected_paths entry \"deploy/**\""
  assert_contains "$out" "draft: rejected drafted spec"

  rm -rf "$bin_dir" "$response"
}

draft_reports_too_large_without_writing_spec_and_stops_all() {
  local repo bin_dir response out run_id spec rejected contents
  repo="$(make_repo_with_commit)"
  write_draft_config "$repo"

  bin_dir="$(mktemp -d)"
  response="$(mktemp)"
  cat > "$response" <<'EOF'
---DRAFT-STATUS---
status: too-large
reason: candidate requires touching over 40 files across the app; cannot fit configured max_diff_files.
EOF
  make_fake_claude_bin_returning "$bin_dir" "$response"

  local ideate_response ideate_bin_dir
  ideate_bin_dir="$bin_dir"
  ideate_response="$(mktemp)"
  cat > "$ideate_response" <<'EOF'
### Candidate 1: Rewrite the whole app
Duplicate: no
Dedup rationale: no existing branch, PR, or past run covers this.
Description: n/a

---IDEATE-STATUS---
selected: candidate-1
reason: only candidate, not a duplicate.
EOF

  # --stage all needs discover + ideate to also succeed against the same fake
  # claude stub before reaching draft, so the stub must serve all three
  # prompts. The real lib/providers/claude adapter pipes the prompt file over
  # stdin (not $1). Route on each stage's distinct role-instruction line
  # rather than on the ---*-STATUS--- markers: the draft prompt embeds the
  # full candidates.md audit trail (which itself contains a literal
  # ---IDEATE-STATUS--- block from the ideate response), so marker text alone
  # is not a reliable way to tell the two prompts apart.
  cat > "$bin_dir/claude" <<EOF
#!/usr/bin/env bash
set -euo pipefail
prompt="\$(cat)"
if grep -q -- 'the ideate stage' <<<"\$prompt"; then
  cat "$ideate_response"
elif grep -q -- 'the draft stage' <<<"\$prompt"; then
  cat "$response"
else
  echo "- external context placeholder"
fi
EOF
  chmod +x "$bin_dir/claude"

  out="$(PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage all)"
  run_id="$(cat "$repo/.e3d-pilot/latest-run")"
  spec="$repo/.e3d-pilot/runs/$run_id/spec-draft.md"
  rejected="$repo/.e3d-pilot/runs/$run_id/draft-rejected.md"

  [[ ! -f "$spec" ]] || { echo "expected spec-draft.md NOT to be written for a too-large candidate" >&2; exit 1; }
  [[ -f "$rejected" ]] || { echo "expected draft-rejected.md to record the too-large reason" >&2; exit 1; }
  contents="$(cat "$rejected")"
  assert_contains "$contents" "status: too-large"
  assert_contains "$out" "draft: candidate cannot be scoped within configured limits"
  assert_contains "$out" "stopping before negotiate"
  assert_not_contains "$out" "negotiate: not yet implemented"

  rm -rf "$bin_dir" "$response" "$ideate_response"
}

draft_requires_a_selected_candidate() {
  local repo run_id bin_dir out_status
  repo="$(make_repo_with_commit)"
  write_draft_config "$repo"
  run_id="2026-07-26-repo-draft-none"
  write_candidates "$repo" "$run_id" "none"

  bin_dir="$(mktemp -d)"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/claude" <<'EOF'
#!/usr/bin/env bash
echo "should not be invoked" >&2
exit 1
EOF
  chmod +x "$bin_dir/claude"

  out_status=0
  PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage draft --run-id "$run_id" >/tmp/draft-none-out.$$ 2>&1 || out_status=$?
  [[ $out_status -ne 0 ]] || { echo "expected draft to fail clearly when no candidate is selected" >&2; exit 1; }
  assert_contains "$(cat /tmp/draft-none-out.$$)" "run ideate first"
  rm -f /tmp/draft-none-out.$$
  rm -rf "$bin_dir"
}

draft_line_estimate_warns_by_default_and_can_be_enforced() {
  local repo run_id bin_dir response out spec warnings rejected i
  repo="$(make_repo_with_commit)"
  write_draft_config "$repo"
  run_id="2026-07-28-repo-draft-estimate-warning"
  write_candidates "$repo" "$run_id" "candidate-1"

  bin_dir="$(mktemp -d)"
  response="$(mktemp)"
  {
    cat <<'EOF'
```spec
# Bounded but Detailed Change

## Overview

Describe a bounded change with detailed acceptance coverage.

## Goals

- Improve the sample behavior.

## Non-Goals

- Do not change unrelated behavior.

## Existing Files

- `README.md`

## Shared Constraints

- Keep the actual diff under the configured ceiling.

## Phase 1 - Update Readme

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=README.md -->

### Requirements
EOF
    i=1
    while [[ $i -le 31 ]]; do
      printf -- '- Requirement %s remains a concise behavior statement.\n' "$i"
      i=$((i + 1))
    done
    cat <<'EOF'

### Acceptance Criteria

- The actual implementation remains within the configured diff ceiling.
```

---DRAFT-STATUS---
status: ok
reason: detailed specification for a bounded one-file change.
EOF
  } > "$response"
  make_fake_claude_bin_returning "$bin_dir" "$response"

  out="$(PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage draft --run-id "$run_id")"
  spec="$repo/.e3d-pilot/runs/$run_id/spec-draft.md"
  warnings="$repo/.e3d-pilot/runs/$run_id/draft-scope-warnings.txt"
  [[ -f "$spec" ]] || { echo "expected advisory line estimate not to reject the spec" >&2; exit 1; }
  [[ -s "$warnings" ]] || { echo "expected an audit warning for the line estimate" >&2; exit 1; }
  assert_contains "$out" "scope estimate warning recorded"
  assert_contains "$(cat "$warnings")" "advisory only"

  repo="$(make_repo_with_commit)"
  write_draft_config "$repo"
  run_id="2026-07-28-repo-draft-estimate-enforced"
  write_candidates "$repo" "$run_id" "candidate-1"
  out="$(PATH="$bin_dir:$PATH" DRAFT_ENFORCE_LINE_ESTIMATE=1 "$BIN" run --repo "$repo" --stage draft --run-id "$run_id")"
  spec="$repo/.e3d-pilot/runs/$run_id/spec-draft.md"
  rejected="$repo/.e3d-pilot/runs/$run_id/draft-rejected.md"
  [[ ! -f "$spec" ]] || { echo "expected enforced line estimate to reject the spec" >&2; exit 1; }
  [[ -f "$rejected" ]] || { echo "expected enforced estimate rejection artifact" >&2; exit 1; }
  assert_contains "$(cat "$rejected")" "exceeding max_diff_lines=600"

  rm -rf "$bin_dir" "$response"
}

main() {
  draft_produces_spec_that_csr_can_list
  draft_rejects_protected_path_touch_before_writing
  draft_reports_too_large_without_writing_spec_and_stops_all
  draft_requires_a_selected_candidate
  draft_line_estimate_warns_by_default_and_can_be_enforced
  echo "phase5: all tests passed"
}

main "$@"
