#!/usr/bin/env bash
set -euo pipefail

# The stored debate result's positions[] hold the ANSWER only (no web-search source list, no notices) and carry the real model each
# seat's adapter reported; the transcript keeps the prefix (later rounds and the synthesizer read it as data).
# Part 1: stripAnswerPrefix units. Part 2: real e3d-debate + e3d-mcp (hosted, with the reference finalize stub) against the fake vendor.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
PIDS=()
trap 'for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done; rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

# ================= 1. stripAnswerPrefix =================
node --input-type=module -e "
import { stripAnswerPrefix, citeList } from '$ROOT/lib/debate/websearch.mjs';
const eq = (a, b, m) => { if (a !== b) { console.error('FAIL ' + m + ': ' + JSON.stringify(a) + ' != ' + JSON.stringify(b)); process.exit(1); } };
const cite = citeList({ citations: [{ domain: 'a.example', url: 'https://a.example/x' }, { domain: 'b.example', url: 'https://b.example/y' }] });
eq(stripAnswerPrefix(cite + '\n\nThe answer.\nLine two.'), 'The answer.\nLine two.', 'citation block');
eq(stripAnswerPrefix('[openai-api could use web search for this answer; it cited no sources.]\n\nThe answer.'), 'The answer.', 'no-sources notice');
eq(stripAnswerPrefix('[Web search was unavailable for this answer (timeout), so xai-api answered without web access.]\n\nThe answer.'), 'The answer.', 'unavailable notice');
eq(stripAnswerPrefix('Just an answer.\n\nSecond paragraph.'), 'Just an answer.\n\nSecond paragraph.', 'no prefix unchanged');
eq(stripAnswerPrefix(''), '', 'empty');
eq(stripAnswerPrefix(cite), '', 'prefix only (citation)');
eq(stripAnswerPrefix('[openai-api could use web search for this answer; it cited no sources.]'), '', 'prefix only (notice)');
for (const t of [cite + '\n\nA.', '[x-api could use web search for this answer; it cited no sources.]\n\nA.', 'plain', cite]) eq(stripAnswerPrefix(stripAnswerPrefix(t)), stripAnswerPrefix(t), 'idempotent');
eq(stripAnswerPrefix(cite + '\n\nIntro.\n- a.example: https://a.example/x\n- point two\n\nEnd.'), 'Intro.\n- a.example: https://a.example/x\n- point two\n\nEnd.', 'only the leading block is stripped');
const mid = 'Answer first.\n\n' + cite + '\n\nMore.';
eq(stripAnswerPrefix(mid), mid, 'never from the middle');
const mid2 = 'Answer.\n[openai-api could use web search for this answer; it cited no sources.]\n\nMore.';
eq(stripAnswerPrefix(mid2), mid2, 'notice in the middle stays');
" || fail "stripAnswerPrefix units"
ok "stripAnswerPrefix: three shapes, unchanged, empty, idempotent, leading block only"

# ================= 2. end to end =================
: > "$T/api.log"
node "$ROOT/tests/fixtures/web-search-fake.mjs" "$T/api.log" > "$T/port" &
PIDS+=("$!")
for _ in $(seq 1 50); do [[ -s "$T/port" ]] && break; sleep 0.1; done
PORT="$(cat "$T/port")"; [[ -n "$PORT" ]] || fail "fake vendor did not start"
BASE="http://127.0.0.1:$PORT"
mkdir -p "$T/tmp"
unset ANTHROPIC_API_KEY_FILE OPENAI_API_KEY_FILE XAI_API_KEY_FILE GEMINI_API_KEY_FILE TYPESAFE_API_KEY E3D_DEBATE_WEB_SEARCH E3D_DEBATE_WEB_SEARCH_PROVIDERS \
  E3D_DEBATE_SEARCH_ALLOW_DOMAINS E3D_DEBATE_SEARCH_DENY_DOMAINS E3D_MCP_TIMEOUT_SEC E3D_DEBATE_TIMEOUT_SEC E3D_MCP_PROVIDERS E3D_MCP_DAILY_SEARCHES \
  ANTHROPIC_API_MAX_TOKENS OPENAI_API_MAX_TOKENS XAI_API_MAX_TOKENS GEMINI_API_MAX_TOKENS
R="$T/repo"; mkdir -p "$R/bin"; cp "$ROOT/bin/e3d-debate" "$R/bin/"; cp -R "$ROOT/lib" "$R/lib"; cp "$ROOT/package.json" "$R/"
cat > "$T/debate-wrapper" <<EOF
#!/usr/bin/env bash
exec "$R/bin/e3d-debate" "\$@" --synthesizer anthropic-api
EOF
chmod +x "$T/debate-wrapper"

