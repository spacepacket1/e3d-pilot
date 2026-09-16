#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$ROOT/lib/providers/gemini"
DEBATE="$ROOT/bin/e3d-debate"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

TEST_HOME="$TEST_DIR/home"
BIN_DIR="$TEST_DIR/bin"
BASH_DIR="$(dirname "$(command -v bash)")"
PROMPT="$TEST_DIR/prompt with spaces.md"
OUT="$TEST_DIR/out"
ERR="$TEST_DIR/err"
MARKER="$TEST_DIR/invoked"
ARGV_LOG="$TEST_DIR/argv"
POLICY_LOG="$TEST_DIR/policy"
mkdir -p "$TEST_HOME/.gemini" "$BIN_DIR"
printf 'TOP SECRET PROMPT CONTENT\n' > "$PROMPT"

write_oauth_settings() {
  printf '%s\n' '{"security":{"auth":{"selectedType":"oauth-personal"}},"billing":{"overageStrategy":"never"}}' > "$TEST_HOME/.gemini/settings.json"
}

write_oauth_settings

cat > "$BIN_DIR/gemini-stub" <<'STUB'
#!/usr/bin/env bash
set -u
printf 'invoked\n' >> "$GEMINI_STUB_MARKER"
printf '%s\n' "$@" > "$GEMINI_STUB_ARGV"
if [[ -n "${GEMINI_STUB_PWD_LOG:-}" ]]; then
  pwd > "$GEMINI_STUB_PWD_LOG"
fi
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--admin-policy" ]]; then
    cp "${args[$((i + 1))]}" "$GEMINI_STUB_POLICY"
  fi
done
case "${GEMINI_STUB_MODE:-measured}" in
  measured)
    printf '%s\n' '{"response":"Gemini answer","stats":{"models":{"gemini-2.5-pro-202609":{"tokens":{"prompt":8,"candidates":4,"total":12}}},"tools":{"totalCalls":0}}}'
    ;;
  at_limit)
    printf '%s\n' '{"response":"At limit","stats":{"models":{"gemini-exact":{"tokens":{"prompt":7,"candidates":5,"total":12}}}}}'
    ;;
  over_limit)
    printf '%s\n' '{"response":"Must stay hidden","stats":{"models":{"gemini-exact":{"tokens":{"prompt":8,"candidates":5,"total":13}}}}}'
    ;;
  unmeasured)
    printf '%s\n' '{"response":"Valid but unmeasured","stats":{"models":{"model-a":{"tokens":{"total":2}},"model-b":{"tokens":{"total":3}}}}}'
    ;;
  malformed_usage)
    printf '%s\n' '{"response":"Usage unavailable","stats":{"models":{"gemini-exact":{"tokens":{"total":-1}}}}}'
    ;;
  components)
    printf '%s\n' '{"response":"Component total","stats":{"models":{"gemini-components":{"tokens":{"prompt":7,"candidates":5}}}}}'
    ;;
  conflicting_usage)
    # total (12) intentionally does not equal prompt+candidates (7+4=11) --
    # simulates a real total that includes extra categories (e.g. thinking
    # tokens) a component breakdown never carries. total must still win.
    printf '%s\n' '{"response":"Conflicting usage","stats":{"models":{"gemini-exact":{"tokens":{"prompt":7,"candidates":4,"total":12}}}}}'
    ;;
  total_mismatch)
    # Two genuinely distinct *total*-type sources disagree (10 vs 15) -- this
    # must still be treated as unmeasured, unlike total-vs-components above.
    printf '%s\n' '{"response":"Multiple totals disagree","model":"gemini-exact","usageMetadata":{"totalTokenCount":10},"stats":{"models":{"gemini-exact":{"tokens":{"total":15}}}}}'
    ;;
  invalid_json) printf '%s\n' 'not json' ;;
  explicit_error) printf '%s\n' '{"response":"hidden","error":{"message":"request failed"}}' ;;
  tool_request) printf '%s\n' '{"response":"hidden","toolCalls":[{"name":"read_file"}]}' ;;
  tool_stats) printf '%s\n' '{"response":"hidden","stats":{"tools":{"totalCalls":1}}}' ;;
  empty_answer) printf '%s\n' '{"response":"   ","model":"gemini-exact","usage":{"totalTokens":1}}' ;;
  failure) echo 'stub diagnostic: simulated CLI failure' >&2; exit 17 ;;
  timeout) echo 'stub diagnostic: waiting' >&2; sleep 5 ;;
