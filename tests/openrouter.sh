#!/usr/bin/env bash
set -euo pipefail

# The OpenRouter transport and its voices (lib/providers/openrouter, or-*, openrouter-models.json) against a fake local server.
# No network beyond 127.0.0.1, no real key, no spend.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OR="$ROOT/lib/providers/openrouter"
REG="$ROOT/lib/providers/openrouter-models.json"
TMP="$(mktemp -d)"
SERVER_PID=""
trap '[[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-assert_eq}: expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "${3:-assert_contains}: expected to find [$2] in [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "${3:-assert_not_contains}: did not expect [$2] in [$1]"; }

KEY="sk-or-v1-SECRETKEY-1234567890abcdef"
printf 'What is 2+2?\n' > "$TMP/prompt.md"

# ---------------- the registry ----------------
node --input-type=module -e "
import { loadRegistry, validateRegistry, voiceFamilies, DIRECT_FAMILIES } from '$ROOT/lib/debate/model-registry.mjs';
import { readFileSync, statSync } from 'node:fs';
const reg = JSON.parse(readFileSync('$REG', 'utf8'));
const bad = validateRegistry(reg); if (bad.length) { console.error(bad.join('\n')); process.exit(1); }
const models = loadRegistry();
if (models.map((m) => m.voice_id).join() !== 'or-deepseek,or-glm,or-minimax,or-mistral') { console.error('the four initial voices'); process.exit(1); }
for (const m of models) {
  if (!(statSync('$ROOT/lib/providers/' + m.voice_id).mode & 0o111)) { console.error('voice script not executable: ' + m.voice_id); process.exit(1); }
  if (DIRECT_FAMILIES.includes(m.family_id)) { console.error('direct family on OpenRouter'); process.exit(1); }
  if (m.auto_eligible) { console.error('nothing is auto-eligible before the evaluation: ' + m.voice_id); process.exit(1); }
}
const fam = voiceFamilies(models);
if (new Set(Object.values(fam)).size !== 4) { console.error('four voices, four families'); process.exit(1); }
const ok = (mut, expect) => { const c = structuredClone(reg); mut(c); const p = validateRegistry(c).join('|'); if (!p.includes(expect)) { console.error('expected a problem containing [' + expect + '], got [' + p + ']'); process.exit(1); } };
ok((c) => { c.models[0].family_id = 'openai'; }, 'has a direct adapter');
ok((c) => { c.models[1].family_id = 'anthropic'; }, 'never routed through OpenRouter');
ok((c) => { c.models[0].model_id = '~deepseek/deepseek-flash-latest'; }, 'moving alias');
ok((c) => { c.models[0].model_id = 'deepseek/deepseek-flash-latest'; }, 'moving alias');
ok((c) => { c.models[0].input_price = 0; }, 'input_price must be a positive number');
ok((c) => { delete c.models[0].output_price; }, 'missing output_price');
ok((c) => { c.models[1].voice_id = 'or-deepseek'; }, 'duplicate voice_id');
ok((c) => { c.models[0].pricing_checked_at = 'yesterday'; }, 'pricing_checked_at');
ok((c) => { c.models[0].enabled = false; c.models[0].auto_eligible = true; }, 'cannot be auto_eligible');
if (loadRegistry('/nonexistent/file.json').length !== 0) { console.error('a missing registry must load as empty'); process.exit(1); }
" || fail "registry"

# independence counts families, not adapters: GPT direct plus GPT-family-on-OpenRouter is one family, four distinct OpenRouter families are four
node --input-type=module -e "
import { independence, OPENROUTER_VOICE_FAMILY, PROVIDER_FAMILY } from '$ROOT/lib/mcp/voices.js';
const four = independence(['or-deepseek', 'or-glm', 'or-minimax', 'or-mistral'], []);
if (!four.independent || four.families.length !== 4 || four.warnings.length) { console.error('four OpenRouter voices are four families'); process.exit(1); }
const mixed = independence(['openai-api', 'or-deepseek'], []);
if (!mixed.independent || mixed.families.join() !== 'openai,deepseek') { console.error('direct and OpenRouter voices mix'); process.exit(1); }
if (Object.keys(PROVIDER_FAMILY).some((k) => k.startsWith('or-'))) { console.error('PROVIDER_FAMILY is the hosting service\'s list: no OpenRouter voices in it'); process.exit(1); }
if (OPENROUTER_VOICE_FAMILY['or-glm'] !== 'glm') { console.error('or-glm family'); process.exit(1); }
" || fail "independence"

