#!/usr/bin/env bash

TRAINING_SCHEMA_VERSION=1

training_sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

training_sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

training_iso_week_now() {
  date -u '+%G-W%V'
}

training_week_cutoff() {
  local week="$1"
  python3 - "$week" <<'PY'
import datetime
import sys

week = sys.argv[1]
try:
    year_s, week_s = week.split("-W", 1)
    start = datetime.date.fromisocalendar(int(year_s), int(week_s), 1)
except Exception:
    raise SystemExit(2)
cutoff = datetime.datetime.combine(start + datetime.timedelta(days=7), datetime.time(), datetime.timezone.utc)
print(cutoff.strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

training_fleet_workspace() {
  local fleet_file="$1"
  [[ -f "$fleet_file" ]] || return 1
  (cd "$(dirname "$fleet_file")" && pwd -P)
}

training_fleet_repos_json() {
  local fleet_file="$1"
  jq -cS '
    if type == "array" then .
    elif type == "object" and (.repos | type == "array") then .repos
    else error("fleet file must be a JSON array of repo path strings or an object with repos")
    end
    | if all(.[]; type == "string") then . else error("fleet repos must be strings") end
  ' "$fleet_file"
}

training_config_json() {
  local fleet_file="$1"
  jq -cS '
    {
      min_reviewed_ideas: (.training.min_reviewed_ideas // 30),
      min_implemented_ideas: (.training.min_implemented_ideas // 10),
      require_negative_examples: (.training.require_negative_examples // true),
      outcome_windows: (.training.outcome_windows // ["7d","30d"])
    }
    | if (.min_reviewed_ideas | type) != "number" or (.min_reviewed_ideas < 0) then error("training.min_reviewed_ideas must be a non-negative number") else . end
    | if (.min_implemented_ideas | type) != "number" or (.min_implemented_ideas < 0) then error("training.min_implemented_ideas must be a non-negative number") else . end
    | if (.require_negative_examples | type) != "boolean" then error("training.require_negative_examples must be boolean") else . end
    | if (.outcome_windows | type) != "array" or (all(.outcome_windows[]; type == "string") | not) then error("training.outcome_windows must be an array of strings") else . end
  ' "$fleet_file"
}

training_previous_success_cutoff() {
  local workspace="$1" best=""
  [[ -d "$workspace/datasets" ]] || return 0
  while IFS= read -r manifest; do
    [[ -f "$manifest" ]] || continue
    local cutoff completed
    completed="$(jq -r '.completed // false' "$manifest" 2>/dev/null || true)"
    [[ "$completed" == "true" ]] || continue
    cutoff="$(jq -r '.cutoff // empty' "$manifest" 2>/dev/null || true)"
    [[ -n "$cutoff" ]] || continue
    if [[ -z "$best" || "$cutoff" > "$best" ]]; then
      best="$cutoff"
    fi
  done < <(find "$workspace/datasets" -mindepth 2 -maxdepth 2 -name manifest.json 2>/dev/null | sort)
  printf '%s' "$best"
}

training_collect_sources() {
  local fleet_file="$1" workspace="$2" out_file="$3" repos_json repo canonical events digest
  : > "$out_file"
  events="$(ideas_events_file fleet "$workspace")" || return 1
  if [[ -f "$events" ]]; then
    ideas_validate_stream "$events" || return 1
    digest="$(training_sha256_file "$events")"
    jq -ncS --arg kind fleet --arg workspace "$workspace" --arg events "$events" --arg digest "$digest" \
      '{kind:$kind,workspace:$workspace,events_file:$events,digest:$digest}' >> "$out_file"
  fi
  repos_json="$(training_fleet_repos_json "$fleet_file")" || return 1
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    canonical="$(ideas_canonical_path "$repo")" || return 1
    events="$(ideas_events_file repo "$canonical")" || return 1
    [[ -f "$events" ]] || continue
    ideas_validate_stream "$events" || return 1
    digest="$(training_sha256_file "$events")"
    jq -ncS --arg kind repo --arg workspace "$canonical" --arg events "$events" --arg digest "$digest" \
      '{kind:$kind,workspace:$workspace,events_file:$events,digest:$digest}' >> "$out_file"
  done < <(jq -r '.[]' <<<"$repos_json")
}

training_replay_sources() {
  local sources_file="$1" out_dir="$2" source_json kind workspace events label snap_dir
  mkdir -p "$out_dir"
  while IFS= read -r source_json || [[ -n "$source_json" ]]; do
    [[ -n "$source_json" ]] || continue
    kind="$(jq -r '.kind' <<<"$source_json")"
    workspace="$(jq -r '.workspace' <<<"$source_json")"
    events="$(jq -r '.events_file' <<<"$source_json")"
    label="$(printf '%s:%s' "$kind" "$workspace" | training_sha256_text | cut -c1-16)"
    snap_dir="$out_dir/$label"
    mkdir -p "$snap_dir"
    ideas_replay_events "$events" "$snap_dir/ideas" || return 1
    jq -cS --arg label "$label" '. + {snapshot_label:$label}' <<<"$source_json" > "$snap_dir/source.json"
  done < "$sources_file"
}

training_aggregate_events() {
  local sources_file="$1" out_file="$2" source_json events
  : > "$out_file"
  while IFS= read -r source_json || [[ -n "$source_json" ]]; do
    [[ -n "$source_json" ]] || continue
    events="$(jq -r '.events_file' <<<"$source_json")"
    [[ -f "$events" ]] && cat "$events" >> "$out_file"
  done < "$sources_file"
  jq -R -s -e '
    split("\n") | map(select(length > 0) | fromjson) as $events
    | ($events | group_by(.event_id) | all(. as $g | ($g | map(tojson) | unique | length) == 1))
    and ($events | group_by(.idea_id) | all(. as $g |
      (($g | map(select(.event == "idea_proposed") | .candidate | tojson) | unique | length) <= 1)
    ))
  ' "$out_file" >/dev/null || {
    printf 'error: conflicting records found while aggregating training ledgers\n' >&2
    return 1
  }
  jq -R -s -cS '
    split("\n") | map(select(length > 0) | fromjson)
    | unique_by(.event_id)
    | sort_by(.timestamp, .event_id)
    | .[]
  ' "$out_file" > "$out_file.tmp.$$"
  mv "$out_file.tmp.$$" "$out_file"
}

training_collect_states() {
  local replay_dir="$1" out_file="$2" file
  : > "$out_file"
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    jq -cS . "$file" >> "$out_file"
  done < <(find "$replay_dir" -path '*/ideas/*/idea.json' -type f 2>/dev/null | sort)
  jq -R -s -e '
    split("\n") | map(select(length > 0) | fromjson)
    | group_by(.idea_id)
    | all(. as $g | ($g | map(tojson) | unique | length) == 1)
  ' "$out_file" >/dev/null || {
    printf 'error: conflicting idea records found while aggregating training ledgers\n' >&2
    return 1
  }
  jq -R -s -cS '
    split("\n") | map(select(length > 0) | fromjson)
    | unique_by(.idea_id)
    | sort_by(.idea_id)
    | .[]
  ' "$out_file" > "$out_file.tmp.$$"
  mv "$out_file.tmp.$$" "$out_file"
}

training_readiness_json() {
  local events_file="$1" states_file="$2" config_json="$3" since="$4" cutoff="${5:-}"
  jq -n -cS \
    --slurpfile events "$events_file" \
    --slurpfile states "$states_file" \
    --argjson cfg "$config_json" \
    --arg since "$since" \
    --arg cutoff "$cutoff" '
    def in_window:
      (($since == "") or (.timestamp > $since))
      and (($cutoff == "") or (.timestamp <= $cutoff));
    ($events | map(select(in_window))) as $e
    | {
        since: (if $since == "" then null else $since end),
        cutoff: (if $cutoff == "" then null else $cutoff end),
        counts: {
          proposed: ($e | map(select(.event == "idea_proposed")) | length),
          reviewed: ($e | map(select(.event == "implementation_approved" or .event == "idea_rejected" or .event == "changes_requested")) | map(.idea_id) | unique | length),
          approved: ($e | map(select(.event == "implementation_approved")) | map(.idea_id) | unique | length),
          rejected: ($e | map(select(.event == "idea_rejected")) | map(.idea_id) | unique | length),
          implementation_successes: ($e | map(select(.event == "implementation_completed")) | length),
          implementation_failures: ($e | map(select(.event == "implementation_failed")) | length),
          merge_approvals: ($e | map(select(.event == "merge_approved")) | length),
          merged: ($e | map(select(.event == "merge_completed" or .event == "merge_observed_external")) | length),
          partially_merged: ($e | map(select(.event == "merge_partially_completed")) | length),
          closed: ($e | map(select(.event == "idea_closed")) | length),
          reverted: ($e | map(select(.event == "idea_reverted")) | length),
          outcomes_7d: ($e | map(select(.event == "outcome_recorded" and .outcome.window == "7d")) | map(.idea_id) | unique | length),
          outcomes_30d: ($e | map(select(.event == "outcome_recorded" and .outcome.window == "30d")) | map(.idea_id) | unique | length)
        }
      } as $r
    | [
        (if $r.counts.reviewed < $cfg.min_reviewed_ideas then "min_reviewed_ideas " + ($r.counts.reviewed|tostring) + "/" + ($cfg.min_reviewed_ideas|tostring) else empty end),
        (if $r.counts.implementation_successes < $cfg.min_implemented_ideas then "min_implemented_ideas " + ($r.counts.implementation_successes|tostring) + "/" + ($cfg.min_implemented_ideas|tostring) else empty end),
        (if $cfg.require_negative_examples and (($r.counts.rejected + $r.counts.implementation_failures + $r.counts.reverted + $r.counts.closed) == 0) then "negative_examples required" else empty end),
        ($cfg.outcome_windows[] as $w | if ($w == "7d" and $r.counts.outcomes_7d == 0) then "outcome_window 7d missing" elif ($w == "30d" and $r.counts.outcomes_30d == 0) then "outcome_window 30d missing" else empty end)
      ] as $unmet
    | $r + {ready: ($unmet | length == 0), unmet_thresholds: $unmet, training_config: $cfg}
  '
}

training_split_expr='
  def hexval($c): ({a:10,b:11,c:12,d:13,e:14,f:15}[$c] // ($c | tonumber));
  def hbyte($id): ($id | gsub("[^0-9a-f]";"") | .[0:2] | explode | map([.] | implode)) as $h | ((hexval($h[0]) * 16) + hexval($h[1]));
  def latest_eval_window($cfg): ($cfg.outcome_windows[-1] // "30d");
  def split_for($idea; $cfg):
    if any($idea.outcomes[]?; .type == "metrics" and .window == latest_eval_window($cfg)) then "evaluation"
    elif ((hbyte($idea.idea_id) % 5) == 0) then "validation"
    else "training"
    end;
'

training_redact_expr='
  def redact_string:
    gsub("-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----"; "[REDACTED]")
    | gsub("sk-[A-Za-z0-9_-]{16,}"; "[REDACTED]")
    | gsub("(?i)(api[_-]?key|token|secret|password|authorization)([\"'\'' ]*[:=][\"'\'' ]*)[^\"'\''\\s,}]+"; "\\1\\2[REDACTED]");
  def redact:
    if type == "string" then redact_string
    elif type == "array" then map(redact)
    elif type == "object" then with_entries(.value |= redact)
    else .
    end;
'

training_secret_count_file() {
  local file="$1"
  perl -0777 -ne '
    my $n = 0;
    $n += () = /-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/sg;
    $n += () = /sk-[A-Za-z0-9_-]{16,}/g;
    $n += () = /(?:api[_-]?key|token|secret|password|authorization)["'"'"' ]*[:=]["'"'"' ]*[^"'"'"'\s,}]+/ig;
    print "$n\n";
  ' "$file"
}

training_write_ideation_jsonl() {
  local states_file="$1" events_file="$2" config_json="$3" cutoff="$4" out_file="$5"
  jq -cS \
    --slurpfile events "$events_file" \
    --argjson cfg "$config_json" \
    --arg cutoff "$cutoff" \
    "$training_split_expr $training_redact_expr
    . as \$idea
    | [\$events[] | select(.idea_id == \$idea.idea_id)] as \$ev
    | (\$ev | map(select(.event == \"implementation_approved\")) | sort_by(.timestamp) | .[-1]) as \$approval
    | (\$ev | map(select(.event == \"idea_rejected\")) | sort_by(.timestamp) | .[-1]) as \$rejection
    | {
        schema_version:\"e3d-qwen-ideation-v1\",
        record_id:(\"ideation:\" + \$idea.idea_id),
        idea_id:\$idea.idea_id,
        split:split_for(\$idea; \$cfg),
        source:{
          workspace_kind:\$idea.workspace_kind,
          workspace_path:\$idea.workspace_path,
          run_id:\$idea.source_run_id,
          candidate_id:\$idea.source_candidate,
          provenance:(\$idea.provenance // null),
          content_digests:(\$idea.content_digests // {})
        },
        candidate:{
          focus:(\$idea.focus // null),
          title:(\$idea.title // null),
          summary:(\$idea.summary // null),
          repos:(\$idea.repos // []),
          scores:(\$idea.scores // {}),
          category:(\$idea.category // null),
          analogy:(\$idea.analogy // null),
          dedup_rationale:(\$idea.dedup_rationale // null),
          validation:(\$idea.validation // {})
        },
        model_selection:{rank:(\$idea.rank // null), selected_by_model:(\$idea.selected_by_model // false)},
        label:(if \$rejection != null then {decision:\"rejected\",reason:(\$rejection.note // null),actor:\$rejection.actor,timestamp:\$rejection.timestamp}
          elif \$approval != null then {decision:\"approved\",reason:(\$approval.note // null),actor:\$approval.actor,timestamp:\$approval.timestamp}
          else {decision:null} end),
        cutoff:\$cutoff
      } | redact" "$states_file" > "$out_file"
}

training_write_preferences_jsonl() {
  local states_file="$1" events_file="$2" config_json="$3" cutoff="$4" out_file="$5"
  jq -n -cS \
    --slurpfile ideas "$states_file" \
    --slurpfile events "$events_file" \
    --argjson cfg "$config_json" \
    --arg cutoff "$cutoff" \
    "$training_split_expr $training_redact_expr
    def comparable_key(\$i): [\$i.workspace_kind, \$i.workspace_path, \$i.source_run_id] | join(\"|\");
    def decision(\$i):
      [\$events[] | select(.idea_id == \$i.idea_id and (.event == \"implementation_approved\" or .event == \"idea_rejected\" or .event == \"changes_requested\"))] | sort_by(.timestamp) | .[-1];
    [\$ideas[] | . + {decision_event: decision(.)}] as \$all
    | [\$all[] | select(.decision_event.event == \"implementation_approved\")] as \$approved
    | [\$all[] | select(.decision_event.event == \"idea_rejected\" or .decision_event.event == \"changes_requested\")] as \$negative
    | [\$approved[] as \$a | \$negative[] as \$n
      | select(comparable_key(\$a) == comparable_key(\$n))
      | {
          schema_version:\"e3d-qwen-preference-v1\",
          record_id:(\"preference:\" + \$a.idea_id + \":\" + \$n.idea_id),
          idea_id:\$a.idea_id,
          compared_idea_id:\$n.idea_id,
          split:split_for(\$a; \$cfg),
          comparable_context:{workspace_kind:\$a.workspace_kind, source_run_id:\$a.source_run_id},
          chosen:{idea_id:\$a.idea_id,title:\$a.title,summary:\$a.summary,decision:\"approved\",reason:(\$a.decision_event.note // null)},
          rejected:{idea_id:\$n.idea_id,title:\$n.title,summary:\$n.summary,decision:(if \$n.decision_event.event == \"changes_requested\" then \"changes_requested\" else \"rejected\" end),reason:(\$n.decision_event.note // null)},
          cutoff:\$cutoff
        } | redact]
    | sort_by(.record_id)[]
    " > "$out_file"
}

training_write_implementation_jsonl() {
  local states_file="$1" events_file="$2" config_json="$3" cutoff="$4" out_file="$5"
  jq -cS \
    --argjson cfg "$config_json" \
    --arg cutoff "$cutoff" \
    "$training_split_expr $training_redact_expr
    select((.implementation_approval // null) != null or any(.outcomes[]?; .type == \"implementation\"))
    | {
        schema_version:\"e3d-qwen-implementation-v1\",
        record_id:(\"implementation:\" + .idea_id),
        idea_id:.idea_id,
        split:split_for(.; \$cfg),
        approved_idea:{
          title:(.title // null),
          summary:(.summary // null),
          repos:(.repos // []),
          scores:(.scores // {}),
          approval:(.implementation_approval // null),
          target_plan:(.implementation.targets // [])
        },
        delivery:{
          implementation:([.outcomes[]? | select(.type == \"implementation\")]),
          merge:([.outcomes[]? | select(.type == \"merge\" or .type == \"merge_external\" or .type == \"closed\" or .type == \"revert\")]),
          forge:(.forge // {}),
          changes_requested_review:(.changes_requested_review // null),
          outcomes:([.outcomes[]? | select(.type == \"metrics\")])
        },
        cutoff:\$cutoff
      } | redact" "$states_file" > "$out_file"
}

training_validate_jsonl() {
  local file="$1" kind="$2"
  [[ -s "$file" ]] || return 0
  jq -R -e --arg kind "$kind" '
    select(length > 0) | fromjson
    | type == "object"
    and (.schema_version | type == "string")
    and (.record_id | type == "string")
    and (.idea_id | type == "string")
    and (.split == "training" or .split == "validation" or .split == "evaluation")
    and (if $kind == "ideation" then ((.label.decision // null) != "rejected" or (.label.reason // null) != null) else true end)
  ' "$file" >/dev/null || return 1
}

training_validate_no_pending_negative() {
  local ideation_file="$1"
  jq -R -s -e '
    split("\n") | map(select(length > 0) | fromjson)
    | all(.[]; ((.label.decision // null) != "rejected") or ((.label.reason // null) != null))
  ' "$ideation_file" >/dev/null
}

training_manifest_json() {
  local fleet_file="$1" sources_file="$2" readiness="$3" out_dir="$4" cutoff="$5" redactions="$6"
  jq -n -cS \
    --argjson schema "$TRAINING_SCHEMA_VERSION" \
    --arg cutoff "$cutoff" \
    --arg fleet_digest "$(training_sha256_file "$fleet_file")" \
    --slurpfile sources "$sources_file" \
    --argjson readiness "$readiness" \
    --argjson redactions "$redactions" \
    --arg ideation_sha "$(training_sha256_file "$out_dir/ideation.jsonl")" \
    --arg preferences_sha "$(training_sha256_file "$out_dir/preferences.jsonl")" \
    --arg implementation_sha "$(training_sha256_file "$out_dir/implementation.jsonl")" \
    '{
      completed:true,
      schema_versions:{
        manifest:$schema,
        ideation:"e3d-qwen-ideation-v1",
        preferences:"e3d-qwen-preference-v1",
        implementation:"e3d-qwen-implementation-v1"
      },
      cutoff:$cutoff,
      fleet_file_digest:$fleet_digest,
      source_event_streams:$sources,
      record_counts:{},
      filters:{
        excludes:["provider credentials","environment dumps",".env files","auth configs","protected-path contents"],
        source_artifact_mode:"bounded excerpts plus digests"
      },
      redactions:{secret_replacements:$redactions},
      files:{
        "ideation.jsonl":{sha256:$ideation_sha},
        "preferences.jsonl":{sha256:$preferences_sha},
        "implementation.jsonl":{sha256:$implementation_sha}
      },
      readiness:$readiness
    }'
}

training_record_counts_json() {
  local out_dir="$1"
  jq -n -cS \
    --argjson ideation "$(wc -l < "$out_dir/ideation.jsonl" | tr -d ' ')" \
    --argjson preferences "$(wc -l < "$out_dir/preferences.jsonl" | tr -d ' ')" \
    --argjson implementation "$(wc -l < "$out_dir/implementation.jsonl" | tr -d ' ')" \
    --argjson training "$(jq -R -s '[split("\n")[] | select(length>0) | fromjson | select(.split=="training")] | length' "$out_dir/ideation.jsonl" "$out_dir/preferences.jsonl" "$out_dir/implementation.jsonl" 2>/dev/null || printf 0)" \
    '{ideation:$ideation,preferences:$preferences,implementation:$implementation}'
}

training_add_manifest_counts() {
  local manifest_file="$1" out_dir="$2" counts split_counts tmp
  counts="$(training_record_counts_json "$out_dir")"
  split_counts="$(jq -n -cS \
    --slurpfile i "$out_dir/ideation.jsonl" \
    --slurpfile p "$out_dir/preferences.jsonl" \
    --slurpfile m "$out_dir/implementation.jsonl" '
    [$i[], $p[], $m[]] as $r
    | {
        training:($r | map(select(.split=="training")) | length),
        validation:($r | map(select(.split=="validation")) | length),
        evaluation:($r | map(select(.split=="evaluation")) | length)
      }')"
  tmp="$manifest_file.tmp.$$"
  jq -cS --argjson counts "$counts" --argjson splits "$split_counts" '.record_counts=$counts | .split_counts=$splits' "$manifest_file" > "$tmp"
  mv "$tmp" "$manifest_file"
}

training_run_readiness() {
  local fleet_file="$1" since="${2:-}" workspace tmp sources events states replay config readiness
  workspace="$(training_fleet_workspace "$fleet_file")" || return 1
  [[ -n "$since" ]] || since="$(training_previous_success_cutoff "$workspace")"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/e3d-training-readiness.XXXXXX")"
  sources="$tmp/sources.jsonl"; events="$tmp/events.jsonl"; states="$tmp/states.jsonl"; replay="$tmp/replay"
  config="$(training_config_json "$fleet_file")" || { rm -rf "$tmp"; return 1; }
  training_collect_sources "$fleet_file" "$workspace" "$sources" || { rm -rf "$tmp"; return 1; }
  training_replay_sources "$sources" "$replay" || { rm -rf "$tmp"; return 1; }
  training_aggregate_events "$sources" "$events" || { rm -rf "$tmp"; return 1; }
  training_collect_states "$replay" "$states" || { rm -rf "$tmp"; return 1; }
  readiness="$(training_readiness_json "$events" "$states" "$config" "$since")" || { rm -rf "$tmp"; return 1; }
  printf '%s\n' "$readiness"
  rm -rf "$tmp"
}

training_run_export() {
  local fleet_file="$1" week="$2" output_dir="$3" workspace cutoff default_dest dest parent base tmp sources events states replay config since readiness
  workspace="$(training_fleet_workspace "$fleet_file")" || return 1
  [[ -n "$week" ]] || week="$(training_iso_week_now)"
  cutoff="$(training_week_cutoff "$week")" || { printf 'error: invalid --week value: %s\n' "$week" >&2; return 1; }
  default_dest="$workspace/datasets/$week"
  if [[ -n "$output_dir" ]]; then
    dest="$output_dir"
  else
    dest="$default_dest"
  fi
  if [[ "$dest" == "$default_dest" && -f "$dest/manifest.json" ]]; then
    printf 'error: dataset already exists: %s\n' "$dest" >&2
    return 1
  fi
  parent="$(dirname "$dest")"
  base="$(basename "$dest")"
  mkdir -p "$parent"
  tmp="$parent/.${base}.tmp.$$"
  rm -rf "$tmp"
  mkdir -p "$tmp"

  sources="$tmp/source-event-streams.jsonl"; events="$tmp/all-events.jsonl"; states="$tmp/states.jsonl"; replay="$tmp/replay"
  config="$(training_config_json "$fleet_file")" || { rm -rf "$tmp"; return 1; }
  training_collect_sources "$fleet_file" "$workspace" "$sources" || { rm -rf "$tmp"; return 1; }
  training_replay_sources "$sources" "$replay" || { rm -rf "$tmp"; return 1; }
  training_aggregate_events "$sources" "$events" || { rm -rf "$tmp"; return 1; }
  training_collect_states "$replay" "$states" || { rm -rf "$tmp"; return 1; }
  since="$(training_previous_success_cutoff "$workspace")"
  readiness="$(training_readiness_json "$events" "$states" "$config" "$since" "$cutoff")" || { rm -rf "$tmp"; return 1; }

  training_write_ideation_jsonl "$states" "$events" "$config" "$cutoff" "$tmp/ideation.raw.jsonl"
  training_write_preferences_jsonl "$states" "$events" "$config" "$cutoff" "$tmp/preferences.raw.jsonl"
  training_write_implementation_jsonl "$states" "$events" "$config" "$cutoff" "$tmp/implementation.raw.jsonl"
  local redactions
  redactions=$(( $(training_secret_count_file "$events") + $(training_secret_count_file "$states") ))
  mv "$tmp/ideation.raw.jsonl" "$tmp/ideation.jsonl"
  mv "$tmp/preferences.raw.jsonl" "$tmp/preferences.jsonl"
  mv "$tmp/implementation.raw.jsonl" "$tmp/implementation.jsonl"

  training_validate_jsonl "$tmp/ideation.jsonl" ideation || { rm -rf "$tmp"; return 1; }
  training_validate_jsonl "$tmp/preferences.jsonl" preferences || { rm -rf "$tmp"; return 1; }
  training_validate_jsonl "$tmp/implementation.jsonl" implementation || { rm -rf "$tmp"; return 1; }
  training_validate_no_pending_negative "$tmp/ideation.jsonl" || { rm -rf "$tmp"; return 1; }
  if grep -R -E 'sk-[A-Za-z0-9_-]{16,}|-----BEGIN [A-Z ]*PRIVATE KEY-----' "$tmp"/ideation.jsonl "$tmp"/preferences.jsonl "$tmp"/implementation.jsonl >/dev/null 2>&1; then
    printf 'error: training export validation found unredacted secret material\n' >&2
    rm -rf "$tmp"
    return 1
  fi

  training_manifest_json "$fleet_file" "$sources" "$readiness" "$tmp" "$cutoff" "$redactions" > "$tmp/manifest.json"
  training_add_manifest_counts "$tmp/manifest.json" "$tmp"
  rm -rf "$replay" "$events" "$states" "$sources"
  if [[ -e "$dest" ]]; then
    rm -rf "$tmp"
    printf 'error: output directory already exists: %s\n' "$dest" >&2
    return 1
  fi
  mv "$tmp" "$dest"
  printf 'fleet train: exported %s ready=%s\n' "$dest" "$(jq -r '.readiness.ready' "$dest/manifest.json")"
}
