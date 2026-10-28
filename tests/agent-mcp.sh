#!/usr/bin/env bash
set -euo pipefail

# The agent contract, MCP side (lib/mcp/agent.js; billing's docs/agent-contract-spec.md): e3d_quote, e3d_debate with quote_id and
# idempotency_key, the new result fields, the stable error shape, the server instructions and the E3D_MCP_AGENT switch. Billing is the
# reference stub (examples/external-auth-stub.js) with STUB_PRICING=1 STUB_AGENT=1: /agent/v1/quote, /agent/v1/begin, reserve `reason`,
# finalize `agent`. No network beyond 127.0.0.1, no real keys, no real billing service.
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
const a = await import(pathToFileURL(`${root}/lib/mcp/agent.js`).href);
const fail = (m) => { console.error(`FAIL: ${m}`); process.exit(1); };
// the rollout switch
const m = (env, mode) => a.agentModeFrom(env, mode);
const eq = (x, y, w) => { if (JSON.stringify(x) !== JSON.stringify(y)) fail(`${w}: ${JSON.stringify(x)} != ${JSON.stringify(y)}`); };
eq(m({}, null).on, false, 'unset, no pricing: off'); eq(m({}, 'per_token').on, true, 'unset, per_token: on');
eq(m({ E3D_MCP_AGENT: '0' }, 'per_token').on, false, '0: off'); eq(m({ E3D_MCP_AGENT: '1' }, 'per_token').on, true, '1: on');
eq(m({ E3D_MCP_AGENT: '1' }, null).ok, false, '1 without per_token is refused'); eq(m({ E3D_MCP_AGENT: 'yes' }, 'per_token').ok, false, 'junk is refused');
// the instructions
const t = a.AGENT_INSTRUCTIONS;
if (t.length > 1200) fail(`instructions are ${t.length} characters`);
for (const w of ['e3d_quote', 'quote_id', 'idempotency_key', 'https://pilot.e3d.ai/AGENTS.md', 'not approval', 'untrusted']) if (!t.includes(w)) fail(`instructions lack ${w}`);
for (const bad of [/multi-agent/i, /\$\s?\d/, /verified/i, /accuracy/i, /audit/i, /complian/i, /coming soon/i, /run_debate/]) if (bad.test(t)) fail(`instructions contain ${bad}`);
// every catalog code builds the stable shape
for (const code of a.ERROR_CODES) {
  const e = a.agentError(code);
  for (const k of ['code', 'message', 'retryable', 'remediation', 'docs_url']) if (!(k in e)) fail(`${code} lacks ${k}`);
  if (typeof e.retryable !== 'boolean') fail(`${code}.retryable`);
  if (e.retryable !== ('retry_after_seconds' in e) && !['key_cap_daily', 'key_cap_period', 'account_cap_daily', 'rate_limited', 'too_many_failed_runs', 'service_capacity'].includes(code)) { if (e.retryable && !('retry_after_seconds' in e)) { /* waits billing did not state */ } }
  if (!e.docs_url.startsWith('https://pilot.e3d.ai/docs/errors#')) fail(`${code}.docs_url`);
  const r = a.errorResult(e);
  if (r.isError !== true || !r.content[0].text.startsWith(`${code}:`) || r.content[0].text.includes('\n')) fail(`${code} text: ${r.content[0].text}`);
  eq(r.structuredContent.error.code, code, `${code} structuredContent`);
}
// an unknown code is kept when billing sent it whole, and a malformed error is internal_error, never a guess
eq(a.fromBilling({ code: 'brand_new', message: 'm', retryable: true, retry_after_seconds: 9, remediation: 'r', docs_url: 'https://pilot.e3d.ai/docs/errors#brand_new' }).code, 'brand_new', 'unknown codes pass through');
eq(a.fromBilling({ nope: 1 }).code, 'internal_error', 'malformed');
eq(a.fromBilling({ code: 'key_cap_daily', message: 'x\u0000y', retryable: true, retry_after_seconds: 41200, remediation: 'wait', mismatch: ['question', 'a b'] }).mismatch, ['question'], 'extras are whitelisted and checked');
eq(a.reasonError({ reason: 'key_cap_daily', code: 'limit_reached', retry_after_seconds: 41200 }).retry_after_seconds, 41200, 'reason keeps the wait');
eq(a.reasonError({ code: 'suspended' }).code, 'account_suspended', 'older hook codes map'); eq(a.reasonError({ code: 'limit_reached' }).code, 'limit_reached', 'no reason: limit_reached');
eq(a.transportError('timeout').code, 'service_unavailable', 'transport failures'); eq(a.transportError('timeout').retryable, true, 'retryable');
// the finalize fields are checked, never trusted
eq(a.agentFieldsOf({ schema_version: 1, recommended_next_step: 'maybe' }), null, 'unknown next step');
eq(a.agentFieldsOf({ schema_version: 1, recommended_next_step: 'proceed', cost: { quote_credits: 5, charged_credits: 3.5 }, dissent_items: [{ text: 'a' }, 7] }).cost, { quote_credits: 5, charged_credits: null }, 'cost integers');
console.log('agent unit tests: ok');
JS

