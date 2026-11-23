#!/usr/bin/env bash
set -euo pipefail

# Hosted skills, PR H2c (docs/skills/phase3/plan-3c-hosted-user-skills.md section 3, "Listener fields"): the run listener accepts hosted user skills (skills_v1) as seats and as
# the observer, and runs them through the real bin/e3d-debate. Unit checks of the strict fields, then the real listener against the reference stub and a fake vendor
# (four API adapters on 127.0.0.1). No model, no network beyond 127.0.0.1, no real key.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-assert_eq}: expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "${3:-assert_contains}: expected to find [$2] in [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "${3:-assert_not_contains}: did not expect [$2] in [$1]"; }

node "$ROOT/tests/fixtures/skills-run-test.mjs" | tee "$TMP/unit.out"
assert_contains "$(cat "$TMP/unit.out")" "skills-run unit tests:"

# ---------------------------------------------------------------- definitions (real hashes, built like a hosted service would)
P=u_abc123def456
mk() { node "$ROOT/tests/fixtures/skills/hosted-make.mjs" "$1" "$2" "$3"; }
mk "$TMP/d-a.json" "$P" '[{"name":"lens-a","body":"SEATMARK-ALPHA. Argue the opposite.","hooks":["seat"]}]'
mk "$TMP/d-b.json" "$P" '[{"name":"lens-b","body":"SEATMARK-BETA. Look for the cost.","hooks":["seat"]}]'
mk "$TMP/d-r.json" "$P" '[{"name":"reviewer","body":"OBSMARK-GAMMA. Say whether the dissent added evidence.","hooks":["observer"]}]'
mk "$TMP/d-dual.json" "$P" '[{"name":"dual","body":"DUALMARK-DELTA. Both a lens and a review.","hooks":["seat","observer"]}]'
mk "$TMP/d-tools.json" "$P" '[{"name":"sneaky","body":"SNEAKMARK-TOOLS.","hooks":["seat"],"mutate":"tools"}]'
mk "$TMP/d-other.json" "u_zzzzzz999999" '[{"name":"lens-a","body":"OTHERMARK-OWNER.","hooks":["seat"]}]'
mk "$TMP/d-dual2.json" "$P" '[{"name":"dual","body":"DUALMARK-OTHER-TEXT. A second, different definition under the same id.","hooks":["seat","observer"]}]'
LONGNAME="$(printf 'a%.0s' $(seq 1 70))"
mk "$TMP/d-long.json" "$P" "[{\"name\":\"longobs\",\"rename\":\"$LONGNAME\",\"body\":\"OBSMARK-LONGNAME. Review.\",\"hooks\":[\"observer\"]}]"
def() { jq -c '.skills[0]' "$1"; }
DA="$(def "$TMP/d-a.json")"; DB="$(def "$TMP/d-b.json")"; DR="$(def "$TMP/d-r.json")"; DUAL="$(def "$TMP/d-dual.json")"; DTOOLS="$(def "$TMP/d-tools.json")"; DOTHER="$(def "$TMP/d-other.json")"; DUAL2="$(def "$TMP/d-dual2.json")"; DLONG="$(def "$TMP/d-long.json")"
spec_of() { jq -r '"\(.id)@\(.version)#\(.definition_hash)"' <<< "$1"; }
SPEC_A="$(spec_of "$DA")"; SPEC_B="$(spec_of "$DB")"; SPEC_R="$(spec_of "$DR")"; SPEC_DUAL="$(spec_of "$DUAL")"
[[ "$SPEC_A" =~ ^skill\.u_abc123def456\.lens-a@1\.0\.0#sha256:[0-9a-f]{64}$ ]] || fail "unexpected spec $SPEC_A"

# ---------------------------------------------------------------- fake vendor, reference billing stub, recording debate wrapper
VREQ="$TMP/vendor.jsonl"; : > "$VREQ"
FAKE_ANSWER='FINAL ANSWER: ok
CONSENSUS: split
DISSENT: none' node "$ROOT/tests/fixtures/fake-vendor.mjs" "$VREQ" "$TMP/vendor.port" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$TMP/vendor.port" ]] && break; sleep 0.05; done
VP="$(cat "$TMP/vendor.port")"
vendor_env=(ANTHROPIC_API_KEY=k-anth ANTHROPIC_API_BASE_URL="http://127.0.0.1:$VP" OPENAI_API_KEY=k-oai OPENAI_API_BASE_URL="http://127.0.0.1:$VP/v1"
  GEMINI_API_KEY=k-gem GEMINI_API_BASE_URL="http://127.0.0.1:$VP/v1" XAI_API_KEY=k-xai XAI_API_BASE_URL="http://127.0.0.1:$VP/v1"
  ANTHROPIC_API_MODEL=claude-test OPENAI_API_MODEL=gpt-test GEMINI_API_MODEL=gem-test XAI_API_MODEL=xai-test
  OPENAI_API_TIMEOUT=5 ANTHROPIC_API_TIMEOUT=5 GEMINI_API_TIMEOUT=5 XAI_API_TIMEOUT=5 E3D_DEBATE_WEB_SEARCH=off TYPESAFE_API_KEY="")
vreq_count() { wc -l < "$VREQ" | tr -d ' '; }
prompts_with() { jq -c --arg s "$1" 'select(.body.messages[0].content | contains($s))' "$VREQ" | wc -l | tr -d ' '; }

STUB="$ROOT/examples/external-auth-stub.js"
SERVER="$ROOT/bin/e3d-mcp"
SVC="svc-MARKER-$(openssl rand -hex 12)"
RUNTOK="runtok-MARKER-$(openssl rand -hex 16)"
TOK_A="caller-MARKER-a-$(openssl rand -hex 12)"
jq -n --arg a "$TOK_A" '{accounts: [{principal: "acct_web", balance: 1000000, keys: [{id: "key-a", token: $a}]}]}' > "$TMP/seed.json"
env STUB_SERVICE_TOKEN="$SVC" STUB_SEED="$TMP/seed.json" STUB_URL_FILE="$TMP/stub.url" STUB_FEATURES="finalize,fetch,authorize-run" STUB_PRICING=1 node "$STUB" > "$TMP/stub.out" 2> "$TMP/stub.log" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$TMP/stub.url" ]] && break; sleep 0.05; done
URL="$(cat "$TMP/stub.url")"
billing() { curl -sS -X POST -H "authorization: Bearer $SVC" -H 'content-type: application/json' "${@:2}" "$URL/$1"; }
new_id() { echo "dbt_$(openssl rand -hex 12)"; }
Q="QCONTENT: which skill?"

# the debate binary the listener runs: records what it was given (the arguments with the paths made generic, the skills file's path and permissions, the skill switches), can tamper with
# the skills file or hang, otherwise runs the REAL bin/e3d-debate and keeps a copy of its usage.json
REC="$TMP/wrap.rec"; SNAP="$TMP/snap"; mkdir -p "$SNAP"; : > "$REC"
cat > "$TMP/wrap.sh" <<'WRAPEOF'
#!/usr/bin/env bash
hs=""; out=""; prev=""
for a in "$@"; do [[ "$prev" == --hosted-skills ]] && hs="$a"; [[ "$prev" == --out-dir ]] && out="$a"; prev="$a"; done
norm="$(printf '%s ' "$@" | sed -E "s#--question-file [^ ]+#--question-file F#; s#--out-dir [^ ]+#--out-dir D#; s#--hosted-skills [^ ]+#--hosted-skills H#")"
fm=""; dm=""
if [[ -n "$hs" ]]; then fm="$(ls -l "$hs" | cut -c1-10)"; dm="$(ls -ld "$(dirname "$hs")" | cut -c1-10)"; fi
jq -nc --arg a "$norm" --arg hs "$hs" --arg fm "$fm" --arg dm "$dm" --arg seats "${E3D_SKILLS_SEATS-unset}" --arg obs "${E3D_SKILLS_OBSERVER-unset}" --arg v1 "${E3D_SKILLS_V1-unset}" \
  --arg hosted "${E3D_SKILLS_HOSTED-unset}" --arg spec "${E3D_SPECIALISTS-unset}" --arg omax "${E3D_DEBATE_OBSERVER_MAX_TOKENS-unset}" --arg oin "${E3D_DEBATE_OBSERVER_INPUT_BYTES_MAX-unset}" \
  '{args:$a,hs:$hs,fm:$fm,dm:$dm,env:{seats:$seats,obs:$obs,v1:$v1,hosted:$hosted,spec:$spec,omax:$omax,oin:$oin}}' >> "$WRAP_REC"
if [[ -n "${WRAP_TAMPER:-}" && -n "$hs" ]]; then jq -c '.skills[0].instructions.method += " tampered"' "$hs" > "$hs.t" && mv "$hs.t" "$hs"; fi
if [[ -n "${WRAP_HANG:-}" ]]; then trap 'exit 143' TERM; while true; do sleep 0.2; done; fi
rc=0
n="$(wc -l < "$WRAP_REC" | tr -d ' ')"
"$WRAP_REAL" "$@" 2> >(tee "$WRAP_SNAP/err-$n.txt" >&2) || rc=$?
[[ -f "$out/usage.json" ]] && cp "$out/usage.json" "$WRAP_SNAP/usage-$n.json"
exit $rc
WRAPEOF
chmod +x "$TMP/wrap.sh"
nrec() { wc -l < "$REC" | tr -d ' '; }
lastrec() { tail -1 "$REC"; }

BASE_ENV=(E3D_MCP_AUTH_URL="$URL" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" E3D_MCP_DEBATE_BIN="$TMP/wrap.sh" WRAP_REC="$REC" WRAP_SNAP="$SNAP" WRAP_REAL="$ROOT/bin/e3d-debate" TYPESAFE_API_KEY="" E3D_MCP_PRINCIPAL=""
  E3D_MCP_AUTH_CACHE_SEC=1 E3D_MCP_TIMEOUT_SEC=60 E3D_MCP_AUTH_HEALTH_SEC=1 E3D_MCP_RATE_PER_MIN=100000
  E3D_MCP_PRICING=per_token E3D_MCP_CUSTOMER_LIMITS='rounds=2,max_words=300,providers=4' E3D_MCP_PER_TOKEN_ALLOW_XAI=1 "${vendor_env[@]}")
SKON=(E3D_MCP_SKILLS_RUN=1 E3D_SKILLS_V1=1 E3D_SKILLS_HOSTED=1 E3D_SKILLS_SEATS=1 E3D_SKILLS_OBSERVER=1)

for bad in E3D_MCP_SKILLS_RUN E3D_SKILLS_V1 E3D_SKILLS_HOSTED E3D_SKILLS_SEATS E3D_SKILLS_OBSERVER; do
  out="$(env "${BASE_ENV[@]}" "${SKON[@]}" "$bad=2" E3D_MCP_STATE_DIR="$TMP/state-bad" "$SERVER" --http --port 0 2>&1)" && fail "$bad=2 must refuse to start" || true
  assert_contains "$out" "$bad must be unset, 0 or 1"
done
out="$(env "${BASE_ENV[@]}" "${SKON[@]}" E3D_MCP_PRICING= E3D_MCP_STATE_DIR="$TMP/state-bad" "$SERVER" --http --port 0 2>&1)" && fail "skills run needs per-token pricing" || true
assert_contains "$out" "E3D_MCP_SKILLS_RUN=1 needs E3D_MCP_PRICING=per_token"
echo "ok - the switches are validated at startup"

start_server() { # start_server <name> [VAR=value ...]
  local name="$1"; shift
  : > "$TMP/$name.port"; : > "$TMP/$name.runport"
  env "${BASE_ENV[@]}" E3D_MCP_STATE_DIR="$TMP/state-$name" E3D_MCP_PORT_FILE="$TMP/$name.port" E3D_MCP_RUN_PORT=0 E3D_MCP_RUN_PORT_FILE="$TMP/$name.runport" E3D_MCP_RUN_TOKEN="$RUNTOK" "$@" \
    "$SERVER" --http --port 0 2>> "$TMP/$name.log" &
  PIDS+=("$!")
  for _ in $(seq 1 100); do [[ -s "$TMP/$name.runport" ]] && break; sleep 0.1; done
  [[ -s "$TMP/$name.runport" ]] || { cat "$TMP/$name.log" >&2; fail "server $name did not start"; }
  RUN="http://127.0.0.1:$(cat "$TMP/$name.runport")/internal/runs"
  curl -s -o /dev/null -X POST -H 'content-type: application/json' -H 'accept: application/json' -H "Authorization: Bearer $TOK_A" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"skills-run-test","version":"0"}}}' "http://127.0.0.1:$(cat "$TMP/$name.port")/mcp"
}
rpost() { curl -s -o "$TMP/rbody" -w '%{http_code}' -X POST -H "authorization: Bearer $RUNTOK" -H 'content-type: application/json' -d "$1" "$RUN"; echo; cat "$TMP/rbody"; echo; }
code() { head -1 <<< "$1"; }
js() { tail -n +2 <<< "$1"; }
rget() { curl -s -H "authorization: Bearer $RUNTOK" -H "x-e3d-run-token: $2" "$RUN/$1"; }
rdel() { curl -s -X DELETE -H "authorization: Bearer $RUNTOK" -H "x-e3d-run-token: $2" "$RUN/$1"; }
wait_run() { for _ in $(seq 1 300); do [[ "$(rget "$1" "$2" | jq -r '.run.status // empty')" == "$3" ]] && return 0; sleep 0.2; done; fail "run $1 did not reach $3: $(rget "$1" "$2" | jq -c '.run | {status, outcome}') engine stderr: $(tail -c 600 "$(ls -t "$SNAP"/err-*.txt 2>/dev/null | head -1)" 2>/dev/null)"; }
web_reserve() { billing reserve -H 'x-e3d-auth-version: 1' -d "$(jq -nc --arg r "$(uuidgen | tr 'A-Z' 'a-z')" '{principal:"acct_web",request_id:$r,kind:"debate",tool:"web",units:{calls:9,est_tokens:0}}')" | jq -r .reservation_id; }
web_debate() { billing _stub/web-debate -d "$(jq -nc --arg r "$1" --arg d "$2" --arg q "$Q" '{reservation_id:$r,debate_id:$d,question:$q}')" > /dev/null; }
LIM3='{"anthropic-api":300,"openai-api":300,"xai-api":300}'
LIM2='{"anthropic-api":300,"openai-api":300}'
PV3='["anthropic-api","openai-api","xai-api"]'
PV2='["anthropic-api","openai-api"]'
# body <providers json> <limits json> <attachments json> [jq filter]: a complete per-token run body with skill fields, a fresh reservation and debate id
body() {
  local r d; r="$(web_reserve)"; d="$(new_id)"; web_debate "$r" "$d"
  jq -nc --arg r "$r" --arg d "$d" --arg q "$Q" --argjson p "$1" --argjson m "$2" --argjson a "$3" --arg pr "$P" \
    '{reservation_id:$r,debate_id:$d,question:$q,providers:$p,rounds:2,max_words:300,max_tokens:$m,answer_bytes:$m,skill_attachments:$a,skills_principal:$pr,skill_bytes:4096} | '"${4:-.}"
}
OBSV='{"provider":"gemini-api","max_tokens":150,"input_bytes":20000}'
seat() { jq -nc --argjson d "$1" --arg t "$2" '{hook:"seat",target:$t,definition:$d}'; }
obsatt() { jq -nc --argjson d "$1" '{hook:"observer",definition:$d}'; }
jarr() { jq -sc '.' ; }
leaks() { # leaks <text>: no marker of any skill, and no principal, in the text
  for m in SEATMARK OBSMARK DUALMARK SNEAKMARK OTHERMARK "$P" sha256:; do assert_not_contains "$1" "$m" "leak of $m"; done
}

