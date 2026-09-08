#!/usr/bin/env bash
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
  local file="$1" title="${2:-Context verbs idea}"
  jq -n \
    --arg title "$title" \
    '{
      focus: "default",
      title: $title,
      summary: "Test idea for append_finding/get_context/build_handoff.",
      repos: ["repo-a"],
      scores: {attraction: 4, retention: 3, revenue: 2, effort: "low"},
      category: "workflow",
      dedup_rationale: "synthetic candidate for phase28",
      provenance: {provider: "stub", model: "none"},
      content_digests: {},
      implementation: {targets: []}
    }' > "$file"
}

new_idea() {
  local repo="$1" title="${2:-Context verbs idea}" candidate idea_id
  candidate="$(mktemp)"
  candidate_json "$candidate" "$title"
  idea_id="$("$BIN" ideas ingest --repo "$repo" --run-id run-1 --candidate-id "candidate-$RANDOM" --candidate-json "$candidate")"
  rm -f "$candidate"
  printf '%s' "$idea_id"
}

note_appends_finding_by_default() {
  local repo idea_id notes
  repo="$(make_repo)"
  idea_id="$(new_idea "$repo")"
  "$BIN" ideas note --repo "$repo" "$idea_id" "first finding" --actor tester@example.com >/dev/null
  notes="$(jq -c '.notes' "$repo/.e3d-pilot/ideas/$idea_id/idea.json")"
  [[ "$(jq -r '.[0].kind' <<<"$notes")" == "finding" ]] || { printf 'expected default kind=finding\n' >&2; exit 1; }
  [[ "$(jq -r '.[0].text' <<<"$notes")" == "first finding" ]] || { printf 'wrong note text\n' >&2; exit 1; }
  [[ "$(jq -r '.[0].actor' <<<"$notes")" == "tester@example.com" ]] || { printf 'wrong note actor\n' >&2; exit 1; }
  [[ "$(jq -r '.last_decision_actor' "$repo/.e3d-pilot/ideas/$idea_id/idea.json")" == "null" ]] || {
    printf 'a finding must not set last_decision_actor\n' >&2
    exit 1
  }
  rm -rf "$repo"
}

note_decision_flag_sets_kind_and_last_decision() {
  local repo idea_id file
  repo="$(make_repo)"
  idea_id="$(new_idea "$repo")"
  "$BIN" ideas note --repo "$repo" --decision "$idea_id" "ship the minimal slice" --actor decider@example.com >/dev/null
  file="$repo/.e3d-pilot/ideas/$idea_id/idea.json"
  [[ "$(jq -r '.notes[0].kind' "$file")" == "decision" ]] || { printf 'expected kind=decision\n' >&2; exit 1; }
  [[ "$(jq -r '.last_decision_actor' "$file")" == "decider@example.com" ]] || {
    printf 'a decision must set last_decision_actor\n' >&2
    exit 1
  }
  [[ "$(jq -r '.last_decision_at' "$file")" != "null" ]] || { printf 'a decision must set last_decision_at\n' >&2; exit 1; }
  rm -rf "$repo"
}

note_does_not_change_status_or_existing_fields() {
  local repo idea_id before after
  repo="$(make_repo)"
  idea_id="$(new_idea "$repo")"
  "$BIN" ideas transition --repo "$repo" "$idea_id" implementation_approved --actor t@e.com >/dev/null
  before="$(jq -cS 'del(.updated_at, .notes, .last_event_id)' "$repo/.e3d-pilot/ideas/$idea_id/idea.json")"
  "$BIN" ideas note --repo "$repo" "$idea_id" "a note after approval" --actor t@e.com >/dev/null
  after="$(jq -cS 'del(.updated_at, .notes, .last_event_id)' "$repo/.e3d-pilot/ideas/$idea_id/idea.json")"
  [[ "$before" == "$after" ]] || { printf 'note_appended mutated unrelated idea fields\n' >&2; exit 1; }
  [[ "$(jq -r '.status' "$repo/.e3d-pilot/ideas/$idea_id/idea.json")" == "approved_for_implementation" ]] || {
    printf 'note_appended must not change lifecycle status\n' >&2
    exit 1
  }
  rm -rf "$repo"
}

notes_survive_rebuild() {
  local repo idea_id notes_before notes_after
  repo="$(make_repo)"
  idea_id="$(new_idea "$repo")"
  "$BIN" ideas note --repo "$repo" "$idea_id" "durable finding" --actor t@e.com >/dev/null
  "$BIN" ideas note --repo "$repo" --decision "$idea_id" "durable decision" --actor t@e.com >/dev/null
  notes_before="$(jq -cS '.notes' "$repo/.e3d-pilot/ideas/$idea_id/idea.json")"
  "$BIN" ideas rebuild --repo "$repo" >/dev/null
  notes_after="$(jq -cS '.notes' "$repo/.e3d-pilot/ideas/$idea_id/idea.json")"
  [[ "$notes_before" == "$notes_after" ]] || { printf 'notes did not survive ledger rebuild\n' >&2; exit 1; }
  [[ "$(jq 'length' <<<"$notes_after")" == "2" ]] || { printf 'expected 2 notes after rebuild\n' >&2; exit 1; }
  rm -rf "$repo"
}

