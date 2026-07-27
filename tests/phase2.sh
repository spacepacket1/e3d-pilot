#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"
PROVIDERS_DIR="$ROOT/lib/providers"
NEGOTIATE_DIR="$ROOT/lib/negotiate"

assert_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] || {
    printf 'expected to find %q in output:\n%s\n' "$needle" "$haystack" >&2
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

make_prompt_file() {
  local file
  file="$(mktemp)"
  printf 'test prompt\n' > "$file"
  printf '%s' "$file"
}

# --- providers list ---------------------------------------------------

providers_list_reports_local_unavailable_when_unset() {
  local out
  out="$(env -u LOCAL_MODEL_ENDPOINT "$BIN" providers list)"
  assert_contains "$out" "local    unavailable"
}

providers_list_reports_local_available_against_real_http_stub() {
  local dir port server_pid out attempt endpoint
  dir="$(mktemp -d)"
  port=$(( (RANDOM % 5000) + 20000 ))
  endpoint="http://127.0.0.1:$port/"

  (cd "$dir" && exec python3 -m http.server "$port" --bind 127.0.0.1) >/dev/null 2>&1 &
  server_pid=$!

  attempt=0
  until curl -s -o /dev/null -m 1 "$endpoint" || [[ $attempt -ge 50 ]]; do
    attempt=$((attempt + 1))
    sleep 0.1
  done
  if [[ $attempt -ge 50 ]]; then
    kill "$server_pid" 2>/dev/null || true
    rm -rf "$dir"
    echo "throwaway HTTP stub never became reachable" >&2
    exit 1
  fi

  out="$(LOCAL_MODEL_ENDPOINT="$endpoint" "$BIN" providers list)"

  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  rm -rf "$dir"

  assert_contains "$out" "local    available"
}

providers_list_reports_local_unavailable_against_closed_port() {
  local port out
  port=$(( (RANDOM % 5000) + 25000 ))
  out="$(LOCAL_MODEL_ENDPOINT="http://127.0.0.1:$port/" "$BIN" providers list)"
  assert_contains "$out" "local    unavailable"
}

providers_list_reports_claude_and_codex_status() {
  local out
  out="$("$BIN" providers list)"
  assert_contains "$out" "claude"
  assert_contains "$out" "codex"
  assert_contains "$out" "local"
}

# --- provider adapters: contract + dry-run -----------------------------

claude_provider_requires_prompt_file_argument() {
  local status
  set +e
  CLAUDE_BIN=claude "$PROVIDERS_DIR/claude" >/dev/null 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "expected claude provider to fail without a prompt file" >&2; exit 1; }
}

claude_provider_dry_run_prints_command() {
  local prompt_file out
  prompt_file="$(make_prompt_file)"
  out="$(E3D_PILOT_DRY_RUN=1 CLAUDE_BIN=claude CLAUDE_MODEL=sonnet "$PROVIDERS_DIR/claude" "$prompt_file")"
  assert_contains "$out" "claude"
  assert_contains "$out" "--print"
  assert_contains "$out" "--model sonnet"
  assert_contains "$out" "--no-session-persistence"
  assert_contains "$out" "$prompt_file"
  rm -f "$prompt_file"
}

codex_provider_dry_run_prints_safe_defaults() {
  local prompt_file out
  prompt_file="$(make_prompt_file)"
  out="$(E3D_PILOT_DRY_RUN=1 CODEX_BIN=codex "$PROVIDERS_DIR/codex" "$prompt_file")"
  assert_contains "$out" "codex"
  assert_contains "$out" "--ask-for-approval never"
  assert_contains "$out" "--sandbox read-only"
  assert_contains "$out" "$prompt_file"
  rm -f "$prompt_file"
}

codex_provider_dry_run_respects_overrides() {
  local prompt_file out
  prompt_file="$(make_prompt_file)"
  out="$(E3D_PILOT_DRY_RUN=1 CODEX_BIN=codex CODEX_SANDBOX_MODE=workspace-write CODEX_APPROVAL_POLICY=on-request "$PROVIDERS_DIR/codex" "$prompt_file")"
  assert_contains "$out" "--ask-for-approval on-request"
  assert_contains "$out" "--sandbox workspace-write"
  rm -f "$prompt_file"
}

