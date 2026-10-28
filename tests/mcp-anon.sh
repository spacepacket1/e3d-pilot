#!/usr/bin/env bash
set -euo pipefail

# Opt-in anonymous discovery (E3D_MCP_ANON_DISCOVERY=on): off by default and then byte-for-byte the old 401s; on, only
# initialize / notifications/initialized / ping / tools/list / prompts/list run without a credential. Real curl on loopback,
# stub debate binary, stub auth service; no credits are spent.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER="$ROOT/bin/e3d-mcp"
STUBAUTH="$ROOT/examples/external-auth-stub.js"
TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-assert_eq}: expected [$2], got [$1]"; }

DEBATE="$TMP/stub-debate"; printf '#!/usr/bin/env bash\nprintf "FINAL ANSWER: x\\nCONSENSUS: full\\nDISSENT: none\\n"\n' > "$DEBATE"; chmod +x "$DEBATE"
ALICE="alice-token-0123456789abcdef"
SVC="svc-$(openssl rand -hex 16)"; HOOKTOK="hook-token-$(openssl rand -hex 12)"
jq -n --arg t "$HOOKTOK" '{accounts: [{principal: "acct_ok", balance: 1000000, keys: [{id: "k1", token: $t}]}]}' > "$TMP/seed.json"
env STUB_SERVICE_TOKEN="$SVC" STUB_SEED="$TMP/seed.json" STUB_URL_FILE="$TMP/stub.url" node "$STUBAUTH" > "$TMP/stub.out" 2> "$TMP/stub.log" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$TMP/stub.url" ]] && break; sleep 0.05; done
[[ -s "$TMP/stub.url" ]] || fail "auth stub did not start"

