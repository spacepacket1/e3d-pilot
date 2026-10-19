#!/usr/bin/env bash
set -euo pipefail

# Async debate runs (e3d_debate_start / _status / _result, lib/mcp/runs.js): unit tests, then the real server (--http) with the
# external hook against the reference stub service, with a stub debate binary. Loopback only, no model calls.
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
node "$ROOT/tests/fixtures/runs-unit.mjs" "$TMP/unit" | tee "$TMP/unit.out"
assert_contains "$(cat "$TMP/unit.out")" "runs unit tests:"

# ---- the real server against the stub ----
SVC="svc-MARKER-$(openssl rand -hex 12)"
TOK_A="caller-MARKER-a-$(openssl rand -hex 12)"; TOK_B="caller-MARKER-b-$(openssl rand -hex 12)"; TOK_BROKE="caller-MARKER-broke-$(openssl rand -hex 12)"
TOK_C="caller-MARKER-c-$(openssl rand -hex 12)"
jq -n --arg a "$TOK_A" --arg b "$TOK_B" --arg br "$TOK_BROKE" --arg c "$TOK_C" '{accounts: [
  {principal: "acct_a", balance: 1000000, keys: [{id: "key-a", token: $a}]},
  {principal: "acct_b", balance: 1000000, keys: [{id: "key-b", token: $b}]},
  {principal: "acct_c", balance: 1000000, keys: [{id: "key-c", token: $c}]},
  {principal: "acct_broke", balance: 0, keys: [{id: "key-broke", token: $br}]}]}' > "$TMP/seed.json"

env STUB_SERVICE_TOKEN="$SVC" STUB_SEED="$TMP/seed.json" STUB_URL_FILE="$TMP/stub.url" node "$STUB" > "$TMP/stub.out" 2> "$TMP/stub.log" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$TMP/stub.url" ]] && break; sleep 0.05; done
[[ -s "$TMP/stub.url" ]] || fail "stub did not start: $(cat "$TMP/stub.log")"
URL="$(cat "$TMP/stub.url")"
ledger() { curl -fsS -H "authorization: Bearer $SVC" "$URL/_stub/state"; }
features() { curl -fsS -X POST -H "authorization: Bearer $SVC" -H 'content-type: application/json' -d "{\"features\":$1}" "$URL/_stub/features" > /dev/null; }
n_res() { ledger | jq '.reservations | length'; }

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
  slow) sleep 3 ;;
esac
printf 'FINAL ANSWER: ACONTENT-$MARK use a JSON file.\nCONSENSUS: split\nDISSENT: Codex prefers SQLite.\n'
STUBEOF
chmod +x "$DEBATE"

