#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"
SAMPLE_CONFIG="$ROOT/examples/sample-config.json"
PROVIDER="$ROOT/lib/providers/phase21-provider"

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
  printf 'available (phase21-provider)\n'
  exit 0
fi
[[ -n "$prompt_file" && -f "$prompt_file" ]] || { echo "missing prompt" >&2; exit 1; }
case "$(basename "$prompt_file")" in
  draft-prompt.md)
    [[ -n "${PHASE21_TRACE_FILE:-}" ]] && printf 'draft\n' >> "$PHASE21_TRACE_FILE"
    cat <<'OUT'
```spec
# Repair Fixture

## Overview

Touch the README through the approved implementation flow.

## Goals

- Exercise repair-run recovery.

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
    [[ -n "${PHASE21_TRACE_FILE:-}" ]] && printf 'negotiate\n' >> "$PHASE21_TRACE_FILE"
    cat <<'OUT'
---STATUS---
status: approved
reason: fixture approved
OUT
    ;;
  review-prompt.md)
    [[ -n "${PHASE21_TRACE_FILE:-}" ]] && printf 'review\n' >> "$PHASE21_TRACE_FILE"
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

make_csr_bin() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex-spec-runner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
spec="${1:?spec required}"
stage="${2:?stage required}"
[[ "$stage" == "all" && -f "$spec" ]] || exit 1
mkdir -p .codex-spec-runner
printf '{"phase":1,"status":"ok"}\n' > .codex-spec-runner/manifest.json
printf '\nimplemented by phase21 csr\n' >> README.md
EOF
  chmod +x "$bin_dir/codex-spec-runner"
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
# Phase 21 Repo
EOF
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m "initial"
  mkdir -p "$repo/.e3d-pilot"
  jq \
    '.verify = ["test -f README.md"]
     | .pr.backend = "github"
     | .pr.labels = ["e3d-pilot"]
     | .providers.draft = "phase21-provider"
     | .providers.negotiate = ["phase21-provider"]
     | .providers.review = "phase21-provider"
     | del(.live_verify)' \
    "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  printf '%s' "$repo"
}

ingest_idea() {
  local repo="$1" run_id="$2" title="$3" candidate_json
  candidate_json="$(mktemp)"
  jq -ncS --arg title "$title" '{
    title:$title,
    summary:"Repair-run fixture implementation.",
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

repair_run_resumes_publish_without_redoing_prior_stages() {
  local repo idea csr_bin_dir gh_bin_dir bare pr_url fail_marker trace out status run_id state before_count after_count
  repo="$(make_repo)"
  csr_bin_dir="$(mktemp -d)"
  make_csr_bin "$csr_bin_dir"
  bare="$(mktemp -d)"
  git init -q --bare "$bare"
  git -C "$repo" remote add origin "$bare"
  gh_bin_dir="$(mktemp -d)"
  pr_url="https://github.com/example/phase21/pull/1"
  fail_marker="$(mktemp)"
  trace="$(mktemp)"
  make_gh_stub "$gh_bin_dir" "$fail_marker" "$pr_url" "$trace"

  idea="$(ingest_idea "$repo" run-1 "Repairable delivery")"
  "$BIN" ideas approve --repo "$repo" "$idea" --actor approver@example.com >/dev/null

  local implement_trace
  implement_trace="$(mktemp)"
  set +e
  out="$(PHASE21_TRACE_FILE="$implement_trace" PATH="$csr_bin_dir:$gh_bin_dir:$PATH" "$BIN" ideas implement --repo "$repo" "$idea" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "expected implement to fail while the label is missing" >&2; exit 1; }
  assert_contains "$out" "ideas: implementation failed for $idea"
  assert_eq "$(jq -r '.status' "$repo/.e3d-pilot/ideas/$idea/idea.json")" "implementation_failed" "status after publish failure"
  run_id="$(run_id_from_failure_output "$out")"
  before_count="$(wc -l < "$implement_trace" | tr -d '[:space:]')"
  [[ "$before_count" -eq 3 ]] || { echo "expected draft+negotiate+review to each run once, got $before_count lines: $(cat "$implement_trace")" >&2; exit 1; }

  # The label now exists (fixed out of band); nothing about draft, negotiate,
  # execute, or review needs to change or redo.
  rm -f "$fail_marker"

  out="$(PHASE21_TRACE_FILE="$implement_trace" PATH="$csr_bin_dir:$gh_bin_dir:$PATH" "$BIN" ideas repair-run --repo "$repo" --run-id "$run_id" "$idea")"
  assert_contains "$out" "ideas: repaired $idea run=$run_id from=publish"

  after_count="$(wc -l < "$implement_trace" | tr -d '[:space:]')"
  assert_eq "$after_count" "$before_count" "repair-run must not re-invoke draft/negotiate/review"

  state="$("$BIN" ideas show --repo "$repo" "$idea" --json)"
  assert_eq "$(jq -r '.status' <<<"$state")" "implemented" "status after repair"
  assert_eq "$(jq -r '.outcomes[-1].targets[0].status' <<<"$state")" "succeeded" "target success after repair"
  assert_eq "$(jq -r '.outcomes[-1].targets[0].publish_backend' <<<"$state")" "github" "publish backend after repair"
  assert_eq "$(jq -r '.outcomes[-1].targets[0].pr_url' <<<"$state")" "$pr_url" "pr url recorded from the original run"
  assert_eq "$(jq -r '.outcomes[-1].targets[0].run_id' <<<"$state")" "$run_id" "outcome still references the original run"

  # A second repair-run attempt on an already-implemented idea must refuse.
  set +e
  out="$("$BIN" ideas repair-run --repo "$repo" --run-id "$run_id" "$idea" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "repair-run should refuse once the idea is already implemented" >&2; exit 1; }
  assert_contains "$out" "only applies to an idea currently in implementation_failed"

  rm -rf "$csr_bin_dir" "$gh_bin_dir" "$bare"
  rm -f "$fail_marker" "$trace" "$implement_trace"
}

repair_run_refuses_when_earlier_stage_artifact_is_missing() {
  local repo idea csr_bin_dir gh_bin_dir bare pr_url fail_marker trace out status run_id run_dir
  repo="$(make_repo)"
  csr_bin_dir="$(mktemp -d)"
  make_csr_bin "$csr_bin_dir"
  bare="$(mktemp -d)"
  git init -q --bare "$bare"
  git -C "$repo" remote add origin "$bare"
  gh_bin_dir="$(mktemp -d)"
  pr_url="https://github.com/example/phase21/pull/2"
  fail_marker="$(mktemp)"
  trace="$(mktemp)"
  make_gh_stub "$gh_bin_dir" "$fail_marker" "$pr_url" "$trace"

  idea="$(ingest_idea "$repo" run-2 "Missing artifact delivery")"
  "$BIN" ideas approve --repo "$repo" "$idea" --actor approver@example.com >/dev/null

  set +e
  out="$(PATH="$csr_bin_dir:$gh_bin_dir:$PATH" "$BIN" ideas implement --repo "$repo" "$idea" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "expected implement to fail while the label is missing" >&2; exit 1; }
  run_id="$(run_id_from_failure_output "$out")"
  run_dir="$repo/.e3d-pilot/runs/$run_id"

  rm -f "$fail_marker"
  # Simulate a corrupted/incomplete run: negotiate's artifact is gone even
  # though the failure was recorded at publish.
  rm -f "$run_dir/spec-final.md"

  set +e
  out="$("$BIN" ideas repair-run --repo "$repo" --run-id "$run_id" "$idea" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "repair-run should refuse when a prior stage never actually succeeded" >&2; exit 1; }
  assert_contains "$out" "no successful negotiate output on disk"
  assert_eq "$(jq -r '.status' "$repo/.e3d-pilot/ideas/$idea/idea.json")" "implementation_failed" "status unchanged after refused repair"

  rm -rf "$csr_bin_dir" "$gh_bin_dir" "$bare"
  rm -f "$fail_marker" "$trace"
}

repair_run_rejects_unknown_from_stage() {
  local repo idea out status
  repo="$(make_repo)"
  idea="$(ingest_idea "$repo" run-3 "Bad stage name")"
  "$BIN" ideas approve --repo "$repo" "$idea" --actor approver@example.com >/dev/null
  set +e
  out="$("$BIN" ideas repair-run --repo "$repo" --run-id "does-not-matter" --from-stage bogus "$idea" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "repair-run should reject an unknown --from-stage" >&2; exit 1; }
  assert_contains "$out" "unknown --from-stage: bogus"
}

main() {
  bash -n "$BIN"
  install_provider
  repair_run_resumes_publish_without_redoing_prior_stages
  repair_run_refuses_when_earlier_stage_artifact_is_missing
  repair_run_rejects_unknown_from_stage
  echo "phase21: all tests passed"
}

main "$@"
