#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"
COLLECTOR="$ROOT/lib/ops/collect-fleet-health.sh"
SAMPLE_CONFIG="$ROOT/examples/sample-fleet-config.json"

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
  local bin_dir="$1" trace_file="$2" responses_file="$3" count_file="$4"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
trace="\${PHASE26_CURL_TRACE:?}"
responses="\${PHASE26_CURL_RESPONSES:?}"
count_file="\${PHASE26_CURL_COUNT:?}"
call=0
if [[ -f "\$count_file" ]]; then
  call="\$(<"\$count_file")"
fi
call=\$((call + 1))
printf '%s' "\$call" > "\$count_file"
{
  printf 'CALL %s\n' "\$call"
  i=1
  for arg in "\$@"; do
    printf 'ARG %s: %s\n' "\$i" "\$arg"
    i=\$((i + 1))
  done
} >> "\$trace"
line="\$(sed -n "\${call}p" "\$responses")"
[[ -n "\$line" ]] || { echo "missing fake curl response for call \$call" >&2; exit 99; }
IFS='|' read -r exit_code http_code time_total <<<"\$line"
printf '%s\t%s\n' "\$http_code" "\$time_total"
exit "\$exit_code"
EOF
  chmod +x "$bin_dir/curl"
  : > "$trace_file"
  : > "$responses_file"
  printf '0' > "$count_file"
}

make_provider_bins() {
  local bin_dir="$1" claude_bin="$2" codex_bin="$3"
  mkdir -p "$bin_dir"
  cat > "$claude_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
prompt="$(cat)"
grep -q 'cross-repo discover stage' <<<"$prompt" || {
  echo "unexpected discover prompt" >&2
  exit 1
}
cat <<'OUT'
### Cross-Repo Opportunities
- repo-a + repo-b: surface live operations signals in the shared fleet view.
### Analogous Patterns
- marketplace liquidity -- route attention toward the healthiest checkout path.
OUT
EOF
  cat > "$codex_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
prompt="$(cat)"
grep -q 'cross-repo ideate stage' <<<"$prompt" || {
  echo "unexpected ideate prompt" >&2
  exit 1
}
cat <<'OUT'
### Candidate 1: Shared operations dashboard
Repos: repo-a, repo-b
Duplicate: no
Dedup rationale: no prior fleet run covers this.
Analogy: developer-tool CLI ergonomics -- show status where operators already look.
Attraction (1-5): 4
Retention (1-5): 4
Effort: medium
Revenue (1-5|n/a): 3
Description: Combine repo-a's health signal with repo-b's control plane.

### Candidate 2: Status digest
Repos: repo-a, repo-b
Duplicate: no
Dedup rationale: distinct second candidate for the fixture.
Analogy: developer-tool CLI ergonomics -- emit a compact operator summary.
Attraction (1-5): 3
Retention (1-5): 3
Effort: low
Revenue (1-5|n/a): 2
Description: Add a small status digest alongside the dashboard.

---IDEATE-STATUS---
selected: candidate-1
reason: fixture candidate selected
OUT
EOF
  chmod +x "$claude_bin" "$codex_bin"
}

write_fleet_config() {
  local file="$1" live_instances_expr="${2:-del(.live_instances)}"
  jq "$live_instances_expr" "$SAMPLE_CONFIG" > "$file"
}

