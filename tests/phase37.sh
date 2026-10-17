#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"
SAMPLE_CONFIG="$ROOT/examples/sample-config.json"
PROVIDER="$ROOT/lib/providers/phase37-provider"

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

cleanup() {
  rm -f "$PROVIDER"
}
trap cleanup EXIT

install_provider() {
  cat > "$PROVIDER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
prompt_file="${1:-}"
if [[ "${E3D_PILOT_CHECK:-0}" == "1" ]]; then
  printf 'available (phase37-provider)\n'
  exit 0
fi
[[ -n "$prompt_file" && -f "$prompt_file" ]] || { echo "missing prompt" >&2; exit 1; }
case "$(basename "$prompt_file")" in
  draft-prompt.md)
    [[ -n "${PHASE37_TRACE_FILE:-}" ]] && printf 'draft\n' >> "$PHASE37_TRACE_FILE"
    cat <<'OUT'
```spec
# Repair Fixture

## Overview

Touch the README through the approved implementation flow.

## Goals

- Exercise pause and resume.

## Non-Goals

- No protected path changes.

## Existing Files

- `README.md`

## Shared Constraints

- Keep the fixture small.

## Phase 1 - Update Readme

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=README.md -->
<!-- runner:verify=test -f README.md -->

### Requirements

- Update README.md.

### Acceptance Criteria

- README.md still exists.
```

---DRAFT-STATUS---
status: ok
reason: scoped fixture
OUT
    ;;
  negotiate-*)
    [[ -n "${PHASE37_TRACE_FILE:-}" ]] && printf 'negotiate\n' >> "$PHASE37_TRACE_FILE"
    cat <<'OUT'
---STATUS---
status: approved
reason: fixture approved
OUT
    ;;
  review-prompt.md)
    [[ -n "${PHASE37_TRACE_FILE:-}" ]] && printf 'review\n' >> "$PHASE37_TRACE_FILE"
    printf 'review ok\n'
    ;;
  *)
    echo "unexpected prompt: $prompt_file" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$PROVIDER"
}

make_e3d_code_bin() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/e3d-code" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
spec="${1:?spec required}"
stage="${2:?stage required}"
[[ "$stage" == "all" && -f "$spec" ]] || exit 1
[[ -n "${PHASE37_CODE_TRACE:-}" ]] && printf 'e3d-code\n' >> "$PHASE37_CODE_TRACE"
mkdir -p .e3d-code
printf '{"phase":1,"status":"ok"}\n' > .e3d-code/manifest.json
printf '\nimplemented by phase37 e3d-code\n' >> README.md
EOF
  chmod +x "$bin_dir/e3d-code"
}

make_gh_stub() {
  local bin_dir="$1" fail_marker="$2" pr_url="$3" trace="$4"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$trace"
if [[ "\${1:-}" == "pr" && "\${2:-}" == "create" ]]; then
  if [[ -f "$fail_marker" ]]; then
    echo "could not add label: 'e3d-pilot' not found" >&2
    exit 1
  fi
  printf '%s\n' "$pr_url"
  exit 0
fi
exit 1
EOF
  chmod +x "$bin_dir/gh"
}

make_repo() {
  local repo
  repo="$(mktemp -d)"
  git init -q "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test User"
  cat > "$repo/README.md" <<'EOF'
# Phase 37 Repo
EOF
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m "initial"
  mkdir -p "$repo/.e3d-pilot"
  jq \
    '.verify = ["test -f README.md"]
     | .pr.backend = "github"
     | .pr.labels = ["e3d-pilot"]
     | .providers.draft = "phase37-provider"
     | .providers.negotiate = ["phase37-provider"]
     | .providers.review = "phase37-provider"
     | del(.live_verify)' \
    "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  printf '%s' "$repo"
}

ingest_idea() {
  local repo="$1" run_id="$2" title="$3" candidate_json
  candidate_json="$(mktemp)"
  jq -ncS --arg title "$title" '{
    title:$title,
    summary:"Pause/resume fixture implementation.",
    scores:{attraction:3,retention:3,revenue:2,effort:"low"},
    category:"testing",
    dedup_rationale:"new fixture",
    validation:{approvable:true,eligibility_reason:null,warnings:[]}
  }' > "$candidate_json"
  "$BIN" ideas ingest --repo "$repo" --run-id "$run_id" --candidate-id candidate-1 --candidate-json "$candidate_json"
  rm -f "$candidate_json"
}

run_id_from_failure_output() {
  local out="$1"
  [[ "$out" =~ run=([^[:space:]]+)$ ]] || { echo "could not parse run id from: $out" >&2; exit 1; }
  printf '%s' "${BASH_REMATCH[1]}"
}


