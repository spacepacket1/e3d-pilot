#!/usr/bin/env bash

IDEA_SCHEMA_VERSION=1

ideas_die() {
  printf 'error: %s\n' "$*" >&2
  return 1
}

ideas_utc_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

ideas_canonical_path() {
  local path="$1"
  [[ -d "$path" ]] || { ideas_die "workspace not found: $path"; return 1; }
  (cd "$path" && pwd -P)
}

ideas_workspace_dir() {
  local kind="$1" workspace="$2"
  case "$kind" in
    repo) printf '%s/.e3d-pilot' "$workspace" ;;
    fleet) printf '%s/.e3d-pilot-fleet' "$workspace" ;;
    *) ideas_die "invalid workspace kind: $kind"; return 1 ;;
  esac
}

ideas_events_file() {
  local kind="$1" workspace="$2" root
  root="$(ideas_workspace_dir "$kind" "$workspace")" || return 1
  printf '%s/events.jsonl' "$root"
}

ideas_snapshots_dir() {
  local kind="$1" workspace="$2" root
  root="$(ideas_workspace_dir "$kind" "$workspace")" || return 1
  printf '%s/ideas' "$root"
}

ideas_lock_dir() {
  local kind="$1" workspace="$2" root
  root="$(ideas_workspace_dir "$kind" "$workspace")" || return 1
  printf '%s/ideas.lock' "$root"
}

ideas_acquire_lock() {
  local kind="$1" workspace="$2" lock now pid started
  lock="$(ideas_lock_dir "$kind" "$workspace")" || return 1
  mkdir -p "$(dirname "$lock")"
  started="$(date +%s)"
  while ! mkdir "$lock" 2>/dev/null; do
    if [[ -f "$lock/pid" ]]; then
      pid="$(cat "$lock/pid" 2>/dev/null || true)"
      if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
        rm -rf "$lock"
        continue
      fi
    fi
    now="$(date +%s)"
    if (( now - started > 30 )); then
      ideas_die "timed out waiting for idea ledger lock: $lock"
      return 1
    fi
    sleep 0.05
  done
  printf '%s\n' "$$" > "$lock/pid"
}

ideas_release_lock() {
  local kind="$1" workspace="$2" lock
  lock="$(ideas_lock_dir "$kind" "$workspace")" || return 0
  rm -rf "$lock"
}

ideas_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

ideas_stable_id() {
  local kind="$1" workspace="$2" source_run_id="$3" candidate_id="$4"
  jq -ncS \
    --arg workspace_kind "$kind" \
    --arg workspace_path "$workspace" \
    --arg source_run_id "$source_run_id" \
    --arg candidate_identifier "$candidate_id" \
    '{workspace_kind:$workspace_kind,workspace_path:$workspace_path,source_run_id:$source_run_id,candidate_identifier:$candidate_identifier}' \
    | ideas_sha256 | cut -c1-12 | sed 's/^/idea-/'
}

ideas_event_id() {
  {
    ideas_utc_now
    printf '%s\n' "$$"
    printf '%s\n' "$RANDOM$RANDOM$RANDOM"
    printf '%s\n' "${1:-}"
  } | ideas_sha256 | cut -c1-24 | sed 's/^/evt-/'
}

ideas_decision_digest_from_json() {
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
    implementation_target_plan: (.implementation.targets // [])
  }' "$file" | ideas_sha256
}

# Same digest formula, but computed as if .implementation.targets were first
# replaced by targets_override (a JSON array file) -- used when an approval
# event binds a freshly-computed target plan (fleet base SHAs/branches) that
# doesn't exist on the snapshot yet. Passing "" behaves exactly like
# ideas_decision_digest_from_json.
ideas_decision_digest_effective() {
  local state_file="$1" targets_override="$2" tmp digest
  if [[ -n "$targets_override" ]]; then
    tmp="$(mktemp "${TMPDIR:-/tmp}/e3d-idea-digest-src.XXXXXX")"
    jq -cS --slurpfile t "$targets_override" '.implementation.targets = $t[0]' "$state_file" > "$tmp"
    digest="$(ideas_decision_digest_from_json "$tmp")"
    rm -f "$tmp"
  else
    digest="$(ideas_decision_digest_from_json "$state_file")"
  fi
  printf '%s' "$digest"
}

# Actor resolution order per spec: explicit --actor, then git config
# user.email in the controlling workspace (repo or fleet dir) when available,
# then $USER.
ideas_resolve_actor() {
  local context_dir="$1" explicit="$2" email=""
  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi
  if [[ -n "$context_dir" && -d "$context_dir" ]]; then
    email="$(git -C "$context_dir" config user.email 2>/dev/null || true)"
  fi
  if [[ -n "$email" ]]; then
    printf '%s' "$email"
    return 0
  fi
  printf '%s' "${USER:-unknown}"
}

