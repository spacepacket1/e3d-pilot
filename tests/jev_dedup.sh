#!/usr/bin/env bash
# Covers lib/ideas/jev_dedup.sh's shadow-mode semantic dedup check, hooked
# into ideas_ingest_candidate (lib/ideas/ledger.sh). Never hits the network:
# TYPESAFE_API_KEY is left unset for the no-op cases, and
# E3D_PILOT_JEV_STUB_RESPONSE (lib/providers/jev.sh's testing seam) stands in
# for a real Jev response for the rest.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"

make_repo() {
  local repo
  repo="$(mktemp -d)"
  git init -q "$repo"
  printf '%s\n' "$repo"
}

candidate_json() {
  local file="$1" title="$2" summary="$3"
  jq -n --arg title "$title" --arg summary "$summary" '{
    focus: "default",
    title: $title,
    summary: $summary,
    repos: [],
    scores: {attraction: 3, retention: 3, revenue: 1, effort: "low"},
    category: "workflow",
    analogy: "test fixture",
    dedup_rationale: "synthetic candidate",
    provenance: {provider: "stub", model: "none"},
    content_digests: {},
    implementation: {targets: []}
  }' > "$file"
}

stub_response() {
  local file="$1" choice="$2" confidence="${3:-0.9}"
  if [[ "$choice" == "none" ]]; then
    jq -n '{answers:{duplicate_match:{type:"choice",choice:"none",probabilities:{none:1},confidence:1}}}' > "$file"
  else
    jq -n --arg choice "$choice" --argjson confidence "$confidence" \
      '{answers:{duplicate_match:{type:"choice",choice:$choice,probabilities:{},confidence:$confidence}}}' > "$file"
  fi
}

notes_json() {
  local repo="$1" idea_id="$2"
  "$BIN" ideas show --repo "$repo" "$idea_id" --json | jq -cS '.notes // []'
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# --- Case 1: no TYPESAFE_API_KEY -> silent no-op, ingest still succeeds ---
repo="$(make_repo)"
cand_a="$(mktemp)"
candidate_json "$cand_a" "First idea" "The very first idea in this ledger."
idea_a="$(env -u TYPESAFE_API_KEY -u E3D_PILOT_JEV_STUB_RESPONSE \
  "$BIN" ideas ingest --repo "$repo" --run-id run-1 --candidate-id cand-a --candidate-json "$cand_a")"
[[ -n "$idea_a" ]] || fail "case 1: ingest did not return an idea id"
notes="$(notes_json "$repo" "$idea_a")"
[[ "$notes" == "[]" ]] || fail "case 1: expected no notes with no API key set, got: $notes"
echo "PASS: case 1 (no key -> no-op)"

# --- Case 2: key set, nothing to compare against yet -> still no note ---
cand_b="$(mktemp)"
candidate_json "$cand_b" "Second idea" "A second, unrelated idea."
resp_none="$(mktemp)"
stub_response "$resp_none" "none"
idea_b="$(TYPESAFE_API_KEY=test-key E3D_PILOT_JEV_STUB_RESPONSE="$resp_none" \
  "$BIN" ideas ingest --repo "$repo" --run-id run-1 --candidate-id cand-b --candidate-json "$cand_b")"
[[ -n "$idea_b" ]] || fail "case 2: ingest did not return an idea id"
notes="$(notes_json "$repo" "$idea_b")"
[[ "$notes" == "[]" ]] || fail "case 2: expected no notes when Jev returns none, got: $notes"
echo "PASS: case 2 (key set, Jev says none -> no note)"

# --- Case 3: key set, Jev flags idea_a as a likely duplicate of idea_c ---
cand_c="$(mktemp)"
candidate_json "$cand_c" "Third idea, worded differently" "Describes the same gap as the first idea."
resp_match="$(mktemp)"
stub_response "$resp_match" "$idea_a" "0.87"
idea_c="$(TYPESAFE_API_KEY=test-key E3D_PILOT_JEV_STUB_RESPONSE="$resp_match" \
  "$BIN" ideas ingest --repo "$repo" --run-id run-1 --candidate-id cand-c --candidate-json "$cand_c")"
[[ -n "$idea_c" ]] || fail "case 3: ingest did not return an idea id"
notes="$(notes_json "$repo" "$idea_c")"
note_count="$(jq 'length' <<<"$notes")"
[[ "$note_count" == "1" ]] || fail "case 3: expected exactly one note, got: $notes"
note_kind="$(jq -r '.[0].kind' <<<"$notes")"
note_actor="$(jq -r '.[0].actor' <<<"$notes")"
note_text="$(jq -r '.[0].text' <<<"$notes")"
[[ "$note_kind" == "finding" ]] || fail "case 3: expected note kind 'finding', got: $note_kind"
[[ "$note_actor" == "jev" ]] || fail "case 3: expected note actor 'jev', got: $note_actor"
[[ "$note_text" == *"$idea_a"* ]] || fail "case 3: expected note text to reference $idea_a, got: $note_text"
[[ "$note_text" == *"0.87"* ]] || fail "case 3: expected note text to include confidence 0.87, got: $note_text"
echo "PASS: case 3 (key set, Jev flags a match -> advisory note attached)"

# --- Case 4: ingest is never blocked by the dedup signal ---
status_c="$("$BIN" ideas show --repo "$repo" "$idea_c" --json | jq -r '.status')"
[[ "$status_c" == "proposed" ]] || fail "case 4: expected idea_c to still be 'proposed' despite the duplicate flag, got: $status_c"
echo "PASS: case 4 (dedup signal is advisory-only, never blocks ingest)"

rm -f "$cand_a" "$cand_b" "$cand_c" "$resp_none" "$resp_match"
rm -rf "$repo"
echo "jev_dedup.sh: all cases passed"
