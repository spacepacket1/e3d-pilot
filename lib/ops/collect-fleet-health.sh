#!/usr/bin/env bash
set -euo pipefail

LIVE_INSTANCE_NAMES=()
LIVE_INSTANCE_URLS=()
LIVE_INSTANCE_CLASSIFICATIONS=()
LIVE_INSTANCE_STATUSES=()
LIVE_INSTANCE_LATENCIES=()

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

normalize_markdown_text() {
  local text="$1"
  text="${text//$'\r'/ }"
  text="${text//$'\n'/ }"
  while [[ "$text" == *"  "* ]]; do
    text="${text//  / }"
  done
  printf '%s' "$text"
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
  local entry="$1" name url
  jq -e '
    type == "object" and
    (keys_unsorted | length == 2) and
    has("name") and has("url") and
    (.name | type == "string" and length > 0) and
    (.url | type == "string" and length > 0)
  ' <<<"$entry" >/dev/null || die "invalid live_instances entry: expected exactly non-empty string name and url"
  name="$(jq -r '.name' <<<"$entry")"
  url="$(jq -r '.url' <<<"$entry")"
  validate_live_instance_url "$url" || die "invalid live_instances url: $url"
  printf '%s\t%s\n' "$name" "$url"
}

validate_fleet_health_config() {
  local file="$1" count entry
  [[ -r "$file" ]] || die "fleet config not readable: $file"
  jq -e . "$file" >/dev/null || die "invalid JSON: $file"
  if jq -e 'has("live_instances") and (.live_instances | type != "array")' "$file" >/dev/null; then
    die "fleet config live_instances must be an array when provided: $file"
  fi
  count="$(jq -r 'if has("live_instances") and (.live_instances | type == "array") then (.live_instances | length) else 0 end' "$file")"
  if [[ "$count" -gt 0 ]]; then
    while IFS= read -r entry; do
      validate_live_instance_entry "$entry" >/dev/null
    done < <(jq -c '.live_instances[]' "$file")
  fi
}

curl_failure_reason() {
  case "$1" in
    28) printf 'timeout' ;;
    7) printf 'connection-refused' ;;
    6) printf 'dns-error' ;;
    *) printf 'unknown-error' ;;
  esac
}

valid_time_total() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

time_total_to_ms() {
  local time_total="$1" seconds fraction
  seconds="${time_total%%.*}"
  fraction=""
  if [[ "$time_total" == *.* ]]; then
    fraction="${time_total#*.}"
  fi
  fraction="${fraction}000"
  fraction="${fraction:0:3}"
  printf '%s' "$((10#$seconds * 1000 + 10#$fraction))"
}

collect_live_instance_statuses() {
  local file="$1" entry name url curl_output exit_status http_status time_total status_value
  LIVE_INSTANCE_NAMES=()
  LIVE_INSTANCE_URLS=()
  LIVE_INSTANCE_CLASSIFICATIONS=()
  LIVE_INSTANCE_STATUSES=()
  LIVE_INSTANCE_LATENCIES=()

  while IFS= read -r entry; do
    name="$(jq -r '.name' <<<"$entry")"
    url="$(jq -r '.url' <<<"$entry")"

    set +e
    curl_output="$(
      curl -sS -o /dev/null -w '%{http_code}\t%{time_total}' \
        --max-redirs 1 \
        --max-time 10 \
        --proto '=http,https' \
        --proto-redir '=http,https' \
        --location \
        --request GET \
        -- "$url"
    )"
    exit_status=$?
    set -e

    http_status=""
    time_total=""
    if [[ "$curl_output" == *$'\t'* ]]; then
      http_status="${curl_output%%$'\t'*}"
      time_total="${curl_output#*$'\t'}"
    else
      http_status="$curl_output"
    fi

    LIVE_INSTANCE_NAMES+=("$name")
    LIVE_INSTANCE_URLS+=("$url")

    if [[ $exit_status -ne 0 ]]; then
      LIVE_INSTANCE_CLASSIFICATIONS+=("down")
      LIVE_INSTANCE_STATUSES+=("$(curl_failure_reason "$exit_status")")
      if valid_time_total "$time_total"; then
        LIVE_INSTANCE_LATENCIES+=("$(time_total_to_ms "$time_total")")
      else
        LIVE_INSTANCE_LATENCIES+=("unavailable")
      fi
      continue
    fi

    if ! valid_time_total "$time_total"; then
      LIVE_INSTANCE_CLASSIFICATIONS+=("down")
      LIVE_INSTANCE_STATUSES+=("invalid-curl-output")
      LIVE_INSTANCE_LATENCIES+=("unavailable")
      continue
    fi

    status_value=0
    if [[ "$http_status" =~ ^[0-9]{3}$ ]]; then
      status_value=$((10#$http_status))
    fi

    if (( status_value >= 200 && status_value <= 299 )); then
      if (( 10#${time_total%%.*} >= 2 )); then
        LIVE_INSTANCE_CLASSIFICATIONS+=("degraded")
      else
        LIVE_INSTANCE_CLASSIFICATIONS+=("healthy")
      fi
      LIVE_INSTANCE_STATUSES+=("$http_status")
      LIVE_INSTANCE_LATENCIES+=("$(time_total_to_ms "$time_total")")
    elif (( status_value >= 300 && status_value <= 399 )); then
      LIVE_INSTANCE_CLASSIFICATIONS+=("degraded")
      LIVE_INSTANCE_STATUSES+=("$http_status")
      LIVE_INSTANCE_LATENCIES+=("$(time_total_to_ms "$time_total")")
    elif (( status_value >= 400 && status_value <= 599 )); then
      LIVE_INSTANCE_CLASSIFICATIONS+=("down")
      LIVE_INSTANCE_STATUSES+=("$http_status")
      LIVE_INSTANCE_LATENCIES+=("$(time_total_to_ms "$time_total")")
    else
      LIVE_INSTANCE_CLASSIFICATIONS+=("down")
      LIVE_INSTANCE_STATUSES+=("unexpected-http-status")
      LIVE_INSTANCE_LATENCIES+=("$(time_total_to_ms "$time_total")")
    fi
  done < <(jq -c '.live_instances[]?' "$file")
}

render_live_instance_statuses() {
  local index name url
  printf '### Live Instance Status\n\n'
  if [[ ${#LIVE_INSTANCE_NAMES[@]} -eq 0 ]]; then
    printf 'No live instances configured.\n'
    return 0
  fi
  for index in "${!LIVE_INSTANCE_NAMES[@]}"; do
    name="$(normalize_markdown_text "${LIVE_INSTANCE_NAMES[$index]}")"
    url="$(normalize_markdown_text "${LIVE_INSTANCE_URLS[$index]}")"
    printf -- '- **%s** (%s): %s — HTTP %s, %sms\n' \
      "$name" \
      "$url" \
      "${LIVE_INSTANCE_CLASSIFICATIONS[$index]}" \
      "${LIVE_INSTANCE_STATUSES[$index]}" \
      "${LIVE_INSTANCE_LATENCIES[$index]}"
  done
}

main() {
  local config_file="${1:-}"
  [[ $# -eq 1 ]] || die "usage: collect-fleet-health.sh <fleet-config.json>"
  validate_fleet_health_config "$config_file"
  collect_live_instance_statuses "$config_file"
  render_live_instance_statuses
}

main "$@"
