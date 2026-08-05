#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"
SAMPLE_CONFIG="$ROOT/examples/sample-config.json"
PROVIDER="$ROOT/lib/providers/phase15-stub"

trap 'rm -f "$PROVIDER"' EXIT

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

make_repo() {
  local repo
  repo="$(mktemp -d)"
  repo="$(cd "$repo" && pwd -P)"
  git init -q "$repo"
  git -C "$repo" config user.email "phase15@example.com"
  git -C "$repo" config user.name "Phase 15"
  printf '# Phase 15 Repo\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m initial
  mkdir -p "$repo/.e3d-pilot"
  jq '.providers.discover="phase15-stub"
      | .providers.ideate="phase15-stub"
      | .providers.draft="phase15-stub"
      | .providers.negotiate=["phase15-stub"]
      | .providers.review="phase15-stub"
      | .pr.backend="local"' "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  printf '%s' "$repo"
}

make_provider() {
  cat > "$PROVIDER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${E3D_PILOT_CHECK:-0}" == 1 ]] && { echo available; exit 0; }
prompt="${1:-}"
case "$(basename "$prompt")" in
  discover-prompt.md)
    printf 'Finding: approval gate test context\n'
    ;;
  ideate-prompt.md)
    cat <<'OUT'
### Candidate 1: Approval gated implementation
Duplicate: no
Category: workflow
Analogy: release train
Attraction (1-5): 4
Retention (1-5): 3
Revenue (1-5|n/a): 2
Effort: low
Dedup rationale: no matching prior work
Description: Confirm implementation waits for explicit approval.
---IDEATE-STATUS---
selected: candidate-1
reason: best candidate
OUT
    ;;
  draft-prompt.md)
    printf 'draft\n' >> "${PHASE15_TRACE_FILE:?}"
    cat <<'OUT'
---DRAFT-STATUS---
status: ok
reason: ok
```spec
# Stub
```
OUT
    ;;
  negotiate-*)
    printf 'negotiate\n' >> "${PHASE15_TRACE_FILE:?}"
    printf '%s\nstatus: approved\nreason: ok\n' '---STATUS---'
    ;;
  review-prompt.md)
    printf 'review\n' >> "${PHASE15_TRACE_FILE:?}"
    printf 'review ok\n'
    ;;
  *)
    printf 'unexpected prompt: %s\n' "$prompt" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$PROVIDER"
}

selected_idea_id() {
  local repo="$1"
  "$BIN" ideas list --repo "$repo" --status proposed --json | jq -r 'map(select(.selected_by_model == true))[0].idea_id'
}

default_all_stops_pending_before_draft() {
  local repo trace out status idea
  repo="$(make_repo)"
  trace="$(mktemp)"

  set +e
  out="$(PHASE15_TRACE_FILE="$trace" "$BIN" run --repo "$repo" --stage all 2>&1)"
  status=$?
  set -e

  assert_eq "$status" "0" "pending approval is a successful stop"
  assert_contains "$out" "pilot: pending-approval idea="
  assert_contains "$out" "approve with: e3d-pilot ideas approve --repo $repo idea-"
  assert_not_contains "$(cat "$trace")" "draft"
  [[ ! -f "$repo/.e3d-pilot/runs/"*/spec-draft.md ]] || { echo "draft artifact should not exist" >&2; exit 1; }
  [[ ! -f "$repo/.e3d-pilot/runs/"*/execute-worktree.txt ]] || { echo "execute worktree should not be created" >&2; exit 1; }
  idea="$(selected_idea_id "$repo")"
  [[ "$idea" == idea-* ]] || { echo "expected selected proposed idea" >&2; exit 1; }
  assert_eq "$(jq -r '.status' "$repo/.e3d-pilot/ideas/$idea/idea.json")" "proposed" "selected idea status"

  rm -rf "$repo"; rm -f "$trace"
}

direct_stages_fail_without_approval_before_mutation() {
  local repo trace out status run_id
  repo="$(make_repo)"
  trace="$(mktemp)"
  PHASE15_TRACE_FILE="$trace" "$BIN" run --repo "$repo" --stage all >/dev/null
  run_id="$(cat "$repo/.e3d-pilot/latest-run")"
  printf '# Final Spec\n' > "$repo/.e3d-pilot/runs/$run_id/spec-final.md"

  set +e
  out="$(PHASE15_TRACE_FILE="$trace" "$BIN" run --repo "$repo" --stage draft --run-id "$run_id" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "draft should fail without approval" >&2; exit 1; }
  assert_contains "$out" "not approved for implementation"
  assert_not_contains "$(cat "$trace")" "draft"
  [[ ! -f "$repo/.e3d-pilot/runs/$run_id/spec-draft.md" ]] || { echo "draft should not create spec-draft.md" >&2; exit 1; }

  set +e
  out="$(PHASE15_TRACE_FILE="$trace" "$BIN" run --repo "$repo" --stage execute --run-id "$run_id" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "execute should fail without approval" >&2; exit 1; }
  assert_contains "$out" "not approved for implementation"
  [[ ! -f "$repo/.e3d-pilot/runs/$run_id/execute-worktree.txt" ]] || { echo "execute should not create a worktree" >&2; exit 1; }
  assert_eq "$(git -C "$repo" status --short --untracked-files=no)" "" "tracked checkout must remain clean"

  rm -rf "$repo"; rm -f "$trace"
}

