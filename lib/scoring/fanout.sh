#!/usr/bin/env bash
# Optional post-ideate candidate scoring. Any lib/providers/<name> adapter can
# be selected via config.candidate_scoring.provider; grok-build is one option.
# Scoring never executes, publishes, or approves. It only re-ranks candidates
# before they are materialized as proposed ideas.

SCORING_ROLES=(product technical risk maintainability testability)

scoring_config_provider() {
  jq -r '.candidate_scoring.provider // empty' "$1"
}

scoring_config_workers() {
  jq -r '.candidate_scoring.workers // 3' "$1"
}

scoring_validate_config_file() {
  local file="$1"
  json_type_check "$file" 'if has("candidate_scoring") then (.candidate_scoring | type == "object") else true end' \
    "config.candidate_scoring must be an object when provided"
  json_type_check "$file" 'if has("candidate_scoring") then (.candidate_scoring | has("provider")) else true end' \
    "config.candidate_scoring.provider is required when candidate_scoring is provided"
  json_type_check "$file" 'if has("candidate_scoring") then ((.candidate_scoring.provider | type) == "string" and ((.candidate_scoring.provider | length) > 0)) else true end' \
    "config.candidate_scoring.provider must be a non-empty string"
  json_type_check "$file" 'if (has("candidate_scoring") and (.candidate_scoring | has("workers"))) then ((.candidate_scoring.workers | type == "number") and (.candidate_scoring.workers == (.candidate_scoring.workers | floor)) and (.candidate_scoring.workers >= 3) and (.candidate_scoring.workers <= 5)) else true end' \
    "config.candidate_scoring.workers must be an integer from 3 to 5 when provided"
}

scoring_extract_first_json_object() {
  awk '
    BEGIN { acc=""; n=0 }
    {
      line=$0
      for (i=1; i<=length(line); i++) {
        c=substr(line,i,1)
        if (c=="{") { n++; acc=acc c; continue }
        if (n>0) {
          acc=acc c
          if (c=="}") {
            n--
            if (n==0) { print acc; exit }
          }
        }
      }
      if (n>0) acc=acc "\n"
    }
  ' "$1"
}

scoring_read_scores_json() {
  local file="$1"
  if jq -e 'type == "object" and (.text | type == "string")' "$file" >/dev/null 2>&1; then
    jq -c '.text | fromjson | .scores' "$file" 2>/dev/null && return 0
  fi
  if jq -e 'type == "object" and (.scores | type == "array")' "$file" >/dev/null 2>&1; then
    jq -c '.scores' "$file" && return 0
  fi
  local extracted
  extracted="$(scoring_extract_first_json_object "$file")"
  [[ -n "$extracted" ]] || return 1
  jq -c '.scores' <<<"$extracted" 2>/dev/null
}

