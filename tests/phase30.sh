#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"

# shellcheck source=../lib/ideas/ledger.sh
source "$ROOT/lib/ideas/ledger.sh"

make_repo() {
  local repo
  repo="$(mktemp -d)"
  git init -q "$repo"
  printf '%s\n' "$repo"
}

new_idea() {
  local repo="$1" candidate_id="$2" title="$3" candidate
  candidate="$(mktemp)"
  jq -n --arg title "$title" '{
    title: $title,
    summary: "Trace query fixture",
    repos: ["repo-a"],
    scores: {attraction: 4, retention: 3, revenue: 2, effort: "low"},
    category: "workflow",
    provenance: {provider: "fixture", model: "trace-model"},
    implementation: {targets: []}
  }' > "$candidate"
  "$BIN" ideas ingest --repo "$repo" --run-id run-30 --candidate-id "$candidate_id" --candidate-json "$candidate"
  rm -f "$candidate"
}

append_custom_event() {
  local repo="$1" idea_id="$2" event="$3" extra_json="$4" extra
  extra="$(mktemp)"
  printf '%s\n' "$extra_json" > "$extra"
  ideas_append_custom_event repo "$repo" "$idea_id" "$event" fixture "$event fixture" "$extra"
  rm -f "$extra"
}

assert_all_section_items_have_event_ids() {
  jq -e '
    [.proposed, .decisions, .findings, .produced, .observed, .outcomes,
     (.failure // [])]
    | all(.[]; all(.[]; (.event_id | type == "string" and length > 0)))
  ' >/dev/null
}

rejected_trace_shows_decision_and_actor() {
  local repo idea json text
  repo="$(make_repo)"
  idea="$(new_idea "$repo" rejected "Rejected trace")"
  "$BIN" ideas transition --repo "$repo" "$idea" idea_rejected --actor rejection-reviewer --note "not this cycle" >/dev/null

  json="$("$BIN" provenance trace --repo "$repo" "$idea" --json)"
  jq -e '.decisions | any(.relation == "decided:idea_rejected" and .actor == "rejection-reviewer" and (.event_id | length > 0))' <<<"$json" >/dev/null
  assert_all_section_items_have_event_ids <<<"$json"
  text="$("$BIN" provenance trace --repo "$repo" "$idea")"
  grep -q '^Decisions$' <<<"$text"
  grep -q 'relation=decided:idea_rejected actor=rejection-reviewer' <<<"$text"
  rm -rf "$repo"
}

implemented_trace_separates_produced_and_observed() {
  local repo idea target outcome sync metric json text produced_event
  repo="$(make_repo)"
  idea="$(new_idea "$repo" implemented "Implemented trace")"
  "$BIN" ideas transition --repo "$repo" "$idea" implementation_approved --actor approver >/dev/null
  "$BIN" ideas transition --repo "$repo" "$idea" implementation_started --actor builder >/dev/null
  target='{"repo":"repo-a","pr_url":"https://example.test/repo-a/pull/30","final_pr_head_sha":"produced-sha"}'
  outcome="$(mktemp)"
  jq -ncS --arg idea "$idea" --argjson target "$target" '{type:"implementation",idea_id:$idea,status:"succeeded",targets:[$target]}' > "$outcome"
  ideas_transition repo "$repo" "$idea" implementation_completed builder "completed" "" "" "$outcome" >/dev/null
  produced_event="$(jq -r 'select(.event=="implementation_completed") | .event_id' "$repo/.e3d-pilot/events.jsonl" | tail -n1)"
  rm -f "$outcome"

  sync="$(jq -ncS '{observations:[
    {repo:"repo-a",pr_url:"https://example.test/repo-a/pull/30",head_sha:"produced-sha"},
    {repo:"external-repo",pr_url:"https://example.test/external/pull/9",head_sha:"observed-sha"}
  ]}')"
  append_custom_event "$repo" "$idea" forge_sync "$sync" >/dev/null
  metric='{"outcome":{"type":"metrics","window":"7d","metrics":[{"key":"useful","value":true}]}}'
  append_custom_event "$repo" "$idea" outcome_recorded "$metric" >/dev/null

  json="$("$BIN" provenance trace --repo "$repo" "$idea" --json)"
  jq -e --arg event "$produced_event" '
    (.produced | any(.commit == "produced-sha"
                     and .pr == "https://example.test/repo-a/pull/30"
                     and .event_id == $event))
    and (.observed | all(.commit != "produced-sha"))
    and (.observed | any(.commit == "observed-sha"))
    and (.outcomes | any(.data.outcome.window == "7d" and .data.outcome.metrics[0].key == "useful"))
  ' <<<"$json" >/dev/null
  assert_all_section_items_have_event_ids <<<"$json"
  text="$("$BIN" provenance trace --repo "$repo" "$idea")"
  grep -A2 '^Produced$' <<<"$text" | grep -q 'commit=produced-sha.*pull/30.*event_id='
  if grep -A2 '^Observed$' <<<"$text" | grep -q 'produced-sha'; then
    printf 'produced commit leaked into Observed section\n' >&2
    exit 1
  fi
  rm -rf "$repo"
}

