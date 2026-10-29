#!/usr/bin/env bash
set -euo pipefail

# Debate execution slots with a first-in-first-out wait (lib/mcp/slots.js, wired in bin/e3d-mcp): unit tests, then the real server (--http)
# against the reference stub service with a slow stub debate binary and one slot. Loopback only, no model calls.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUB="$ROOT/examples/external-auth-stub.js"
SERVER="$ROOT/bin/e3d-mcp"
TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-assert_eq}: expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "${3:-assert_contains}: expected to find [$2] in [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "${3:-assert_not_contains}: did not expect [$2] in [$1]"; }

# ---- unit level ----
node "$ROOT/tests/fixtures/slots-unit.mjs" | tee "$TMP/unit.out"
assert_contains "$(cat "$TMP/unit.out")" "slots unit tests:"

# ---- the real server ----
SVC="svc-MARKER-$(openssl rand -hex 12)"
TOK_A="caller-MARKER-a-$(openssl rand -hex 12)"; TOK_B="caller-MARKER-b-$(openssl rand -hex 12)"; TOK_C="caller-MARKER-c-$(openssl rand -hex 12)"
jq -n --arg a "$TOK_A" --arg b "$TOK_B" --arg c "$TOK_C" '{accounts: [
  {principal: "acct_a", balance: 1000000, keys: [{id: "key-a", token: $a}]},
  {principal: "acct_b", balance: 1000000, keys: [{id: "key-b", token: $b}]},
  {principal: "acct_c", balance: 1000000, keys: [{id: "key-c", token: $c}]}]}' > "$TMP/seed.json"
env STUB_SERVICE_TOKEN="$SVC" STUB_SEED="$TMP/seed.json" STUB_URL_FILE="$TMP/stub.url" node "$STUB" > "$TMP/stub.out" 2> "$TMP/stub.log" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$TMP/stub.url" ]] && break; sleep 0.05; done
[[ -s "$TMP/stub.url" ]] || fail "stub did not start: $(cat "$TMP/stub.log")"
URL="$(cat "$TMP/stub.url")"
ledger() { curl -fsS -H "authorization: Bearer $SVC" "$URL/_stub/state"; }

MARK="$(openssl rand -hex 4)"
Q="QCONTENT-$MARK: a JSON file or SQLite?"
DEBATE="$TMP/stub-debate"
cat > "$DEBATE" <<STUBEOF
#!/usr/bin/env bash
out=""
while [[ \$# -gt 0 ]]; do case "\$1" in --out-dir) out="\$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p "\$out"
printf '# Debate\n\n## Round 1 -- claude\n\nTCONTENT-$MARK JSON file.\n\n## Round 1 -- codex\n\nSQLite.\n' > "\$out/transcript.md"
sleep 2
printf 'FINAL ANSWER: ACONTENT-$MARK use a JSON file.\nCONSENSUS: split\nDISSENT: Codex prefers SQLite.\n'
STUBEOF
chmod +x "$DEBATE"

start_server() {
  local name="$1"; shift
  : > "$TMP/$name.port"
  env E3D_MCP_AUTH_URL="$URL" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" E3D_MCP_STATE_DIR="$TMP/state-$name" E3D_MCP_PORT_FILE="$TMP/$name.port" \
    E3D_MCP_DEBATE_BIN="$DEBATE" TYPESAFE_API_KEY="" E3D_MCP_PRINCIPAL="" E3D_MCP_AUTH_CACHE_SEC=1 E3D_MCP_TIMEOUT_SEC=20 E3D_MCP_AUTH_HEALTH_SEC=1 \
    E3D_MCP_RATE_PER_MIN=100000 "$@" "$SERVER" --http --port 0 2>> "$TMP/$name.log" &
  local pid=$!; PIDS+=("$pid"); eval "PID_$name=$pid"
  for _ in $(seq 1 100); do [[ -s "$TMP/$name.port" ]] && break; sleep 0.1; done
  [[ -s "$TMP/$name.port" ]] || { cat "$TMP/$name.log" >&2; fail "server $name did not start"; }
  eval "PORT_$name=$(cat "$TMP/$name.port")"
}
sport() { local v="PORT_$1"; echo "${!v}"; }
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"slots-test","version":"0"}}}'
J=(-H 'content-type: application/json' -H 'accept: application/json')
# sid_of <server> <token> -> the MCP session id
sid_of() { curl -s -m 30 -D "$TMP/h.$$" -o /dev/null "${J[@]}" -H "Authorization: Bearer $2" -d "$INIT" "http://127.0.0.1:$(sport "$1")/mcp"; grep -i '^mcp-session-id:' "$TMP/h.$$" | head -1 | sed -E 's/^[^:]+: *//' | tr -d '\r'; }
# debate <server> <token> <sid> <outfile>: a synchronous e3d_debate call; writes "<seconds> <isError> <text>" to the outfile
debate() {
  local args; args="$(jq -nc --arg q "$Q" '{question:$q,providers:["claude","codex"]}')"
  local t0=$SECONDS
  local out; out="$(curl -s -m 60 "${J[@]}" -H "Authorization: Bearer $2" -H "mcp-session-id: $3" \
    -d "$(jq -nc --argjson a "$args" '{jsonrpc:"2.0",id:7,method:"tools/call",params:{name:"e3d_debate",arguments:$a}}')" "http://127.0.0.1:$(sport "$1")/mcp")"
  echo "$((SECONDS - t0)) $(jq -r '.result.isError // false' <<< "$out") $(jq -r '.result.content[0].text' <<< "$out" | tr '\n' ' ' | cut -c1-240)" > "$4"
}