ideas_allowed_transition() {
  local from="$1" event="$2"
  case "$from:$event" in
    none:idea_proposed) printf 'proposed' ;;
    proposed:implementation_approved) printf 'approved_for_implementation' ;;
    proposed:idea_rejected) printf 'rejected' ;;
    approved_for_implementation:implementation_started) printf 'implementing' ;;
    implementing:implementation_completed) printf 'implemented' ;;
    implementing:implementation_failed) printf 'implementation_failed' ;;
    implemented:merge_approved) printf 'approved_for_merge' ;;
    implemented:changes_requested) printf 'changes_requested' ;;
    implemented:idea_closed) printf 'closed' ;;
    implemented:forge_sync) printf 'implemented' ;;
    implemented:outcome_recorded) printf 'implemented' ;;
    implemented:merge_observed_external) printf 'merged' ;;
    changes_requested:implementation_started) printf 'implementing' ;;
    changes_requested:merge_approved) printf 'approved_for_merge' ;;
    changes_requested:idea_closed) printf 'closed' ;;
    changes_requested:forge_sync) printf 'changes_requested' ;;
    changes_requested:outcome_recorded) printf 'changes_requested' ;;
    changes_requested:merge_observed_external) printf 'merged' ;;
    approved_for_merge:changes_requested) printf 'changes_requested' ;;
    approved_for_merge:idea_closed) printf 'closed' ;;
    approved_for_merge:merge_target_merged) printf 'approved_for_merge' ;;
    approved_for_merge:merge_target_failed) printf 'approved_for_merge' ;;
    approved_for_merge:merge_completed) printf 'merged' ;;
    approved_for_merge:merge_partially_completed) printf 'partially_merged' ;;
    approved_for_merge:merge_failed) printf 'merge_failed' ;;
    approved_for_merge:forge_sync) printf 'approved_for_merge' ;;
    approved_for_merge:merge_observed_external) printf 'merged' ;;
    approved_for_merge:merge_approval_invalidated) printf 'dynamic' ;;
    approved_for_merge:outcome_recorded) printf 'approved_for_merge' ;;
    partially_merged:merge_target_merged) printf 'partially_merged' ;;
    partially_merged:merge_target_failed) printf 'partially_merged' ;;
    partially_merged:merge_completed) printf 'merged' ;;
    partially_merged:merge_failed) printf 'merge_failed' ;;
    partially_merged:idea_closed) printf 'closed' ;;
    partially_merged:forge_sync) printf 'partially_merged' ;;
    partially_merged:merge_observed_external) printf 'merged' ;;
    partially_merged:outcome_recorded) printf 'partially_merged' ;;
    merged:forge_sync) printf 'merged' ;;
    merged:outcome_recorded) printf 'merged' ;;
    merged:idea_reverted) printf 'reverted' ;;
    reverted:outcome_recorded) printf 'reverted' ;;
    closed:outcome_recorded) printf 'closed' ;;
    implementation_failed:implementation_retry_approved) printf 'implementing' ;;
    implementation_failed:outcome_recorded) printf 'implementation_failed' ;;
    merge_failed:merge_retry_approved) printf 'approved_for_merge' ;;
    merge_failed:outcome_recorded) printf 'merge_failed' ;;
    *) return 1 ;;
  esac
}

