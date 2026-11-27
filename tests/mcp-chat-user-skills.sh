#!/usr/bin/env bash
set -euo pipefail

# One hosted user skill in a chat (chat_user_skills_v1; cloud docs/skills-chat-plan.md section 7). Unit checks of the runner and the route
# (tests/fixtures/chat-user-skills-test.mjs), then the real bin/e3d-mcp: the switch validated at startup, the capability advertised only with it, stale
# e3d-chat-* temp dirs swept at start, and a chat with a skill through the real openai-api adapter against a fake vendor. No model, no network beyond
# 127.0.0.1, no real key. The skill text carries a marker that must reach the vendor once and never a log.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-assert_eq}: expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "${3:-assert_contains}: expected to find [$2] in [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "${3:-assert_not_contains}: did not expect [$2] in [$1]"; }

node "$ROOT/tests/fixtures/chat-user-skills-test.mjs" | tee "$TMP/unit.out"
assert_contains "$(cat "$TMP/unit.out")" "chat user skills unit tests:"

# ---------------------------------------------------------------- a definition built like a hosted service builds it
P=u_abc123def456
node "$ROOT/tests/fixtures/skills/hosted-make.mjs" "$TMP/d.json" "$P" '[{"name":"artist","body":"CUSMARK-SEAT. Answer like a painter would.","hooks":["seat"]}]'
DEF="$(jq -c '.skills[0]' "$TMP/d.json")"

# ---------------------------------------------------------------- fake vendor and the reference billing stub
VREQ="$TMP/vendor.jsonl"; : > "$VREQ"
FAKE_ANSWER='A painterly sunset.' node "$ROOT/tests/fixtures/fake-vendor.mjs" "$VREQ" "$TMP/vendor.port" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$TMP/vendor.port" ]] && break; sleep 0.05; done
VP="$(cat "$TMP/vendor.port")"
SVC="svc-MARKER-$(openssl rand -hex 12)"
RUNTOK="runtok-MARKER-$(openssl rand -hex 16)"
TOK_A="caller-MARKER-a-$(openssl rand -hex 12)"
jq -n --arg a "$TOK_A" '{accounts: [{principal: "acct_web", balance: 1000000, keys: [{id: "key-a", token: $a}]}]}' > "$TMP/seed.json"
env STUB_SERVICE_TOKEN="$SVC" STUB_SEED="$TMP/seed.json" STUB_URL_FILE="$TMP/stub.url" STUB_FEATURES="finalize,fetch,authorize-run" STUB_PRICING=1 node "$ROOT/examples/external-auth-stub.js" > "$TMP/stub.out" 2> "$TMP/stub.log" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$TMP/stub.url" ]] && break; sleep 0.05; done
URL="$(cat "$TMP/stub.url")"

SERVER="$ROOT/bin/e3d-mcp"
BASE_ENV=(E3D_MCP_AUTH_URL="$URL" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" TYPESAFE_API_KEY="" E3D_MCP_PRINCIPAL="" E3D_MCP_AUTH_HEALTH_SEC=1
  E3D_MCP_PRICING=per_token E3D_MCP_CUSTOMER_LIMITS='rounds=2,max_words=300,providers=4' E3D_DEBATE_WEB_SEARCH=off
  OPENAI_API_KEY=k-oai OPENAI_API_BASE_URL="http://127.0.0.1:$VP/v1" OPENAI_API_MODEL=gpt-test OPENAI_API_TIMEOUT=5
  E3D_MCP_CHAT=1 E3D_MCP_CHAT_PROVIDERS=openai-api)
SKON=(E3D_MCP_SKILLS_RUN=1 E3D_SKILLS_V1=1 E3D_SKILLS_HOSTED=1 E3D_SKILLS_SEATS=1)