esac
STUB
chmod +x "$BIN_DIR/gemini-stub"

cat > "$BIN_DIR/devin-stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' 'Deterministic peer or synthesis answer'
STUB
chmod +x "$BIN_DIR/devin-stub"

run_adapter() {
  local mode="$1"
  shift
  : > "$OUT"
  : > "$ERR"
  set +e
  env -i \
    PATH="$BIN_DIR:/usr/bin:/bin" \
    HOME="$TEST_HOME" \
    GEMINI_CLI_HOME="$TEST_HOME" \
    GEMINI_BIN="$BIN_DIR/gemini-stub" \
    GEMINI_STUB_MODE="$mode" \
    GEMINI_STUB_MARKER="$MARKER" \
    GEMINI_STUB_ARGV="$ARGV_LOG" \
    GEMINI_STUB_POLICY="$POLICY_LOG" \
    "$@" "$ADAPTER" "$PROMPT" > "$OUT" 2> "$ERR"
  STATUS=$?
  set -e
}

assert_not_invoked() {
  [[ ! -s "$MARKER" ]]
}

check_mode_and_availability() {
  : > "$MARKER"
  set +e
  env -i PATH="$BIN_DIR:/usr/bin:/bin" GEMINI_BIN="$BIN_DIR/gemini-stub" \
    GEMINI_STUB_MARKER="$MARKER" E3D_PILOT_CHECK=1 "$ADAPTER" > "$OUT" 2> "$ERR"
  local status=$?
  set -e
  [[ $status -eq 0 ]]
  grep -qi gemini "$OUT"
  assert_not_invoked

  set +e
  env -i PATH="/usr/bin:/bin" GEMINI_BIN="$TEST_DIR/missing-gemini" \
    E3D_PILOT_CHECK=1 "$ADAPTER" > "$OUT" 2> "$ERR"
  status=$?
  set -e
  [[ $status -eq 2 ]]
  grep -qi gemini "$OUT"
}

dry_run_is_exact_and_safe() {
  : > "$MARKER"
  run_adapter measured E3D_PILOT_DRY_RUN=1 GEMINI_MODEL=gemini-test
  [[ $STATUS -eq 0 ]]
  assert_not_invoked
  grep -q -- '--prompt' "$OUT"
  grep -q -- '--output-format json' "$OUT"
  grep -q -- '--extensions none' "$OUT"
  grep -q -- '--admin-policy' "$OUT"
  grep -q 'disable-all-tools' "$OUT"
  grep -q -- '--approval-mode default' "$OUT"
  grep -q -- '--model gemini-test' "$OUT"
  grep -q 'prompt.*with.*spaces.md' "$OUT"
  # `! grep ...` is exempt from set -e (negated commands never trigger
  # errexit), so an actual match here would silently pass. `grep && exit 1`
  # has its own footgun when it's the last statement executed in a function
  # call (grep's own failing "no match" status leaks through as the
  # function's return value once `exit 1` is short-circuited away, and set
  # -e then aborts at the *caller* of that function instead) -- an `if`
  # condition is unconditionally exempt from errexit and returns 0 on a
  # false branch regardless of position, so use that form everywhere here.
  if grep -q 'TOP SECRET' "$OUT"; then exit 1; fi
  if grep -Eqi -- '--yolo|always.approve|allow.list' "$OUT"; then exit 1; fi

  run_adapter measured E3D_PILOT_DRY_RUN=1
  [[ $STATUS -eq 0 ]]
  if grep -q -- '--model' "$OUT"; then exit 1; fi
}