# start_server <name> [VAR=value ...] -> PORT_<name>, PID_<name>; state in $TMP/state-<name>; stderr in $TMP/<name>.log
start_server() {
  local name="$1"; shift
  : > "$TMP/$name.port"
  env E3D_MCP_AUTH_URL="$URL" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" E3D_MCP_STATE_DIR="$TMP/state-$name" E3D_MCP_PORT_FILE="$TMP/$name.port" \
    E3D_MCP_DEBATE_BIN="$DEBATE" TYPESAFE_API_KEY="" E3D_MCP_PRINCIPAL="" E3D_MCP_AUTH_CACHE_SEC=1 E3D_MCP_TIMEOUT_SEC=20 E3D_MCP_AUTH_HEALTH_SEC=1 \
    E3D_MCP_RATE_PER_MIN=100000 E3D_MCP_RUNS_POLL_PER_MIN=100000 "$@" "$SERVER" --http --port 0 2>> "$TMP/$name.log" &
  local pid=$!; PIDS+=("$pid"); eval "PID_$name=$pid"
  for _ in $(seq 1 100); do [[ -s "$TMP/$name.port" ]] && break; sleep 0.1; done
  [[ -s "$TMP/$name.port" ]] || { cat "$TMP/$name.log" >&2; fail "server $name did not start"; }
  eval "PORT_$name=$(cat "$TMP/$name.port")"
}
sport() { local v="PORT_$1"; echo "${!v}"; }
http() {
  local name="$1"; shift
  curl -s -m 60 -D "$TMP/headers" -o "$TMP/body" -w '%{http_code}' "$@" "http://127.0.0.1:$(sport "$name")/mcp"; echo; cat "$TMP/body"; echo
  { cat "$TMP/body"; echo; } >> "$TMP/bodies.out"
}
body() { tail -n +2 <<< "$1"; }
hdr() { grep -i "^$1:" "$TMP/headers" | head -1 | sed -E 's/^[^:]+: *//' | tr -d '\r'; }
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"runs-test","version":"0"}}}'
J=(-H 'content-type: application/json' -H 'accept: application/json')
sid_of() { http "$1" -X POST "${J[@]}" -H "Authorization: Bearer $2" -d "$INIT" > /dev/null; hdr mcp-session-id; }
rpc() { http "$1" -X POST "${J[@]}" -H "Authorization: Bearer $2" -H "mcp-session-id: $3" -d "$4"; }
tool() { rpc "$1" "$2" "$3" "$(jq -nc --arg n "$4" --argjson a "${5:-{\}}" '{jsonrpc:"2.0",id:7,method:"tools/call",params:{name:$n,arguments:$a}}')"; }
tools_of() { body "$(rpc "$1" "$2" "$3" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')" | jq -r '.result.tools | map(.name) | sort | join(",")'; }
res() { body "$1" | jq -c .result.structuredContent; }
rtext() { body "$1" | jq -r '.result.content[0].text'; }
rerr() { body "$1" | jq -r '.result.isError // false'; }
start_args() { jq -nc --arg q "$Q" '{question:$q,providers:["claude","codex"]}'; }
dstart() { tool "$1" "$2" "$3" e3d_debate_start "${4:-$(start_args)}"; }
dstatus() { tool "$1" "$2" "$3" e3d_debate_status "$(jq -nc --arg d "$4" '{debate_id:$d}')"; }
dresult() { tool "$1" "$2" "$3" e3d_debate_result "$(jq -nc --arg d "$4" --argjson t "${5:-false}" '{debate_id:$d,include_transcript:$t}')"; }
wait_status() {  # wait_status <srv> <tok> <sid> <id> <status> -> waits up to 20 s
  for _ in $(seq 1 100); do [[ "$(res "$(dstatus "$1" "$2" "$3" "$4")" | jq -r .status)" == "$5" ]] && return 0; sleep 0.2; done
  fail "debate $4 did not reach $5 (last: $(res "$(dstatus "$1" "$2" "$3" "$4")"))"
}
runs_in() { find "$TMP/state-$1/runs" -mindepth 2 -maxdepth 2 -type d -name 'dbt_*' 2>/dev/null | wc -l | tr -d ' '; }

# --- configuration errors refuse to start ---
out="$(E3D_MCP_AUTH_URL="$URL" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" E3D_MCP_STATE_DIR="$TMP/state-bad" E3D_MCP_RUNS_PER_PRINCIPAL=0 "$SERVER" --http --port 0 2>&1)" && fail "a bad run setting must refuse to start" || true
assert_contains "$out" "E3D_MCP_RUNS_PER_PRINCIPAL"
out="$(E3D_MCP_AUTH_URL="$URL" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" E3D_MCP_STATE_DIR="$TMP/state-bad" E3D_MCP_CUSTOMER_LIMITS=rounds=zero "$SERVER" --http --port 0 2>&1)" && fail "bad customer limits must refuse to start" || true
assert_contains "$out" "E3D_MCP_CUSTOMER_LIMITS"
echo "ok - bad run settings refuse to start"

# --- gating: the async tools exist only while the service advertises BOTH finalize and fetch ---
start_server R1
SA="$(sid_of R1 "$TOK_A")"
assert_eq "$(tools_of R1 "$TOK_A" "$SA")" "e3d_debate,e3d_list_providers,e3d_usage" "no features: no async tools"
r="$(dstart R1 "$TOK_A" "$SA")"; assert_eq "$(body "$r" | jq -r .error.code)" "-32602" "a gated tool is an unknown tool"
for f in '["finalize"]' '["fetch"]' '["fetch","authorize-run"]'; do
  features "$f"; sleep 1.2
  assert_eq "$(tools_of R1 "$TOK_A" "$SA")" "e3d_debate,e3d_list_providers,e3d_usage" "features $f alone is insufficient"
  r="$(tool R1 "$TOK_A" "$SA" e3d_debate_status '{"debate_id":"dbt_000000000000000000000000"}')"; assert_eq "$(body "$r" | jq -r .error.code)" "-32602"