setup_world() {  # sets: repo idea code_bin gh_bin bare pr_url code_trace provider_trace
  repo="$(make_repo)"
  code_bin="$(mktemp -d)"; make_e3d_code_bin "$code_bin"
  bare="$(mktemp -d)"; git init -q --bare "$bare"; git -C "$repo" remote add origin "$bare"
  gh_bin="$(mktemp -d)"; pr_url="https://github.com/example/phase37/pull/1"
  make_gh_stub "$gh_bin" "$(mktemp -u)" "$pr_url" "$(mktemp)"
  code_trace="$(mktemp)"; provider_trace="$(mktemp)"
  idea="$(ingest_idea "$repo" run-1 "Pausable delivery")"
  "$BIN" ideas approve --repo "$repo" "$idea" --actor approver@example.com >/dev/null
}

pilot() {  # pilot <args...>, with the fakes on PATH and traces wired
  PHASE37_CODE_TRACE="$code_trace" PHASE37_TRACE_FILE="$provider_trace" PATH="$code_bin:$gh_bin:$PATH" "$BIN" "$@"
}

status_of() { jq -r '.status' "$repo/.e3d-pilot/ideas/$idea/idea.json"; }

pause_stops_before_execute_and_runs_nothing_after() {
  local repo idea code_bin gh_bin bare pr_url code_trace provider_trace out run_id run_dir
  setup_world
  out="$(pilot ideas implement --repo "$repo" --stop-before execute "$idea" 2>&1)"
  assert_contains "$out" "ideas: paused $idea"
  assert_contains "$out" "before=execute"
  [[ "$out" =~ run=([^[:space:]]+) ]] || { echo "no run id in: $out" >&2; exit 1; }
  run_id="${BASH_REMATCH[1]}"; run_dir="$repo/.e3d-pilot/runs/$run_id"

  assert_eq "$(status_of)" "implementing" "a paused idea stays implementing (no new ledger state)"
  [[ -f "$run_dir/spec-final.md" ]] || { echo "negotiate should have produced spec-final.md before the pause" >&2; exit 1; }
  [[ "$(cut -f1 "$run_dir/paused-before.txt")" == "execute" ]] || { echo "pause marker should name the stage" >&2; exit 1; }
  [[ ! -s "$code_trace" ]] || { echo "e3d-code must not run before the pause point" >&2; exit 1; }
  [[ ! -f "$run_dir/execute-worktree.txt" ]] || { echo "no worktree should exist before execute" >&2; exit 1; }
  assert_contains "$(cat "$run_dir/implementation-stage-log.md")" "paused before execute"
  assert_eq "$(wc -l < "$provider_trace" | tr -d '[:space:]')" "2" "only draft and negotiate should have run"
  rm -rf "$code_bin" "$gh_bin" "$bare"
}

resume_runs_only_the_remaining_stages_and_completes() {
  local repo idea code_bin gh_bin bare pr_url code_trace provider_trace out run_id state
  setup_world
  out="$(pilot ideas implement --repo "$repo" --stop-before execute "$idea" 2>&1)"
  [[ "$out" =~ run=([^[:space:]]+) ]] && run_id="${BASH_REMATCH[1]}"

  out="$(pilot ideas resume --repo "$repo" "$idea" 2>&1)"
  assert_contains "$out" "ideas: implemented $idea run=$run_id (resumed from execute)"
  assert_eq "$(status_of)" "implemented" "status after resume"
  assert_eq "$(wc -l < "$code_trace" | tr -d '[:space:]')" "1" "e3d-code runs exactly once, on resume"
  assert_eq "$(wc -l < "$provider_trace" | tr -d '[:space:]')" "3" "draft and negotiate are not redone; review runs once"
  state="$("$BIN" ideas show --repo "$repo" "$idea" --json)"
  assert_eq "$(jq -r '.outcomes[-1].targets[0].run_id' <<<"$state")" "$run_id" "outcome references the paused run"
  assert_eq "$(jq -r '.outcomes[-1].targets[0].pr_url' <<<"$state")" "$pr_url" "PR recorded"
  [[ ! -f "$repo/.e3d-pilot/runs/$run_id/paused-before.txt" ]] || { echo "pause marker should be cleared on resume" >&2; exit 1; }

  set +e; out="$(pilot ideas resume --repo "$repo" "$idea" 2>&1)"; local st=$?; set -e
  [[ $st -ne 0 ]] || { echo "resume on an implemented idea must refuse" >&2; exit 1; }
  assert_contains "$out" "only applies to an idea paused mid-implementation"
  rm -rf "$code_bin" "$gh_bin" "$bare"
}

