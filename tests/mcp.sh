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
# The four original tools must stay byte-for-byte identical in schema; new tools may only be added after them.
[[ "$(field 2 '.result.tools[0:4]|map(.name)|join(",")')" == "e3d_debate,e3d_list_providers,e3d_provenance_trace,e3d_ideas_list" ]] || fail "tools/list: original four tools must come first, in order"
[[ "$(field 2 '.result.tools[0:4]|sort_by(.name)' | jq -S .)" == "$(jq -S 'sort_by(.name)' "$ROOT/tests/fixtures/mcp-original-tools.json")" ]] || fail "the original four tools' definitions changed"
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

# ---- e3d_debate: modes + structured verdict, using a stub debate binary (no model calls) ----
STUB="$(mktemp -d)/stub-debate"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
out=""; rounds=""; words=""
while [[ $# -gt 0 ]]; do
  case "$1" in --out-dir) out="$2"; shift 2 ;; --rounds) rounds="$2"; shift 2 ;; --max-words) words="$2"; shift 2 ;; *) shift ;; esac
done
echo "rounds=$rounds words=$words" >> "$STUB_ARGS_FILE"
mkdir -p "$out"
if [[ "${STUB_CASE:-split}" == "full" ]]; then
  printf '# Debate\n\n## Round 1 -- claude\n\nUse X.\n\n## Round 1 -- codex\n\nUse X too.\n' > "$out/transcript.md"
  printf 'FINAL ANSWER: Use X.\nCONSENSUS: full\nDISSENT: none\n'
elif [[ "${STUB_CASE:-split}" == "garbled" ]]; then
  printf '# Debate\n' > "$out/transcript.md"
  printf 'FINAL ANSWER: Something unstructured with no consensus line.\n'
else
  printf '# Debate\n\n## Round 1 -- claude\n\nJSON file.\n\n## Round 1 -- codex\n\nSQLite.\n' > "$out/transcript.md"
  printf 'FINAL ANSWER: Use a JSON file.\nCONSENSUS: split\nDISSENT: Codex prefers SQLite for transactions.\n'
fi
STUBEOF
chmod +x "$STUB"
ARGS_FILE="$(mktemp)"

call_debate() {  # $1 = STUB_CASE, $2 = arguments JSON
  printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"e3d_debate\",\"arguments\":$2}}" \
    | E3D_MCP_DEBATE_BIN="$STUB" STUB_ARGS_FILE="$ARGS_FILE" STUB_CASE="$1" "$SERVER" 2>/dev/null
}

r="$(call_debate split '{"question":"JSON or SQLite?"}')"
[[ "$(jq -r .result.structuredContent.consensus <<< "$r")" == "split" ]] || fail "structured consensus"
[[ "$(jq -r .result.structuredContent.dissent.present <<< "$r")" == "true" ]] || fail "dissent.present should be true"
[[ "$(jq -r .result.structuredContent.dissent.summary <<< "$r")" == *SQLite* ]] || fail "dissent.summary"
[[ "$(jq -r '.result.structuredContent.positions|map(.provider)|join(",")' <<< "$r")" == "claude,codex" ]] || fail "positions"
[[ "$(jq -r .result.structuredContent.mode <<< "$r")" == "quick" ]] || fail "default mode must be quick"
[[ "$(jq -r '.result.structuredContent|has("transcript")' <<< "$r")" == "false" ]] || fail "transcript must be opt-in"
[[ "$(jq -r .result.content[0].text <<< "$r")" == *"SPLIT"*"report this to the user"* ]] || fail "text must lead with SPLIT and carry the dissent instruction"
tail -1 "$ARGS_FILE" | grep -qx "rounds=1 words=80" || fail "quick mode should run 1 round, 80 words (got: $(tail -1 "$ARGS_FILE"))"

r="$(call_debate split '{"question":"q","mode":"thorough","include_transcript":true}')"
tail -1 "$ARGS_FILE" | grep -qx "rounds=2 words=200" || fail "thorough mode should run 2 rounds, 200 words"
[[ "$(jq -r '.result.structuredContent.transcript|length > 0' <<< "$r")" == "true" ]] || fail "include_transcript"

call_debate split '{"question":"q","mode":"quick","rounds":3,"max_words":120}' >/dev/null
tail -1 "$ARGS_FILE" | grep -qx "rounds=3 words=120" || fail "explicit rounds/max_words must override the mode"

r="$(call_debate full '{"question":"q"}')"
[[ "$(jq -r .result.structuredContent.dissent.present <<< "$r")" == "false" ]] || fail "full consensus has no dissent"
[[ "$(jq -r .result.content[0].text <<< "$r")" == *"FULL CONSENSUS"*"**Dissent:** none"* ]] || fail "full-consensus rendering"

r="$(call_debate garbled '{"question":"q"}')"
[[ "$(jq -r .result.structuredContent.consensus <<< "$r")" == "unknown" ]] || fail "unparseable verdict -> consensus unknown"
[[ "$(jq -r .result.structuredContent.dissent.present <<< "$r")" == "null" ]] || fail "unparseable verdict -> dissent.present null, not false"

[[ "$(jq -r .result.isError <<< "$(call_debate split '{"question":"q","mode":"turbo"}')")" == "true" ]] || fail "invalid mode rejected"
[[ "$(printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | "$SERVER" 2>/dev/null | jq -r '.result.tools[0].outputSchema.required|index("dissent")!=null')" == "true" ]] || fail "e3d_debate must declare outputSchema with dissent"

# ---- housekeeping: print-config matches README, provider wording, doctor ending, redaction ----
cfg_out="$("$SERVER" --print-config 2>/dev/null)"
while IFS= read -r line; do
  grep -qF -- "$line" "$ROOT/README.md" || fail "--print-config line is not in the README snippet: $line"
done <<< "$cfg_out"
jq -e '.servers["e3d-pilot"].args | index("--no-update-notifier")' <<< "$cfg_out" >/dev/null || fail "--print-config should silence the npm update banner"

prov="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"e3d_list_providers","arguments":{}}}' | "$SERVER" 2>/dev/null | jq -r '.result.content[0].text')"
grep -q "UNAVAILABLE" <<< "$prov" && fail "provider listing should say 'unavailable' in lowercase, like --doctor"
grep -qiE "available[^()]*\(available" <<< "$prov" && fail "provider listing repeats the word 'available'"

doc="$("$SERVER" --doctor 2>/dev/null || true)"
grep -q "All good" <<< "$doc" && fail "--doctor must not claim 'All good' without checking an editor"
grep -qE "Requirements met\.|Fix the FAIL items" <<< "$doc" || fail "--doctor should end with a conditional hint"
grep -q "tool that writes code phase by phase" <<< "$doc" || grep -q "e3d-code found" <<< "$doc" || fail "--doctor must explain or report e3d-code"

red="$(node -e "import('$ROOT/lib/mcp/redact.js').then(m=>console.log(m.redact('k=sk-abcdefghijklmnopqrstuvwx and ANTHROPIC_API_KEY=hunter2 and {\"password\":\"p4ss\"} plain')))")"
[[ "$red" == *"plain" ]] || fail "redact should keep ordinary text"
[[ "$red" != *abcdefghijklmnop* && "$red" != *hunter2* && "$red" != *p4ss* ]] || fail "redact leaked a secret: $red"

echo "mcp.sh: ok"
