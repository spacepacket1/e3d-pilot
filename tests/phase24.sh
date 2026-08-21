#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROVIDER="$ROOT/lib/providers/grok-build"
BENCHMARK="$ROOT/bin/e3d-backend-benchmark"
BIN="$ROOT/bin/e3d-pilot"
SAMPLE_CONFIG="$ROOT/examples/sample-config.json"

assert_contains() { [[ "$1" == *"$2"* ]] || { printf 'expected to find %q in:\n%s\n' "$2" "$1" >&2; exit 1; }; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || { printf 'did not expect to find %q in:\n%s\n' "$2" "$1" >&2; exit 1; }; }
assert_eq() { [[ "$1" == "$2" ]] || { printf 'expected %q, got %q (%s)\n' "$2" "$1" "${3:-}" >&2; exit 1; }; }

make_repo() {
  local repo
  repo="$(mktemp -d)"
  git init -q "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name 'Test User'
  printf '# Fixture\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m initial
  printf '%s' "$repo"
}

make_fake_grok() {
  local dir="$1" mode="${2:-success}"
  mkdir -p "$dir"
  cat > "$dir/grok fake" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$PWD" > "\${FAKE_GROK_CWD_FILE:-/dev/null}"
printf '%s\n' "\$@" > "\${FAKE_GROK_ARGS_FILE:-/dev/null}"
printf 'diagnostic stderr\n' >&2
prompt=""
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "--prompt-file" ]]; then prompt="\$arg"; fi
  prev="\$arg"
done
if [[ -n "\${FAKE_GROK_SCORES:-}" ]]; then
  printf '%s\n' "\$FAKE_GROK_SCORES"
  exit 0
fi
case "$mode" in
  worker)
    jq -cn --arg text '{"scores":[{"id":"a","score":90,"reason":"strong"},{"id":"b","score":40,"reason":"weak"}]}' '{text:\$text,usage:{total_tokens:12},total_cost_usd:0.002}'
    exit 0
    ;;
esac
if [[ -n "\$prompt" && -f "\$prompt" ]] && grep -q 'Act as a read-only' "\$prompt"; then
  jq -cn --arg text '{"scores":[{"id":"candidate-1","score":40,"reason":"weak"},{"id":"candidate-2","score":90,"reason":"strong"}]}' \
    '{text:\$text,usage:{total_tokens:12},total_cost_usd:0.002}'
  exit 0
fi
case "$mode" in
  success)
    if [[ "\${FAKE_GROK_EDIT:-0}" == "1" ]]; then printf 'grok edit\n' >> README.md; fi
    printf '{"text":"done","usage":{"total_tokens":42},"total_cost_usd":0.01,"model":"fixture-model"}\n'
    ;;
  ideate)
    cat <<'IDEOUTE'
### Candidate 1: Weak idea
Duplicate: no
Dedup rationale: not covered.
Category: other
Analogy: none
Attraction (1-5): 2
Retention (1-5): 2
Effort: low
Description: A weak idea.

### Candidate 2: Strong idea
Duplicate: no
Dedup rationale: not covered.
Category: workflow
Analogy: none
Attraction (1-5): 5
Retention (1-5): 5
Effort: medium
Description: A strong idea.

---IDEATE-STATUS---
selected: candidate-1
reason: model picked the weak idea.
IDEOUTE
    ;;
  failure) printf 'backend exploded\n' >&2; exit 7 ;;
  timeout) sleep 5 ;;
esac
EOF
  chmod +x "$dir/grok fake"
  printf '%s' "$dir/grok fake"
}

make_fake_claude_ideate() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
prompt="$(cat)"
if grep -q 'Act as a read-only' <<<"$prompt"; then
  printf '%s\n' '{"scores":[{"id":"candidate-1","score":20,"reason":"weak"},{"id":"candidate-2","score":95,"reason":"strong"}]}'
  exit 0
fi
cat <<'IDEOUTE'
### Candidate 1: Weak idea
Duplicate: no
Dedup rationale: not covered.
Category: other
Analogy: none
Attraction (1-5): 2
Retention (1-5): 2
Effort: low
Description: A weak idea.

### Candidate 2: Strong idea
Duplicate: no
Dedup rationale: not covered.
Category: workflow
Analogy: none
Attraction (1-5): 5
Retention (1-5): 5
Effort: medium
Description: A strong idea.

---IDEATE-STATUS---
selected: candidate-1
reason: model picked the weak idea.
IDEOUTE
EOF
  chmod +x "$dir/claude"
}