cancel_paused_records_failure_and_allows_a_fresh_retry() {
  local repo idea code_bin gh_bin bare pr_url code_trace provider_trace out run_id state st
  setup_world
  out="$(pilot ideas implement --repo "$repo" --stop-before execute "$idea" 2>&1)"
  [[ "$out" =~ run=([^[:space:]]+) ]] && run_id="${BASH_REMATCH[1]}"

  set +e; out="$(pilot ideas cancel-paused --repo "$repo" "$idea" 2>&1)"; st=$?; set -e
  [[ $st -ne 0 ]] || { echo "cancel-paused must require --reason" >&2; exit 1; }
  assert_contains "$out" "requires --reason"

  out="$(pilot ideas cancel-paused --repo "$repo" --reason "plan looks wrong" "$idea" 2>&1)"
  assert_contains "$out" "cancelled paused implementation of $idea"
  assert_eq "$(status_of)" "implementation_failed" "status after cancel"
  [[ ! -f "$repo/.e3d-pilot/runs/$run_id/paused-before.txt" ]] || { echo "marker should be cleared" >&2; exit 1; }
  [[ ! -s "$code_trace" ]] || { echo "cancel must never run e3d-code" >&2; exit 1; }
  state="$("$BIN" ideas show --repo "$repo" "$idea" --json)"
  assert_contains "$(jq -r '.events // [] | tostring' <<<"$state")$(cat "$repo/.e3d-pilot/events.jsonl")" "plan looks wrong"

  set +e; out="$(pilot ideas resume --repo "$repo" "$idea" 2>&1)"; st=$?; set -e
  [[ $st -ne 0 ]] || { echo "resume after cancel must refuse" >&2; exit 1; }

  out="$(pilot ideas implement --repo "$repo" "$idea" 2>&1)"
  assert_contains "$out" "ideas: implemented $idea"
  assert_eq "$(status_of)" "implemented" "a cancelled idea can be retried with a normal implement"
  rm -rf "$code_bin" "$gh_bin" "$bare"
}

stop_before_validation() {
  local repo idea code_bin gh_bin bare pr_url code_trace provider_trace out st
  setup_world
  for bad in draft bogus; do
    set +e; out="$(pilot ideas implement --repo "$repo" --stop-before "$bad" "$idea" 2>&1)"; st=$?; set -e
    [[ $st -ne 0 ]] || { echo "--stop-before $bad must be rejected" >&2; exit 1; }
    assert_contains "$out" "stop-before"
  done
  assert_eq "$(status_of)" "approved_for_implementation" "a rejected flag must not start implementation"
  [[ ! -s "$provider_trace" ]] || { echo "validation must happen before any stage runs" >&2; exit 1; }
  set +e; out="$(pilot ideas resume --repo "$repo" "$idea" 2>&1)"; st=$?; set -e
  [[ $st -ne 0 ]] || { echo "resume on a never-started idea must refuse" >&2; exit 1; }
  assert_contains "$out" "only applies to an idea paused mid-implementation"
  rm -rf "$code_bin" "$gh_bin" "$bare"
}

resume_refuses_when_the_base_moved_since_approval() {
  local repo idea code_bin gh_bin bare pr_url code_trace provider_trace out st
  setup_world
  # Discovered ideas record the base in their source run's findings.md; give this one the same.
  mkdir -p "$repo/.e3d-pilot/runs/run-1"
  printf 'head_sha: %s\n' "$(git -C "$repo" rev-parse HEAD)" > "$repo/.e3d-pilot/runs/run-1/findings.md"
  pilot ideas implement --repo "$repo" --stop-before execute "$idea" >/dev/null 2>&1
  printf 'drift\n' >> "$repo/README.md"
  git -C "$repo" commit -q -am "move the base after approval"
  set +e; out="$(pilot ideas resume --repo "$repo" "$idea" 2>&1)"; st=$?; set -e
  [[ $st -ne 0 ]] || { echo "resume must refuse when the base SHA changed" >&2; exit 1; }
  assert_contains "$out" "base SHA changed since approval"
  [[ ! -s "$code_trace" ]] || { echo "e3d-code must not run after a refused resume" >&2; exit 1; }
  assert_eq "$(status_of)" "implementing" "refused resume leaves the pause in place"
  rm -rf "$code_bin" "$gh_bin" "$bare"
}

actor_env_overrides_the_git_identity() {
  local repo idea code_bin gh_bin bare pr_url code_trace provider_trace last
  setup_world
  last() { jq -r 'select(.idea_id=="'"$idea"'") | .actor' "$repo/.e3d-pilot/events.jsonl" | tail -1; }
  "$BIN" ideas note --repo "$repo" "$idea" "no actor given" >/dev/null
  assert_eq "$(last)" "test@example.com" "default: the git identity, as before"
  E3D_PILOT_ACTOR="mcp:some-client" "$BIN" ideas note --repo "$repo" "$idea" "env actor" >/dev/null
  assert_eq "$(last)" "mcp:some-client" "E3D_PILOT_ACTOR replaces the git identity"
  E3D_PILOT_ACTOR="mcp:some-client" "$BIN" ideas note --repo "$repo" "$idea" "explicit" --actor "human@example.com" >/dev/null
  assert_eq "$(last)" "human@example.com" "an explicit --actor still wins"
  rm -rf "$code_bin" "$gh_bin" "$bare"
}

main() {
  install_provider
  pause_stops_before_execute_and_runs_nothing_after
  resume_runs_only_the_remaining_stages_and_completes
  cancel_paused_records_failure_and_allows_a_fresh_retry
  stop_before_validation
  actor_env_overrides_the_git_identity
  resume_refuses_when_the_base_moved_since_approval
  echo "phase37: ok"
}

main "$@"
