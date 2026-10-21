#!/usr/bin/env bash
set -euo pipefail

# Per-account model panels in hosted mode (lib/mcp/panel.js; pilot.e3d.ai docs/panel-config-spec.md 4.3): unit tests, then the
# real server (--http) with the external hook against the reference stub service (which also answers POST /panel/v1/resolve),
# with a stub debate binary that records its argv. Covers the hosted allowlist with the panel flag off and on, the resolve
# call before every hosted debate (no cache), refusals with nothing reserved, explicit lists as subsets only, degrade, the
# family checks, the summary writer, and the run listener answering an existing run before planning. No model calls.
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
node "$ROOT/tests/fixtures/panel-unit.mjs" | tee "$TMP/unit.out"
assert_contains "$(cat "$TMP/unit.out")" "panel unit tests:"

# ---- the real server against the stub ----
SVC="svc-MARKER-$(openssl rand -hex 12)"
RUNTOK="runtok-MARKER-$(openssl rand -hex 16)"
TOK_A="caller-MARKER-a-$(openssl rand -hex 12)"; TOK_B="caller-MARKER-b-$(openssl rand -hex 12)"
jq -n --arg a "$TOK_A" --arg b "$TOK_B" '{accounts: [
  {principal: "acct_a", balance: 1000000, keys: [{id: "key-a", token: $a}]},
  {principal: "acct_b", balance: 1000000, keys: [{id: "key-b", token: $b}]},
  {principal: "acct_web", balance: 1000000, keys: []}]}' > "$TMP/seed.json"
env STUB_SERVICE_TOKEN="$SVC" STUB_SEED="$TMP/seed.json" STUB_URL_FILE="$TMP/stub.url" STUB_FEATURES="finalize,fetch,authorize-run" node "$STUB" > "$TMP/stub.out" 2> "$TMP/stub.log" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$TMP/stub.url" ]] && break; sleep 0.05; done
[[ -s "$TMP/stub.url" ]] || fail "stub did not start: $(cat "$TMP/stub.log")"
URL="$(cat "$TMP/stub.url")"
admin() { curl -fsS -X POST -H "authorization: Bearer $SVC" -H 'content-type: application/json' -d "$2" "$URL/_stub/$1" > /dev/null; }
ledger() { curl -fsS -H "authorization: Bearer $SVC" "$URL/_stub/state"; }
n_res() { ledger | jq '.reservations | length'; }
n_panel() { ledger | jq '.received.panel // 0'; }
set_panel() { admin panel "$(jq -nc --arg p "$1" --argjson v "$2" '{principal:$p,providers:$v}')"; }
panel_mode() { admin panel-mode "{\"mode\":$1}"; }

