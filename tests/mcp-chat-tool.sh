#!/usr/bin/env bash
set -euo pipefail

# e3d_chat_quote and e3d_chat through the hosted MCP, agent mode (billing's docs/mcp-chat-spec.md; E3D_MCP_CHAT_TOOL=1): the switch, the tool surface, argument
# validation (nothing invalid reaches billing), the quote and send relay, idempotent retries, the continued chat, billing's errors mapped to the catalog, and the
# listing of chat providers. Billing is the reference stub (examples/external-auth-stub.js, STUB_AGENT_CHAT=1). No network beyond 127.0.0.1, no real keys, no model.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-assert_eq}: expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "${3:-assert_contains}: expected to find [$2] in [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "${3:-assert_not_contains}: did not expect [$2] in [$1]"; }

# ---------------------------------------------------------------- unit level (no server)
node --input-type=module - "$ROOT" <<'JS'
import { pathToFileURL } from 'node:url';
const root = process.argv[2];
const c = await import(pathToFileURL(`${root}/lib/mcp/agent-chat.js`).href);
const a = await import(pathToFileURL(`${root}/lib/mcp/agent.js`).href);
const fail = (m) => { console.error(`FAIL: ${m}`); process.exit(1); };
const eq = (x, y, w) => { if (JSON.stringify(x) !== JSON.stringify(y)) fail(`${w}: ${JSON.stringify(x)} != ${JSON.stringify(y)}`); };
// the switch
eq(c.chatToolFrom({}).on, false, 'unset: off'); eq(c.chatToolFrom({ E3D_MCP_CHAT_TOOL: '0' }).on, false, '0: off'); eq(c.chatToolFrom({ E3D_MCP_CHAT_TOOL: '1' }).on, true, '1: on');
eq(c.chatToolFrom({ E3D_MCP_CHAT_TOOL: 'yes' }).ok, false, 'junk refused');
// the arguments
const ck = (args, send = false) => c.checkChatArgs(args, { send });
const ok = ck({ message: 'hi', model: 'anthropic-api' });
eq([ok.error, ok.fields], [undefined, { message: 'hi', model: 'anthropic-api' }], 'minimal quote args');
const KEY = 'key-0123456789';
const sent = ck({ message: 'hi', model: 'openai-api', chat_id: 'cht_' + 'a'.repeat(24), web_search: true, skills: ['skeptic'], quote_id: 'qt_' + 'b'.repeat(32), idempotency_key: KEY }, true);
eq(Object.keys(sent.fields).sort(), ['chat_id', 'idempotency_key', 'message', 'model', 'quote_id', 'skills', 'web_search'], 'full send args');
for (const [args, send, code] of [
  [{ model: 'anthropic-api' }, false, 'invalid_request'], [{ message: '   ', model: 'anthropic-api' }, false, 'invalid_request'], [{ message: 'x'.repeat(20001), model: 'anthropic-api' }, false, 'invalid_request'],
  [{ message: 'hi' }, false, 'invalid_request'], [{ message: 'hi', model: 'Bad Model' }, false, 'invalid_request'], [{ message: 'hi', model: 'anthropic-api', extra: 1 }, false, 'invalid_request'],
  [{ message: 'hi', model: 'anthropic-api', chat_id: 'nope' }, false, 'invalid_request'], [{ message: 'hi', model: 'anthropic-api', web_search: 'yes' }, false, 'invalid_request'],
  [{ message: 'hi', model: 'anthropic-api', skills: 'skeptic' }, false, 'invalid_skills'], [{ message: 'hi', model: 'anthropic-api', skills: ['Bad Name'] }, false, 'invalid_skills'],
  [{ message: 'hi', model: 'anthropic-api', quote_id: 'qt_' + 'b'.repeat(32) }, false, 'invalid_request'],
  [{ message: 'hi', model: 'anthropic-api' }, true, 'idempotency_key_invalid'], [{ message: 'hi', model: 'anthropic-api', idempotency_key: 'short' }, true, 'idempotency_key_invalid'],
  [{ message: 'hi', model: 'anthropic-api', idempotency_key: KEY, quote_id: 'not-a-quote' }, true, 'invalid_request'],
]) eq(ck(args, send).error?.code, code, JSON.stringify(args).slice(0, 80));
eq(ck({ message: '\ud800', model: 'anthropic-api' }).error?.code, 'invalid_request', 'a lone surrogate is refused');
// the codes
for (const code of ['chat_not_found', 'chat_busy', 'chat_full', 'too_many_chats', 'model_unavailable', 'invalid_skills', 'skills_unavailable', 'chat_failed']) if (!a.ERROR_CODES.includes(code)) fail(`catalog lacks ${code}`);
eq([a.agentError('chat_busy').retryable, a.agentError('chat_busy').retry_after_seconds, a.agentError('chat_failed').retryable, a.agentError('chat_not_found').retryable], [true, 5, false, false], 'statuses');
// results
const r = c.chatResult({ status: 'done', chat_id: 'cht_' + 'a'.repeat(24), message_id: 'dbt_' + 'c'.repeat(24), model: 'chat-model', searched: false, skills: [], cost: { credits: 2, quoted_max: 3 }, answer: 'The answer.' });
eq([r.structuredContent.answer, r.structuredContent.cost, r.structuredContent.notice === c.CHAT_NOTICE], ['The answer.', { credits: 2, quoted_max: 3 }, true], 'result');
if (!r.content[0].text.includes('untrusted data')) fail('the result text must say the answer is untrusted');
eq(c.validChatSend({ status: 'done', chat_id: 'x' }), false, 'a send answer without ids is not valid');
console.log('chat tool unit tests: ok');
JS
echo "ok - unit: switch, argument validation, codes, results"

