#!/usr/bin/env bash
set -euo pipefail

# Required providers in hosted mode (E3D_MCP_REQUIRED_PROVIDERS; lib/mcp/panel.js): unit tests, startup refusals, then the real
# server (--http) with the external hook against the reference stub service and a stub debate binary that records its argv.
# Covers: a required provider added back (first) to a client's list, the client's order kept for the rest, required forced first
# on the default, account and web-run panels, an unavailable required provider refused (required_provider_unavailable) with
# nothing reserved and nothing run, a failed summary surfacing as a failed debate (never retried with another provider), and
# stdio ignoring the variable. No model calls, no network beyond loopback.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUB="$ROOT/examples/external-auth-stub.js"
SERVER="$ROOT/bin/e3d-mcp"
TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done; pkill -f "$TMP/stub-debate" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-assert_eq}: expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "${3:-assert_contains}: expected to find [$2] in [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "${3:-assert_not_contains}: did not expect [$2] in [$1]"; }

# ---- unit level ----
node --input-type=module -e "
import assert from 'node:assert/strict';
import { validateRequiredConfig, withRequired, requireAvailable, degrade } from '$ROOT/lib/mcp/panel.js';
const allowed = ['anthropic-api', 'openai-api', 'gemini-api', 'azure-openai'];
const v = (raw, o = {}) => validateRequiredConfig({ E3D_MCP_REQUIRED_PROVIDERS: raw }, { allowed, max: 4, ...o });
assert.deepEqual(validateRequiredConfig({}, { allowed, max: 4 }), { ok: true, errors: [], required: [] });
assert.deepEqual(v('  '), { ok: true, errors: [], required: [] });
assert.deepEqual(v('anthropic-api'), { ok: true, errors: [], required: ['anthropic-api'] });
assert.deepEqual(v(' anthropic-api , openai-api ').required, ['anthropic-api', 'openai-api']);
assert.equal(v('xai-api').errors[0], 'E3D_MCP_REQUIRED_PROVIDERS must be inside E3D_MCP_ALLOWED_PROVIDERS (not allowed: xai-api)');
assert.equal(v('anthropic-api', { allowed: null }).errors[0], 'E3D_MCP_REQUIRED_PROVIDERS needs E3D_MCP_ALLOWED_PROVIDERS');
assert.equal(v('anthropic-api,anthropic-api').errors[0], 'E3D_MCP_REQUIRED_PROVIDERS lists a provider twice');
assert.equal(v('Anthropic API').errors[0], 'E3D_MCP_REQUIRED_PROVIDERS must be a comma-separated list of provider names');
assert.equal(v('anthropic-api,openai-api,gemini-api', { max: 2 }).errors[0], 'E3D_MCP_REQUIRED_PROVIDERS names 3 providers; at most 2 per debate (E3D_MCP_MAX_PROVIDERS)');
assert.deepEqual(v('xai-api').required, []);
assert.deepEqual(withRequired(['gemini-api', 'openai-api'], ['anthropic-api']), ['anthropic-api', 'gemini-api', 'openai-api']);
assert.deepEqual(withRequired(['gemini-api', 'anthropic-api', 'openai-api'], ['anthropic-api']), ['anthropic-api', 'gemini-api', 'openai-api']);
assert.deepEqual(withRequired(['anthropic-api', 'openai-api'], ['anthropic-api']), ['anthropic-api', 'openai-api'], 'idempotent');
assert.deepEqual(withRequired(['gemini-api', 'openai-api'], []), ['gemini-api', 'openai-api'], 'no required: unchanged');
const up = () => true; const noAnth = (p) => p !== 'anthropic-api';
assert.equal(requireAvailable(['anthropic-api'], up), null);
assert.equal(requireAvailable([], noAnth), null);
assert.equal(requireAvailable(['anthropic-api'], noAnth).code, 'required_provider_unavailable');
// degrade without required: unchanged (drops the unavailable lead, the next vendor leads)
assert.deepEqual(degrade(['anthropic-api', 'openai-api', 'gemini-api'], { allowed, isAvailable: noAnth, max: 4 }), { providers: ['openai-api', 'gemini-api'], dropped: ['anthropic-api'] });
// degrade with required: refused, never substituted; forced first otherwise
const d = degrade(['anthropic-api', 'openai-api', 'gemini-api'], { allowed, isAvailable: noAnth, max: 4, required: ['anthropic-api'] });
assert.equal(d.code, 'required_provider_unavailable'); assert.match(d.error, /^error: required_provider_unavailable: anthropic-api is required/);
assert.deepEqual(degrade(['openai-api', 'gemini-api'], { allowed, isAvailable: up, max: 4, required: ['anthropic-api'] }), { providers: ['anthropic-api', 'openai-api', 'gemini-api'], dropped: [] });
console.log('required unit tests: passed');
" | tee "$TMP/unit.out"
assert_contains "$(cat "$TMP/unit.out")" "required unit tests: passed"
echo "ok - unit: config validation, required-first ordering (idempotent), degrade refuses instead of substituting"