validation_and_auth_fail_closed() {
  : > "$MARKER"
  set +e
  env -i PATH="$BIN_DIR:/usr/bin:/bin" GEMINI_BIN="$BIN_DIR/gemini-stub" \
    GEMINI_STUB_MARKER="$MARKER" "$ADAPTER" > "$OUT" 2> "$ERR"
  local status=$?
  env -i PATH="$BIN_DIR:/usr/bin:/bin" GEMINI_BIN="$BIN_DIR/gemini-stub" \
    GEMINI_STUB_MARKER="$MARKER" "$ADAPTER" "$PROMPT" "$PROMPT" > "$OUT" 2> "$ERR"
  local extra_status=$?
  set -e
  [[ $status -eq 1 && $extra_status -eq 1 ]]
  assert_not_invoked

  set +e
  env -i PATH="/usr/bin:/bin" HOME="$TEST_HOME" GEMINI_BIN="$TEST_DIR/missing" \
    "$ADAPTER" "$PROMPT" > "$OUT" 2> "$ERR"
  status=$?
  set -e
  [[ $status -eq 2 ]]

  local settings="$TEST_HOME/.gemini/settings.json" fixture variable
  for fixture in missing malformed api-key vertex cloud other overage-missing overage-ask overage-always hooks-configured mcp-configured admin-mcp-config admin-mcp-required admin-policy-paths; do
    write_oauth_settings
    case "$fixture" in
      missing) rm -f "$settings" ;;
      malformed) printf '%s\n' '{bad json' > "$settings" ;;
      api-key) printf '%s\n' '{"security":{"auth":{"selectedType":"gemini-api-key"}}}' > "$settings" ;;
      vertex) printf '%s\n' '{"security":{"auth":{"selectedType":"vertex-ai"}}}' > "$settings" ;;
      cloud) printf '%s\n' '{"security":{"auth":{"selectedType":"gcp"}}}' > "$settings" ;;
      other) printf '%s\n' '{"security":{"auth":{"selectedType":"other"}}}' > "$settings" ;;
      overage-missing) printf '%s\n' '{"security":{"auth":{"selectedType":"oauth-personal"}}}' > "$settings" ;;
      overage-ask) printf '%s\n' '{"security":{"auth":{"selectedType":"oauth-personal"}},"billing":{"overageStrategy":"ask"}}' > "$settings" ;;
      overage-always) printf '%s\n' '{"security":{"auth":{"selectedType":"oauth-personal"}},"billing":{"overageStrategy":"always"}}' > "$settings" ;;
      hooks-configured) printf '%s\n' '{"security":{"auth":{"selectedType":"oauth-personal"}},"billing":{"overageStrategy":"never"},"hooks":{"SessionStart":[{"type":"command","command":"echo hostile"}]}}' > "$settings" ;;
      mcp-configured) printf '%s\n' '{"security":{"auth":{"selectedType":"oauth-personal"}},"billing":{"overageStrategy":"never"},"mcpServers":{"hostile":{"command":"echo","args":["hostile"]}}}' > "$settings" ;;
      admin-mcp-config) printf '%s\n' '{"security":{"auth":{"selectedType":"oauth-personal"}},"billing":{"overageStrategy":"never"},"admin":{"mcp":{"config":{"hostile":{"command":"echo"}}}}}' > "$settings" ;;
      admin-mcp-required) printf '%s\n' '{"security":{"auth":{"selectedType":"oauth-personal"}},"billing":{"overageStrategy":"never"},"admin":{"mcp":{"requiredConfig":{"hostile":{"command":"echo"}}}}}' > "$settings" ;;
      admin-policy-paths) printf '%s\n' '{"security":{"auth":{"selectedType":"oauth-personal"}},"billing":{"overageStrategy":"never"},"adminPolicyPaths":["/tmp/hostile-policy"]}' > "$settings" ;;
    esac
    : > "$MARKER"
    run_adapter measured
    [[ $STATUS -eq 1 ]]
    assert_not_invoked
    grep -qi oauth "$ERR"
  done

  for variable in GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_GENAI_USE_VERTEXAI GOOGLE_APPLICATION_CREDENTIALS GOOGLE_CLOUD_PROJECT GOOGLE_CLOUD_LOCATION GOOGLE_GENAI_USE_GCA GOOGLE_CLOUD_ACCESS_TOKEN; do
    write_oauth_settings
    : > "$MARKER"
    run_adapter measured "$variable=test-value"
    [[ $STATUS -eq 1 ]]
    assert_not_invoked
    grep -q "$variable" "$ERR"
  done

  write_oauth_settings
  : > "$MARKER"
  run_adapter measured GEMINI_TOKEN_LIMIT=-1
  [[ $STATUS -eq 1 ]]
  assert_not_invoked
}

# Gemini CLI's own documented config precedence auto-loads a .env file next
# to settings.json and merges it as environment variables, which override
# settings.json -- a real bypass of the oauth-only check above if unguarded.
global_env_file_blocks_auth() {
  write_oauth_settings
  printf 'GOOGLE_API_KEY=hostile\n' > "$TEST_HOME/.gemini/.env"
  : > "$MARKER"
  run_adapter measured
  [[ $STATUS -eq 1 ]]
  assert_not_invoked
  rm -f "$TEST_HOME/.gemini/.env"
}