ideas_default_candidate_json() {
  jq -cS '
    . as $c
    | {
        rank: ($c.rank // null),
        selected_by_model: ($c.selected_by_model // false),
        focus: ($c.focus // null),
        title: ($c.title // null),
        summary: ($c.summary // $c.description // null),
        repos: ($c.repos // []),
        scores: {
          attraction: ($c.scores.attraction // $c.attraction // null),
          retention: ($c.scores.retention // $c.retention // null),
          revenue: ($c.scores.revenue // $c.revenue // null),
          effort: ($c.scores.effort // $c.effort // null)
        },
        category: ($c.category // null),
        analogy: ($c.analogy // null),
        dedup_rationale: ($c.dedup_rationale // null),
        provenance: ($c.provenance // null),
        content_digests: ($c.content_digests // {}),
        validation: ($c.validation // {approvable:true,eligibility_reason:null,warnings:[]}),
        implementation: {targets: ($c.implementation.targets // $c.implementation_targets // [])}
      }'
}

ideas_initial_state_from_event() {
  local event_file="$1"
  jq -cS '
    . as $e
    | $e.candidate as $c
    | {
        schema_version: $e.schema_version,
        idea_id: $e.idea_id,
        workspace_kind: $e.workspace_kind,
        workspace_path: $e.workspace_path,
        source_run_id: $e.source_run_id,
        source_candidate: $e.source_candidate,
        created_at: $e.timestamp,
        updated_at: $e.timestamp,
        status: "proposed",
        rank: ($c.rank // null),
        selected_by_model: ($c.selected_by_model // false),
        focus: ($c.focus // null),
        title: ($c.title // null),
        summary: ($c.summary // null),
        repos: ($c.repos // []),
        scores: {
          attraction: ($c.scores.attraction // null),
          retention: ($c.scores.retention // null),
          revenue: ($c.scores.revenue // null),
          effort: ($c.scores.effort // null)
        },
        category: ($c.category // null),
        analogy: ($c.analogy // null),
        dedup_rationale: ($c.dedup_rationale // null),
        provenance: ($c.provenance // null),
        content_digests: ($c.content_digests // {}),
        validation: ($c.validation // {approvable:true,eligibility_reason:null,warnings:[]}),
        implementation_approval: null,
        implementation: {targets: ($c.implementation.targets // [])},
        merge_approval: null,
        outcomes: [],
        outcomes_latest: {},
        forge: {targets: []},
        changes_requested_review: null,
        tracking: {project_item_id: null, project_kind: null, project_status: null},
        last_decision_actor: null,
        last_decision_at: null,
        last_event_id: $e.event_id
      }' "$event_file"
}

ideas_materialize_next_status() {
  local state_file="$1" event_file="$2"
  local from event next restore_status
  from="$(jq -r '.status // "none"' "$state_file")"
  event="$(jq -r '.event' "$event_file")"
  # project_tracking_synced is pure metadata (which board item an idea is
  # linked to, and what status was last written there) -- it never gates or
  # represents a lifecycle decision, so unlike every other event it is valid
  # as a self-loop from any status, "none" included.
  if [[ "$event" == "project_tracking_synced" ]]; then
    printf '%s' "$from"
    return 0
  fi
  next="$(ideas_allowed_transition "$from" "$event")" || {
    ideas_die "invalid idea lifecycle transition: $from + $event"
    return 1
  }
  if [[ "$next" == "dynamic" ]]; then
    restore_status="$(jq -r '.restore_status // empty' "$event_file")"
    case "$restore_status" in
      implemented|changes_requested) printf '%s' "$restore_status" ;;
      *)
        ideas_die "invalid dynamic restore status for $event: ${restore_status:-<empty>}"
        return 1
        ;;
    esac
    return 0
  fi
  printf '%s' "$next"
}

ideas_apply_event() {
  local state_file="$1" event_file="$2" out_file="$3" from event next
  from="$(jq -r '.status // "none"' "$state_file")"
  event="$(jq -r '.event' "$event_file")"
  next="$(ideas_materialize_next_status "$state_file" "$event_file")" || return 1

  case "$event" in
    implementation_approved|implementation_retry_approved)
      jq -cS --arg status "$next" '
        . as $s | input as $e
        | $s
        | .status=$status
        | .updated_at=$e.timestamp
        | .implementation.targets=($e.targets // .implementation.targets // [])
        | .implementation_approval={
            actor: $e.actor,
            approved_at: $e.timestamp,
            digest: $e.approval_digest,
            note: ($e.note // null),
            event_id: $e.event_id
          }
        | .last_decision_actor=$e.actor
        | .last_decision_at=$e.timestamp
        | .last_event_id=$e.event_id
      ' "$state_file" "$event_file" > "$out_file"
      ;;
    merge_approved|merge_retry_approved)
      jq -cS --arg status "$next" '
        . as $s | input as $e
        | $s
        | .status=$status
        | .updated_at=$e.timestamp
        | .merge_approval={
            actor: $e.actor,
            approved_at: $e.timestamp,
            digest: ($e.approval_digest // null),
            head_sha: ($e.head_sha // null),
            targets: ($e.targets // []),
            source_status: ($e.source_status // .status),
            note: ($e.note // null),
            event_id: $e.event_id
          }
        | .last_decision_actor=$e.actor
        | .last_decision_at=$e.timestamp
        | .last_event_id=$e.event_id
      ' "$state_file" "$event_file" > "$out_file"
      ;;
    implementation_started)
      jq -cS --arg status "$next" '
        . as $s | input as $e
        | $s
        | .status=$status
        | .updated_at=$e.timestamp
        | .implementation.targets=($e.targets // .implementation.targets // [])
        | .last_event_id=$e.event_id
      ' "$state_file" "$event_file" > "$out_file"
      ;;
    idea_rejected)
      jq -cS --arg status "$next" '
        . as $s | input as $e
        | $s
        | .status=$status
        | .updated_at=$e.timestamp
        | if ($e.outcome? != null) then .outcomes += [$e.outcome] else . end
        | .last_decision_actor=$e.actor
        | .last_decision_at=$e.timestamp
        | .last_event_id=$e.event_id
      ' "$state_file" "$event_file" > "$out_file"
      ;;
    changes_requested)
      jq -cS --arg status "$next" '
        def reviewed_targets_from_event($e):
          if ($e.targets? // [] | length) > 0 then
            ($e.targets | map({
              repo: (.repo // null),
              pr_url: (.pr_url // null),
              reviewed_head_sha: (.reviewed_head_sha // .head_sha // null)
            }))
          else
            []
          end;
        . as $s | input as $e
        | $s
        | .status=$status
        | .updated_at=$e.timestamp
        | .merge_approval=null
        | .changes_requested_review={
            actor:$e.actor,
            requested_at:$e.timestamp,
            reason:($e.note // null),
            reviewed_head_sha:($e.head_sha // null),
            targets:reviewed_targets_from_event($e),
            invalidated_merge_approval: (($s.merge_approval // null) != null),
            event_id:$e.event_id
          }
        | if ($e.outcome? != null) then .outcomes += [$e.outcome] else . end
        | .last_decision_actor=$e.actor
        | .last_decision_at=$e.timestamp
        | .last_event_id=$e.event_id
      ' "$state_file" "$event_file" > "$out_file"
      ;;
    idea_closed)
      jq -cS --arg status "$next" '
        . as $s | input as $e
        | $s
        | .status=$status
        | .updated_at=$e.timestamp
        | if ($e.outcome? != null) then .outcomes += [$e.outcome] else . end
        | .last_decision_actor=$e.actor
        | .last_decision_at=$e.timestamp
        | .last_event_id=$e.event_id
      ' "$state_file" "$event_file" > "$out_file"
      ;;
    idea_reverted)
      jq -cS --arg status "$next" '
        . as $s | input as $e
        | $s
        | .status=$status
        | .updated_at=$e.timestamp
        | if ($e.outcome? != null) then .outcomes += [$e.outcome] else . end
        | .last_decision_actor=$e.actor
        | .last_decision_at=$e.timestamp
        | .last_event_id=$e.event_id
      ' "$state_file" "$event_file" > "$out_file"
      ;;
    implementation_completed|implementation_failed|merge_target_merged|merge_target_failed|merge_completed|merge_partially_completed|merge_failed)
      jq -cS --arg status "$next" '
        . as $s | input as $e
        | $s
        | .status=$status
        | .updated_at=$e.timestamp
        | if ($e.outcome? != null) then .outcomes += [$e.outcome] else . end
        | .last_event_id=$e.event_id
      ' "$state_file" "$event_file" > "$out_file"
      ;;
    forge_sync)
      jq -cS --arg status "$next" '
        def forge_key($t): [($t.repo // ""), ($t.pr_url // ""), (($t.pr_number // null) | tostring)] | join("|");
        def upsert_target($targets; $obs):
          ($targets // []) as $existing
          | ([$existing[] | forge_key(.)] | index(forge_key($obs))) as $idx
          | if $idx == null then
              $existing + [$obs]
            else
              ($existing[0:$idx] + [($existing[$idx] + $obs)] + $existing[$idx + 1:])
            end;
        . as $s | input as $e
        | reduce ($e.observations // [])[] as $obs (
            $s
            | .status=$status
            | .updated_at=$e.timestamp;
            .forge.targets = upsert_target(.forge.targets; $obs)
          )
        | .last_event_id=$e.event_id
      ' "$state_file" "$event_file" > "$out_file"
      ;;
    outcome_recorded)
      jq -cS --arg status "$next" '
        def reduce_latest($latest; $metrics):
          reduce ($metrics // [])[] as $metric (
            ($latest // {});
            .[$metric.key] = {
              type: ($metric.type // null),
              value: $metric.value,
              window: ($metric.window // null),
              observed_at: ($metric.observed_at // null),
              note: ($metric.note // null)
            }
          );
        . as $s | input as $e
        | $s
        | .status=$status
        | .updated_at=$e.timestamp
        | if ($e.outcome? != null) then .outcomes += [$e.outcome] else . end
        | .outcomes_latest = reduce_latest(.outcomes_latest; ($e.outcome.metrics // []))
        | .last_event_id=$e.event_id
      ' "$state_file" "$event_file" > "$out_file"
      ;;
    merge_approval_invalidated)
      jq -cS --arg status "$next" '
        def forge_key($t): [($t.repo // ""), ($t.pr_url // ""), (($t.pr_number // null) | tostring)] | join("|");
        def upsert_target($targets; $obs):
          ($targets // []) as $existing
          | ([$existing[] | forge_key(.)] | index(forge_key($obs))) as $idx
          | if $idx == null then
              $existing + [$obs]
            else
              ($existing[0:$idx] + [($existing[$idx] + $obs)] + $existing[$idx + 1:])
            end;
        . as $s | input as $e
        | reduce ($e.observations // [])[] as $obs (
            $s
            | .status=$status
            | .updated_at=$e.timestamp
            | .merge_approval=null;
            .forge.targets = upsert_target(.forge.targets; $obs)
          )
        | .last_decision_actor=$e.actor
        | .last_decision_at=$e.timestamp
        | .last_event_id=$e.event_id
      ' "$state_file" "$event_file" > "$out_file"
      ;;
    merge_observed_external)
      jq -cS --arg status "$next" '
        def forge_key($t): [($t.repo // ""), ($t.pr_url // ""), (($t.pr_number // null) | tostring)] | join("|");
        def upsert_target($targets; $obs):
          ($targets // []) as $existing
          | ([$existing[] | forge_key(.)] | index(forge_key($obs))) as $idx
          | if $idx == null then
              $existing + [$obs]
            else
              ($existing[0:$idx] + [($existing[$idx] + $obs)] + $existing[$idx + 1:])
            end;
        . as $s | input as $e
        | reduce ($e.observations // [])[] as $obs (
            $s
            | .status=$status
            | .updated_at=$e.timestamp;
            .forge.targets = upsert_target(.forge.targets; $obs)
          )
        | if ($e.outcome? != null) then .outcomes += [$e.outcome] else . end
        | .last_event_id=$e.event_id
      ' "$state_file" "$event_file" > "$out_file"
      ;;
    project_tracking_synced)
      jq -cS --arg status "$next" '
        . as $s | input as $e
        | $s
        | .status=$status
        | .updated_at=$e.timestamp
        | .tracking = ((.tracking // {}) + ($e.tracking // {}))
        | .last_event_id=$e.event_id
      ' "$state_file" "$event_file" > "$out_file"
      ;;
    *)
      ideas_die "unsupported event: $event"
      return 1
      ;;
  esac
}

ideas_validate_event_shape() {
  local event_file="$1"
  jq -e --argjson schema "$IDEA_SCHEMA_VERSION" '
    type == "object"
    and .schema_version == $schema
    and (.event_id | type == "string" and test("^evt-[0-9a-f]{24}$"))
    and (.idea_id | type == "string" and test("^idea-[0-9a-f]{12}$"))
    and (.event | type == "string")
    and (.timestamp | type == "string")
    and (.actor | type == "string")
  ' "$event_file" >/dev/null || {
    ideas_die "malformed or schema-incompatible idea event"
    return 1
  }
}

ideas_replay_events() {
  local events_file="$1" out_dir="$2" line tmp_event state_file next_file idea_id event
  mkdir -p "$out_dir"
  [[ -f "$events_file" ]] || return 0
  tmp_event="$(mktemp "${TMPDIR:-/tmp}/e3d-idea-event.XXXXXX")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || { ideas_die "blank line in idea event stream: $events_file"; rm -f "$tmp_event"; return 1; }
    printf '%s\n' "$line" > "$tmp_event"
    jq -e . "$tmp_event" >/dev/null || { ideas_die "malformed JSON in idea event stream: $events_file"; rm -f "$tmp_event"; return 1; }
    ideas_validate_event_shape "$tmp_event" || { rm -f "$tmp_event"; return 1; }
    idea_id="$(jq -r '.idea_id' "$tmp_event")"
    event="$(jq -r '.event' "$tmp_event")"
    mkdir -p "$out_dir/$idea_id"
    state_file="$out_dir/$idea_id/idea.json"
    next_file="$out_dir/$idea_id/.idea.json.next"
    if [[ ! -f "$state_file" ]]; then
      [[ "$event" == "idea_proposed" ]] || { ideas_die "first event for $idea_id must be idea_proposed"; rm -f "$tmp_event"; return 1; }
      ideas_initial_state_from_event "$tmp_event" > "$next_file" || { rm -f "$tmp_event"; return 1; }
    else
      ideas_apply_event "$state_file" "$tmp_event" "$next_file" || { rm -f "$tmp_event"; return 1; }
    fi
    jq -e . "$next_file" >/dev/null || { rm -f "$tmp_event"; return 1; }
    mv "$next_file" "$state_file"
  done < "$events_file"
  rm -f "$tmp_event"
}

ideas_validate_stream() {
  local events_file="$1" tmp
  [[ -f "$events_file" ]] || return 0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/e3d-ideas-validate.XXXXXX")"
  if ideas_replay_events "$events_file" "$tmp/ideas"; then
    rm -rf "$tmp"
    return 0
  fi
  rm -rf "$tmp"
  return 1
}

ideas_materialize_snapshot() {
  local kind="$1" workspace="$2" idea_id="$3" events_file tmp state source dest root
  events_file="$(ideas_events_file "$kind" "$workspace")" || return 1
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/e3d-idea-materialize.XXXXXX")"
  if ! ideas_replay_events "$events_file" "$tmp/ideas"; then
    rm -rf "$tmp"
    return 1
  fi
  source="$tmp/ideas/$idea_id/idea.json"
  [[ -f "$source" ]] || { rm -rf "$tmp"; ideas_die "idea not found after replay: $idea_id"; return 1; }
  root="$(ideas_snapshots_dir "$kind" "$workspace")" || { rm -rf "$tmp"; return 1; }
  dest="$root/$idea_id/idea.json"
  mkdir -p "$(dirname "$dest")"
  cp "$source" "$dest.tmp.$$"
  mv "$dest.tmp.$$" "$dest"
  rm -rf "$tmp"
}

ideas_rebuild() {
  local kind="$1" workspace="$2" events_file root tmp
  events_file="$(ideas_events_file "$kind" "$workspace")" || return 1
  root="$(ideas_snapshots_dir "$kind" "$workspace")" || return 1
  mkdir -p "$(dirname "$events_file")"
  tmp="$(mktemp -d "$(dirname "$root")/.ideas-rebuild.XXXXXX")"
  if ! ideas_replay_events "$events_file" "$tmp/ideas"; then
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$root.previous.$$"
  if [[ -d "$root" ]]; then
    mv "$root" "$root.previous.$$"
  fi
  mv "$tmp/ideas" "$root"
  rm -rf "$root.previous.$$" "$tmp"
}

ideas_append_event() {
  local events_file="$1" event_file="$2"
  mkdir -p "$(dirname "$events_file")"
  [[ -f "$events_file" ]] || : > "$events_file"
  ideas_validate_stream "$events_file" || return 1
  ideas_validate_event_shape "$event_file" || return 1
  jq -cS . "$event_file" >> "$events_file"
}

ideas_commit_event_file() {
  local kind="$1" workspace="$2" idea_id="$3" event_file="$4"
  local canonical events_file current_file
  canonical="$(ideas_canonical_path "$workspace")" || return 1
  events_file="$(ideas_events_file "$kind" "$canonical")" || return 1
  current_file="$(ideas_snapshots_dir "$kind" "$canonical")/$idea_id/idea.json"
  [[ -f "$current_file" ]] || { ideas_rebuild "$kind" "$canonical" || return 1; }
  [[ -f "$current_file" ]] || { ideas_die "idea not found: $idea_id"; return 1; }

  ideas_acquire_lock "$kind" "$canonical" || return 1
  ideas_validate_stream "$events_file" || { ideas_release_lock "$kind" "$canonical"; return 1; }
  ideas_rebuild "$kind" "$canonical" || { ideas_release_lock "$kind" "$canonical"; return 1; }
  current_file="$(ideas_snapshots_dir "$kind" "$canonical")/$idea_id/idea.json"
  [[ -f "$current_file" ]] || { ideas_release_lock "$kind" "$canonical"; ideas_die "idea not found: $idea_id"; return 1; }
  ideas_materialize_next_status "$current_file" "$event_file" >/dev/null || {
    ideas_release_lock "$kind" "$canonical"
    return 1
  }
  ideas_append_event "$events_file" "$event_file" || { ideas_release_lock "$kind" "$canonical"; return 1; }
  if [[ "${E3D_PILOT_CRASH_AFTER_EVENT:-0}" == "1" ]]; then
    ideas_release_lock "$kind" "$canonical"
    return 99
  fi
  ideas_materialize_snapshot "$kind" "$canonical" "$idea_id" || { ideas_release_lock "$kind" "$canonical"; return 1; }
  ideas_release_lock "$kind" "$canonical"
}

# Returns the path to idea_id's materialized snapshot, rebuilding first if
# it isn't present on disk yet (e.g. right after a concurrent writer's
# append). Pure ledger read primitive -- no network, no gh -- so it lives
# here rather than in bin/e3d-pilot, alongside everything else that needs
# to resolve an idea by ID.
ideas_require_snapshot() {
  local kind="$1" workspace="$2" idea_id="$3" file
  file="$(ideas_snapshots_dir "$kind" "$workspace")/$idea_id/idea.json"
  if [[ ! -f "$file" ]]; then
    ideas_rebuild "$kind" "$workspace" || { ideas_die "failed to rebuild idea ledger for $workspace"; return 1; }
  fi
  file="$(ideas_snapshots_dir "$kind" "$workspace")/$idea_id/idea.json"
  [[ -f "$file" ]] || { ideas_die "idea not found: $idea_id"; return 1; }
  printf '%s' "$file"
}

# Appends an event whose shape isn't one of ideas_transition's fixed decision
# events (approval/rejection/etc, which also carry a digest) -- used for
# forge-observed and other system-authored events (sync, outcomes, project
# tracking) that just need $extra_file's fields merged onto the standard
# event envelope.
ideas_append_custom_event() {
  local kind="$1" workspace="$2" idea_id="$3" event="$4" actor="$5" note="$6" extra_file="$7"
  local canonical event_tmp timestamp
  canonical="$(ideas_canonical_path "$workspace")" || return 1
  ideas_require_snapshot "$kind" "$canonical" "$idea_id" >/dev/null
  event_tmp="$(mktemp "${TMPDIR:-/tmp}/e3d-idea-custom-event.XXXXXX")"
  timestamp="$(ideas_utc_now)"
  jq -ncS \
    --argjson schema "$IDEA_SCHEMA_VERSION" \
    --arg event_id "$(ideas_event_id "$idea_id:$event:$timestamp")" \
    --arg idea_id "$idea_id" \
    --arg event "$event" \
    --arg timestamp "$timestamp" \
    --arg actor "$actor" \
    --arg note "$note" \
    --slurpfile extra "$extra_file" '
      {
        schema_version:$schema,
        event_id:$event_id,
        idea_id:$idea_id,
        event:$event,
        timestamp:$timestamp,
        actor:$actor
      }
      | if $note != "" then .note=$note else . end
      | . + ($extra[0] // {})
    ' > "$event_tmp"
  ideas_commit_event_file "$kind" "$canonical" "$idea_id" "$event_tmp" || {
    rm -f "$event_tmp"
    return 1
  }
  rm -f "$event_tmp"
}

ideas_ingest_candidate() {
  local kind="$1" workspace="$2" source_run_id="$3" candidate_id="$4" candidate_file="$5"
  local canonical idea_id events_file existing_count timestamp candidate_tmp event_tmp
  canonical="$(ideas_canonical_path "$workspace")" || return 1
  idea_id="$(ideas_stable_id "$kind" "$canonical" "$source_run_id" "$candidate_id")"
  events_file="$(ideas_events_file "$kind" "$canonical")" || return 1
  candidate_tmp="$(mktemp "${TMPDIR:-/tmp}/e3d-idea-candidate.XXXXXX")"
  event_tmp="$(mktemp "${TMPDIR:-/tmp}/e3d-idea-event.XXXXXX")"
  jq -e . "$candidate_file" >/dev/null || { rm -f "$candidate_tmp" "$event_tmp"; ideas_die "candidate JSON is invalid: $candidate_file"; return 1; }
  jq -cS . "$candidate_file" | ideas_default_candidate_json > "$candidate_tmp"

  ideas_acquire_lock "$kind" "$canonical" || { rm -f "$candidate_tmp" "$event_tmp"; return 1; }
  if [[ -f "$events_file" ]]; then
    ideas_validate_stream "$events_file" || { rm -f "$candidate_tmp" "$event_tmp"; ideas_release_lock "$kind" "$canonical"; return 1; }
    existing_count="$(jq -R -s --arg id "$idea_id" '[split("\n")[] | select(length>0) | fromjson | select(.idea_id==$id and .event=="idea_proposed")] | length' "$events_file")"
    if (( existing_count > 0 )); then
      ideas_materialize_snapshot "$kind" "$canonical" "$idea_id" || { rm -f "$candidate_tmp" "$event_tmp"; ideas_release_lock "$kind" "$canonical"; return 1; }
      printf '%s\n' "$idea_id"
      rm -f "$candidate_tmp" "$event_tmp"
      ideas_release_lock "$kind" "$canonical"
      return 0
    fi
  fi

  timestamp="$(ideas_utc_now)"
  jq -ncS \
    --argjson schema "$IDEA_SCHEMA_VERSION" \
    --arg event_id "$(ideas_event_id "$idea_id:$source_run_id:$candidate_id")" \
    --arg idea_id "$idea_id" \
    --arg timestamp "$timestamp" \
    --arg workspace_kind "$kind" \
    --arg workspace_path "$canonical" \
    --arg source_run_id "$source_run_id" \
    --arg source_candidate "$candidate_id" \
    --slurpfile candidate "$candidate_tmp" \
    '{
      schema_version:$schema,event_id:$event_id,idea_id:$idea_id,event:"idea_proposed",
      timestamp:$timestamp,actor:"system",workspace_kind:$workspace_kind,workspace_path:$workspace_path,
      source_run_id:$source_run_id,source_candidate:$source_candidate,candidate:$candidate[0]
  }' > "$event_tmp"
  ideas_append_event "$events_file" "$event_tmp" || { rm -f "$candidate_tmp" "$event_tmp"; ideas_release_lock "$kind" "$canonical"; return 1; }
  if [[ "${E3D_PILOT_CRASH_AFTER_EVENT:-0}" == "1" ]]; then
    rm -f "$candidate_tmp" "$event_tmp"
    ideas_release_lock "$kind" "$canonical"
    return 99
  fi
  ideas_materialize_snapshot "$kind" "$canonical" "$idea_id" || { rm -f "$candidate_tmp" "$event_tmp"; ideas_release_lock "$kind" "$canonical"; return 1; }
  printf '%s\n' "$idea_id"
  rm -f "$candidate_tmp" "$event_tmp"
  ideas_release_lock "$kind" "$canonical"
}

ideas_transition() {
  local kind="$1" workspace="$2" idea_id="$3" event="$4" actor="$5" note="$6" targets_file="$7" head_sha="$8" outcome_file="${9:-}"
  local canonical events_file current_file timestamp event_tmp current_digest
  canonical="$(ideas_canonical_path "$workspace")" || return 1
  events_file="$(ideas_events_file "$kind" "$canonical")" || return 1
  current_file="$(ideas_snapshots_dir "$kind" "$canonical")/$idea_id/idea.json"
  [[ -f "$current_file" ]] || { ideas_rebuild "$kind" "$canonical" || return 1; }
  [[ -f "$current_file" ]] || { ideas_die "idea not found: $idea_id"; return 1; }
  event_tmp="$(mktemp "${TMPDIR:-/tmp}/e3d-idea-event.XXXXXX")"
  timestamp="$(ideas_utc_now)"
  current_digest="$(ideas_decision_digest_from_json "$current_file")"

  ideas_acquire_lock "$kind" "$canonical" || { rm -f "$event_tmp"; return 1; }
  ideas_validate_stream "$events_file" || { rm -f "$event_tmp"; ideas_release_lock "$kind" "$canonical"; return 1; }
  ideas_rebuild "$kind" "$canonical" || { rm -f "$event_tmp"; ideas_release_lock "$kind" "$canonical"; return 1; }
  current_file="$(ideas_snapshots_dir "$kind" "$canonical")/$idea_id/idea.json"
  [[ -f "$current_file" ]] || { rm -f "$event_tmp"; ideas_release_lock "$kind" "$canonical"; ideas_die "idea not found: $idea_id"; return 1; }
  ideas_allowed_transition "$(jq -r '.status' "$current_file")" "$event" >/dev/null || {
    rm -f "$event_tmp"
    ideas_release_lock "$kind" "$canonical"
    ideas_die "invalid idea lifecycle transition: $(jq -r '.status' "$current_file") + $event"
    return 1
  }
  if [[ "$event" == "implementation_approved" ]]; then
    if [[ "$(jq -r 'if .validation.approvable == null then true else .validation.approvable end' "$current_file")" != "true" ]]; then
      rm -f "$event_tmp"
      ideas_release_lock "$kind" "$canonical"
      ideas_die "$(jq -r '.validation.eligibility_reason // "idea is not eligible for approval"' "$current_file")"
      return 1
    fi
  fi
  current_digest="$(ideas_decision_digest_effective "$current_file" "$targets_file")"
  jq -ncS \
    --argjson schema "$IDEA_SCHEMA_VERSION" \
    --arg event_id "$(ideas_event_id "$idea_id:$event:$timestamp")" \
    --arg idea_id "$idea_id" \
    --arg event "$event" \
    --arg timestamp "$timestamp" \
    --arg actor "$actor" \
    --arg note "$note" \
    --arg digest "$current_digest" \
    --arg head_sha "$head_sha" \
    --arg source_status "$(jq -r '.status' "$current_file")" \
    --argjson targets "$(if [[ -n "$targets_file" ]]; then jq -c 'if type == "array" then . else [.] end' "$targets_file"; else printf '[]'; fi)" \
    --argjson outcome "$(if [[ -n "$outcome_file" ]]; then jq -c '.' "$outcome_file"; else printf 'null'; fi)" \
    '{
      schema_version:$schema,event_id:$event_id,idea_id:$idea_id,event:$event,
      timestamp:$timestamp,actor:$actor
    }
    | if $note != "" then .note=$note else . end
    | if ($event|test("approved|retry")) then .approval_digest=$digest else . end
    | if $head_sha != "" then .head_sha=$head_sha else . end
    | if $event == "merge_approved" or $event == "merge_retry_approved" then .source_status=$source_status else . end
    | if ($targets|length) > 0 then .targets=$targets else . end
    | if $outcome != null then .outcome=$outcome else . end' > "$event_tmp"
  ideas_materialize_next_status "$current_file" "$event_tmp" >/dev/null || {
    rm -f "$event_tmp"
    ideas_release_lock "$kind" "$canonical"
    return 1
  }
  ideas_append_event "$events_file" "$event_tmp" || { rm -f "$event_tmp"; ideas_release_lock "$kind" "$canonical"; return 1; }
  if [[ "${E3D_PILOT_CRASH_AFTER_EVENT:-0}" == "1" ]]; then
    rm -f "$event_tmp"
    ideas_release_lock "$kind" "$canonical"
    return 99
  fi
  ideas_materialize_snapshot "$kind" "$canonical" "$idea_id" || { rm -f "$event_tmp"; ideas_release_lock "$kind" "$canonical"; return 1; }
  printf '%s\n' "$idea_id"
  rm -f "$event_tmp"
  ideas_release_lock "$kind" "$canonical"
}
