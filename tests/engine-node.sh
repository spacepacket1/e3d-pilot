#!/usr/bin/env bash
set -euo pipefail

# Which node the engine uses, and what happens when web search cannot be set up (an old `node` first on PATH, as in the
# 2026-10-22 incident: Node 12 in a service sandbox died on `??` in lib/debate/websearch.mjs and search went off silently).
# No model calls, no network. (a) e3d-mcp children run the same node as e3d-mcp; (b) the engine's warning is precise and reaches
# the stored web_search block, the log and the tool result; (c) bin/e3d-debate names an old node and refuses per-token limits.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }
has() { [[ "$1" == *"$2"* ]] || fail "${3:-has}: expected [$2] in [$1]"; }
hasnt() { [[ "$1" != *"$2"* ]] || fail "${3:-hasnt}: did not expect [$2] in [$1]"; }

REAL_NODE="$(node -p process.execPath)"; REAL_DIR="$(dirname "$REAL_NODE")"
SHIM="$T/shim"; mkdir -p "$SHIM"
cat > "$SHIM/node" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "v12.22.9"; exit 0; }
echo "SyntaxError: Unexpected token '?'" >&2
exit 1
EOF
chmod +x "$SHIM/node"

# ---- (a) children use the running node ----
out="$(PATH="$SHIM:$PATH" "$REAL_NODE" --input-type=module -e "
import { run, childEnv } from '$ROOT/lib/mcp/util.js';
const r = await run('bash', ['-c', 'command -v node; node --version']);
const e1 = childEnv({ PATH: '/a:/b' }, '/x/node'), e2 = childEnv(e1, '/x/node'), e3 = childEnv({ PATH: '/a:/x:/b' }, '/x/node');
process.stdout.write(JSON.stringify({ out: r.out, e1: e1.PATH, e2: e2.PATH, e3: e3.PATH }));")"
has "$(jq -r .out <<< "$out")" "$REAL_NODE" "child resolves node to the running binary"
hasnt "$(jq -r .out <<< "$out")" "v12.22.9" "the old shim is not used"
[[ "$(jq -r .e1 <<< "$out")" == "/x:/a:/b" ]] || fail "childEnv prepends"
[[ "$(jq -r .e2 <<< "$out")" == "/x:/a:/b" ]] || fail "childEnv is idempotent"
[[ "$(jq -r .e3 <<< "$out")" == "/x:/a:/b" ]] || fail "childEnv does not duplicate"
ok "children run the node that runs e3d-mcp (shim in PATH ignored; no duplicate PATH entries)"

# ---- (c) bin/e3d-debate with the old node first on PATH ----
Q="$T/q.md"; echo "JSON or SQLite?" > "$Q"
err="$(perl -e 'alarm 30; exec @ARGV' env PATH="$SHIM:$PATH" ANTHROPIC_API_KEY=k OPENAI_API_KEY=k ANTHROPIC_API_BASE_URL=http://127.0.0.1:9 OPENAI_API_BASE_URL=http://127.0.0.1:9/v1 E3D_DEBATE_PROVIDER_RETRIES=0 \
  "$ROOT/bin/e3d-debate" --question-file "$Q" --providers anthropic-api,openai-api --synthesizer anthropic-api --rounds 1 --web-search on --out-dir "$T/o1" 2>&1 >/dev/null || true)"
has "$err" "warning: web search is off for this debate: node v12.22.9 at $SHIM/node is older than 18" "old node named precisely"
hasnt "$err" "is missing)" "the opaque message is gone"
# a node that is new enough but whose websearch.mjs config fails: its first stderr line is the reason
cat > "$SHIM/node" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "v20.1.0"; exit 0; }
echo "SyntaxError: Unexpected token '?'" >&2
echo "second line" >&2
exit 1
EOF
err="$(perl -e 'alarm 30; exec @ARGV' env PATH="$SHIM:$PATH" ANTHROPIC_API_KEY=k OPENAI_API_KEY=k ANTHROPIC_API_BASE_URL=http://127.0.0.1:9 OPENAI_API_BASE_URL=http://127.0.0.1:9/v1 E3D_DEBATE_PROVIDER_RETRIES=0 \
  "$ROOT/bin/e3d-debate" --question-file "$Q" --providers anthropic-api,openai-api --synthesizer anthropic-api --rounds 1 --web-search on --out-dir "$T/o2" 2>&1 >/dev/null || true)"
