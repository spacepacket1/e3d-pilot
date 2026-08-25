#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

COLLECTOR_LEGACY_MODE=0

collector_is_legacy_mode() {
  [[ -n "${PHASE26_CURL_TRACE:-}" || -n "${PHASE26_CURL_RESPONSES:-}" || -n "${PHASE26_CURL_COUNT:-}" ]]
}

collector_unavailable_latency() {
  if [[ "$COLLECTOR_LEGACY_MODE" -eq 1 ]]; then
    printf 'unavailablems'
  else
    printf 'unavailable'
  fi
}

sanitize_markdown_line() {
  local value="$1"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  while [[ "$value" == *"  "* ]]; do
    value="${value//  / }"
  done
  printf '%s' "$value"
}

validate_fleet_config_json() {
  local file="$1"
  [[ -r "$file" ]] || die "fleet discover config not readable: $file"
  jq -e . "$file" >/dev/null 2>&1 || die "invalid JSON: $file"
  jq -e 'type == "object"' "$file" >/dev/null || die "fleet discover config must be a JSON object: $file"
}

validate_live_instance_url() {
  local url="$1" lower rest authority
  lower="$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    http://*|https://*) ;;
    *) return 1 ;;
  esac
  rest="${url#*://}"
  authority="${rest%%[/?#]*}"
  [[ -n "$authority" && "$authority" != *"@"* ]]
}

validate_live_instance_entry() {
  local file="$1" entry="$2" url
  jq -e '
    type == "object" and
    ((keys_unsorted | sort) == ["name", "url"]) and
    (.name | type == "string" and length > 0) and
    (.url | type == "string" and length > 0)
  ' <<<"$entry" >/dev/null || die "fleet discover config.live_instances entries must contain only non-empty string name and url: $file"
  url="$(jq -r '.url' <<<"$entry")"
  validate_live_instance_url "$url" || die "fleet discover config.live_instances url must be http(s) with a non-empty authority and no userinfo: $file"
}

validate_live_instances() {
  local file="$1" count entry
  if jq -e 'has("live_instances") and (.live_instances | type != "array")' "$file" >/dev/null; then
    die "fleet discover config.live_instances must be an array when provided: $file"
  fi
  count="$(jq -r 'if has("live_instances") and (.live_instances | type == "array") then (.live_instances | length) else 0 end' "$file")"
  if [[ "$count" -gt 0 ]]; then
    while IFS= read -r entry; do
      validate_live_instance_entry "$file" "$entry"
    done < <(jq -c '.live_instances[]' "$file")
  fi
}

validate_social_account_entry() {
  local file="$1" entry="$2"
  jq -e '
    type == "object" and
    ((keys_unsorted | sort) == ["bot_user_id", "channel_id", "name", "platform"]) and
    (.platform == "discord") and
    (.name | type == "string" and length > 0) and
    (.channel_id | type == "string" and length > 0) and
    (.bot_user_id | type == "string" and length > 0)
  ' <<<"$entry" >/dev/null || die "fleet discover config.social_accounts entries must contain platform=discord and non-empty name, channel_id, and bot_user_id: $file"
}

validate_social_accounts() {
  local file="$1" count entry
  if jq -e 'has("social_accounts") and (.social_accounts | type != "array")' "$file" >/dev/null; then
    die "fleet discover config.social_accounts must be an array when provided: $file"
  fi
  count="$(jq -r 'if has("social_accounts") and (.social_accounts | type == "array") then (.social_accounts | length) else 0 end' "$file")"
  if [[ "$count" -gt 0 ]]; then
    while IFS= read -r entry; do
      validate_social_account_entry "$file" "$entry"
    done < <(jq -c '.social_accounts[]' "$file")
  fi
}

validate_fleet_config() {
  local file="$1"
  validate_fleet_config_json "$file"
  validate_live_instances "$file"
  validate_social_accounts "$file"
}

live_curl_error_label() {
  case "$1" in
    28) printf 'HTTP timeout' ;;
    7) printf 'HTTP connection-refused' ;;
    6) printf 'HTTP dns-error' ;;
    *) printf 'HTTP unknown-error' ;;
  esac
}

elapsed_to_ms() {
  local elapsed="$1" whole fraction
  whole="${elapsed%%.*}"
  if [[ "$elapsed" == *.* ]]; then
    fraction="${elapsed#*.}"
  else
    fraction=""
  fi
  fraction="${fraction}000"
  fraction="${fraction:0:3}"
  printf '%s' "$((10#$whole * 1000 + 10#$fraction))"
}

http_status_is_three_digits() {
  [[ "$1" =~ ^[0-9]{3}$ ]]
}

