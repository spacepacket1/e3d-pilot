#!/usr/bin/env bash
set -euo pipefail

# Bedrock and Azure OpenAI provider adapters, against a fake `aws` binary and a fake local HTTP server.
# No network beyond 127.0.0.1, no credentials, no spend.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BEDROCK="$ROOT/lib/providers/bedrock"
AZURE="$ROOT/lib/providers/azure-openai"
TMP="$(mktemp -d)"
SERVER_PID=""
trap '[[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-assert_eq}: expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "${3:-assert_contains}: expected to find [$2] in [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "${3:-assert_not_contains}: did not expect [$2] in [$1]"; }

SECRET="sk-azure-SECRETKEY-1234567890abcdef"
printf 'What is 2+2?\n' > "$TMP/prompt.md"

# ---------------- registration ----------------
list="$("$ROOT/bin/e3d-pilot" providers list)"
assert_contains "$list" "bedrock"; assert_contains "$list" "azure-openai"
grep -q "'bedrock', 'azure-openai'" "$ROOT/lib/mcp/voices.js" || fail "voices.js CLI_ORDER must list the new providers after the existing ones"

# ---------------- bedrock (fake aws) ----------------
cat > "$TMP/aws" <<'AEOF'
#!/usr/bin/env bash
# Fake aws: records argv and the payload, answers like `bedrock-runtime converse`.
printf '%s\n' "$*" > "$FAKE_AWS_ARGS"
payload=""
for a in "$@"; do [[ "$a" == file://* ]] && payload="${a#file://}"; done
[[ -n "$payload" ]] && cp "$payload" "$FAKE_AWS_PAYLOAD"
case "${FAKE_AWS_MODE:-ok}" in
  ok) cat <<'JSON'
{"output":{"message":{"role":"assistant","content":[{"text":"Four"},{"text":", obviously."}]}},"stopReason":"end_turn","usage":{"inputTokens":10,"outputTokens":5,"totalTokens":15}}
JSON
  ;;
  empty) echo '{"output":{"message":{"role":"assistant","content":[]}},"usage":{"totalTokens":1}}' ;;
  big) echo '{"output":{"message":{"role":"assistant","content":[{"text":"huge"}]}},"usage":{"totalTokens":900000}}' ;;
  fail) echo "An error occurred (AccessDeniedException): not allowed to invoke this model" >&2; exit 254 ;;
esac
AEOF
chmod +x "$TMP/aws"
export FAKE_AWS_ARGS="$TMP/aws.args" FAKE_AWS_PAYLOAD="$TMP/aws.payload"
B() { env -u AWS_REGION -u AWS_DEFAULT_REGION -u BEDROCK_MODEL_ID AWS_BIN="$TMP/aws" "$@"; }

out="$(B E3D_PILOT_CHECK=1 AWS_BIN="$TMP/nope" BEDROCK_MODEL_ID=m AWS_REGION=r "$BEDROCK" 2>&1)" && fail "no aws binary must be unavailable"; assert_contains "$out" "aws CLI not found"
out="$(B E3D_PILOT_CHECK=1 AWS_REGION=us-east-1 "$BEDROCK" 2>&1)" && fail "no model id must be unavailable"; assert_contains "$out" "BEDROCK_MODEL_ID"
out="$(B E3D_PILOT_CHECK=1 BEDROCK_MODEL_ID=m "$BEDROCK" 2>&1)" && fail "no region must be unavailable"; assert_contains "$out" "AWS_REGION"
out="$(B E3D_PILOT_CHECK=1 BEDROCK_MODEL_ID=m AWS_DEFAULT_REGION=eu-west-1 "$BEDROCK" 2>&1)"; assert_contains "$out" "available (m in eu-west-1)"