# ---- the stub service and a stub debate binary ----
SVC="svc-MARKER-$(openssl rand -hex 12)"
RUNTOK="runtok-MARKER-$(openssl rand -hex 16)"
TOK_A="caller-MARKER-a-$(openssl rand -hex 12)"
jq -n --arg a "$TOK_A" '{accounts: [
  {principal: "acct_a", balance: 1000000, keys: [{id: "key-a", token: $a}]},
  {principal: "acct_web", balance: 1000000, keys: []}]}' > "$TMP/seed.json"
env STUB_SERVICE_TOKEN="$SVC" STUB_SEED="$TMP/seed.json" STUB_URL_FILE="$TMP/stub.url" STUB_FEATURES="finalize,fetch,authorize-run" node "$STUB" > "$TMP/stub.out" 2> "$TMP/stub.log" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$TMP/stub.url" ]] && break; sleep 0.05; done
[[ -s "$TMP/stub.url" ]] || fail "stub did not start: $(cat "$TMP/stub.log")"
URL="$(cat "$TMP/stub.url")"
admin() { curl -fsS -X POST -H "authorization: Bearer $SVC" -H 'content-type: application/json' -d "$2" "$URL/_stub/$1" > /dev/null; }
ledger() { curl -fsS -H "authorization: Bearer $SVC" "$URL/_stub/state"; }
n_res() { ledger | jq '.reservations | length'; }
n_active() { ledger | jq '[.reservations[] | select(.state == "active")] | length'; }
set_panel() { admin panel "$(jq -nc --arg p "$1" --argjson v "$2" '{principal:$p,providers:$v}')"; }

MARK="$(openssl rand -hex 4)"
Q="QCONTENT-$MARK: a JSON file or SQLite?"
DEBATE="$TMP/stub-debate"; ARGS="$TMP/debate.args"; DOWN="$TMP/unavailable"; SYNTHFAIL="$TMP/synthfail"; : > "$ARGS"; : > "$DOWN"
# With $SYNTHFAIL present the stub behaves like bin/e3d-debate when the --synthesizer call fails: the rounds ran, no synthesis,
# no verdict on stdout, "synthesis provider failed" on stderr, exit 0.
cat > "$DEBATE" <<STUBEOF
#!/usr/bin/env bash
out=""; all="\$*"
while [[ \$# -gt 0 ]]; do case "\$1" in --out-dir) out="\$2"; shift 2 ;; *) shift ;; esac; done
echo "\$all" >> "$ARGS"
mkdir -p "\$out"
printf '# Debate\n\n## Round 1 -- p1\n\nTCONTENT-$MARK JSON file.\n\n## Round 1 -- p2\n\nSQLite.\n' > "\$out/transcript.md"
if [[ -e "$SYNTHFAIL" ]]; then echo "error: synthesis provider failed -- see synthesis.stderr" >&2; exit 0; fi
printf 'FINAL ANSWER: ACONTENT-$MARK use a JSON file.\nCONSENSUS: split\nDISSENT: one prefers SQLite.\n'
STUBEOF
chmod +x "$DEBATE"

ALLOWED="anthropic-api,openai-api,gemini-api,azure-openai"
BASE_ENV=(E3D_MCP_AUTH_URL="$URL" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" E3D_MCP_DEBATE_BIN="$DEBATE" E3D_MCP_STUB_UNAVAILABLE_FILE="$DOWN" TYPESAFE_API_KEY=""
  E3D_MCP_PRINCIPAL="" E3D_MCP_AUTH_CACHE_SEC=1 E3D_MCP_TIMEOUT_SEC=20 E3D_MCP_AUTH_HEALTH_SEC=1 E3D_MCP_RATE_PER_MIN=100000 E3D_MCP_RUNS_POLL_PER_MIN=100000
  E3D_MCP_PROVIDERS=openai-api,anthropic-api E3D_MCP_ALLOWED_PROVIDERS="$ALLOWED")

# --- configuration errors refuse to start (hosted) ---
refuse_start() { # message env...
  local want="$1"; shift
  out="$(env "${BASE_ENV[@]}" E3D_MCP_STATE_DIR="$TMP/state-bad" "$@" "$SERVER" --http --port 0 2>&1)" && fail "must refuse to start: $*" || true
  assert_contains "$out" "$want"; assert_not_contains "$out" "$SVC"
}
refuse_start "E3D_MCP_REQUIRED_PROVIDERS must be inside E3D_MCP_ALLOWED_PROVIDERS (not allowed: xai-api)" E3D_MCP_REQUIRED_PROVIDERS=xai-api
refuse_start "E3D_MCP_REQUIRED_PROVIDERS needs E3D_MCP_ALLOWED_PROVIDERS" E3D_MCP_ALLOWED_PROVIDERS= E3D_MCP_REQUIRED_PROVIDERS=anthropic-api
refuse_start "at most 2 per debate (E3D_MCP_MAX_PROVIDERS)" E3D_MCP_MAX_PROVIDERS=2 E3D_MCP_REQUIRED_PROVIDERS=anthropic-api,openai-api,gemini-api
refuse_start "at most 2 per started debate (E3D_MCP_CUSTOMER_LIMITS providers)" E3D_MCP_CUSTOMER_LIMITS=providers=2 E3D_MCP_REQUIRED_PROVIDERS=anthropic-api,openai-api,gemini-api
echo "ok - hosted: a required provider outside the allowlist, without an allowlist, or more than the per-debate maximum refuses to start"

# --- stdio ignores the variable entirely (even a value hosted mode would refuse) ---
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"required-test","version":"0"}}}'
CALL="$(jq -nc --arg q "$Q" '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"e3d_debate",arguments:{question:$q,providers:["openai-api","gemini-api"]}}}')"
out="$(printf '%s\n%s\n' "$INIT" "$CALL" | env E3D_MCP_STATE_DIR="$TMP/state-stdio" E3D_MCP_DEBATE_BIN="$DEBATE" E3D_MCP_STUB_UNAVAILABLE_FILE="$DOWN" \
  E3D_MCP_REQUIRED_PROVIDERS=xai-api,anthropic-api "$SERVER" 2> "$TMP/stdio.log")"