# ---------------- registration ----------------
list="$("$ROOT/bin/e3d-pilot" providers list)"
for v in or-deepseek or-glm or-minimax or-mistral; do assert_contains "$list" "$v"; done
for v in or-deepseek or-glm or-minimax or-mistral; do [[ -x "$ROOT/lib/providers/$v" ]] || fail "$v must be an executable voice script"; done
grep -q "or-deepseek" "$ROOT/bin/e3d-debate" && fail "OpenRouter voices must not join e3d-debate's automatic expert pool: no default changes" || true
grep -q "'or-" "$ROOT/lib/mcp/voices.js" && fail "OpenRouter voices must not join the automatic CLI_ORDER" || true

# ---------------- fake server ----------------
cat > "$TMP/fake-or.mjs" <<'JS'
import http from 'node:http';
import { appendFileSync } from 'node:fs';
const log = process.argv[2];
const srv = http.createServer((req, res) => {
  let body = '';
  req.on('data', (d) => { body += d; });
  req.on('end', () => {
    let parsed = {}; try { parsed = JSON.parse(body); } catch { /* probe */ }
    appendFileSync(log, `${JSON.stringify({ method: req.method, url: req.url, auth: req.headers.authorization ?? null, body })}\n`);
    const model = parsed.model ?? '';
    const send = (code, obj) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(typeof obj === 'string' ? obj : JSON.stringify(obj)); };
    if (req.url !== '/api/v1/chat/completions') { res.writeHead(404); return res.end('not found'); }
    if (model === 'ratelimited') return send(429, { error: { code: 429, message: 'Rate limit exceeded, retry later' } });
    if (model === 'badkey') return send(401, { error: { code: 401, message: 'No auth credentials found' } });
    if (model === 'nocredits') return send(402, { error: { code: 402, message: 'Insufficient credits' } });
    if (model === 'noendpoint') return send(404, { error: { code: 404, message: 'No endpoints found matching your data policy' } });
    if (model === 'down') return send(503, { error: { code: 503, message: 'upstream unavailable' } });
    if (model === 'malformed') return send(200, 'this is not json');
    if (model === 'empty') return send(200, { id: 'gen-empty', model, choices: [{ message: { content: '' } }], usage: { prompt_tokens: 7, completion_tokens: 50, total_tokens: 57 } });
    if (model === 'errin200') return send(200, { error: { code: 502, message: 'Provider returned error' } });
    if (model === 'huge') return send(200, { id: 'gen-huge', model, choices: [{ message: { content: 'x' } }], usage: { prompt_tokens: 7, completion_tokens: 899993, total_tokens: 900000 } });
    if (model === 'parts') return send(200, { id: 'gen-parts', model, choices: [{ message: { content: [{ type: 'text', text: 'Four' }, { type: 'text', text: ', obviously.' }] } }], usage: { prompt_tokens: 7, completion_tokens: 2, total_tokens: 9 } });
    if (model === 'nousage') return send(200, { id: 'gen-nu', model, choices: [{ message: { content: 'Four.' } }] });
    return send(200, { id: `gen-${model.replace(/\W/g, '')}`, model: `${model}-20260910`, provider: 'FakeHost', choices: [{ message: { content: 'Four.' } }], usage: { prompt_tokens: 7, completion_tokens: 2, total_tokens: 9, cost: 0.000012 } });
  });
});
srv.listen(0, '127.0.0.1', () => console.log(srv.address().port));
JS
: > "$TMP/api.log"
node "$TMP/fake-or.mjs" "$TMP/api.log" > "$TMP/port" &
SERVER_PID=$!
for _ in $(seq 1 50); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
PORT="$(cat "$TMP/port")"; [[ -n "$PORT" ]] || fail "fake API server did not start"
BASE="http://127.0.0.1:$PORT/api/v1"
# a registry whose voices run the fake server's special models
cat > "$TMP/reg.json" <<JSON
{"version":1,"models":[
$(for m in ratelimited badkey nocredits noendpoint down malformed empty errin200 huge parts nousage; do
printf '{"voice_id":"or-t-%s","transport":"openrouter","model_id":"x/%s","family_id":"fam-%s","organization_id":"x","display_name":"t","capabilities":[],"context_window":1000,"input_price":0.1,"output_price":0.1,"pricing_source":"t","pricing_checked_at":"2026-01-01","availability":"eligible","privacy_attributes":{},"enabled":true,"auto_eligible":false},\n' "$m" "$m" "$m"
done)
{"voice_id":"or-t-off","transport":"openrouter","model_id":"x/off","family_id":"fam-off","organization_id":"x","display_name":"t","capabilities":[],"context_window":1000,"input_price":0.1,"output_price":0.1,"pricing_source":"t","pricing_checked_at":"2026-01-01","availability":"unavailable","privacy_attributes":{},"enabled":false,"auto_eligible":false}
]}
JSON
sed -i.bak -E 's#"model_id":"x/([a-z0-9]+)"#"model_id":"\1"#' "$TMP/reg.json" && rm -f "$TMP/reg.json.bak"
R() { env -u OPENROUTER_API_KEY -u OPENROUTER_API_KEY_FILE -u OPENROUTER_MODEL -u OPENROUTER_MAX_TOKENS -u OPENROUTER_ZDR -u OPENROUTER_ONLY -u OPENROUTER_DATA_COLLECTION -u OPENROUTER_ALLOW_FALLBACKS -u OPENROUTER_REASONING_EFFORT -u E3D_OPENROUTER_VOICE OPENROUTER_BASE_URL="$BASE" "$@"; }
lastreq() { tail -1 "$TMP/api.log"; }
RV() { local v="$1"; shift; R E3D_OPENROUTER_REGISTRY="$TMP/reg.json" E3D_OPENROUTER_VOICE="$v" OPENROUTER_API_KEY="$KEY" "$@"; }