# ---------------------------------------------------------------- the fake billing and the server
STUB="$ROOT/examples/external-auth-stub.js"
SERVER="$ROOT/bin/e3d-mcp"
SVC="svc-MARKER-$(openssl rand -hex 12)"
TOK_A="caller-MARKER-a-$(openssl rand -hex 12)"
TOK_B="caller-MARKER-b-$(openssl rand -hex 12)"
jq -n --arg a "$TOK_A" --arg b "$TOK_B" '{accounts: [{principal: "acct_a", balance: 1000000, keys: [{id: "key-a", token: $a}]}, {principal: "acct_b", balance: 1000000, keys: [{id: "key-b", token: $b}]}]}' > "$TMP/seed.json"
URL=""
start_stub() { # start_stub <name> [VAR=value ...]  sets URL
  local name="$1"; shift
  rm -f "$TMP/$name.url"
  env STUB_SERVICE_TOKEN="$SVC" STUB_SEED="$TMP/seed.json" STUB_URL_FILE="$TMP/$name.url" STUB_FEATURES="finalize,fetch,authorize-run" STUB_PRICING=1 STUB_AGENT=1 STUB_AGENT_CHAT=1 STUB_QUOTE_MAX_CREDITS=40 "$@" node "$STUB" > "$TMP/$name.out" 2> "$TMP/$name.stub.log" &
  PIDS+=("$!")
  for _ in $(seq 1 100); do [[ -s "$TMP/$name.url" ]] && break; sleep 0.05; done
  URL="$(cat "$TMP/$name.url")"
}
ledger() { curl -fsS -H "authorization: Bearer $SVC" "$URL/_stub/state"; }
inject() { curl -fsS -X POST -H "authorization: Bearer $SVC" -H 'content-type: application/json' -d "$1" "$URL/_stub/agent-inject" > /dev/null; }
bodies() { curl -fsS -H "authorization: Bearer $SVC" "$URL/_stub/chat-bodies"; }
n_agent() { ledger | jq --arg r "$1" '.received["agent_" + $r] // 0'; }

