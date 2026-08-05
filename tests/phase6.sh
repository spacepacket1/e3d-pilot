#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"
SAMPLE_CONFIG="$ROOT/examples/sample-config.json"

PHASE6_PROVIDER_NAMES=()

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

cleanup_phase6_providers() {
  local name
  for name in "${PHASE6_PROVIDER_NAMES[@]}"; do
    rm -f "$ROOT/lib/providers/$name"
  done
}

trap cleanup_phase6_providers EXIT

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

write_phase6_config() {
  local repo="$1" negotiate_json="$2"
  mkdir -p "$repo/.e3d-pilot"
  jq --argjson negotiate "$negotiate_json" \
    '.providers.negotiate = $negotiate
     | .approval.implementation_required = false | .approval.merge_required = false' \
    "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
}

write_phase6_draft() {
  local repo="$1" run_id="$2"
  mkdir -p "$repo/.e3d-pilot/runs/$run_id"
  cat > "$repo/.e3d-pilot/runs/$run_id/spec-draft.md" <<'EOF'
# Phase 6 Draft

## Overview

Initial draft for negotiate-loop testing.

## Goals

- Exercise reviewer sequencing and replacement propagation.

## Non-Goals

- Do not change the repository itself.

## Existing Files

- `README.md`

## Shared Constraints

- Keep this draft intentionally small.

## Phase 1 - Baseline

<!-- runner:model=claude:sonnet -->
<!-- pilot:touches=README.md -->

### Requirements

- Provide a baseline draft for negotiation tests.

### Acceptance Criteria

- The initial draft can be replaced by reviewers.
EOF
}

make_phase6_provider() {
  local name="$1" mode="$2" path
  path="$ROOT/lib/providers/$name"
  PHASE6_PROVIDER_NAMES+=("$name")
  cat <<'EOF' | sed "s/__NAME__/$name/g; s/__MODE__/$mode/g" > "$path"
#!/usr/bin/env bash
set -euo pipefail

prompt_file="${1:-}"
if [[ "${E3D_PILOT_CHECK:-0}" == "1" ]]; then
  printf 'available (%s)\n' '__NAME__'
  exit 0
fi

[[ -n "$prompt_file" ]] || { echo "error: prompt file path required as \$1" >&2; exit 1; }
[[ -f "$prompt_file" ]] || { echo "error: prompt file not found: $prompt_file" >&2; exit 1; }

if [[ -n "${NEGOTIATE_TRACE_FILE:-}" ]]; then
  marker="$(grep -o 'phase6-replacement-[ab]' "$prompt_file" | tail -n1 || true)"
  printf '%s|%s\n' '__NAME__' "${marker:-initial}" >> "$NEGOTIATE_TRACE_FILE"
fi
if [[ -n "${NEGOTIATE_PWD_TRACE_FILE:-}" ]]; then
  printf '%s\n' "$PWD" >> "$NEGOTIATE_PWD_TRACE_FILE"
fi

prompt="$(cat "$prompt_file")"
case '__MODE__' in
  approve)
    cat <<'OUT'
---STATUS---
status: approved
reason: approved by stub
OUT
    ;;
  approve-on-b)
    if grep -q 'phase6-replacement-b' <<<"$prompt"; then
      cat <<'OUT'
---STATUS---
status: approved
reason: replacement B has already landed
OUT
    else
      echo "error: expected replacement B to be present in prompt" >&2
      exit 1
    fi
    ;;
  always-revise)
    cat <<'OUT'
---STATUS---
status: revise
reason: stub always requests another pass
```spec
# Phase 6 Replacement

phase6-replacement-a
```
OUT
    ;;
  revise-a)
    if grep -q 'phase6-replacement-b' <<<"$prompt"; then
      cat <<'OUT'
---STATUS---
status: approved
reason: replacement B has already landed
OUT
    else
      cat <<'OUT'