scoring_candidates_json_from_markdown() {
  local file="$1" jsonl current="" line
  jsonl="$(mktemp "${TMPDIR:-/tmp}/e3d-scoring-candidates.XXXXXX")"
  : > "$jsonl"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "---IDEATE-STATUS---" ]] && break
    if [[ "$line" =~ ^###\ Candidate\ ([0-9]+):[[:space:]]*(.*)$ ]]; then
      if [[ -n "$current" ]]; then
        scoring_candidate_json_from_block "$current" >> "$jsonl"
      fi
      current="$line"$'\n'
    elif [[ -n "$current" ]]; then
      current+="$line"$'\n'
    fi
  done < "$file"
  if [[ -n "$current" ]]; then
    scoring_candidate_json_from_block "$current" >> "$jsonl"
  fi
  if [[ ! -s "$jsonl" ]]; then
    rm -f "$jsonl"
    printf '[]'
    return 0
  fi
  jq -s '.' "$jsonl"
  rm -f "$jsonl"
}

scoring_candidate_json_from_block() {
  local block="$1" header id num title duplicate summary
  header="$(printf '%s' "$block" | head -n 1)"
  if [[ "$header" =~ ^###\ Candidate\ ([0-9]+):[[:space:]]*(.*)$ ]]; then
    num="${BASH_REMATCH[1]}"
    title="${BASH_REMATCH[2]}"
    id="candidate-$num"
  else
    return 0
  fi
  duplicate="$(printf '%s' "$block" | awk -F': ' '/^Duplicate:/ { print tolower($2); exit }')"
  summary="$(printf '%s' "$block" | awk -F': ' '/^Description:/ { print substr($0, index($0,": ")+2); exit }')"
  jq -ncS \
    --arg id "$id" \
    --arg title "$title" \
    --arg duplicate "$duplicate" \
    --arg summary "$summary" \
    '{
      id:$id,
      title:$title,
      duplicate:(if $duplicate == "yes" then true elif $duplicate == "no" then false else null end),
      summary:$summary
    }'
}

scoring_run_fanout() {
  local cwd="$1" provider="$2" candidates_file="$3" workers="$4" artifact_dir="$5" output_file="$6"
  local script roles_count i role prompt response stderr_file status_file pids_file pid overall_status=0
  local normalized valid_workers=0 scores_json status text_response
  script="${SCORING_PROVIDERS_DIR:-$REPO_ROOT/lib/providers}/$provider"
  [[ -x "$script" ]] || { echo "error: scoring provider script missing or not executable: $script" >&2; return 1; }

  mkdir -p "$artifact_dir" "$(dirname "$output_file")"
  pids_file="$(mktemp "${TMPDIR:-/tmp}/e3d-scoring-pids.XXXXXX")"
  scoring_kill_workers() {
    local worker_pid
    while IFS= read -r worker_pid; do
      [[ -n "$worker_pid" ]] || continue
      kill -TERM "$worker_pid" 2>/dev/null || true
    done < "$pids_file"
  }

  roles_count=${#SCORING_ROLES[@]}
  for ((i=0; i<workers; i++)); do
    role="${SCORING_ROLES[$((i % roles_count))]}"
    prompt="$artifact_dir/worker-${i}-${role}.prompt.md"
    response="$artifact_dir/worker-${i}-${role}.stdout"
    stderr_file="$artifact_dir/worker-${i}-${role}.stderr"
    status_file="$artifact_dir/worker-${i}-${role}.status"
    {
      printf 'Act as a read-only %s evaluator. Score every candidate from 0 to 100.\n' "$role"
      printf 'Do not edit files, invoke subagents, or make high-consequence decisions.\n'
      printf 'Return JSON only: {"scores":[{"id":"...","score":0,"reason":"..."}]}.\n'
      printf 'Use exactly the candidate ids supplied, once each.\n\nCandidates:\n'
      cat "$candidates_file"
      printf '\n'
    } > "$prompt"
    (
      set +e
      cd "$cwd"
      if [[ "$provider" == "grok-build" ]]; then
        GROK_BUILD_OUTPUT_FORMAT=json "$script" "$prompt" > "$response" 2> "$stderr_file"
      else
        "$script" "$prompt" > "$response" 2> "$stderr_file"
      fi
      printf '%s\n' "$?" > "$status_file"
    ) &
    printf '%s\n' "$!" >> "$pids_file"
  done

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    if ! wait "$pid"; then overall_status=1; fi
  done < "$pids_file"
  : > "$pids_file"

  normalized="$artifact_dir/normalized-workers.json"
  : > "$normalized"
  for ((i=0; i<workers; i++)); do
    role="${SCORING_ROLES[$((i % roles_count))]}"
    response="$artifact_dir/worker-${i}-${role}.stdout"
    status_file="$artifact_dir/worker-${i}-${role}.status"
    status=1
    [[ -f "$status_file" ]] && status="$(<"$status_file")"
    scores_json=""
    if [[ $status -eq 0 ]]; then
      scores_json="$(scoring_read_scores_json "$response" 2>/dev/null || true)"
    fi
    if [[ $status -eq 0 && -n "$scores_json" ]] && jq -n -e --slurpfile candidates "$candidates_file" --argjson scores "$scores_json" '
        ($scores | type == "array") and
        (($scores | map(.id) | sort) == ($candidates[0] | map(.id) | sort)) and
        (all($scores[]; (.score | type == "number") and .score >= 0 and .score <= 100 and (.reason | type == "string")))
      ' >/dev/null 2>&1; then
      valid_workers=$((valid_workers + 1))
      jq -n -c --arg role "$role" --argjson scores "$scores_json" \
        --argjson tokens "$(jq -c '.usage.total_tokens // .usage.totalTokens // null' "$response" 2>/dev/null || printf null)" \
        --argjson cost "$(jq -c '.total_cost_usd // .usage.total_cost_usd // null' "$response" 2>/dev/null || printf null)" \
        '{role:$role,status:0,scores:$scores,tokens:$tokens,cost_usd:$cost}' >> "$normalized"
    else
      text_response=""
      if [[ -f "$response" ]]; then
        text_response="$(jq -r '.text // empty' "$response" 2>/dev/null || true)"
        [[ -n "$text_response" ]] || text_response="$(head -c 2000 "$response" 2>/dev/null || true)"
      fi
      jq -n -c --arg role "$role" --argjson status "$status" --arg text "$text_response" \
        '{role:$role,status:$status,scores:[],tokens:null,cost_usd:null,error:(if $text == "" then "missing or invalid JSON response" else $text end)}' \
        >> "$normalized"
      overall_status=1
    fi
  done

  scoring_kill_workers
  rm -f "$pids_file"

  if (( valid_workers == 0 )); then
    echo "error: all scoring workers failed; inspect $artifact_dir" >&2
    return 1
  fi

  jq -s --arg provider "$provider" --argjson requested "$workers" --argjson valid "$valid_workers" '
    . as $workers |
    ([.[].scores[]] | group_by(.id) | map({
      id: .[0].id,
      average_score: ((map(.score) | add / length) * 100 | round / 100),
      worker_scores: map({score, reason})
    }) | sort_by(-.average_score)) as $ranked |
    {schema_version:1, strategy:"read-only-fanout", provider:$provider,
     requested_workers:$requested, valid_workers:$valid,
     partial:($valid != $requested), workers:$workers, ranked:$ranked,
     downstream:"existing negotiation then csr execute; scoring never executes"}
  ' "$normalized" > "$output_file"
  return "$overall_status"
}

scoring_block_id() {
  local header
  header="$(head -n 1 "$1")"
  if [[ "$header" =~ ^###\ Candidate\ ([0-9]+): ]]; then
    printf 'candidate-%s' "${BASH_REMATCH[1]}"
  fi
}

scoring_annotate_block() {
  local block="$1" score="$2"
  if printf '%s' "$block" | grep -q '^Ensemble (0-100):'; then
    printf '%s' "$block" | sed "s/^Ensemble (0-100):.*/Ensemble (0-100): $score/"
  else
    printf '%s\n' "$(printf '%s' "$block" | head -n 1)"
    printf 'Ensemble (0-100): %s\n' "$score"
    printf '%s' "$block" | tail -n +2
  fi
}

scoring_rewrite_response() {
  local response_file="$1" scoring_file="$2" model_selected="$3" model_reason="$4"
  local dir i block_file id duplicate score new_selected new_reason ranked_ids candidate_id
  dir="$(mktemp -d "${TMPDIR:-/tmp}/e3d-scoring-blocks.XXXXXX")"
  i=0
  local current="" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "---IDEATE-STATUS---" ]] && break
    if [[ "$line" =~ ^###\ Candidate\  ]]; then
      if [[ -n "$current" ]]; then
        i=$((i + 1))
        printf '%s' "$current" > "$dir/block-$i.md"
      fi
      current="$line"$'\n'
    elif [[ -n "$current" ]]; then
      current+="$line"$'\n'
    fi
  done < "$response_file"
  if [[ -n "$current" ]]; then
    i=$((i + 1))
    printf '%s' "$current" > "$dir/block-$i.md"
  fi
  (( i > 0 )) || { rm -rf "$dir"; return 1; }

  ranked_ids="$(jq -r '.ranked[].id' "$scoring_file")"
  for candidate_id in $ranked_ids; do
    for block_file in "$dir"/block-*.md; do
      [[ -f "$block_file" ]] || continue
      id="$(scoring_block_id "$block_file")"
      [[ "$id" == "$candidate_id" ]] || continue
      score="$(jq -r --arg id "$id" '.ranked[] | select(.id==$id) | .average_score' "$scoring_file")"
      scoring_annotate_block "$(cat "$block_file")" "$score" > "$block_file.annotated"
      mv "$block_file.annotated" "$block_file"
    done
  done

  new_selected="$(jq -r --argjson candidates "$(scoring_candidates_json_from_markdown "$response_file")" '
    (.ranked) as $ranked |
    ($candidates | map(select(.duplicate == false) | .id)) as $eligible |
    [$ranked[] | select(.id as $id | $eligible | index($id))][0].id // empty
  ' "$scoring_file")"
  if [[ -z "$new_selected" ]]; then
    new_selected="none"
    new_reason="ensemble scoring found no non-duplicate candidate; original model selected ${model_selected:-none}"
  else
    score="$(jq -r --arg id "$new_selected" '.ranked[] | select(.id==$id) | .average_score' "$scoring_file")"
    new_reason="ensemble score ${score} via $(jq -r '.provider' "$scoring_file") ($(jq -r '.valid_workers' "$scoring_file") workers); original model selected ${model_selected:-none}"
  fi

  local out="$dir/rewritten.md"
  : > "$out"
  local -a emitted=()
  local already
  for candidate_id in $ranked_ids; do
    for block_file in "$dir"/block-*.md; do
      id="$(scoring_block_id "$block_file")"
      [[ "$id" == "$candidate_id" ]] || continue
      duplicate="$(awk -F': ' '/^Duplicate:/ { print tolower($2); exit }' "$block_file")"
      [[ "$duplicate" == "no" ]] || continue
      cat "$block_file" >> "$out"
      printf '\n' >> "$out"
      emitted+=("$id")
    done
  done
  for block_file in "$dir"/block-*.md; do
    id="$(scoring_block_id "$block_file")"
    already=0
    for emitted_id in "${emitted[@]+"${emitted[@]}"}"; do
      [[ "$emitted_id" == "$id" ]] && already=1
    done
    (( already == 0 )) || continue
    cat "$block_file" >> "$out"
    printf '\n' >> "$out"
  done
  {
    printf -- '---IDEATE-STATUS---\n'
    printf 'selected: %s\n' "$new_selected"
    printf 'reason: %s\n' "$new_reason"
  } >> "$out"
  cp "$out" "$response_file"
  printf '%s\t%s\t%s\n' "$new_selected" "$new_reason" "$model_selected"
  rm -rf "$dir"
}

# Returns 0 if scoring is not configured or was applied (possibly with a
# warning fallback). Returns 1 only when the configured provider is
# unavailable -- that is an operator error, like a missing negotiate reviewer.
scoring_apply_if_configured() {
  local cwd="$1" config_file="$2" run_dir="$3" response_file="$4" label="${5:-ideate}"
  local provider workers candidates_json_file artifact_dir output_file availability_output
  local model_selected model_reason selection_line

  provider="$(scoring_config_provider "$config_file")"
  [[ -n "$provider" ]] || return 0

  workers="$(scoring_config_workers "$config_file")"
  [[ "$workers" =~ ^[0-9]+$ ]] && (( workers >= 3 && workers <= 5 )) \
    || { echo "error: candidate_scoring.workers must be an integer from 3 to 5" >&2; return 1; }

  local provider_script="${SCORING_PROVIDERS_DIR:-$REPO_ROOT/lib/providers}/$provider"
  [[ -x "$provider_script" ]] || { echo "error: candidate_scoring provider script missing or not executable: $provider_script" >&2; return 1; }
  if availability_output="$(provider_availability_probe "$provider_script")"; then
    :
  else
    echo "error: candidate_scoring provider \"$provider\" unavailable: ${availability_output:-no availability details}" >&2
    return 1
  fi

  model_selected="$(ideate_status_field "selected" < "$response_file" || true)"
  model_reason="$(ideate_status_field "reason" < "$response_file" || true)"

  candidates_json_file="$run_dir/${label}-scoring-candidates.json"
  scoring_candidates_json_from_markdown "$response_file" > "$candidates_json_file"
  if [[ "$(jq 'length' "$candidates_json_file")" -eq 0 ]]; then
    printf '%s: warning: candidate scoring skipped; no parseable candidates\n' "$label"
    return 0
  fi
  if [[ "$(jq '[.[] | select(.duplicate == false)] | length' "$candidates_json_file")" -eq 0 ]]; then
    printf '%s: candidate scoring skipped; every candidate is marked duplicate\n' "$label"
    return 0
  fi

  cp "$response_file" "$run_dir/${label}-response.model.md"
  artifact_dir="$run_dir/${label}-scoring.artifacts"
  output_file="$run_dir/${label}-scoring.json"
  if ! scoring_run_fanout "$cwd" "$provider" "$candidates_json_file" "$workers" "$artifact_dir" "$output_file"; then
    if [[ ! -s "$output_file" ]]; then
      printf '%s: warning: candidate scoring failed; keeping model ranking\n' "$label"
      return 0
    fi
    printf '%s: warning: candidate scoring was partial; applying scores from valid workers\n' "$label"
  fi

  selection_line="$(scoring_rewrite_response "$response_file" "$output_file" "$model_selected" "$model_reason")"
  printf '%s\n' "$selection_line" > "$run_dir/${label}-scoring-selection.txt"
  printf '%s: scored candidates with %s (%s workers); selected %s (model selected %s)\n' \
    "$label" "$provider" "$workers" "$(printf '%s' "$selection_line" | cut -f1)" "$model_selected"
  return 0
}