# ---------------------------------------------------------------- stdio and unconfigured servers: unchanged
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"agent-test","version":"0"}}}'
LIST='{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
out="$(printf '%s\n%s\n' "$INIT" "$LIST" | env -u E3D_MCP_AUTH_URL -u E3D_MCP_PRICING E3D_MCP_STATE_DIR="$TMP/state-stdio" node "$ROOT/bin/e3d-mcp" 2>/dev/null)"
assert_not_contains "$(jq -r 'select(.id==1) | .result.instructions' <<< "$out")" "e3d_quote" "stdio keeps its own instructions"
assert_eq "$(jq -r 'select(.id==2) | [.result.tools[].name] | index("e3d_quote")' <<< "$out")" "null" "stdio has no e3d_quote"
assert_eq "$(jq -r 'select(.id==2) | .result.tools[] | select(.name=="e3d_debate") | .inputSchema.properties | has("idempotency_key") or has("quote_id")' <<< "$out")" "false" "stdio e3d_debate has no agent inputs"
assert_eq "$(jq -r 'select(.id==2) | .result.tools[] | select(.name=="e3d_debate") | .outputSchema.properties | has("recommended_next_step")' <<< "$out")" "false" "stdio e3d_debate has no agent outputs"
out="$(printf '' | env E3D_MCP_AGENT=1 node "$ROOT/bin/e3d-mcp" 2>&1)" && fail "E3D_MCP_AGENT=1 needs per_token" || true
assert_contains "$out" "E3D_MCP_AGENT=1 needs E3D_MCP_PRICING=per_token"
echo "ok - stdio and unconfigured servers: no e3d_quote, no new inputs or outputs, the old instructions; E3D_MCP_AGENT=1 needs per_token"

# ---------------------------------------------------------------- the fake billing
STUB="$ROOT/examples/external-auth-stub.js"
SERVER="$ROOT/bin/e3d-mcp"
SVC="svc-MARKER-$(openssl rand -hex 12)"
TOK_A="caller-MARKER-a-$(openssl rand -hex 12)"
jq -n --arg a "$TOK_A" '{accounts: [{principal: "acct_web", balance: 1000000, keys: [{id: "key-a", token: $a}]}]}' > "$TMP/seed.json"
env STUB_SERVICE_TOKEN="$SVC" STUB_SEED="$TMP/seed.json" STUB_URL_FILE="$TMP/stub.url" STUB_FEATURES="finalize,fetch,authorize-run" STUB_PRICING=1 STUB_AGENT=1 STUB_QUOTE_MAX_CREDITS=40 node "$STUB" > "$TMP/stub.out" 2> "$TMP/stub.log" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$TMP/stub.url" ]] && break; sleep 0.05; done
URL="$(cat "$TMP/stub.url")"
ledger() { curl -fsS -H "authorization: Bearer $SVC" "$URL/_stub/state"; }
stubpost() { curl -fsS -X POST -H "authorization: Bearer $SVC" -H 'content-type: application/json' -d "$2" "$URL/_stub/$1" > /dev/null; }