# ---------------------------------------------------------------- the switch at startup
out="$(env "${BASE_ENV[@]}" "${SKON[@]}" E3D_MCP_CHAT_USER_SKILLS=2 E3D_MCP_STATE_DIR="$TMP/state-bad" "$SERVER" --http --port 0 2>&1)" && fail "E3D_MCP_CHAT_USER_SKILLS=2 must refuse to start" || true
assert_contains "$out" "E3D_MCP_CHAT_USER_SKILLS must be unset, 0 or 1"
out="$(env "${BASE_ENV[@]}" E3D_MCP_CHAT_USER_SKILLS=1 E3D_MCP_STATE_DIR="$TMP/state-bad" "$SERVER" --http --port 0 2>&1)" && fail "the switch without skill seats must refuse to start" || true
assert_contains "$out" "E3D_MCP_CHAT_USER_SKILLS=1 needs hosted skill seats"
out="$(env "${BASE_ENV[@]}" "${SKON[@]}" E3D_SKILLS_SEATS=0 E3D_SKILLS_OBSERVER=1 E3D_MCP_CHAT_USER_SKILLS=1 E3D_MCP_STATE_DIR="$TMP/state-bad" "$SERVER" --http --port 0 2>&1)" && fail "observer alone is not seats" || true
assert_contains "$out" "E3D_MCP_CHAT_USER_SKILLS=1 needs hosted skill seats"
out="$(env "${BASE_ENV[@]}" "${SKON[@]}" E3D_MCP_CHAT= E3D_MCP_CHAT_USER_SKILLS=1 E3D_MCP_STATE_DIR="$TMP/state-bad" "$SERVER" --http --port 0 2>&1)" && fail "the switch without the chat run must refuse to start" || true
assert_contains "$out" "E3D_MCP_CHAT_USER_SKILLS=1 needs the chat run"
echo "ok - the switch is validated at startup (0/1; needs E3D_MCP_CHAT=1 and the skills-run seats switch)"

# ---------------------------------------------------------------- listeners
# each listener gets its own short temporary directory, so the sweep at start can be seen
start_server() { # start_server <name> [VAR=value ...]
  local name="$1"; shift
  : > "$TMP/$name.port"; : > "$TMP/$name.runport"; mkdir -p "$TMP/t-$name"
  env "${BASE_ENV[@]}" TMPDIR="$TMP/t-$name" E3D_MCP_STATE_DIR="$TMP/state-$name" E3D_MCP_PORT_FILE="$TMP/$name.port" E3D_MCP_RUN_PORT=0 E3D_MCP_RUN_PORT_FILE="$TMP/$name.runport" E3D_MCP_RUN_TOKEN="$RUNTOK" "$@" \
    "$SERVER" --http --port 0 2>> "$TMP/$name.log" &
  PIDS+=("$!")
  for _ in $(seq 1 100); do [[ -s "$TMP/$name.runport" ]] && break; sleep 0.1; done
  [[ -s "$TMP/$name.runport" ]] || { cat "$TMP/$name.log" >&2; fail "server $name did not start"; }
  RUNBASE="http://127.0.0.1:$(cat "$TMP/$name.runport")/internal"
  # the health answer (a 400 to an empty run request) needs the billing features, which the listener learns on its first authenticated call
  curl -s -o /dev/null -X POST -H 'content-type: application/json' -H 'accept: application/json' -H "Authorization: Bearer $TOK_A" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"chat-user-skills-test","version":"0"}}}' "http://127.0.0.1:$(cat "$TMP/$name.port")/mcp"
  for _ in $(seq 1 100); do curl -s -X POST -H "authorization: Bearer $RUNTOK" -H 'content-type: application/json' -d '{}' "$RUNBASE/runs" | jq -e '.capabilities' > /dev/null && break; sleep 0.1; done
}
rpost() { curl -s -o "$TMP/rbody" -w '%{http_code}' -X POST -H "authorization: Bearer $RUNTOK" -H 'content-type: application/json' -d "$2" "$RUNBASE/$1"; echo; cat "$TMP/rbody"; echo; }
code() { head -1 <<< "$1"; }
js() { tail -n +2 <<< "$1"; }
chatbody() { jq -nc --arg id "$1" --argjson d "$DEF" --arg p "$P" '{request_id:$id,provider:"openai-api",max_tokens:300,messages:[{role:"user",text:"Describe a sunset."}],skill_attachments:[{hook:"seat",definition:$d}],skills_principal:$p,skill_bytes:4096}'; }
plainbody() { jq -nc --arg id "$1" '{request_id:$id,provider:"openai-api",max_tokens:300,messages:[{role:"user",text:"Describe a sunset."}]}'; }
vcount() { jq -c --arg s "$1" 'select((.body.messages // []) | map(.content | tostring) | join(" ") | contains($s))' "$VREQ" | wc -l | tr -d ' '; }

# a stale chat dir (as a killed process leaves it) in the "on" listener's temp dir, plus a recent one that must stay
mkdir -p "$TMP/t-on/e3d-chat-Stale1" "$TMP/t-on/e3d-chat-Fresh1"
printf 'CUSMARK-LEFTOVER' > "$TMP/t-on/e3d-chat-Stale1/prompt.md"; printf 'x' > "$TMP/t-on/e3d-chat-Fresh1/prompt.md"
chmod 700 "$TMP/t-on/e3d-chat-Stale1" "$TMP/t-on/e3d-chat-Fresh1"
touch -t 202001010000 "$TMP/t-on/e3d-chat-Stale1"