DEBATE="$TMP/stub-debate"
printf '#!/usr/bin/env bash\nexit 0\n' > "$DEBATE"; chmod +x "$DEBATE"
start_server() { # start_server <name> [VAR=value ...]   (uses the current $URL)
  local name="$1"; shift
  : > "$TMP/$name.port"
  env E3D_MCP_AUTH_URL="$URL" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" E3D_MCP_DEBATE_BIN="$DEBATE" TYPESAFE_API_KEY="" E3D_MCP_PRINCIPAL="" E3D_MCP_AUTH_CACHE_SEC=1 E3D_MCP_TIMEOUT_SEC=20 \
    E3D_MCP_AUTH_HEALTH_SEC=1 E3D_MCP_RATE_PER_MIN=100000 E3D_MCP_PRICING=per_token E3D_MCP_CUSTOMER_LIMITS='rounds=2,max_words=300,providers=3' \
    E3D_MCP_STATE_DIR="$TMP/state-$name" E3D_MCP_PORT_FILE="$TMP/$name.port" "$@" "$SERVER" --http --port 0 2>> "$TMP/$name.log" &
  PIDS+=("$!")
  for _ in $(seq 1 100); do [[ -s "$TMP/$name.port" ]] && break; sleep 0.1; done
  [[ -s "$TMP/$name.port" ]] || { cat "$TMP/$name.log" >&2; fail "server $name did not start"; }
}
J=(-H 'content-type: application/json' -H 'accept: application/json')
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"chat-tool-test","version":"0"}}}'
mcp() { curl -s -m 60 -X POST "${J[@]}" -H "Authorization: Bearer ${TOK:-$TOK_A}" ${3:+-H "mcp-session-id: $3"} -d "$2" "http://127.0.0.1:$(cat "$TMP/$1.port")/mcp"; }
sid_of() { curl -s -D "$TMP/h" -o "$TMP/init.body" -X POST "${J[@]}" -H "Authorization: Bearer ${TOK:-$TOK_A}" -d "$INIT" "http://127.0.0.1:$(cat "$TMP/$1.port")/mcp"; grep -i '^mcp-session-id:' "$TMP/h" | sed -E 's/^[^:]+: *//' | tr -d '\r'; }
tool() { mcp "$1" "$(jq -nc --arg n "$3" --argjson a "$4" '{jsonrpc:"2.0",id:7,method:"tools/call",params:{name:$n,arguments:$a}}')" "$2"; }
list() { mcp "$1" '{"jsonrpc":"2.0","id":3,"method":"tools/list"}' "$2"; }
MSG="CHATMARK what is a monad?"
KEYA="key-$(openssl rand -hex 8)"

# ---------------------------------------------------------------- refusals to start
out="$(env E3D_MCP_CHAT_TOOL=yes "$SERVER" --http --port 0 2>&1 </dev/null)" && fail "junk E3D_MCP_CHAT_TOOL must be refused" || true
assert_contains "$out" "E3D_MCP_CHAT_TOOL must be unset, 0 or 1"
out="$(env E3D_MCP_CHAT_TOOL=1 "$SERVER" 2>&1 </dev/null)" && fail "E3D_MCP_CHAT_TOOL=1 needs the agent contract (stdio has none)" || true
assert_contains "$out" "needs the agent contract"
echo "ok - E3D_MCP_CHAT_TOOL refuses junk and refuses to start without the agent contract"

# ---------------------------------------------------------------- flag off: the surface is exactly as before
start_stub plain
start_server off
SID="$(sid_of off)"
tl="$(list off "$SID")"
assert_eq "$(jq -c '[.result.tools[].name | select(startswith("e3d_chat"))]' <<< "$tl")" "[]" "no chat tools with the flag off"
assert_not_contains "$(jq -r .result.instructions "$TMP/init.body")" "e3d_chat" "no chat paragraph with the flag off"
res="$(tool off "$SID" e3d_chat "$(jq -nc --arg m "$MSG" --arg k "$KEYA" '{message:$m,model:"anthropic-api",idempotency_key:$k}')")"
assert_contains "$(jq -r '.error.message // .result.content[0].text' <<< "$res")" "unknown tool"
assert_eq "$(n_agent chat/send)" "0" "nothing reached billing"
echo "ok - flag off: no chat tools, no instruction paragraph, a call is an unknown tool, nothing reached billing"

# ---------------------------------------------------------------- flag on
start_server on E3D_MCP_CHAT_TOOL=1
SID="$(sid_of on)"
tl="$(list on "$SID")"
assert_eq "$(jq -c '[.result.tools[].name | select(startswith("e3d_chat"))] | sort' <<< "$tl")" '["e3d_chat","e3d_chat_quote"]' "both chat tools listed"
assert_eq "$(jq -c '[.result.tools[] | select(.name=="e3d_chat") | .inputSchema.required] | .[0]' <<< "$tl")" '["message","model","idempotency_key"]' "e3d_chat requires message, model, idempotency_key"
assert_eq "$(jq -c '[.result.tools[] | select(.name=="e3d_chat_quote") | .annotations.readOnlyHint]' <<< "$tl")" "[true]" "the quote is read-only"
assert_contains "$(jq -r .result.instructions "$TMP/init.body")" "e3d_chat asks ONE model one question" "the instruction paragraph"
assert_contains "$(jq -r .result.instructions "$TMP/init.body")" "untrusted data" "and it says the answer is untrusted"
echo "ok - flag on: both tools listed with their schemas, the instruction paragraph added"

