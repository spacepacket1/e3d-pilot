#!/usr/bin/env bash
set -euo pipefail

# Remote (streamable HTTP) transport: auth, origin/host checks, sessions, tool allowlist, limits.
# Real curl against servers on random loopback ports; the debate binary is a stub, so no credits are spent.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER="$ROOT/bin/e3d-mcp"
TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-assert_eq}: expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "${3:-assert_contains}: expected to find [$2] in [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "${3:-assert_not_contains}: did not expect [$2] in [$1]"; }

STUB="$TMP/stub-debate"; CALLS="$TMP/stub-calls"; : > "$CALLS"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do case "$1" in --out-dir) out="$2"; shift 2 ;; *) shift ;; esac; done
echo call >> "$STUB_CALLS"
[[ -n "${STUB_SLEEP:-}" ]] && sleep "$STUB_SLEEP"
mkdir -p "$out"
printf '# Debate\n\n## Round 1 -- claude\n\nJSON file.\n\n## Round 1 -- codex\n\nSQLite.\n' > "$out/transcript.md"
printf 'FINAL ANSWER: Use JSON.\nCONSENSUS: split\nDISSENT: Codex prefers SQLite.\n'
STUBEOF
chmod +x "$STUB"

ALICE="alice-token-0123456789abcdef"; BOB="bob-token-fedcba9876543210"
TOKENS="alice:$ALICE,bob:$BOB"

# start <name> [VAR=value ...]  -> sets PORT_<name>; server stderr in $TMP/<name>.err
start() {
  local name="$1"; shift
  env E3D_MCP_PORT_FILE="$TMP/$name.port" E3D_MCP_STATE_DIR="$TMP/state-$name" E3D_MCP_DEBATE_BIN="$STUB" STUB_CALLS="$CALLS" \
    TYPESAFE_API_KEY="" E3D_MCP_PRINCIPAL="" "$@" "$SERVER" --http --port 0 2> "$TMP/$name.err" &
  PIDS+=($!); LAST_PID=$!
  for _ in $(seq 1 80); do [[ -s "$TMP/$name.port" ]] && break; sleep 0.1; done
  [[ -s "$TMP/$name.port" ]] || { cat "$TMP/$name.err" >&2; fail "server $name did not start"; }
  eval "PORT_$name=$(cat "$TMP/$name.port")"
}
port() { local v="PORT_$1"; echo "${!v}"; }

# http <name> <curl args...>  -> prints "<status>\n<body>"; headers in $TMP/headers
http() {
  local name="$1"; shift
  curl -s -m 30 -D "$TMP/headers" -o "$TMP/body" -w '%{http_code}' "$@" "http://127.0.0.1:$(port "$name")${HTTP_PATH:-/mcp}"; echo; cat "$TMP/body"; echo
}
status() { head -1 <<< "$1"; }
body() { tail -n +2 <<< "$1"; }
hdr() { grep -i "^$1:" "$TMP/headers" | head -1 | sed -E 's/^[^:]+: *//' | tr -d '\r'; }
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"sampling":{},"elicitation":{},"roots":{}},"clientInfo":{"name":"curl-test","version":"0"}}}'
J=(-H 'content-type: application/json' -H 'accept: application/json')
auth() { printf '%s\n' "Authorization: Bearer $1"; }
# session <name> <token|-> -> prints a fresh session id
session() {
  local name="$1" tok="$2" a=()
  [[ "$tok" != "-" ]] && a=(-H "$(auth "$tok")")
  http "$name" -X POST "${J[@]}" "${a[@]}" -d "$INIT" >/dev/null
  hdr mcp-session-id
}
call() {  # call <name> <token|-> <sid> <json>
  local name="$1" tok="$2" sid="$3" a=()
  [[ "$tok" != "-" ]] && a=(-H "$(auth "$tok")")
  http "$name" -X POST "${J[@]}" "${a[@]}" -H "mcp-session-id: $sid" -d "$4"
}
tool() {  # tool <name> <token|-> <sid> <tool-name> <args-json>
  call "$1" "$2" "$3" "$(jq -nc --arg n "$4" --argjson a "$5" '{jsonrpc:"2.0",id:7,method:"tools/call",params:{name:$n,arguments:$a}}')"
}