render_live_instance_result() {
  local result="$1" name url state detail
  name="$(jq -r '.name' <<<"$result")"
  url="$(jq -r '.url' <<<"$result")"
  state="$(jq -r '.state' <<<"$result")"
  detail="$(jq -r '.detail' <<<"$result")"
  printf -- '- **%s** (%s): %s — %s\n' "$name" "$url" "$state" "$detail"
}

collect_one_live_instance() {
  local name="$1" url="$2" curl_output curl_status status elapsed state detail latency_display latency_ms status_num elapsed_valid=0
  local -a curl_args
  name="$(sanitize_markdown_line "$name")"
  url="$(sanitize_markdown_line "$url")"
  if [[ "$COLLECTOR_LEGACY_MODE" -eq 1 ]]; then
    curl_args=(
      -sS -o /dev/null
      -w '%{http_code}\t%{time_total}'
      --max-redirs 1
      --max-time 10
      --proto '=http,https'
      --proto-redir '=http,https'
      --location
      --request GET
      --
      "$url"
    )
  else
    curl_args=(
      -sS -L -o /dev/null
      -w '%{http_code}\t%{time_total}'
      --max-time 10
      --max-redirs 1
      --proto '=http,https'
      --proto-redir '=http,https'
      --request GET
      --
      "$url"
    )
  fi
  set +e
  curl_output="$(curl "${curl_args[@]}")"
  curl_status=$?
  set -e
  status="${curl_output%%$'\t'*}"
  if [[ "$curl_output" == *$'\t'* ]]; then
    elapsed="${curl_output#*$'\t'}"
  else
    elapsed=""
  fi
  if [[ "$elapsed" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    latency_ms="$(elapsed_to_ms "$elapsed")"
    latency_display="${latency_ms}ms"
    elapsed_valid=1
  else
    latency_ms=""
    latency_display="$(collector_unavailable_latency)"
  fi
  if [[ "$curl_status" -ne 0 ]]; then
    state="down"
    detail="$(live_curl_error_label "$curl_status"), $latency_display"
  elif ! http_status_is_three_digits "$status"; then
    state="down"
    detail="HTTP invalid-curl-output, $latency_display"
  else
    status_num="$((10#$status))"
    if [[ "$elapsed_valid" -eq 0 ]]; then
      state="down"
      detail="HTTP invalid-curl-output, $latency_display"
    elif [[ "$status_num" -eq 200 && "$latency_ms" -le 1500 ]]; then
      state="healthy"
      detail="HTTP $status, $latency_display"
    elif [[ "$status_num" -eq 200 ]]; then
      state="degraded"
      detail="HTTP $status, $latency_display"
    elif [[ "$status_num" -ge 201 && "$status_num" -le 399 ]]; then
      state="degraded"
      detail="HTTP $status, $latency_display"
    else
      state="down"
      detail="HTTP $status, $latency_display"
    fi
  fi
  jq -nc --arg name "$name" --arg url "$url" --arg state "$state" --arg detail "$detail" '{name:$name,url:$url,state:$state,detail:$detail}'
}

render_social_account_result() {
  local result="$1" name detail
  name="$(jq -r '.name' <<<"$result")"
  detail="$(jq -r '.detail' <<<"$result")"
  printf -- '- **%s**: %s\n' "$name" "$detail"
}

discord_curl_error_label() {
  live_curl_error_label "$1"
}

discord_message_reaction_sum() {
  local message="$1"
  jq -e -r '
    if has("reactions") and .reactions != null then
      if (.reactions | type) != "array" then
        error("invalid Discord payload")
      else
        [ .reactions[]
          | if type == "object" and (.count | type == "number") and (.count >= 0) and ((.count | floor) == .count)
            then .count
            else error("invalid Discord payload")
            end
        ] | add // 0
      end
    else
      0
    end
  ' <<<"$message"
}

collect_one_discord_account() {
  local name="$1" channel_id="$2" bot_user_id="$3" token="${DISCORD_BOT_TOKEN:-}" body_file curl_output curl_status http_status
  local -a curl_args
  name="$(sanitize_markdown_line "$name")"
  if [[ -z "$token" ]]; then
    jq -nc --arg name "$name" --arg detail "collection failure — DISCORD_BOT_TOKEN not set" '{name:$name,detail:$detail}'
    return 0
  fi
  body_file="$(mktemp "${TMPDIR:-/tmp}/e3d-discord-body.XXXXXX")"
  curl_args=(
    -sS -L
    -o "$body_file"
    -w '%{http_code}'
    --max-time 10
    --max-redirs 1
    --proto '=http,https'
    --proto-redir '=http,https'
    --request GET
    -H "Authorization: Bot $token"
    --
    "https://discord.com/api/v10/channels/$channel_id/messages?limit=50"
  )
  set +e
  curl_output="$(curl "${curl_args[@]}")"
  curl_status=$?
  set -e
  if [[ "$curl_status" -ne 0 ]]; then
    rm -f "$body_file"
    jq -nc --arg name "$name" --arg detail "collection failure — $(discord_curl_error_label "$curl_status")" '{name:$name,detail:$detail}'
    return 0
  fi
  http_status="$curl_output"
  if ! http_status_is_three_digits "$http_status"; then
    rm -f "$body_file"
    jq -nc --arg name "$name" --arg detail "collection failure — HTTP invalid-curl-output" '{name:$name,detail:$detail}'
    return 0
  fi
  if [[ "$http_status" != 2* ]]; then
    rm -f "$body_file"
    jq -nc --arg name "$name" --arg detail "collection failure — HTTP $http_status" '{name:$name,detail:$detail}'
    return 0
  fi
  if ! jq -e 'type == "array"' "$body_file" >/dev/null 2>&1; then
    rm -f "$body_file"
    jq -nc --arg name "$name" --arg detail "collection failure — invalid Discord payload" '{name:$name,detail:$detail}'
    return 0
  fi
  local count=0 reactions_total=0 message reaction_sum detail
  while IFS= read -r message; do
    if [[ "$count" -ge 10 ]]; then
      break
    fi
    reaction_sum="$(discord_message_reaction_sum "$message")" || {
      rm -f "$body_file"
      jq -nc --arg name "$name" --arg detail "collection failure — invalid Discord payload" '{name:$name,detail:$detail}'
      return 0
    }
    count=$((count + 1))
    reactions_total=$((reactions_total + reaction_sum))
  done < <(jq -c --arg bot_user_id "$bot_user_id" '.[] | select(type == "object" and (.author | type == "object") and (.author.id | type == "string") and .author.id == $bot_user_id)' "$body_file")
  rm -f "$body_file"
  if [[ "$count" -eq 0 ]]; then
    detail="no recent messages found"
  else
    detail="$count recent messages, $reactions_total total reactions"
  fi
  jq -nc --arg name "$name" --arg detail "$detail" '{name:$name,detail:$detail}'
}

render_live_instances() {
  local file="$1" entry result count
  count="$(jq -r 'if has("live_instances") and (.live_instances | type == "array") then (.live_instances | length) else 0 end' "$file")"
  printf '### Live Instance Status\n'
  if [[ "$count" -eq 0 ]]; then
    printf '\nNo live instances configured.\n'
    return 0
  fi
  printf '\n'
  while IFS= read -r entry; do
    result="$(collect_one_live_instance "$(jq -r '.name' <<<"$entry")" "$(jq -r '.url' <<<"$entry")")"
    render_live_instance_result "$result"
  done < <(jq -c '.live_instances[]' "$file")
}

render_social_accounts() {
  local file="$1" entry result count
  count="$(jq -r 'if has("social_accounts") and (.social_accounts | type == "array") then (.social_accounts | length) else 0 end' "$file")"
  if [[ "$count" -eq 0 ]]; then
    return 0
  fi
  printf '\n### Social Engagement\n\n'
  while IFS= read -r entry; do
    result="$(collect_one_discord_account "$(jq -r '.name' <<<"$entry")" "$(jq -r '.channel_id' <<<"$entry")" "$(jq -r '.bot_user_id' <<<"$entry")")"
    render_social_account_result "$result"
  done < <(jq -c '.social_accounts[]' "$file")
}

platform_dispatch() {
  local file="$1" validate_only="${2:-0}"
  validate_fleet_config "$file"
  if [[ "$validate_only" -eq 1 ]]; then
    return 0
  fi
  COLLECTOR_LEGACY_MODE=0
  if collector_is_legacy_mode; then
    COLLECTOR_LEGACY_MODE=1
  fi
  render_live_instances "$file"
  if jq -e 'has("social_accounts") and (.social_accounts | type == "array" and length > 0)' "$file" >/dev/null; then
    render_social_accounts "$file"
  fi
}

main() {
  local validate_only=0 file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --validate-only)
        validate_only=1
        ;;
      -h|--help)
        printf 'usage: collect-fleet-health.sh [--validate-only] <fleet-config.json>\n'
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "unknown argument: $1"
        ;;
      *)
        [[ -z "$file" ]] || die "unexpected argument: $1"
        file="$1"
        ;;
    esac
    shift
  done
  if [[ -z "$file" && $# -gt 0 ]]; then
    file="$1"
    shift
  fi
  [[ -n "$file" ]] || die "usage: collect-fleet-health.sh [--validate-only] <fleet-config.json>"
  [[ -r "$file" ]] || die "fleet discover config not readable: $file"
  platform_dispatch "$file" "$validate_only"
}

main "$@"