MARK="$(openssl rand -hex 4)"
Q="QCONTENT-$MARK: a JSON file or SQLite?"
DEBATE="$TMP/stub-debate"; ARGS="$TMP/debate.args"; DOWN="$TMP/unavailable"; : > "$ARGS"; : > "$DOWN"
cat > "$DEBATE" <<STUBEOF
#!/usr/bin/env bash
out=""; all="\$*"
while [[ \$# -gt 0 ]]; do case "\$1" in --out-dir) out="\$2"; shift 2 ;; *) shift ;; esac; done
echo "\$all" >> "$ARGS"
mkdir -p "\$out"
printf '# Debate\n\n## Round 1 -- p1\n\nTCONTENT-$MARK JSON file.\n\n## Round 1 -- p2\n\nSQLite.\n' > "\$out/transcript.md"
printf 'FINAL ANSWER: ACONTENT-$MARK use a JSON file.\nCONSENSUS: split\nDISSENT: one prefers SQLite.\n'
STUBEOF
chmod +x "$DEBATE"

ALLOWED="anthropic-api,openai-api,gemini-api,azure-openai"
BASE_ENV=(E3D_MCP_AUTH_URL="$URL" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" E3D_MCP_DEBATE_BIN="$DEBATE" E3D_MCP_STUB_UNAVAILABLE_FILE="$DOWN" TYPESAFE_API_KEY=""
  E3D_MCP_PRINCIPAL="" E3D_MCP_AUTH_CACHE_SEC=1 E3D_MCP_TIMEOUT_SEC=20 E3D_MCP_AUTH_HEALTH_SEC=1 E3D_MCP_RATE_PER_MIN=100000 E3D_MCP_RUNS_POLL_PER_MIN=100000
  E3D_MCP_PROVIDERS=anthropic-api,openai-api E3D_MCP_ALLOWED_PROVIDERS="$ALLOWED")

# --- configuration errors refuse to start ---
out="$(env "${BASE_ENV[@]}" E3D_MCP_STATE_DIR="$TMP/state-bad" E3D_MCP_ALLOWED_PROVIDERS=anthropic-api,mystery-api "$SERVER" --http --port 0 2>&1)" && fail "an allowlisted provider without a family must refuse to start" || true
assert_contains "$out" "no vendor family: mystery-api"
out="$(env "${BASE_ENV[@]}" E3D_MCP_STATE_DIR="$TMP/state-bad" E3D_MCP_ALLOWED_PROVIDERS=openai-api,gemini-api "$SERVER" --http --port 0 2>&1)" && fail "a default outside the allowlist must refuse to start" || true
assert_contains "$out" "E3D_MCP_PROVIDERS must be inside E3D_MCP_ALLOWED_PROVIDERS"
out="$(env "${BASE_ENV[@]}" E3D_MCP_STATE_DIR="$TMP/state-bad" E3D_MCP_ALLOWED_PROVIDERS= E3D_MCP_PANEL=1 "$SERVER" --http --port 0 2>&1)" && fail "the panel needs the allowlist" || true
assert_contains "$out" "E3D_MCP_PANEL=1 needs E3D_MCP_ALLOWED_PROVIDERS"
out="$(env E3D_MCP_STATE_DIR="$TMP/state-bad" E3D_MCP_ALLOWED_PROVIDERS=anthropic-api,openai-api E3D_MCP_PANEL=1 "$SERVER" 2>&1 < /dev/null)" && fail "stdio must refuse the panel" || true
assert_contains "$out" "E3D_MCP_PANEL=1 needs the external auth hook"
assert_not_contains "$out$(cat "$TMP"/*.log 2>/dev/null || true)" "$SVC"
echo "ok - bad panel settings refuse to start (unknown family, default outside the allowlist, panel without allowlist or hook)"

start_server() {
  local name="$1"; shift
  : > "$TMP/$name.port"; : > "$TMP/$name.runport"
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
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"panel-test","version":"0"}}}'
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

# ================================================================ allowlist only (E3D_MCP_PANEL unset)
start_server S0
S0A="$(sid_of S0 "$TOK_A")"
r="$(debate S0 "$TOK_A" "$S0A")"
assert_eq "$(rerr "$r")" "false" "default debate: $(rtext "$r")"
assert_eq "$(argv_of --providers)" "anthropic-api,openai-api"; assert_eq "$(argv_of --synthesizer)" "anthropic-api" "the summary writer is the first provider, passed explicitly"
# provider spy: a panel without Anthropic never reaches claude, in any round or the synthesis (the stub counts claude as available)
r="$(debate S0 "$TOK_A" "$S0A" '["openai-api","gemini-api"]')"
assert_eq "$(rerr "$r")" "false"; assert_eq "$(argv_of --providers)" "openai-api,gemini-api"; assert_eq "$(argv_of --synthesizer)" "openai-api"
assert_not_contains "$(last_args)" "claude" "no non-panel adapter in the argv"; assert_not_contains "$(last_args)" "anthropic" "no non-panel adapter in the argv"
assert_eq "$(res "$r" | jq -r .synthesizer)" "openai-api"
n0="$(n_res)"; a0="$(wc -l < "$ARGS")"
for bad in '["anthropic-api","xai-api"]' '["anthropic-api","claude"]' '["anthropic-api","mcp-sampling"]'; do
  r="$(debate S0 "$TOK_A" "$S0A" "$bad")"
  assert_eq "$(rerr "$r")" "true" "$bad is refused"; assert_contains "$(rtext "$r")" "not offered on this server"
