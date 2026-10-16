#!/usr/bin/env bash
set -euo pipefail

# Direct API providers (anthropic-api, openai-api) against a fake local server that speaks both APIs.
# No network beyond 127.0.0.1, no real keys, no spend.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANTH="$ROOT/lib/providers/anthropic-api"
OAI="$ROOT/lib/providers/openai-api"
TMP="$(mktemp -d)"
SERVER_PID=""
trap '[[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-assert_eq}: expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "${3:-assert_contains}: expected to find [$2] in [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "${3:-assert_not_contains}: did not expect [$2] in [$1]"; }

AKEY="sk-ant-SECRETKEY-1234567890abcdef"
OKEY="sk-oai-SECRETKEY-1234567890abcdef"
printf 'What is 2+2?\n' > "$TMP/prompt.md"

# ---------------- registration ----------------
list="$("$ROOT/bin/e3d-pilot" providers list)"
assert_contains "$list" "anthropic-api"; assert_contains "$list" "openai-api"
grep -q "'anthropic-api', 'openai-api'" "$ROOT/lib/mcp/voices.js" || fail "voices.js CLI_ORDER must list the API providers"

# ---------------- fake server: both APIs ----------------
cat > "$TMP/fake-api.mjs" <<'JS'
import http from 'node:http';
import { appendFileSync } from 'node:fs';
const log = process.argv[2];
const answer = process.env.DEBATE_TEXT || 'Four.';
const srv = http.createServer((req, res) => {
  let body = '';
  req.on('data', (d) => { body += d; });
  req.on('end', () => {
    let parsed = {}; try { parsed = JSON.parse(body); } catch { /* probe */ }
    appendFileSync(log, `${JSON.stringify({ method: req.method, url: req.url, xApiKey: req.headers['x-api-key'] ?? null, version: req.headers['anthropic-version'] ?? null, auth: req.headers.authorization ?? null, body })}\n`);
    const model = parsed.model ?? '';
    const send = (code, obj) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
    if (req.url === '/v1/messages') {
      if (model === 'ratelimited') return send(429, { type: 'error', error: { type: 'rate_limit_error', message: 'Rate limit exceeded, retry later' } });
      if (model === 'badkey') return send(401, { type: 'error', error: { type: 'authentication_error', message: 'invalid x-api-key' } });
      if (model === 'empty') return send(200, { content: [], usage: { input_tokens: 1, output_tokens: 0 } });
      if (model === 'huge') return send(200, { content: [{ type: 'text', text: 'x' }], usage: { input_tokens: 500000, output_tokens: 400000 } });
      if (model === 'blocks') return send(200, { model: 'claude-blocks', content: [{ type: 'thinking', thinking: 'hmm' }, { type: 'text', text: 'Four' }, { type: 'text', text: ', obviously.' }], usage: { input_tokens: 7, output_tokens: 3 } });
      return send(200, { model: parsed.model, content: [{ type: 'text', text: answer }], usage: { input_tokens: 7, output_tokens: 2 } });
    }
    if (req.url === '/v1/chat/completions') {
      if (model === 'ratelimited') return send(429, { error: { message: 'Rate limit exceeded, retry later' } });
      if (model === 'empty') return send(200, { choices: [{ message: { content: '' } }], usage: { total_tokens: 1 } });
      if (model === 'huge') return send(200, { choices: [{ message: { content: 'x' } }], usage: { total_tokens: 900000 } });
      return send(200, { model, choices: [{ message: { content: answer } }], usage: { prompt_tokens: 7, completion_tokens: 2, total_tokens: 9 } });
    }
    res.writeHead(404); res.end('not found');
  });
});
srv.listen(0, '127.0.0.1', () => console.log(srv.address().port));
JS
: > "$TMP/api.log"
node "$TMP/fake-api.mjs" "$TMP/api.log" > "$TMP/port" &
SERVER_PID=$!
for _ in $(seq 1 50); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
PORT="$(cat "$TMP/port")"; [[ -n "$PORT" ]] || fail "fake API server did not start"
BASE="http://127.0.0.1:$PORT"
A() { env -u ANTHROPIC_API_KEY -u ANTHROPIC_API_KEY_FILE -u ANTHROPIC_API_MODEL -u ANTHROPIC_API_MAX_TOKENS ANTHROPIC_API_BASE_URL="$BASE" "$@"; }
O() { env -u OPENAI_API_KEY -u OPENAI_API_KEY_FILE -u OPENAI_API_MODEL -u OPENAI_API_MAX_TOKENS OPENAI_API_BASE_URL="$BASE/v1" "$@"; }
lastreq() { tail -1 "$TMP/api.log"; }

