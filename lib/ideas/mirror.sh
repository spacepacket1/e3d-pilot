#!/usr/bin/env bash

# Mirror transport limits are deliberately fixed: mirroring is ancillary work
# and must not leave a publish workflow waiting indefinitely.
IDEAS_MIRROR_CONNECT_TIMEOUT=10
IDEAS_MIRROR_TOTAL_TIMEOUT=30

ideas_mirror_error() {
  [[ "${IDEAS_MIRROR_QUIET:-false}" == "true" ]] && return 1
  printf 'mirror: %s\n' "$*" >&2
  return 1
}

# Populates IDEAS_MIRROR_ENABLED, IDEAS_MIRROR_URL, and
# IDEAS_MIRROR_API_KEY_ENV. The configuration file itself is the only input
# inspected when mirroring is disabled.
ideas_mirror_read_config() {
  local config_file="$1" mirror_type
  IDEAS_MIRROR_ENABLED=false
  IDEAS_MIRROR_URL=""
  IDEAS_MIRROR_API_KEY_ENV=""

  [[ -r "$config_file" && -f "$config_file" ]] \
    || { ideas_mirror_error "configuration is not a readable regular file"; return 1; }
  jq -e 'type == "object"' "$config_file" >/dev/null 2>&1 \
    || { ideas_mirror_error "configuration is not valid JSON"; return 1; }

  mirror_type="$(jq -r 'if (.storage? | type) == "object" and .storage.mirror? != null then (.storage.mirror | type) else "absent" end' "$config_file")"
  if [[ "$mirror_type" == "absent" ]]; then
    return 0
  fi
  [[ "$mirror_type" == "object" ]] \
    || { ideas_mirror_error "storage.mirror must be an object"; return 1; }
  jq -e '
    (.storage.mirror | keys | sort) == ["api_key_env", "enabled", "url"]
    and (.storage.mirror.enabled | type) == "boolean"
    and (.storage.mirror.url | type) == "string"
    and (.storage.mirror.api_key_env | type) == "string"
  ' "$config_file" >/dev/null 2>&1 \
    || { ideas_mirror_error "storage.mirror has invalid or unknown properties"; return 1; }

  IDEAS_MIRROR_ENABLED="$(jq -r '.storage.mirror.enabled' "$config_file")"
  IDEAS_MIRROR_URL="$(jq -r '.storage.mirror.url' "$config_file")"
  IDEAS_MIRROR_API_KEY_ENV="$(jq -r '.storage.mirror.api_key_env' "$config_file")"
}