# start <name> <mode: tokens|hook> [VAR=value ...]
start() {
  local name="$1" mode="$2"; shift 2
  local auth=(E3D_MCP_AUTH_TOKENS="alice:$ALICE")
  [[ "$mode" == hook ]] && auth=(E3D_MCP_AUTH_URL="$(cat "$TMP/stub.url")" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC")
  env E3D_MCP_PORT_FILE="$TMP/$name.port" E3D_MCP_STATE_DIR="$TMP/state-$name" E3D_MCP_DEBATE_BIN="$DEBATE" TYPESAFE_API_KEY="" E3D_MCP_PRINCIPAL="" \
    E3D_MCP_RATE_PER_MIN=100000 "${auth[@]}" "$@" "$SERVER" --http --port 0 2> "$TMP/$name.err" &
  PIDS+=("$!")
  for _ in $(seq 1 100); do [[ -s "$TMP/$name.port" ]] && break; sleep 0.1; done
  [[ -s "$TMP/$name.port" ]] || { cat "$TMP/$name.err" >&2; fail "server $name did not start"; }
}
J=(-H 'content-type: application/json' -H 'accept: application/json')
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl-test","version":"0"}}}'
LIST='{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
CALL='{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"e3d_list_providers","arguments":{}}}'
# req <name> <json> [curl args...] -> sets CODE, BODY, SID, WWW (headers) from one request
req() {
  local name="$1" data="$2"; shift 2
  CODE="$(curl -s -m 30 -D "$TMP/h" -o "$TMP/b" -w '%{http_code}' -X POST "${J[@]}" "$@" -d "$data" "http://127.0.0.1:$(cat "$TMP/$name.port")/mcp")"
  BODY="$(cat "$TMP/b")"
  SID="$(grep -i '^mcp-session-id:' "$TMP/h" | sed -E 's/^[^:]+: *//' | tr -d '\r' || true)"
  WWW="$(grep -i '^www-authenticate:' "$TMP/h" | sed -E 's/^[^:]+: *//' | tr -d '\r' || true)"
}
is401() { assert_eq "$CODE" "401" "$1: status"; assert_eq "$BODY" '{"error":"unauthorized"}' "$1: body"; assert_eq "$WWW" 'Bearer realm="e3d-mcp"' "$1: www-authenticate"; }

for mode in tokens hook; do
  GOOD=( -H "Authorization: Bearer $([[ $mode == hook ]] && echo "$HOOKTOK" || echo "$ALICE")" )

  # ---- flag unset, or anything but exactly "on": the old behaviour
  start "off-$mode" "$mode"
  req "off-$mode" "$INIT"; is401 "$mode unset: initialize"
  req "off-$mode" "$LIST"; is401 "$mode unset: tools/list"
  req "off-$mode" "$INIT" "${GOOD[@]}"; assert_eq "$CODE" "200" "$mode unset: authenticated initialize"
  for v in ON On 1 true yes " on" "on " off ""; do
    start "v-$mode" "$mode" E3D_MCP_ANON_DISCOVERY="$v"
    req "v-$mode" "$INIT"; is401 "$mode [$v]: initialize"
    req "v-$mode" "$LIST"; is401 "$mode [$v]: tools/list"
    kill "${PIDS[-1]}" 2>/dev/null || true; rm -f "$TMP/v-$mode.port"
  done
  echo "ok - $mode: flag unset or not exactly 'on': no-credential initialize and tools/list are the old 401"

  # ---- flag on
  start "on-$mode" "$mode" E3D_MCP_ANON_DISCOVERY=on E3D_MCP_ANON_IP_PER_MIN=12
  n="on-$mode"
  req "$n" "$INIT"; assert_eq "$CODE" "200" "anonymous initialize"; ASID="$SID"; [[ -n "$ASID" ]] || fail "anonymous initialize returned no session"
  req "$n" '{"jsonrpc":"2.0","method":"notifications/initialized"}' -H "mcp-session-id: $ASID"; assert_eq "$CODE" "202" "anonymous notifications/initialized"
  req "$n" '{"jsonrpc":"2.0","id":9,"method":"ping"}' -H "mcp-session-id: $ASID"; assert_eq "$CODE" "200" "anonymous ping"
  req "$n" "$LIST" -H "mcp-session-id: $ASID"; assert_eq "$CODE" "200" "anonymous tools/list"
  ANON_LIST="$BODY"
  req "$n" "$LIST" "${GOOD[@]}" -H "mcp-session-id: $ASID"; assert_eq "$CODE" "404" "an anonymous session id with a valid token"
  req "$n" "$INIT" "${GOOD[@]}"; assert_eq "$CODE" "200" "authenticated initialize"; BSID="$SID"
  req "$n" "$LIST" "${GOOD[@]}" -H "mcp-session-id: $BSID"; assert_eq "$CODE" "200" "authenticated tools/list"; AUTH_LIST="$BODY"
  # the anonymous list is only what a customer's default list shows: same names, descriptions and schemas, nothing else
  assert_eq "$(jq -S '.result' <<< "$ANON_LIST")" "$(jq -S '.result' <<< "$AUTH_LIST")" "anonymous tools/list equals the authenticated one"
  req "$n" "$LIST" -H "mcp-session-id: $BSID"; assert_eq "$CODE" "404" "an authenticated session id without a credential"
  req "$n" '{"jsonrpc":"2.0","id":4,"method":"prompts/list"}' -H "mcp-session-id: $ASID"; assert_eq "$CODE" "200" "anonymous prompts/list"
  # everything else: the existing 401
  req "$n" "$CALL" -H "mcp-session-id: $ASID"; is401 "anonymous tools/call"
  req "$n" "$CALL" -H "mcp-session-id: $BSID"; is401 "anonymous tools/call with an authenticated session id"
  req "$n" '{"jsonrpc":"2.0","id":5,"method":"prompts/get","params":{"name":"e3d-budget"}}' -H "mcp-session-id: $ASID"; is401 "anonymous prompts/get"
  req "$n" '{"jsonrpc":"2.0","id":6,"method":"resources/list"}' -H "mcp-session-id: $ASID"; is401 "anonymous resources/list"
  req "$n" '{"jsonrpc":"2.0","method":"notifications/cancelled"}' -H "mcp-session-id: $ASID"; is401 "anonymous other notification"
  CODE="$(curl -s -o "$TMP/b" -w '%{http_code}' -X DELETE -H "mcp-session-id: $ASID" "http://127.0.0.1:$(cat "$TMP/$n.port")/mcp")"; assert_eq "$CODE" 401 "anonymous DELETE"
  CODE="$(curl -s -o "$TMP/b" -w '%{http_code}' "http://127.0.0.1:$(cat "$TMP/$n.port")/mcp")"; assert_eq "$CODE" 401 "anonymous GET"
  # a credential that fails is never anonymous
  req "$n" "$INIT" -H "Authorization: Bearer wrong-token-0123456789abcdef"; is401 "bad token initialize"
  req "$n" "$LIST" -H "X-Auth-Token: wrong-token-0123456789abcdef"; is401 "bad x-auth-token tools/list"
  req "$n" "$INIT" -H 'Authorization;'; is401 "empty Authorization header"
  # authenticated flow unchanged: a tool call works
  req "$n" "$CALL" "${GOOD[@]}" -H "mcp-session-id: $BSID"; assert_eq "$CODE" "200" "authenticated tools/call"
  assert_eq "$(jq -r '.result.isError // false' <<< "$BODY")" "false" "authenticated tools/call result"
  echo "ok - $mode: anonymous initialize/ping/tools/list/prompts/list work, everything else is the old 401, sessions are not interchangeable"

  # ---- per-IP limit (default 20 a minute; 5 here), on a fresh server
  start "rl-$mode" "$mode" E3D_MCP_ANON_DISCOVERY=on E3D_MCP_ANON_IP_PER_MIN=5
  for i in 1 2 3 4 5; do req "rl-$mode" "$INIT"; assert_eq "$CODE" 200 "anon request $i within the limit"; done
  req "rl-$mode" "$INIT"; assert_eq "$CODE" 429 "the sixth anonymous request in a minute"
  grep -qi '^retry-after:' "$TMP/h" || fail "429 without retry-after"
  req "rl-$mode" "$INIT" "${GOOD[@]}"; assert_eq "$CODE" 200 "an authenticated request is not blocked by the anonymous limit"
  echo "ok - $mode: anonymous requests are limited per address, authenticated ones are not affected"
done

# hook mode: a wrong credential still counts against the failed-attempt limiter (no bypass through the flag)
start fail hook E3D_MCP_ANON_DISCOVERY=on E3D_MCP_AUTH_IP_PER_MIN=3
for i in 1 2 3; do req fail "$INIT" -H "Authorization: Bearer wrong-token-$i-0123456789abcdef"; assert_eq "$CODE" 401 "bad token $i"; done
req fail "$INIT" -H "Authorization: Bearer wrong-token-4-0123456789abcdef"; assert_eq "$CODE" 429 "bad token after the limit: limiter still counts"
req fail "$INIT"; assert_eq "$CODE" 200 "anonymous discovery is a separate budget from failed attempts"
echo "ok - hook: failed credentials still hit the failed-attempt limiter"
echo "PASS mcp-anon"