# ---------------- availability check ----------------
out="$(R E3D_PILOT_CHECK=1 E3D_OPENROUTER_VOICE=or-deepseek "$OR" 2>&1)" && fail "no key must be unavailable"; assert_contains "$out" "OPENROUTER_API_KEY"
out="$(R E3D_PILOT_CHECK=1 OPENROUTER_API_KEY="$KEY" "$OR" 2>&1)" && fail "the bare voice with no model must be unavailable"; assert_contains "$out" "OPENROUTER_MODEL"
out="$(R E3D_PILOT_CHECK=1 OPENROUTER_API_KEY="$KEY" OPENROUTER_BASE_URL="http://127.0.0.1:1" E3D_OPENROUTER_VOICE=or-glm "$OR" 2>&1)" && fail "closed port must be unavailable"; assert_contains "$out" "not reachable"
out="$(R E3D_PILOT_CHECK=1 OPENROUTER_API_KEY="$KEY" E3D_OPENROUTER_VOICE=or-glm "$OR" 2>&1)"; assert_eq "$out" "available (z-ai/glm-5.3-flash)"
assert_not_contains "$out" "$KEY"
out="$(RV or-t-off E3D_PILOT_CHECK=1 "$OR" 2>&1)" && fail "a disabled voice must be unavailable"; assert_contains "$out" "not enabled in the model registry"
out="$(RV or-unknown E3D_PILOT_CHECK=1 "$OR" 2>&1)" && fail "an unknown voice must be unavailable"; assert_contains "$out" "not enabled in the model registry"
[[ "$(jq -s 'map(select(.auth != null)) | length' "$TMP/api.log")" == "0" ]] || fail "the availability probe must never send the key"