# invalid arguments never reach billing
for args in '{"model":"anthropic-api"}' '{"message":"hi"}' '{"message":"hi","model":"anthropic-api","web_search":"yes"}' '{"message":"hi","model":"anthropic-api","skills":"x"}' '{"message":"hi","model":"anthropic-api","bogus":1}'; do
  res="$(tool on "$SID" e3d_chat_quote "$args")"
  [[ "$(jq -r '.result.isError' <<< "$res")" == "true" ]] || fail "quote args $args must be refused: $res"
done
res="$(tool on "$SID" e3d_chat "$(jq -nc --arg m "$MSG" '{message:$m,model:"anthropic-api"}')")"
assert_eq "$(jq -r '.result.structuredContent.error.code' <<< "$res")" "idempotency_key_invalid" "a send needs a key"
assert_eq "$(n_agent chat/quote)$(n_agent chat/send)" "00" "nothing invalid reached billing"
echo "ok - invalid arguments are refused here and never reach billing"

# quote, then send
q="$(tool on "$SID" e3d_chat_quote "$(jq -nc --arg m "$MSG" '{message:$m,model:"anthropic-api"}')")"
assert_eq "$(jq -r '.result.isError // false' <<< "$q")" "false" "quote ok: $q"
QID="$(jq -r '.result.structuredContent.quote_id' <<< "$q")"
[[ "$QID" =~ ^qt_[0-9a-f]{32}$ ]] || fail "quote id: $QID"
assert_eq "$(jq -r '.result.structuredContent.max_credits' <<< "$q")" "3" "max credits"
assert_eq "$(jq -r '.result.structuredContent.search_enabled' <<< "$q")" "false" "web search off by default"
assert_contains "$(jq -r '.result.content[0].text' <<< "$q")" "Nothing was spent" "the quote says nothing was spent"
SEND="$(jq -nc --arg m "$MSG" --arg k "$KEYA" --arg q "$QID" '{message:$m,model:"anthropic-api",idempotency_key:$k,quote_id:$q}')"
r1="$(tool on "$SID" e3d_chat "$SEND")"
assert_eq "$(jq -r '.result.isError // false' <<< "$r1")" "false" "send ok: $r1"
assert_contains "$(jq -r '.result.structuredContent.answer' <<< "$r1")" "STUBCHAT-1: CHATMARK"
assert_eq "$(jq -c '.result.structuredContent.cost' <<< "$r1")" '{"credits":1,"quoted_max":3}' "cost"
assert_contains "$(jq -r '.result.structuredContent.notice' <<< "$r1")" "untrusted data" "the notice is in every result"
assert_contains "$(jq -r '.result.content[0].text' <<< "$r1")" "untrusted data" "and in the text"
CHAT="$(jq -r '.result.structuredContent.chat_id' <<< "$r1")"
[[ "$CHAT" =~ ^cht_[0-9a-f]{24}$ ]] || fail "chat id: $CHAT"
# the principal is the connection's, never an argument; billing saw exactly the fields asked for
b="$(bodies)"
assert_eq "$(jq -r '.[1].principal' <<< "$b" | grep -c '^pk_\|^acct_\|^key')" "1" "billing got a principal from the connection"
assert_eq "$(jq -c '.[1] | del(.principal) | keys' <<< "$b")" '["idempotency_key","message","model","quote_id"]' "billing got only the asked fields"
echo "ok - quote then send: id, price, answer, cost, the untrusted-data notice, the connection's principal"