done
features '["finalize","fetch"]'; sleep 1.2
assert_eq "$(tools_of R1 "$TOK_A" "$SA")" "e3d_debate,e3d_debate_result,e3d_debate_start,e3d_debate_status,e3d_list_providers,e3d_usage" "both advertised: async tools listed"
echo "ok - async tools are absent unless both finalize and fetch are advertised"

# --- a started debate cannot use the client's own models (mcp-sampling): refused before anything is reserved ---
n0="$(n_res)"
r="$(dstart R1 "$TOK_A" "$SA" "$(jq -nc --arg q "$Q" '{question:$q,providers:["mcp-sampling","claude"]}')")"
assert_eq "$(rerr "$r")" "true"; assert_contains "$(rtext "$r")" "cannot use your client"; assert_eq "$(n_res)" "$n0" "refused before reserve"
r="$(dstart R1 "$TOK_A" "$SA" "$(jq -nc --arg q "$Q" '{question:$q,providers:["claude","codex"],synthesizer:"mcp-sampling"}')")"
assert_eq "$(rerr "$r")" "true"; assert_eq "$(n_res)" "$n0" "a sampling synthesizer is refused too"
echo "ok - async start refuses client-side (mcp-sampling) models before reserving"

# --- start returns well before the debate ends; status queued/running -> done; result; transcript only on request ---
echo slow > "$MODE"
now_ms() { node -e 'console.log(Date.now())'; }
t0="$(now_ms)"
r="$(dstart R1 "$TOK_A" "$SA")"
t1="$(now_ms)"
assert_eq "$(rerr "$r")" "false" "start: $(rtext "$r")"
ID="$(res "$r" | jq -r .debate_id)"; [[ "$ID" =~ ^dbt_[0-9a-f]{24}$ ]] || fail "start returns a debate id: $(res "$r")"
assert_contains "queued running" "$(res "$r" | jq -r .status)"; [[ "$(res "$r" | jq -r .poll_after_sec)" -gt 0 ]] || fail "poll_after_sec"
(( t1 - t0 < 2000 )) || fail "start took $(( t1 - t0 )) ms; the debate takes 3 s"
st="$(res "$(dstatus R1 "$TOK_A" "$SA" "$ID")" | jq -r .status)"; assert_contains "queued running" "$st" "status before the end"
r="$(dresult R1 "$TOK_A" "$SA" "$ID")"; assert_eq "$(rerr "$r")" "false"; assert_contains "$(rtext "$r")" "still"
wait_status R1 "$TOK_A" "$SA" "$ID" done
r="$(dresult R1 "$TOK_A" "$SA" "$ID")"; sc="$(res "$r")"
assert_contains "$(jq -r .final_answer <<< "$sc")" "ACONTENT-$MARK"; assert_eq "$(jq -r .consensus <<< "$sc")" "split"; assert_eq "$(jq -r .dissent <<< "$sc")" "Codex prefers SQLite."
assert_eq "$(jq -r '.positions | map(.provider) | join(",")' <<< "$sc")" "claude,codex"; assert_eq "$(jq -r 'has("transcript")' <<< "$sc")" "false" "no transcript unless asked"
assert_eq "$(jq -r .source <<< "$sc")" "local"; assert_contains "$(rtext "$r")" "Dissent"
r="$(dresult R1 "$TOK_A" "$SA" "$ID" true)"; assert_contains "$(res "$r" | jq -r .transcript)" "TCONTENT-$MARK"
assert_eq "$(ledger | jq -r --arg d "$ID" '[.effects[] | select(.debate_id == $d)] | map([.stored, (.charged > 0)]) | tostring')" "[[true,true]]" "finalized once, stored and charged"
assert_eq "$(ledger | jq '[.settlements[] | select(.call != "finalize")] | length')" "0" "never a settle"
echo "ok - start returns at once; status progresses to done; result has verdict and positions; transcript only on request"

# --- settlement and storage happen without anyone polling ---
r="$(dstart R1 "$TOK_A" "$SA")"; ID2="$(res "$r" | jq -r .debate_id)"
for _ in $(seq 1 100); do [[ "$(ledger | jq -r --arg d "$ID2" '[.debates[] | select(.debate_id == $d and .has_result)] | length')" == "1" ]] && break; sleep 0.2; done
assert_eq "$(ledger | jq -r --arg d "$ID2" '[.effects[] | select(.debate_id == $d)] | map(.stored) | tostring')" "[true]" "stored without polling"
echo "ok - a debate nobody polls is still finalized and stored"