# ================================================================ listeners WITHOUT the capability
SKILLBODY="$(body "$PV3" "$LIM3" "[$(seat "$DA" anthropic-api)]")"
for variant in "unset:E3D_MCP_SKILLS_RUN=0" "no-v1:E3D_MCP_SKILLS_RUN=1 E3D_SKILLS_V1=0 E3D_SKILLS_HOSTED=1 E3D_SKILLS_SEATS=1" "no-hosted:E3D_MCP_SKILLS_RUN=1 E3D_SKILLS_V1=1 E3D_SKILLS_HOSTED=0 E3D_SKILLS_SEATS=1"; do
  name="${variant%%:*}"; read -r -a vars <<< "${variant#*:}"
  start_server "off-$name" "${vars[@]}"
  r="$(rpost '{}')"; assert_eq "$(js "$r" | jq -c '.capabilities')" '["per_token_v1"]' "$name: no skills_v1"
  n0="$(nrec)"
  r="$(rpost "$(body "$PV3" "$LIM3" "[$(seat "$DA" anthropic-api)]")")"
  assert_eq "$(code "$r")" "400" "$name: skills sent to a listener without skills_v1: $(js "$r")"; assert_eq "$(js "$r" | jq -r '[.code, .accepted] | join(",")')" "invalid,false"; assert_contains "$(js "$r")" "unknown field"; leaks "$(js "$r")"
  r="$(rpost "$(body "$PV3" "$LIM3" "[$(seat "$DA" anthropic-api)]" | jq -c 'del(.skill_attachments, .skills_principal, .skill_bytes) + {observer: {provider:"gemini-api",max_tokens:150,input_bytes:20000}}')")"; assert_eq "$(code "$r")" "400" "$name: observer alone"
  sleep 0.2; assert_eq "$(nrec)" "$n0" "$name: nothing ran"