done
assert_eq "$(n_res)" "$n0" "nothing reserved for a refused list"; assert_eq "$(wc -l < "$ARGS")" "$a0" "nothing ran"
assert_eq "$(n_panel)" "0" "without E3D_MCP_PANEL billing is never asked"
r="$(tool S0 "$TOK_A" "$S0A" e3d_list_providers)"; assert_not_contains "$(rtext "$r")" "mcp-sampling"
echo "ok - allowlist only: every list is held to E3D_MCP_ALLOWED_PROVIDERS (sampling included); the summary writer is the first provider, always explicit"

# ================================================================ per-account panels (E3D_MCP_PANEL=1)
start_server S1 E3D_MCP_PANEL=1 E3D_MCP_RUN_PORT=0 E3D_MCP_RUN_PORT_FILE="$TMP/S1.runport" E3D_MCP_RUN_TOKEN="$RUNTOK"
SA="$(sid_of S1 "$TOK_A")"; SB="$(sid_of S1 "$TOK_B")"
# no preference: the default list billing answers, asked again for every debate
p0="$(n_panel)"
r="$(debate S1 "$TOK_A" "$SA")"; assert_eq "$(rerr "$r")" "false" "$(rtext "$r")"
assert_eq "$(argv_of --providers)" "anthropic-api,openai-api"
assert_eq "$(res "$r" | jq -c '.panel | [.source, .used, .dropped, .synthesizer]')" '["default",["anthropic-api","openai-api"],[],"anthropic-api"]'
r="$(debate S1 "$TOK_A" "$SA")"; assert_eq "$(n_panel)" "$((p0 + 2))" "one resolve per debate, no positive cache"
# a change in Settings is used by the very next debate
set_panel acct_a '[{"id":"openai-api","family":"openai"},{"id":"gemini-api","family":"google"}]'
r="$(debate S1 "$TOK_A" "$SA")"; assert_eq "$(rerr "$r")" "false"
assert_eq "$(argv_of --providers)" "openai-api,gemini-api"; assert_eq "$(argv_of --synthesizer)" "openai-api"; assert_not_contains "$(last_args)" "anthropic"
assert_eq "$(res "$r" | jq -c '.panel | [.source, .families, .synthesizer]')" '["account",["openai","google"],"openai-api"]'
# another account is untouched
r="$(debate S1 "$TOK_B" "$SB")"; assert_eq "$(argv_of --providers)" "anthropic-api,openai-api" "account B keeps the default"
echo "ok - panel: billing is asked before every hosted debate (no cache); a removal is used by the next debate; accounts are separate"

# explicit lists: a subset is used as given; adding a vendor is refused before anything is reserved
r="$(debate S1 "$TOK_A" "$SA" '["gemini-api","openai-api"]')"; assert_eq "$(rerr "$r")" "false"
assert_eq "$(argv_of --providers)" "gemini-api,openai-api"; assert_eq "$(argv_of --synthesizer)" "gemini-api"
n0="$(n_res)"; a0="$(wc -l < "$ARGS")"
r="$(debate S1 "$TOK_A" "$SA" '["openai-api","anthropic-api"]')"
assert_eq "$(rerr "$r")" "true"; assert_contains "$(rtext "$r")" "not on your account's debate panel: anthropic-api"
r="$(debate S1 "$TOK_A" "$SA" '["openai-api","xai-api"]')"; assert_contains "$(rtext "$r")" "not offered on this server: xai-api"
r="$(debate S1 "$TOK_A" "$SA" '["openai-api","mcp-sampling"]')"; assert_eq "$(rerr "$r")" "true" "sampling is refused in hosted mode"
assert_eq "$(n_res)" "$n0"; assert_eq "$(wc -l < "$ARGS")" "$a0"
echo "ok - panel: an explicit list may only narrow the account panel; one that adds a vendor is refused with nothing reserved"