# --- three callers, one slot, a 2 s debate: all three are answered, one after the other, none is bounced ---
start_server Q1 E3D_MCP_MAX_CONCURRENT=1 E3D_MCP_QUEUE_WAIT_SEC=30
SA="$(sid_of Q1 "$TOK_A")"; SB="$(sid_of Q1 "$TOK_B")"; SC="$(sid_of Q1 "$TOK_C")"
[[ -n "$SA" && -n "$SB" && -n "$SC" ]] || fail "no session ids"
T0=$SECONDS
debate Q1 "$TOK_A" "$SA" "$TMP/o1" & P1=$!; sleep 0.3
debate Q1 "$TOK_B" "$SB" "$TMP/o2" & P2=$!; sleep 0.3
debate Q1 "$TOK_C" "$SC" "$TMP/o3" & P3=$!
wait "$P1" "$P2" "$P3"
ELAPSED=$((SECONDS - T0))
for f in o1 o2 o3; do assert_eq "$(cut -d' ' -f2 "$TMP/$f")" "false" "$f: no error ($(cat "$TMP/$f"))"; assert_contains "$(cat "$TMP/$f")" "ACONTENT-$MARK" "$f: the answer"; done
(( ELAPSED >= 5 )) || fail "one slot and a 2 s debate: three debates must take about 6 s, took ${ELAPSED}s"
assert_eq "$(ledger | jq '[.reservations[]] | length')" "3" "three reservations"
assert_contains "$(cat "$TMP/Q1.log")" "debate slot: granted after waiting" "the wait is logged"
assert_contains "$(cat "$TMP/Q1.log")" "debate slot: released after" "the run time is logged"
SLOTLOG="$(grep 'debate slot:' "$TMP/Q1.log")"
assert_not_contains "$SLOTLOG" "QCONTENT" "no question in the slot lines"
assert_not_contains "$SLOTLOG" "acct_" "no principal in the slot lines"
echo "ok - one slot, three callers: all answered in turn (${ELAPSED}s), none bounced, the wait and run time logged without identifying data"

# --- a wait that runs out is refused, honestly, and nothing is charged ---
start_server Q2 E3D_MCP_MAX_CONCURRENT=1 E3D_MCP_QUEUE_WAIT_SEC=1
SA="$(sid_of Q2 "$TOK_A")"; SB="$(sid_of Q2 "$TOK_B")"
n0="$(ledger | jq '[.reservations[] | select(.state != "released" and .state != "aborted")] | length')"
debate Q2 "$TOK_A" "$SA" "$TMP/p1" & P1=$!; sleep 0.4
debate Q2 "$TOK_B" "$SB" "$TMP/p2"
wait "$P1"
assert_eq "$(cut -d' ' -f2 "$TMP/p1")" "false" "the first debate runs"
assert_eq "$(cut -d' ' -f2 "$TMP/p2")" "true" "the second waited 1 s and was refused"
assert_contains "$(cat "$TMP/p2")" "waited 1s for a free slot" "says what happened"
assert_contains "$(cat "$TMP/p2")" "nothing was charged" "and that nothing was charged"
assert_contains "$(cat "$TMP/p2")" "e3d_debate_start" "and where to go for a burst"
assert_contains "$(cat "$TMP/Q2.log")" "debate slot: refused (timeout" "the refusal is logged"
echo "ok - a wait that times out is refused with the reason, nothing charged, and a pointer to the async tool"

# --- waiting off (0): the old behaviour, an immediate refusal ---
start_server Q3 E3D_MCP_MAX_CONCURRENT=1 E3D_MCP_QUEUE_WAIT_SEC=0
SA="$(sid_of Q3 "$TOK_A")"; SB="$(sid_of Q3 "$TOK_B")"
debate Q3 "$TOK_A" "$SA" "$TMP/r1" & P1=$!; sleep 0.4
debate Q3 "$TOK_B" "$SB" "$TMP/r2"; wait "$P1"
assert_eq "$(cut -d' ' -f2 "$TMP/r2")" "true"; assert_contains "$(cat "$TMP/r2")" "debates are already running"
(( $(cut -d' ' -f1 "$TMP/r2") <= 1 )) || fail "with waiting off the refusal must be immediate"
echo "ok - E3D_MCP_QUEUE_WAIT_SEC=0 refuses at once, as before"

# --- the proxy budget warning, and the README rows ---
start_server Q4 E3D_MCP_QUEUE_WAIT_SEC=200 E3D_MCP_TIMEOUT_SEC=200
assert_contains "$(cat "$TMP/Q4.log")" "longer than the proxy read timeout" "a wait plus timeout over the proxy limit is flagged at startup"
for v in E3D_MCP_QUEUE_WAIT_SEC E3D_MCP_QUEUE_MAX; do grep -q "| \`$v\` |" "$ROOT/README.md" || fail "README table is missing $v"; done
echo "ok - the startup warning names the proxy budget; README documents the settings"
