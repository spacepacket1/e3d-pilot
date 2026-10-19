#!/usr/bin/env bash
set -euo pipefail

# The internal run listener (lib/mcp/run-server.js): unit tests over loopback HTTP, then the real server (--http) with the
# external hook and the run listener against the reference stub service, with a stub debate binary. No model calls.
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
node "$ROOT/tests/fixtures/runserver-test.mjs" "$TMP/unit" | tee "$TMP/unit.out"
assert_contains "$(cat "$TMP/unit.out")" "run-server unit tests:"

# ---- the real server against the stub ----
SVC="svc-MARKER-$(openssl rand -hex 12)"
RUNTOK="runtok-MARKER-$(openssl rand -hex 16)"
TOK_A="caller-MARKER-a-$(openssl rand -hex 12)"
jq -n --arg a "$TOK_A" '{accounts: [{principal: "acct_web", balance: 1000000, keys: [{id: "key-a", token: $a}]}]}' > "$TMP/seed.json"
env STUB_SERVICE_TOKEN="$SVC" STUB_SEED="$TMP/seed.json" STUB_URL_FILE="$TMP/stub.url" STUB_FEATURES="finalize,fetch,authorize-run" node "$STUB" > "$TMP/stub.out" 2> "$TMP/stub.log" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$TMP/stub.url" ]] && break; sleep 0.05; done
[[ -s "$TMP/stub.url" ]] || fail "stub did not start: $(cat "$TMP/stub.log")"
URL="$(cat "$TMP/stub.url")"
ledger() { curl -fsS -H "authorization: Bearer $SVC" "$URL/_stub/state"; }
# the web page's side: a reservation, then the debate record, made at the service before the run is requested
web_reserve() {
  curl -fsS -X POST -H "authorization: Bearer $SVC" -H 'content-type: application/json' -H 'x-e3d-auth-version: 1' \
    -d "$(jq -nc --arg r "$(uuidgen | tr 'A-Z' 'a-z')" '{principal:"acct_web",request_id:$r,kind:"debate",tool:"web",units:{calls:3,est_tokens:3000}}')" "$URL/reserve" | jq -r .reservation_id
}
web_debate() { curl -fsS -X POST -H "authorization: Bearer $SVC" -H 'content-type: application/json' -d "$(jq -nc --arg r "$1" --arg d "$2" --arg q "$Q" '{reservation_id:$r,debate_id:$d,question:$q}')" "$URL/_stub/web-debate" > /dev/null; }
new_id() { echo "dbt_$(openssl rand -hex 12)"; }