legacy_runs_have_no_implicit_approval() {
  local repo run_id out status
  repo="$(make_repo)"
  run_id="legacy-run"
  mkdir -p "$repo/.e3d-pilot/runs/$run_id"
  printf '%s\n' "selected: candidate-1" > "$repo/.e3d-pilot/runs/$run_id/candidates.md"

  set +e
  out="$("$BIN" run --repo "$repo" --stage draft --run-id "$run_id" 2>&1)"
  status=$?
  set -e

  [[ $status -ne 0 ]] || { echo "legacy draft should fail" >&2; exit 1; }
  assert_contains "$out" "Legacy runs created before approval-gated ideas have no implicit approval"
  assert_contains "$out" "materialize idea records"
  assert_contains "$out" "e3d-pilot ideas approve --repo $repo <idea-id>"

  rm -rf "$repo"
}

digest_mismatch_blocks_after_approval() {
  local repo run_id idea out status trace tmp
  repo="$(make_repo)"
  trace="$(mktemp)"
  PHASE15_TRACE_FILE="$trace" "$BIN" run --repo "$repo" --stage all >/dev/null
  run_id="$(cat "$repo/.e3d-pilot/latest-run")"
  idea="$(selected_idea_id "$repo")"
  "$BIN" ideas approve --repo "$repo" "$idea" --actor "approver@example.com" >/dev/null
  tmp="$(mktemp)"
  jq '.title = "Edited after approval"' "$repo/.e3d-pilot/ideas/$idea/idea.json" > "$tmp"
  mv "$tmp" "$repo/.e3d-pilot/ideas/$idea/idea.json"

  set +e
  out="$(PHASE15_TRACE_FILE="$trace" "$BIN" run --repo "$repo" --stage draft --run-id "$run_id" 2>&1)"
  status=$?
  set -e

  [[ $status -ne 0 ]] || { echo "draft should fail after digest mismatch" >&2; exit 1; }
  assert_contains "$out" "approval digest no longer matches"
  assert_not_contains "$(cat "$trace")" "draft"

  rm -rf "$repo"; rm -f "$trace"
}

fleet_reports_pending_separately_from_failures() {
  local good broken fleet out status
  good="$(make_repo)"
  broken="$(mktemp -d)"
  git init -q "$broken"
  git -C "$broken" config user.email "broken@example.com"
  git -C "$broken" config user.name "Broken"
  printf '# Broken\n' > "$broken/README.md"
  git -C "$broken" add README.md
  git -C "$broken" commit -q -m initial
  fleet="$(mktemp)"
  jq -n --arg good "$good" --arg broken "$broken" '[$good,$broken]' > "$fleet"

  set +e
  out="$("$BIN" fleet "$fleet" 2>&1)"
  status=$?
  set -e

  [[ $status -ne 0 ]] || { echo "fleet should exit nonzero because one repo failed" >&2; exit 1; }
  assert_contains "$out" "fleet: PENDING $good"
  assert_contains "$out" "fleet: FAIL $broken"
  assert_contains "$out" "total=2 passed=0 failed=1 pending=1"

  rm -rf "$good" "$broken"; rm -f "$fleet"
}

config_approval_validation() {
  local repo out status
  repo="$(make_repo)"
  jq 'del(.approval)' "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  "$BIN" config validate "$repo" >/dev/null

  jq '.approval = {"implementation_required": false, "merge_required": false}' "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  "$BIN" config validate "$repo" >/dev/null

  jq '.approval = {"implementation_required": true}' "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  set +e
  out="$("$BIN" config validate "$repo" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "malformed approval config should fail" >&2; exit 1; }
  assert_contains "$out" "config.approval must include implementation_required and merge_required"

  jq -e '.approval.implementation_required == true and .approval.merge_required == true' "$SAMPLE_CONFIG" >/dev/null

  rm -rf "$repo"
}

main() {
  make_provider
  bash -n "$BIN"
  bash -n "$ROOT/lib/ideas/ledger.sh"
  bash -n "$ROOT/lib/ideas/materialize.sh"
  default_all_stops_pending_before_draft
  direct_stages_fail_without_approval_before_mutation
  legacy_runs_have_no_implicit_approval
  digest_mismatch_blocks_after_approval
  fleet_reports_pending_separately_from_failures
  config_approval_validation
  echo "phase15: all tests passed"
}

main "$@"