SVC="svc-$(openssl rand -hex 16)"; TOK="caller-$(openssl rand -hex 16)"
jq -n --arg tok "$TOK" '{accounts: [{principal: "acct_ok", balance: 1000000, keys: [{id: "key-ok", token: $tok, tools: ["e3d_debate"], limits: {rate_per_min: 60, max_inflight: 2}}]}]}' > "$T/seed.json"
env STUB_SERVICE_TOKEN="$SVC" STUB_SEED="$T/seed.json" STUB_URL_FILE="$T/stub.url" STUB_FEATURES=finalize,fetch,authorize-run node "$ROOT/examples/external-auth-stub.js" > "$T/stub.out" 2> "$T/stub.log" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$T/stub.url" ]] && break; sleep 0.05; done
[[ -s "$T/stub.url" ]] || fail "stub did not start: $(cat "$T/stub.log")"
STUB_URL="$(cat "$T/stub.url")"
: > "$T/mcp.port"
env TMPDIR="$T/tmp" E3D_MCP_AUTH_URL="$STUB_URL" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" E3D_MCP_STATE_DIR="$T/state" E3D_MCP_PORT_FILE="$T/mcp.port" \
  E3D_MCP_DEBATE_BIN="$T/debate-wrapper" E3D_MCP_PRINCIPAL="" E3D_DEBATE_PROVIDER_RETRY_DELAY=0 \
  ANTHROPIC_API_KEY=k-a ANTHROPIC_API_BASE_URL="$BASE" ANTHROPIC_API_MODEL=ws-model-anth \
  OPENAI_API_KEY=k-o OPENAI_API_BASE_URL="$BASE/v1" OPENAI_API_MODEL=ws-model-oai \
  node "$ROOT/bin/e3d-mcp" --http --port 0 2> "$T/mcp.err" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$T/mcp.port" ]] && break; sleep 0.1; done
[[ -s "$T/mcp.port" ]] || { cat "$T/mcp.err" >&2; fail "e3d-mcp did not start"; }
MP="$(cat "$T/mcp.port")"
call() { curl -s -m 120 -D "$T/h" -H 'content-type: application/json' -H 'accept: application/json' -H "Authorization: Bearer $TOK" ${SID:+-H "mcp-session-id: $SID"} "$@" "http://127.0.0.1:$MP/mcp"; }
SID=""; call -X POST -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' > /dev/null
SID="$(grep -i '^mcp-session-id:' "$T/h" | head -1 | sed -E 's/^[^:]+: *//' | tr -d '\r')"
r="$(call -X POST -d '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"e3d_debate","arguments":{"question":"Which version is current?","providers":["anthropic-api","openai-api"]}}}')"
[[ "$(jq -r '.result.isError // false' <<< "$r")" == false ]] || { cat "$T/mcp.err" >&2; fail "debate failed: $r"; }
DID="$(jq -r '.result.structuredContent.billing.debate_id' <<< "$r")"
[[ "$DID" =~ ^dbt_[0-9a-f]{24}$ ]] || fail "debate id: $r"
sc="$(jq -c .result.structuredContent <<< "$r")"
txt="$(jq -r '.result.content[0].text' <<< "$r")"
fr="$(curl -sS -X POST -H "authorization: Bearer $SVC" -H 'x-e3d-auth-version: 1' -H 'content-type: application/json' -d "$(jq -nc --arg d "$DID" '{debate_id:$d,principal:"acct_ok",include_transcript:true}')" "$STUB_URL/fetch")"
pos="$(jq -c '.debate.result.positions' <<< "$fr")"
[[ "$(jq 'length' <<< "$pos")" == 2 ]] || fail "two stored positions: $fr"
PFX="Sources this answer's web search returned"

# group A: the stored position is the answer, with no source list or notice
jq -e 'all(.[]; (.position | startswith("Sources this answer") | not) and (.position | contains("untrusted internet data") | not) and (.position | startswith("[") | not) and (.position | length) > 0)' <<< "$pos" >/dev/null || fail "stored positions carry a prefix: $pos"
jq -e 'all(.[]; .position | startswith("Plain answer") or startswith("Answer") or (test("^[A-Za-z]")))' <<< "$pos" >/dev/null || fail "stored position is not the answer: $pos"
ok "stored positions hold no source list or notice"

# group B: the transcript still has the prefix, and the citations are still in web_search
tr="$(jq -r '.debate.transcript' <<< "$fr")"
[[ "$tr" == *"$PFX"* ]] || fail "the transcript lost the source list"
[[ "$(jq -r '.debate.result.web_search.citations | length' <<< "$fr")" -gt 0 ]] || fail "web_search citations missing"
ok "the transcript keeps the source lists; web_search keeps the citations"

# group C: the real model per seat (from the adapters' e3d_provider_usage line), not 'unspecified'
assert_model() { [[ "$(jq -r --arg p "$1" '.[] | select(.provider == $p) | .model' <<< "$pos")" == "$2" ]] || fail "model of $1: expected $2 in $pos"; }
assert_model anthropic-api ws-model-anth
assert_model openai-api ws-model-oai
ok "positions carry the model the adapter reported"

# group D: the MCP tool text shows the answer, not the source block, under each position
[[ "$txt" == *"Each model's final position"* ]] || fail "positions section missing from the tool text"
posblock="${txt#*"Each model's final position"}"; posblock="${posblock%%<details>*}"
[[ "$posblock" != *"$PFX"* ]] || fail "the tool text's positions still print the source list: $posblock"
jq -e 'all(.positions[]; .text | startswith("Sources this answer") | not)' <<< "$sc" >/dev/null || fail "structured positions carry the prefix"
ok "tool output prints answers first"

echo "mcp-positions-clean.sh: ok"