# ================= anthropic-api =================
out="$(A E3D_PILOT_CHECK=1 "$ANTH" 2>&1)" && fail "no key must be unavailable"; assert_contains "$out" "ANTHROPIC_API_KEY"
out="$(A E3D_PILOT_CHECK=1 ANTHROPIC_API_BASE_URL="http://127.0.0.1:1" ANTHROPIC_API_KEY="$AKEY" "$ANTH" 2>&1)" && fail "closed port must be unavailable"; assert_contains "$out" "not reachable"
out="$(A E3D_PILOT_CHECK=1 ANTHROPIC_API_KEY="$AKEY" "$ANTH" 2>&1)"; assert_contains "$out" "available (claude-sonnet-5-5)"
assert_not_contains "$out" "$AKEY"
[[ "$(jq -s 'map(select(.xApiKey != null)) | length' "$TMP/api.log")" == "0" ]] || fail "the availability probe must never send the key"

: > "$TMP/api.log"
stdout="$(A ANTHROPIC_API_KEY="$AKEY" "$ANTH" "$TMP/prompt.md" 2> "$TMP/a.err")"
assert_eq "$stdout" "Four."
req="$(lastreq)"
assert_eq "$(jq -r .url <<< "$req")" "/v1/messages"
assert_eq "$(jq -r .xApiKey <<< "$req")" "$AKEY" "key in the x-api-key header"
assert_eq "$(jq -r .version <<< "$req")" "2023-06-01" "anthropic-version header"
assert_eq "$(jq -r '.body | fromjson | .model' <<< "$req")" "claude-sonnet-5-5" "default model"
assert_eq "$(jq -r '.body | fromjson | .max_tokens' <<< "$req")" "4096" "default max_tokens"
assert_eq "$(jq -r '.body | fromjson | .messages[0].content' <<< "$req")" "$(cat "$TMP/prompt.md")" "prompt in the body"
assert_not_contains "$stdout$(cat "$TMP/a.err")" "$AKEY" "the key is never printed"
assert_contains "$(cat "$TMP/a.err")" 'e3d_provider_usage={"provider":"anthropic-api","model":"claude-sonnet-5-5","tokens":9'

A ANTHROPIC_API_KEY="$AKEY" ANTHROPIC_API_MODEL=custom-model ANTHROPIC_API_MAX_TOKENS=64 "$ANTH" "$TMP/prompt.md" >/dev/null 2>&1
req="$(lastreq)"
assert_eq "$(jq -r '.body | fromjson | .model' <<< "$req")" "custom-model"; assert_eq "$(jq -r '.body | fromjson | .max_tokens' <<< "$req")" "64"

# key files: bare key, `export NAME=key`, quoted, and with other lines present
printf '%s\n' "$AKEY" > "$TMP/key-bare"
printf 'export ANTHROPIC_API_KEY=%s\n' "$AKEY" > "$TMP/key-export"
printf '# metered key\nexport OTHER=zzz\nexport ANTHROPIC_API_KEY="%s"\n' "$AKEY" > "$TMP/key-quoted"
for f in key-bare key-export key-quoted; do
  A ANTHROPIC_API_KEY_FILE="$TMP/$f" "$ANTH" "$TMP/prompt.md" >/dev/null 2>&1 || fail "key file format $f"
  assert_eq "$(lastreq | jq -r .xApiKey)" "$AKEY" "key file format $f"
done

