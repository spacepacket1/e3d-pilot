#!/usr/bin/env bash
set -euo pipefail

# Protocol + validation tests for bin/e3d-mcp. Makes no model calls (no credit spend).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER="$ROOT/bin/e3d-mcp"

fail() { echo "FAIL: $*" >&2; exit 1; }

responses="$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"e3d_list_providers","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"e3d_debate","arguments":{"question":"x","rounds":99}}}' \
  '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"e3d_debate","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"e3d_debate","arguments":{"question":"x","providers":["claude","../evil"]}}}' \
  '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"e3d_ideas_list","arguments":{"repo":"/nonexistent"}}}' \
  '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"nope","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":9,"method":"nope"}' \
  'not json' \
  | "$SERVER" 2>/dev/null)"

field() { jq -r --argjson id "$1" "select(.id==\$id) | $2" <<< "$responses"; }

[[ "$(field 1 .result.serverInfo.name)" == "e3d-pilot" ]] || fail "initialize serverInfo"
[[ "$(field 1 .result.protocolVersion)" == "2025-06-18" ]] || fail "protocol version negotiation"
[[ "$(field 2 '.result.tools|map(.name)|join(",")')" == "e3d_debate,e3d_list_providers,e3d_provenance_trace,e3d_ideas_list" ]] || fail "tools/list"
[[ "$(field 3 .result.content[0].text)" == *claude* ]] || fail "list_providers should mention claude"
[[ "$(field 4 .result.isError)" == "true" ]] || fail "rounds over cap must be rejected"
[[ "$(field 5 .result.content[0].text)" == *"question"* ]] || fail "missing question must be rejected"
[[ "$(field 6 .result.isError)" == "true" ]] || fail "bad provider name must be rejected"
[[ "$(field 7 .result.content[0].text)" == *".e3d-pilot"* ]] || fail "non-e3d-pilot repo must be rejected"
[[ "$(field 8 .error.code)" == "-32602" ]] || fail "unknown tool"
[[ "$(field 9 .error.code)" == "-32601" ]] || fail "unknown method"
[[ "$(jq -r 'select(.id==null) | .error.code' <<< "$responses")" == "-32700" ]] || fail "parse error"
[[ "$(jq -s 'map(select(.method=="notifications/initialized"))|length' <<< "$responses")" == "0" ]] || fail "notifications must not be answered"

"$SERVER" --print-config 2>/dev/null | jq -e '.servers["e3d-pilot"].args | index("e3d-mcp")' >/dev/null || fail "--print-config"
npm_files="$(cd "$ROOT" && npm pack --dry-run --json 2>/dev/null | jq -r '.[0].files[].path')"
for f in bin/e3d-mcp bin/e3d-debate lib/providers/jev.sh lib/negotiate/convergence; do
  grep -qx "$f" <<< "$npm_files" || fail "npm package is missing $f"
done

echo "mcp.sh: ok"