context_json_separates_decisions_and_findings() {
  local repo idea_id ctx
  repo="$(make_repo)"
  idea_id="$(new_idea "$repo")"
  "$BIN" ideas note --repo "$repo" "$idea_id" "a finding" --actor t@e.com >/dev/null
  "$BIN" ideas note --repo "$repo" --decision "$idea_id" "a decision" --actor t@e.com >/dev/null
  ctx="$("$BIN" ideas context --repo "$repo" "$idea_id" --json)"
  [[ "$(jq -r '.idea_id' <<<"$ctx")" == "$idea_id" ]] || { printf 'context json missing idea_id\n' >&2; exit 1; }
  [[ "$(jq '.decisions | length' <<<"$ctx")" == "1" ]] || { printf 'expected 1 decision\n' >&2; exit 1; }
  [[ "$(jq '.findings | length' <<<"$ctx")" == "1" ]] || { printf 'expected 1 finding\n' >&2; exit 1; }
  [[ "$(jq -r '.decisions[0].text' <<<"$ctx")" == "a decision" ]] || { printf 'wrong decision text\n' >&2; exit 1; }
  [[ "$(jq -r '.findings[0].text' <<<"$ctx")" == "a finding" ]] || { printf 'wrong finding text\n' >&2; exit 1; }
  rm -rf "$repo"
}

context_and_handoff_render_none_recorded_when_empty() {
  local repo idea_id ctx_out handoff_out
  repo="$(make_repo)"
  idea_id="$(new_idea "$repo")"
  ctx_out="$("$BIN" ideas context --repo "$repo" "$idea_id")"
  handoff_out="$("$BIN" ideas handoff --repo "$repo" "$idea_id")"
  grep -q '(none recorded)' <<<"$ctx_out" || { printf 'expected context to render (none recorded)\n' >&2; exit 1; }
  grep -q '(none recorded)' <<<"$handoff_out" || { printf 'expected handoff to render (none recorded)\n' >&2; exit 1; }
  rm -rf "$repo"
}

handoff_includes_goal_status_decisions_and_findings() {
  local repo idea_id out
  repo="$(make_repo)"
  idea_id="$(new_idea "$repo" "Handoff packet idea")"
  "$BIN" ideas note --repo "$repo" "$idea_id" "observed something relevant" --actor t@e.com >/dev/null
  "$BIN" ideas note --repo "$repo" --decision "$idea_id" "decided to proceed" --actor t@e.com >/dev/null
  out="$("$BIN" ideas handoff --repo "$repo" "$idea_id")"
  grep -q '^GOAL$' <<<"$out" || { printf 'missing GOAL section\n' >&2; exit 1; }
  grep -q 'Handoff packet idea' <<<"$out" || { printf 'missing title in GOAL\n' >&2; exit 1; }
  grep -q '^STATUS$' <<<"$out" || { printf 'missing STATUS section\n' >&2; exit 1; }
  grep -q '^RELEVANT DECISIONS$' <<<"$out" || { printf 'missing RELEVANT DECISIONS section\n' >&2; exit 1; }
  grep -q 'decided to proceed' <<<"$out" || { printf 'missing decision text\n' >&2; exit 1; }
  grep -q '^RECENT FINDINGS$' <<<"$out" || { printf 'missing RECENT FINDINGS section\n' >&2; exit 1; }
  grep -q 'observed something relevant' <<<"$out" || { printf 'missing finding text\n' >&2; exit 1; }
  rm -rf "$repo"
}

note_requires_repo_and_two_positionals() {
  local repo idea_id
  repo="$(make_repo)"
  idea_id="$(new_idea "$repo")"
  if "$BIN" ideas note "$idea_id" "text" >/dev/null 2>&1; then
    printf 'expected ideas note without --repo to fail\n' >&2
    exit 1
  fi
  if "$BIN" ideas note --repo "$repo" "$idea_id" >/dev/null 2>&1; then
    printf 'expected ideas note with missing text argument to fail\n' >&2
    exit 1
  fi
  rm -rf "$repo"
}

note_evidence_ref_survives_materialization_and_rebuild() {
  local repo idea_id file
  repo="$(make_repo)"
  idea_id="$(new_idea "$repo")"
  "$BIN" ideas note --repo "$repo" --decision --evidence "docs/debates/example/transcript.md" "$idea_id" "with evidence" --actor t@e.com >/dev/null
  "$BIN" ideas note --repo "$repo" "$idea_id" "no evidence" --actor t@e.com >/dev/null
  file="$repo/.e3d-pilot/ideas/$idea_id/idea.json"
  [[ "$(jq -r '.notes[0].evidence_ref' "$file")" == "docs/debates/example/transcript.md" ]] || {
    printf 'evidence_ref did not materialize into idea.json notes\n' >&2
    exit 1
  }
  [[ "$(jq -r '.notes[1] | has("evidence_ref")' "$file")" == "false" ]] || {
    printf 'a note without --evidence must not gain an evidence_ref key\n' >&2
    exit 1
  }
  "$BIN" ideas rebuild --repo "$repo" >/dev/null
  [[ "$(jq -r '.notes[0].evidence_ref' "$file")" == "docs/debates/example/transcript.md" ]] || {
    printf 'evidence_ref did not survive ledger rebuild\n' >&2
    exit 1
  }
  rm -rf "$repo"
}

main() {
  bash -n "$BIN"
  bash -n "$ROOT/lib/ideas/ledger.sh"
  note_appends_finding_by_default
  note_decision_flag_sets_kind_and_last_decision
  note_does_not_change_status_or_existing_fields
  notes_survive_rebuild
  context_json_separates_decisions_and_findings
  context_and_handoff_render_none_recorded_when_empty
  handoff_includes_goal_status_decisions_and_findings
  note_requires_repo_and_two_positionals
  note_evidence_ref_survives_materialization_and_rebuild
  echo "phase28: all tests passed"
}

main "$@"