write_findings() {
  local repo="$1" run_id="$2" run_dir
  run_dir="$repo/.e3d-pilot/runs/$run_id"
  mkdir -p "$run_dir"
  cat > "$run_dir/findings.md" <<EOF
---
head_sha: $(git -C "$repo" rev-parse HEAD)
focus: default
---

# Findings

## Local State

- Fixture repo.

## External Context

- External signal.
EOF
}

provider_missing_binary_is_clear_without_a_feature_flag() {
  local prompt out status
  prompt="$(mktemp)"; printf 'hello\n' > "$prompt"
  set +e; out="$(GROK_BUILD_BIN=/definitely/missing/grok "$PROVIDER" "$prompt" 2>&1)"; status=$?; set -e
  assert_eq "$status" 2 missing
  assert_contains "$out" 'grok binary not found'
  assert_contains "$out" 'curl -fsSL https://x.ai/cli/install.sh | bash'
  set +e; out="$(E3D_PILOT_CHECK=1 GROK_BUILD_BIN=/definitely/missing/grok "$PROVIDER" 2>&1)"; status=$?; set -e
  assert_eq "$status" 2 check-missing
  assert_not_contains "$out" 'GROK_BUILD_ENABLED'
  rm -f "$prompt"
}

provider_invocation_is_safe_and_captures_streams() {
  local repo fake_dir fake_bin prompt args_file cwd_file stdout stderr marker
  repo="$(make_repo)"; fake_dir="$(mktemp -d)"; fake_bin="$(make_fake_grok "$fake_dir")"
  prompt="$(mktemp)"; args_file="$(mktemp)"; cwd_file="$(mktemp)"; stdout="$(mktemp)"; stderr="$(mktemp)"
  marker="$(mktemp)"; rm -f "$marker"
  printf 'quoted " prompt; touch %s\n' "$marker" > "$prompt"
  (cd "$repo" && GROK_BUILD_BIN="$fake_bin" GROK_BUILD_MODEL='fixture model' \
    FAKE_GROK_ARGS_FILE="$args_file" FAKE_GROK_CWD_FILE="$cwd_file" "$PROVIDER" "$prompt") >"$stdout" 2>"$stderr"
  [[ ! -e "$marker" ]] || { echo 'prompt content was executed' >&2; exit 1; }
  assert_eq "$(<"$cwd_file")" "$repo" cwd
  assert_contains "$(<"$args_file")" '--prompt-file'
  assert_contains "$(<"$args_file")" "$prompt"
  assert_contains "$(<"$args_file")" 'fixture model'
  assert_contains "$(<"$stdout")" '"total_tokens":42'
  assert_contains "$(<"$stderr")" 'diagnostic stderr'
  rm -rf "$repo" "$fake_dir"; rm -f "$prompt" "$args_file" "$cwd_file" "$stdout" "$stderr"
}

provider_nonzero_and_timeout_are_preserved() {
  local prompt dir bin out status
  prompt="$(mktemp)"; printf 'hello\n' > "$prompt"
  dir="$(mktemp -d)"; bin="$(make_fake_grok "$dir" failure)"
  set +e; out="$(GROK_BUILD_BIN="$bin" "$PROVIDER" "$prompt" 2>&1)"; status=$?; set -e
  assert_eq "$status" 7 nonzero
  assert_contains "$out" 'backend exploded'
  rm -rf "$dir"; dir="$(mktemp -d)"; bin="$(make_fake_grok "$dir" timeout)"
  set +e; out="$(GROK_BUILD_BIN="$bin" GROK_BUILD_TIMEOUT=1 "$PROVIDER" "$prompt" 2>&1)"; status=$?; set -e
  assert_eq "$status" 124 timeout
  assert_contains "$out" 'timed out after 1s'
  rm -rf "$dir"; rm -f "$prompt"
}

execute_selects_grok_inside_isolated_worktree() {
  local repo run_id run_dir fake_dir fake_bin worktree out
  repo="$(make_repo)"; mkdir -p "$repo/.e3d-pilot"
  jq '.providers.execute="grok-build" | .approval.implementation_required=false | .approval.merge_required=false' "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  run_id=phase24-grok-execute; run_dir="$repo/.e3d-pilot/runs/$run_id"; mkdir -p "$run_dir"
  cat > "$run_dir/spec-final.md" <<'EOF'
# Spec
## Overview
Bounded edit.
## Goals
- Edit README.
## Non-Goals
- No publishing.
## Existing Files
- `README.md`
## Shared Constraints
- Stay bounded.
## Phase 1 - Edit
<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=README.md -->
### Requirements
- Add one line.
### Acceptance Criteria
- README changes.
EOF
  fake_dir="$(mktemp -d)"; fake_bin="$(make_fake_grok "$fake_dir")"
  out="$(GROK_BUILD_BIN="$fake_bin" FAKE_GROK_EDIT=1 "$BIN" run --repo "$repo" --stage execute --run-id "$run_id")"
  worktree="$(cut -f2 "$run_dir/execute-worktree.txt")"
  assert_contains "$(<"$worktree/README.md")" 'grok edit'
  [[ "$(<"$repo/README.md")" != *'grok edit'* ]] || { echo 'primary checkout was modified' >&2; exit 1; }
  assert_contains "$out" 'completed grok-build run'
  assert_contains "$(<"$run_dir/execute-grok-build.stderr")" 'diagnostic stderr'
  rm -rf "$fake_dir"
}