# --- another principal: not_found, identical to an unknown id, also through the service fallback ---
SB="$(sid_of R1 "$TOK_B")"
fetch0="$(ledger | jq '.received.fetch // 0')"
foreign="$(rtext "$(dresult R1 "$TOK_B" "$SB" "$ID")")"; unknown="$(rtext "$(dresult R1 "$TOK_A" "$SA" "dbt_$(openssl rand -hex 12)")")"
assert_eq "$foreign" "$unknown" "foreign and unknown ids are indistinguishable"; assert_contains "$foreign" "not_found"
assert_eq "$(rtext "$(dstatus R1 "$TOK_B" "$SB" "$ID2")")" "$unknown" "status too"
[[ "$(ledger | jq '.received.fetch // 0')" -gt "$fetch0" ]] || fail "a foreign id falls back to the service fetch"
fetch1="$(ledger | jq '.received.fetch // 0')"
dresult R1 "$TOK_B" "$SB" "$ID" > /dev/null; assert_eq "$(ledger | jq '.received.fetch // 0')" "$fetch1" "the not_found is cached for 60 s"
assert_eq "$(rtext "$(dresult R1 "$TOK_A" "$SA" "../../etc/passwd")")" "$unknown" "malformed ids are not_found"
echo "ok - another principal gets not_found, identical to an unknown id, including through the service fallback (negative-cached)"

# --- customer maxima clamp caller arguments (defaults: 2 rounds, 300 words, 3 providers) ---
echo ok > "$MODE"; : > "$ARGS"
r="$(dstart R1 "$TOK_A" "$SA" "$(jq -nc --arg q "$Q" '{question:$q,mode:"thorough",rounds:3,max_words:600,providers:["claude","codex","gemini","grok"]}')")"
assert_eq "$(rerr "$r")" "false" "clamped, not refused: $(rtext "$r")"; wait_status R1 "$TOK_A" "$SA" "$(res "$r" | jq -r .debate_id)" done
a="$(tail -1 "$ARGS")"; assert_contains "$a" "--rounds 2"; assert_contains "$a" "--max-words 300"; assert_contains "$a" "--providers claude,codex,gemini "
: > "$ARGS"
r="$(dstart R1 "$TOK_A" "$SA")"; wait_status R1 "$TOK_A" "$SA" "$(res "$r" | jq -r .debate_id)" done
a="$(tail -1 "$ARGS")"; assert_contains "$a" "--rounds 1"; assert_contains "$a" "--max-words 80" "omitted values keep the defaults"
# the synchronous tool is not clamped and behaves as before
: > "$ARGS"
r="$(tool R1 "$TOK_A" "$SA" e3d_debate "$(jq -nc --arg q "$Q" '{question:$q,rounds:3,max_words:600,providers:["claude","codex","gemini","grok"]}')")"
assert_eq "$(rerr "$r")" "false"; a="$(tail -1 "$ARGS")"; assert_contains "$a" "--rounds 3"; assert_contains "$a" "--max-words 600"; assert_contains "$a" "--providers claude,codex,gemini,grok "
sc="$(res "$r")"; assert_contains "$(jq -r .final_answer <<< "$sc")" "ACONTENT-$MARK"; assert_eq "$(jq -r '.dissent.summary' <<< "$sc")" "Codex prefers SQLite."
assert_eq "$(jq -r '[.mode, .rounds_requested, .billing.stored] | join(",")' <<< "$sc")" "quick,3,true" "e3d_debate unchanged (finalized)"
echo "ok - customer maxima clamp async arguments; the synchronous e3d_debate is unchanged"

# --- a reserve refusal leaves no run and holds nothing ---
SBR="$(sid_of R1 "$TOK_BROKE")"; runs0="$(runs_in R1)"
r="$(dstart R1 "$TOK_BROKE" "$SBR")"; assert_eq "$(rerr "$r")" "true"; assert_contains "$(rtext "$r")" "billing"
assert_eq "$(runs_in R1)" "$runs0" "no run left behind"
assert_eq "$(ledger | jq '[.reservations[] | select(.principal == "acct_broke")] | length')" "0"
echo "ok - a refused reserve leaves no visible run"