stdout="$(B BEDROCK_MODEL_ID=anthropic.test-model AWS_REGION=us-east-1 "$BEDROCK" "$TMP/prompt.md" 2> "$TMP/b.err")"
assert_eq "$stdout" "Four, obviously." "content parts are joined"
assert_contains "$(cat "$FAKE_AWS_ARGS")" "bedrock-runtime converse --region us-east-1 --cli-input-json file://"
assert_not_contains "$(cat "$FAKE_AWS_ARGS")" "What is 2+2" "the prompt must not appear on the command line"
assert_eq "$(jq -r .modelId "$FAKE_AWS_PAYLOAD")" "anthropic.test-model"
assert_eq "$(jq -r '.messages[0].content[0].text' "$FAKE_AWS_PAYLOAD")" "$(cat "$TMP/prompt.md")" "prompt delivered through the payload file"
assert_eq "$(jq -r .inferenceConfig.maxTokens "$FAKE_AWS_PAYLOAD")" "4096"
assert_contains "$(cat "$TMP/b.err")" 'e3d_provider_usage={"provider":"bedrock"'
assert_eq "$(B BEDROCK_MODEL_ID=m AWS_REGION=r BEDROCK_MAX_TOKENS=777 "$BEDROCK" "$TMP/prompt.md" >/dev/null 2>&1; jq -r .inferenceConfig.maxTokens "$FAKE_AWS_PAYLOAD")" "777" "BEDROCK_MAX_TOKENS"

head -c 300000 /dev/zero | tr '\0' 'p' > "$TMP/big-prompt.md"
B BEDROCK_MODEL_ID=m AWS_REGION=r "$BEDROCK" "$TMP/big-prompt.md" >/dev/null 2>&1 || fail "a 300KB prompt must work (payload file, not argv)"
assert_eq "$(jq -r '.messages[0].content[0].text | length' "$FAKE_AWS_PAYLOAD")" "300000"

out="$(B FAKE_AWS_MODE=fail BEDROCK_MODEL_ID=m AWS_REGION=r "$BEDROCK" "$TMP/prompt.md" 2>&1)" && fail "aws failure must fail"; assert_contains "$out" "bedrock converse failed (aws exit 254)"; assert_contains "$out" "AccessDeniedException"
out="$(B FAKE_AWS_MODE=empty BEDROCK_MODEL_ID=m AWS_REGION=r "$BEDROCK" "$TMP/prompt.md" 2>&1)" && fail "empty content must fail"; assert_contains "$out" "no text content"
out="$(B FAKE_AWS_MODE=big BEDROCK_MODEL_ID=m AWS_REGION=r "$BEDROCK" "$TMP/prompt.md" 2>&1)" && fail "token ceiling must fail"; assert_contains "$out" "token ceiling exceeded (900000 > 200000)"
out="$(B E3D_PILOT_DRY_RUN=1 BEDROCK_MODEL_ID=m AWS_REGION=r "$BEDROCK" "$TMP/prompt.md")"; assert_contains "$out" "bedrock-runtime converse"
out="$(B BEDROCK_MODEL_ID=m AWS_REGION=r "$BEDROCK" 2>&1)" && fail "missing prompt file must fail"; assert_contains "$out" "prompt file path required"

# ---------------- azure-openai (fake local HTTP server) ----------------
cat > "$TMP/fake-azure.mjs" <<'JS'
import http from 'node:http';
import { appendFileSync } from 'node:fs';
const log = process.argv[2];
const srv = http.createServer((req, res) => {
  let body = '';
  req.on('data', (d) => { body += d; });
  req.on('end', () => {
    appendFileSync(log, `${JSON.stringify({ method: req.method, url: req.url, apiKey: req.headers['api-key'] ?? null, body })}\n`);
    if (!req.url.startsWith('/openai/deployments/')) { res.writeHead(404); res.end('not found'); return; }
    const mode = req.headers['x-mode'] ?? 'ok';
    const dep = req.url.split('/')[3];
    if (dep === 'ratelimited') { res.writeHead(429, { 'content-type': 'application/json' }); res.end(JSON.stringify({ error: { message: 'Rate limit exceeded, retry later' } })); return; }
    if (dep === 'empty') { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify({ choices: [{ message: { content: '' } }], usage: { total_tokens: 1 } })); return; }
    if (dep === 'huge') { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify({ choices: [{ message: { content: 'x' } }], usage: { total_tokens: 900000 } })); return; }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ model: 'gpt-test', choices: [{ message: { content: 'Four.' } }], usage: { prompt_tokens: 7, completion_tokens: 2, total_tokens: 9 } }));
  });
});
srv.listen(0, '127.0.0.1', () => console.log(srv.address().port));
JS
: > "$TMP/azure.log"
node "$TMP/fake-azure.mjs" "$TMP/azure.log" > "$TMP/port" &
SERVER_PID=$!
for _ in $(seq 1 50); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
PORT="$(cat "$TMP/port")"; [[ -n "$PORT" ]] || fail "fake Azure server did not start"
EP="http://127.0.0.1:$PORT"
Z() { env -u AZURE_OPENAI_ENDPOINT -u AZURE_OPENAI_DEPLOYMENT -u AZURE_OPENAI_API_KEY -u AZURE_OPENAI_API_KEY_FILE -u AZURE_OPENAI_API_VERSION "$@"; }