benchmark_serializes_measured_and_unavailable_fields() {
  local repo prompt output fake_dir fake_bin
  repo="$(make_repo)"; prompt="$(mktemp)"; output="$(mktemp)"; fake_dir="$(mktemp -d)"; fake_bin="$(make_fake_grok "$fake_dir")"
  printf 'Make the bounded fixture edit.\n' > "$prompt"
  GROK_BUILD_BIN="$fake_bin" FAKE_GROK_EDIT=1 \
    "$BENCHMARK" --repo "$repo" --task-id benchmark-001 --prompt "$prompt" --backends grok-build --verify "grep -q 'grok edit' README.md" --output "$output" >/dev/null
  jq -e '.schema_version == 1 and .results[0].backend == "grok-build" and .results[0].success == true and .results[0].tests_passed == true and .results[0].files_changed == 1 and .results[0].tokens == 42 and .results[0].cost_usd == 0.01 and .results[0].retry_count == 0 and .results[0].human_review_score == null' "$output" >/dev/null
  rm -rf "$repo" "$fake_dir" "${output%.json}.artifacts"; rm -f "$prompt" "$output"
}

worker_fanout_is_bounded_and_serialized() {
  local repo candidates output fake_dir fake_bin
  repo="$(make_repo)"; candidates="$(mktemp)"; output="$(mktemp)"; fake_dir="$(mktemp -d)"; fake_bin="$(make_fake_grok "$fake_dir" worker)"
  printf '[{"id":"a","title":"A"},{"id":"b","title":"B"}]\n' > "$candidates"
  GROK_BUILD_BIN="$fake_bin" \
    "$ROOT/bin/e3d-grok-workers" --repo "$repo" --candidates "$candidates" --workers 3 --top 1 --output "$output" >/dev/null
  jq -e '.requested_workers == 3 and .valid_workers == 3 and .partial == false and .selected[0].id == "a" and .selected[0].average_score == 90 and (.downstream | contains("existing negotiation")) and .provider == "grok-build"' "$output" >/dev/null
  rm -rf "$repo" "$fake_dir" "${output%.json}.artifacts"; rm -f "$candidates" "$output"
}

grok_build_is_a_normal_ideate_provider() {
  local repo fake_dir fake_bin run_id candidates
  repo="$(make_repo)"; mkdir -p "$repo/.e3d-pilot"
  jq '.providers.ideate="grok-build"' "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  run_id=phase24-grok-ideate
  write_findings "$repo" "$run_id"
  fake_dir="$(mktemp -d)"; fake_bin="$(make_fake_grok "$fake_dir" ideate)"
  GROK_BUILD_BIN="$fake_bin" "$BIN" run --repo "$repo" --stage ideate --run-id "$run_id" >/dev/null
  candidates="$repo/.e3d-pilot/runs/$run_id/candidates.md"
  assert_contains "$(<"$candidates")" 'selected: candidate-1'
  assert_not_contains "$(<"$candidates")" '## Ensemble Scoring'
  rm -rf "$repo" "$fake_dir"
}