done
# a plain body on the off listener: the debate arguments and environment recorded for the comparison below
start_server off-plain E3D_MCP_SKILLS_RUN=0
PLAIN_OFF="$(body "$PV3" "$LIM3" '[]' 'del(.skill_attachments, .skills_principal, .skill_bytes)')"
r="$(rpost "$PLAIN_OFF")"; assert_eq "$(code "$r")" "202" "a plain body is accepted: $(js "$r")"; wait_run "$(jq -r .debate_id <<< "$PLAIN_OFF")" "$(js "$r" | jq -r .run_token)" done
REC_OFF="$(lastrec)"
assert_eq "$(jq -r '.hs' <<< "$REC_OFF")" "" "a plain run has no skills file"
echo "ok - without skills_v1 (switch off, V1 off, HOSTED off): not advertised, every new field refused as unknown, nothing runs, a plain body runs as before"

# ================================================================ a listener WITH it
start_server on "${SKON[@]}"
r="$(rpost '{}')"; assert_eq "$(js "$r" | jq -c '.capabilities')" '["per_token_v1","skills_v1"]' "skills_v1 is advertised next to per_token_v1"
PLAIN_ON="$(body "$PV3" "$LIM3" '[]' 'del(.skill_attachments, .skills_principal, .skill_bytes)')"
r="$(rpost "$PLAIN_ON")"; assert_eq "$(code "$r")" "202"; wait_run "$(jq -r .debate_id <<< "$PLAIN_ON")" "$(js "$r" | jq -r .run_token)" done
assert_eq "$(jq -c '[.args, .hs, .env.spec, .env.omax, .env.oin]' <<< "$(lastrec)")" "$(jq -c '[.args, .hs, .env.spec, .env.omax, .env.oin]' <<< "$REC_OFF")" "switch on, no skills: the debate arguments and the variables this listener sets are identical to switch off"

