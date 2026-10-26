#!/usr/bin/env bash
# load_prior_runs_content must not re-embed prior runs' "## Dedup Context" (which nests the whole prior
# facts file), or ideate-facts.md compounds in size every run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

runs_dir_for_repo() { printf '%s/runs' "$tmp"; }
# shellcheck disable=SC1090
source <(awk '/^load_prior_runs_content\(\) \{/,/^}/' "$BIN")

mkdir -p "$tmp/runs"
big="$(head -c 2000000 /dev/zero | tr '\0' 'x')"
for i in 01 02 03 04 05 06 07 08 09 10 11 12 13; do
  mkdir "$tmp/runs/run-$i"
  {
    printf -- '---\nselected: candidate-1\n---\n\n# Candidates\n\n## Dedup Context\n\nDEDUP-NEST-%s\n%s\n' "$i" "$big"
    printf '\n## Proposed Candidates\n\n### Candidate 1: Idea %s\nbody %s\n' "$i" "$i"
  } > "$tmp/runs/run-$i/candidates.md"
  touch -t "202610$((10 + 10#$i))0000" "$tmp/runs/run-$i" 2>/dev/null || touch "$tmp/runs/run-$i"
done

out="$(load_prior_runs_content "$tmp/repo" run-current)"
size=${#out}

[[ "$out" != *DEDUP-NEST* ]] || { echo "FAIL: output embeds a prior run's Dedup Context" >&2; exit 1; }
[[ "$out" == *'### Candidate 1: Idea'* ]] || { echo "FAIL: Proposed Candidates section missing" >&2; exit 1; }
(( size < 10 * 17000 )) || { echo "FAIL: output is $size bytes, expected under 170000" >&2; exit 1; }
count="$(grep -c 'candidates.md (Proposed' <<<"$out")"
[[ "$count" -eq 10 ]] || { echo "FAIL: expected 10 prior runs, got $count" >&2; exit 1; }

echo "ideate-prior-runs-bounded: ok ($size bytes)"