candidate_scoring_reranks_with_grok_and_does_not_execute() {
  local repo bin_dir fake_dir fake_bin run_id out candidates idea_dir
  repo="$(make_repo)"; mkdir -p "$repo/.e3d-pilot"
  jq '.providers.ideate="claude" | .candidate_scoring = {"provider":"grok-build","workers":3}' \
    "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  run_id=phase24-score
  write_findings "$repo" "$run_id"
  bin_dir="$(mktemp -d)"; make_fake_claude_ideate "$bin_dir"
  fake_dir="$(mktemp -d)"; fake_bin="$(make_fake_grok "$fake_dir")"
  out="$(PATH="$bin_dir:$PATH" GROK_BUILD_BIN="$fake_bin" "$BIN" run --repo "$repo" --stage ideate --run-id "$run_id")"
  candidates="$repo/.e3d-pilot/runs/$run_id/candidates.md"
  assert_contains "$out" 'scored candidates with grok-build'
  assert_contains "$(<"$candidates")" 'selected: candidate-2'
  assert_contains "$(<"$candidates")" 'model_selected: candidate-1'
  assert_contains "$(<"$candidates")" 'Ensemble (0-100): 90'
  assert_contains "$(<"$candidates")" '## Ensemble Scoring'
  assert_contains "$(<"$candidates")" 'Scoring never executes'
  [[ -f "$repo/.e3d-pilot/runs/$run_id/ideate-response.model.md" ]] || { echo 'missing model response copy' >&2; exit 1; }
  [[ -f "$repo/.e3d-pilot/runs/$run_id/ideate-scoring.json" ]] || { echo 'missing scoring json' >&2; exit 1; }
  idea_dir="$repo/.e3d-pilot/ideas"
  [[ -d "$idea_dir" ]] || { echo 'expected materialized ideas' >&2; exit 1; }
  jq -s -e 'map(select(.source_candidate == "candidate-1" and .selected_by_model == true)) | length > 0' "$idea_dir"/*/idea.json >/dev/null
  jq -s -e 'map(select(.source_candidate == "candidate-2" and .scores.ensemble == 90)) | length > 0' "$idea_dir"/*/idea.json >/dev/null
  # Scoring must not skip the implementation gate.
  set +e
  out="$(PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage draft --run-id "$run_id" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo 'draft should still require implementation approval' >&2; exit 1; }
  assert_contains "$out" 'not approved for implementation'
  rm -rf "$repo" "$bin_dir" "$fake_dir"
}

candidate_scoring_accepts_claude_like_other_providers() {
  local repo bin_dir run_id candidates
  repo="$(make_repo)"; mkdir -p "$repo/.e3d-pilot"
  jq '.providers.ideate="claude" | .candidate_scoring = {"provider":"claude","workers":3}' \
    "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  run_id=phase24-score-claude
  write_findings "$repo" "$run_id"
  bin_dir="$(mktemp -d)"; make_fake_claude_ideate "$bin_dir"
  PATH="$bin_dir:$PATH" "$BIN" run --repo "$repo" --stage ideate --run-id "$run_id" >/dev/null
  candidates="$repo/.e3d-pilot/runs/$run_id/candidates.md"
  assert_contains "$(<"$candidates")" 'selected: candidate-2'
  assert_contains "$(<"$candidates")" 'scoring_provider: claude'
  assert_contains "$(<"$candidates")" 'model_selected: candidate-1'
  rm -rf "$repo" "$bin_dir"
}

candidate_scoring_unavailable_provider_fails() {
  local repo bin_dir run_id out status
  repo="$(make_repo)"; mkdir -p "$repo/.e3d-pilot"
  jq '.providers.ideate="claude" | .candidate_scoring = {"provider":"grok-build","workers":3}' \
    "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  run_id=phase24-score-missing
  write_findings "$repo" "$run_id"
  bin_dir="$(mktemp -d)"; make_fake_claude_ideate "$bin_dir"
  set +e
  out="$(PATH="$bin_dir:$PATH" GROK_BUILD_BIN=/definitely/missing/grok "$BIN" run --repo "$repo" --stage ideate --run-id "$run_id" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo 'missing scoring provider should fail' >&2; exit 1; }
  assert_contains "$out" 'candidate_scoring provider'
  assert_contains "$out" 'unavailable'
  rm -rf "$repo" "$bin_dir"
}

config_rejects_invalid_scoring_workers() {
  local repo out status
  repo="$(make_repo)"; mkdir -p "$repo/.e3d-pilot"
  jq '.candidate_scoring = {"provider":"grok-build","workers":2}' "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  set +e
  out="$("$BIN" config validate "$repo" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo 'workers=2 should fail validation' >&2; exit 1; }
  assert_contains "$out" 'candidate_scoring.workers'
  jq '.candidate_scoring = {"provider":"grok-build","workers":3}' "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  "$BIN" config validate "$repo" >/dev/null
  rm -rf "$repo"
}

main() {
  provider_missing_binary_is_clear_without_a_feature_flag
  provider_invocation_is_safe_and_captures_streams
  provider_nonzero_and_timeout_are_preserved
  execute_selects_grok_inside_isolated_worktree
  benchmark_serializes_measured_and_unavailable_fields
  worker_fanout_is_bounded_and_serialized
  grok_build_is_a_normal_ideate_provider
  candidate_scoring_reranks_with_grok_and_does_not_execute
  candidate_scoring_accepts_claude_like_other_providers
  candidate_scoring_unavailable_provider_fails
  config_rejects_invalid_scoring_workers
  echo 'phase24: all tests passed'
}
main "$@"