assert_eq "$(jq -r 'select(.id==2) | .result.isError // false' <<< "$out")" "false" "stdio debate: $out $(cat "$TMP/stdio.log")"
assert_eq "$(tail -1 "$ARGS" | tr ' ' '\n' | grep -A1 -- --providers | tail -1)" "openai-api,gemini-api" "stdio: the client's list as given"
assert_eq "$(tail -1 "$ARGS" | tr ' ' '\n' | grep -A1 -- --synthesizer | tail -1)" "openai-api" "stdio: summary writer unchanged"
echo "ok - stdio: E3D_MCP_REQUIRED_PROVIDERS is ignored (no startup check, no reordering)"

start_server() {
  local name="$1"; shift
  : > "$TMP/$name.port"
  env "${BASE_ENV[@]}" E3D_MCP_STATE_DIR="$TMP/state-$name" E3D_MCP_PORT_FILE="$TMP/$name.port" "$@" "$SERVER" --http --port 0 2>> "$TMP/$name.log" &
  local pid=$!; PIDS+=("$pid")
  for _ in $(seq 1 100); do [[ -s "$TMP/$name.port" ]] && break; sleep 0.1; done
  [[ -s "$TMP/$name.port" ]] || { cat "$TMP/$name.log" >&2; fail "server $name did not start"; }
  eval "PORT_$name=$(cat "$TMP/$name.port")"
}
sport() { local v="PORT_$1"; echo "${!v}"; }
http() {
  local name="$1"; shift
  curl -s -m 60 -D "$TMP/headers" -o "$TMP/body" -w '%{http_code}' "$@" "http://127.0.0.1:$(sport "$name")/mcp"; echo; cat "$TMP/body"; echo
}
body() { tail -n +2 <<< "$1"; }
hdr() { grep -i "^$1:" "$TMP/headers" | head -1 | sed -E 's/^[^:]+: *//' | tr -d '\r'; }
J=(-H 'content-type: application/json' -H 'accept: application/json')
sid_of() { http "$1" -X POST "${J[@]}" -H "Authorization: Bearer $2" -d "$INIT" > /dev/null; hdr mcp-session-id; }
rpc() { http "$1" -X POST "${J[@]}" -H "Authorization: Bearer $2" -H "mcp-session-id: $3" -d "$4"; }
tool() { rpc "$1" "$2" "$3" "$(jq -nc --arg n "$4" --argjson a "${5:-{\}}" '{jsonrpc:"2.0",id:7,method:"tools/call",params:{name:$n,arguments:$a}}')"; }
res() { body "$1" | jq -c .result.structuredContent; }
rtext() { body "$1" | jq -r '.result.content[0].text'; }
rerr() { body "$1" | jq -r '.result.isError // false'; }
debate() { tool "$1" "$2" "$3" e3d_debate "$(jq -nc --arg q "$Q" --argjson p "${4:-null}" 'if $p == null then {question:$q} else {question:$q,providers:$p} end')"; }
last_args() { tail -1 "$ARGS"; }
argv_of() { last_args | tr ' ' '\n' | grep -A1 -- "$1" | tail -1; }
outbox_pending() { find "$TMP/state-$1/auth-outbox/pending" -type f 2>/dev/null | wc -l | tr -d ' '; }
REQ=(E3D_MCP_REQUIRED_PROVIDERS=anthropic-api)