out="$(A ANTHROPIC_API_KEY="$AKEY" ANTHROPIC_API_MODEL=blocks "$ANTH" "$TMP/prompt.md" 2>&1)"; assert_contains "$out" "Four, obviously."; assert_not_contains "$out" "hmm" "thinking blocks are not part of the answer"
out="$(A ANTHROPIC_API_KEY="$AKEY" ANTHROPIC_API_MODEL=ratelimited "$ANTH" "$TMP/prompt.md" 2>&1)" && fail "429 must fail"; assert_contains "$out" "HTTP 429: Rate limit exceeded"; assert_not_contains "$out" "$AKEY"
out="$(A ANTHROPIC_API_KEY="$AKEY" ANTHROPIC_API_MODEL=badkey "$ANTH" "$TMP/prompt.md" 2>&1)" && fail "401 must fail"; assert_contains "$out" "HTTP 401: invalid x-api-key"
out="$(A ANTHROPIC_API_KEY="$AKEY" ANTHROPIC_API_MODEL=empty "$ANTH" "$TMP/prompt.md" 2>&1)" && fail "empty content must fail"; assert_contains "$out" "no text content"
out="$(A ANTHROPIC_API_KEY="$AKEY" ANTHROPIC_API_MODEL=huge "$ANTH" "$TMP/prompt.md" 2>&1)" && fail "token ceiling must fail"; assert_contains "$out" "token ceiling exceeded (900000 > 200000)"
out="$(A ANTHROPIC_API_BASE_URL="http://127.0.0.1:1" ANTHROPIC_API_KEY="$AKEY" "$ANTH" "$TMP/prompt.md" 2>&1)" && fail "unreachable must fail"; assert_contains "$out" "request failed"; assert_not_contains "$out" "$AKEY"
out="$(A "$ANTH" "$TMP/prompt.md" 2>&1)" && fail "unconfigured run must fail"; assert_contains "$out" "not configured"
out="$(A E3D_PILOT_DRY_RUN=1 ANTHROPIC_API_KEY="$AKEY" "$ANTH" "$TMP/prompt.md")"; assert_contains "$out" "redacted"; assert_not_contains "$out" "$AKEY" "dry-run must not print the key"
head -c 300000 /dev/zero | tr '\0' 'p' > "$TMP/big.md"
A ANTHROPIC_API_KEY="$AKEY" "$ANTH" "$TMP/big.md" >/dev/null 2>&1 || fail "a 300KB prompt must work"
assert_eq "$(lastreq | jq -r '.body | fromjson | .messages[0].content | length')" "300000"

# ================= openai-api =================
out="$(O E3D_PILOT_CHECK=1 "$OAI" 2>&1)" && fail "no key must be unavailable"; assert_contains "$out" "OPENAI_API_KEY"
out="$(O E3D_PILOT_CHECK=1 OPENAI_API_KEY="$OKEY" "$OAI" 2>&1)" && fail "no model must be unavailable (there is no default)"; assert_contains "$out" "OPENAI_API_MODEL"
out="$(O E3D_PILOT_CHECK=1 OPENAI_API_BASE_URL="http://127.0.0.1:1" OPENAI_API_KEY="$OKEY" OPENAI_API_MODEL=m "$OAI" 2>&1)" && fail "closed port must be unavailable"; assert_contains "$out" "not reachable"
out="$(O E3D_PILOT_CHECK=1 OPENAI_API_KEY="$OKEY" OPENAI_API_MODEL=gpt-test "$OAI" 2>&1)"; assert_contains "$out" "available (gpt-test)"; assert_not_contains "$out" "$OKEY"

: > "$TMP/api.log"
stdout="$(O OPENAI_API_KEY="$OKEY" OPENAI_API_MODEL=gpt-test "$OAI" "$TMP/prompt.md" 2> "$TMP/o.err")"
assert_eq "$stdout" "Four."
req="$(lastreq)"
assert_eq "$(jq -r .url <<< "$req")" "/v1/chat/completions"
assert_eq "$(jq -r .auth <<< "$req")" "Bearer $OKEY" "bearer auth"
assert_eq "$(jq -r '.body | fromjson | .model' <<< "$req")" "gpt-test"
assert_eq "$(jq -r '.body | fromjson | has("max_completion_tokens")' <<< "$req")" "false" "no token cap unless asked"
assert_eq "$(jq -r '.body | fromjson | .messages[0].content' <<< "$req")" "$(cat "$TMP/prompt.md")"
assert_not_contains "$stdout$(cat "$TMP/o.err")" "$OKEY"
assert_contains "$(cat "$TMP/o.err")" 'e3d_provider_usage={"provider":"openai-api","model":"gpt-test","tokens":9'
O OPENAI_API_KEY="$OKEY" OPENAI_API_MODEL=gpt-test OPENAI_API_MAX_TOKENS=64 "$OAI" "$TMP/prompt.md" >/dev/null 2>&1
assert_eq "$(lastreq | jq -r '.body | fromjson | .max_completion_tokens')" "64"
printf 'export OPENAI_API_KEY=%s\n' "$OKEY" > "$TMP/okey-export"
O OPENAI_API_KEY_FILE="$TMP/okey-export" OPENAI_API_MODEL=gpt-test "$OAI" "$TMP/prompt.md" >/dev/null 2>&1
assert_eq "$(lastreq | jq -r .auth)" "Bearer $OKEY" "OPENAI_API_KEY_FILE with an export line"