# ---- 1. a seat run: two seat skills on two of three providers, the third a plain seat
: > "$VREQ"
B1="$(body "$PV3" "$LIM3" "[$(seat "$DA" anthropic-api), $(seat "$DB" openai-api)]")"; D1="$(jq -r .debate_id <<< "$B1")"
n0="$(nrec)"
r="$(rpost "$B1")"; assert_eq "$(code "$r")" "202" "accepted: $(js "$r")"; RT1="$(js "$r" | jq -r .run_token)"; wait_run "$D1" "$RT1" done
assert_eq "$(nrec)" "$((n0 + 1))"
R1="$(lastrec)"; HS1="$(jq -r .hs <<< "$R1")"
assert_eq "$(jq -r .args <<< "$R1" | sed -E 's/--synthesizer [^ ]+/--synthesizer S/')" "--question-file F --providers anthropic-api,openai-api,xai-api --rounds 2 --max-words 300 --out-dir D --synthesizer S --web-search off --builtin-only --hosted-skills H --seat-skill $SPEC_A:anthropic-api --seat-skill $SPEC_B:openai-api --fill-pool --lens-bytes-max 4096 " "the arguments the engine receives"
assert_eq "$(jq -c '.env' <<< "$R1")" '{"seats":"1","obs":"unset","v1":"1","hosted":"1","spec":"1","omax":"unset","oin":"unset"}' "the environment: seats on, no observer switch or limits"
assert_eq "$(jq -r .fm <<< "$R1")" "-rw-------" "the skills file is 0600"; assert_eq "$(jq -r .dm <<< "$R1")" "drwx------" "its directory is 0700"
[[ -n "$HS1" && ! -e "$HS1" && ! -e "$(dirname "$HS1")" ]] || fail "the skills file and its directory are gone after the run"
assert_eq "$(prompts_with SEATMARK-ALPHA)" "2" "skill A text reaches its seat in both rounds, nowhere else"
assert_eq "$(prompts_with SEATMARK-BETA)" "2" "skill B text reaches its seat in both rounds, nowhere else"
assert_eq "$(prompts_with '[Your role in this debate]')" "4" "only the two skill seats get a lens block; the plain seat and the synthesis do not"
V1="$(rget "$D1" "$RT1")"
assert_eq "$(jq -r '.run.outcome' <<< "$V1")" "ok"; leaks "$V1"
assert_eq "$(jq -c '[.run.result.positions[].provider] | sort' <<< "$V1")" '["anthropic-api","openai-api","xai-api"]' "one position per provider"
echo "ok - a seat run: --hosted-skills/--seat-skill/--fill-pool/--lens-bytes-max, the switches, a 0600 file in a 0700 directory, removed afterwards; each skill text on its own seat only"