# Separately from .gemini/.env, Gemini CLI's plain-.env search unconditionally
# falls back to ~/.env (bare, not inside .gemini/) once its upward directory
# walk finds nothing -- this applies regardless of the invocation's cwd, so
# cwd isolation alone cannot defeat it.
home_env_file_blocks_auth() {
  write_oauth_settings
  printf 'GOOGLE_API_KEY=hostile\n' > "$TEST_HOME/.env"
  : > "$MARKER"
  run_adapter measured
  [[ $STATUS -eq 1 ]]
  assert_not_invoked
  rm -f "$TEST_HOME/.env"
}

# The system settings file outranks the user settings file in Gemini CLI's
# own documented precedence -- if it exists and picks a non-personal auth
# type, it silently wins regardless of what the validated user file says.
system_settings_file_overrides_oauth() {
  write_oauth_settings
  local sys_settings="$TEST_DIR/system-settings.json"
  printf '%s\n' '{"security":{"auth":{"selectedType":"gemini-api-key"}}}' > "$sys_settings"
  : > "$MARKER"
  run_adapter measured "GEMINI_CLI_SYSTEM_SETTINGS_PATH=$sys_settings"
  [[ $STATUS -eq 1 ]]
  assert_not_invoked

  # A system settings file that exists but never selects an auth type at all
  # must not block a call the user-level settings file already approved.
  printf '%s\n' '{"ui":{"theme":"dark"}}' > "$sys_settings"
  : > "$MARKER"
  run_adapter measured "GEMINI_CLI_SYSTEM_SETTINGS_PATH=$sys_settings"
  [[ $STATUS -eq 0 ]]

  # The same precedence applies to overageStrategy: system settings can
  # re-enable paid overage even though the user-level file says "never".
  printf '%s\n' '{"security":{"auth":{"selectedType":"oauth-personal"}},"billing":{"overageStrategy":"always"}}' > "$sys_settings"
  : > "$MARKER"
  run_adapter measured "GEMINI_CLI_SYSTEM_SETTINGS_PATH=$sys_settings"
  [[ $STATUS -eq 1 ]]
  assert_not_invoked

  # ...and to hooks: system settings can configure an arbitrary-command hook
  # even though the user-level file has none.
  printf '%s\n' '{"security":{"auth":{"selectedType":"oauth-personal"}},"billing":{"overageStrategy":"never"},"hooks":{"SessionStart":[{"type":"command","command":"echo hostile"}]}}' > "$sys_settings"
  : > "$MARKER"
  run_adapter measured "GEMINI_CLI_SYSTEM_SETTINGS_PATH=$sys_settings"
  [[ $STATUS -eq 1 ]]
  assert_not_invoked

  # ...and to mcpServers: a server command launches at CLI startup during
  # MCP discovery, before any tool-calling decision is ever made.
  printf '%s\n' '{"security":{"auth":{"selectedType":"oauth-personal"}},"billing":{"overageStrategy":"never"},"mcpServers":{"hostile":{"command":"echo","args":["hostile"]}}}' > "$sys_settings"
  : > "$MARKER"
  run_adapter measured "GEMINI_CLI_SYSTEM_SETTINGS_PATH=$sys_settings"
  [[ $STATUS -eq 1 ]]
  assert_not_invoked
  rm -f "$sys_settings"
}

# The system defaults file is the lowest-precedence real settings file --
# scalar selectedType/overageStrategy are already safe by precedence
# reasoning once the user file requires them explicitly, but hooks/mcpServers
# are checked independently since a higher layer leaving them unset does not
# provably "empty out" a lower layer's value for an object-valued key.
system_defaults_file_hooks_and_mcp_block_auth() {
  write_oauth_settings
  local sys_defaults="$TEST_DIR/system-defaults.json"
  printf '%s\n' '{"ui":{"theme":"dark"}}' > "$sys_defaults"
  : > "$MARKER"
  run_adapter measured "GEMINI_CLI_SYSTEM_DEFAULTS_PATH=$sys_defaults"
  [[ $STATUS -eq 0 ]]

  printf '%s\n' '{"hooks":{"SessionStart":[{"type":"command","command":"echo hostile"}]}}' > "$sys_defaults"
  : > "$MARKER"
  run_adapter measured "GEMINI_CLI_SYSTEM_DEFAULTS_PATH=$sys_defaults"
  [[ $STATUS -eq 1 ]]
  assert_not_invoked

  printf '%s\n' '{"mcpServers":{"hostile":{"command":"echo","args":["hostile"]}}}' > "$sys_defaults"
  : > "$MARKER"
  run_adapter measured "GEMINI_CLI_SYSTEM_DEFAULTS_PATH=$sys_defaults"
  [[ $STATUS -eq 1 ]]
  assert_not_invoked
  rm -f "$sys_defaults"
}

