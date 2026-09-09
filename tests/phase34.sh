#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAMPLE_CONFIG="$ROOT/examples/sample-config.json"

# shellcheck source=../lib/ideas/mirror.sh
source "$ROOT/lib/ideas/mirror.sh"

TMP_ROOT="$(mktemp -d)"
TMPDIR="$TMP_ROOT"
export TMPDIR
ORIGINAL_PATH="$PATH"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'phase34: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-expected '$2', got '$1'}"; }

write_config() {
  local file="$1" enabled="$2" url="${3:-https://mirror.example.test/v1}" env_name="${4:-PHASE34_TOKEN}"
  jq -nc --argjson enabled "$enabled" --arg url "$url" --arg env "$env_name" \
    '{storage:{mirror:{enabled:$enabled,url:$url,api_key_env:$env}}}' > "$file"
}

make_repo() {
  local repo
  repo="$(mktemp -d "$TMP_ROOT/repo.XXXXXX")"
  git init -q "$repo"
  mkdir -p "$repo/.e3d-pilot"
  printf '%s' "$repo"
}

install_fake_curl() {
  local fake_bin="$TMP_ROOT/fake-bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=0
[[ -f "$FAKE_CURL_COUNT" ]] && count="$(cat "$FAKE_CURL_COUNT")"
printf '%s\n' "$((count + 1))" > "$FAKE_CURL_COUNT"
: > "$FAKE_CURL_ARGS"
auth_ok=false
body=""
while (( $# > 0 )); do
  arg="$1"; shift
  case "$arg" in
    --header)
      value="$1"; shift
      if [[ "$value" == @* ]]; then
        header_file="${value#@}"
        [[ "$(cat "$header_file")" == "Authorization: Bearer $FAKE_EXPECTED_KEY" ]] && auth_ok=true
        printf '%s\n' '--header' '@<private-header-file>' >> "$FAKE_CURL_ARGS"
      else
        printf '%s\n' '--header' "$value" >> "$FAKE_CURL_ARGS"
      fi
      ;;
    --data-binary)
      value="$1"; shift
      body="${value#@}"
      printf '%s\n' '--data-binary' '@<private-payload-file>' >> "$FAKE_CURL_ARGS"
      ;;
    --output|--write-out|--max-redirs|--retry|--connect-timeout|--max-time|--request)
      printf '%s\n' "$arg" "$1" >> "$FAKE_CURL_ARGS"
      shift
      ;;
    *) printf '%s\n' "$arg" >> "$FAKE_CURL_ARGS" ;;
  esac
done
[[ "$auth_ok" == true ]] || exit 91
[[ -n "$body" && -f "$body" ]] || exit 92
cp "$body" "$FAKE_CURL_BODY"
printf '%s' "${FAKE_HTTP_STATUS:-204}"
exit "${FAKE_CURL_EXIT:-0}"
EOF
  chmod +x "$fake_bin/curl"
  PATH="$fake_bin:$ORIGINAL_PATH"
  export PATH
}

reset_fake() {
  FAKE_CURL_COUNT="$TMP_ROOT/curl-count"
  FAKE_CURL_ARGS="$TMP_ROOT/curl-args"
  FAKE_CURL_BODY="$TMP_ROOT/curl-body"
  FAKE_EXPECTED_KEY='phase34-super-secret'
  FAKE_HTTP_STATUS=204
  FAKE_CURL_EXIT=0
  rm -f "$FAKE_CURL_COUNT" "$FAKE_CURL_ARGS" "$FAKE_CURL_BODY"
  export FAKE_CURL_COUNT FAKE_CURL_ARGS FAKE_CURL_BODY FAKE_EXPECTED_KEY FAKE_HTTP_STATUS FAKE_CURL_EXIT
}