# --- TTL eviction: the result is still retrievable through the service fetch ---
start_server R3 E3D_MCP_RUNS_TTL_SEC=1
S3="$(sid_of R3 "$TOK_A")"
r="$(dstart R3 "$TOK_A" "$S3")"; ID3="$(res "$r" | jq -r .debate_id)"; wait_status R3 "$TOK_A" "$S3" "$ID3" done
sleep 1.5
r="$(dresult R3 "$TOK_A" "$S3" "$ID3" true)"; sc="$(res "$r")"
assert_eq "$(jq -r .source <<< "$sc")" "service" "after the local TTL the service answers"; assert_contains "$(jq -r .final_answer <<< "$sc")" "ACONTENT-$MARK"
assert_contains "$(jq -r .transcript <<< "$sc")" "TCONTENT-$MARK"
assert_eq "$(runs_in R3)" "0" "the local copy is gone"
S3B="$(sid_of R3 "$TOK_B")"; assert_contains "$(rtext "$(dresult R3 "$TOK_B" "$S3B" "$ID3")")" "not_found" "the fallback checks the owner"
echo "ok - after local TTL eviction the owner still gets the result through the service; others get not_found"

# --- byte cap: new starts are refused before any reserve ---
start_server R4 E3D_MCP_RUNS_MAX_BYTES=1
S4="$(sid_of R4 "$TOK_A")"
r="$(dstart R4 "$TOK_A" "$S4")"; wait_status R4 "$TOK_A" "$S4" "$(res "$r" | jq -r .debate_id)" done
n0="$(n_res)"; r="$(dstart R4 "$TOK_A" "$S4")"
assert_eq "$(rerr "$r")" "true"; assert_contains "$(rtext "$r")" "cannot store more"; assert_eq "$(n_res)" "$n0" "refused before reserve"; assert_eq "$(runs_in R4)" "1"
echo "ok - the run store byte cap refuses new starts before reserving"

# --- slots: a refused slot reserves nothing; slots and queued runs survive a crash; started runs end as errors ---
start_server R2 E3D_MCP_RUNS_PER_PRINCIPAL=2 E3D_MCP_MAX_CONCURRENT=1
S2="$(sid_of R2 "$TOK_C")"
rm -f "$STARTED"; echo hang > "$MODE"
r="$(dstart R2 "$TOK_C" "$S2")"; HID="$(res "$r" | jq -r .debate_id)"
for _ in $(seq 1 100); do [[ -e "$STARTED" ]] && break; sleep 0.05; done; [[ -e "$STARTED" ]] || fail "the debate did not start"
wait_status R2 "$TOK_C" "$S2" "$HID" running
r="$(dstart R2 "$TOK_C" "$S2")"; QID="$(res "$r" | jq -r .debate_id)"; assert_eq "$(res "$r" | jq -r .status)" "queued" "the execution slot is busy"
n0="$(n_res)"; runs0="$(runs_in R2)"
r="$(dstart R2 "$TOK_C" "$S2")"; assert_eq "$(rerr "$r")" "true"; assert_contains "$(rtext "$r")" "busy"
assert_eq "$(n_res)" "$n0" "a refused slot reserves nothing"; assert_eq "$(runs_in R2)" "$runs0" "and leaves no run"
HRID="$(ledger | jq -r --arg d "$HID" '.reservations[-2].reservation_id')"
kill -9 "$PID_R2"; wait "$PID_R2" 2>/dev/null || true
pkill -f "$TMP/stub-debate" 2>/dev/null || true
echo ok > "$MODE"
start_server R2 E3D_MCP_RUNS_PER_PRINCIPAL=2 E3D_MCP_MAX_CONCURRENT=1
S2="$(sid_of R2 "$TOK_C")"
assert_eq "$(ledger | jq -r --arg d "$HID" '.debates[] | select(.debate_id == $d) | [.outcome, .has_result, .credits_charged] | join(",")')" "error,false,0" "the interrupted started run is finalized as an error"
assert_eq "$(res "$(dstatus R2 "$TOK_C" "$S2" "$HID")" | jq -r '[.status, .outcome] | join(",")')" "failed,error"
wait_status R2 "$TOK_C" "$S2" "$QID" done
assert_contains "$(res "$(dresult R2 "$TOK_C" "$S2" "$QID")" | jq -r .final_answer)" "ACONTENT-$MARK" "the queued run resumed after the restart"
assert_eq "$(ledger | jq --arg p acct_c '[.reservations[] | select(.principal == $p)] | length')" "2" "a resumed run is never reserved again"
assert_contains "$(cat "$TMP/R2.log")" "recovered 1 queued run(s)"
# the slots were rebuilt and released: the full per-principal count is available again
r1="$(dstart R2 "$TOK_C" "$S2")"; r2="$(dstart R2 "$TOK_C" "$S2")"
assert_eq "$(rerr "$r1"),$(rerr "$r2")" "false,false" "slots are free after recovery"
wait_status R2 "$TOK_C" "$S2" "$(res "$r2" | jq -r .debate_id)" done
[[ -z "$(ls -A "$TMP/state-R2/metering-intents")" ]] || fail "every intent is reconciled"
echo "ok - slots: refusal reserves nothing; after a crash the started run is an error, the queued run resumes, slots recover"