# ---- 2. a seat plus the observer on a separate adapter, and one skill that is both
: > "$VREQ"
B2="$(body "$PV2" "$LIM2" "[$(seat "$DA" anthropic-api), $(seat "$DB" openai-api), $(obsatt "$DR")]")"
B2="$(jq -c --argjson o "$OBSV" '.observer = $o' <<< "$B2")"; D2="$(jq -r .debate_id <<< "$B2")"
r="$(rpost "$B2")"; assert_eq "$(code "$r")" "202" "accepted: $(js "$r")"; RT2="$(js "$r" | jq -r .run_token)"; wait_run "$D2" "$RT2" done
R2="$(lastrec)"
assert_eq "$(jq -r .args <<< "$R2" | sed -E 's/--synthesizer [^ ]+/--synthesizer S/')" "--question-file F --providers anthropic-api,openai-api --rounds 2 --max-words 300 --out-dir D --synthesizer S --web-search off --builtin-only --hosted-skills H --seat-skill $SPEC_A:anthropic-api --seat-skill $SPEC_B:openai-api --observer $SPEC_R:gemini-api --fill-pool --lens-bytes-max 4096 "
assert_eq "$(jq -c '.env' <<< "$R2")" '{"seats":"1","obs":"1","v1":"1","hosted":"1","spec":"1","omax":"150","oin":"20000"}' "the observer gets exactly the quoted limits through the environment"
assert_eq "$(jq -c '[.[] | select(.body.model == "gem-test")] | length' -s "$VREQ")" "1" "the observer makes exactly one vendor call"
assert_eq "$(jq -s '[.[] | select(.body.model == "gem-test")][0].body.max_tokens' "$VREQ")" "150" "that call carries the quoted output limit"
assert_eq "$(jq -s '[.[] | select(.body.model == "gem-test")][0].body.messages[0].content | length' "$VREQ" | awk '{print ($1 <= 20000) ? "fits" : "over"}')" "fits" "and a prompt within the quoted input bytes"
assert_eq "$(prompts_with OBSMARK-GAMMA)" "1" "the observer skill text reaches the observer call only"
assert_eq "$(prompts_with SEATMARK-ALPHA)" "2"; assert_eq "$(prompts_with SEATMARK-BETA)" "2"
SNAPF="$SNAP/usage-$(nrec).json"
jq -e '(map(.key) | index("observer:reviewer")) != null' "$SNAPF" >/dev/null || fail "usage.json has the observer row: $(jq -c 'map(.key)' "$SNAPF")"
jq -e '.[] | select(.key == "observer:reviewer") | .provider == "gemini-api" and .input_tokens > 0 and .output_tokens > 0' "$SNAPF" >/dev/null || fail "the observer row names its adapter and carries vendor counts"
# what the listener sends to billing: the observer row is kept (a row that fails the listener's own check is logged as "malformed usage row(s) dropped")
! grep -q 'malformed usage row' "$TMP/on.log" || fail "the observer row was dropped before the usage report: $(grep 'malformed usage row' "$TMP/on.log")"
V2="$(rget "$D2" "$RT2")"; leaks "$V2"; assert_eq "$(jq -r '.run.outcome' <<< "$V2")" "ok"
HS2="$(jq -r .hs <<< "$R2")"; [[ ! -e "$HS2" && ! -e "$(dirname "$HS2")" ]] || fail "files gone (observer run)"
echo "ok - a seat run with an observer: --observer skill:gemini-api, the quoted limits (150 tokens, 20000 bytes), one call, usage row observer:reviewer kept for billing's report"

: > "$VREQ"
B3="$(body "$PV2" "$LIM2" "[$(seat "$DA" anthropic-api), $(seat "$DUAL" openai-api), $(obsatt "$DUAL")]")"; B3="$(jq -c --argjson o "$OBSV" '.observer = $o' <<< "$B3")"; D3="$(jq -r .debate_id <<< "$B3")"
r="$(rpost "$B3")"; assert_eq "$(code "$r")" "202" "a skill that is a seat and the observer: $(js "$r")"; RT3="$(js "$r" | jq -r .run_token)"; wait_run "$D3" "$RT3" done
R3="$(lastrec)"
assert_contains "$(jq -r .args <<< "$R3")" "--seat-skill $SPEC_A:anthropic-api --seat-skill $SPEC_DUAL:openai-api --observer $SPEC_DUAL:gemini-api"
assert_eq "$(prompts_with DUALMARK-DELTA)" "3" "the one skill reaches its seat in two rounds and the observer once"
# an observer-only run
B3b="$(body "$PV2" "$LIM2" "[$(obsatt "$DR")]")"; B3b="$(jq -c --argjson o "$OBSV" '.observer = $o' <<< "$B3b")"; D3b="$(jq -r .debate_id <<< "$B3b")"
r="$(rpost "$B3b")"; assert_eq "$(code "$r")" "202" "an observer-only run: $(js "$r")"; wait_run "$D3b" "$(js "$r" | jq -r .run_token)" done
R3b="$(lastrec)"; assert_not_contains "$(jq -r .args <<< "$R3b")" "--seat-skill"; assert_not_contains "$(jq -r .args <<< "$R3b")" "--fill-pool"; assert_eq "$(jq -r .env.seats <<< "$R3b")" "unset"
# a quoted input bound too small for the smallest prompt: the observer is skipped, the debate is unaffected
: > "$VREQ"
B3c="$(body "$PV2" "$LIM2" "[$(seat "$DA" anthropic-api), $(seat "$DB" openai-api), $(obsatt "$DR")]")"; B3c="$(jq -c '.observer = {provider:"gemini-api",max_tokens:150,input_bytes:1}' <<< "$B3c")"
r="$(rpost "$B3c")"; assert_eq "$(code "$r")" "202"; wait_run "$(jq -r .debate_id <<< "$B3c")" "$(js "$r" | jq -r .run_token)" done
assert_eq "$(jq -s '[.[] | select(.body.model == "gem-test")] | length' "$VREQ")" "0" "no observer call when even the smallest prompt does not fit the quoted bound"
echo "ok - one skill as seat and observer, an observer-only run, and an observer that does not fit its quoted input bound is skipped"

