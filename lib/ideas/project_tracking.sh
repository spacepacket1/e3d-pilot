#!/usr/bin/env bash

# Best-effort sync of an idea's lifecycle status to an external GitHub
# Projects (v2) board. Every external call here is wrapped so a
# misconfigured project, an unauthenticated gh, or a transient API failure
# degrades to a stderr warning -- never a `die` that would block the
# calling command. Tracking state (which board item an idea is linked to,
# and what status was last written) is persisted through the same
# append-only event mechanism the rest of the ledger uses, via a
# project_tracking_synced event, so `ideas rebuild` never loses the
# linkage between an idea and its board item.

# Resolves the configured project board URL: the repo/fleet config's
# tracking.project_url when present, else the E3D_PILOT_TRACKING_PROJECT_URL
# environment variable (same "one setting, every workspace" shape as
# LOCAL_MODEL_ENDPOINT), else empty (tracking disabled -- the default).
project_tracking_resolve_url() {
  local config_file="$1" url=""
  if [[ -f "$config_file" ]]; then
    url="$(jq -r '.tracking.project_url // empty' "$config_file" 2>/dev/null || true)"
  fi
  [[ -n "$url" ]] || url="${E3D_PILOT_TRACKING_PROJECT_URL:-}"
  printf '%s' "$url"
}

project_tracking_config_file() {
  local kind="$1" workspace="$2"
  case "$kind" in
    repo) config_path_for_repo "$workspace" ;;
    fleet) printf '%s/.e3d-pilot-fleet/config.json' "$workspace" ;;
    *) return 1 ;;
  esac
}

# Prints "owner<TAB>number" for a project URL shaped like
# https://github.com/users/<owner>/projects/<n> or
# https://github.com/orgs/<owner>/projects/<n>. Fails on anything else.
project_tracking_parse_url() {
  local url="$1"
  [[ "$url" =~ ^https://github\.com/(users|orgs)/([^/]+)/projects/([0-9]+) ]] || return 1
  printf '%s\t%s' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

# Pure mapping from an idea's lifecycle status to the board's Status column.
# "ARCHIVE" is a sentinel, not a real Status option: rejected/closed/
# reverted ideas get archived instead of forced into a column that doesn't
# describe them. implementation_failed/merge_failed map back to Ready/In
# review respectively since both are explicitly retryable, not dead ends.
project_tracking_status_for_idea() {
  local status="$1"
  case "$status" in
    proposed) printf 'Backlog' ;;
    approved_for_implementation|changes_requested|implementation_failed) printf 'Ready' ;;
    implementing) printf 'In progress' ;;
    implemented|approved_for_merge|partially_merged|merge_failed) printf 'In review' ;;
    merged) printf 'Done' ;;
    rejected|closed|reverted) printf 'ARCHIVE' ;;
    *) return 1 ;;
  esac
}

