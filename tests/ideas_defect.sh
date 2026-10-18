#!/usr/bin/env bash
# Covers `e3d-pilot ideas defect`: a structured "post_review_defect" finding for a defect that got past review
# (the most valuable training signal for the adversarial-reviewer dataset). Uses the same stub seam as jev_dedup.sh:
# no network, TYPESAFE_API_KEY unset.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

repo="$(mktemp -d)"
git init -q "$repo"
cand="$(mktemp)"
jq -n '{focus: "default", title: "Defect fixture", summary: "A fixture idea.", repos: [],
  scores: {attraction: 3, retention: 3, revenue: 1, effort: "low"}, category: "workflow", analogy: "test fixture",
  dedup_rationale: "synthetic", provenance: {provider: "stub", model: "none"}, content_digests: {}, implementation: {targets: []}}' > "$cand"
idea="$(env -u TYPESAFE_API_KEY "$BIN" ideas ingest --repo "$repo" --run-id run-1 --candidate-id c1 --candidate-json "$cand" | tail -1)"
[[ "$idea" == idea-* ]] || fail "ingest did not return an idea id: $idea"

"$BIN" ideas defect --repo "$repo" --found-by live-run --stage-missed review --severity high \
  --evidence docs/notes/live-run.md "$idea" "client and stub shared a wrong wire format; three reviews approved it" >/dev/null

notes="$("$BIN" ideas show --repo "$repo" "$idea" --json | jq -c '.notes // []')"
[[ "$notes" == *"post_review_defect: found_by=live-run stage_missed=review severity=high :: client and stub shared"* ]] || fail "structured note missing: $notes"
[[ "$notes" == *"docs/notes/live-run.md"* ]] || fail "evidence ref missing: $notes"

# defaults, and rejection of unknown values
"$BIN" ideas defect --repo "$repo" --found-by ci "$idea" "flaky after merge" >/dev/null
notes="$("$BIN" ideas show --repo "$repo" "$idea" --json | jq -c '.notes // []')"
[[ "$notes" == *"found_by=ci stage_missed=unknown severity=unknown :: flaky after merge"* ]] || fail "defaults not applied: $notes"

if "$BIN" ideas defect --repo "$repo" --found-by vibes "$idea" "x" >/dev/null 2>&1; then fail "an unknown --found-by was accepted"; fi
if "$BIN" ideas defect --repo "$repo" --found-by ci --severity catastrophic "$idea" "x" >/dev/null 2>&1; then fail "an unknown --severity was accepted"; fi
if "$BIN" ideas defect --repo "$repo" "$idea" "x" >/dev/null 2>&1; then fail "--found-by is required"; fi

printf 'ideas_defect: all checks passed\n'