# ---------------- refusing to start unsafely ----------------
out="$(env E3D_MCP_AUTH_TOKENS="" "$SERVER" --http --host 0.0.0.0 --port 0 2>&1)" && fail "non-loopback without auth must refuse to start" || rc=$?
assert_eq "${rc:-0}" "2" "exit code"; assert_contains "$out" "requires auth"
out="$(env E3D_MCP_AUTH_TOKENS="alice:short" "$SERVER" --http --port 0 2>&1)" && fail "weak token must be rejected" || true
assert_contains "$out" "shorter than 16"
out="$(env E3D_MCP_AUTH_TOKENS="notaname" "$SERVER" --http --port 0 2>&1)" && fail "malformed token spec must be rejected" || true
assert_contains "$out" "name:token"

# ---------------- server A: tokens, default safe tools, budgets ----------------
start A E3D_MCP_AUTH_TOKENS="$TOKENS" E3D_MCP_DAILY_CALLS=4 E3D_MCP_MAX_BODY_BYTES=4000
assert_contains "$(cat "$TMP/A.err")" '"timeoutMs":120000'   # hosted default keeps tool calls under typical load-balancer timeouts

HTTP_PATH=/healthz; r="$(http A)"; assert_eq "$(status "$r")" "200" "healthz needs no auth"; assert_contains "$(body "$r")" '"status":"ok"'
assert_not_contains "$(body "$r")" "$ALICE"
HTTP_PATH=/nope; r="$(http A)"; assert_eq "$(status "$r")" "404"
HTTP_PATH=/readyz; r="$(http A)"; assert_eq "$(status "$r")" "404" "readyz exists only with the external auth hook"
HTTP_PATH=/mcp