# degrade keeps the order and reports what was dropped; one family left is refused
set_panel acct_a '[{"id":"anthropic-api","family":"anthropic"},{"id":"openai-api","family":"openai"},{"id":"gemini-api","family":"google"}]'
echo openai-api > "$DOWN"
r="$(debate S1 "$TOK_A" "$SA")"; assert_eq "$(rerr "$r")" "false" "$(rtext "$r")"
assert_eq "$(argv_of --providers)" "anthropic-api,gemini-api"
assert_eq "$(res "$r" | jq -c '.panel | [.requested, .used, .dropped]')" '[["anthropic-api","openai-api","gemini-api"],["anthropic-api","gemini-api"],["openai-api"]]'
assert_contains "$(rtext "$r")" "Not available for this debate, so not asked: openai-api"
# an explicit list is strict: an unavailable vendor in it is refused
r="$(debate S1 "$TOK_A" "$SA" '["anthropic-api","openai-api"]')"; assert_eq "$(rerr "$r")" "true"; assert_contains "$(rtext "$r")" "not available here: openai-api"
set_panel acct_a '[{"id":"openai-api","family":"openai"},{"id":"azure-openai","family":"openai"},{"id":"anthropic-api","family":"anthropic"}]'
echo anthropic-api > "$DOWN"
n0="$(n_res)"; a0="$(wc -l < "$ARGS")"
r="$(debate S1 "$TOK_A" "$SA")"; assert_eq "$(rerr "$r")" "true"; assert_contains "$(rtext "$r")" "panel_unavailable: your panel needs at least two available vendors from different companies; anthropic-api is unavailable"
# a stored vendor this server does not offer is dropped, never replaced
set_panel acct_a '[{"id":"xai-api","family":"xai"},{"id":"openai-api","family":"openai"}]'; : > "$DOWN"
r="$(debate S1 "$TOK_A" "$SA")"; assert_eq "$(rerr "$r")" "true" "one vendor left after dropping a non-allowed one"; assert_contains "$(rtext "$r")" "xai-api is unavailable"
assert_eq "$(n_res)" "$n0"; assert_eq "$(wc -l < "$ARGS")" "$a0"
echo "ok - panel: degrade keeps the order and reports dropped vendors; one vendor or one family left is refused with nothing reserved"

# billing and e3d-mcp disagree on a family: refused, an operator alert, nothing reserved
set_panel acct_a '[{"id":"anthropic-api","family":"anthropic"},{"id":"gemini-api","family":"xai"}]'
r="$(debate S1 "$TOK_A" "$SA")"; assert_eq "$(rerr "$r")" "true"; assert_contains "$(rtext "$r")" "panel_config_mismatch"
assert_contains "$(cat "$TMP/S1.log")" "ALERT panel: billing and e3d-mcp disagree on vendor families (gemini-api: billing xai, here google)"
assert_eq "$(n_res)" "$n0"
set_panel acct_a null
echo "ok - panel: a family disagreement between billing and e3d-mcp refuses the debate (panel_config_mismatch) and alerts"

# any resolve failure refuses with nothing reserved and nothing queued for settlement; never a fallback
for mode in '"404"' '"5xx"' '"garbled"' '"redirect"' '"slow"'; do
  panel_mode "$mode"
  r="$(debate S1 "$TOK_A" "$SA")"
  assert_eq "$(rerr "$r")" "true" "resolve $mode"; assert_contains "$(rtext "$r")" "temporarily unavailable; retry"
  assert_eq "$(n_res)" "$n0" "resolve $mode: no reserve call"; assert_eq "$(outbox_pending S1)" "0" "resolve $mode: outbox empty"
done
assert_eq "$(wc -l < "$ARGS")" "$a0" "nothing ran for the refusals"
panel_mode null
p1="$(n_panel)"
r="$(tool S1 "$TOK_A" "$SA" e3d_debate_start "$(jq -nc --arg q "$Q" '{question:$q}')")"; assert_eq "$(rerr "$r")" "false" "async start: $(rtext "$r")"
assert_eq "$(n_panel)" "$((p1 + 1))" "async start asks billing too"
echo "ok - panel: 404, 5xx, garbled, redirect and timeout from the resolve endpoint refuse the debate before anything is reserved"

