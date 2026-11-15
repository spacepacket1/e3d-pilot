#!/usr/bin/env bash
set -euo pipefail

# e3d-mcp: each web-search citation carries a deterministic tier, web_search.source_tiers counts them, and the claim ledger (claims[])
# reaches the structured result with every model-written field sanitised. A stub debate stands in for the engine; no model calls, no network.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
STUB="$TMP/stub-debate"
cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
out=""; while [[ $# -gt 0 ]]; do case "$1" in --out-dir) out="$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p "$out"
printf '# Debate\n\n## Round 1 -- anthropic-api\n\nJSON.\n\n## Synthesis\n\nx\n' > "$out/transcript.md"
printf '%s' '{"enabled":true,"models_with_search":1,"models_total":1,"searches_used":{"anthropic-api":1},"citations":[{"title":"FAA","domain":"www.faa.gov","url":"https://www.faa.gov/newsroom/x","excerpt":"e","provider":"anthropic-api"},{"title":"AP","domain":"apnews.com","url":"https://apnews.com/article/y","excerpt":"e","provider":"anthropic-api"},{"title":"post","domain":"x.com","url":"https://x.com/a/status/1","excerpt":"e","provider":"anthropic-api"},{"title":"blog","domain":"example.org","url":"https://example.org/p","excerpt":"e","provider":"anthropic-api"}],"flags":{}}' > "$out/web-search.json"
printf 'FINAL ANSWER: use JSON.\nCONSENSUS: full\nDISSENT: none\n\n## What would change this\n- A benchmark\n\n## Key claims\n- The outage began on Nov 13 | tier: documented | source: reputable | by: anthropic-api\n- Officials say no cyberattack ![x](http://evil.example/p.png) | tier: inferred | source: primary | by: official statement\n'
EOS
chmod +x "$STUB"
call='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"e3d_debate","arguments":{"question":"JSON or SQLite?","providers":["anthropic-api","openai-api"],"web_search":true}}}'
resp="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$call" \
  | env E3D_MCP_STATE_DIR="$TMP/state" E3D_MCP_DEBATE_BIN="$STUB" E3D_MCP_PROVIDERS=anthropic-api,openai-api ANTHROPIC_API_KEY=k OPENAI_API_KEY=k "$ROOT/bin/e3d-mcp" 2>"$TMP/mcp.log")"
r="$(jq -c 'select(.id==2)' <<< "$resp")"
[[ "$(jq -r '.result.structuredContent.web_search.enabled' <<< "$r")" == true ]] || { cat "$TMP/mcp.log" >&2; fail "web_search not enabled in the result: $(jq -c '.result.structuredContent.web_search' <<< "$r")"; }
[[ "$(jq -c '.result.structuredContent.web_search.source_tiers' <<< "$r")" == '{"primary":1,"reputable":1,"low":1,"unclassified":1}' ]] || fail "source_tiers: $(jq -c '.result.structuredContent.web_search.source_tiers' <<< "$r")"
[[ "$(jq -c '[.result.structuredContent.web_search.citations[].tier]' <<< "$r")" == '["primary","reputable","low","unclassified"]' ]] || fail "citation tiers"
echo "ok - citations carry a tier and web_search.source_tiers counts them"
[[ "$(jq -r '.result.structuredContent.claims | length' <<< "$r")" == 2 ]] || fail "claims length: $(jq -c '.result.structuredContent.claims' <<< "$r")"
[[ "$(jq -r '.result.structuredContent.claims[0] | [.tier, .source, .by] | @csv' <<< "$r")" == '"documented","reputable","anthropic-api"' ]] || fail "claim 0"
[[ "$(jq -r '.result.structuredContent.claims[1].claim' <<< "$r")" != *"evil.example/p.png"* ]] || fail "claim text was not sanitised: $(jq -r '.result.structuredContent.claims[1].claim' <<< "$r")"
[[ "$(jq -c '.result.structuredContent.would_change' <<< "$r")" == '["A benchmark"]' ]] || fail "would_change"
echo "ok - claims[] and would_change reach the result, and claim text is sanitised"
echo "mcp-source-tiers: all passed"