# one seat skill is enough: that seat carries it, the other seats of the panel run plain (the engine takes one named skill with --fill-pool)
: > "$VREQ"
B2s="$(body "$PV3" "$LIM3" "[$(seat "$DA" anthropic-api)]")"; D2s="$(jq -r .debate_id <<< "$B2s")"
r="$(rpost "$B2s")"; assert_eq "$(code "$r")" "202" "one seat skill is accepted: $(js "$r")"; RT2s="$(js "$r" | jq -r .run_token)"; wait_run "$D2s" "$RT2s" done
R2s="$(lastrec)"
assert_contains "$(jq -r .args <<< "$R2s")" "--seat-skill $SPEC_A:anthropic-api --fill-pool"; assert_not_contains "$(jq -r .args <<< "$R2s")" "--seat-skill $SPEC_B"
assert_eq "$(prompts_with SEATMARK-ALPHA)" "2" "the one skill reaches its seat in both rounds"
assert_eq "$(prompts_with '[Your role in this debate]')" "2" "only that seat carries a lens block; the two plain seats and the synthesis do not"
assert_eq "$(jq -r '.run.outcome' <<< "$(rget "$D2s" "$RT2s")")" "ok"
echo "ok - one seat skill is enough: it sits on its seat, the others run plain"

# ---- 3. refusals: 400 invalid, nothing runs, nothing leaks
n1="$(nrec)"; v1="$(vreq_count)"; SEATB="$(seat "$DB" openai-api)"
refuse() { # refuse <label> <body>
  local r; r="$(rpost "$2")"
  assert_eq "$(code "$r")" "400" "$1: $(js "$r")"; assert_eq "$(js "$r" | jq -r '[.code, .accepted] | join(",")')" "invalid,false" "$1"
  assert_not_contains "$(js "$r")" "QCONTENT" "$1: the question is not echoed"; leaks "$(js "$r")"
  LAST_MSG="$(js "$r" | jq -r .message)"
}
refuse "tools requested" "$(body "$PV3" "$LIM3" "[$(seat "$DTOOLS" anthropic-api), $SEATB]")"; assert_contains "$LAST_MSG" "skill_capability_denied"
refuse "a definition owned by someone else" "$(body "$PV3" "$LIM3" "[$(seat "$DOTHER" anthropic-api), $SEATB]")"; assert_contains "$LAST_MSG" "skill_tenant_denied"
refuse "a wrong hash" "$(body "$PV3" "$LIM3" "[$(seat "$(jq -c '.definition_hash = "sha256:'"$(printf '0%.0s' $(seq 1 64))"'"' <<< "$DA")" anthropic-api), $SEATB]")"; assert_contains "$LAST_MSG" "skill_hash"
refuse "changed text under the old hash" "$(body "$PV3" "$LIM3" "[$(seat "$(jq -c '.instructions.method += " more"' <<< "$DA")" anthropic-api), $SEATB]")"; assert_contains "$LAST_MSG" "skill_hash"
refuse "a principal that is not the owner" "$(body "$PV3" "$LIM3" "[$(seat "$DA" anthropic-api), $SEATB]" | jq -c '.skills_principal = "u_zzzzzz999999"')"
refuse "an observer-only skill used as a seat" "$(body "$PV3" "$LIM3" "[$(seat "$DR" anthropic-api), $SEATB]")"; assert_contains "$LAST_MSG" "seat hook"
refuse "a seat-only skill used as the observer" "$(body "$PV2" "$LIM2" "[$(obsatt "$DA")]" | jq -c --argjson o "$OBSV" '.observer = $o')"; assert_contains "$LAST_MSG" "observer hook"
refuse "the same skill on two seats" "$(body "$PV3" "$LIM3" "[$(seat "$DA" anthropic-api), $(seat "$DA" openai-api)]")"
refuse "one id with two different definitions (each with a real hash)" "$(body "$PV2" "$LIM2" "[$(seat "$DUAL" anthropic-api), $(seat "$DB" openai-api), $(obsatt "$DUAL2")]" | jq -c --argjson o "$OBSV" '.observer = $o')"; assert_contains "$LAST_MSG" "skill_conflict"
refuse "more instruction text than skill_bytes" "$(body "$PV3" "$LIM3" "[$(seat "$DA" anthropic-api), $(seat "$DB" openai-api)]" | jq -c '.skill_bytes = 60')"; assert_contains "$LAST_MSG" "skill_bytes"
refuse "an observer adapter that cannot be priced" "$(body "$PV2" "$LIM2" "[$(obsatt "$DR")]" | jq -c '.observer = {provider:"or-nonexistent-voice",max_tokens:150,input_bytes:20000}')"
# review findings: refused here, before anything is held, what the engine would refuse after the hold
refuse "a seat whose prompt wrapper does not fit skill_bytes (the instruction text alone does)" "$(body "$PV3" "$LIM3" "[$(seat "$DA" anthropic-api), $(seat "$DB" openai-api)]" | jq -c '.skill_bytes = 80')"; assert_contains "$LAST_MSG" "skill_too_large"
refuse "an observer skill whose name is too long for the usage report" "$(body "$PV2" "$LIM2" "[$(obsatt "$DLONG")]" | jq -c --argjson o "$OBSV" '.observer = $o')"; assert_contains "$LAST_MSG" "usage report"
DEEP="$(python3 -c 'print("{\"a\":" * 3000 + "1" + "}" * 3000, end="")')"
BDEEP="$(body "$PV3" "$LIM3" "[$(seat "$DA" anthropic-api), $SEATB]" | jq -c '.skill_attachments[0].definition = "DEEPDEEP"')"; BDEEP="${BDEEP/\"DEEPDEEP\"/$DEEP}"
refuse "a definition nested 3000 levels deep (a 400, never a retryable 503)" "$BDEEP"; assert_contains "$LAST_MSG" "nested too deeply"
refuse "an oversized definition" "$(body "$PV3" "$LIM3" "[$(seat "$(jq -c '.pad = ("x" * 50000)' <<< "$DA")" anthropic-api), $SEATB]")"
refuse "two 40 KiB definitions (a body over the 64 KiB of a listener without skills_v1 is read, then refused for its content)" "$(body "$PV3" "$LIM3" "[$(seat "$(jq -c '.pad = ("x" * 40000)' <<< "$DA")" anthropic-api), $(seat "$(jq -c '.pad = ("y" * 40000)' <<< "$DB")" openai-api)]")"
refuse "a definition with a float" "$(body "$PV3" "$LIM3" "[$(seat "$(jq -c '.limits.timeout_ms = 1.5' <<< "$DA")" anthropic-api), $SEATB]")"
refuse "experts together with skills" "$(body "$PV3" "$LIM3" "[$(seat "$DA" anthropic-api), $SEATB]" | jq -c '.experts = [{id:"skeptic",hash:"sha256:'"$(printf 'a%.0s' $(seq 1 64))"'"},{id:"customer",hash:"sha256:'"$(printf 'b%.0s' $(seq 1 64))"'"}] | .lens_bytes = 640')"
refuse "an unknown key in an attachment" "$(body "$PV3" "$LIM3" "[$(seat "$DA" anthropic-api | jq -c '.attachment_id = "a1"'), $SEATB]")"
refuse "a seat target outside the providers" "$(body "$PV3" "$LIM3" "[$(seat "$DA" gemini-api), $SEATB]")"
refuse "observer limits without an observer attachment" "$(body "$PV3" "$LIM3" "[$(seat "$DA" anthropic-api), $SEATB]" | jq -c --argjson o "$OBSV" '.observer = $o')"
refuse "an observer attachment without observer limits" "$(body "$PV2" "$LIM2" "[$(obsatt "$DR")]")"
sleep 0.3; assert_eq "$(nrec)" "$n1" "no debate was started for any refused body"; assert_eq "$(vreq_count)" "$v1" "no vendor call for any refused body"
echo "ok - refused (400 invalid) before any run or model call, with a stable skill_* code and no skill text: tools, owner, hash, hook, duplicates, bytes, adapter, size, experts together, unknown keys"