ideas_mirror_validate_config() {
  local url="${1:-$IDEAS_MIRROR_URL}" api_key_env="${2:-$IDEAS_MIRROR_API_KEY_ENV}"
  local scheme authority host
  [[ "$url" =~ ^(https?)://([^/?#]+)([^#]*)$ ]] \
    || { ideas_mirror_error "URL must use lowercase http or https with an authority and no fragment"; return 1; }
  scheme="${BASH_REMATCH[1]}"
  authority="${BASH_REMATCH[2]}"
  [[ "$authority" != *"@"* && ! "$authority" =~ [[:space:]] ]] \
    || { ideas_mirror_error "URL authority must not contain user information or whitespace"; return 1; }
  [[ "$url" != *$'\r'* && "$url" != *$'\n'* ]] \
    || { ideas_mirror_error "URL contains invalid characters"; return 1; }
  if [[ "$scheme" != "https" ]]; then
    # The mirror sends a bearer API key on every request; http:// would put
    # that credential on the wire in plaintext. Only exempt loopback, for
    # local development against a mirror running on the same machine.
    host="${authority%%:*}"
    [[ "$host" == "localhost" || "$host" == "127.0.0.1" || "$host" == "::1" ]] \
      || { ideas_mirror_error "http:// is only permitted for localhost/127.0.0.1/::1; use https:// for any other host"; return 1; }
  fi
  [[ "$api_key_env" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || { ideas_mirror_error "api_key_env is not a valid environment-variable name"; return 1; }
}

ideas_mirror_repository_identifier() {
  local repo="$1" origin="" fallback scheme scheme_lower remainder authority path sanitized
  fallback="$(basename "$(cd "$repo" 2>/dev/null && pwd -P)")" \
    || { ideas_mirror_error "repository is not a directory"; return 1; }
  origin="$(git -C "$repo" config --get remote.origin.url 2>/dev/null || true)"
  [[ -n "$origin" && ! "$origin" =~ [[:space:]] ]] || { printf '%s' "$fallback"; return 0; }

  if [[ "$origin" =~ ^([A-Za-z][A-Za-z0-9+.-]*)://(.*)$ ]]; then
    scheme="${BASH_REMATCH[1]}"
    scheme_lower="$(printf '%s' "$scheme" | tr '[:upper:]' '[:lower:]')"
    remainder="${BASH_REMATCH[2]}"
    [[ "$scheme_lower" != "file" ]] || { printf '%s' "$fallback"; return 0; }
    remainder="${remainder%%#*}"
    remainder="${remainder%%\?*}"
    authority="${remainder%%/*}"
    if [[ "$remainder" == */* ]]; then path="/${remainder#*/}"; else path=""; fi
    authority="${authority##*@}"
    [[ -n "$authority" && "$authority" != *"@"* && ! "$authority" =~ [[:space:]] ]] \
      || { printf '%s' "$fallback"; return 0; }
    if [[ "$authority" == \[* ]]; then
      [[ "$authority" =~ ^\[[0-9A-Fa-f:.]+\](:[0-9]+)?$ ]] \
        || { printf '%s' "$fallback"; return 0; }
    else
      [[ "$authority" =~ ^[A-Za-z0-9._~-]+(:[0-9]+)?$ ]] \
        || { printf '%s' "$fallback"; return 0; }
    fi
    sanitized="$scheme://$authority$path"
    [[ -n "$sanitized" ]] || sanitized="$fallback"
    printf '%s' "$sanitized"
    return 0
  fi

  origin="${origin%%#*}"
  origin="${origin%%\?*}"
  if [[ "$origin" =~ ^([^@:/]+@)([^@:/]+):(.+)$ ]]; then
    sanitized="${BASH_REMATCH[2]}:${BASH_REMATCH[3]}"
    [[ -n "$sanitized" && "$sanitized" != *"@"* ]] || sanitized="$fallback"
    printf '%s' "$sanitized"
    return 0
  fi
  # Scheme-like values without // are authority-less URLs, not safe remotes.
  printf '%s' "$fallback"
}

# Writes a complete payload to the caller-provided file. The caller owns that
# file; all internal staging files are private and removed before return.
ideas_mirror_build_payload() (
  local repo="$1" payload_file="$2" events_file ideas_dir identifier timestamp
  local line idea_file
  local -a idea_files=()
  umask 077
  IDEAS_MIRROR_TMP_EVENTS="$(mktemp "${TMPDIR:-/tmp}/e3d-mirror-events.XXXXXX")" || exit 1
  IDEAS_MIRROR_TMP_IDEAS="$(mktemp "${TMPDIR:-/tmp}/e3d-mirror-ideas.XXXXXX")" || { rm -f "$IDEAS_MIRROR_TMP_EVENTS"; exit 1; }
  trap 'rm -f "$IDEAS_MIRROR_TMP_EVENTS" "$IDEAS_MIRROR_TMP_IDEAS"' EXIT HUP INT TERM

  events_file="$repo/.e3d-pilot/events.jsonl"
  ideas_dir="$repo/.e3d-pilot/ideas"
  if [[ -e "$events_file" ]]; then
    [[ -f "$events_file" && -r "$events_file" && ! -L "$events_file" ]] \
      || { ideas_mirror_error "events ledger is not a readable regular file"; exit 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      printf '%s\n' "$line" | jq -es 'length == 1' >/dev/null 2>&1 \
        || { ideas_mirror_error "events ledger contains invalid JSON"; exit 1; }
    done < "$events_file"
    jq -s '.' "$events_file" > "$IDEAS_MIRROR_TMP_EVENTS" \
      || { ideas_mirror_error "could not read events ledger"; exit 1; }
  else
    printf '[]\n' > "$IDEAS_MIRROR_TMP_EVENTS"
  fi

  if [[ -d "$ideas_dir" ]]; then
    LC_ALL=C
    for idea_file in "$ideas_dir"/*/idea.json; do
      [[ -e "$idea_file" ]] || continue
      [[ -f "$idea_file" && -r "$idea_file" && ! -L "$idea_file" ]] \
        || { ideas_mirror_error "an idea snapshot is not a readable regular file"; exit 1; }
      jq -e 'true' "$idea_file" >/dev/null 2>&1 \
        || { ideas_mirror_error "an idea snapshot contains invalid JSON"; exit 1; }
      [[ "$(jq -s 'length' "$idea_file" 2>/dev/null)" == "1" ]] \
        || { ideas_mirror_error "an idea snapshot must contain one JSON value"; exit 1; }
      idea_files+=("$idea_file")
    done
  elif [[ -e "$ideas_dir" ]]; then
    ideas_mirror_error "ideas path is not a directory" || true
    exit 1
  fi
  if (( ${#idea_files[@]} > 0 )); then
    jq -s '.' "${idea_files[@]}" > "$IDEAS_MIRROR_TMP_IDEAS" \
      || { ideas_mirror_error "could not read idea snapshots"; exit 1; }
  else
    printf '[]\n' > "$IDEAS_MIRROR_TMP_IDEAS"
  fi

  identifier="$(ideas_mirror_repository_identifier "$repo")" || exit 1
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  jq -nS \
    --arg identifier "$identifier" \
    --arg mirrored_at "$timestamp" \
    --slurpfile events "$IDEAS_MIRROR_TMP_EVENTS" \
    --slurpfile ideas "$IDEAS_MIRROR_TMP_IDEAS" \
    '{schema_version:1,repository:{identifier:$identifier},mirrored_at:$mirrored_at,events:$events[0],ideas:$ideas[0]}' \
    > "$payload_file" || { ideas_mirror_error "could not build payload"; exit 1; }
  chmod 600 "$payload_file"
)

ideas_mirror_post_payload() (
  local url="$1" api_key="$2" payload_file="$3" status curl_status escaped_key
  umask 077
  # `curl --header "@file"` does not exist -- `@file` is only meaningful to
  # curl's data-family options (-d/--data-binary/etc). Written that way, curl
  # sends a literal header line reading "@/tmp/...", not the resolved bearer
  # token, so the request is never actually authenticated. Keeping the
  # Authorization header out of argv (so it can't appear in a `ps` snapshot
  # of this process) while it's still a real header requires curl's own
  # -K/--config file mechanism instead.
  IDEAS_MIRROR_TMP_CURL_CONFIG="$(mktemp "${TMPDIR:-/tmp}/e3d-mirror-curlrc.XXXXXX")" || exit 1
  trap 'rm -f "$IDEAS_MIRROR_TMP_CURL_CONFIG"' EXIT HUP INT TERM
  escaped_key="${api_key//\\/\\\\}"
  escaped_key="${escaped_key//\"/\\\"}"
  {
    printf 'header = "Content-Type: application/json"\n'
    printf 'header = "Authorization: Bearer %s"\n' "$escaped_key"
  } > "$IDEAS_MIRROR_TMP_CURL_CONFIG"
  chmod 600 "$IDEAS_MIRROR_TMP_CURL_CONFIG"

  set +e
  status="$(curl \
    --config "$IDEAS_MIRROR_TMP_CURL_CONFIG" \
    --silent --show-error \
    --request POST \
    --data-binary "@$payload_file" \
    --output /dev/null \
    --write-out '%{http_code}' \
    --max-redirs 0 \
    --retry 0 \
    --connect-timeout "$IDEAS_MIRROR_CONNECT_TIMEOUT" \
    --max-time "$IDEAS_MIRROR_TOTAL_TIMEOUT" \
    "$url")"
  curl_status=$?
  set -e
  if (( curl_status != 0 )); then
    ideas_mirror_error "request failed" || true
    exit 1
  fi
  [[ "$status" =~ ^2[0-9][0-9]$ ]] \
    || { ideas_mirror_error "server returned HTTP ${status:-unknown}"; exit 1; }
)

# Mode is "strict" for an on-demand invocation and "best-effort" for an
# automatic post-publication attempt. Best-effort failures are warning-only.
ideas_mirror_run() (
  local repo="$1" mode="${2:-strict}" config_file="${3:-$1/.e3d-pilot/config.json}"
  local api_key failure=""
  [[ "$mode" == "strict" || "$mode" == "best-effort" ]] \
    || { ideas_mirror_error "mode must be strict or best-effort"; exit 1; }
  [[ "$mode" == "best-effort" ]] && IDEAS_MIRROR_QUIET=true
  umask 077
  IDEAS_MIRROR_TMP_PAYLOAD=""
  trap '[[ -z "$IDEAS_MIRROR_TMP_PAYLOAD" ]] || rm -f "$IDEAS_MIRROR_TMP_PAYLOAD"' EXIT HUP INT TERM

  if ! ideas_mirror_read_config "$config_file"; then
    failure="invalid configuration"
  elif [[ "$IDEAS_MIRROR_ENABLED" != "true" ]]; then
    if [[ "$mode" == "strict" ]]; then
      ideas_mirror_error "mirroring is not enabled" || true
      exit 1
    fi
    exit 0
  elif ! ideas_mirror_validate_config "$IDEAS_MIRROR_URL" "$IDEAS_MIRROR_API_KEY_ENV"; then
    failure="invalid configuration"
  else
    api_key="$(printenv "$IDEAS_MIRROR_API_KEY_ENV" 2>/dev/null || true)"
    if [[ -z "$api_key" ]]; then
      # Bare `|| true`: ideas_mirror_error always returns 1 by contract, and
      # under this file's global set -e that would otherwise abort right
      # here -- before `failure` is even set, let alone reaching the
      # best-effort-vs-strict dispatch below. A best-effort mirror attempt
      # failing this way would silently propagate and fail an otherwise
      # successful publish, which best-effort mode exists specifically to
      # never do.
      ideas_mirror_error "configured credential is missing or empty" || true
      failure="missing credential"
    elif [[ "$api_key" == *$'\r'* || "$api_key" == *$'\n'* ]]; then
      ideas_mirror_error "configured credential contains invalid characters" || true
      failure="invalid credential"
    else
      IDEAS_MIRROR_TMP_PAYLOAD="$(mktemp "${TMPDIR:-/tmp}/e3d-mirror-payload.XXXXXX")" || failure="temporary file creation failed"
      if [[ -z "$failure" ]]; then
        chmod 600 "$IDEAS_MIRROR_TMP_PAYLOAD"
        ideas_mirror_build_payload "$repo" "$IDEAS_MIRROR_TMP_PAYLOAD" || failure="payload validation failed"
      fi
      if [[ -z "$failure" ]]; then
        ideas_mirror_post_payload "$IDEAS_MIRROR_URL" "$api_key" "$IDEAS_MIRROR_TMP_PAYLOAD" || failure="transport failed"
      fi
    fi
  fi

  if [[ -n "$failure" ]]; then
    if [[ "$mode" == "best-effort" ]]; then
      printf 'mirror: warning: mirror attempt failed (%s)\n' "$failure" >&2
      exit 0
    fi
    exit 1
  fi
)