DEBATE="$TMP/stub-debate"; ARGS="$TMP/debate.args"; : > "$ARGS"
cat > "$DEBATE" <<STUBEOF
#!/usr/bin/env bash
out=""; provs=""; rounds=1; all="\$*"
while [[ \$# -gt 0 ]]; do case "\$1" in --out-dir) out="\$2"; shift 2 ;; --providers) provs="\$2"; shift 2 ;; --rounds) rounds="\$2"; shift 2 ;; *) shift ;; esac; done
echo "\$all" >> "$ARGS"
[[ -e "$TMP/slow" ]] && sleep 3
mkdir -p "\$out"
printf '# Debate\n\n## Round 1 -- anthropic-api\n\nJSON file.\n\n## Round 1 -- openai-api\n\nSQLite.\n' > "\$out/transcript.md"
if [[ -n "\${E3D_DEBATE_MAX_TOKENS:-}" ]]; then
  IFS=, read -r -a P <<< "\$provs"
  rows='[]'
  for ((r = 1; r <= rounds; r++)); do for p in "\${P[@]}"; do rows="\$(jq -c --arg k "r\$r:\$p" --arg p "\$p" '. + [{key:\$k, provider:\$p, model:"stub-model-1", input_tokens:100, output_tokens:50, source:"vendor"}]' <<< "\$rows")"; done; done
  rows="\$(jq -c --arg p "\${P[0]}" '. + [{key:"synth", provider:\$p, model:"stub-model-1", input_tokens:200, output_tokens:60, source:"bytes"}]' <<< "\$rows")"
  echo "\$rows" > "\$out/usage.json"
fi
printf 'FINAL ANSWER: use a JSON file.\nCONSENSUS: %s\nDISSENT: %s\n' "\${STUB_CONSENSUS:-split}" "\${STUB_DISSENT:-SQLite has a case.}"
STUBEOF
chmod +x "$DEBATE"

BASE_ENV=(E3D_MCP_AUTH_URL="$URL" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" E3D_MCP_DEBATE_BIN="$DEBATE" TYPESAFE_API_KEY="" E3D_MCP_PRINCIPAL=""
  E3D_MCP_AUTH_CACHE_SEC=1 E3D_MCP_TIMEOUT_SEC=20 E3D_MCP_AUTH_HEALTH_SEC=1 E3D_MCP_RATE_PER_MIN=100000)
start_server() { # start_server <name> [VAR=value ...]
  local name="$1"; shift
  : > "$TMP/$name.port"
  env "${BASE_ENV[@]}" E3D_MCP_STATE_DIR="$TMP/state-$name" E3D_MCP_PORT_FILE="$TMP/$name.port" "$@" "$SERVER" --http --port 0 2>> "$TMP/$name.log" &
  PIDS+=("$!")
  for _ in $(seq 1 100); do [[ -s "$TMP/$name.port" ]] && break; sleep 0.1; done
  [[ -s "$TMP/$name.port" ]] || { cat "$TMP/$name.log" >&2; fail "server $name did not start"; }
}
J=(-H 'content-type: application/json' -H 'accept: application/json')
mcp() { curl -s -m 60 -X POST "${J[@]}" -H "Authorization: Bearer $TOK_A" ${3:+-H "mcp-session-id: $3"} -d "$2" "http://127.0.0.1:$(cat "$TMP/$1.port")/mcp"; }
sid_of() { curl -s -D "$TMP/h" -o "$TMP/init.body" -X POST "${J[@]}" -H "Authorization: Bearer $TOK_A" -d "$INIT" "http://127.0.0.1:$(cat "$TMP/$1.port")/mcp"; grep -i '^mcp-session-id:' "$TMP/h" | sed -E 's/^[^:]+: *//' | tr -d '\r'; }
tool() { local r; r="$(mcp "$1" "$(jq -nc --arg n "$3" --argjson a "$4" '{jsonrpc:"2.0",id:7,method:"tools/call",params:{name:$n,arguments:$a}}')" "$2")"; printf '%s\n' "$r" >> "$TMP/responses.out"; printf '%s' "$r"; }
list() { mcp "$1" '{"jsonrpc":"2.0","id":3,"method":"tools/list"}' "$2"; }
Q="QCONTENT: a JSON file or SQLite?"
PR='["anthropic-api","openai-api"]'
n_res() { ledger | jq '.reservations | length'; }
n_debates() { wc -l < "$ARGS" | tr -d ' '; }
PT=(E3D_MCP_PRICING=per_token E3D_MCP_CUSTOMER_LIMITS='rounds=2,max_words=300,providers=3')

# ---------------------------------------------------------------- the switch: per_token with E3D_MCP_AGENT=0 is the old surface
start_server off "${PT[@]}" E3D_MCP_AGENT=0
SID="$(sid_of off)"
assert_not_contains "$(jq -r .result.instructions "$TMP/init.body")" "e3d_quote" "E3D_MCP_AGENT=0: the old hosted instructions"
tl="$(list off "$SID")"
assert_eq "$(jq -r '[.result.tools[].name] | index("e3d_quote")' <<< "$tl")" "null" "E3D_MCP_AGENT=0: no e3d_quote"
assert_eq "$(jq -r '.result.tools[] | select(.name=="e3d_debate") | .inputSchema.properties | has("idempotency_key")' <<< "$tl")" "false"
res="$(tool off "$SID" e3d_quote "$(jq -nc --arg q "$Q" --argjson p "$PR" '{question:$q,providers:$p}')")"
assert_eq "$(jq -r '.error.code' <<< "$res")" "-32602" "e3d_quote is an unknown tool with the switch off"
# a call with the new arguments (ignored) is exactly today's flow: the connector quote, no agent route, no agent fields in the result
res="$(tool off "$SID" e3d_debate "$(jq -nc --arg q "$Q" --argjson p "$PR" '{question:$q,providers:$p,rounds:2,idempotency_key:"switch-off-key-0001"}')")"
assert_eq "$(jq -r '.result.isError // false' <<< "$res")" "false" "$(jq -c . <<< "$res")"
assert_eq "$(jq -c '.result.structuredContent | [has("recommended_next_step"), has("schema_version"), has("cost"), has("replayed")]' <<< "$res")" "[false,false,false,false]" "no agent fields with the switch off"
assert_eq "$(ledger | jq -c '[.received.agent_quote, .received.agent_begin] | map(. // 0)')" "[0,0]" "no agent route was called"
assert_eq "$(ledger | jq '[.pricing.quotes[] | select(.version == "1")] | length')" "1" "the connector quote path"
echo "ok - E3D_MCP_AGENT=0: no e3d_quote, no new inputs or outputs, no agent route, today's result"

# ---------------------------------------------------------------- agent mode (the default under per_token)
start_server ag "${PT[@]}"
SID="$(sid_of ag)"
INSTR="$(jq -r .result.instructions "$TMP/init.body")"
EXPECT="$(node --input-type=module -e "import('$ROOT/lib/mcp/agent.js').then((m) => process.stdout.write(m.AGENT_INSTRUCTIONS))")"
assert_eq "$INSTR" "$EXPECT" "initialize returns the agent instructions"
[[ "${#INSTR}" -le 1200 ]] || fail "instructions are ${#INSTR} characters"
assert_contains "$INSTR" "e3d_quote"; assert_contains "$INSTR" "idempotency_key"; assert_contains "$INSTR" "https://pilot.e3d.ai/AGENTS.md"
tl="$(list ag "$SID")"
assert_eq "$(jq -c '.result.tools[] | select(.name=="e3d_quote") | [.annotations.readOnlyHint, .annotations.destructiveHint, (.inputSchema.required), (.outputSchema.required | index("quote_id") != null)]' <<< "$tl")" '[true,false,["question"],true]' "e3d_quote is read-only"
assert_eq "$(jq -c '.result.tools[] | select(.name=="e3d_debate") | [(.inputSchema.properties | has("idempotency_key") and has("quote_id")), .inputSchema.required, (.outputSchema.properties.recommended_next_step.enum | length), (.outputSchema.properties | has("cost") and has("dissent_items") and has("schema_version") and has("notice") and has("dissent")), (.outputSchema.required | index("recommended_next_step"))]' <<< "$tl")" '[true,["question"],4,true,null]' "e3d_debate: two optional inputs, the new result fields"
assert_eq "$(jq -r '.result.tools[] | select(.name=="e3d_debate") | .outputSchema.properties.dissent.type' <<< "$tl")" "object" "the dissent summary object is unchanged"
# every hosted tool declares MCP annotations: a title and explicit readOnlyHint and destructiveHint booleans (registries and
# connector directories read them); e3d_debate spends the account's credits, so it is never read-only; e3d_quote, e3d_usage and
# e3d_list_providers are. idempotentHint stays false for e3d_debate: the key is optional and without it a repeat spends again.
assert_eq "$(jq -r '[.result.tools[] | select((.annotations.title | type) != "string" or (.annotations.readOnlyHint | type) != "boolean" or (.annotations.destructiveHint | type) != "boolean") | .name] | join(",")' <<< "$tl")" "" "every hosted tool has title, readOnlyHint, destructiveHint"
assert_eq "$(jq -c '[.result.tools[] | select(.name=="e3d_quote" or .name=="e3d_usage" or .name=="e3d_list_providers") | .annotations.readOnlyHint] | [length, all]' <<< "$tl")" "[3,true]" "quote, usage, list_providers are read-only"
assert_eq "$(jq -c '.result.tools[] | select(.name=="e3d_debate") | .annotations | [.readOnlyHint, .destructiveHint, .idempotentHint, .openWorldHint]' <<< "$tl")" "[false,false,false,true]" "e3d_debate annotations"
echo "ok - agent mode: instructions (${#INSTR} chars), e3d_quote (read-only), e3d_debate with quote_id and idempotency_key and the new result fields"

# e3d_quote: free, nothing held, only a hash and a size leave this server
before="$(n_res)"
res="$(tool ag "$SID" e3d_quote "$(jq -nc --arg q "$Q" --argjson p "$PR" '{question:$q,providers:$p,rounds:2}')")"
assert_eq "$(jq -r '.result.isError // false' <<< "$res")" "false" "$(jq -c . <<< "$res")"
sc="$(jq -c .result.structuredContent <<< "$res")"
QID="$(jq -r .quote_id <<< "$sc")"
printf '%s' "$sc" > "$TMP/sc-quote.json"
assert_eq "$(jq -c '[.max_credits, .ttl_seconds, .schema_version, .search_enabled, (.expires_at | type), .key_limits.cap_daily_credits, .key_limits.service_max_per_run_credits]' <<< "$sc")" '[14,600,1,false,"string",2000,40]'
assert_contains "$(jq -r '.result.content[0].text' <<< "$res")" "at most 14 credits"
assert_eq "$(n_res)" "$before" "a quote holds nothing"
assert_eq "$(ledger | jq '.received.agent_quote')" "1"
echo "ok - e3d_quote: quote_id, max_credits, expires_at, ttl_seconds, schema_version, key_limits; no reservation"

# quote, then run with the key and the quote: reserve under the quote's id, the result carries the agent fields
KEY1="key-run-$(openssl rand -hex 6)"
n0="$(n_debates)"
res="$(tool ag "$SID" e3d_debate "$(jq -nc --arg q "$Q" --argjson p "$PR" --arg k "$KEY1" --arg id "$QID" '{question:$q,providers:$p,rounds:2,idempotency_key:$k,quote_id:$id}')")"
assert_eq "$(jq -r '.result.isError // false' <<< "$res")" "false" "$(jq -c . <<< "$res")"
sc="$(jq -c .result.structuredContent <<< "$res")"
printf '%s' "$sc" > "$TMP/sc-run.json"
assert_eq "$(jq -c '[.schema_version, .cost, .recommended_next_step, (.dissent_items | length), .dissent_items[0].text, .dissent.present, .dissent.summary, .consensus, (.notice | startswith("Advisory input")), has("replayed")]' <<< "$sc")" \
  '[1,{"quote_credits":14,"charged_credits":4},"escalate_to_human",1,"SQLite has a case.",true,"SQLite has a case.","split",true,false]' "agent fields from billing's finalize answer; the dissent object is unchanged"
txt="$(jq -r '.result.content[0].text' <<< "$res")"
assert_contains "$txt" "REPORT THIS TO THE USER"; assert_contains "$txt" "recommended_next_step: escalate_to_human"; assert_contains "$txt" "NOT approval"
assert_eq "$(ledger | jq -r --arg id "$QID" '.reservations[] | select(.request_id == $id) | .state')" "settled" "the reservation's request_id is the quote_id"
assert_eq "$(ledger | jq -c --arg id "$QID" '[.pricing.order[] | select(.[1] == $id or (.[1] | startswith("res_"))) | .[0]] | .[-3:]')" '["reserve","usage","finalize"]'
assert_eq "$(( $(n_debates) - n0 ))" "1" "one debate process"
assert_eq "$(ledger | jq '.received.agent_begin')" "1"
echo "ok - quote then run: begin, reserve with request_id = quote_id, run, usage, finalize; result has schema_version, cost, dissent_items, recommended_next_step, notice"

# a replay returns the stored result: nothing ran, nothing reserved, nothing charged
n1="$(n_debates)"; r1="$(n_res)"; bal="$(ledger | jq '.accounts.acct_web.balance')"
res="$(tool ag "$SID" e3d_debate "$(jq -nc --arg q "$Q" --argjson p "$PR" --arg k "$KEY1" --arg id "$QID" '{question:$q,providers:$p,rounds:2,idempotency_key:$k,quote_id:$id}')")"
assert_eq "$(jq -r '.result.isError // false' <<< "$res")" "false" "$(jq -c . <<< "$res")"
rc="$(jq -c .result.structuredContent <<< "$res")"
printf '%s' "$rc" > "$TMP/sc-replay.json"
assert_eq "$(jq -c '[.replayed, .final_answer, .consensus, .recommended_next_step, .cost, (.debate_id | startswith("dbt_")), .dissent_items[0].text]' <<< "$rc")" '[true,"use a JSON file.","split","escalate_to_human",{"quote_credits":14,"charged_credits":4},true,"SQLite has a case."]' "the stored result"
assert_contains "$(jq -r '.result.content[0].text' <<< "$res")" "REPORT THIS TO THE USER"
assert_contains "$(jq -r '.result.content[0].text' <<< "$res")" "nothing was charged"
assert_eq "$(n_debates)" "$n1" "a replay runs no debate"; assert_eq "$(n_res)" "$r1" "a replay reserves nothing (the fake saw no second reserve)"
assert_eq "$(ledger | jq '.accounts.acct_web.balance')" "$bal" "a replay charges nothing"
# the same key without a quote_id: the server quotes (a free read) and begin still replays
res="$(tool ag "$SID" e3d_debate "$(jq -nc --arg q "$Q" --argjson p "$PR" --arg k "$KEY1" '{question:$q,providers:$p,rounds:2,idempotency_key:$k}')")"
assert_eq "$(jq -c '.result.structuredContent | [.replayed, .final_answer]' <<< "$res")" '[true,"use a JSON file."]' "a retry with a fresh or no quote_id still replays"
assert_eq "$(n_debates)" "$n1"; assert_eq "$(n_res)" "$r1"
echo "ok - replay: the stored result, no debate, no reserve, no charge (with the old quote_id and without one)"

# the tool results validate against the outputSchema the server lists (the repo's own validator, lib/mcp/external-auth.js)
printf '%s' "$tl" > "$TMP/tools.json"
node --input-type=module - "$ROOT" "$TMP" <<'JS'
import { pathToFileURL } from 'node:url';
import { readFileSync } from 'node:fs';
const [root, tmp] = process.argv.slice(2);
const { validateSchema } = await import(pathToFileURL(`${root}/lib/mcp/external-auth.js`).href);
const tools = JSON.parse(readFileSync(`${tmp}/tools.json`, 'utf8')).result.tools;
const schemaOf = (n) => tools.find((t) => t.name === n).outputSchema;
const check = (name, file) => { const errs = validateSchema(schemaOf(name), JSON.parse(readFileSync(`${tmp}/${file}`, 'utf8'))); if (errs.length) { console.error(`FAIL: ${file} vs ${name}: ${errs.join('; ')}`); process.exit(1); } };
check('e3d_quote', 'sc-quote.json'); check('e3d_debate', 'sc-run.json'); check('e3d_debate', 'sc-replay.json');
// a result that breaks the schema is caught (the validator is not vacuous)
const bad = JSON.parse(readFileSync(`${tmp}/sc-run.json`, 'utf8')); bad.recommended_next_step = 'approved';
if (!validateSchema(schemaOf('e3d_debate'), bad).length) { console.error('FAIL: an unknown recommended_next_step passed'); process.exit(1); }
JS
echo "ok - e3d_quote, e3d_debate and a replayed result validate against the listed outputSchema"

# key without quote_id on a new request: the server quotes itself
KEY2="key-selfquote-$(openssl rand -hex 6)"
res="$(tool ag "$SID" e3d_debate "$(jq -nc --arg q "$Q self" --argjson p "$PR" --arg k "$KEY2" '{question:$q,providers:$p,rounds:1,idempotency_key:$k}')")"
assert_eq "$(jq -r '.result.isError // false' <<< "$res")" "false" "$(jq -c . <<< "$res")"
assert_eq "$(jq -c '.result.structuredContent | [.cost.quote_credits, (has("replayed")), .recommended_next_step]' <<< "$res")" '[8,false,"escalate_to_human"]'
echo "ok - an idempotency_key without a quote_id: the server quotes first"

# in_progress: a second call while the first is still running
touch "$TMP/slow"
KEY3="key-slow-$(openssl rand -hex 6)"
ARGS3="$(jq -nc --arg q "$Q slow" --argjson p "$PR" --arg k "$KEY3" '{question:$q,providers:$p,rounds:1,idempotency_key:$k}')"
( tool ag "$SID" e3d_debate "$ARGS3" > "$TMP/slow1.out" ) &
SLOWPID=$!
for _ in $(seq 1 100); do [[ "$(ledger | jq '[.reservations[] | select(.state == "held")] | length')" -ge 1 ]] && break; sleep 0.05; done
r2="$(n_res)"
res="$(tool ag "$SID" e3d_debate "$ARGS3")"
assert_eq "$(jq -c '.result | [.isError, .structuredContent.error.code, .structuredContent.error.retryable, .structuredContent.error.retry_after_seconds, (.content[0].text | startswith("in_progress:"))]' <<< "$res")" '[true,"in_progress",true,5,true]' "$(jq -c . <<< "$res")"
assert_eq "$(n_res)" "$r2" "in_progress reserved nothing"
wait "$SLOWPID"; rm -f "$TMP/slow"
assert_eq "$(jq -r '.result.isError // false' "$TMP/slow1.out")" "false" "the first call finished"
res="$(tool ag "$SID" e3d_debate "$ARGS3")"
assert_eq "$(jq -c '.result.structuredContent | [.replayed, .recommended_next_step]' <<< "$res")" '[true,"escalate_to_human"]' "after it finished, the same call replays"
echo "ok - in_progress is a structured retryable error with retry_after_seconds; afterwards the same call replays"

# conflicts and bad inputs
res="$(tool ag "$SID" e3d_debate "$(jq -nc --arg q "$Q DIFFERENT" --argjson p "$PR" --arg k "$KEY1" '{question:$q,providers:$p,rounds:2,idempotency_key:$k}')")"
assert_eq "$(jq -c '.result | [.isError, .structuredContent.error.code, .structuredContent.error.retryable, (.structuredContent.error | has("retry_after_seconds"))]' <<< "$res")" '[true,"idempotency_conflict",false,false]' "the same key for another request"
r3="$(n_res)"
res="$(tool ag "$SID" e3d_debate "$(jq -nc --arg q "$Q" --argjson p "$PR" --arg k "key-other-$(openssl rand -hex 6)" --arg id "$QID" '{question:$q,providers:$p,rounds:2,idempotency_key:$k,quote_id:$id}')")"
assert_eq "$(jq -r '.result.structuredContent.error.code' <<< "$res")" "quote_used" "a quote is single use"
res="$(tool ag "$SID" e3d_quote "$(jq -nc --arg q "$Q m" --argjson p "$PR" '{question:$q,providers:$p,rounds:1}')")"; QM="$(jq -r .result.structuredContent.quote_id <<< "$res")"
res="$(tool ag "$SID" e3d_debate "$(jq -nc --arg q "$Q m" --argjson p "$PR" --arg k "key-mm-$(openssl rand -hex 6)" --arg id "$QM" '{question:$q,providers:$p,rounds:2,idempotency_key:$k,quote_id:$id}')")"
assert_eq "$(jq -c '.result.structuredContent.error | [.code, .mismatch]' <<< "$res")" '["quote_mismatch",["length"]]' "a quote for another run"
res="$(tool ag "$SID" e3d_debate "$(jq -nc --arg q "$Q" --argjson p "$PR" --arg k "key-ex-$(openssl rand -hex 6)" --arg id "$(uuidgen | tr 'A-Z' 'a-z')" '{question:$q,providers:$p,rounds:2,idempotency_key:$k,quote_id:$id}')")"
assert_eq "$(jq -r '.result.structuredContent.error.code' <<< "$res")" "quote_expired" "an unknown quote"
res="$(tool ag "$SID" e3d_debate "$(jq -nc --arg q "$Q" --argjson p "$PR" --arg id "$QM" '{question:$q,providers:$p,rounds:1,quote_id:$id}')")"
assert_eq "$(jq -c '.result | [.isError, .structuredContent.error.code]' <<< "$res")" '[true,"invalid_request"]' "quote_id needs an idempotency_key"
res="$(tool ag "$SID" e3d_debate "$(jq -nc --arg q "$Q" --argjson p "$PR" '{question:$q,providers:$p,rounds:1,idempotency_key:"short"}')")"
assert_eq "$(jq -r '.result.structuredContent.error.code' <<< "$res")" "idempotency_key_invalid"
res="$(tool ag "$SID" e3d_debate "$(jq -nc --arg q "$Q" --argjson p "$PR" '{question:$q,providers:$p,rounds:1,idempotency_key:"has spaces in it"}')")"
assert_eq "$(jq -r '.result.structuredContent.error.code' <<< "$res")" "idempotency_key_invalid"
assert_eq "$(n_res)" "$r3" "none of these reserved anything"
echo "ok - idempotency_conflict, quote_used, quote_mismatch (with mismatch), quote_expired, invalid_request, idempotency_key_invalid"

# no idempotency_key: today's behaviour. The connector quote and reserve as before; the result gains the agent fields only
ab="$(ledger | jq '.received.agent_begin')"; aq="$(ledger | jq '.received.agent_quote')"; legacy="$(ledger | jq '[.pricing.quotes[] | select(.agent == null)] | length')"
res="$(tool ag "$SID" e3d_debate "$(jq -nc --arg q "$Q nokey" --argjson p "$PR" '{question:$q,providers:$p,rounds:2}')")"
assert_eq "$(jq -r '.result.isError // false' <<< "$res")" "false" "$(jq -c . <<< "$res")"
assert_eq "$(ledger | jq '.received.agent_begin')" "$ab" "no begin without a key"; assert_eq "$(ledger | jq '.received.agent_quote')" "$aq" "no agent quote without a key"
assert_eq "$(ledger | jq '[.pricing.quotes[] | select(.agent == null)] | length')" "$(( legacy + 1 ))" "the connector quote, as before"
assert_not_contains "$(jq -r '.result.content[0].text' <<< "$res")" "recommended_next_step" "the legacy success text is unchanged"
assert_eq "$(jq -c '.result.structuredContent | [.billing.quote_credits, .billing.charged_credits, (.billing | has("agent")), .recommended_next_step, (has("replayed"))]' <<< "$res")" '[14,4,false,"escalate_to_human",false]' "billing object unchanged; agent fields added"
echo "ok - without an idempotency_key: the connector quote and reserve as before, the success text is unchanged and structuredContent gains the agent fields"

# ---------------------------------------------------------------- errors: every catalog code, through every place billing can say it
CODES="key_revoked key_unknown key_cap_per_run key_cap_daily key_cap_total key_cap_period account_cap_daily insufficient_credits quote_required quote_expired quote_mismatch quote_used quote_changed quote_exceeds_limit idempotency_key_invalid idempotency_conflict in_progress rate_limited concurrency_limit panel_unavailable question_too_large kill_switch service_capacity pricing_paused too_many_failed_runs terms_required account_suspended account_closing invalid_request unsupported_version unauthorized not_found service_unavailable internal_error"
retryable_of() { case "$1" in key_cap_daily|key_cap_period|account_cap_daily|in_progress|rate_limited|concurrency_limit|kill_switch|service_capacity|too_many_failed_runs|service_unavailable|internal_error) echo true ;; *) echo false ;; esac; }
for code in $CODES; do
  rt="$(retryable_of "$code")"
  errobj="$(jq -nc --arg c "$code" --argjson r "$rt" '{code:$c, message:("billing says " + $c), retryable:$r, remediation:("do the thing for " + $c), docs_url:("https://pilot.e3d.ai/docs/errors#" + $c)} + (if $r then {retry_after_seconds: 41} else {} end)')"
  # on the quote route (e3d_quote) and on begin (an e3d_debate with a key)
  for route in quote begin; do
    stubpost agent-inject "$(jq -nc --arg r "$route" --argjson e "$errobj" '{route:$r,error:$e,status:400,count:1}')"
    if [[ "$route" == quote ]]; then res="$(tool ag "$SID" e3d_quote "$(jq -nc --arg q "$Q" --argjson p "$PR" '{question:$q,providers:$p,rounds:1}')")"
    else res="$(tool ag "$SID" e3d_debate "$(jq -nc --arg q "$Q" --argjson p "$PR" --arg k "key-err-$code-$(openssl rand -hex 4)" '{question:$q,providers:$p,rounds:1,idempotency_key:$k}')")"; fi
    e="$(jq -c '.result.structuredContent.error' <<< "$res")"
    assert_eq "$(jq -r '.result.isError' <<< "$res")" "true" "$code via $route"
    assert_eq "$(jq -c '[.code, .retryable, .remediation, .docs_url, .retry_after_seconds]' <<< "$e")" "$(jq -c '[.code, .retryable, .remediation, .docs_url, .retry_after_seconds]' <<< "$errobj")" "$code via $route: the cloud object, verbatim"
    assert_eq "$(jq -r '.message' <<< "$e")" "billing says $code"
    assert_eq "$(jq -r '.result.content[0].text | startswith("'"$code"':")' <<< "$res")" "true" "$code: the text begins with the code"
  done