# The most recent PR URL from a succeeded implementation target, if any.
project_tracking_idea_pr_url() {
  local idea_file="$1"
  jq -r '
    [.outcomes[]? | select(.type=="implementation" and .status=="succeeded") | .targets[]? | select((.pr_url // null) != null) | .pr_url]
    | .[-1] // empty
  ' "$idea_file"
}

project_tracking_gh_project_id() {
  gh project view "$2" --owner "$1" --format json --jq '.id' 2>/dev/null
}

project_tracking_status_field_json() {
  gh project field-list "$2" --owner "$1" --format json --jq '.fields[] | select(.name=="Status")' 2>/dev/null
}

project_tracking_find_item_by_url() {
  local owner="$1" number="$2" url="$3"
  gh project item-list "$number" --owner "$owner" --format json --limit 200 \
    --jq ".items[] | select(.content.url==\"$url\") | .id" 2>/dev/null | head -n1
}

project_tracking_create_draft_item() {
  local owner="$1" number="$2" title="$3" body="$4"
  gh project item-create "$number" --owner "$owner" --title "$title" --body "$body" --format json --jq '.id' 2>/dev/null
}

project_tracking_add_item_by_url() {
  local owner="$1" number="$2" url="$3"
  gh project item-add "$number" --owner "$owner" --url "$url" --format json --jq '.id' 2>/dev/null
}

project_tracking_set_status() {
  local project_id="$1" item_id="$2" field_id="$3" option_id="$4"
  gh project item-edit --id "$item_id" --project-id "$project_id" --field-id "$field_id" --single-select-option-id "$option_id" >/dev/null 2>&1
}

project_tracking_archive_item() {
  local owner="$1" number="$2" item_id="$3"
  gh project item-archive "$number" --owner "$owner" --id "$item_id" >/dev/null 2>&1
}

project_tracking_delete_item() {
  local owner="$1" number="$2" item_id="$3"
  gh project item-delete "$number" --owner "$owner" --id "$item_id" >/dev/null 2>&1
}

# Syncs one idea's board item to match its current ledger status. Safe to
# call unconditionally after any status-changing event: no-ops immediately
# when tracking isn't configured, and every external step degrades to a
# stderr warning rather than failing the caller.
project_tracking_sync_idea() {
  local kind="$1" workspace="$2" idea_id="$3"
  local config_file url
  config_file="$(project_tracking_config_file "$kind" "$workspace")" || return 0
  url="$(project_tracking_resolve_url "$config_file")"
  [[ -n "$url" ]] || return 0
  command -v gh >/dev/null 2>&1 || { printf 'warning: project tracking: gh CLI unavailable\n' >&2; return 0; }

  local owner_number owner number
  owner_number="$(project_tracking_parse_url "$url")" || {
    printf 'warning: project tracking: unrecognized project url: %s\n' "$url" >&2
    return 0
  }
  owner="${owner_number%%$'\t'*}"
  number="${owner_number##*$'\t'}"

  local idea_file
  idea_file="$(ideas_snapshots_dir "$kind" "$workspace")/$idea_id/idea.json"
  [[ -f "$idea_file" ]] || return 0

  local idea_status target_status pr_url current_item_id current_item_kind current_status
  idea_status="$(jq -r '.status' "$idea_file")"
  target_status="$(project_tracking_status_for_idea "$idea_status")" || return 0
  pr_url="$(project_tracking_idea_pr_url "$idea_file")"
  current_item_id="$(jq -r '.tracking.project_item_id // empty' "$idea_file")"
  current_item_kind="$(jq -r '.tracking.project_kind // empty' "$idea_file")"
  current_status="$(jq -r '.tracking.project_status // empty' "$idea_file")"

  local project_id
  project_id="$(project_tracking_gh_project_id "$owner" "$number")"
  [[ -n "$project_id" ]] || { printf 'warning: project tracking: could not resolve project %s\n' "$url" >&2; return 0; }

  if [[ -z "$current_item_id" ]]; then
    if [[ -n "$pr_url" ]]; then
      current_item_id="$(project_tracking_find_item_by_url "$owner" "$number" "$pr_url")"
      [[ -n "$current_item_id" ]] || current_item_id="$(project_tracking_add_item_by_url "$owner" "$number" "$pr_url")"
      current_item_kind="pr"
    else
      current_item_id="$(project_tracking_create_draft_item "$owner" "$number" "e3d-pilot: $(jq -r '.title // .idea_id' "$idea_file")" "$(jq -r '.summary // ""' "$idea_file")")"
      current_item_kind="draft"
    fi
    [[ -n "$current_item_id" ]] || { printf 'warning: project tracking: failed to create/link a board item for %s\n' "$idea_id" >&2; return 0; }
    current_status=""
  elif [[ "$current_item_kind" == "draft" && -n "$pr_url" ]]; then
    # The idea now has a real PR. Reuse it (including one GitHub's own
    # project auto-add workflow may have already created) instead of
    # leaving two cards -- a stale draft and the real PR -- for one idea.
    local pr_item_id
    pr_item_id="$(project_tracking_find_item_by_url "$owner" "$number" "$pr_url")"
    [[ -n "$pr_item_id" ]] || pr_item_id="$(project_tracking_add_item_by_url "$owner" "$number" "$pr_url")"
    if [[ -n "$pr_item_id" ]]; then
      project_tracking_delete_item "$owner" "$number" "$current_item_id"
      current_item_id="$pr_item_id"
      current_item_kind="pr"
      current_status=""
    fi
  fi

  if [[ "$target_status" == "ARCHIVE" ]]; then
    if [[ "$current_status" != "Archived" ]]; then
      project_tracking_archive_item "$owner" "$number" "$current_item_id"
      current_status="Archived"
    fi
  elif [[ "$current_status" != "$target_status" ]]; then
    local status_field_json field_id option_id
    status_field_json="$(project_tracking_status_field_json "$owner" "$number")"
    if [[ -n "$status_field_json" ]]; then
      field_id="$(jq -r '.id' <<<"$status_field_json")"
      option_id="$(jq -r --arg name "$target_status" '.options[]? | select(.name==$name) | .id' <<<"$status_field_json")"
      if [[ -n "$field_id" && -n "$option_id" ]]; then
        project_tracking_set_status "$project_id" "$current_item_id" "$field_id" "$option_id"
        current_status="$target_status"
      else
        printf 'warning: project tracking: board has no Status option named %s\n' "$target_status" >&2
      fi
    fi
  fi

  local extra_file
  extra_file="$(mktemp "${TMPDIR:-/tmp}/e3d-project-tracking.XXXXXX")"
  jq -ncS \
    --arg id "$current_item_id" \
    --arg kind "$current_item_kind" \
    --arg status "$current_status" \
    '{tracking:{project_item_id:$id, project_kind:$kind, project_status:$status}}' > "$extra_file"
  ideas_append_custom_event "$kind" "$workspace" "$idea_id" project_tracking_synced "system-tracking" "project board sync" "$extra_file" >/dev/null 2>&1
  rm -f "$extra_file"
  return 0
}