# ---------------- a normal call, per voice ----------------
for pair in "or-deepseek:deepseek/deepseek-v4.1-flash" "or-glm:z-ai/glm-5.3-flash" "or-minimax:minimax/minimax-m3.1-flash" "or-mistral:mistralai/mistral-small-2603"; do
  v="${pair%%:*}"; model="${pair#*:}"
  : > "$TMP/api.log"
  stdout="$(R OPENROUTER_API_KEY="$KEY" "$ROOT/lib/providers/$v" "$TMP/prompt.md" 2> "$TMP/o.err")"
  assert_eq "$stdout" "Four." "$v answer"
  req="$(lastreq)"
  assert_eq "$(jq -r .url <<< "$req")" "/api/v1/chat/completions"
  assert_eq "$(jq -r .auth <<< "$req")" "Bearer $KEY" "key in the Authorization header"
  assert_eq "$(jq -r '.body | fromjson | .model' <<< "$req")" "$model" "$v runs its registry model"
  assert_eq "$(jq -r '.body | fromjson | .messages[0].content' <<< "$req")" "$(cat "$TMP/prompt.md")" "prompt in the body"
  assert_eq "$(jq -c '.body | fromjson | .provider' <<< "$req")" '{"data_collection":"deny","require_parameters":true}' "privacy first by default"
  assert_eq "$(jq -r '.body | fromjson | .usage.include' <<< "$req")" "true" "usage requested"
  assert_eq "$(jq -r '.body | fromjson | has("max_tokens")' <<< "$req")" "false" "no limit unless asked"
  assert_not_contains "$stdout$(cat "$TMP/o.err")" "$KEY" "the key is never printed"
  usage="$(sed -n 's/^e3d_provider_usage=//p' "$TMP/o.err")"
  assert_eq "$(jq -r .provider <<< "$usage")" "$v" "the usage line names the voice"
  assert_eq "$(jq -r .model <<< "$usage")" "$model-20260910" "the resolved model, as the service reports it"
  assert_eq "$(jq -c '[.input_tokens, .output_tokens, .tokens]' <<< "$usage")" "[7,2,9]"
  assert_eq "$(jq -c '.routing' <<< "$usage")" "{\"transport\":\"openrouter\",\"requested\":\"$model\",\"request_id\":\"gen-$(tr -dc 'a-z0-9' <<< "$model")\",\"upstream\":\"FakeHost\",\"cost\":0.000012}" "routing facts for the receipt"
done

# ---------------- request options ----------------
: > "$TMP/api.log"
R OPENROUTER_API_KEY="$KEY" OPENROUTER_MODEL=custom/model OPENROUTER_MAX_TOKENS=64 OPENROUTER_ZDR=1 OPENROUTER_ONLY="Alpha, Beta" OPENROUTER_ALLOW_FALLBACKS=0 OPENROUTER_REASONING_EFFORT=low "$OR" "$TMP/prompt.md" >/dev/null 2>&1
req="$(lastreq)"
assert_eq "$(jq -r '.body | fromjson | .model' <<< "$req")" "custom/model" "the bare voice runs OPENROUTER_MODEL"
assert_eq "$(jq -r '.body | fromjson | .max_tokens' <<< "$req")" "64"
assert_eq "$(jq -c '.body | fromjson | .provider' <<< "$req")" '{"data_collection":"deny","require_parameters":true,"zdr":true,"only":["Alpha","Beta"],"allow_fallbacks":false}'
assert_eq "$(jq -c '.body | fromjson | .reasoning' <<< "$req")" '{"effort":"low"}'
R OPENROUTER_API_KEY="$KEY" OPENROUTER_MODEL=custom/model OPENROUTER_DATA_COLLECTION=allow "$OR" "$TMP/prompt.md" >/dev/null 2>&1
assert_eq "$(lastreq | jq -c '.body | fromjson | .provider')" '{"data_collection":"allow","require_parameters":true}'
out="$(R OPENROUTER_API_KEY="$KEY" OPENROUTER_MODEL=m OPENROUTER_DATA_COLLECTION=maybe "$OR" "$TMP/prompt.md" 2>&1)" && fail "bad data collection value"; assert_contains "$out" "must be deny or allow"
out="$(R OPENROUTER_API_KEY="$KEY" OPENROUTER_MODEL=m OPENROUTER_MAX_TOKENS=lots "$OR" "$TMP/prompt.md" 2>&1)" && fail "bad max tokens"; assert_contains "$out" "must be a number"
out="$(R OPENROUTER_API_KEY="$KEY" OPENROUTER_MODEL=m OPENROUTER_REASONING_EFFORT=extreme "$OR" "$TMP/prompt.md" 2>&1)" && fail "bad effort"; assert_contains "$out" "low, medium or high"

# key files: bare key, `export NAME=key`, quoted, and with other lines present
printf '%s\n' "$KEY" > "$TMP/key-bare"
printf 'export OPENROUTER_API_KEY=%s\n' "$KEY" > "$TMP/key-export"
printf '# metered key\nexport OTHER=zzz\nexport OPENROUTER_API_KEY="%s"\n' "$KEY" > "$TMP/key-quoted"
for f in key-bare key-export key-quoted; do
  R OPENROUTER_API_KEY_FILE="$TMP/$f" OPENROUTER_MODEL=custom/model "$OR" "$TMP/prompt.md" >/dev/null 2>&1 || fail "key file format $f"
  assert_eq "$(lastreq | jq -r .auth)" "Bearer $KEY" "key file format $f"