MARK="$(openssl rand -hex 4)"
Q="QCONTENT-$MARK: a JSON file or SQLite?"
DEBATE="$TMP/stub-debate"; MODE="$TMP/debate.mode"; ARGS="$TMP/debate.args"; STARTED="$TMP/debate.started"; echo ok > "$MODE"; : > "$ARGS"
cat > "$DEBATE" <<STUBEOF
#!/usr/bin/env bash
out=""; all="\$*"
while [[ \$# -gt 0 ]]; do case "\$1" in --out-dir) out="\$2"; shift 2 ;; *) shift ;; esac; done
echo "\$all" >> "$ARGS"
mode="\$(cat "$MODE")"
mkdir -p "\$out"
printf '# Debate\n\n## Round 1 -- claude\n\nTCONTENT-$MARK JSON file.\n\n## Round 1 -- codex\n\nSQLite.\n' > "\$out/transcript.md"
case "\$mode" in
  hang) touch "$STARTED"; exec sleep 20 ;;
esac
printf 'FINAL ANSWER: ACONTENT-$MARK use a JSON file.\nCONSENSUS: split\nDISSENT: Codex prefers SQLite.\n'
STUBEOF
chmod +x "$DEBATE"

BASE_ENV=(E3D_MCP_AUTH_URL="$URL" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" E3D_MCP_DEBATE_BIN="$DEBATE" TYPESAFE_API_KEY="" E3D_MCP_PRINCIPAL=""
  E3D_MCP_AUTH_CACHE_SEC=1 E3D_MCP_TIMEOUT_SEC=20 E3D_MCP_AUTH_HEALTH_SEC=1 E3D_MCP_RATE_PER_MIN=100000)

# --- configuration errors refuse to start, without echoing the token ---
SHORT="short-MARKER-token"
out="$(env "${BASE_ENV[@]}" E3D_MCP_STATE_DIR="$TMP/state-bad" E3D_MCP_RUN_PORT=0 E3D_MCP_RUN_TOKEN="$SHORT" "$SERVER" --http --port 0 2>&1)" && fail "a short run token must refuse to start" || true
assert_contains "$out" "E3D_MCP_RUN_TOKEN"; assert_not_contains "$out" "$SHORT"
out="$(env E3D_MCP_STATE_DIR="$TMP/state-bad" E3D_MCP_RUN_PORT=0 E3D_MCP_RUN_TOKEN="$RUNTOK" "$SERVER" --http --port 0 2>&1)" && fail "the run listener needs the hook" || true
assert_contains "$out" "E3D_MCP_AUTH_URL"
out="$(env E3D_MCP_STATE_DIR="$TMP/state-bad" E3D_MCP_RUN_PORT=0 E3D_MCP_RUN_TOKEN="$RUNTOK" "$SERVER" 2>&1 < /dev/null)" && fail "stdio must refuse the run listener" || true
assert_contains "$out" "only supported in hosted mode"
echo "ok - a short run token, a missing hook, or stdio refuse to start"

: > "$TMP/S.port"; : > "$TMP/S.runport"
env "${BASE_ENV[@]}" E3D_MCP_STATE_DIR="$TMP/state-S" E3D_MCP_PORT_FILE="$TMP/S.port" E3D_MCP_RUN_PORT=0 E3D_MCP_RUN_PORT_FILE="$TMP/S.runport" E3D_MCP_RUN_TOKEN="$RUNTOK" \
  "$SERVER" --http --port 0 2>> "$TMP/S.log" &
PID_S=$!; PIDS+=("$PID_S")
for _ in $(seq 1 100); do [[ -s "$TMP/S.runport" ]] && break; sleep 0.1; done
[[ -s "$TMP/S.runport" ]] || { cat "$TMP/S.log" >&2; fail "server did not start"; }
PORT="$(cat "$TMP/S.port")"; RPORT="$(cat "$TMP/S.runport")"
RUN="http://127.0.0.1:$RPORT/internal/runs"

# --- loopback only, and a separate listener ---
assert_contains "$(cat "$TMP/S.log")" "run-server: listening on 127.0.0.1:$RPORT"
if command -v lsof > /dev/null; then
  l="$(lsof -nP -a -p "$PID_S" -iTCP:"$RPORT" -sTCP:LISTEN 2>/dev/null | tail -n +2)"
  assert_contains "$l" "127.0.0.1:$RPORT"; assert_not_contains "$l" "*:$RPORT"
fi
for m in GET POST DELETE; do
  c="$(curl -s -o /dev/null -w '%{http_code}' -X "$m" -H "authorization: Bearer $RUNTOK" -H 'content-type: application/json' -d '{}' "http://127.0.0.1:$PORT/internal/runs")"
  assert_eq "$c" "404" "the public listener never serves $m /internal/runs"
  c="$(curl -s -o /dev/null -w '%{http_code}' -X "$m" -H "authorization: Bearer $RUNTOK" "http://127.0.0.1:$PORT/internal/runs/$(new_id)")"; assert_eq "$c" "404"
done
echo "ok - the run listener binds to 127.0.0.1 only; the public listener never serves /internal paths"

# rpost <body> [token] -> "<status>\n<json>"
rpost() { curl -s -o "$TMP/rbody" -w '%{http_code}' -X POST -H "authorization: Bearer ${2:-$RUNTOK}" -H 'content-type: application/json' -d "$1" "$RUN"; echo; cat "$TMP/rbody"; echo; }
rcall() { curl -s -o "$TMP/rbody" -w '%{http_code}' -X "$1" -H "authorization: Bearer ${4:-$RUNTOK}" -H "x-e3d-run-token: $3" "$RUN/$2"; echo; cat "$TMP/rbody"; echo; }
code() { head -1 <<< "$1"; }
js() { tail -n +2 <<< "$1"; }
wait_run() {  # wait_run <id> <run token> <status>
  for _ in $(seq 1 100); do [[ "$(js "$(rcall GET "$1" "$2")" | jq -r .run.status)" == "$3" ]] && return 0; sleep 0.2; done
  fail "run $1 did not reach $3: $(rcall GET "$1" "$2")"
}
body_of() { jq -nc --arg r "$1" --arg d "$2" --arg q "${3:-$Q}" '{reservation_id:$r,debate_id:$d,question:$q,providers:["claude","codex"]}'; }

# --- features are learned from introspect: until then, nothing is accepted (retryable) ---
R1="$(web_reserve)"; D1="$(new_id)"; web_debate "$R1" "$D1"
r="$(rpost "$(body_of "$R1" "$D1")")"; assert_eq "$(code "$r")" "503"; assert_eq "$(js "$r" | jq -r .code)" "not_ready"
assert_eq "$(ledger | jq '.received["authorize-run"] // 0')" "0"
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"rs-test","version":"0"}}}'
curl -s -o /dev/null -X POST -H 'content-type: application/json' -H 'accept: application/json' -H "Authorization: Bearer $TOK_A" -d "$INIT" "http://127.0.0.1:$PORT/mcp"
echo "ok - before the service's features are known the listener answers not_ready and calls nothing"