# ================================================================ allowlist only (E3D_MCP_PANEL unset)
start_server S0 "${REQ[@]}"
assert_contains "$(cat "$TMP/S0.log")" "required providers: anthropic-api"
S0A="$(sid_of S0 "$TOK_A")"
# default E3D_MCP_PROVIDERS=openai-api,anthropic-api: the required provider is forced first
r="$(debate S0 "$TOK_A" "$S0A")"; assert_eq "$(rerr "$r")" "false" "default: $(rtext "$r")"
assert_eq "$(argv_of --providers)" "anthropic-api,openai-api"; assert_eq "$(argv_of --synthesizer)" "anthropic-api"
# a client list that omits the required provider: added back, first; the rest keep the client's order
r="$(debate S0 "$TOK_A" "$S0A" '["gemini-api","openai-api"]')"; assert_eq "$(rerr "$r")" "false" "$(rtext "$r")"
assert_eq "$(argv_of --providers)" "anthropic-api,gemini-api,openai-api"; assert_eq "$(argv_of --synthesizer)" "anthropic-api"
assert_eq "$(res "$r" | jq -r .synthesizer)" "anthropic-api"
# a client list that names it later: moved first, the rest in the client's order
r="$(debate S0 "$TOK_A" "$S0A" '["openai-api","gemini-api","anthropic-api"]')"
assert_eq "$(argv_of --providers)" "anthropic-api,openai-api,gemini-api"; assert_eq "$(argv_of --synthesizer)" "anthropic-api"
# the existing refusals still apply after the required provider is added back
r="$(debate S0 "$TOK_A" "$S0A" '["openai-api","xai-api"]')"; assert_eq "$(rerr "$r")" "true"; assert_contains "$(rtext "$r")" "not offered on this server: xai-api"
r="$(debate S0 "$TOK_A" "$S0A" '["openai-api","gemini-api","azure-openai","x"]')"; assert_eq "$(rerr "$r")" "true"
# the required provider unavailable: refused with the code, nothing reserved, nothing run (no other vendor summarizes)
echo anthropic-api > "$DOWN"
n0="$(n_res)"; a0="$(wc -l < "$ARGS")"
for p in null '["openai-api","gemini-api"]'; do
  r="$(debate S0 "$TOK_A" "$S0A" "$p")"
  assert_eq "$(rerr "$r")" "true" "required down ($p)"; assert_contains "$(rtext "$r")" "required_provider_unavailable: anthropic-api is required"
done
assert_eq "$(n_res)" "$n0" "nothing reserved"; assert_eq "$(wc -l < "$ARGS")" "$a0" "nothing ran"; assert_eq "$(outbox_pending S0)" "0"
: > "$DOWN"
echo "ok - allowlist only: required added back first (client order kept for the rest), forced first on the default, unavailable refused with nothing reserved or run"