collector_renders_all_fixture_states() {
  local config_file curl_bin trace_file responses_file count_file out expected status
  local repo_config
  config_file="$(mktemp "$TMP_ROOT/collector-config.XXXXXX.json")"
  curl_bin="$(mktemp -d "$TMP_ROOT/curl-bin.XXXXXX")"
  trace_file="$(mktemp "$TMP_ROOT/curl-trace.XXXXXX")"
  responses_file="$(mktemp "$TMP_ROOT/curl-responses.XXXXXX")"
  count_file="$(mktemp "$TMP_ROOT/curl-count.XXXXXX")"
  make_curl_stub "$curl_bin" "$trace_file" "$responses_file" "$count_file"
  export PHASE26_CURL_TRACE="$trace_file"
  export PHASE26_CURL_RESPONSES="$responses_file"
  export PHASE26_CURL_COUNT="$count_file"

  repo_config="$(mktemp "$TMP_ROOT/collector-base.XXXXXX.json")"
  jq '
    .live_instances = [
      {name:"Line 1\r\nLine 2", url:"https://fast.example.com/health"},
      {name:"Slow 2xx", url:"https://slow.example.com/health"},
      {name:"Redirect 3xx", url:"https://redirect.example.com/health"},
      {name:"Server 500", url:"https://error.example.com/health"},
      {name:"Timeout", url:"https://timeout.example.com/health"},
      {name:"Conn refused", url:"https://refused.example.com/health"},
      {name:"DNS fail", url:"https://dns.example.com/health"},
      {name:"Unknown fail", url:"https://unknown.example.com/health"},
      {name:"Bad timing nonzero", url:"https://badtiming.example.com/health"},
      {name:"Bad timing zero", url:"https://zerotiming.example.com/health"}
    ]
  ' "$SAMPLE_CONFIG" > "$repo_config"

  cat > "$responses_file" <<'EOF'
0|200|1.234567
0|204|2.000000
0|302|0.456789
0|500|0.333333
28|200|2.500000
7|200|0.100000
6|200|0.200000
35|418|0.300000
7|503|bogus
0|200|
EOF

  out="$(PATH="$curl_bin:$PATH" "$COLLECTOR" "$repo_config")"
  expected="$(cat <<'EOF'
### Live Instance Status

- **Line 1 Line 2** (https://fast.example.com/health): healthy — HTTP 200, 1234ms
- **Slow 2xx** (https://slow.example.com/health): degraded — HTTP 204, 2000ms
- **Redirect 3xx** (https://redirect.example.com/health): degraded — HTTP 302, 456ms
- **Server 500** (https://error.example.com/health): down — HTTP 500, 333ms
- **Timeout** (https://timeout.example.com/health): down — HTTP timeout, 2500ms
- **Conn refused** (https://refused.example.com/health): down — HTTP connection-refused, 100ms
- **DNS fail** (https://dns.example.com/health): down — HTTP dns-error, 200ms
- **Unknown fail** (https://unknown.example.com/health): down — HTTP unknown-error, 300ms
- **Bad timing nonzero** (https://badtiming.example.com/health): down — HTTP connection-refused, unavailablems
- **Bad timing zero** (https://zerotiming.example.com/health): down — HTTP invalid-curl-output, unavailablems
EOF
)"
  assert_eq "$out" "$expected" "collector markdown"
  assert_eq "$(grep -c '^CALL ' "$trace_file" || true)" "10" "one curl call per instance"
  assert_eq "$(grep -c '^ARG 6: --max-redirs$' "$trace_file" || true)" "10" "max-redirs bound"
  assert_eq "$(grep -c '^ARG 7: 1$' "$trace_file" || true)" "10" "max-redirs value"
  assert_eq "$(grep -c '^ARG 8: --max-time$' "$trace_file" || true)" "10" "max-time flag"
  assert_eq "$(grep -c '^ARG 9: 10$' "$trace_file" || true)" "10" "max-time value"
  assert_eq "$(grep -c '^ARG 10: --proto$' "$trace_file" || true)" "10" "proto flag"
  assert_eq "$(grep -c '^ARG 11: =http,https$' "$trace_file" || true)" "10" "proto value"
  assert_eq "$(grep -c '^ARG 12: --proto-redir$' "$trace_file" || true)" "10" "proto-redir flag"
  assert_eq "$(grep -c '^ARG 13: =http,https$' "$trace_file" || true)" "10" "proto-redir value"
  assert_eq "$(grep -c '^ARG 14: --location$' "$trace_file" || true)" "10" "location flag"
  assert_eq "$(grep -c '^ARG 15: --request$' "$trace_file" || true)" "10" "request flag"
  assert_eq "$(grep -c '^ARG 16: GET$' "$trace_file" || true)" "10" "request method"
  assert_eq "$(grep -c '^ARG 17: --$' "$trace_file" || true)" "10" "url terminator"
  assert_eq "$(grep -c '^ARG 18: https://.*example.com/health$' "$trace_file" || true)" "10" "url as one argument"

  rm -f "$config_file" "$repo_config"
}

collector_rejects_invalid_configs_and_skips_curl() {
  local config_file trace_file responses_file count_file curl_bin out status
  curl_bin="$(mktemp -d "$TMP_ROOT/curl-bin-invalid.XXXXXX")"
  trace_file="$(mktemp "$TMP_ROOT/curl-trace-invalid.XXXXXX")"
  responses_file="$(mktemp "$TMP_ROOT/curl-responses-invalid.XXXXXX")"
  count_file="$(mktemp "$TMP_ROOT/curl-count-invalid.XXXXXX")"
  make_curl_stub "$curl_bin" "$trace_file" "$responses_file" "$count_file"
  export PHASE26_CURL_TRACE="$trace_file"
  export PHASE26_CURL_RESPONSES="$responses_file"
  export PHASE26_CURL_COUNT="$count_file"

  config_file="$(mktemp "$TMP_ROOT/collector-invalid.XXXXXX.json")"

  printf 'not json\n' > "$config_file"
  set +e
  out="$(PATH="$curl_bin:$PATH" "$COLLECTOR" "$config_file" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "invalid JSON should fail" >&2; exit 1; }
  assert_contains "$out" "invalid JSON"
  assert_eq "$(grep -c '^CALL ' "$trace_file" || true)" "0" "no curl on invalid JSON"

  : > "$trace_file"
  jq '.live_instances = 1' "$SAMPLE_CONFIG" > "$config_file"
  set +e
  out="$(PATH="$curl_bin:$PATH" "$COLLECTOR" "$config_file" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "non-array live_instances should fail" >&2; exit 1; }
  assert_contains "$out" "must be an array"
  assert_eq "$(grep -c '^CALL ' "$trace_file" || true)" "0" "no curl on non-array live_instances"

  local -a invalid_exprs=(
    '.live_instances = [{"name":"A","url":"https://a.example.com/health","extra":1}]'
    '.live_instances = [{"name":"","url":"https://a.example.com/health"}]'
    '.live_instances = [{"name":1,"url":"https://a.example.com/health"}]'
    '.live_instances = [{"name":"A","url":"ftp://a.example.com/health"}]'
    '.live_instances = [{"name":"A","url":"https:///health"}]'
    '.live_instances = [{"name":"A","url":"https://user@a.example.com/health"}]'
  )
  local expr
  for expr in "${invalid_exprs[@]}"; do
    : > "$trace_file"
    jq "$expr" "$SAMPLE_CONFIG" > "$config_file"
    set +e
    out="$(PATH="$curl_bin:$PATH" "$COLLECTOR" "$config_file" 2>&1)"
    status=$?
    set -e
    [[ $status -ne 0 ]] || { printf 'expected failure for %s\n' "$expr" >&2; exit 1; }
    assert_contains "$out" "live_instances"
    assert_eq "$(grep -c '^CALL ' "$trace_file" || true)" "0" "no curl on invalid entry"
  done

  local missing_file
  missing_file="$TMP_ROOT/no-such-config.json"
  set +e
  out="$(PATH="$curl_bin:$PATH" "$COLLECTOR" "$missing_file" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "missing config should fail" >&2; exit 1; }
  assert_contains "$out" "not readable"
  assert_eq "$(grep -c '^CALL ' "$trace_file" || true)" "0" "no curl on missing file"

  local unreadable_file
  unreadable_file="$(mktemp "$TMP_ROOT/unreadable.XXXXXX.json")"
  jq '.live_instances = []' "$SAMPLE_CONFIG" > "$unreadable_file"
  chmod 000 "$unreadable_file"
  set +e
  out="$(PATH="$curl_bin:$PATH" "$COLLECTOR" "$unreadable_file" 2>&1)"
  status=$?
  set -e
  chmod 600 "$unreadable_file"
  [[ $status -ne 0 ]] || { echo "unreadable config should fail" >&2; exit 1; }
  assert_contains "$out" "not readable"
  assert_eq "$(grep -c '^CALL ' "$trace_file" || true)" "0" "no curl on unreadable file"

  rm -f "$config_file" "$unreadable_file"
}

collector_prints_empty_fragment_without_curl() {
  local config_file trace_file responses_file count_file curl_bin out
  curl_bin="$(mktemp -d "$TMP_ROOT/curl-bin-empty.XXXXXX")"
  trace_file="$(mktemp "$TMP_ROOT/curl-trace-empty.XXXXXX")"
  responses_file="$(mktemp "$TMP_ROOT/curl-responses-empty.XXXXXX")"
  count_file="$(mktemp "$TMP_ROOT/curl-count-empty.XXXXXX")"
  make_curl_stub "$curl_bin" "$trace_file" "$responses_file" "$count_file"
  export PHASE26_CURL_TRACE="$trace_file"
  export PHASE26_CURL_RESPONSES="$responses_file"
  export PHASE26_CURL_COUNT="$count_file"

  config_file="$(mktemp "$TMP_ROOT/collector-empty.XXXXXX.json")"
  write_fleet_config "$config_file" 'del(.live_instances)'
  out="$(PATH="$curl_bin:$PATH" "$COLLECTOR" "$config_file")"
  assert_eq "$out" "### Live Instance Status"$'\n\n'"No live instances configured." "empty fragment"
  assert_eq "$(grep -c '^CALL ' "$trace_file" || true)" "0" "no curl when live_instances absent"

  : > "$trace_file"
  jq '.live_instances = []' "$SAMPLE_CONFIG" > "$config_file"
  out="$(PATH="$curl_bin:$PATH" "$COLLECTOR" "$config_file")"
  assert_eq "$out" "### Live Instance Status"$'\n\n'"No live instances configured." "empty array fragment"
  assert_eq "$(grep -c '^CALL ' "$trace_file" || true)" "0" "no curl when live_instances empty"

  rm -f "$config_file"
}

fleet_discover_validation_and_live_ops_integration() {
  local repo_a repo_b fleet_dir fleet_file config_file bin_dir claude_bin codex_bin curl_bin trace_file responses_file count_file out status run_id findings prompt
  repo_a="$(make_repo repo-a)"
  repo_b="$(make_repo repo-b)"
  fleet_dir="$(mktemp -d "$TMP_ROOT/fleet.XXXXXX")"
  fleet_file="$fleet_dir/fleet.json"
  jq -n --arg a "$repo_a" --arg b "$repo_b" '[$a,$b]' > "$fleet_file"
  mkdir -p "$fleet_dir/.e3d-pilot-fleet"

  bin_dir="$(mktemp -d "$TMP_ROOT/provider-bin.XXXXXX")"
  claude_bin="$TMP_ROOT/claude-fake.bin"
  codex_bin="$TMP_ROOT/codex-fake.bin"
  make_provider_bins "$bin_dir" "$claude_bin" "$codex_bin"

  curl_bin="$(mktemp -d "$TMP_ROOT/curl-bin-fleet.XXXXXX")"
  trace_file="$(mktemp "$TMP_ROOT/curl-trace-fleet.XXXXXX")"
  responses_file="$(mktemp "$TMP_ROOT/curl-responses-fleet.XXXXXX")"
  count_file="$(mktemp "$TMP_ROOT/curl-count-fleet.XXXXXX")"
  make_curl_stub "$curl_bin" "$trace_file" "$responses_file" "$count_file"
  export PHASE26_CURL_TRACE="$trace_file"
  export PHASE26_CURL_RESPONSES="$responses_file"
  export PHASE26_CURL_COUNT="$count_file"
  export CLAUDE_BIN="$claude_bin"
  export CODEX_BIN="$codex_bin"
  export PATH="$curl_bin:$PATH"

  config_file="$fleet_dir/.e3d-pilot-fleet/config.json"
  jq '.providers.discover = "claude" | .providers.ideate = "codex"' "$SAMPLE_CONFIG" > "$config_file"

  run_id="phase26-absent"
  printf '' > "$responses_file"
  out="$(PATH="$bin_dir:$PATH" CLAUDE_BIN="$claude_bin" CODEX_BIN="$codex_bin" "$BIN" fleet discover "$fleet_file" --run-id "$run_id" 2>&1)"
  assert_contains "$out" "$run_id"
  findings="$fleet_dir/.e3d-pilot-fleet/runs/$run_id/findings.md"
  prompt="$fleet_dir/.e3d-pilot-fleet/runs/$run_id/fleet-discover-prompt.md"
  assert_contains "$(cat "$findings")" "## Live Operations"
  assert_contains "$(cat "$findings")" "No live instances configured."
  assert_contains "$(cat "$prompt")" "omit that entire section when all configured live instances are healthy or when no live instances are configured."
  assert_eq "$(grep -c '^CALL ' "$trace_file" || true)" "0" "no curl for absent live_instances"

  run_id="phase26-empty"
  : > "$trace_file"
  jq '.live_instances = [] | .providers.discover = "claude" | .providers.ideate = "codex"' "$SAMPLE_CONFIG" > "$config_file"
  out="$(PATH="$bin_dir:$PATH" CLAUDE_BIN="$claude_bin" CODEX_BIN="$codex_bin" "$BIN" fleet discover "$fleet_file" --run-id "$run_id" 2>&1)"
  assert_contains "$out" "$run_id"
  findings="$fleet_dir/.e3d-pilot-fleet/runs/$run_id/findings.md"
  assert_contains "$(cat "$findings")" "No live instances configured."
  assert_eq "$(grep -c '^CALL ' "$trace_file" || true)" "0" "no curl for empty live_instances"

  run_id="phase26-down"
  : > "$trace_file"
  cat > "$responses_file" <<'EOF'
0|500|0.456789
EOF
  jq '
    .live_instances = [
      {name:"Netdoctor", url:"https://netdoctor.example.com/health"}
    ]
    | .providers.discover = "claude"
    | .providers.ideate = "codex"
  ' "$SAMPLE_CONFIG" > "$config_file"
  out="$(PATH="$bin_dir:$PATH" CLAUDE_BIN="$claude_bin" CODEX_BIN="$codex_bin" "$BIN" fleet discover "$fleet_file" --run-id "$run_id" 2>&1)"
  assert_contains "$out" "$run_id"
  findings="$fleet_dir/.e3d-pilot-fleet/runs/$run_id/findings.md"
  prompt="$fleet_dir/.e3d-pilot-fleet/runs/$run_id/fleet-discover-prompt.md"
  assert_contains "$(cat "$findings")" "## Live Operations"
  assert_contains "$(cat "$findings")" "Netdoctor"
  assert_contains "$(cat "$findings")" "down — HTTP 500, 456ms"
  assert_contains "$(cat "$prompt")" "create one recommendation for every degraded or down entry"
  assert_contains "$(cat "$prompt")" "repeat the observed classification and status or failure reason exactly as reported"
  assert_eq "$(grep -c '^CALL ' "$trace_file" || true)" "1" "one curl call for one live instance"

  local invalid_dir invalid_file invalid_out invalid_status
  invalid_dir="$(mktemp -d "$TMP_ROOT/fleet-invalid.XXXXXX")"
  invalid_file="$invalid_dir/fleet.json"
  jq -n --arg a "$repo_a" --arg b "$repo_b" '[$a,$b]' > "$invalid_file"
  for config_expr in \
    'not json' \
    '.live_instances = 1' \
    '.live_instances = [{"name":"A","url":"https://a.example.com/health","extra":1}]' \
    '.live_instances = [{"name":"","url":"https://a.example.com/health"}]' \
    '.live_instances = [{"name":"A","url":"ftp://a.example.com/health"}]' \
    '.live_instances = [{"name":"A","url":"https:///health"}]' \
    '.live_instances = [{"name":"A","url":"https://user@a.example.com/health"}]'
  do
    : > "$trace_file"
    if [[ "$config_expr" == "not json" ]]; then
      printf 'not json\n' > "$config_file"
    else
      jq ".providers.discover = \"claude\" | .providers.ideate = \"codex\" | $config_expr" "$SAMPLE_CONFIG" > "$config_file"
    fi
    set +e
    invalid_out="$(PATH="$bin_dir:$PATH" CLAUDE_BIN="$claude_bin" CODEX_BIN="$codex_bin" "$BIN" fleet discover "$fleet_file" --config "$config_file" --run-id "phase26-invalid" 2>&1)"
    invalid_status=$?
    set -e
    [[ $invalid_status -ne 0 ]] || { printf 'expected failure for %s\n' "$config_expr" >&2; exit 1; }
    assert_eq "$(grep -c '^CALL ' "$trace_file" || true)" "0" "invalid config should fail before curl"
    if [[ "$config_expr" == "not json" ]]; then
      assert_contains "$invalid_out" "invalid JSON"
    else
      assert_contains "$invalid_out" "live_instances"
    fi
  done

  rm -rf "$invalid_dir"
}

main() {
  collector_renders_all_fixture_states
  collector_rejects_invalid_configs_and_skips_curl
  collector_prints_empty_fragment_without_curl
  fleet_discover_validation_and_live_ops_integration
  echo 'phase26: all tests passed'
}

main "$@"