schema_and_runtime_configuration() {
  local schema="$ROOT/config.schema.json" config="$TMP_ROOT/config.json"
  jq -e '
    (.properties.storage.additionalProperties == false)
    and (.properties.storage.properties.mirror.additionalProperties == false)
    and (.properties.storage.properties.mirror.required | sort == ["api_key_env","enabled","url"])
    and (.properties.storage.properties.mirror.properties.url.pattern == "^https?://")
    and (.properties.storage.properties.mirror.properties.api_key_env.pattern == "^[A-Za-z_][A-Za-z0-9_]*$")
    and (.required | index("storage") == null)
  ' "$schema" >/dev/null

  printf '{}\n' > "$config"
  ideas_mirror_read_config "$config"
  assert_eq "$IDEAS_MIRROR_ENABLED" false
  write_config "$config" false
  ideas_mirror_read_config "$config"
  assert_eq "$IDEAS_MIRROR_ENABLED" false
  write_config "$config" true
  ideas_mirror_read_config "$config"
  ideas_mirror_validate_config

  for bad_url in 'HTTP://host/path' 'https:///path' 'https://user@host/path' 'https://host/path#fragment' 'http://host/path' 'http://example.com:8080/path'; do
    write_config "$config" true "$bad_url"
    ideas_mirror_read_config "$config"
    if ideas_mirror_validate_config >/dev/null 2>&1; then fail "accepted invalid URL $bad_url"; fi
  done
  for loopback_url in 'http://localhost/path' 'http://localhost:8080/path' 'http://127.0.0.1/path'; do
    write_config "$config" true "$loopback_url"
    ideas_mirror_read_config "$config"
    ideas_mirror_validate_config || fail "rejected valid loopback http:// URL $loopback_url"
  done
  write_config "$config" true 'https://host/path' '9INVALID'
  ideas_mirror_read_config "$config"
  if ideas_mirror_validate_config >/dev/null 2>&1; then fail 'accepted invalid credential name'; fi
  printf '{"storage":{"mirror":{"enabled":true,"url":"https://host","api_key_env":"KEY","extra":1}}}\n' > "$config"
  if ideas_mirror_read_config "$config" >/dev/null 2>&1; then fail 'accepted unknown mirror key'; fi
  printf '{"storage":{"mirror":{"enabled":true,"url":"https://host"}}}\n' > "$config"
  if ideas_mirror_read_config "$config" >/dev/null 2>&1; then fail 'accepted missing mirror key'; fi
}

payload_order_and_identifiers() {
  local repo payload payload2 identifier base
  repo="$(make_repo)"; payload="$TMP_ROOT/payload.json"; payload2="$TMP_ROOT/payload2.json"
  printf '%s\n\n%s\n' '{"event":2}' '{"event":1}' > "$repo/.e3d-pilot/events.jsonl"
  mkdir -p "$repo/.e3d-pilot/ideas/z-last" "$repo/.e3d-pilot/ideas/A-first" "$repo/.e3d-pilot/ideas/a-middle"
  printf '{"idea":"z"}\n' > "$repo/.e3d-pilot/ideas/z-last/idea.json"
  printf '{"idea":"A"}\n' > "$repo/.e3d-pilot/ideas/A-first/idea.json"
  printf '{"idea":"a"}\n' > "$repo/.e3d-pilot/ideas/a-middle/idea.json"
  git -C "$repo" remote add origin 'https://user:password@example.test:8443/org/repo.git?token=secret#private'
  ideas_mirror_build_payload "$repo" "$payload"
  jq -e '
    .schema_version == 1
    and .repository.identifier == "https://example.test:8443/org/repo.git"
    and (.mirrored_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.events | map(.event)) == [2,1]
    and (.ideas | map(.idea)) == ["A","a","z"]
  ' "$payload" >/dev/null
  ideas_mirror_build_payload "$repo" "$payload2"
  jq -n -e --slurpfile a "$payload" --slurpfile b "$payload2" \
    '($a[0] | del(.mirrored_at)) == ($b[0] | del(.mirrored_at))' >/dev/null

  git -C "$repo" remote set-url origin 'git@example.test:org/repo.git'
  identifier="$(ideas_mirror_repository_identifier "$repo")"
  assert_eq "$identifier" 'example.test:org/repo.git' 'SCP origin was not sanitized'
  base="$(basename "$repo")"
  for origin in "file://$repo/private.git" "$repo/private.git" 'https:/authority-less' 'custom:value'; do
    git -C "$repo" remote set-url origin "$origin"
    identifier="$(ideas_mirror_repository_identifier "$repo")"
    assert_eq "$identifier" "$base" "unsafe origin did not fall back: $origin"
    [[ "$identifier" != *"$repo"* ]] || fail 'absolute path leaked through identifier'
  done
}