done
# the key never appears on a command line while a call runs
: > "$TMP/api.log"
R OPENROUTER_API_KEY="$KEY" OPENROUTER_MODEL=custom/model "$OR" "$TMP/prompt.md" >/dev/null 2>&1 &
CALL_PID=$!
for _ in 1 2 3 4 5 6; do ps -A -o command= | grep -F "$KEY" | grep -v grep && fail "the key is on a command line" || true; sleep 0.03; done
wait "$CALL_PID"

# ---------------- failures ----------------
out="$(RV or-t-ratelimited "$OR" "$TMP/prompt.md" 2>&1)" && fail "429 must fail"; assert_contains "$out" "HTTP 429: Rate limit exceeded"; assert_not_contains "$out" "$KEY"
out="$(RV or-t-badkey "$OR" "$TMP/prompt.md" 2>&1)" && fail "401 must fail"; assert_contains "$out" "HTTP 401: No auth credentials found (the OpenRouter key was refused)"
out="$(RV or-t-nocredits "$OR" "$TMP/prompt.md" 2>&1)" && fail "402 must fail"; assert_contains "$out" "HTTP 402: Insufficient credits (the OpenRouter account is out of credits)"
out="$(RV or-t-noendpoint "$OR" "$TMP/prompt.md" 2>&1)" && fail "no endpoint must fail, never fall back past the privacy setting"; assert_contains "$out" "HTTP 404"; assert_contains "$out" "privacy or routing"
out="$(RV or-t-down "$OR" "$TMP/prompt.md" 2>&1)" && fail "503 must fail"; assert_contains "$out" "HTTP 503"
out="$(RV or-t-malformed "$OR" "$TMP/prompt.md" 2>&1)" && fail "malformed must fail"; assert_contains "$out" "not JSON"
out="$(RV or-t-errin200 "$OR" "$TMP/prompt.md" 2>&1)" && fail "an error body with 200 must fail"; assert_contains "$out" "HTTP 502: Provider returned error"
out="$(RV or-t-empty "$OR" "$TMP/prompt.md" 2>&1)" && fail "empty content must fail"; assert_contains "$out" "no message content"; assert_contains "$out" 'e3d_provider_usage={"provider":"or-t-empty"'
assert_contains "$out" '"output_tokens":50' "an empty reply is still billed"
out="$(RV or-t-huge "$OR" "$TMP/prompt.md" 2>&1)" && fail "token ceiling must fail"; assert_contains "$out" "token ceiling exceeded (900000 > 200000)"
out="$(RV or-t-parts "$OR" "$TMP/prompt.md" 2>&1)"; assert_contains "$out" "Four, obviously."
out="$(RV or-t-nousage "$OR" "$TMP/prompt.md" 2>&1)"; assert_contains "$out" '"input_tokens":null,"output_tokens":null'
out="$(RV or-t-parts OPENROUTER_BASE_URL="http://127.0.0.1:1" "$OR" "$TMP/prompt.md" 2>&1)" && fail "unreachable must fail"; assert_contains "$out" "request failed"; assert_not_contains "$out" "$KEY"
out="$(R E3D_OPENROUTER_VOICE=or-glm "$OR" "$TMP/prompt.md" 2>&1)" && fail "unconfigured run must fail"; assert_contains "$out" "not configured"
out="$(R E3D_OPENROUTER_VOICE=or-glm E3D_PILOT_DRY_RUN=1 OPENROUTER_API_KEY="$KEY" "$OR" "$TMP/prompt.md")"; assert_contains "$out" "redacted"; assert_contains "$out" "model=z-ai/glm-5.3-flash"; assert_not_contains "$out" "$KEY" "dry-run must not print the key"

# the engine's transient-failure matcher sees what these errors say, so a 429, 503 or a 502 inside a 200 retries, and a 401 or 402 does not
grep -qE 'HTTP (429|500|502|503|504)\b' <<< "error: or-glm HTTP 502: Provider returned error" || fail "502 retries"
! grep -qE 'HTTP (429|500|502|503|504)\b' <<< "error: or-glm HTTP 402: Insufficient credits (the OpenRouter account is out of credits)" || fail "402 must not retry"

echo "openrouter: ok"