# auth matrix
r="$(http A -X POST "${J[@]}" -d "$INIT")"; assert_eq "$(status "$r")" "401" "no credentials"; assert_contains "$(hdr www-authenticate)" "Bearer"
r="$(http A -X POST "${J[@]}" -H "$(auth wrong-token-0123456789)" -d "$INIT")"; assert_eq "$(status "$r")" "401" "wrong token"
r="$(http A -X POST "${J[@]}" -H "Authorization: Basic $ALICE" -d "$INIT")"; assert_eq "$(status "$r")" "401" "wrong scheme"
r="$(http A -X POST "${J[@]}" -H "$(auth "${ALICE:0:10}")" -d "$INIT")"; assert_eq "$(status "$r")" "401" "a token prefix must not work"
r="$(http A -X POST "${J[@]}" -H "$(auth "$ALICE")" -d "$INIT")"; assert_eq "$(status "$r")" "200" "valid token"
SID_ALICE="$(hdr mcp-session-id)"; [[ ${#SID_ALICE} -ge 32 ]] || fail "session id should be long and random"
assert_eq "$(jq -r .result.serverInfo.name <<< "$(body "$r")")" "e3d-pilot"
SID_BOB="$(session A "$BOB")"

# origin and host defenses (DNS rebinding)
r="$(http A -X POST "${J[@]}" -H "$(auth "$ALICE")" -H 'Origin: http://evil.example' -d "$INIT")"; assert_eq "$(status "$r")" "403" "foreign origin"
r="$(http A -X POST "${J[@]}" -H "$(auth "$ALICE")" -H 'Origin: http://localhost:3000' -d "$INIT")"; assert_eq "$(status "$r")" "200" "loopback origin is fine on a loopback server"
r="$(http A -X POST "${J[@]}" -H "$(auth "$ALICE")" -H 'Host: evil.example' -d "$INIT")"; assert_eq "$(status "$r")" "403" "foreign Host header on a loopback server"

# methods, content negotiation, framing
r="$(http A -X GET -H "$(auth "$ALICE")")"; assert_eq "$(status "$r")" "405"; assert_contains "$(hdr allow)" "POST"
r="$(http A -X PUT -H "$(auth "$ALICE")")"; assert_eq "$(status "$r")" "405"
r="$(http A -X POST -H 'content-type: text/plain' -H "$(auth "$ALICE")" -d "$INIT")"; assert_eq "$(status "$r")" "415"
r="$(http A -X POST -H 'content-type: application/json' -H 'accept: text/html' -H "$(auth "$ALICE")" -d "$INIT")"; assert_eq "$(status "$r")" "406"
r="$(http A -X POST "${J[@]}" -H "$(auth "$ALICE")" -H 'MCP-Protocol-Version: 1999-01-01' -d "$INIT")"; assert_eq "$(status "$r")" "400" "unknown protocol version"
r="$(http A -X POST "${J[@]}" -H "$(auth "$ALICE")" -d "[$INIT]")"; assert_eq "$(status "$r")" "400" "batches are not accepted"; assert_eq "$(jq -r .error.code <<< "$(body "$r")")" "-32600"
r="$(http A -X POST "${J[@]}" -H "$(auth "$ALICE")" -d '{not json')"; assert_eq "$(status "$r")" "400"; assert_eq "$(jq -r .error.code <<< "$(body "$r")")" "-32700"

# sessions
r="$(http A -X POST "${J[@]}" -H "$(auth "$ALICE")" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"; assert_eq "$(status "$r")" "400" "no session header"
r="$(call A "$ALICE" bogus-session '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"; assert_eq "$(status "$r")" "404" "unknown session"
r="$(call A "$BOB" "$SID_ALICE" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"; assert_eq "$(status "$r")" "404" "a session belongs to the principal that created it"
r="$(call A "$ALICE" "$SID_ALICE" '{"jsonrpc":"2.0","method":"notifications/initialized"}')"; assert_eq "$(status "$r")" "202" "notifications get 202"
r="$(call A "$ALICE" "$SID_ALICE" '{"jsonrpc":"2.0","id":3,"method":"ping"}')"; assert_eq "$(status "$r")" "200"; assert_eq "$(jq -c .result <<< "$(body "$r")")" "{}"
r="$(http A -X DELETE -H "$(auth "$BOB")" -H "mcp-session-id: $SID_ALICE")"; assert_eq "$(status "$r")" "404" "another principal cannot end my session"

# only the safe tools by default; everything else looks nonexistent
r="$(call A "$ALICE" "$SID_ALICE" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
assert_eq "$(jq -r '.result.tools | map(.name) | sort | join(",")' <<< "$(body "$r")")" "e3d_debate,e3d_list_providers,e3d_usage" "hosted default tool set"
r="$(tool A "$ALICE" "$SID_ALICE" e3d_pilot_config_check '{"repo":"/tmp"}')"
assert_eq "$(jq -r .error.code <<< "$(body "$r")")" "-32602" "pipeline tools are not reachable by default"
assert_contains "$(jq -r .error.message <<< "$(body "$r")")" "unknown tool"
r="$(tool A "$ALICE" "$SID_ALICE" e3d_not_a_tool '{}')"
assert_eq "$(jq -r .error.message <<< "$(body "$r")" | sed 's/e3d_not_a_tool//;s/e3d_pilot_config_check//')" "unknown tool: " "a hidden tool and a missing tool are indistinguishable"

# sampling and elicitation are off over HTTP even if the client claims them
r="$(tool A "$ALICE" "$SID_ALICE" e3d_list_providers '{}')"
assert_not_contains "$(jq -r '.result.content[0].text' <<< "$(body "$r")")" "mcp-sampling:" "no sampling voices in hosted mode"
# (no stub debate binary here, so the real provider checks run; the refusal happens before any debate process starts)
start F E3D_MCP_DEBATE_BIN=""
SF="$(session F -)"
r="$(tool F - "$SF" e3d_debate '{"question":"q","providers":["mcp-sampling","mcp-sampling-b"]}')"
assert_eq "$(jq -r '.result.isError' <<< "$(body "$r")")" "true" "sampling voices are refused over HTTP"; assert_contains "$(jq -r '.result.content[0].text' <<< "$(body "$r")")" "supports sampling"

# a debate over HTTP: usage + budget, per-principal cap, refusal without spending
r="$(tool A "$ALICE" "$SID_ALICE" e3d_debate '{"question":"JSON or SQLite?","providers":["claude","codex"]}')"
res="$(jq -c .result.structuredContent <<< "$(body "$r")")"
assert_eq "$(jq -r .consensus <<< "$res")" "split"
assert_eq "$(jq -r .usage.model_calls <<< "$res")" "3"
assert_eq "$(jq -r .budget.principal <<< "$res")" "alice" "the token name is the budget principal"
assert_eq "$(jq -r .budget.calls_limit <<< "$res")" "4"
before="$(wc -l < "$CALLS" | tr -d ' ')"
r="$(tool A "$ALICE" "$SID_ALICE" e3d_debate '{"question":"again","providers":["claude","codex"]}')"
assert_eq "$(jq -r '.result.isError' <<< "$(body "$r")")" "true" "3 + worst case 3 > 4"
assert_contains "$(jq -r '.result.content[0].text' <<< "$(body "$r")")" "daily budget"
assert_eq "$(wc -l < "$CALLS" | tr -d ' ')" "$before" "a refused debate never runs"
r="$(tool A "$BOB" "$SID_BOB" e3d_usage '{}')"; assert_eq "$(jq -r .result.structuredContent.calls_today <<< "$(body "$r")")" "0" "bob's budget is untouched"
r="$(tool A "$ALICE" "$SID_ALICE" e3d_usage '{}')"; assert_eq "$(jq -r .result.structuredContent.calls_today <<< "$(body "$r")")" "3"

# body size cap (declared and chunked), server stays healthy
head -c 6000 /dev/zero | tr '\0' 'x' > "$TMP/big.json"
r="$(http A -X POST "${J[@]}" -H "$(auth "$ALICE")" --data-binary @"$TMP/big.json")"; assert_eq "$(status "$r")" "413" "declared size over the cap"
r="$(http A -X POST "${J[@]}" -H "$(auth "$ALICE")" -H 'Transfer-Encoding: chunked' --data-binary @"$TMP/big.json")"; assert_eq "$(status "$r")" "413" "chunked body over the cap"
HTTP_PATH=/healthz; r="$(http A)"; assert_eq "$(status "$r")" "200" "still alive after oversized bodies"; HTTP_PATH=/mcp

# session end
r="$(http A -X DELETE -H "$(auth "$ALICE")" -H "mcp-session-id: $SID_ALICE")"; assert_eq "$(status "$r")" "204"
r="$(call A "$ALICE" "$SID_ALICE" '{"jsonrpc":"2.0","id":2,"method":"ping"}')"; assert_eq "$(status "$r")" "404" "an ended session is gone"

# tokens are never logged
assert_not_contains "$(cat "$TMP/A.err")" "$ALICE" "tokens must not appear in logs"
assert_not_contains "$(cat "$TMP/A.err")" "$BOB"
assert_contains "$(cat "$TMP/A.err")" "principal=alice"

# ---------------- server B: rate limiting per principal ----------------
start B E3D_MCP_AUTH_TOKENS="$TOKENS" E3D_MCP_RATE_PER_MIN=5
SB="$(session B "$ALICE")"   # 1 request
for i in 2 3 4 5; do r="$(call B "$ALICE" "$SB" '{"jsonrpc":"2.0","id":2,"method":"ping"}')"; assert_eq "$(status "$r")" "200" "request $i of 5"; done
r="$(call B "$ALICE" "$SB" '{"jsonrpc":"2.0","id":2,"method":"ping"}')"; assert_eq "$(status "$r")" "429" "6th request in a minute"
[[ -n "$(hdr retry-after)" ]] || fail "429 must carry Retry-After"
r="$(http B -X POST "${J[@]}" -H "$(auth "$BOB")" -d "$INIT")"; assert_eq "$(status "$r")" "200" "bob has his own window"

# ---------------- server C: opt in to every tool; loopback without tokens; hosted budget defaults ----------------
start C E3D_MCP_HTTP_TOOLS='*'
SC="$(session C -)"
r="$(call C - "$SC" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
assert_eq "$(jq -r '.result.tools | length' <<< "$(body "$r")")" "17" "E3D_MCP_HTTP_TOOLS=* exposes everything"
r="$(tool C - "$SC" e3d_usage '{}')"; assert_eq "$(jq -r .result.structuredContent.calls_limit <<< "$(body "$r")")" "100" "hosted mode ships with finite default budgets"
assert_eq "$(jq -r .result.structuredContent.principal <<< "$(body "$r")")" "local"
start C2 E3D_MCP_HTTP_TOOLS='e3d_usage,e3d_debate' E3D_MCP_ALLOWED_ORIGINS='https://app.example'
r="$(http C2 -X POST "${J[@]}" -H 'Origin: https://app.example' -d "$INIT")"; assert_eq "$(status "$r")" "200" "an explicitly allowed origin"
r="$(http C2 -X POST "${J[@]}" -H 'Origin: http://localhost:3000' -d "$INIT")"; assert_eq "$(status "$r")" "403" "an explicit origin list replaces the loopback default"
SC2="$(session C2 -)"
r="$(call C2 - "$SC2" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"; assert_eq "$(jq -r '.result.tools | map(.name) | sort | join(",")' <<< "$(body "$r")")" "e3d_debate,e3d_usage"

# ---------------- server D: in-flight cap and request timeout (slow stub) ----------------
start D E3D_MCP_HTTP_MAX_INFLIGHT=1 STUB_SLEEP=3
SD="$(session D -)"
( tool D - "$SD" e3d_debate '{"question":"slow","providers":["claude","codex"]}' > "$TMP/slow.out" ) &
SLOWPID=$!
sleep 1
r="$(call D - "$SD" '{"jsonrpc":"2.0","id":2,"method":"ping"}')"; assert_eq "$(status "$r")" "503" "busy server sheds load"
wait "$SLOWPID"; assert_eq "$(head -1 "$TMP/slow.out")" "200" "the in-flight request still completes"
start D2 E3D_MCP_HTTP_REQUEST_TIMEOUT_SEC=1 STUB_SLEEP=3
SD2="$(session D2 -)"
r="$(tool D2 - "$SD2" e3d_debate '{"question":"slow","providers":["claude","codex"]}')"; assert_eq "$(status "$r")" "504" "per-request timeout"

# ---------------- server E: session cap ----------------
start E E3D_MCP_MAX_SESSIONS=2
session E - >/dev/null; session E - >/dev/null
r="$(http E -X POST "${J[@]}" -d "$INIT")"; assert_eq "$(status "$r")" "503" "third session over the cap"

# ---------------- graceful shutdown ----------------
kill -TERM "$LAST_PID"
for _ in $(seq 1 30); do kill -0 "$LAST_PID" 2>/dev/null || break; sleep 0.2; done
kill -0 "$LAST_PID" 2>/dev/null && fail "SIGTERM should stop the server promptly"
assert_contains "$(cat "$TMP/E.err")" "shutting down"

echo "mcp-http.sh: ok"