done
echo "ok - every catalog code is returned verbatim as isError with structuredContent.error (via e3d_quote and via e3d_debate's begin)"

# reserve refusals carry the catalog `reason`; the older hook code maps when there is none
for pair in "limit_reached key_cap_daily 41200" "limit_reached key_cap_per_run" "limit_reached key_cap_total" "limit_reached key_cap_period 100" "limit_reached account_cap_daily 5" "insufficient_credits insufficient_credits" "suspended key_revoked" "suspended account_suspended" "suspended kill_switch 300" "unknown_principal key_unknown" "limit_reached quote_changed" "limit_reached quote_expired" "limit_reached concurrency_limit 15" "limit_reached rate_limited 22" "limit_reached too_many_failed_runs 9" "limit_reached service_capacity 9" "limit_reached pricing_paused" "limit_reached panel_unavailable"; do
  set -- $pair; hook="$1"; reason="$2"; wait_s="${3:-}"
  stubpost reserve-refuse "$(jq -nc --arg c "$hook" --arg r "$reason" --arg w "$wait_s" '{code:$c, reason:$r, count:1} + (if $w != "" then {retry_after_seconds: ($w|tonumber)} else {} end)')"
  res="$(tool ag "$SID" e3d_debate "$(jq -nc --arg q "$Q" --argjson p "$PR" --arg k "key-rsv-$reason-$(openssl rand -hex 4)" '{question:$q,providers:$p,rounds:1,idempotency_key:$k}')")"
  assert_eq "$(jq -r '.result.isError' <<< "$res")" "true" "$reason"
  assert_eq "$(jq -c '.result.structuredContent.error | [.code, .retry_after_seconds, (has("remediation") and has("docs_url") and has("message") and (.retryable | type == "boolean"))]' <<< "$res")" "$(jq -nc --arg r "$reason" --arg w "$wait_s" '[$r, (if $w != "" then ($w|tonumber) else null end), true]')" "reserve refusal $hook/$reason"
  assert_eq "$(jq -r '.result.content[0].text | startswith("'"$reason"':")' <<< "$res")" "true"