# ================================================================ per-account panels (E3D_MCP_PANEL=1) and the run listener
start_server S1 "${REQ[@]}" E3D_MCP_PANEL=1 E3D_MCP_RUN_PORT=0 E3D_MCP_RUN_PORT_FILE="$TMP/S1.runport" E3D_MCP_RUN_TOKEN="$RUNTOK"
SA="$(sid_of S1 "$TOK_A")"
# billing's default (anthropic-api first): idempotent
r="$(debate S1 "$TOK_A" "$SA")"; assert_eq "$(rerr "$r")" "false" "$(rtext "$r")"
assert_eq "$(argv_of --providers)" "anthropic-api,openai-api"; assert_eq "$(argv_of --synthesizer)" "anthropic-api"
assert_eq "$(res "$r" | jq -c '.panel | [.source, .used, .synthesizer, .required]')" '["default",["anthropic-api","openai-api"],"anthropic-api",["anthropic-api"]]'
# an account panel that leads with another vendor, or lacks the required one: forced first (defensive)
set_panel acct_a '[{"id":"openai-api","family":"openai"},{"id":"anthropic-api","family":"anthropic"},{"id":"gemini-api","family":"google"}]'
r="$(debate S1 "$TOK_A" "$SA")"; assert_eq "$(argv_of --providers)" "anthropic-api,openai-api,gemini-api"; assert_eq "$(argv_of --synthesizer)" "anthropic-api"
set_panel acct_a '[{"id":"openai-api","family":"openai"},{"id":"gemini-api","family":"google"}]'
r="$(debate S1 "$TOK_A" "$SA")"; assert_eq "$(rerr "$r")" "false"
assert_eq "$(argv_of --providers)" "anthropic-api,openai-api,gemini-api"; assert_eq "$(argv_of --synthesizer)" "anthropic-api"
# a client list narrows only the optional providers
r="$(debate S1 "$TOK_A" "$SA" '["gemini-api"]')"; assert_eq "$(rerr "$r")" "false" "$(rtext "$r")"
assert_eq "$(argv_of --providers)" "anthropic-api,gemini-api"; assert_eq "$(argv_of --synthesizer)" "anthropic-api"
assert_eq "$(res "$r" | jq -c '.panel | [.source, .requested, .used, .synthesizer]')" '["explicit",["gemini-api"],["anthropic-api","gemini-api"],"anthropic-api"]'
r="$(debate S1 "$TOK_A" "$SA" '["gemini-api","openai-api"]')"; assert_eq "$(argv_of --providers)" "anthropic-api,gemini-api,openai-api"
r="$(debate S1 "$TOK_A" "$SA" '["openai-api","xai-api"]')"; assert_eq "$(rerr "$r")" "true"; assert_contains "$(rtext "$r")" "not offered on this server: xai-api"
set_panel acct_a null
# the required provider unavailable: degrade refuses instead of handing the summary on; explicit too; nothing reserved or run
echo anthropic-api > "$DOWN"
n0="$(n_res)"; a0="$(wc -l < "$ARGS")"
for p in null '["openai-api","gemini-api"]' '["anthropic-api","openai-api"]'; do
  r="$(debate S1 "$TOK_A" "$SA" "$p")"
  assert_eq "$(rerr "$r")" "true" "required down ($p)"; assert_contains "$(rtext "$r")" "required_provider_unavailable: anthropic-api is required"
done
r="$(tool S1 "$TOK_A" "$SA" e3d_debate_start "$(jq -nc --arg q "$Q" '{question:$q}')")"; assert_eq "$(rerr "$r")" "true"; assert_contains "$(rtext "$r")" "required_provider_unavailable"
assert_eq "$(n_res)" "$n0" "nothing reserved"; assert_eq "$(wc -l < "$ARGS")" "$a0" "nothing ran"; assert_eq "$(outbox_pending S1)" "0"
echo "ok - panel: required forced first on the default and account panels, client lists narrow only the optional providers, unavailable refused before reserve"