# ---- 4. idempotency
r="$(rpost "$B1")"; assert_eq "$(code "$r")" "200" "identical retry: existing"; assert_eq "$(js "$r" | jq -r '.run_token == "'"$RT1"'"')" "true"
n2="$(nrec)"
r="$(rpost "$(jq -c '.skill_attachments[0].definition.description = "a changed description"' <<< "$B1")")"
assert_eq "$(code "$r")" "409" "a changed definition is a conflict: $(js "$r")"
r="$(rpost "$(jq -c '.skill_bytes = 4097' <<< "$B1")")"; assert_eq "$(code "$r")" "409" "skill_bytes is part of the key"
r="$(rpost "$(jq -c '.skill_attachments |= reverse' <<< "$B1")")"; assert_eq "$(code "$r")" "409" "attachment order is part of the key"
r="$(rpost "$(jq -c '.skills_principal = "u_abc123def457"' <<< "$B1")")"; assert_eq "$(code "$r")" "409" "the principal is part of the key"
r="$(rpost "$B2" )"; assert_eq "$(code "$r")" "200" "an identical observer retry is the same run"
r="$(rpost "$(jq -c '.observer.max_tokens = 151' <<< "$B2")")"; assert_eq "$(code "$r")" "409" "the observer limits are part of the key"
assert_eq "$(nrec)" "$n2" "no second run for any retry"
echo "ok - an identical retry returns the existing run; a changed definition, bytes, order, principal or observer limit is a conflict"

# ---- 5. nothing about the skills is kept or logged
sleep 0.2
! grep -rq 'SEATMARK\|OBSMARK\|DUALMARK' "$TMP"/state-on 2>/dev/null || fail "a finished run keeps no skill text in the stored state: $(grep -rl 'SEATMARK\|OBSMARK\|DUALMARK' "$TMP"/state-on | head -2)"
! grep -q 'SEATMARK\|OBSMARK\|DUALMARK\|SNEAKMARK\|OTHERMARK' "$TMP/on.log" || fail "the server log carries skill text"
! grep -q "$P" "$TMP/on.log" || fail "the server log carries the principal"
grep -q 'skills: hosted run seats=2 observer=0 skills=2 digest=[0-9a-f]\{16\}' "$TMP/on.log" || fail "the log says how many skills, and a digest: $(grep skills: "$TMP/on.log" | head -3)"
echo "ok - the stored state and the log carry counts and a digest only"