done
# the same refusals without a key or quote_id (the legacy path) keep today's text and carry no structured error
stubpost reserve-refuse '{"code":"insufficient_credits","reason":"insufficient_credits","count":1}'
res="$(tool ag "$SID" e3d_debate "$(jq -nc --arg q "$Q" --argjson p "$PR" '{question:$q,providers:$p,rounds:1}')")"
assert_eq "$(jq -c '.result | [.isError, (.content[0].text | startswith("error: billing: ")), has("structuredContent")]' <<< "$res")" '[true,true,false]' "legacy refusal: the old text, no structuredContent"
stubpost reserve-refuse '{"code":"limit_reached","reason":"","count":1}'
res="$(tool ag "$SID" e3d_debate "$(jq -nc --arg q "$Q" --argjson p "$PR" '{question:$q,providers:$p,rounds:1}')")"
assert_eq "$(jq -r '.result.content[0].text' <<< "$res")" "error: billing: refused (stub)"
# a hook code with no reason (an older billing) maps to its closest entry, on the contract path
stubpost reserve-refuse '{"code":"limit_reached","reason":"","count":1}'
res="$(tool ag "$SID" e3d_debate "$(jq -nc --arg q "$Q" --argjson p "$PR" --arg k "key-old-$(openssl rand -hex 4)" '{question:$q,providers:$p,rounds:1,idempotency_key:$k}')")"
assert_eq "$(jq -r '.result.structuredContent.error.code' <<< "$res")" "limit_reached"
echo "ok - reserve refusals: the catalog reason and retry_after_seconds, the hook code when there is none, with and without a key"