transport_and_cleanup() {
  local repo config output status before after
  repo="$(make_repo)"; config="$repo/.e3d-pilot/config.json"
  write_config "$config" true
  printf '{"event":"safe"}\n' > "$repo/.e3d-pilot/events.jsonl"
  reset_fake
  PHASE34_TOKEN="$FAKE_EXPECTED_KEY"; export PHASE34_TOKEN
  ideas_mirror_run "$repo" strict
  assert_eq "$(cat "$FAKE_CURL_COUNT")" 1
  grep -qx -- '--request' "$FAKE_CURL_ARGS"
  grep -qx -- 'POST' "$FAKE_CURL_ARGS"
  grep -qx -- 'Content-Type: application/json' "$FAKE_CURL_ARGS"
  grep -qx -- '--max-redirs' "$FAKE_CURL_ARGS"; grep -qx -- '0' "$FAKE_CURL_ARGS"
  grep -qx -- '--retry' "$FAKE_CURL_ARGS"
  grep -qx -- '--connect-timeout' "$FAKE_CURL_ARGS"; grep -qx -- '10' "$FAKE_CURL_ARGS"
  grep -qx -- '--max-time' "$FAKE_CURL_ARGS"; grep -qx -- '30' "$FAKE_CURL_ARGS"
  ! grep -q -- '--location' "$FAKE_CURL_ARGS"
  ! grep -Fq "$FAKE_EXPECTED_KEY" "$FAKE_CURL_ARGS"
  ! grep -Fq "$FAKE_EXPECTED_KEY" "$FAKE_CURL_BODY"
  jq -e '.events == [{"event":"safe"}]' "$FAKE_CURL_BODY" >/dev/null
  if find "$TMP_ROOT" -maxdepth 1 -type f \( -name 'e3d-mirror-*' -o -name '.e3d-mirror-*' \) | grep -q .; then
    fail 'mirror temporary file retained after success'
  fi

  write_config "$config" false
  rm -f "$FAKE_CURL_COUNT"
  rm -f "$repo/.e3d-pilot/events.jsonl"
  mkdir -p "$repo/.e3d-pilot/events.jsonl"
  ideas_mirror_run "$repo" best-effort
  [[ ! -e "$FAKE_CURL_COUNT" ]] || fail 'disabled best-effort mirror invoked curl'
  if output="$(ideas_mirror_run "$repo" strict 2>&1)"; then fail 'strict disabled mirror succeeded'; fi
  [[ "$output" == *'not enabled'* ]] || fail 'strict disabled diagnostic missing'
  rmdir "$repo/.e3d-pilot/events.jsonl"

  write_config "$config" true
  unset PHASE34_TOKEN
  if output="$(ideas_mirror_run "$repo" strict 2>&1)"; then fail 'missing credential succeeded'; fi
  ! grep -Fq "$FAKE_EXPECTED_KEY" <<<"$output"
  [[ ! -e "$FAKE_CURL_COUNT" ]] || fail 'missing credential invoked curl'

  PHASE34_TOKEN="$FAKE_EXPECTED_KEY"; export PHASE34_TOKEN
  printf 'not-json\n' > "$repo/.e3d-pilot/events.jsonl"
  if output="$(ideas_mirror_run "$repo" strict 2>&1)"; then fail 'malformed ledger succeeded'; fi
  [[ ! -e "$FAKE_CURL_COUNT" ]] || fail 'malformed ledger invoked curl'
  ! grep -Fq "$FAKE_EXPECTED_KEY" <<<"$output"

  printf '{"event":"safe"}\n' > "$repo/.e3d-pilot/events.jsonl"
  reset_fake; FAKE_HTTP_STATUS=500; export FAKE_HTTP_STATUS
  if output="$(ideas_mirror_run "$repo" strict 2>&1)"; then fail 'HTTP 500 succeeded'; fi
  assert_eq "$(cat "$FAKE_CURL_COUNT")" 1
  reset_fake; FAKE_CURL_EXIT=7; export FAKE_CURL_EXIT
  if output="$(ideas_mirror_run "$repo" strict 2>&1)"; then fail 'curl failure succeeded'; fi
  ! grep -Fq "$FAKE_EXPECTED_KEY" <<<"$output"
  reset_fake; FAKE_HTTP_STATUS=503; export FAKE_HTTP_STATUS
  output="$(ideas_mirror_run "$repo" best-effort 2>&1)"
  assert_eq "$(grep -c 'warning:' <<<"$output")" 1 'best-effort failure should emit one warning'
  ! grep -Fq "$FAKE_EXPECTED_KEY" <<<"$output"
  before="$(find "$TMP_ROOT" -maxdepth 1 -name 'e3d-mirror-*' | wc -l | tr -d ' ')"
  after="$before"
  assert_eq "$after" 0 'mirror temporary files retained after failure'
  rm -f "$FAKE_CURL_BODY"
}

