#!/usr/bin/env bash

ideas_relative_path() {
  local workspace="$1" path="$2"
  if [[ "$path" == "$workspace/"* ]]; then
    printf '%s' "${path#$workspace/}"
  else
    printf '%s' "$path"
  fi
}

ideas_artifact_digest_json() {
  local workspace="$1"
  shift
  local artifact path rel digest first=1
  printf '['
  for artifact in "$@"; do
    [[ -f "$artifact" ]] || continue
    rel="$(ideas_relative_path "$workspace" "$artifact")"
    digest="$(ideas_sha256 < "$artifact")"
    if (( first == 0 )); then
      printf ','
    fi
    first=0
    jq -ncS --arg path "$rel" --arg sha256 "$digest" '{path:$path,sha256:$sha256}'
  done
  printf ']'
}

ideas_candidate_digest_from_json() {
  local file="$1"
  jq -cS '{
    title: (.title // null),
    summary: (.summary // null),
    repos: (.repos // []),
    scores: {
      attraction: (.scores.attraction // null),
      retention: (.scores.retention // null),
      revenue: (.scores.revenue // null),
      effort: (.scores.effort // null)
    },
    category: (.category // null),
    dedup_rationale: (.dedup_rationale // null),
    implementation_target_plan: []
  }' "$file" | ideas_sha256
}

ideas_find_duplicate_by_digest() {
  local kind="$1" workspace="$2" candidate_file="$3" stable_idea_id="${4:-}"
  local canonical snapshots_dir digest existing_file existing_id existing_digest
  canonical="$(ideas_canonical_path "$workspace")" || return 1
  snapshots_dir="$(ideas_snapshots_dir "$kind" "$canonical")" || return 1
  [[ -d "$snapshots_dir" ]] || return 1
  digest="$(ideas_candidate_digest_from_json "$candidate_file")"
  for existing_file in "$snapshots_dir"/*/idea.json; do
    [[ -f "$existing_file" ]] || continue
    existing_id="$(jq -r '.idea_id' "$existing_file")"
    [[ -n "$stable_idea_id" && "$existing_id" == "$stable_idea_id" ]] && continue
    existing_digest="$(ideas_decision_digest_from_json "$existing_file")"
    if [[ "$existing_digest" == "$digest" ]]; then
      printf '%s' "$existing_id"
      return 0
    fi
  done
  return 1
}

ideas_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

ideas_json_string_array() {
  local first=1 item
  printf '['
  for item in "$@"; do
    if (( first == 0 )); then
      printf ','
    fi
    first=0
    jq -Rn --arg v "$item" '$v'
  done
  printf ']'
}

ideas_extract_field_value() {
  local file="$1" label="$2"
  awk -v label="$label" '
    index($0, label ":") == 1 {
      sub("^[^:]+:[[:space:]]*", "", $0)
      print
      exit
    }
  ' "$file"
}

ideas_parse_candidate_blocks() {
  local candidates_file="$1" output_dir="$2"
  local in_proposed=0 current_index=0 current_file="" line
  mkdir -p "$output_dir"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( in_proposed == 0 )); then
      [[ "$line" == "## Proposed Candidates" ]] && in_proposed=1
      continue
    fi
    [[ "$line" == "---IDEATE-STATUS---" ]] && break
    if [[ "$line" =~ ^##[[:space:]] ]] && (( current_index == 0 )); then
      continue
    fi
    if [[ "$line" =~ ^###\ Candidate ]]; then
      current_index=$((current_index + 1))
      current_file="$output_dir/candidate-$current_index.md"
      : > "$current_file"
    fi
    [[ -n "$current_file" ]] || continue
    printf '%s\n' "$line" >> "$current_file"
  done < "$candidates_file"
  printf '%s\n' "$current_index"
}

ideas_fleet_repo_map_json() {
  local fleet_file="$1" repo canonical name first=1
  printf '{'
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    canonical="$(ideas_canonical_path "$repo")" || return 1
    name="$(basename "$canonical")"
    if (( first == 0 )); then
      printf ','
    fi
    first=0
    jq -ncS --arg name "$name" --arg path "$canonical" '{($name):[$path]}' | sed 's/^{//;s/}$//'
  done < <(jq -r '.[]' "$fleet_file")
  printf '}'
}

ideas_materialize_candidate_record() {
  local kind="$1" workspace="$2" source_run_id="$3" selected="$4" focus="$5" block_file="$6" rank="$7" artifacts_json="$8" fleet_repo_map_json="${9:-}"
  local title duplicate_raw duplicate_value summary category analogy effort dedup_rationale attraction retention revenue ensemble
  local repos_field="" candidate_num="" candidate_id="" source_candidate="" header=""
  local -a warnings=() resolved_repos=() raw_repos=()
  local approvable=true eligibility_reason="" warn_json repos_json tmp_json duplicate_idea_id stable_idea_id

  header="$(head -n 1 "$block_file")"
  if [[ "$header" =~ ^###\ Candidate\ ([0-9]+):[[:space:]]*(.*)$ ]]; then
    candidate_num="${BASH_REMATCH[1]}"
    title="$(ideas_trim "${BASH_REMATCH[2]}")"
    candidate_id="candidate-$candidate_num"
  elif [[ "$header" =~ ^###\ Candidate[^:]*:[[:space:]]*(.*)$ ]]; then
    title="$(ideas_trim "${BASH_REMATCH[1]}")"
    warnings+=("Candidate $rank is missing candidate identity")
  else
    title=""
    warnings+=("Candidate $rank is missing candidate identity")
  fi

  source_candidate="${candidate_id:-missing-candidate-$rank}"
  [[ -n "${title:-}" ]] || warnings+=("Candidate $rank is missing a title")

  duplicate_raw="$(ideas_trim "$(ideas_extract_field_value "$block_file" "Duplicate")")"
  duplicate_raw="$(printf '%s' "$duplicate_raw" | tr '[:upper:]' '[:lower:]')"
  case "$duplicate_raw" in
    yes) duplicate_value=true ;;
    no) duplicate_value=false ;;
    *)
      duplicate_value=null
      warnings+=("Candidate $rank is missing a Duplicate status")
      ;;
  esac

  summary="$(ideas_trim "$(ideas_extract_field_value "$block_file" "Description")")"
  if [[ -z "$summary" ]]; then
    summary="$(ideas_trim "$(ideas_extract_field_value "$block_file" "Summary")")"
  fi
  [[ -n "$summary" ]] || warnings+=("Candidate $rank is missing a description/summary")

  dedup_rationale="$(ideas_trim "$(ideas_extract_field_value "$block_file" "Dedup rationale")")"
  category="$(ideas_trim "$(ideas_extract_field_value "$block_file" "Category")")"
  analogy="$(ideas_trim "$(ideas_extract_field_value "$block_file" "Analogy")")"
  attraction="$(ideas_trim "$(ideas_extract_field_value "$block_file" "Attraction (1-5)")")"
  retention="$(ideas_trim "$(ideas_extract_field_value "$block_file" "Retention (1-5)")")"
  effort="$(ideas_trim "$(ideas_extract_field_value "$block_file" "Effort")")"
  revenue="$(ideas_trim "$(ideas_extract_field_value "$block_file" "Revenue (1-5|n/a)")")"
  if [[ -z "$revenue" ]]; then
    revenue="$(ideas_trim "$(ideas_extract_field_value "$block_file" "Revenue (1-5)")")"
  fi
  ensemble="$(ideas_trim "$(ideas_extract_field_value "$block_file" "Ensemble (0-100)")")"

  if [[ "$kind" == "fleet" ]]; then
    repos_field="$(ideas_trim "$(ideas_extract_field_value "$block_file" "Repos")")"
    if [[ -n "$repos_field" ]]; then
      while IFS= read -r repo_name; do
        repo_name="$(ideas_trim "$repo_name")"
        [[ -n "$repo_name" ]] || continue
        raw_repos+=("$repo_name")
        local matches_count
        matches_count="$(jq -r --arg name "$repo_name" '.[$name] | if . == null then 0 else length end' <<<"$fleet_repo_map_json")"
        if [[ "$matches_count" == "1" ]]; then
          resolved_repos+=("$(jq -r --arg name "$repo_name" '.[$name][0]' <<<"$fleet_repo_map_json")")
        else
          warnings+=("Candidate $rank references unresolved fleet repo '$repo_name'")
        fi
      done < <(tr ',' '\n' <<<"$repos_field")
    else
      warnings+=("Candidate $rank is missing a Repos field")
    fi
    if (( ${#resolved_repos[@]} < 2 )); then
      warnings+=("Candidate $rank requires at least two resolvable fleet repositories")
    fi
  fi

  if (( ${#warnings[@]} > 0 )); then
    approvable=false
    eligibility_reason="${warnings[0]}"
  fi

  warn_json="$(ideas_json_string_array "${warnings[@]+"${warnings[@]}"}")"
  if [[ "$kind" == "fleet" ]]; then
    repos_json="$(ideas_json_string_array "${resolved_repos[@]+"${resolved_repos[@]}"}")"
  else
    repos_json='[]'
  fi

  tmp_json="$(mktemp "${TMPDIR:-/tmp}/e3d-materialized-candidate.XXXXXX")"
  jq -ncS \
    --argjson rank "$rank" \
    --arg source_candidate "$source_candidate" \
    --arg focus "$focus" \
    --arg title "${title:-}" \
    --arg summary "${summary:-}" \
    --arg dedup_rationale "${dedup_rationale:-}" \
    --arg category "${category:-}" \
    --arg analogy "${analogy:-}" \
    --arg effort "${effort:-}" \
    --arg attraction "${attraction:-}" \
    --arg retention "${retention:-}" \
    --arg revenue "${revenue:-}" \
    --arg ensemble "${ensemble:-}" \
    --argjson duplicate "$duplicate_value" \
    --argjson selected_by_model "$( [[ -n "$candidate_id" && "$candidate_id" == "$selected" ]] && printf 'true' || printf 'false' )" \
    --argjson repos "$repos_json" \
    --argjson artifacts "$artifacts_json" \
    --argjson warnings "$warn_json" \
    --arg approvable "$approvable" \
    --arg eligibility_reason "$eligibility_reason" \
    --argjson raw_repos "$(ideas_json_string_array "${raw_repos[@]+"${raw_repos[@]}"}")" \
    '{
      rank: $rank,
      selected_by_model: $selected_by_model,
      focus: ($focus | select(length > 0)),
      title: (if $title == "" then null else $title end),
      summary: (if $summary == "" then null else $summary end),
      repos: $repos,
      scores: {
        attraction: (if $attraction == "" then null else ($attraction | tonumber? // $attraction) end),
        retention: (if $retention == "" then null else ($retention | tonumber? // $retention) end),
        revenue: (if $revenue == "" then null else (if ($revenue | ascii_downcase) == "n/a" then "n/a" else ($revenue | tonumber? // $revenue) end) end),
        effort: (if $effort == "" then null else $effort end),
        ensemble: (if $ensemble == "" then null else ($ensemble | tonumber? // $ensemble) end)
      },
      category: (if $category == "" then null else $category end),
      analogy: (if $analogy == "" then null else $analogy end),
      dedup_rationale: (if $dedup_rationale == "" then null else $dedup_rationale end),
      provenance: {
        source_candidate: $source_candidate,
        duplicate: $duplicate,
        raw_repos: (if ($raw_repos | length) == 0 then null else $raw_repos end)
      },
      content_digests: {
        source_artifacts: $artifacts
      },
      validation: {
        approvable: ($approvable == "true"),
        eligibility_reason: (if $eligibility_reason == "" then null else $eligibility_reason end),
        warnings: $warnings
      }
    }' > "$tmp_json"

  stable_idea_id="$(ideas_stable_id "$kind" "$(ideas_canonical_path "$workspace")" "$source_run_id" "$source_candidate")"
  if [[ "$duplicate_value" == "true" ]]; then
    rm -f "$tmp_json"
    return 11
  fi
  if [[ "$duplicate_value" != "true" ]]; then
    if duplicate_idea_id="$(ideas_find_duplicate_by_digest "$kind" "$workspace" "$tmp_json" "$stable_idea_id" 2>/dev/null)"; then
      rm -f "$tmp_json"
      return 10
    fi
  fi

  printf '%s\n' "$tmp_json"
}

ideas_materialize_candidates_from_markdown() {
  local kind="$1" workspace="$2" source_run_id="$3" candidates_file="$4" focus="$5" artifacts_json="$6" fleet_repo_map_json="${7:-}"
  local selected block_dir block_count rank block_file candidate_json idea_id source_candidate
  local -a materialized_ids=()

  selected="$(candidates_selected_field "$candidates_file" || true)"
  local model_selected
  model_selected="$(awk -F': ' '/^model_selected: / { print $2; exit }' "$candidates_file" || true)"
  [[ -n "$model_selected" ]] || model_selected="$selected"
  block_dir="$(mktemp -d "${TMPDIR:-/tmp}/e3d-candidate-blocks.XXXXXX")"
  block_count="$(ideas_parse_candidate_blocks "$candidates_file" "$block_dir")"

  if [[ -f "$(ideas_events_file "$kind" "$(ideas_canonical_path "$workspace")")" ]]; then
    ideas_rebuild "$kind" "$workspace" >/dev/null 2>&1 || true
  fi

  for ((rank=1; rank<=block_count; rank++)); do
    block_file="$block_dir/candidate-$rank.md"
    [[ -f "$block_file" ]] || continue
    candidate_json=""
    if ! candidate_json="$(ideas_materialize_candidate_record "$kind" "$workspace" "$source_run_id" "$model_selected" "$focus" "$block_file" "$rank" "$artifacts_json" "$fleet_repo_map_json")"; then
      continue
    fi
    source_candidate="$(jq -r '.provenance.source_candidate' "$candidate_json")"
    idea_id="$(ideas_ingest_candidate "$kind" "$workspace" "$source_run_id" "$source_candidate" "$candidate_json")"
    project_tracking_sync_idea "$kind" "$workspace" "$idea_id"
    materialized_ids+=("$idea_id")
    rm -f "$candidate_json"
  done

  rm -rf "$block_dir"
  if (( ${#materialized_ids[@]} > 0 )); then
    printf '%s\n' "${materialized_ids[@]}"
  fi
}

materialize_single_repo_ideas() {
  local repo="$1" run_dir="$2" run_id="$3" focus="$4"
  local workspace artifacts_json
  workspace="$(ideas_canonical_path "$repo")" || return 1
  artifacts_json="$(ideas_artifact_digest_json "$workspace" \
    "$run_dir/findings.md" \
    "$run_dir/candidates.md" \
    "$run_dir/discover-prompt.md" \
    "$run_dir/discover-external-context.md" \
    "$run_dir/ideate-prompt.md" \
    "$run_dir/ideate-response.md" \
    "$run_dir/ideate-scoring.json" \
    "$run_dir/ideate-response.model.md")"
  ideas_materialize_candidates_from_markdown repo "$workspace" "$run_id" "$run_dir/candidates.md" "$focus" "$artifacts_json"
}

materialize_fleet_ideas() {
  local fleet_workspace="$1" fleet_file="$2" run_dir="$3" run_id="$4" focus="$5"
  local workspace artifacts_json repo_map_json
  workspace="$(ideas_canonical_path "$fleet_workspace")" || return 1
  repo_map_json="$(ideas_fleet_repo_map_json "$fleet_file")" || return 1
  artifacts_json="$(ideas_artifact_digest_json "$workspace" \
    "$run_dir/findings.md" \
    "$run_dir/candidates.md" \
    "$run_dir/fleet-discover-prompt.md" \
    "$run_dir/fleet-discover-response.md" \
    "$run_dir/fleet-ideate-prompt.md" \
    "$run_dir/fleet-ideate-response.md" \
    "$run_dir/fleet-ideate-scoring.json" \
    "$run_dir/fleet-ideate-response.model.md")"
  ideas_materialize_candidates_from_markdown fleet "$workspace" "$run_id" "$run_dir/candidates.md" "$focus" "$artifacts_json" "$repo_map_json"
}
