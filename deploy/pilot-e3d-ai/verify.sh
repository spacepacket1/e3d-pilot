#!/usr/bin/env bash
# Black-box checks from any machine:  verify.sh https://pilot.e3d.ai <token> [--debate]
# --debate runs one real quick debate (about 3 model calls, a few cents).
set -uo pipefail
BASE="${1:?base url, e.g. https://pilot.e3d.ai}"; TOKEN="${2:?token}"; DEBATE="${3:-}"
pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "ok    $1"; pass=$((pass+1)); else echo "FAIL  $1 (expected $3, got $2)"; fail=$((fail+1)); fi; }
code() { curl -s -o /dev/null -w '%{http_code}' -m 20 "$@"; }
SID=""; HDR="$(mktemp)"; trap 'rm -f "$HDR"' EXIT
# The server issues a session id on initialize; every later request must carry it (MCP streamable HTTP).
rpc() { curl -sS -m 200 -D "$HDR" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -H 'MCP-Protocol-Version: 2025-06-18' ${SID:+-H "Mcp-Session-Id: $SID"} "$BASE/mcp" -d "$1"; }

ck "healthz is public and answers" "$(code "$BASE/healthz")" 200
ck "/mcp without a token is refused" "$(code -X POST "$BASE/mcp" -H 'Content-Type: application/json' -d '{}')" 401
ck "/mcp with a wrong token is refused" "$(code -X POST "$BASE/mcp" -H 'Authorization: Bearer wrong-token-0123456789' -H 'Content-Type: application/json' -d '{}')" 401
ck "an unrelated path is a 404" "$(code "$BASE/anything-else")" 404
ck "a hostile Origin is refused" "$(code -X POST "$BASE/mcp" -H "Authorization: Bearer $TOKEN" -H 'Origin: https://evil.example' -H 'Content-Type: application/json' -d '{}')" 403
init="$(rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify","version":"0"}}}')"
ck "initialize works" "$(jq -r '.result.serverInfo.name // "none"' <<< "$init")" e3d-pilot
SID="$(grep -i '^mcp-session-id:' "$HDR" | awk '{print $2}' | tr -d '\r')"
ck "a session id was issued" "$([[ -n "$SID" ]] && echo yes || echo no)" yes
rpc '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
tools="$(rpc '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | jq -r '.result.tools | map(.name) | sort | join(",")')"
ck "only the safe tools are exposed" "$tools" "e3d_debate,e3d_list_providers,e3d_usage"
if [[ "$DEBATE" == "--debate" ]]; then
  out="$(rpc '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"e3d_debate","arguments":{"question":"Tabs or spaces for a new small project? One sentence.","mode":"quick"}}}')"
  ck "a quick debate returns a verdict" "$(jq -r '.result.structuredContent.consensus // "none"' <<< "$out" | grep -E -c '^(full|majority|split)$')" 1
  echo "      spent: $(jq -c '.result.structuredContent.usage' <<< "$out")"
fi
if [[ -n "$SID" ]]; then ck "the session can be ended" "$(code -X DELETE "$BASE/mcp" -H "Authorization: Bearer $TOKEN" -H "Mcp-Session-Id: $SID")" 204; fi
echo "$pass passed, $fail failed"; [[ $fail -eq 0 ]]