has "$err" "warning: web search is off for this debate: SyntaxError: Unexpected token '?' (node v20.1.0 at $SHIM/node)" "config failure reason"
hasnt "$err" "second line" "only the first stderr line"
# per-token limits need node 18+: refuse, clearly
cat > "$SHIM/node" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "v12.22.9"; exit 0; }
exit 1
EOF
err="$(env PATH="$SHIM:$PATH" E3D_DEBATE_MAX_TOKENS='{"anthropic-api":100,"openai-api":100}' ANTHROPIC_API_KEY=k OPENAI_API_KEY=k \
  "$ROOT/bin/e3d-debate" --question-file "$Q" --providers anthropic-api,openai-api --synthesizer anthropic-api --rounds 1 --out-dir "$T/o3" 2>&1 >/dev/null)" && fail "per-token with node 12 must refuse" || true
has "$err" "error: token limits need Node 18 or newer: node v12.22.9" "per-token refusal names the node"
# the good node: no warning
err="$(perl -e 'alarm 30; exec @ARGV' env ANTHROPIC_API_KEY=k OPENAI_API_KEY=k ANTHROPIC_API_BASE_URL=http://127.0.0.1:9 OPENAI_API_BASE_URL=http://127.0.0.1:9/v1 E3D_DEBATE_PROVIDER_RETRIES=0 \
  "$ROOT/bin/e3d-debate" --question-file "$Q" --providers anthropic-api,openai-api --synthesizer anthropic-api --rounds 1 --web-search on --out-dir "$T/o4" 2>&1 >/dev/null || true)"
hasnt "$err" "web search is off for this debate" "a good node leaves search on"
ok "e3d-debate: precise search-off reasons; old node refused for per-token; good node unaffected"

# ---- (b) e3d-mcp: the warning reaches the log, the stored block and the tool result ----
STUB="$T/stub-debate"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
out=""; while [[ $# -gt 0 ]]; do case "$1" in --out-dir) out="$2"; shift 2 ;; *) shift ;; esac; done
echo "warning: web search is off for this debate: SyntaxError: Unexpected token '?' (node v12.22.9 at /usr/bin/node)" >&2
echo "warning: second SECRETQ thing" >&2
echo "$PATH" > "$STUB_PATH_FILE"
mkdir -p "$out"
printf '# Debate\n\n## Round 1 -- anthropic-api\n\nJSON.\n\n## Round 1 -- openai-api\n\nSQLite.\n' > "$out/transcript.md"
printf 'FINAL ANSWER: use JSON.\nCONSENSUS: split\nDISSENT: one prefers SQLite.\n'
EOF
chmod +x "$STUB"
call='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"e3d_debate","arguments":{"question":"JSON or SQLite?","providers":["anthropic-api","openai-api"],"web_search":true}}}'
resp="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$call" \
  | env PATH="$SHIM:$PATH" E3D_MCP_STATE_DIR="$T/state" E3D_MCP_DEBATE_BIN="$STUB" STUB_PATH_FILE="$T/path" E3D_MCP_PROVIDERS=anthropic-api,openai-api \
    ANTHROPIC_API_KEY=k OPENAI_API_KEY=k "$REAL_NODE" "$ROOT/bin/e3d-mcp" 2>"$T/mcp.log")"
r="$(jq -c 'select(.id==2)' <<< "$resp")"
[[ "$(cut -d: -f1 "$T/path")" == "$REAL_DIR" ]] || fail "the debate binary's PATH starts with the running node's directory: $(cat "$T/path")"
has "$(cat "$T/mcp.log")" "[e3d-mcp] engine warning: web search is off for this debate: SyntaxError: Unexpected token '?' (node v12.22.9 at /usr/bin/node)" "warning logged"
[[ "$(jq -r '.result.structuredContent.web_search.flags.unavailable[0].reason' <<< "$r")" == "search_setup_failed" ]] || fail "stored block carries the reason: $r"
has "$(jq -r '.result.structuredContent.web_search.flags.unavailable[0].detail' <<< "$r")" "SyntaxError: Unexpected token '?'" "detail"
[[ "$(jq -r '.result.structuredContent.web_search.flags.unavailable[0].provider' <<< "$r")" == "anthropic-api" ]] || fail "provider is a real API provider (billing drops others)"
has "$(jq -r '.result.structuredContent.warnings | join(" | ")' <<< "$r")" "Web search was requested but is off for this debate: web search is off" "warnings[]"
has "$(jq -r '.result.content[0].text' <<< "$r")" "web search was requested but is off for this debate" "rendered text"
ok "e3d-mcp: children's PATH, logged warning, flags.unavailable and warnings[] on a failed search setup"
echo "engine-node: all passed"