local_provider_reports_unavailable_exit_code_when_unset() {
  local prompt_file status
  prompt_file="$(make_prompt_file)"
  set +e
  env -u LOCAL_MODEL_ENDPOINT "$PROVIDERS_DIR/local" "$prompt_file" >/dev/null 2>&1
  status=$?
  set -e
  assert_eq "$status" "2" "local provider unavailable exit code"
  rm -f "$prompt_file"
}

# --- lib/negotiate/parse-status ----------------------------------------

parse_status_extracts_approved_without_spec() {
  local file out status
  file="$(mktemp)"
  cat > "$file" <<'EOF'
Reviewer commentary.

---STATUS---
status: approved
reason: meets acceptance criteria
EOF
  status="$("$NEGOTIATE_DIR/parse-status" "$file" status)"
  assert_eq "$status" "approved"
  out="$("$NEGOTIATE_DIR/parse-status" "$file" reason)"
  assert_eq "$out" "meets acceptance criteria"
  rm -f "$file"
}

parse_status_extracts_revise_and_spec_block_even_when_fenced() {
  local file status reason spec
  file="$(mktemp)"
  cat > "$file" <<'EOF'
Reviewer commentary.

```
---STATUS---
status: revise
reason: phase 3 touches a protected path
```

```spec
## Phase 1 - Replacement
Body text here.
```
EOF
  status="$("$NEGOTIATE_DIR/parse-status" "$file" status)"
  assert_eq "$status" "revise"
  reason="$("$NEGOTIATE_DIR/parse-status" "$file" reason)"
  assert_eq "$reason" "phase 3 touches a protected path"
  spec="$("$NEGOTIATE_DIR/parse-status" "$file" spec)"
  assert_contains "$spec" "## Phase 1 - Replacement"
  assert_contains "$spec" "Body text here."
  rm -f "$file"
}

parse_status_fails_on_missing_status_block() {
  local file status
  file="$(mktemp)"
  printf 'no status block here\n' > "$file"
  set +e
  "$NEGOTIATE_DIR/parse-status" "$file" >/dev/null 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "expected parse-status to fail without a status block" >&2; exit 1; }
  rm -f "$file"
}

# --- lib/negotiate/convergence ------------------------------------------

convergence_two_entries_all_approved_converges() {
  local status
  set +e
  "$NEGOTIATE_DIR/convergence" approved approved >/dev/null
  status=$?
  set -e
  assert_eq "$status" "0" "2-entry all-approved should converge"
}

convergence_two_entries_one_dissenting_does_not_converge() {
  local status
  set +e
  "$NEGOTIATE_DIR/convergence" approved revise >/dev/null
  status=$?
  set -e
  assert_eq "$status" "1" "2-entry one-dissent should not converge"
}

convergence_three_entries_all_approved_converges() {
  local status
  set +e
  "$NEGOTIATE_DIR/convergence" approved approved approved >/dev/null
  status=$?
  set -e
  assert_eq "$status" "0" "3-entry all-approved should converge"
}

convergence_three_entries_one_dissenting_does_not_converge() {
  local status
  set +e
  "$NEGOTIATE_DIR/convergence" approved revise approved >/dev/null
  status=$?
  set -e
  assert_eq "$status" "1" "3-entry one-dissent should not converge"
}

main() {
  providers_list_reports_local_unavailable_when_unset
  providers_list_reports_local_available_against_real_http_stub
  providers_list_reports_local_unavailable_against_closed_port
  providers_list_reports_claude_and_codex_status
  claude_provider_requires_prompt_file_argument
  claude_provider_dry_run_prints_command
  codex_provider_dry_run_prints_safe_defaults
  codex_provider_dry_run_respects_overrides
  local_provider_reports_unavailable_exit_code_when_unset
  parse_status_extracts_approved_without_spec
  parse_status_extracts_revise_and_spec_block_even_when_fenced
  parse_status_fails_on_missing_status_block
  convergence_two_entries_all_approved_converges
  convergence_two_entries_one_dissenting_does_not_converge
  convergence_three_entries_all_approved_converges
  convergence_three_entries_one_dissenting_does_not_converge
  echo "phase2: all tests passed"
}

main "$@"