failure_trace_uses_nearest_prior_context() {
  local repo idea decision_id finding_id failure_id outcome json text stripped
  repo="$(make_repo)"
  idea="$(new_idea "$repo" failed "Failed trace")"
  "$BIN" ideas transition --repo "$repo" "$idea" implementation_approved --actor approver >/dev/null
  decision_id="$("$BIN" ideas note --repo "$repo" --decision "$idea" "choose the narrow path" --actor decider >/dev/null; jq -r 'select(.event=="note_appended" and .kind=="decision") | .event_id' "$repo/.e3d-pilot/events.jsonl" | tail -n1)"
  sleep 1
  "$BIN" ideas note --repo "$repo" "$idea" "the latest relevant evidence" --actor researcher >/dev/null
  finding_id="$(jq -r 'select(.event=="note_appended" and .kind=="finding") | .event_id' "$repo/.e3d-pilot/events.jsonl" | tail -n1)"
  sleep 1
  "$BIN" ideas transition --repo "$repo" "$idea" implementation_started --actor builder >/dev/null
  outcome="$(mktemp)"
  jq -ncS --arg idea "$idea" '{type:"implementation",idea_id:$idea,status:"failed",targets:[],failure_reason:"fixture"}' > "$outcome"
  ideas_transition repo "$repo" "$idea" implementation_failed builder "failed" "" "" "$outcome" >/dev/null
  failure_id="$(jq -r 'select(.event=="implementation_failed") | .event_id' "$repo/.e3d-pilot/events.jsonl" | tail -n1)"
  rm -f "$outcome"

  json="$("$BIN" provenance trace --repo "$repo" "$idea" --json)"
  jq -e --arg failure "$failure_id" --arg finding "$finding_id" --arg decision "$decision_id" '
    (.failure | length == 1)
    and (.failure[0].event_id == $failure)
    and (.failure[0].nearest_prior_context == $finding)
    and (.failure[0].nearest_prior_context != $decision)
    and (.failure[0] | has("invalidated") | not)
  ' <<<"$json" >/dev/null
  assert_all_section_items_have_event_ids <<<"$json"

  text="$("$BIN" provenance trace --repo "$repo" "$idea")"
  grep -q '^Failure$' <<<"$text"
  grep -q "event_id=$failure_id.*nearest_prior_context=$finding_id" <<<"$text"
  grep -q 'no invalidation is claimed; this is the nearest preceding entry in time only' <<<"$text"
  stripped="${text//no invalidation is claimed; this is the nearest preceding entry in time only/}"
  if grep -Eqi 'invalidate|invalidated|invalidates|invalidation' <<<"$stripped"; then
    printf 'trace made an unsupported causal claim\n' >&2
    exit 1
  fi
  rm -rf "$repo"
}

evidence_round_trips_and_absence_stays_absent() {
  local repo idea json text
  repo="$(make_repo)"
  idea="$(new_idea "$repo" evidence "Evidence trace")"
  "$BIN" ideas note --repo "$repo" --decision "$idea" "decision with support" \
    --actor decider --evidence "docs/debate.md#decision" >/dev/null
  "$BIN" ideas note --repo "$repo" "$idea" "finding with support" \
    --actor researcher --evidence "https://example.test/evidence/30" >/dev/null
  "$BIN" ideas note --repo "$repo" "$idea" "finding without support" --actor researcher >/dev/null

  json="$("$BIN" provenance trace --repo "$repo" "$idea" --json)"
  jq -e '
    (.decisions | any(.text == "decision with support" and .evidence_ref == "docs/debate.md#decision"))
    and (.findings | any(.text == "finding with support" and .evidence_ref == "https://example.test/evidence/30"))
    and (.findings | any(.text == "finding without support" and (has("evidence_ref") | not)))
  ' <<<"$json" >/dev/null

  text="$("$BIN" provenance trace --repo "$repo" "$idea")"
  grep -E -q 'text=decision with support.*event_id=.* evidence_ref=docs/debate.md#decision$' <<<"$text"
  grep -E -q 'text=finding with support.*event_id=.* evidence_ref=https://example.test/evidence/30$' <<<"$text"
  if grep 'finding without support' <<<"$text" | grep -q 'evidence_ref='; then
    printf 'trace rendered an absent evidence reference\n' >&2
    exit 1
  fi
  rm -rf "$repo"
}

main() {
  bash -n "$BIN"
  bash -n "$ROOT/lib/provenance/graph.sh"
  rejected_trace_shows_decision_and_actor
  implemented_trace_separates_produced_and_observed
  failure_trace_uses_nearest_prior_context
  evidence_round_trips_and_absence_stays_absent
  echo "phase30: all tests passed"
}

main "$@"