---STATUS---
status: revise
reason: first reviewer wants replacement A
```spec
# Phase 6 Replacement A

phase6-replacement-a
```
OUT
    fi
    ;;
  revise-b)
    if grep -q 'phase6-replacement-b' <<<"$prompt"; then
      cat <<'OUT'
---STATUS---
status: approved
reason: replacement B has already landed
OUT
    elif grep -q 'phase6-replacement-a' <<<"$prompt"; then
      cat <<'OUT'
---STATUS---
status: revise
reason: second reviewer wants replacement B
```spec
# Phase 6 Replacement B

phase6-replacement-b
```
OUT
    else
      echo "error: second reviewer expected to see replacement A in prompt" >&2
      exit 1
    fi
    ;;
  guard)
    cat <<'OUT'
---STATUS---
status: approved
reason: guard provider should never be called
OUT
    ;;
  malformed-once)
    if [[ "$prompt_file" == *-attempt2-prompt.md ]]; then
      cat <<'OUT'
---STATUS---
status: approved
reason: retry returned the required status block
OUT
    else
      printf 'approved, but missing the required parser marker\n'
    fi
    ;;
  *)
    echo "error: unknown phase6 stub mode: __MODE__" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$path"
}

negotiate_two_reviewers_converge_round_one() {
  local repo run_id trace out status spec_final log contents
  repo="$(make_repo_with_commit)"
  run_id="2026-07-27-repo-negotiate-two"
  write_phase6_config "$repo" '["phase6-approve-a","phase6-approve-b"]'
  write_phase6_draft "$repo" "$run_id"
  make_phase6_provider "phase6-approve-a" "approve"
  make_phase6_provider "phase6-approve-b" "approve"

  trace="$(mktemp)"
  out="$(NEGOTIATE_TRACE_FILE="$trace" "$BIN" run --repo "$repo" --stage negotiate --run-id "$run_id")"

  spec_final="$repo/.e3d-pilot/runs/$run_id/spec-final.md"
  log="$repo/.e3d-pilot/runs/$run_id/negotiation-log.md"
  [[ -f "$spec_final" ]] || { echo "expected spec-final.md to be written" >&2; exit 1; }
  [[ -f "$log" ]] || { echo "expected negotiation-log.md to be written" >&2; exit 1; }

  contents="$(cat "$spec_final")"
  assert_contains "$contents" "Initial draft for negotiate-loop testing."
  assert_contains "$out" "converged in round 1"
  assert_contains "$(cat "$log")" "## Round 1"
  assert_contains "$(cat "$log")" "Converged in round 1."
  assert_eq "$(cat "$trace")" $'phase6-approve-a|initial\nphase6-approve-b|initial' "two-reviewer trace order"

  rm -f "$trace"
}

negotiate_unavailable_reviewer_fails_before_round_one_requests() {
  local repo run_id trace out status guard_invoked
  repo="$(make_repo_with_commit)"
  run_id="2026-07-27-repo-negotiate-unavailable"
  write_phase6_config "$repo" '["local","phase6-guard"]'
  write_phase6_draft "$repo" "$run_id"
  make_phase6_provider "phase6-guard" "guard"

  trace="$(mktemp)"
  set +e
  out="$(NEGOTIATE_TRACE_FILE="$trace" env -u LOCAL_MODEL_ENDPOINT "$BIN" run --repo "$repo" --stage negotiate --run-id "$run_id" 2>&1)"
  status=$?
  set -e

  assert_eq "$status" "1" "unavailable reviewer should fail the stage"
  assert_contains "$out" 'negotiate reviewer "local" unavailable'
  assert_contains "$out" 'LOCAL_MODEL_ENDPOINT is not set'
  guard_invoked="$(cat "$trace" 2>/dev/null || true)"
  assert_eq "$guard_invoked" "" "other reviewer should not be called after unavailable reviewer check"
  assert_not_contains "$out" "phase6-guard"

  rm -f "$trace"
}