out="$(Z E3D_PILOT_CHECK=1 "$AZURE" 2>&1)" && fail "unconfigured azure must be unavailable"; assert_contains "$out" "set AZURE_OPENAI_ENDPOINT"
out="$(Z E3D_PILOT_CHECK=1 AZURE_OPENAI_ENDPOINT="$EP" AZURE_OPENAI_DEPLOYMENT=d1 "$AZURE" 2>&1)" && fail "no key must be unavailable"; assert_contains "$out" "AZURE_OPENAI_API_KEY"
out="$(Z E3D_PILOT_CHECK=1 AZURE_OPENAI_ENDPOINT="http://127.0.0.1:1" AZURE_OPENAI_DEPLOYMENT=d1 AZURE_OPENAI_API_KEY="$SECRET" "$AZURE" 2>&1)" && fail "closed port must be unavailable"; assert_contains "$out" "not reachable"
out="$(Z E3D_PILOT_CHECK=1 AZURE_OPENAI_ENDPOINT="$EP" AZURE_OPENAI_DEPLOYMENT=d1 AZURE_OPENAI_API_KEY="$SECRET" "$AZURE" 2>&1)"; assert_contains "$out" "available (deployment d1)"
assert_not_contains "$out" "$SECRET"
[[ "$(jq -s 'map(select(.apiKey != null)) | length' "$TMP/azure.log")" == "0" ]] || fail "the availability probe must never send the key"

: > "$TMP/azure.log"
stdout="$(Z AZURE_OPENAI_ENDPOINT="$EP/" AZURE_OPENAI_DEPLOYMENT=d1 AZURE_OPENAI_API_KEY="$SECRET" "$AZURE" "$TMP/prompt.md" 2> "$TMP/z.err")"
assert_eq "$stdout" "Four."
req="$(tail -1 "$TMP/azure.log")"
assert_eq "$(jq -r .url <<< "$req")" "/openai/deployments/d1/chat/completions?api-version=2024-10-21" "URL shape and default api-version"
assert_eq "$(jq -r .apiKey <<< "$req")" "$SECRET" "key sent in the api-key header"
assert_eq "$(jq -r '.body | fromjson | .messages[0].content' <<< "$req")" "$(cat "$TMP/prompt.md")" "prompt in the request body"
assert_not_contains "$stdout$(cat "$TMP/z.err")" "$SECRET" "the key is never printed"
assert_contains "$(cat "$TMP/z.err")" 'e3d_provider_usage={"provider":"azure-openai","model":"gpt-test","tokens":9'

Z AZURE_OPENAI_ENDPOINT="$EP" AZURE_OPENAI_DEPLOYMENT=d1 AZURE_OPENAI_API_KEY="$SECRET" AZURE_OPENAI_API_VERSION=2025-01-01 AZURE_OPENAI_MAX_TOKENS=64 "$AZURE" "$TMP/prompt.md" >/dev/null 2>&1
req="$(tail -1 "$TMP/azure.log")"
assert_contains "$(jq -r .url <<< "$req")" "api-version=2025-01-01"
assert_eq "$(jq -r '.body | fromjson | .max_completion_tokens' <<< "$req")" "64"
printf '%s\n' "$SECRET" > "$TMP/keyfile"
Z AZURE_OPENAI_ENDPOINT="$EP" AZURE_OPENAI_DEPLOYMENT=d1 AZURE_OPENAI_API_KEY_FILE="$TMP/keyfile" "$AZURE" "$TMP/prompt.md" >/dev/null 2>&1
assert_eq "$(tail -1 "$TMP/azure.log" | jq -r .apiKey)" "$SECRET" "AZURE_OPENAI_API_KEY_FILE"