write_complete_config() {
  local repo="$1" enabled="$2"
  jq --argjson enabled "$enabled" '
    .storage.mirror.enabled = $enabled
    | .storage.mirror.url = "https://ledger-mirror.example.com/v1/snapshots"
    | .storage.mirror.api_key_env = "PHASE34_TOKEN"
  ' "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
}

cli_behavior() {
  local repo output before_hash after_hash
  repo="$(make_repo)"
  write_complete_config "$repo" true
  printf '{"event":"unchanged"}\n' > "$repo/.e3d-pilot/events.jsonl"
  before_hash="$(git hash-object "$repo/.e3d-pilot/events.jsonl")"
  reset_fake
  PHASE34_TOKEN="$FAKE_EXPECTED_KEY"; export PHASE34_TOKEN

  output="$($ROOT/bin/e3d-pilot storage mirror --repo "$repo")"
  [[ "$output" == *'upload completed'* ]] || fail 'strict CLI success confirmation missing'
  assert_eq "$(cat "$FAKE_CURL_COUNT")" 1 'strict CLI did not make exactly one request'
  ! grep -Fq "$FAKE_EXPECTED_KEY" <<<"$output"

  write_complete_config "$repo" false
  reset_fake
  if output="$($ROOT/bin/e3d-pilot storage mirror --repo "$repo" 2>&1)"; then fail 'disabled CLI mirror succeeded'; fi
  [[ "$output" == *'not enabled'* ]] || fail 'disabled CLI diagnostic missing'
  [[ ! -e "$FAKE_CURL_COUNT" ]] || fail 'disabled CLI invoked curl'

  jq 'del(.storage)' "$repo/.e3d-pilot/config.json" > "$TMP_ROOT/config-without-storage"
  cp "$TMP_ROOT/config-without-storage" "$repo/.e3d-pilot/config.json"
  reset_fake
  if output="$($ROOT/bin/e3d-pilot storage mirror --repo "$repo" 2>&1)"; then fail 'absent CLI mirror succeeded'; fi
  [[ "$output" == *'not enabled'* ]] || fail 'absent CLI diagnostic missing'
  [[ ! -e "$FAKE_CURL_COUNT" ]] || fail 'absent CLI invoked curl'

  write_complete_config "$repo" true
  reset_fake; FAKE_HTTP_STATUS=500; export FAKE_HTTP_STATUS
  if output="$($ROOT/bin/e3d-pilot storage mirror --repo "$repo" 2>&1)"; then fail 'HTTP failure CLI mirror succeeded'; fi
  assert_eq "$(cat "$FAKE_CURL_COUNT")" 1 'HTTP failure CLI retried or skipped its request'
  [[ "$output" == *'HTTP 500'* ]] || fail 'HTTP failure CLI diagnostic missing'
  ! grep -Fq "$FAKE_EXPECTED_KEY" <<<"$output"

  $ROOT/bin/e3d-pilot storage --help | grep -Fq 'storage mirror --repo <path>'
  $ROOT/bin/e3d-pilot storage mirror --help | grep -Fq 'storage mirror --repo <path>'
  if $ROOT/bin/e3d-pilot storage unknown >/dev/null 2>&1; then fail 'unknown storage subcommand succeeded'; fi
  if $ROOT/bin/e3d-pilot storage mirror --repo >/dev/null 2>&1; then fail 'missing --repo value succeeded'; fi
  if $ROOT/bin/e3d-pilot storage mirror --repo "$repo" --repo "$repo" >/dev/null 2>&1; then fail 'duplicate --repo succeeded'; fi
  if $ROOT/bin/e3d-pilot storage mirror --repo "$repo" extra >/dev/null 2>&1; then fail 'unexpected mirror argument succeeded'; fi
  if $ROOT/bin/e3d-pilot storage mirror --bogus >/dev/null 2>&1; then fail 'unknown mirror option succeeded'; fi

  after_hash="$(git hash-object "$repo/.e3d-pilot/events.jsonl")"
  assert_eq "$after_hash" "$before_hash" 'CLI mirror changed the event ledger'
}