r="$(tool S1 "$TOK_A" "$SA" e3d_list_providers)"; assert_contains "$(rtext "$r")" "Your account's panel: anthropic-api, openai-api (the default"
echo "ok - e3d_list_providers names the account's panel"

# ================================================================ the run listener (web runs; billing sends the stored panel)
RPORT="$(cat "$TMP/S1.runport")"; RUN="http://127.0.0.1:$RPORT/internal/runs"
web_reserve() {
  curl -fsS -X POST -H "authorization: Bearer $SVC" -H 'content-type: application/json' -H 'x-e3d-auth-version: 1' \
    -d "$(jq -nc --arg r "$(uuidgen | tr 'A-Z' 'a-z')" '{principal:"acct_web",request_id:$r,kind:"debate",tool:"web",units:{calls:3,est_tokens:3000}}')" "$URL/reserve" | jq -r .reservation_id
}
web_debate() { admin web-debate "$(jq -nc --arg r "$1" --arg d "$2" --arg q "$Q" '{reservation_id:$r,debate_id:$d,question:$q}')"; }
post_run() { curl -s -o "$TMP/run.body" -w '%{http_code}' -X POST -H "authorization: Bearer $RUNTOK" -H 'content-type: application/json' -d "$1" "$RUN"; }
new_id() { echo "dbt_$(openssl rand -hex 12)"; }
R1="$(web_reserve)"; D1="$(new_id)"; web_debate "$R1" "$D1"
RB="$(jq -nc --arg r "$R1" --arg d "$D1" --arg q "$Q" '{reservation_id:$r,debate_id:$d,question:$q,providers:["anthropic-api","openai-api"]}')"
p0="$(n_panel)"
assert_eq "$(post_run "$RB")" "202" "accepted: $(cat "$TMP/run.body")"
TOKEN1="$(jq -r .run_token "$TMP/run.body")"
echo openai-api > "$DOWN"
assert_eq "$(post_run "$RB")" "200" "an identical retry after a vendor went down is existing, not 400: $(cat "$TMP/run.body")"
assert_eq "$(jq -r '[.existing, .run_token] | join(",")' "$TMP/run.body")" "true,$TOKEN1"
R2="$(web_reserve)"; D2="$(new_id)"; web_debate "$R2" "$D2"
assert_eq "$(post_run "$(jq -nc --arg r "$R2" --arg d "$D2" --arg q "$Q" '{reservation_id:$r,debate_id:$d,question:$q,providers:["anthropic-api","openai-api"]}')")" "400" "a new run with one vendor left is refused"
assert_contains "$(jq -r .message "$TMP/run.body")" "panel_unavailable"
R3="$(web_reserve)"; D3="$(new_id)"; web_debate "$R3" "$D3"
: > "$ARGS"
assert_eq "$(post_run "$(jq -nc --arg r "$R3" --arg d "$D3" --arg q "$Q" '{reservation_id:$r,debate_id:$d,question:$q,providers:["openai-api","anthropic-api","gemini-api"]}')")" "202"
for _ in $(seq 1 100); do [[ -s "$ARGS" ]] && grep -q -- "--providers anthropic-api,gemini-api" "$ARGS" && break; sleep 0.1; done
assert_contains "$(cat "$ARGS")" "--providers anthropic-api,gemini-api" "a web panel degrades in order"; assert_contains "$(cat "$ARGS")" "--synthesizer anthropic-api"
assert_eq "$(n_panel)" "$p0" "a web run uses billing's stored list; no resolve"
: > "$DOWN"
echo "ok - run listener: an identical retry is answered existing before planning; a new run is planned (degrade, refuse) with the stored list"

# no question, answer, transcript, token or principal in the logs
for f in "$TMP/S0.log" "$TMP/S1.log"; do
  for secret in "$SVC" "$RUNTOK" "$TOK_A" "QCONTENT-$MARK" "ACONTENT-$MARK" "TCONTENT-$MARK"; do assert_not_contains "$(cat "$f")" "$secret" "$(basename "$f") leaks"; done
done
echo "ok - no question, answer, transcript or token in the server logs"
echo "mcp-panel: all passed"
