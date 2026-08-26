#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"
COLLECTOR="$ROOT/lib/ops/collect-fleet-health.sh"
SAMPLE_CONFIG="$ROOT/examples/sample-fleet-config-with-ops.json"

assert_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] || {
    printf 'expected to find %q in output\n' "$needle" >&2
    exit 1
  }
}

assert_not_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" != *"$needle"* ]] || {
    printf 'did not expect to find %q in output\n' "$needle" >&2
    exit 1
  }
}

assert_eq() {
  local actual="$1" expected="$2" msg="${3:-}"
  [[ "$actual" == "$expected" ]] || {
    printf 'expected %q, got %q (%s)\n' "$expected" "$actual" "$msg" >&2
    exit 1
  }
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

make_repo() {
  local name="$1" repo
  repo="$(mktemp -d "$TMP_ROOT/${name}.XXXXXX")"
  git init -q "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name 'Test User'
  printf '# %s\n' "$name" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m initial
  printf '%s' "$repo"
}

make_curl_stub() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
trace="${PHASE27_CURL_TRACE_FILE:?}"
status_file="${PHASE27_CURL_STATUS_FILE:?}"
body_file="${PHASE27_CURL_BODY_FILE:?}"
count_file="${PHASE27_CURL_COUNT_FILE:?}"
call=0
if [[ -f "$count_file" ]]; then
  call="$(<"$count_file")"
fi
call=$((call + 1))
printf '%s' "$call" > "$count_file"
{
  printf 'CALL %s\n' "$call"
  idx=1
  prev=""
  for arg in "$@"; do
    if [[ "$prev" == "-H" || "$prev" == "--header" ]]; then
      printf 'ARG %s: Authorization: Bot [REDACTED]\n' "$idx"
    else
      printf 'ARG %s: %s\n' "$idx" "$arg"
    fi
    prev="$arg"
    idx=$((idx + 1))
  done
} >> "$trace"
status_line="$(sed -n "${call}p" "$status_file")"
body_line="$(sed -n "${call}p" "$body_file")"
[[ -n "$status_line" ]] || { printf 'missing response for call %s\n' "$call" >&2; exit 99; }
IFS='|' read -r exit_code http_code time_total <<<"$status_line"
output_file=""
write_format=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-w" || "$prev" == "--write-out" ]]; then
    write_format="$arg"
  fi
  if [[ "$prev" == "-o" || "$prev" == "--output" ]]; then
    output_file="$arg"
  fi
  prev="$arg"
done
if [[ -n "$output_file" && "$output_file" != "/dev/null" ]]; then
  printf '%s' "$body_line" > "$output_file"
fi
if [[ "$write_format" == *'%{time_total}'* ]]; then
  printf '%s\t%s\n' "$http_code" "$time_total"
else
  printf '%s\n' "$http_code"
fi
exit "$exit_code"
EOF
  chmod +x "$bin_dir/curl"
}

make_provider_bins() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat > /dev/null
cat <<'OUT'
### Cross-Repo Opportunities
- repo-a + repo-b: surface live operations signals in the shared fleet view.
### Analogous Patterns
- social feed and notification mechanics: reuse alerting mechanics for operators.
OUT
EOF
  cat > "$bin_dir/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat > /dev/null
cat <<'OUT'
### Candidate 1: Shared ops dashboard
Repos: repo-a, repo-b
Duplicate: no
Dedup rationale: fixture candidate.
Analogy: developer-tool CLI ergonomics -- surface status where operators already look.
Attraction (1-5): 4
Retention (1-5): 4
Effort: low
Revenue (1-5|n/a): 2
Description: Combine repo-a and repo-b operational signals in one view.

---IDEATE-STATUS---
selected: candidate-1
reason: fixture candidate
OUT
EOF
  chmod +x "$bin_dir/claude" "$bin_dir/codex"
}