out="$(O OPENAI_API_KEY="$OKEY" OPENAI_API_MODEL=ratelimited "$OAI" "$TMP/prompt.md" 2>&1)" && fail "429 must fail"; assert_contains "$out" "HTTP 429: Rate limit exceeded"; assert_not_contains "$out" "$OKEY"
out="$(O OPENAI_API_KEY="$OKEY" OPENAI_API_MODEL=empty "$OAI" "$TMP/prompt.md" 2>&1)" && fail "empty must fail"; assert_contains "$out" "no message content"
out="$(O OPENAI_API_KEY="$OKEY" OPENAI_API_MODEL=huge "$OAI" "$TMP/prompt.md" 2>&1)" && fail "ceiling must fail"; assert_contains "$out" "token ceiling exceeded (900000 > 200000)"
out="$(O E3D_PILOT_DRY_RUN=1 OPENAI_API_KEY="$OKEY" OPENAI_API_MODEL=m "$OAI" "$TMP/prompt.md")"; assert_contains "$out" "redacted"; assert_not_contains "$out" "$OKEY"
ls "${TMPDIR:-/tmp}" 2>/dev/null | grep -qE '^e3d-pilot-(anthropic|openai)\.' && fail "temp dirs holding the key header must be removed"

# ================= a real debate across both, then through the MCP server =================
kill "$SERVER_PID" 2>/dev/null || true
BLOCK=$'FINAL ANSWER: Use JSON.\nCONSENSUS: split\nDISSENT: one voice prefers SQLite.\n'
DEBATE_TEXT="$BLOCK" node "$TMP/fake-api.mjs" "$TMP/api2.log" > "$TMP/port2" & SERVER_PID=$!
for _ in $(seq 1 50); do [[ -s "$TMP/port2" ]] && break; sleep 0.1; done
BASE2="http://127.0.0.1:$(cat "$TMP/port2")"
ENVSET=(TYPESAFE_API_KEY= ANTHROPIC_API_BASE_URL="$BASE2" ANTHROPIC_API_KEY="$AKEY" OPENAI_API_BASE_URL="$BASE2/v1" OPENAI_API_KEY="$OKEY" OPENAI_API_MODEL=gpt-test)
out="$(env "${ENVSET[@]}" "$ROOT/bin/e3d-debate" "JSON or SQLite?" --providers anthropic-api,openai-api --rounds 1 --synthesizer anthropic-api 2>/dev/null)"
assert_contains "$out" "FINAL ANSWER: Use JSON."; assert_contains "$out" "CONSENSUS: split"
assert_not_contains "$out" "$AKEY"; assert_not_contains "$out" "$OKEY"

plan="$(jq -nc --arg s "$ROOT/bin/e3d-mcp" --arg b "$BASE2" --arg ak "$AKEY" --arg ok "$OKEY" \
  '{server:$s, env:{TYPESAFE_API_KEY:"", ANTHROPIC_API_BASE_URL:$b, ANTHROPIC_API_KEY:$ak, OPENAI_API_BASE_URL:($b+"/v1"), OPENAI_API_KEY:$ok, OPENAI_API_MODEL:"gpt-test"},
    calls:[{name:"e3d_debate", arguments:{question:"JSON or SQLite?", providers:["anthropic-api","openai-api"], mode:"quick"}}]}')"
res="$(node "$ROOT/tests/fixtures/mcp-test-client.mjs" "$plan")"
[[ "$(jq -r '.results[0].isError // false' <<< "$res")" == "false" ]] || fail "MCP debate over the API providers failed: $(jq -r '.results[0].content[0].text' <<< "$res")"
assert_eq "$(jq -r '.results[0].structuredContent.consensus' <<< "$res")" "split"
assert_eq "$(jq -r '.results[0].structuredContent.providers | join(",")' <<< "$res")" "anthropic-api,openai-api"
assert_not_contains "$res" "$AKEY"; assert_not_contains "$res" "$OKEY"

echo "providers-api.sh: ok"