# retry with the same key: the stored result, same body
r2="$(tool on "$SID" e3d_chat "$SEND")"
assert_eq "$(jq -c '.result.structuredContent' <<< "$r2")" "$(jq -c '.result.structuredContent' <<< "$r1")" "a retry returns the stored result"
# the same key for another message is a conflict
r3="$(tool on "$SID" e3d_chat "$(jq -nc --arg k "$KEYA" '{message:"another",model:"anthropic-api",idempotency_key:$k}')")"
assert_eq "$(jq -r '.result.structuredContent.error.code' <<< "$r3")" "idempotency_conflict" "same key, other message"
# without a quote_id the server quotes for you (billing does)
r4="$(tool on "$SID" e3d_chat "$(jq -nc --arg c "$CHAT" --arg k "key-$(openssl rand -hex 8)" '{message:"and a functor?",model:"anthropic-api",chat_id:$c,idempotency_key:$k}')")"
assert_eq "$(jq -r '.result.structuredContent.chat_id' <<< "$r4")" "$CHAT" "the chat is continued"
assert_contains "$(jq -r '.result.structuredContent.answer' <<< "$r4")" "STUBCHAT-2:" "second exchange of the chat"
echo "ok - retry, conflict, no quote_id, continued chat"

# another key cannot continue this chat
SIDB="$(TOK="$TOK_B" sid_of on)"
r5="$(TOK="$TOK_B" tool on "$SIDB" e3d_chat "$(jq -nc --arg c "$CHAT" --arg k "key-$(openssl rand -hex 8)" '{message:"hi",model:"anthropic-api",chat_id:$c,idempotency_key:$k}')")"
assert_eq "$(jq -r '.result.structuredContent.error.code' <<< "$r5")" "chat_not_found" "another key's chat"
assert_eq "$(jq -r '.result.structuredContent.error.retryable' <<< "$r5")" "false"
echo "ok - another key cannot continue the chat"

# billing's errors are mapped; a transport failure is service_unavailable and retryable
inject '{"route":"chat/send","status":409,"error":{"code":"chat_busy","message":"busy","retryable":true,"retry_after_seconds":5,"remediation":"wait","docs_url":"https://pilot.e3d.ai/docs/errors#chat_busy"}}'
r6="$(tool on "$SID" e3d_chat "$(jq -nc --arg c "$CHAT" --arg k "key-$(openssl rand -hex 8)" '{message:"hi again",model:"anthropic-api",chat_id:$c,idempotency_key:$k}')")"
assert_eq "$(jq -c '.result.structuredContent.error | [.code, .retryable, .retry_after_seconds]' <<< "$r6")" '["chat_busy",true,5]' "chat_busy keeps its wait"
inject '{"route":"chat/quote","mode":"5xx","count":1}'
r7="$(tool on "$SID" e3d_chat_quote "$(jq -nc --arg m "$MSG" '{message:$m,model:"anthropic-api"}')")"
assert_eq "$(jq -r '.result.structuredContent.error.code' <<< "$r7")" "service_unavailable" "billing 5xx"
# one garbled answer is retried with the same key (a send is idempotent); two in a row are an error
inject '{"route":"chat/send","mode":"garbled","count":1}'
r8a="$(tool on "$SID" e3d_chat "$(jq -nc --arg m "$MSG" --arg k "key-$(openssl rand -hex 8)" '{message:$m,model:"anthropic-api",idempotency_key:$k}')")"
assert_eq "$(jq -r '.result.isError // false' <<< "$r8a")" "false" "one garbled answer is retried: $r8a"
inject '{"route":"chat/send","mode":"garbled","count":2}'
r8="$(tool on "$SID" e3d_chat "$(jq -nc --arg m "$MSG" --arg k "key-$(openssl rand -hex 8)" '{message:$m,model:"anthropic-api",idempotency_key:$k}')")"
[[ "$(jq -r '.result.isError' <<< "$r8")" == "true" ]] || fail "a garbled answer must be an error: $r8"
r9="$(tool on "$SID" e3d_chat_quote "$(jq -nc --arg m "$MSG" '{message:$m,model:"nobody-api"}')")"
assert_eq "$(jq -r '.result.structuredContent.error.code' <<< "$r9")" "model_unavailable" "an unknown model"
echo "ok - billing's errors mapped to the catalog; 5xx and garbled answers are errors"

# the providers listing says which providers chat and which search
lp="$(tool on "$SID" e3d_list_providers '{}')"
assert_contains "$(jq -r '.result.content[0].text' <<< "$lp")" "Chat (e3d_chat, one model per message):" "the chat section"
assert_contains "$(jq -r '.result.content[0].text' <<< "$lp")" "Web search in chat (web_search: true, off by default):" "and the search line"
echo "ok - e3d_list_providers has a chat section"

echo "mcp-chat-tool: ok"