# Gemini CLI also auto-loads a *project* settings.json/.env relative to its
# own cwd, which overrides the user-level file above -- this must never
# depend on wherever the caller happens to invoke the adapter from (for any
# generic pipeline stage, that's an arbitrary, not fully trusted target
# repo). Prove the real invocation runs from an isolated directory, never
# the caller's cwd, regardless of what a "project" directory contains.
isolated_cwd_used_for_invocation() {
  write_oauth_settings
  local project_dir="$TEST_DIR/hostile-project" pwd_log="$TEST_DIR/stub-pwd" out
  mkdir -p "$project_dir/.gemini"
  printf '%s\n' '{"security":{"auth":{"selectedType":"gemini-api-key"}}}' \
    > "$project_dir/.gemini/settings.json"
  printf 'GOOGLE_API_KEY=hostile\n' > "$project_dir/.gemini/.env"
  : > "$MARKER"
  out="$(cd "$project_dir" && env -i \
    PATH="$BIN_DIR:/usr/bin:/bin" HOME="$TEST_HOME" GEMINI_CLI_HOME="$TEST_HOME" \
    GEMINI_BIN="$BIN_DIR/gemini-stub" GEMINI_STUB_MODE=measured GEMINI_STUB_MARKER="$MARKER" \
    GEMINI_STUB_ARGV="$ARGV_LOG" GEMINI_STUB_POLICY="$POLICY_LOG" GEMINI_STUB_PWD_LOG="$pwd_log" \
    "$ADAPTER" "$PROMPT")"
  [[ "$out" == 'Gemini answer' ]]
  [[ -s "$pwd_log" ]]
  [[ "$(cat "$pwd_log")" != "$project_dir" ]]
}

# Isolating the invocation cwd via mktemp does not help if TMPDIR itself
# (the isolated directory's own parent) is caller-controlled and has a
# hostile .env directly inside it -- Gemini CLI's own upward search from the
# isolated cwd would still find it as an ancestor.
hostile_tmpdir_ancestor_env_blocks_auth() {
  write_oauth_settings
  local hostile_tmpdir="$TEST_DIR/hostile-tmpdir"
  mkdir -p "$hostile_tmpdir"
  printf 'GOOGLE_API_KEY=hostile\n' > "$hostile_tmpdir/.env"
  : > "$MARKER"
  run_adapter measured "TMPDIR=$hostile_tmpdir"
  [[ $STATUS -eq 1 ]]
  assert_not_invoked
  rm -rf "$hostile_tmpdir"
}

measured_success_and_limits() {
  write_oauth_settings
  : > "$MARKER"
  run_adapter measured GEMINI_MODEL=requested-alias GEMINI_TOKEN_LIMIT=12
  [[ $STATUS -eq 0 ]]
  [[ "$(cat "$OUT")" == 'Gemini answer' ]]
  [[ "$(grep -c '^e3d_provider_usage=' "$ERR")" -eq 1 ]]
  usage="$(sed -n 's/^e3d_provider_usage=//p' "$ERR")"
  jq -e '.provider == "gemini" and .model == "gemini-2.5-pro-202609" and .tokens == 12 and .cost_usd == 0 and (.cost_usd | type) == "number"' <<< "$usage" >/dev/null
  grep -Fxq -- '--extensions' "$ARGV_LOG"
  grep -Fxq none "$ARGV_LOG"
  grep -Fxq -- '--admin-policy' "$ARGV_LOG"
  if grep -Eqi -- 'yolo|always.approve|allow.list' "$ARGV_LOG"; then exit 1; fi
  grep -Fxq 'toolName = "*"' "$POLICY_LOG"
  grep -Fxq 'decision = "deny"' "$POLICY_LOG"
  if grep -q 'TOP SECRET' "$ARGV_LOG"; then exit 1; fi

  run_adapter at_limit GEMINI_TOKEN_LIMIT=12
  [[ $STATUS -eq 0 ]]
  [[ "$(cat "$OUT")" == 'At limit' ]]

  run_adapter components GEMINI_TOKEN_LIMIT=12
  [[ $STATUS -eq 0 ]]
  usage="$(sed -n 's/^e3d_provider_usage=//p' "$ERR")"
  jq -e '.model == "gemini-components" and .tokens == 12 and .cost_usd == 0' <<< "$usage" >/dev/null

  run_adapter over_limit GEMINI_TOKEN_LIMIT=12
  [[ $STATUS -eq 1 ]]
  [[ ! -s "$OUT" ]]
  if grep -q '^e3d_provider_usage=' "$ERR"; then exit 1; fi
  grep -qi exceeding "$ERR"
}