# --- --doctor reports the async run settings and stores, without secrets ---
doc="$(E3D_MCP_AUTH_URL="$URL" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" E3D_MCP_STATE_DIR="$TMP/state-R1" "$SERVER" --doctor 2>&1 || true)"
assert_contains "$doc" "Async debates:"; assert_contains "$doc" "ok    async run settings are valid"; assert_contains "$doc" "run store bytes"; assert_contains "$doc" "outbox bytes"
doc2="$(E3D_MCP_AUTH_URL="$URL" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" E3D_MCP_STATE_DIR="$TMP/state-R1" E3D_MCP_RUNS_TTL_SEC=never "$SERVER" --doctor 2>&1 || true)"
assert_contains "$doc2" "FAIL  async run settings are valid"
for out in "$doc" "$doc2"; do assert_not_contains "$out" "$SVC"; assert_not_contains "$out" "QCONTENT"; done
echo "ok - --doctor checks the async run settings, the run store and the outbox bytes"

# --- README documents every new variable ---
for v in E3D_MCP_RUNS_PER_PRINCIPAL E3D_MCP_RUNS_GLOBAL E3D_MCP_RUNS_KEEP_PER_PRINCIPAL E3D_MCP_RUNS_TTL_SEC E3D_MCP_RUNS_MAX_BYTES E3D_MCP_RUNS_POLL_PER_MIN E3D_MCP_RUN_TIMEOUT_SEC E3D_MCP_CUSTOMER_LIMITS; do
  grep -q "| \`$v\` |" "$ROOT/README.md" || fail "README table is missing $v"
done
echo "ok - README documents the async run settings"

# --- privacy: no question, answer, transcript or token in any log; run state files 0600, directories 0700 ---
for f in "$TMP"/R*.log "$TMP/stub.log"; do
  if grep -lE "QCONTENT-$MARK|ACONTENT-$MARK|TCONTENT-$MARK" "$f"; then fail "debate content leaked into $f"; fi
  for secret in "$SVC" "$TOK_A" "$TOK_B" "$TOK_C" "$TOK_BROKE"; do if grep -qF -- "$secret" "$f"; then fail "a token leaked into $f"; fi; done
done
while IFS= read -r -d '' f; do
  mode="$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f")"; [[ "$mode" == "600" ]] || fail "$f has mode $mode, expected 600"
done < <(find "$TMP"/state-R* -path '*/runs/*' -type f -print0)
while IFS= read -r -d '' d; do
  mode="$(stat -f '%Lp' "$d" 2>/dev/null || stat -c '%a' "$d")"; [[ "$mode" == "700" ]] || fail "$d has mode $mode, expected 700"
done < <(find "$TMP"/state-R* -path '*/runs*' -type d -print0)
ledger > "$TMP/ledger.json"
jq -e '[.effects[].reservation_id] | (length == (unique | length))' "$TMP/ledger.json" > /dev/null || fail "a reservation was finalized twice"
jq -e '[.reservations[] | select(.state == "held")] | length == 0' "$TMP/ledger.json" > /dev/null || fail "a hold is left: $(jq -c '[.reservations[] | select(.state=="held")]' "$TMP/ledger.json")"
echo "ok - no debate content or token in logs; run files 0600 and directories 0700; one effect per reservation; no hold left"
echo "mcp-runs: all passed"