start_server off "${SKON[@]}"
r="$(rpost runs '{}')"; assert_eq "$(js "$r" | jq -c '.capabilities')" '["per_token_v1","skills_v1","chat_v1"]' "switch off: no chat_user_skills_v1"
: > "$VREQ"
r="$(rpost chats "$(chatbody c-off-1)")"
assert_eq "$(code "$r")" "409" "switch off: $(js "$r")"; assert_eq "$(js "$r" | jq -r .code)" "skills_unavailable"
assert_eq "$(wc -l < "$VREQ" | tr -d ' ')" "0" "switch off: nothing was called"
P_OFF="$(rpost chats "$(plainbody plain-1)")"
assert_eq "$(code "$P_OFF")" "200" "a plain chat: $(js "$P_OFF")"
echo "ok - switch off: not advertised, a skill message is 409 skills_unavailable with no call, a plain chat runs"

start_server on "${SKON[@]}" E3D_MCP_CHAT_USER_SKILLS=1
r="$(rpost runs '{}')"; assert_eq "$(js "$r" | jq -c '.capabilities')" '["per_token_v1","skills_v1","chat_v1","chat_user_skills_v1"]' "switch on: chat_user_skills_v1 is advertised"
[[ ! -e "$TMP/t-on/e3d-chat-Stale1" ]] || fail "the stale chat dir was not swept at start"
[[ -f "$TMP/t-on/e3d-chat-Fresh1/prompt.md" ]] || fail "a recent chat dir was swept"
assert_contains "$(cat "$TMP/on.log")" "swept 1 stale chat temp directory"
echo "ok - switch on: chat_user_skills_v1 advertised; a stale e3d-chat-* dir swept at start, a recent one kept"

P_ON="$(rpost chats "$(plainbody plain-1)")"
assert_eq "$P_ON" "$P_OFF" "no skill: the plain chat answer is byte for byte the same with the switch on"
: > "$VREQ"
r="$(rpost chats "$(chatbody c-on-1)")"
assert_eq "$(code "$r")" "200" "a chat with a skill: $(js "$r")"; assert_eq "$(js "$r" | jq -r .answer)" "A painterly sunset."
assert_eq "$(vcount CUSMARK-SEAT)" "1" "the skill text reached the vendor once"
assert_eq "$(vcount '[Skill: artist. Guidance on how to answer')" "1" "inside the chat skill block"
r2="$(rpost chats "$(chatbody c-on-1)")"; assert_eq "$r2" "$r" "a retry is answered from memory"
assert_eq "$(wc -l < "$VREQ" | tr -d ' ')" "1" "with no second call"
r="$(rpost chats "$(chatbody c-on-2 | jq -c '.skill_attachments[0].definition.instructions.method += " changed"')")"
assert_eq "$(code "$r")" "400" "hash mismatch"; assert_eq "$(js "$r" | jq -r .code)" "invalid"
r="$(rpost chats "$(chatbody c-on-3 | jq -c '.skills_principal = "u_zzzzzz999999"')")"
assert_eq "$(code "$r")" "400" "foreign principal"
assert_eq "$(wc -l < "$VREQ" | tr -d ' ')" "1" "refusals call nothing"
DIGEST="$(node --input-type=module -e "import { intakeDigest } from '$ROOT/lib/skills/intake.mjs'; console.log(intakeDigest(JSON.parse(process.argv[1])))" "$DEF")"
assert_contains "$(cat "$TMP/on.log")" "chat: openai-api user skill $DIGEST" "the log names the intake digest"
for f in "$TMP/on.log" "$TMP/off.log"; do
  assert_not_contains "$(cat "$f")" "CUSMARK" "no skill text in $(basename "$f")"
  assert_not_contains "$(cat "$f")" "Describe a sunset" "no message text in $(basename "$f")"
  assert_not_contains "$(cat "$f")" "$P" "no principal in $(basename "$f")"
done
[[ -z "$(find "$TMP/t-on" -maxdepth 1 -name 'e3d-chat-*' ! -name 'e3d-chat-Fresh1')" ]] || fail "a chat temp dir was left behind"
echo "ok - the real listener: a skill chat reaches the vendor once inside the block, retries are free, hash and principal refusals call nothing, logs carry the digest only, no temp dir left"

echo "mcp-chat-user-skills: ok"
