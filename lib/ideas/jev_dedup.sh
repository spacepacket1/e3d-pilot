#!/usr/bin/env bash
# Advisory-only semantic dedup check via Jev (TypeSafe System One).
#
# Shadow mode: this never blocks ingest and never changes the candidate --
# it only attaches a finding note to the already-materialized idea if Jev
# flags a likely semantic duplicate among the ledger's other live ideas.
# Exact duplicates are already caught upstream by
# ideas_find_duplicate_by_digest (lib/ideas/materialize.sh); this catches
# what hashing can't: different wording, same underlying gap.
#
# Opt-in by credential presence, same convention as the `local` provider's
# LOCAL_MODEL_ENDPOINT check: no TYPESAFE_API_KEY means this silently
# no-ops, not an error.
#
# Stays advisory-only (a note a human can read, never an auto-reject or a
# blocked ingest) until a real calibration sample validates Jev's
# false-positive rate -- see idea-980bf5b4df6b / idea-82a5c2225266.

# Builds the Choice criteria for one idea's dedup check: every other
# non-terminal idea in the same ledger, keyed by idea_id, plus a "none"
# escape hatch. Pure read, no network -- kept separate so it's testable on
# its own. Returns non-zero if there's nothing to compare against.
ideas_jev_dedup_criteria() {
  local kind="$1" workspace="$2" idea_id="$3"
  local snapshots_dir existing_file existing_id existing_status existing_title existing_summary
  local criteria_json count=0
  snapshots_dir="$(ideas_snapshots_dir "$kind" "$workspace")" || return 1
  criteria_json='{"none":"This candidate does not duplicate any idea listed above -- it describes a genuinely different gap or change."}'
  for existing_file in "$snapshots_dir"/*/idea.json; do
    [[ -f "$existing_file" ]] || continue
    existing_id="$(jq -r '.idea_id // ""' "$existing_file")"
    [[ -n "$existing_id" && "$existing_id" != "$idea_id" ]] || continue
    existing_status="$(jq -r '.status // ""' "$existing_file")"
    case "$existing_status" in
      rejected|implementation_failed|merge_failed) continue ;;
    esac
    existing_title="$(jq -r '.title // ""' "$existing_file")"
    [[ -n "$existing_title" ]] || continue
    existing_summary="$(jq -r '.summary // ""' "$existing_file")"
    criteria_json="$(jq -cnS --argjson c "$criteria_json" --arg id "$existing_id" \
      --arg desc "title: ${existing_title} -- summary: ${existing_summary}" \
      '$c + {($id): $desc}')"
    count=$((count + 1))
    # Choice supports at most 255 options; stop well short so "none" and any
    # in-flight additions never risk pushing past the API's own ceiling.
    (( count < 200 )) || break
  done
  (( count > 0 )) || return 1
  printf '%s' "$criteria_json"
}

# ideas_jev_dedup_note <kind> <workspace> <idea_id> <candidate_file>
# Best-effort: always returns 0. Any failure (no key, network, bad response)
# just means no signal was recorded -- never a blocked or altered ingest.
ideas_jev_dedup_note() {
  local kind="$1" workspace="$2" idea_id="$3" candidate_file="$4"
  local title summary criteria_json state_json questions_json response match confidence note_text

  jev_available || return 0
  title="$(jq -r '.title // ""' "$candidate_file" 2>/dev/null)"
  summary="$(jq -r '.summary // ""' "$candidate_file" 2>/dev/null)"
  [[ -n "$title" || -n "$summary" ]] || return 0
  criteria_json="$(ideas_jev_dedup_criteria "$kind" "$workspace" "$idea_id")" || return 0

  state_json="$(jq -ncS --arg title "$title" --arg summary "$summary" \
    '{candidate_title:$title, candidate_summary:$summary}')"
  questions_json="$(jq -ncS --argjson criteria "$criteria_json" '{
    duplicate_match: {
      type: "choice",
      instructions: "The state is a newly proposed idea (candidate_title, candidate_summary) for this repo. Which existing idea below, if any, describes the same underlying gap or change, even if worded differently? Pick \"none\" if the candidate is genuinely distinct from all of them.",
      criteria: $criteria
    }
  }')"

  response="$(jev_call "jev-latest" "$state_json" "$questions_json")" || return 0
  match="$(jq -r '.answers.duplicate_match.choice // "none"' <<<"$response" 2>/dev/null)" || return 0
  [[ -n "$match" && "$match" != "none" ]] || return 0
  confidence="$(jq -r '.answers.duplicate_match.confidence // "unknown"' <<<"$response" 2>/dev/null)"

  note_text="Jev dedup check (shadow-mode, advisory only, not verified by a human): possible semantic duplicate of ${match}, confidence ${confidence}. Does not block this idea."
  ideas_do_note "$kind" "$workspace" "$idea_id" "$note_text" "finding" "jev" "" >/dev/null 2>&1 || true
  return 0
}