response_failures_and_unmeasured_usage() {
  local mode
  write_oauth_settings
  for mode in invalid_json explicit_error tool_request tool_stats empty_answer; do
    run_adapter "$mode"
    [[ $STATUS -eq 1 ]]
    [[ ! -s "$OUT" ]]
    if grep -q '^e3d_provider_usage=' "$ERR"; then exit 1; fi
  done

  for mode in unmeasured malformed_usage total_mismatch; do
    run_adapter "$mode"
    [[ $STATUS -eq 0 ]]
    usage="$(sed -n 's/^e3d_provider_usage=//p' "$ERR")"
    jq -e '. == {provider:"gemini",unmeasured:true} and (has("model") | not) and (has("tokens") | not) and (has("cost_usd") | not)' <<< "$usage" >/dev/null
  done

  # A reported total that exceeds prompt+candidates must still win and be
  # enforced -- not get discarded as "unmeasured" merely because it disagrees
  # with an incomplete component breakdown (the bug this regression guards).
  run_adapter conflicting_usage
  [[ $STATUS -eq 0 ]]
  [[ "$(cat "$OUT")" == 'Conflicting usage' ]]
  usage="$(sed -n 's/^e3d_provider_usage=//p' "$ERR")"
  jq -e '. == {provider:"gemini",model:"gemini-exact",tokens:12,cost_usd:0}' <<< "$usage" >/dev/null

  # The same total must still be enforced against the ceiling, not skipped.
  run_adapter conflicting_usage GEMINI_TOKEN_LIMIT=11
  [[ $STATUS -eq 1 ]]
  [[ ! -s "$OUT" ]]
  if grep -q '^e3d_provider_usage=' "$ERR"; then exit 1; fi
}

process_failures_map_to_one() {
  write_oauth_settings
  run_adapter failure
  [[ $STATUS -eq 1 ]]
  [[ ! -s "$OUT" ]]
  grep -q 'stub diagnostic' "$ERR"

  run_adapter timeout GEMINI_TIMEOUT=1
  [[ $STATUS -eq 1 ]]
  [[ ! -s "$OUT" ]]
  grep -q 'stub diagnostic' "$ERR"
  grep -qi timed.out "$ERR"
}

explicit_debate_participation() {
  write_oauth_settings
  local debate_out="$TEST_DIR/debate.out" debate_err="$TEST_DIR/debate.err"
  env -i \
    PATH="$BIN_DIR:$BASH_DIR:/usr/bin:/bin" HOME="$TEST_HOME" GEMINI_CLI_HOME="$TEST_HOME" \
    GEMINI_BIN="$BIN_DIR/gemini-stub" GEMINI_STUB_MODE=measured \
    GEMINI_STUB_MARKER="$MARKER" GEMINI_STUB_ARGV="$ARGV_LOG" GEMINI_STUB_POLICY="$POLICY_LOG" \
    DEVIN_BIN="$BIN_DIR/devin-stub" \
    "$DEBATE" 'Which deterministic answer?' --providers gemini,devin --rounds 1 \
      --synthesizer devin --out-dir "$TEST_DIR/debate" > "$debate_out" 2> "$debate_err"
  grep -q -- 'Round 1 / gemini' "$debate_out"
  grep -q 'Gemini answer' "$debate_out"
  grep -q 'Deterministic peer or synthesis answer' "$debate_out"
  [[ -s "$TEST_DIR/debate/transcript.md" ]]
}

providers_list_includes_gemini() {
  local out
  out="$(env -u LOCAL_MODEL_ENDPOINT "$ROOT/bin/e3d-pilot" providers list)"
  grep -qE '^gemini[[:space:]]' <<<"$out"
}

check_mode_and_availability
dry_run_is_exact_and_safe
validation_and_auth_fail_closed
global_env_file_blocks_auth
home_env_file_blocks_auth
system_settings_file_overrides_oauth
system_defaults_file_hooks_and_mcp_block_auth
isolated_cwd_used_for_invocation
hostile_tmpdir_ancestor_env_blocks_auth
measured_success_and_limits
response_failures_and_unmeasured_usage
process_failures_map_to_one
explicit_debate_participation
providers_list_includes_gemini

echo "phase34: ok"