write_lines() {
  local file="$1"; shift
  : > "$file"
  while [[ $# -gt 0 ]]; do
    printf '%s\n' "$1" >> "$file"
    shift
  done
}

write_config() {
  local file="$1" expr="${2:-.}"
  jq "$expr" "$SAMPLE_CONFIG" > "$file"
}

collector_live_instance_cases() {
  local config_file curl_bin trace_file status_file body_file count_file out repo_config
  repo_config="$(mktemp "$TMP_ROOT/live-config.XXXXXX.json")"
  jq '
    .live_instances = [
      {name:"Line 1\r\nLine 2", url:"https://healthy.example.com/health"},
      {name:"Slow 200", url:"https://slow.example.com/health"},
      {name:"Created 201", url:"https://created.example.com/health"},
      {name:"Redirect 302", url:"https://redirect.example.com/health"},
      {name:"Zero 000", url:"https://zero.example.com/health"},
      {name:"Informational 101", url:"https://info.example.com/health"},
      {name:"Client 404", url:"https://client.example.com/health"},
      {name:"Server 500", url:"https://server.example.com/health"},
      {name:"Range 699", url:"https://range.example.com/health"},
      {name:"Timeout", url:"https://timeout.example.com/health"},
      {name:"Conn refused", url:"https://refused.example.com/health"},
      {name:"DNS fail", url:"https://dns.example.com/health"},
      {name:"Unknown fail", url:"https://unknown.example.com/health"},
      {name:"Invalid elapsed", url:"https://invalid-elapsed.example.com/health"},
      {name:"Invalid status", url:"https://invalid-status.example.com/health"},
      {name:"Unavailable latency", url:"https://unavailable.example.com/health"}
    ]
    | del(.social_accounts)
  ' "$SAMPLE_CONFIG" > "$repo_config"

  curl_bin="$(mktemp -d "$TMP_ROOT/curl-bin-live.XXXXXX")"
  trace_file="$(mktemp "$TMP_ROOT/live-trace.XXXXXX")"
  status_file="$(mktemp "$TMP_ROOT/live-status.XXXXXX")"
  body_file="$(mktemp "$TMP_ROOT/live-body.XXXXXX")"
  count_file="$(mktemp "$TMP_ROOT/live-count.XXXXXX")"
  make_curl_stub "$curl_bin"
  export PATH="$curl_bin:$PATH"
  export PHASE27_CURL_TRACE_FILE="$trace_file"
  export PHASE27_CURL_STATUS_FILE="$status_file"
  export PHASE27_CURL_BODY_FILE="$body_file"
  export PHASE27_CURL_COUNT_FILE="$count_file"

  write_lines "$status_file" \
    '0|200|1.234567' \
    '0|200|2.000000' \
    '0|201|0.050000' \
    '0|302|0.100000' \
    '0|000|0.100000' \
    '0|101|0.100000' \
    '0|404|0.100000' \
    '0|500|0.100000' \
    '0|699|0.100000' \
    '28|200|2.500000' \
    '7|200|0.100000' \
    '6|200|0.200000' \
    '35|418|0.300000' \
    '0|200|bogus' \
    '0|abc|0.123' \
    '7|503|bogus'
  write_lines "$body_file" \
    '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' ''

  out="$(PATH="$curl_bin:$PATH" "$COLLECTOR" "$repo_config")"
  assert_not_contains "$out" '## Live Operations'
  assert_contains "$out" '### Live Instance Status'
  assert_contains "$out" 'Line 1 Line 2'
  assert_contains "$out" 'healthy — HTTP 200, 1234ms'
  assert_contains "$out" 'degraded — HTTP 200, 2000ms'
  assert_contains "$out" 'degraded — HTTP 201, 50ms'
  assert_contains "$out" 'degraded — HTTP 302, 100ms'
  assert_contains "$out" 'down — HTTP 000, 100ms'
  assert_contains "$out" 'down — HTTP 101, 100ms'
  assert_contains "$out" 'down — HTTP 404, 100ms'
  assert_contains "$out" 'down — HTTP 500, 100ms'
  assert_contains "$out" 'down — HTTP 699, 100ms'
  assert_contains "$out" 'down — HTTP timeout, 2500ms'
  assert_contains "$out" 'down — HTTP connection-refused, unavailable'
  assert_contains "$out" 'down — HTTP dns-error, 200ms'
  assert_contains "$out" 'down — HTTP unknown-error, 300ms'
  assert_contains "$out" 'down — HTTP invalid-curl-output, unavailable'
  assert_contains "$out" 'down — HTTP invalid-curl-output, 123ms'
  assert_contains "$out" 'down — HTTP connection-refused, unavailable'
  assert_eq "$(grep -c '^CALL ' "$trace_file" || true)" "16" "one request per live instance"
  assert_eq "$(grep -c '^ARG 1: -sS$' "$trace_file" || true)" "16" "-sS present"
  assert_eq "$(grep -c '^ARG 2: -L$' "$trace_file" || true)" "16" "-L present"
  assert_eq "$(grep -c '^ARG 3: -o$' "$trace_file" || true)" "16" "-o present"
  assert_eq "$(grep -c '^ARG 4: /dev/null$' "$trace_file" || true)" "16" "live body discarded"
  assert_eq "$(grep -c '^ARG 5: -w$' "$trace_file" || true)" "16" "write flag present"
  assert_eq "$(grep -c '^ARG 7: --max-time$' "$trace_file" || true)" "16" "max-time flag present"
  assert_eq "$(grep -c '^ARG 9: --max-redirs$' "$trace_file" || true)" "16" "max-redirs flag present"
  assert_eq "$(grep -c '^ARG 11: --proto$' "$trace_file" || true)" "16" "proto flag present"
  assert_eq "$(grep -c '^ARG 13: --proto-redir$' "$trace_file" || true)" "16" "proto-redir flag present"
  assert_eq "$(grep -c '^ARG 15: --request$' "$trace_file" || true)" "16" "request flag present"
  assert_eq "$(grep -c '^ARG 17: --$' "$trace_file" || true)" "16" "url terminator present"
  assert_eq "$(grep -c '^ARG 18: https://.*example.com/health$' "$trace_file" || true)" "16" "url follows --"
}

collector_validation_cases() {
  local config_file curl_bin trace_file status_file body_file count_file out status expr
  config_file="$(mktemp "$TMP_ROOT/invalid-config.XXXXXX.json")"
  curl_bin="$(mktemp -d "$TMP_ROOT/curl-bin-invalid.XXXXXX")"
  trace_file="$(mktemp "$TMP_ROOT/invalid-trace.XXXXXX")"
  status_file="$(mktemp "$TMP_ROOT/invalid-status.XXXXXX")"
  body_file="$(mktemp "$TMP_ROOT/invalid-body.XXXXXX")"
  count_file="$(mktemp "$TMP_ROOT/invalid-count.XXXXXX")"
  make_curl_stub "$curl_bin"
  export PATH="$curl_bin:$PATH"
  export PHASE27_CURL_TRACE_FILE="$trace_file"
  export PHASE27_CURL_STATUS_FILE="$status_file"
  export PHASE27_CURL_BODY_FILE="$body_file"
  export PHASE27_CURL_COUNT_FILE="$count_file"
  write_lines "$status_file" '0|200|0.1'
  write_lines "$body_file" ''

  write_config "$config_file" '.live_instances = 1'
  set +e
  out="$(PATH="$curl_bin:$PATH" "$COLLECTOR" "$config_file" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "expected live_instances type failure" >&2; exit 1; }
  assert_contains "$out" 'live_instances'
  assert_eq "$(grep -c '^CALL ' "$trace_file" || true)" "0" "no curl on invalid live_instances type"

  local -a live_exprs=(
    '.live_instances = [{"name":"A","url":"https://a.example.com/health","extra":1}]'
    '.live_instances = [{"name":"","url":"https://a.example.com/health"}]'
    '.live_instances = [{"name":"A"}]'
    '.live_instances = [{"name":"A","url":""}]'
    '.live_instances = [{"name":"A","url":"ftp://a.example.com/health"}]'
    '.live_instances = [{"name":"A","url":"https:///health"}]'
    '.live_instances = [{"name":"A","url":"https://user@a.example.com/health"}]'
  )
  for expr in "${live_exprs[@]}"; do
    : > "$trace_file"
    write_config "$config_file" "$expr"
    set +e
    out="$(PATH="$curl_bin:$PATH" "$COLLECTOR" "$config_file" 2>&1)"
    status=$?
    set -e
    [[ $status -ne 0 ]] || { printf 'expected failure for %s\n' "$expr" >&2; exit 1; }
    assert_contains "$out" 'live_instances'
    assert_eq "$(grep -c '^CALL ' "$trace_file" || true)" "0" "no curl on invalid live config"
  done

  local -a social_exprs=(
    '.social_accounts = 1'
    '.social_accounts = [{"platform":"discord","name":"A","channel_id":"1","bot_user_id":"2","extra":1}]'
    '.social_accounts = [{"platform":"discord","name":"","channel_id":"1","bot_user_id":"2"}]'
    '.social_accounts = [{"platform":"discord","name":"A","channel_id":"","bot_user_id":"2"}]'
    '.social_accounts = [{"platform":"discord","name":"A","channel_id":"1","bot_user_id":""}]'
    '.social_accounts = [{"name":"A","channel_id":"1","bot_user_id":"2"}]'
    '.social_accounts = [{"platform":"slack","name":"A","channel_id":"1","bot_user_id":"2"}]'
  )
  for expr in "${social_exprs[@]}"; do
    : > "$trace_file"
    write_config "$config_file" "$expr"
    set +e
    out="$(PATH="$curl_bin:$PATH" "$COLLECTOR" "$config_file" 2>&1)"
    status=$?
    set -e
    [[ $status -ne 0 ]] || { printf 'expected failure for %s\n' "$expr" >&2; exit 1; }
    assert_contains "$out" 'social_accounts'
    assert_eq "$(grep -c '^CALL ' "$trace_file" || true)" "0" "no curl on invalid social config"
  done

  local repo fleet_dir fleet_file bad_config
  repo="$(make_repo repo-a)"
  fleet_dir="$(mktemp -d "$TMP_ROOT/fleet-invalid.XXXXXX")"
  fleet_file="$fleet_dir/fleet.json"
  jq -n --arg repo "$repo" '[$repo]' > "$fleet_file"
  bad_config="$(mktemp "$TMP_ROOT/fleet-bad-config.XXXXXX.json")"
  write_config "$bad_config" '.live_instances = [{"name":"Healthy","url":"https://healthy.example.com"}] | .social_accounts = [{"platform":"discord","name":"A","channel_id":"1","bot_user_id":"2","extra":1}]'
  : > "$trace_file"
  set +e
  out="$(PATH="$curl_bin:$PATH" "$BIN" fleet discover "$fleet_file" --config "$bad_config" --run-id phase27-invalid 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "expected fleet discover validation failure" >&2; exit 1; }
  assert_contains "$out" 'social_accounts'
  assert_eq "$(grep -c '^CALL ' "$trace_file" || true)" "0" "fleet discover validates before requests"
}

collector_discord_cases() {
  local config_file curl_bin trace_file status_file body_file count_file out status token
  token='super-secret-token'
  config_file="$(mktemp "$TMP_ROOT/discord-config.XXXXXX.json")"
  jq '
    .live_instances = []
    | .social_accounts = [
        {platform:"discord", name:"Empty reactions", channel_id:"111", bot_user_id:"bot-1"},
        {platform:"discord", name:"Omitted reactions", channel_id:"222", bot_user_id:"bot-2"},
        {platform:"discord", name:"Null reactions", channel_id:"333", bot_user_id:"bot-3"},
        {platform:"discord", name:"No match", channel_id:"444", bot_user_id:"bot-4"},
        {platform:"discord", name:"Trimmed top ten", channel_id:"555", bot_user_id:"bot-5"},
        {platform:"discord", name:"Collection failure", channel_id:"666", bot_user_id:"bot-6"},
        {platform:"discord", name:"HTTP 503", channel_id:"777", bot_user_id:"bot-7"},
        {platform:"discord", name:"Malformed JSON", channel_id:"888", bot_user_id:"bot-8"},
        {platform:"discord", name:"Invalid payload", channel_id:"999", bot_user_id:"bot-9"}
      ]
  ' "$SAMPLE_CONFIG" > "$config_file"

  curl_bin="$(mktemp -d "$TMP_ROOT/curl-bin-discord.XXXXXX")"
  trace_file="$(mktemp "$TMP_ROOT/discord-trace.XXXXXX")"
  status_file="$(mktemp "$TMP_ROOT/discord-status.XXXXXX")"
  body_file="$(mktemp "$TMP_ROOT/discord-body.XXXXXX")"
  count_file="$(mktemp "$TMP_ROOT/discord-count.XXXXXX")"
  make_curl_stub "$curl_bin"
  export PATH="$curl_bin:$PATH"
  export PHASE27_CURL_TRACE_FILE="$trace_file"
  export PHASE27_CURL_STATUS_FILE="$status_file"
  export PHASE27_CURL_BODY_FILE="$body_file"
  export PHASE27_CURL_COUNT_FILE="$count_file"

  jq -nc '
    [
      [{"author":{"id":"bot-1"},"reactions":[] }],
      [{"author":{"id":"bot-2"}}],
      [{"author":{"id":"bot-3"},"reactions":null}],
      [{"author":{"id":"other"},"reactions":[{"count":7}]}],
      [
        {"author":{"id":"bot-5"},"reactions":[{"count":1}]},
        {"author":{"id":"bot-5"},"reactions":[{"count":1}]},
        {"author":{"id":"bot-5"},"reactions":[{"count":1}]},
        {"author":{"id":"bot-5"},"reactions":[{"count":1}]},
        {"author":{"id":"bot-5"},"reactions":[{"count":1}]},
        {"author":{"id":"bot-5"},"reactions":[{"count":1}]},
        {"author":{"id":"bot-5"},"reactions":[{"count":1}]},
        {"author":{"id":"bot-5"},"reactions":[{"count":1}]},
        {"author":{"id":"bot-5"},"reactions":[{"count":1}]},
        {"author":{"id":"bot-5"},"reactions":[{"count":1}]},
        {"author":{"id":"bot-5"},"reactions":[{"count":50}]}
      ],
      [{"author":{"id":"bot-6"},"reactions":[{"count":1}]}],
      [{"author":{"id":"bot-7"},"reactions":[{"count":1}]}],
      "not-json",
      [{"author":{"id":"bot-9"},"reactions":[{"count":-1}]}]
    ]
    | map(tostring)
    | .[]
  ' >/dev/null 2>&1 || true

  write_lines "$status_file" \
    '0|200|0.100000' \
    '0|200|0.200000' \
    '0|200|0.300000' \
    '0|200|0.400000' \
    '0|200|0.500000' \
    '28|200|0.100000' \
    '0|503|0.600000' \
    '0|200|0.700000' \
    '0|200|0.800000'
  write_lines "$body_file" \
    '[{"author":{"id":"bot-1"},"reactions":[]}]' \
    '[{"author":{"id":"bot-2"}}]' \
    '[{"author":{"id":"bot-3"},"reactions":null}]' \
    '[{"author":{"id":"other"},"reactions":[{"count":7}]}]' \
    '[{"author":{"id":"bot-5"},"reactions":[{"count":1}]},{"author":{"id":"bot-5"},"reactions":[{"count":1}]},{"author":{"id":"bot-5"},"reactions":[{"count":1}]},{"author":{"id":"bot-5"},"reactions":[{"count":1}]},{"author":{"id":"bot-5"},"reactions":[{"count":1}]},{"author":{"id":"bot-5"},"reactions":[{"count":1}]},{"author":{"id":"bot-5"},"reactions":[{"count":1}]},{"author":{"id":"bot-5"},"reactions":[{"count":1}]},{"author":{"id":"bot-5"},"reactions":[{"count":1}]},{"author":{"id":"bot-5"},"reactions":[{"count":1}]},{"author":{"id":"bot-5"},"reactions":[{"count":50}]}]' \
    '{"author":{"id":"bot-6"},"reactions":[{"count":1}]}' \
    'not-json' \
    '[{"author":{"id":"bot-9"},"reactions":[{"count":-1}]}]'

  DISCORD_BOT_TOKEN="$token" out="$(PATH="$curl_bin:$PATH" DISCORD_BOT_TOKEN="$token" "$COLLECTOR" "$config_file")"
  assert_contains "$out" '### Social Engagement'
  assert_contains "$out" 'Empty reactions'
  assert_contains "$out" '1 recent messages, 0 total reactions'
  assert_contains "$out" 'Omitted reactions'
  assert_contains "$out" 'Null reactions'
  assert_contains "$out" 'No match'
  assert_contains "$out" 'no recent messages found'
  assert_contains "$out" 'Trimmed top ten'
  assert_contains "$out" '10 recent messages, 10 total reactions'
  assert_contains "$out" 'Collection failure'
  assert_contains "$out" 'collection failure — HTTP timeout'
  assert_contains "$out" 'HTTP 503'
  assert_contains "$out" 'collection failure — invalid Discord payload'
  assert_eq "$(grep -c '^CALL ' "$trace_file" || true)" "9" "one request per credentialed Discord account"
  assert_contains "$(cat "$trace_file")" 'Authorization: Bot [REDACTED]'
  assert_not_contains "$(cat "$trace_file")" "$token"
  local previous_line=0 name line_no
  for name in 'Empty reactions' 'Omitted reactions' 'Null reactions' 'No match' 'Trimmed top ten' 'Collection failure' 'HTTP 503' 'Malformed JSON' 'Invalid payload'; do
    line_no="$(printf '%s\n' "$out" | grep -n "$name" | head -n1 | cut -d: -f1)"
    [[ -n "$line_no" ]] || { printf 'missing %s in Discord output\n' "$name" >&2; exit 1; }
    [[ "$line_no" -gt "$previous_line" ]] || { printf 'Discord output order violated at %s\n' "$name" >&2; exit 1; }
    previous_line="$line_no"
  done

  : > "$trace_file"
  unset DISCORD_BOT_TOKEN
  out="$(PATH="$curl_bin:$PATH" "$COLLECTOR" "$config_file")"
  assert_contains "$out" 'collection failure — DISCORD_BOT_TOKEN not set'
  assert_eq "$(grep -c '^CALL ' "$trace_file" || true)" "0" "no Discord requests without a token"

  : > "$trace_file"
  DISCORD_BOT_TOKEN='' out="$(PATH="$curl_bin:$PATH" DISCORD_BOT_TOKEN='' "$COLLECTOR" "$config_file")"
  assert_contains "$out" 'collection failure — DISCORD_BOT_TOKEN not set'
  assert_eq "$(grep -c '^CALL ' "$trace_file" || true)" "0" "no Discord requests with empty token"
}

collector_empty_sections_and_prompt_recommendations() {
  local repo_a repo_b fleet_dir fleet_file config_file curl_bin trace_file status_file body_file count_file provider_bin out status findings prompt
  repo_a="$(make_repo repo-a)"
  repo_b="$(make_repo repo-b)"
  fleet_dir="$(mktemp -d "$TMP_ROOT/fleet.XXXXXX")"
  fleet_file="$fleet_dir/fleet.json"
  jq -n --arg a "$repo_a" --arg b "$repo_b" '[$a,$b]' > "$fleet_file"

  provider_bin="$(mktemp -d "$TMP_ROOT/provider-bin.XXXXXX")"
  make_provider_bins "$provider_bin"
  curl_bin="$(mktemp -d "$TMP_ROOT/curl-bin-prompt.XXXXXX")"
  trace_file="$(mktemp "$TMP_ROOT/prompt-trace.XXXXXX")"
  status_file="$(mktemp "$TMP_ROOT/prompt-status.XXXXXX")"
  body_file="$(mktemp "$TMP_ROOT/prompt-body.XXXXXX")"
  count_file="$(mktemp "$TMP_ROOT/prompt-count.XXXXXX")"
  make_curl_stub "$curl_bin"
  export PATH="$curl_bin:$provider_bin:$PATH"
  export PHASE27_CURL_TRACE_FILE="$trace_file"
  export PHASE27_CURL_STATUS_FILE="$status_file"
  export PHASE27_CURL_BODY_FILE="$body_file"
  export PHASE27_CURL_COUNT_FILE="$count_file"

  config_file="$(mktemp "$TMP_ROOT/prompt-config.XXXXXX.json")"
  jq '
    .live_instances = []
    | .social_accounts = [
        {platform:"discord", name:"Zero engagement", channel_id:"1111", bot_user_id:"bot-zero"},
        {platform:"discord", name:"Collection failure", channel_id:"2222", bot_user_id:"bot-fail"},
        {platform:"discord", name:"Nonzero engagement", channel_id:"3333", bot_user_id:"bot-ok"},
        {platform:"discord", name:"No messages", channel_id:"4444", bot_user_id:"bot-none"}
      ]
  ' "$SAMPLE_CONFIG" > "$config_file"

  write_lines "$status_file" \
    '0|200|0.100000' \
    '0|200|0.200000' \
    '0|200|0.300000' \
    '0|200|0.400000'
  write_lines "$body_file" \
    '[{"author":{"id":"bot-zero"},"reactions":[{"count":0}]}]' \
    'not-json' \
    '[{"author":{"id":"bot-ok"},"reactions":[{"count":3}]}]' \
    '[{"author":{"id":"other"},"reactions":[{"count":3}]}]'

  out="$(PATH="$curl_bin:$provider_bin:$PATH" DISCORD_BOT_TOKEN='fixture-token' "$BIN" fleet discover "$fleet_file" --config "$config_file" --run-id phase27-prompt 2>&1)"
  assert_contains "$out" 'phase27-prompt'
  findings="$fleet_dir/.e3d-pilot-fleet/runs/phase27-prompt/findings.md"
  prompt="$fleet_dir/.e3d-pilot-fleet/runs/phase27-prompt/fleet-discover-prompt.md"
  assert_contains "$(cat "$findings")" '## Live Operations'
  assert_contains "$(cat "$findings")" '### Live Instance Status'
  assert_contains "$(cat "$findings")" 'No live instances configured.'
  assert_contains "$(cat "$findings")" '### Social Engagement'
  prompt_text="$(cat "$prompt")"
  assert_contains "$prompt_text" '### Operational Recommendations'
  recs_section="$(printf '%s\n' "$prompt_text" | sed -n '/^### Operational Recommendations$/,$p')"
  assert_contains "$recs_section" 'Zero engagement'
  assert_contains "$recs_section" 'collection failure — invalid Discord payload'
  assert_not_contains "$recs_section" 'healthy'
  assert_not_contains "$recs_section" 'Nonzero engagement'
  assert_not_contains "$recs_section" 'No messages'
  assert_eq "$(grep -c '^CALL ' "$trace_file" || true)" "4" "one request per credentialed Discord account"
  assert_contains "$(cat "$trace_file")" 'Authorization: Bot [REDACTED]'

  config_file="$(mktemp "$TMP_ROOT/live-prompt-config.XXXXXX.json")"
  jq '
    .live_instances = [
      {name:"Healthy", url:"https://healthy.example.com/health"},
      {name:"Degraded", url:"https://degraded.example.com/health"},
      {name:"Down", url:"https://down.example.com/health"}
    ]
    | .social_accounts = []
  ' "$SAMPLE_CONFIG" > "$config_file"
  write_lines "$status_file" \
    '0|200|1.000000' \
    '0|200|2.000000' \
    '0|503|0.300000'
  write_lines "$body_file" '' '' ''
  : > "$trace_file"
  : > "$count_file"
  out="$(PATH="$curl_bin:$provider_bin:$PATH" "$BIN" fleet discover "$fleet_file" --config "$config_file" --run-id phase27-live-prompt 2>&1)"
  assert_contains "$out" 'phase27-live-prompt'
  prompt="$fleet_dir/.e3d-pilot-fleet/runs/phase27-live-prompt/fleet-discover-prompt.md"
  prompt_text="$(cat "$prompt")"
  recs_section="$(printf '%s\n' "$prompt_text" | sed -n '/^### Operational Recommendations$/,$p')"
  assert_not_contains "$recs_section" 'Healthy'
  assert_contains "$recs_section" 'Degraded'
  assert_contains "$recs_section" 'Down'
  assert_contains "$recs_section" 'degraded'
  assert_contains "$recs_section" 'down'
  assert_not_contains "$recs_section" 'healthy'
  assert_eq "$(grep -c '^CALL ' "$trace_file" || true)" "3" "one request per live instance"

  config_file="$(mktemp "$TMP_ROOT/empty-config.XXXXXX.json")"
  write_config "$config_file" '.live_instances = [] | .social_accounts = []'
  : > "$trace_file"
  : > "$count_file"
  out="$(PATH="$curl_bin:$provider_bin:$PATH" "$BIN" fleet discover "$fleet_file" --config "$config_file" --run-id phase27-empty 2>&1)"
  assert_contains "$out" 'phase27-empty'
  findings="$fleet_dir/.e3d-pilot-fleet/runs/phase27-empty/findings.md"
  prompt="$fleet_dir/.e3d-pilot-fleet/runs/phase27-empty/fleet-discover-prompt.md"
  assert_contains "$(cat "$findings")" '## Live Operations'
  assert_contains "$(cat "$findings")" 'No live instances configured.'
  assert_not_contains "$(cat "$prompt")" $'\n### Operational Recommendations\n'
  assert_eq "$(grep -c '^CALL ' "$trace_file" || true)" "0" "no requests when both signals are empty"
}

main() {
  collector_live_instance_cases
  collector_validation_cases
  collector_discord_cases
  collector_empty_sections_and_prompt_recommendations
  echo 'phase27 ok'
}

main "$@"