negotiate_always_revise_hits_max_rounds_and_needs_human() {
  local repo run_id trace out status spec_final log contents
  repo="$(make_repo_with_commit)"
  run_id="2026-07-27-repo-negotiate-revise"
  write_phase6_config "$repo" '["phase6-always-revise"]'
  write_phase6_draft "$repo" "$run_id"
  make_phase6_provider "phase6-always-revise" "always-revise"

  trace="$(mktemp)"
  set +e
  out="$(NEGOTIATE_TRACE_FILE="$trace" NEGOTIATE_MAX_ROUNDS=2 "$BIN" run --repo "$repo" --stage negotiate --run-id "$run_id" 2>&1)"
  status=$?
  set -e

  assert_eq "$status" "3" "max-round failure should exit with needs-human status"
  assert_contains "$out" "needs human after 2 rounds"
  assert_contains "$out" "spec-draft.md and negotiation-log.md left in place"

  spec_final="$repo/.e3d-pilot/runs/$run_id/spec-final.md"
  log="$repo/.e3d-pilot/runs/$run_id/negotiation-log.md"
  [[ ! -f "$spec_final" ]] || { echo "did not expect spec-final.md on needs-human exit" >&2; exit 1; }
  [[ -f "$log" ]] || { echo "expected negotiation-log.md to remain in place" >&2; exit 1; }
  assert_contains "$(cat "$log")" "Needs human review after 2 rounds"
  assert_eq "$(wc -l < "$trace" | tr -d '[:space:]')" "2" "always-revise provider should run once per round"

  rm -f "$trace"
}

negotiate_three_reviewers_apply_replacements_in_order() {
  local repo run_id trace out status spec_final log contents trace_contents
  repo="$(make_repo_with_commit)"
  run_id="2026-07-27-repo-negotiate-three"
  write_phase6_config "$repo" '["phase6-revise-a","phase6-revise-b","phase6-approve-c"]'
  write_phase6_draft "$repo" "$run_id"
  make_phase6_provider "phase6-revise-a" "revise-a"
  make_phase6_provider "phase6-revise-b" "revise-b"
  make_phase6_provider "phase6-approve-c" "approve-on-b"

  trace="$(mktemp)"
  out="$(NEGOTIATE_TRACE_FILE="$trace" "$BIN" run --repo "$repo" --stage negotiate --run-id "$run_id")"

  spec_final="$repo/.e3d-pilot/runs/$run_id/spec-final.md"
  log="$repo/.e3d-pilot/runs/$run_id/negotiation-log.md"
  [[ -f "$spec_final" ]] || { echo "expected spec-final.md to be written" >&2; exit 1; }
  [[ -f "$log" ]] || { echo "expected negotiation-log.md to be written" >&2; exit 1; }

  contents="$(cat "$spec_final")"
  assert_contains "$contents" "phase6-replacement-b"
  assert_contains "$out" "converged in round 2"
  assert_contains "$(cat "$log")" "Round Result: not converged"
  assert_contains "$(cat "$log")" "phase6-replacement-a"
  assert_contains "$(cat "$log")" "phase6-replacement-b"
  trace_contents="$(cat "$trace")"
  assert_eq "$trace_contents" $'phase6-revise-a|initial\nphase6-revise-b|phase6-replacement-a\nphase6-approve-c|phase6-replacement-b\nphase6-revise-a|phase6-replacement-b\nphase6-revise-b|phase6-replacement-b\nphase6-approve-c|phase6-replacement-b' "three-reviewer sequential trace"

  rm -f "$trace"
}

