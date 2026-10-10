#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/bin/e3d-provenance-agreement"

make_repo() {
  local repo
  repo="$(mktemp -d)"
  mkdir -p "$repo/.e3d-pilot/runs"
  printf '%s\n' "$repo"
}

negotiate_file() {
  local run_dir="$1" round="$2" reviewer="$3" provider="$4" status="$5" reason="$6"
  local out="$run_dir/negotiate-round-${round}-reviewer-${reviewer}-${provider}-response.md"
  {
    printf '%s\n' "Some free-text analysis from the reviewer precedes the marker."
    printf '%s\n' "---STATUS---"
    printf 'status: %s\n' "$status"
    printf 'reason: %s\n' "$reason"
    # parse-status requires a fenced ```spec replacement block whenever
    # status is "revise" -- without it the real tool rejects the file.
    if [[ "$status" == "revise" ]]; then
      printf '%s\n' '```spec' "Replacement spec body for the fixture." '```'
    fi
  } > "$out"
}

review_file() {
  local run_dir="$1" provider="$2" status="$3" reason="$4"
  cat > "$run_dir/review-provider-${provider}.md" <<EOF
Some free-text review precedes the marker.
---VERDICT---
status: ${status}
reason: ${reason}
EOF
}

agreement_and_disagreement_counts_are_correct() {
  local repo run_dir out
  repo="$(make_repo)"
  run_dir="$repo/.e3d-pilot/runs/impl-fixture-repo-20260101000000"
  mkdir -p "$run_dir"

  # Round 1: claude and codex both approve -- agreement.
  negotiate_file "$run_dir" 1 1 claude approved "looks consistent"
  negotiate_file "$run_dir" 1 2 codex approved "no issues found"
  # Round 2: claude approves, codex wants a revise -- disagreement.
  negotiate_file "$run_dir" 2 1 claude approved "still consistent"
  negotiate_file "$run_dir" 2 2 codex revise "edge case unhandled"

  # Review: claude approves, codex blocks -- disagreement.
  review_file "$run_dir" claude approved "diff matches the approved spec"
  review_file "$run_dir" codex blocked "diff diverges from the approved spec"

  # A malformed/pre-contract file with no marker at all -- must be skipped,
  # not crash the run (mirrors real early-format history in this repo).
  printf 'just prose, no status marker of any kind\n' > "$run_dir/review-provider-devin.md"

  out="$("$TOOL" --repo "$repo")"

  jq -e '
    .by_provider.claude.negotiate_rounds == 2
    and .by_provider.claude.approved == 2
    and .by_provider.claude.revise == 0
    and .by_provider.claude.approval_rate == 1
    and .by_provider.codex.negotiate_rounds == 2
    and .by_provider.codex.approved == 1
    and .by_provider.codex.revise == 1
    and .by_provider.codex.approval_rate == 0.5
    and ."by_provider_pair"["claude|codex"].agree == 1
    and ."by_provider_pair"["claude|codex"].disagree == 2
    and (.disagreements | length) == 2
    and (.disagreements | map(select(.kind == "review")) | length) == 1
    and (.disagreements | map(select(.kind == "negotiate")) | length) == 1
    and .skipped_malformed_files == 1
  ' <<<"$out" >/dev/null

  rm -rf "$repo"
}

zero_runs_produces_empty_but_valid_report() {
  local repo out
  repo="$(make_repo)"
  out="$("$TOOL" --repo "$repo")"
  jq -e '
    (.by_provider | length) == 0
    and (.by_provider_pair | length) == 0
    and (.disagreements | length) == 0
    and .skipped_malformed_files == 0
  ' <<<"$out" >/dev/null
  rm -rf "$repo"
}

default_repo_is_cwd_when_flag_omitted() {
  local repo out
  repo="$(make_repo)"
  out="$(cd "$repo" && "$TOOL")"
  jq -e '(.by_provider | length) == 0' <<<"$out" >/dev/null
  rm -rf "$repo"
}

main() {
  node --check "$TOOL"
  agreement_and_disagreement_counts_are_correct
  zero_runs_produces_empty_but_valid_report
  default_repo_is_cwd_when_flag_omitted
  echo "phase36: all tests passed"
}

main "$@"
