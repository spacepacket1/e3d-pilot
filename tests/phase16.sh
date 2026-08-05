#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"
SAMPLE_CONFIG="$ROOT/examples/sample-config.json"
PROVIDER="$ROOT/lib/providers/phase16-provider"

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
  printf 'available (phase16-provider)\n'
  exit 0
fi
[[ -n "$prompt_file" && -f "$prompt_file" ]] || { echo "missing prompt" >&2; exit 1; }
case "$(basename "$prompt_file")" in
  draft-prompt.md)
    [[ -n "${PHASE16_TRACE_FILE:-}" ]] && printf 'draft\n' >> "$PHASE16_TRACE_FILE"
    cat <<'OUT'
```spec
# Approved Delivery Fixture

## Overview

Touch the README through the approved implementation flow.

## Goals

- Exercise delivery recording.

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
    cat <<'OUT'
---STATUS---
status: approved
reason: fixture approved
OUT
    ;;
  review-prompt.md)
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
printf '\nimplemented by phase16 csr\n' >> README.md
EOF
  chmod +x "$bin_dir/codex-spec-runner"
}

make_repo() {
  local verify="${1:-test -f README.md}" repo
  repo="$(mktemp -d)"
  git init -q "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test User"
  cat > "$repo/README.md" <<'EOF'
# Phase 16 Repo
EOF
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m "initial"
  mkdir -p "$repo/.e3d-pilot"
  jq \
    --arg verify "$verify" \
    '.verify = [$verify]
     | .pr.backend = "local"
     | .providers.draft = "phase16-provider"
     | .providers.negotiate = ["phase16-provider"]
     | .providers.review = "phase16-provider"
     | del(.live_verify)' \
    "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  printf '%s' "$repo"
}

ingest_idea() {
  local repo="$1" run_id="$2" title="$3" candidate_json
  candidate_json="$(mktemp)"
  jq -ncS --arg title "$title" '{
    title:$title,
    summary:"Approved fixture implementation.",
    scores:{attraction:3,retention:3,revenue:2,effort:"low"},
    category:"testing",
    dedup_rationale:"new fixture",
    validation:{approvable:true,eligibility_reason:null,warnings:[]}
  }' > "$candidate_json"
  "$BIN" ideas ingest --repo "$repo" --run-id "$run_id" --candidate-id candidate-1 --candidate-json "$candidate_json"
  rm -f "$candidate_json"
}

ingest_fleet_idea() {
  local fleet_file="$1" title="$2" candidate_json
  candidate_json="$(mktemp)"
  jq -ncS --arg title "$title" --slurpfile repos "$fleet_file" '{
    title:$title,
    summary:"Approved fleet fixture implementation.",
    repos:$repos[0],
    scores:{attraction:4,retention:4,revenue:3,effort:"medium"},
    category:"workflow",
    dedup_rationale:"new fleet fixture",
    validation:{approvable:true,eligibility_reason:null,warnings:[]}
  }' > "$candidate_json"
  "$BIN" fleet ideas "$fleet_file" ingest --run-id fleet-run --candidate-id candidate-1 --candidate-json "$candidate_json"
  rm -f "$candidate_json"
}

single_repo_approved_implementation_records_delivery() {
  local repo bin_dir idea out state
  repo="$(make_repo)"
  bin_dir="$(mktemp -d)"
  make_csr_bin "$bin_dir"
  idea="$(ingest_idea "$repo" run-1 "Single approved delivery")"
  "$BIN" ideas approve --repo "$repo" "$idea" --actor approver@example.com >/dev/null
  out="$(PATH="$bin_dir:$PATH" "$BIN" ideas implement --repo "$repo" "$idea")"
  state="$("$BIN" ideas show --repo "$repo" "$idea" --json)"
  assert_contains "$out" "ideas: implemented $idea"
  assert_eq "$(jq -r '.status' <<<"$state")" "implemented" "single idea status"
  assert_eq "$(jq -r '.outcomes[-1].targets[0].status' <<<"$state")" "succeeded" "target success"
  assert_eq "$(jq -r '.outcomes[-1].targets[0].publish_backend' <<<"$state")" "local" "publish backend"
  [[ "$(jq -r '.outcomes[-1].targets[0].commit_shas | length' <<<"$state")" -ge 1 ]] || { echo "expected commit evidence" >&2; exit 1; }
  [[ "$(jq -r '.outcomes[-1].targets[0].verification | length' <<<"$state")" -ge 1 ]] || { echo "expected verification evidence" >&2; exit 1; }
  rm -rf "$bin_dir"
}

unapproved_and_rejected_ideas_do_not_start() {
  local repo idea rejected out status events
  repo="$(make_repo)"
  idea="$(ingest_idea "$repo" run-1 "Unapproved delivery")"
  set +e
  out="$("$BIN" ideas implement --repo "$repo" "$idea" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "unapproved idea should not implement" >&2; exit 1; }
  assert_contains "$out" "cannot enter implementation from status: proposed"
  events="$(grep -c 'implementation_started' "$repo/.e3d-pilot/events.jsonl" || true)"
  assert_eq "$events" "0" "unapproved should not start"

  rejected="$(ingest_idea "$repo" run-2 "Rejected delivery")"
  "$BIN" ideas reject --repo "$repo" "$rejected" --reason "no" >/dev/null
  set +e
  out="$("$BIN" ideas implement --repo "$repo" "$rejected" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "rejected idea should not implement" >&2; exit 1; }
  assert_contains "$out" "cannot enter implementation from status: rejected"
}

changed_base_blocks_before_provider() {
  local repo idea trace out status
  repo="$(make_repo)"
  mkdir -p "$repo/.e3d-pilot/runs/run-1"
  printf -- '---\nhead_sha: %s\n---\n\n# Findings\n' "$(git -C "$repo" rev-parse HEAD)" > "$repo/.e3d-pilot/runs/run-1/findings.md"
  idea="$(ingest_idea "$repo" run-1 "Changed base delivery")"
  "$BIN" ideas approve --repo "$repo" "$idea" >/dev/null
  printf 'material change\n' > "$repo/material.txt"
  git -C "$repo" add material.txt
  git -C "$repo" commit -q -m "material change"
  trace="$(mktemp)"
  set +e
  out="$(PHASE16_TRACE_FILE="$trace" "$BIN" ideas implement --repo "$repo" "$idea" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "changed base should fail" >&2; exit 1; }
  assert_contains "$out" "base SHA changed since approval"
  [[ ! -s "$trace" ]] || { echo "provider should not be invoked after base change" >&2; exit 1; }
  assert_eq "$(jq -r '.status' "$repo/.e3d-pilot/ideas/$idea/idea.json")" "approved_for_implementation" "base block status"
  rm -f "$trace"
}

fleet_two_repo_success_records_linked_runs() {
  local dir repo1 repo2 fleet idea bin_dir state
  dir="$(mktemp -d)"
  repo1="$(make_repo)"
  repo2="$(make_repo)"
  fleet="$dir/fleet.json"
  jq -ncS --arg r1 "$repo1" --arg r2 "$repo2" '[$r1,$r2]' > "$fleet"
  bin_dir="$(mktemp -d)"
  make_csr_bin "$bin_dir"
  idea="$(ingest_fleet_idea "$fleet" "Two repo fleet delivery")"
  "$BIN" fleet ideas "$fleet" approve "$idea" >/dev/null
  PATH="$bin_dir:$PATH" "$BIN" fleet ideas "$fleet" implement "$idea" >/dev/null
  state="$("$BIN" fleet ideas "$fleet" show "$idea" --json)"
  assert_eq "$(jq -r '.status' <<<"$state")" "implemented" "fleet success status"
  assert_eq "$(jq -r '.outcomes[-1].targets | length' <<<"$state")" "2" "fleet target count"
  assert_eq "$(jq -r '[.outcomes[-1].targets[].status] | join(",")' <<<"$state")" "succeeded,succeeded" "fleet target statuses"
  [[ "$(find "$repo1/.e3d-pilot/runs" -name idea-link.txt | wc -l | tr -d ' ')" -eq 1 ]] || { echo "repo1 missing linked run" >&2; exit 1; }
  [[ "$(find "$repo2/.e3d-pilot/runs" -name idea-link.txt | wc -l | tr -d ' ')" -eq 1 ]] || { echo "repo2 missing linked run" >&2; exit 1; }
  rm -rf "$bin_dir"
}

fleet_second_failure_records_success_failure_and_skip() {
  local dir repo1 repo2 repo3 fleet idea bin_dir state status out
  dir="$(mktemp -d)"
  repo1="$(make_repo)"
  repo2="$(make_repo false)"
  repo3="$(make_repo)"
  fleet="$dir/fleet.json"
  jq -ncS --arg r1 "$repo1" --arg r2 "$repo2" --arg r3 "$repo3" '[$r1,$r2,$r3]' > "$fleet"
  bin_dir="$(mktemp -d)"
  make_csr_bin "$bin_dir"
  idea="$(ingest_fleet_idea "$fleet" "Failing fleet delivery")"
  "$BIN" fleet ideas "$fleet" approve "$idea" >/dev/null
  set +e
  out="$(PATH="$bin_dir:$PATH" "$BIN" fleet ideas "$fleet" implement "$idea" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "fleet failure should return nonzero" >&2; exit 1; }
  assert_contains "$out" "implementation failed"
  state="$("$BIN" fleet ideas "$fleet" show "$idea" --json)"
  assert_eq "$(jq -r '.status' <<<"$state")" "implementation_failed" "fleet failure status"
  assert_eq "$(jq -r '[.outcomes[-1].targets[].status] | join(",")' <<<"$state")" "succeeded,failed,skipped" "fleet failure target statuses"
  assert_eq "$(jq -r '.outcomes[-1].targets[1].failure.stage' <<<"$state")" "review" "second target failed in review"
  assert_eq "$(jq -r '.outcomes[-1].targets[2].run_id' <<<"$state")" "null" "third target skipped"
  rm -rf "$bin_dir"
}

implement_approved_queue_returns_nonzero_after_recorded_failure() {
  local repo ok bad bin_dir status state
  repo="$(make_repo false)"
  bin_dir="$(mktemp -d)"
  make_csr_bin "$bin_dir"
  ok="$(ingest_idea "$repo" run-a "Queue failure delivery")"
  "$BIN" ideas approve --repo "$repo" "$ok" >/dev/null
  set +e
  PATH="$bin_dir:$PATH" "$BIN" ideas implement-approved --repo "$repo" >/dev/null 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "implement-approved should return nonzero when an idea fails" >&2; exit 1; }
  state="$("$BIN" ideas show --repo "$repo" "$ok" --json)"
  assert_eq "$(jq -r '.status' <<<"$state")" "implementation_failed" "queue failure recorded"
  rm -rf "$bin_dir"
}

install_provider
bash -n "$ROOT/bin/e3d-pilot"
bash -n "$ROOT/lib/ideas/ledger.sh"
bash -n "$ROOT/lib/ideas/materialize.sh"
single_repo_approved_implementation_records_delivery
unapproved_and_rejected_ideas_do_not_start
changed_base_blocks_before_provider
fleet_two_repo_success_records_linked_runs
fleet_second_failure_records_success_failure_and_skip
implement_approved_queue_returns_nonzero_after_recorded_failure

printf 'phase16 ok\n'