# web runs: billing's stored list, required forced first; unavailable refused (400) before planning anything
RPORT="$(cat "$TMP/S1.runport")"; RUN="http://127.0.0.1:$RPORT/internal/runs"
web_reserve() {
  curl -fsS -X POST -H "authorization: Bearer $SVC" -H 'content-type: application/json' -H 'x-e3d-auth-version: 1' \
    -d "$(jq -nc --arg r "$(uuidgen | tr 'A-Z' 'a-z')" '{principal:"acct_web",request_id:$r,kind:"debate",tool:"web",units:{calls:3,est_tokens:3000}}')" "$URL/reserve" | jq -r .reservation_id
}
web_debate() { admin web-debate "$(jq -nc --arg r "$1" --arg d "$2" --arg q "$Q" '{reservation_id:$r,debate_id:$d,question:$q}')"; }
post_run() { curl -s -o "$TMP/run.body" -w '%{http_code}' -X POST -H "authorization: Bearer $RUNTOK" -H 'content-type: application/json' -d "$1" "$RUN"; }
new_id() { echo "dbt_$(openssl rand -hex 12)"; }
a0="$(wc -l < "$ARGS")"
R1="$(web_reserve)"; D1="$(new_id)"; web_debate "$R1" "$D1"
assert_eq "$(post_run "$(jq -nc --arg r "$R1" --arg d "$D1" --arg q "$Q" '{reservation_id:$r,debate_id:$d,question:$q,providers:["openai-api","anthropic-api"]}')")" "400" "required down: $(cat "$TMP/run.body")"
assert_contains "$(jq -r .message "$TMP/run.body")" "required_provider_unavailable"
: > "$DOWN"
R2="$(web_reserve)"; D2="$(new_id)"; web_debate "$R2" "$D2"
assert_eq "$(post_run "$(jq -nc --arg r "$R2" --arg d "$D2" --arg q "$Q" '{reservation_id:$r,debate_id:$d,question:$q,providers:["openai-api","gemini-api"]}')")" "202" "$(cat "$TMP/run.body")"
for _ in $(seq 1 100); do [[ "$(wc -l < "$ARGS")" -gt "$a0" ]] && break; sleep 0.1; done
assert_eq "$(argv_of --providers)" "anthropic-api,openai-api,gemini-api" "a web run's list gets the required provider first"; assert_eq "$(argv_of --synthesizer)" "anthropic-api"
echo "ok - run listener: required forced first on billing's stored list; unavailable refused with 400 required_provider_unavailable"

# ================================================================ mid-debate failure of the summary writer
# bin/e3d-debate calls only --synthesizer for the summary; a failed call leaves no verdict. e3d-mcp must report a failed
# debate and never run it again with another summary writer.
sleep 1
touch "$SYNTHFAIL"
a0="$(wc -l < "$ARGS")"
r="$(debate S0 "$TOK_A" "$S0A" '["openai-api","gemini-api"]')"
assert_eq "$(rerr "$r")" "true" "a failed summary is a failed debate"; assert_contains "$(rtext "$r")" "debate failed"
assert_eq "$(($(wc -l < "$ARGS")))" "$((a0 + 1))" "the debate ran once; no retry with another summary writer"
assert_eq "$(argv_of --synthesizer)" "anthropic-api"
for _ in $(seq 1 50); do [[ "$(n_active)" == "0" ]] && break; sleep 0.1; done
assert_eq "$(n_active)" "0" "the reservation was settled, not left open"
rm -f "$SYNTHFAIL"
echo "ok - a failed summary by the required provider is a failed debate (settled once), never retried with another provider"

# bin/e3d-debate itself: a failing --synthesizer is not replaced by another provider
D="$TMP/debate-copy"; mkdir -p "$D/bin" "$D/lib/providers"
cp "$ROOT/bin/e3d-debate" "$D/bin/"; cp "$ROOT/lib/providers/jev.sh" "$ROOT/lib/providers/common.sh" "$D/lib/providers/"
for p in lead other; do
  cat > "$D/lib/providers/$p" <<STUB
#!/usr/bin/env bash
echo "\$(basename "\$1")" >> "$D/calls-$p"
case "\$1" in *synthesis*) [[ "$p" == lead ]] && { echo "lead down" >&2; exit 1; } ;; esac
printf 'Answer from $p.\nPOSITION: p-$p\nstatus: revise\n'
STUB
  chmod +x "$D/lib/providers/$p"
done
out="$(TYPESAFE_API_KEY="" E3D_DEBATE_DECISION_LOG="" "$D/bin/e3d-debate" "Which?" --providers lead,other --rounds 1 --synthesizer lead --out-dir "$D/out" 2> "$D/err")" || true
assert_not_contains "$out" "FINAL ANSWER" "no verdict without the synthesizer"
assert_contains "$(cat "$D/err")" "synthesis provider failed"
assert_eq "$(grep -c synthesis "$D/calls-lead")" "1" "the synthesizer was asked once"
assert_eq "$(grep -c synthesis "$D/calls-other" || true)" "0" "no other provider wrote the summary"
echo "ok - e3d-debate: a failing --synthesizer yields no verdict and no substitute summary writer"

# no question, answer, transcript or token in the server logs
for f in "$TMP/S0.log" "$TMP/S1.log"; do
  for secret in "$SVC" "$RUNTOK" "$TOK_A" "QCONTENT-$MARK" "ACONTENT-$MARK" "TCONTENT-$MARK"; do assert_not_contains "$(cat "$f")" "$secret" "$(basename "$f") leaks"; done
done
echo "ok - no question, answer, transcript or token in the server logs"
echo "mcp-required: all passed"