# ---- 6. the engine refuses a definition that changed after planning: before any call, nothing charged, nothing leaked, files gone
start_server tamper "${SKON[@]}" WRAP_TAMPER=1
: > "$VREQ"; n3="$(nrec)"
BT="$(body "$PV3" "$LIM3" "[$(seat "$DA" anthropic-api), $SEATB]")"; DT="$(jq -r .debate_id <<< "$BT")"
r="$(rpost "$BT")"; assert_eq "$(code "$r")" "202"; RTT="$(js "$r" | jq -r .run_token)"; wait_run "$DT" "$RTT" failed
VT="$(rget "$DT" "$RTT")"; assert_eq "$(jq -r '.run.outcome' <<< "$VT")" "error"; leaks "$VT"
assert_eq "$(nrec)" "$((n3 + 1))" "the engine was started"; assert_eq "$(vreq_count)" "0" "and made no model call"
assert_eq "$(jq -r '.run.credits_charged // 0' <<< "$VT")" "0" "nothing charged"
HST="$(jq -r .hs <<< "$(lastrec)")"; [[ ! -e "$HST" && ! -e "$(dirname "$HST")" ]] || fail "files gone after an engine refusal"
! grep -q 'SEATMARK\|tampered' "$TMP/tamper.log" || fail "the log carries skill text after an engine refusal"
echo "ok - an engine refusal (definition changed after planning) fails the run before any model call, charges nothing and leaks nothing"

# ---- 7. a cancelled run removes its files
start_server hang "${SKON[@]}" WRAP_HANG=1
n4="$(nrec)"
BH="$(body "$PV3" "$LIM3" "[$(seat "$DA" anthropic-api), $SEATB]")"; DH="$(jq -r .debate_id <<< "$BH")"
r="$(rpost "$BH")"; assert_eq "$(code "$r")" "202"; RTH="$(js "$r" | jq -r .run_token)"
for _ in $(seq 1 100); do [[ "$(nrec)" == "$((n4 + 1))" ]] && break; sleep 0.1; done
HSH="$(jq -r .hs <<< "$(lastrec)")"
[[ -n "$HSH" && -f "$HSH" ]] || fail "the skills file exists while the run is going"
assert_eq "$(jq -r .fm <<< "$(lastrec)")" "-rw-------"
rdel "$DH" "$RTH" > /dev/null
wait_run "$DH" "$RTH" failed
for _ in $(seq 1 50); do [[ ! -e "$(dirname "$HSH")" ]] && break; sleep 0.1; done
[[ ! -e "$HSH" && ! -e "$(dirname "$HSH")" ]] || fail "the skills file and its directory are gone after a cancelled run"
assert_eq "$(jq -r '.run.outcome' <<< "$(rget "$DH" "$RTH")")" "error"
echo "ok - a cancelled run removes the skills file and its directory"

# ---- 8. a process killed in the middle of a skills run: the restart scrubs the skill text from the stored state, sweeps the stale private file, and (switch now off) does not run skills
start_server crash "${SKON[@]}" WRAP_HANG=1
CRASHPID="${PIDS[$((${#PIDS[@]} - 1))]}"
n5="$(nrec)"
BC="$(body "$PV3" "$LIM3" "[$(seat "$DA" anthropic-api), $SEATB]")"; DC="$(jq -r .debate_id <<< "$BC")"
r="$(rpost "$BC")"; assert_eq "$(code "$r")" "202"; RTC="$(js "$r" | jq -r .run_token)"
for _ in $(seq 1 100); do [[ "$(nrec)" == "$((n5 + 1))" ]] && break; sleep 0.1; done
HSC="$(jq -r .hs <<< "$(lastrec)")"; [[ -f "$HSC" ]] || fail "the skills file exists while the run is going"
grep -rq 'SEATMARK-ALPHA' "$TMP/state-crash" || fail "while a run is queued or running its definitions are in its state (that is how a restart can resume it)"
kill -9 "$CRASHPID" 2>/dev/null || true; pkill -f "$TMP/wrap.sh" 2>/dev/null || true; sleep 0.5
[[ -f "$HSC" ]] || fail "a killed process leaves its private file behind (the thing the sweep is for)"
# the file is older than the sweep's margin (6 hours)
node -e 'const fs=require("fs"); const t=(Date.now()-7*3600*1000)/1000; fs.utimesSync(process.argv[1], t, t)' "$(dirname "$HSC")"
# a young directory with a file is NOT swept
YOUNG="$(mktemp -d "${TMPDIR:-/tmp}/e3d-mcp-XXXXXX")"; chmod 700 "$YOUNG"; echo '{}' > "$YOUNG/hosted-skills.json"
# restart on the same state, the skills switch now OFF: the recovered run does not run skills, its state is scrubbed
start_server crash E3D_MCP_SKILLS_RUN=0
for _ in $(seq 1 100); do [[ "$(rget "$DC" "$RTC" | jq -r '.run.status // empty')" == failed ]] && break; sleep 0.2; done
! grep -rq 'SEATMARK-ALPHA' "$TMP/state-crash" || fail "after a restart no definition text remains in the stored state: $(grep -rl 'SEATMARK-ALPHA' "$TMP/state-crash" | head -2)"
echo "ok - a killed process: the restart ends the run and scrubs the skill text from the stored state"
# the sweep runs when skills are ON at start: the old private file is removed (the directory is not), a young one is kept
start_server crash2 "${SKON[@]}"
for _ in $(seq 1 50); do [[ ! -e "$HSC" ]] && break; sleep 0.1; done
[[ ! -e "$HSC" ]] || fail "the stale private skills file is swept at start"
assert_contains "$(cat "$TMP/crash2.log")" "swept 1 stale hosted-skills file"
[[ -f "$YOUNG/hosted-skills.json" ]] || fail "a young run directory (a run in progress) is never swept"
rm -rf "$YOUNG"
echo "ok - the stale private skills file left by a killed process is swept at start (old, private and ours only)"
rm -rf "$(dirname "$HSC")"
echo "mcp-skills-run: all passed"