# --- service token required ---
for t in "" "wrong-token" "$SVC" "$TOK_A"; do
  c="$(curl -s -o /dev/null -w '%{http_code}' -X POST ${t:+-H "authorization: Bearer $t"} -H 'content-type: application/json' -d "$(body_of "$R1" "$D1")" "$RUN")"
  assert_eq "$c" "401" "token [$t]"
done
assert_eq "$(ledger | jq '.received["authorize-run"] // 0')" "0" "nothing reaches the service without the run listener token"
echo "ok - missing or wrong service tokens get 401"

# --- an accepted run: authorized, metered from the web reservation, finalized once and stored ---
n_res0="$(ledger | jq '.reservations | length')"
r="$(rpost "$(body_of "$R1" "$D1")")"; assert_eq "$(code "$r")" "202" "accepted: $(js "$r")"
RT1="$(js "$r" | jq -r .run_token)"; [[ ${#RT1} -ge 32 ]] || fail "a run token"
assert_eq "$(js "$r" | jq -r '[.accepted, .existing, .debate_id] | join(",")')" "true,false,$D1"
wait_run "$D1" "$RT1" done
g="$(js "$(rcall GET "$D1" "$RT1")")"
assert_contains "$(jq -r .run.result.final_answer <<< "$g")" "ACONTENT-$MARK"; assert_eq "$(jq -r .run.result.consensus <<< "$g")" "split"
assert_eq "$(jq -r '.run | has("transcript")' <<< "$g")" "false"
assert_eq "$(ledger | jq -r --arg d "$D1" '[.effects[] | select(.debate_id == $d)] | map([.stored, (.charged > 0)]) | tostring')" "[[true,true]]" "one finalize, stored and charged"
assert_eq "$(ledger | jq -r --arg d "$D1" '.debates[] | select(.debate_id == $d) | [.principal, .status, .has_result] | join(",")')" "acct_web,done,true"
assert_eq "$(ledger | jq '.reservations | length')" "$n_res0" "never reserved again"
assert_eq "$(ledger | jq '[.settlements[] | select(.call != "finalize")] | length')" "0" "never a settle"
echo "ok - an accepted run is authorized, metered from the web reservation, finalized once and stored"

# --- GET and DELETE need the run's own token ---
for rt in "" "wrong" "${RT1}x"; do assert_eq "$(code "$(rcall GET "$D1" "$rt")")" "401" "run token [$rt]"; done
assert_eq "$(code "$(rcall GET "$D1" "$RT1" "wrong-token")")" "401" "the run token alone is not enough"
assert_eq "$(code "$(rcall DELETE "$D1" "wrong")")" "401"
echo "ok - only the per-run token (with the service token) permits GET or DELETE"

# --- idempotent create; conflicts ---
r="$(rpost "$(body_of "$R1" "$D1")")"; assert_eq "$(code "$r")" "200"; assert_eq "$(js "$r" | jq -r .run_token)" "$RT1"; assert_eq "$(js "$r" | jq -r .existing)" "true"
assert_eq "$(code "$(rpost "$(body_of "$R1" "$D1" "$Q changed")")")" "409" "changed fields"
D2="$(new_id)"; assert_eq "$(code "$(rpost "$(body_of "$R1" "$D2")")")" "409" "the reservation is bound to another debate"
assert_eq "$(ledger | jq -r --arg r "$R1" '.finalize_requests[$r]')" "1" "one finalize request for the reservation"
echo "ok - a duplicate returns the same run and token; changed fields or bindings are conflicts"

# --- refused authorization: no model work ---
lines0="$(wc -l < "$ARGS")"
r="$(rpost "$(body_of "res_00000000-0000-0000-0000-000000000000" "$(new_id)")")"
assert_eq "$(code "$r")" "403"; assert_eq "$(js "$r" | jq -r '[.code, .reason, .accepted] | join(",")')" "not_authorized,not_found,false"
r="$(rpost "$(jq -nc --arg r "$R1" --arg d "$(new_id)" --arg q "$Q" '{reservation_id:$r,debate_id:$d,question:$q,principal:"acct_web"}')")"
assert_eq "$(code "$r")" "400" "a principal in the body is refused (ownership comes only from authorize-run)"
sleep 0.5; assert_eq "$(wc -l < "$ARGS")" "$lines0" "no debate ran"
echo "ok - a refused authorization or a body naming its own owner starts no model work"

# --- cancel a running run: finalized as error without a result ---
echo hang > "$MODE"; rm -f "$STARTED"
R3="$(web_reserve)"; D3="$(new_id)"; web_debate "$R3" "$D3"
r="$(rpost "$(body_of "$R3" "$D3")")"; assert_eq "$(code "$r")" "202"; RT3="$(js "$r" | jq -r .run_token)"
for _ in $(seq 1 100); do [[ -e "$STARTED" ]] && break; sleep 0.05; done; [[ -e "$STARTED" ]] || fail "the debate did not start"
wait_run "$D3" "$RT3" running
r="$(rcall DELETE "$D3" "$RT3")"; assert_eq "$(code "$r")" "200"
assert_eq "$(js "$r" | jq -r '.run | [.status, .outcome, .cancelled, has("result")] | join(",")')" "failed,error,true,false"
assert_eq "$(ledger | jq -r --arg d "$D3" '.debates[] | select(.debate_id == $d) | [.outcome, .has_result] | join(",")')" "error,false"
assert_eq "$(ledger | jq -r --arg r "$R3" '.finalize_requests[$r]')" "1"
echo ok > "$MODE"
echo "ok - cancel finalizes a running run with outcome error and no result"

# --- --doctor reports the listener without the token ---
doc="$(env "${BASE_ENV[@]}" E3D_MCP_STATE_DIR="$TMP/state-S" E3D_MCP_RUN_PORT=8799 E3D_MCP_RUN_TOKEN="$RUNTOK" "$SERVER" --doctor 2>&1 || true)"
assert_contains "$doc" "Internal run listener:"; assert_contains "$doc" "ok    internal run listener settings are valid"; assert_contains "$doc" "127.0.0.1:8799"
doc2="$(env "${BASE_ENV[@]}" E3D_MCP_STATE_DIR="$TMP/state-S" E3D_MCP_RUN_PORT=8799 E3D_MCP_RUN_TOKEN="$SHORT" "$SERVER" --doctor 2>&1 || true)"
assert_contains "$doc2" "FAIL  internal run listener settings are valid"
for o in "$doc" "$doc2"; do assert_not_contains "$o" "$RUNTOK"; assert_not_contains "$o" "$SHORT"; assert_not_contains "$o" "$SVC"; done
echo "ok - --doctor checks the run listener settings without printing the token"

# --- shutdown closes the listener ---
kill -TERM "$PID_S"; for _ in $(seq 1 50); do kill -0 "$PID_S" 2>/dev/null || break; sleep 0.1; done
kill -0 "$PID_S" 2>/dev/null && fail "the server did not stop"
c="$(curl -s -o /dev/null -w '%{http_code}' "$RUN" || true)"; assert_eq "$c" "000" "the listener is closed"
echo "ok - SIGTERM closes the run listener"

# --- README ---
for v in E3D_MCP_RUN_PORT E3D_MCP_RUN_TOKEN E3D_MCP_RUN_AUTH_FAILS_PER_MIN; do grep -q "| \`$v\` |" "$ROOT/README.md" || fail "README table is missing $v"; done
echo "ok - README documents the run listener settings"

# --- privacy: no body, question, answer, service token or run token in any log ---
tokens=("$SVC" "$RUNTOK" "$TOK_A" "$RT1" "$RT3")
for f in "$TMP/S.log" "$TMP/stub.log"; do
  if grep -lE "QCONTENT-$MARK|ACONTENT-$MARK|TCONTENT-$MARK" "$f"; then fail "debate content leaked into $f"; fi
  for secret in "${tokens[@]}"; do if grep -qF -- "$secret" "$f"; then fail "a token leaked into $f"; fi; done
done
while IFS= read -r -d '' f; do
  mode="$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f")"; [[ "$mode" == "600" ]] || fail "$f has mode $mode, expected 600"
done < <(find "$TMP/state-S" -path '*/runs/*' -type f -print0)
echo "ok - no content or token in logs; run state (with the run token) is 0600"
echo "mcp-runserver: all passed"