post_publish_hook_behavior() {
  local hook_log="$TMP_ROOT/post-success-log" config="$TMP_ROOT/post-success-config" repo output
  # Sourcing the CLI exposes the same hook used by ordinary, repaired, and
  # per-target fleet publication without dispatching main.
  source "$ROOT/bin/e3d-pilot"
  repo="$(make_repo)"
  write_complete_config "$repo" true
  config="$repo/.e3d-pilot/config.json"
  reset_fake; FAKE_HTTP_STATUS=503; export FAKE_HTTP_STATUS
  PHASE34_TOKEN="$FAKE_EXPECTED_KEY"; export PHASE34_TOKEN
  output="$(publish_post_success "$repo" "$config" /tmp/run branch local published /tmp/summary 2>&1)"
  assert_eq "$(cat "$FAKE_CURL_COUNT")" 1 'automatic mirror did not make one request'
  assert_eq "$(grep -c 'warning:' <<<"$output")" 1 'automatic failure did not emit one warning'
  ! grep -Fq "$FAKE_EXPECTED_KEY" <<<"$output"

  publish_send_notification() { :; }
  ideas_mirror_run() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$hook_log"; return 0; }
  publish_post_success /tmp/repository "$config" /tmp/run branch local published /tmp/summary
  assert_eq "$(wc -l < "$hook_log" | tr -d ' ')" 1 'post-success hook invoked mirror more than once'
  assert_eq "$(cut -f2 "$hook_log")" best-effort 'post-success hook was not best-effort'

  # The one call site is deliberately after backend output is persisted and
  # accepted; all ordinary, repair, and fleet pipelines share publish_stage.
  assert_eq "$(grep -c 'publish_post_success \"\$repo\"' "$ROOT/bin/e3d-pilot")" 1 'post-success hook call site is not singular'
  local write_line hook_line backend_failure_line
  write_line="$(grep -n 'publish-backend.out' "$ROOT/bin/e3d-pilot" | grep 'printf' | head -n1 | cut -d: -f1)"
  hook_line="$(grep -n 'publish_post_success \"\$repo\"' "$ROOT/bin/e3d-pilot" | cut -d: -f1)"
  backend_failure_line="$(grep -n 'publish backend failed:' "$ROOT/bin/e3d-pilot" | head -n1 | cut -d: -f1)"
  (( hook_line > write_line && hook_line > backend_failure_line )) || fail 'post-success hook is not after recorded backend success'
}

main() {
  bash -n "$ROOT/lib/ideas/mirror.sh"
  jq -e . "$ROOT/config.schema.json" >/dev/null
  install_fake_curl
  schema_and_runtime_configuration
  payload_order_and_identifiers
  transport_and_cleanup
  cli_behavior
  post_publish_hook_behavior
  echo 'phase34: all tests passed'
}

main "$@"