out="$(Z AZURE_OPENAI_ENDPOINT="$EP" AZURE_OPENAI_DEPLOYMENT=ratelimited AZURE_OPENAI_API_KEY="$SECRET" "$AZURE" "$TMP/prompt.md" 2>&1)" && fail "429 must fail"
assert_contains "$out" "HTTP 429: Rate limit exceeded"; assert_not_contains "$out" "$SECRET"
out="$(Z AZURE_OPENAI_ENDPOINT="$EP" AZURE_OPENAI_DEPLOYMENT=empty AZURE_OPENAI_API_KEY="$SECRET" "$AZURE" "$TMP/prompt.md" 2>&1)" && fail "empty content must fail"; assert_contains "$out" "no message content"
out="$(Z AZURE_OPENAI_ENDPOINT="$EP" AZURE_OPENAI_DEPLOYMENT=huge AZURE_OPENAI_API_KEY="$SECRET" "$AZURE" "$TMP/prompt.md" 2>&1)" && fail "token ceiling must fail"; assert_contains "$out" "token ceiling exceeded (900000 > 200000)"
out="$(Z AZURE_OPENAI_ENDPOINT="http://127.0.0.1:1" AZURE_OPENAI_DEPLOYMENT=d1 AZURE_OPENAI_API_KEY="$SECRET" "$AZURE" "$TMP/prompt.md" 2>&1)" && fail "unreachable endpoint must fail"; assert_contains "$out" "request failed"; assert_not_contains "$out" "$SECRET"
out="$(Z E3D_PILOT_DRY_RUN=1 AZURE_OPENAI_ENDPOINT="$EP" AZURE_OPENAI_DEPLOYMENT=d1 AZURE_OPENAI_API_KEY="$SECRET" "$AZURE" "$TMP/prompt.md")"
assert_contains "$out" "redacted"; assert_not_contains "$out" "$SECRET" "dry-run must not print the key"
ls "${TMPDIR:-/tmp}" 2>/dev/null | grep -q '^e3d-pilot-azure\.' && fail "temp dirs holding the key header must be removed"

# ---------------- both inside a real e3d-debate run ----------------
BLOCK=$'FINAL ANSWER: Use JSON.\nCONSENSUS: split\nDISSENT: one voice prefers SQLite.\n'
cat > "$TMP/aws-debate" <<'AEOF'
#!/usr/bin/env bash
jq -n --arg t "$DEBATE_TEXT" '{output:{message:{role:"assistant",content:[{text:$t}]}},usage:{totalTokens:5}}'
AEOF
chmod +x "$TMP/aws-debate"
cat > "$TMP/fake-azure-debate.mjs" <<'JS'
import http from 'node:http';
const srv = http.createServer((req, res) => { req.resume(); req.on('end', () => { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify({ choices: [{ message: { content: process.env.DEBATE_TEXT } }], usage: { total_tokens: 5 } })); }); });
srv.listen(0, '127.0.0.1', () => console.log(srv.address().port));
JS
kill "$SERVER_PID" 2>/dev/null || true
DEBATE_TEXT="$BLOCK" node "$TMP/fake-azure-debate.mjs" > "$TMP/port2" & SERVER_PID=$!
for _ in $(seq 1 50); do [[ -s "$TMP/port2" ]] && break; sleep 0.1; done
out="$(env -u TYPESAFE_API_KEY DEBATE_TEXT="$BLOCK" AWS_BIN="$TMP/aws-debate" BEDROCK_MODEL_ID=m AWS_REGION=r \
  AZURE_OPENAI_ENDPOINT="http://127.0.0.1:$(cat "$TMP/port2")" AZURE_OPENAI_DEPLOYMENT=d AZURE_OPENAI_API_KEY="$SECRET" \
  "$ROOT/bin/e3d-debate" "JSON or SQLite?" --providers bedrock,azure-openai --rounds 1 --synthesizer bedrock 2>/dev/null)"
assert_contains "$out" "FINAL ANSWER: Use JSON."
assert_contains "$out" "CONSENSUS: split"
assert_not_contains "$out" "$SECRET"

echo "providers-cloud.sh: ok"