# transport failures: billing unreachable, a timeout, an unreadable answer, a 5xx
for mode in drop 5xx garbled; do
  for route in quote begin; do
    stubpost agent-inject "$(jq -nc --arg r "$route" --arg m "$mode" '{route:$r,mode:$m,count:5}')"
    if [[ "$route" == quote ]]; then res="$(tool ag "$SID" e3d_quote "$(jq -nc --arg q "$Q" --argjson p "$PR" '{question:$q,providers:$p,rounds:1}')")"
    else res="$(tool ag "$SID" e3d_debate "$(jq -nc --arg q "$Q" --argjson p "$PR" --arg k "key-tr-$mode-$(openssl rand -hex 4)" '{question:$q,providers:$p,rounds:1,idempotency_key:$k}')")"; fi
    assert_eq "$(jq -c '.result | [.isError, .structuredContent.error.code, .structuredContent.error.retryable, .structuredContent.error.retry_after_seconds]' <<< "$res")" '[true,"service_unavailable",true,10]' "$mode on $route"
    stubpost agent-inject '{"route":""}'
  done
done
echo "ok - transport failures (dropped connection, 5xx, unreadable answer) are service_unavailable, retryable, retry_after_seconds 10"

# billing that already sends max_tokens and answer_bytes in the agent quote (STUB_AGENT_QUOTE_LIMITS=1): no connector quote is needed
env STUB_SERVICE_TOKEN="$SVC" STUB_SEED="$TMP/seed.json" STUB_URL_FILE="$TMP/stub2.url" STUB_FEATURES="finalize,fetch,authorize-run" STUB_PRICING=1 STUB_AGENT=1 STUB_AGENT_QUOTE_LIMITS=1 STUB_QUOTE_MAX_CREDITS=40 node "$STUB" > "$TMP/stub2.out" 2> "$TMP/stub2.log" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$TMP/stub2.url" ]] && break; sleep 0.05; done
URL2="$(cat "$TMP/stub2.url")"
: > "$TMP/lim.port"
env "${BASE_ENV[@]}" E3D_MCP_AUTH_URL="$URL2" E3D_MCP_STATE_DIR="$TMP/state-lim" E3D_MCP_PORT_FILE="$TMP/lim.port" "${PT[@]}" "$SERVER" --http --port 0 2>> "$TMP/lim.log" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$TMP/lim.port" ]] && break; sleep 0.1; done
SIDL="$(sid_of lim)"
res="$(tool lim "$SIDL" e3d_debate "$(jq -nc --arg q "$Q lim" --argjson p "$PR" --arg k "key-lim-$(openssl rand -hex 6)" '{question:$q,providers:$p,rounds:2,idempotency_key:$k}')")"
assert_eq "$(jq -r '.result.isError // false' <<< "$res")" "false" "$(jq -c . <<< "$res")"
assert_eq "$(curl -fsS -H "authorization: Bearer $SVC" "$URL2/_stub/state" | jq -c '[.pricing.quotes[] | select(.agent == null)] | length')" "0" "limits came from the agent quote: no connector quote row"
assert_eq "$(jq -r '.result.structuredContent.cost.charged_credits' <<< "$res")" "4"
echo "ok - when the agent quote carries max_tokens and answer_bytes they are used, with no connector quote"

# ---------------------------------------------------------------- privacy: no content or token in any log or error
for f in "$TMP/off.log" "$TMP/ag.log" "$TMP/lim.log" "$TMP/stub.log" "$TMP/stub2.log"; do
  if grep -q "QCONTENT" "$f"; then fail "debate content leaked into $f"; fi
  for secret in "$SVC" "$TOK_A"; do if grep -qF -- "$secret" "$f"; then fail "a token leaked into $f"; fi; done
done
if jq -r 'select(.result.isError == true) | .result.content[0].text, (.result.structuredContent | tostring)' "$TMP/responses.out" | grep -qE "QCONTENT|$SVC|$TOK_A"; then fail "content or a token in an error result"; fi
echo "ok - no content or token in logs or in any error result"
echo "agent-mcp: all passed"