negotiate_retries_one_malformed_response_from_repo_cwd() {
  local repo run_id trace pwd_trace out spec_final response retry_response
  repo="$(make_repo_with_commit)"
  run_id="2026-07-27-repo-negotiate-parse-retry"
  write_phase6_config "$repo" '["phase6-malformed-once"]'
  write_phase6_draft "$repo" "$run_id"
  make_phase6_provider "phase6-malformed-once" "malformed-once"

  trace="$(mktemp)"
  pwd_trace="$(mktemp)"
  out="$(NEGOTIATE_TRACE_FILE="$trace" NEGOTIATE_PWD_TRACE_FILE="$pwd_trace" "$BIN" run --repo "$repo" --stage negotiate --run-id "$run_id" 2>&1)"

  spec_final="$repo/.e3d-pilot/runs/$run_id/spec-final.md"
  response="$repo/.e3d-pilot/runs/$run_id/negotiate-round-1-reviewer-1-phase6-malformed-once-response.md"
  retry_response="$repo/.e3d-pilot/runs/$run_id/negotiate-round-1-reviewer-1-phase6-malformed-once-attempt2-response.md"
  [[ -f "$spec_final" ]] || { echo "expected retry to converge and write spec-final.md" >&2; exit 1; }
  [[ -f "$response" && -f "$retry_response" ]] || { echo "expected both negotiation response artifacts" >&2; exit 1; }
  assert_contains "$out" "response failed to parse; retrying once"
  assert_contains "$out" "converged in round 1"
  assert_eq "$(wc -l < "$trace" | tr -d '[:space:]')" "2" "malformed response should be retried exactly once"
  while IFS= read -r provider_pwd; do
    assert_eq "$(cd "$provider_pwd" && pwd -P)" "$(cd "$repo" && pwd -P)" "negotiate provider cwd"
  done < "$pwd_trace"

  rm -f "$trace" "$pwd_trace"
}


# Same test body run at two different reviewer-array arities, to directly
# confirm (per this phase's acceptance criteria) that the convergence code
# path is identical regardless of how many reviewers are configured -- not
# just exercised by two structurally different scenarios elsewhere in this
# file.
negotiate_all_approve_converges_at_arity() {
  local count="$1" repo run_id trace out spec_final log name names=() i expected_trace=""
  repo="$(make_repo_with_commit)"
  run_id="2026-07-27-repo-negotiate-arity-$count"
  for ((i = 1; i <= count; i++)); do
    names+=("phase6-arity${count}-reviewer${i}")
  done
  write_phase6_config "$repo" "$(printf '%s\n' "${names[@]}" | jq -R . | jq -s .)"
  write_phase6_draft "$repo" "$run_id"
  for name in "${names[@]}"; do
    make_phase6_provider "$name" "approve"
  done

  trace="$(mktemp)"
  out="$(NEGOTIATE_TRACE_FILE="$trace" "$BIN" run --repo "$repo" --stage negotiate --run-id "$run_id")"

  spec_final="$repo/.e3d-pilot/runs/$run_id/spec-final.md"
  log="$repo/.e3d-pilot/runs/$run_id/negotiation-log.md"
  [[ -f "$spec_final" ]] || { echo "expected spec-final.md to be written ($count-reviewer arity)" >&2; exit 1; }
  [[ -f "$log" ]] || { echo "expected negotiation-log.md to be written ($count-reviewer arity)" >&2; exit 1; }

  assert_contains "$out" "converged in round 1"
  assert_contains "$(cat "$log")" "## Round 1"

  for name in "${names[@]}"; do
    expected_trace+="${name}|initial"$'\n'
  done
  expected_trace="${expected_trace%$'\n'}"
  assert_eq "$(cat "$trace")" "$expected_trace" "$count-reviewer all-approve trace order"

  rm -f "$trace"
}

main() {
  negotiate_two_reviewers_converge_round_one
  negotiate_unavailable_reviewer_fails_before_round_one_requests
  negotiate_always_revise_hits_max_rounds_and_needs_human
  negotiate_three_reviewers_apply_replacements_in_order
  negotiate_retries_one_malformed_response_from_repo_cwd
  negotiate_all_approve_converges_at_arity 2
  negotiate_all_approve_converges_at_arity 3
  echo "phase6: all tests passed"
}

main "$@"
