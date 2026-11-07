#!/usr/bin/env bash
set -euo pipefail

# Experts through the hosted MCP, agent mode (docs/specs/experts-phase2b2-mcp-listing-and-use-spec.md, PR 2b.2c and 2b.2a): the `experts` argument of
# e3d_quote and e3d_debate (E3D_MCP_EXPERTS_AGENT=1), validated here, priced by billing's agent routes, echoed back, and run with the planner flags a web
# run uses; and the fail-closed rule: a billing that ignores or refuses the field never gets its lenses run unpriced. Billing is the reference stub
# (examples/external-auth-stub.js) in four modes: priced (STUB_AGENT_EXPERTS=1), an OLDER billing (unset: ignores the field), a flag-off billing
# (=refuse) and the tool surface with the use flag off. No network beyond 127.0.0.1, no real keys, no real billing, no model.
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
const r = await import(pathToFileURL(`${root}/lib/mcp/experts-read.js`).href);
const a = await import(pathToFileURL(`${root}/lib/mcp/agent.js`).href);
const fail = (m) => { console.error(`FAIL: ${m}`); process.exit(1); };
const eq = (x, y, w) => { if (JSON.stringify(x) !== JSON.stringify(y)) fail(`${w}: ${JSON.stringify(x)} != ${JSON.stringify(y)}`); };
// the switch
eq(r.expertsAgentFrom({}).on, false, 'unset: off'); eq(r.expertsAgentFrom({ E3D_MCP_EXPERTS_AGENT: '0' }).on, false, '0: off');
eq(r.expertsAgentFrom({ E3D_MCP_EXPERTS_AGENT: '1', E3D_MCP_EXPERTS: '1' }).on, true, '1 with the listing: on');
eq(r.expertsAgentFrom({ E3D_MCP_EXPERTS_AGENT: '1' }).ok, false, '1 without the listing is refused');
eq(r.expertsAgentFrom({ E3D_MCP_EXPERTS_AGENT: 'yes', E3D_MCP_EXPERTS: '1' }).ok, false, 'junk is refused');
// the argument against the built-in catalogue
const c = r.loadCatalogue(`${root}/lib/specialists`);
const ck = (v, n = 2) => r.checkAgentExperts(v, c, n);
const ok = ck(['skeptic', 'customer']);
eq([ok.ok, ok.ids, ok.list.map((e) => e.id), ok.list.every((e) => /^sha256:[0-9a-f]{64}$/.test(e.hash))], [true, ['skeptic', 'customer'], ['skeptic', 'customer'], true], 'valid pair, pins from the catalogue');
eq(ck(['customer', 'skeptic']).ids, ['customer', 'skeptic'], 'order is kept');
for (const [v, reason] of [['skeptic', 'type'], [null, 'type'], [['skeptic', 7], 'type'], [['Skeptic', 'customer'], 'type'], [['skeptic'], 'too_few'], [[], 'too_few'],
  [['skeptic', 'customer', 'architect'], 'too_many'], [['skeptic', 'no-such-expert'], 'unknown'], [['skeptic', 'skeptic'], 'duplicate']]) eq(ck(v).reason, reason, `${JSON.stringify(v)}`);
eq(ck(['skeptic', 'customer', 'architect'], 4).ok, true, 'three of four providers');
eq(c.experts.every((e) => Number.isInteger(e.lens_bytes) && e.lens_bytes >= 300 && e.lens_bytes <= 640), true, 'every lens block fits the 640-byte headroom');
// the codes
for (const code of ['invalid_experts', 'experts_unavailable']) if (!a.ERROR_CODES.includes(code)) fail(`catalog lacks ${code}`);
eq([a.agentError('invalid_experts').retryable, a.agentError('experts_unavailable').retryable, a.agentError('experts_unavailable').retry_after_seconds], [false, true, 10], 'statuses');
eq(a.fromBilling({ code: 'invalid_experts', message: 'm', retryable: false, remediation: 'r', reason: 'too_few' }).reason, 'too_few', 'billing reason kept');
eq('reason' in a.fromBilling({ code: 'invalid_experts', message: 'm', retryable: false, remediation: 'r', reason: 'Bad Text!' }), false, 'a free-text reason is dropped');
console.log('experts-agent unit tests: ok');
JS
echo "ok - unit: switch, argument validation, codes"

# ---------------------------------------------------------------- the fake billing, in modes
STUB="$ROOT/examples/external-auth-stub.js"
SERVER="$ROOT/bin/e3d-mcp"
SVC="svc-MARKER-$(openssl rand -hex 12)"
TOK_A="caller-MARKER-a-$(openssl rand -hex 12)"
jq -n --arg a "$TOK_A" '{accounts: [{principal: "acct_web", balance: 1000000, keys: [{id: "key-a", token: $a}]}]}' > "$TMP/seed.json"
URL=""
start_stub() { # start_stub <name> [VAR=value ...]  sets URL
  local name="$1"; shift
  rm -f "$TMP/$name.url"
  env STUB_SERVICE_TOKEN="$SVC" STUB_SEED="$TMP/seed.json" STUB_URL_FILE="$TMP/$name.url" STUB_FEATURES="finalize,fetch,authorize-run" STUB_PRICING=1 STUB_AGENT=1 STUB_QUOTE_MAX_CREDITS=40 "$@" node "$STUB" > "$TMP/$name.out" 2> "$TMP/$name.stub.log" &
  PIDS+=("$!")
  for _ in $(seq 1 100); do [[ -s "$TMP/$name.url" ]] && break; sleep 0.05; done
  URL="$(cat "$TMP/$name.url")"
}
ledger() { curl -fsS -H "authorization: Bearer $SVC" "$URL/_stub/state"; }

DEBATE="$TMP/stub-debate"; ARGS="$TMP/debate.args"; : > "$ARGS"
cat > "$DEBATE" <<STUBEOF
#!/usr/bin/env bash
out=""; provs=""; rounds=1; all="\$*"
while [[ \$# -gt 0 ]]; do case "\$1" in --out-dir) out="\$2"; shift 2 ;; --providers) provs="\$2"; shift 2 ;; --rounds) rounds="\$2"; shift 2 ;; *) shift ;; esac; done
echo "SPECIALISTS=\${E3D_SPECIALISTS:-} \$all" >> "$ARGS"
mkdir -p "\$out"
printf '# Debate\n\n## Round 1 -- anthropic-api\n\nJSON file.\n\n## Round 1 -- openai-api\n\nSQLite.\n' > "\$out/transcript.md"
if [[ -n "\${E3D_DEBATE_MAX_TOKENS:-}" ]]; then
  IFS=, read -r -a P <<< "\$provs"
  rows='[]'
  for ((r = 1; r <= rounds; r++)); do for p in "\${P[@]}"; do rows="\$(jq -c --arg k "r\$r:\$p" --arg p "\$p" '. + [{key:\$k, provider:\$p, model:"stub-model-1", input_tokens:100, output_tokens:50, source:"vendor"}]' <<< "\$rows")"; done; done
  rows="\$(jq -c --arg p "\${P[0]}" '. + [{key:"synth", provider:\$p, model:"stub-model-1", input_tokens:200, output_tokens:60, source:"bytes"}]' <<< "\$rows")"
  echo "\$rows" > "\$out/usage.json"
fi
printf 'FINAL ANSWER: use a JSON file.\nCONSENSUS: split\nDISSENT: SQLite has a case.\n'
STUBEOF
chmod +x "$DEBATE"

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
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"experts-agent-test","version":"0"}}}'
mcp() { curl -s -m 60 -X POST "${J[@]}" -H "Authorization: Bearer $TOK_A" ${3:+-H "mcp-session-id: $3"} -d "$2" "http://127.0.0.1:$(cat "$TMP/$1.port")/mcp"; }
sid_of() { curl -s -D "$TMP/h" -o "$TMP/init.body" -X POST "${J[@]}" -H "Authorization: Bearer $TOK_A" -d "$INIT" "http://127.0.0.1:$(cat "$TMP/$1.port")/mcp"; grep -i '^mcp-session-id:' "$TMP/h" | sed -E 's/^[^:]+: *//' | tr -d '\r'; }
tool() { mcp "$1" "$(jq -nc --arg n "$3" --argjson a "$4" '{jsonrpc:"2.0",id:7,method:"tools/call",params:{name:$n,arguments:$a}}')" "$2"; }
list() { mcp "$1" '{"jsonrpc":"2.0","id":3,"method":"tools/list"}' "$2"; }
Q="QCONTENT: a JSON file or SQLite?"
PR='["anthropic-api","openai-api"]'
n_debates() { wc -l < "$ARGS" | tr -d ' '; }
n_agent() { ledger | jq --arg r "$1" '.received["agent_" + $r] // 0'; }
n_res() { ledger | jq '.reservations | length'; }
hash_of() { node --input-type=module -e "import('$ROOT/lib/mcp/experts-read.js').then((m) => process.stdout.write(m.loadCatalogue('$ROOT/lib/specialists').experts.find((e) => e.name === process.argv[1]).content_hash))" "$1"; }
H_SKEPTIC="$(hash_of skeptic)"; H_CUSTOMER="$(hash_of customer)"
[[ "$H_SKEPTIC" =~ ^sha256:[0-9a-f]{64}$ && "$H_CUSTOMER" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "could not read the built-in experts"
EX='["skeptic","customer"]'
EXA="E3D_MCP_EXPERTS=1 E3D_MCP_EXPERTS_AGENT=1"

# ---------------------------------------------------------------- refusals to start
out="$(env E3D_MCP_EXPERTS_AGENT=1 "$SERVER" --http --port 0 2>&1 </dev/null)" && fail "E3D_MCP_EXPERTS_AGENT=1 needs the listing" || true
assert_contains "$out" "E3D_MCP_EXPERTS_AGENT=1 needs E3D_MCP_EXPERTS=1"
out="$(env E3D_MCP_EXPERTS=1 E3D_MCP_EXPERTS_AGENT=1 "$SERVER" 2>&1 </dev/null)" && fail "E3D_MCP_EXPERTS_AGENT=1 needs the agent contract (stdio has none)" || true
assert_contains "$out" "needs the agent contract"
echo "ok - E3D_MCP_EXPERTS_AGENT=1 refuses to start without the listing or without the agent contract"

# ---------------------------------------------------------------- the use flag OFF (listing on): the surface is exactly as before
start_stub plain STUB_AGENT_EXPERTS=1 STUB_AGENT_QUOTE_LIMITS=1
start_server off E3D_MCP_EXPERTS=1
SID="$(sid_of off)"
tl="$(list off "$SID")"
assert_eq "$(jq -c '[.result.tools[] | select(.name=="e3d_debate" or .name=="e3d_quote") | (.inputSchema.properties | has("experts"))]' <<< "$tl")" "[false,false]" "no experts argument with the use flag off"
assert_eq "$(jq -c '[.result.tools[] | select(.name=="e3d_debate") | (.outputSchema.properties | has("experts"))]' <<< "$tl")" "[false]" "no experts output"
assert_eq "$(jq -r .result.instructions "$TMP/init.body" | grep -c 'running a debate with experts is not available')" "1" "the listing instruction still says running is not available"
res="$(tool off "$SID" e3d_quote "$(jq -nc --arg q "$Q" --argjson p "$PR" --argjson e "$EX" '{question:$q,providers:$p,rounds:2,experts:$e}')")"
assert_eq "$(jq -r '.result.structuredContent.error.code' <<< "$res")" "invalid_request" "experts is an unknown argument with the use flag off"
assert_eq "$(n_agent quote)" "0" "nothing reached billing"
le="$(tool off "$SID" e3d_list_experts '{}')"
assert_contains "$(jq -r '.result.structuredContent.notice' <<< "$le")" "not available yet"
assert_eq "$(jq -c '[.result.structuredContent.experts[] | .lens_bytes | type] | unique' <<< "$le")" '["number"]' "the list shows lens_bytes"
echo "ok - use flag off: no experts argument, the old listing text, experts refused as unknown, nothing reached billing; the list shows lens_bytes"

# ---------------------------------------------------------------- the use flag ON, billing prices experts
start_server on $EXA
SID="$(sid_of on)"
INSTR="$(jq -r .result.instructions "$TMP/init.body")"
assert_eq "$INSTR" "$(node --input-type=module -e "import('$ROOT/lib/mcp/agent.js').then(async (a) => { const e = await import('$ROOT/lib/mcp/experts-read.js'); process.stdout.write([a.AGENT_INSTRUCTIONS, e.EXPERTS_USE_INSTRUCTION].join('\n\n')); })")" "initialize: the agent instructions then the use instruction"
for bad in 'smarter' 'better' 'improves' 'accuracy'; do assert_not_contains "$INSTR" "$bad" "no claim words ($bad) in the instructions"; done
tl="$(list on "$SID")"
assert_eq "$(jq -c '[.result.tools[] | select(.name=="e3d_debate" or .name=="e3d_quote") | .inputSchema.properties.experts | [.type, .minItems, .items.type]]' <<< "$tl")" '[["array",2,"string"],["array",2,"string"]]' "experts on both tools"
assert_eq "$(jq -c '[.result.tools[] | select(.name=="e3d_debate") | .outputSchema.properties.experts.type]' <<< "$tl")" '["array"]' "experts in the e3d_debate output"
assert_eq "$(jq -c '[.result.tools[] | select(.name=="e3d_quote") | .outputSchema.properties | has("experts")]' <<< "$tl")" "[true]" "experts in the e3d_quote output"
for bad in 'smarter' 'better' 'improves' 'accuracy'; do assert_not_contains "$(jq -r '.result.tools[] | select(.name=="e3d_debate") | .inputSchema.properties.experts.description' <<< "$tl")" "$bad" "no claim words in the argument text"; done
le="$(tool on "$SID" e3d_get_expert '{"name":"skeptic"}')"
assert_contains "$(jq -r '.result.structuredContent.notice' <<< "$le")" "pass their names in the \`experts\` argument"
assert_contains "$(jq -r '.result.structuredContent.expert.how_to_use' <<< "$le")" 'experts: ["skeptic"'
echo "ok - use flag on: experts on e3d_quote and e3d_debate (and their outputs), the use instruction, the listing text names the argument, no claim words"

# validation happens here, before billing is asked anything
q0="$(n_agent quote)"
chk() { # chk <experts json> <reason>
  local res; res="$(tool on "$SID" e3d_quote "$(jq -nc --arg q "$Q" --argjson p "$PR" --argjson e "$1" '{question:$q,providers:$p,rounds:2,experts:$e}')")"
  assert_eq "$(jq -r '.result.structuredContent.error.code' <<< "$res")" "invalid_experts" "$1"
  assert_eq "$(jq -r '.result.structuredContent.error.reason' <<< "$res")" "$2" "reason for $1"
}
chk '["skeptic"]' too_few; chk '["skeptic","skeptic"]' duplicate; chk '["skeptic","no-such-expert"]' unknown; chk '["skeptic","customer","architect"]' too_many; chk '"skeptic"' type
assert_eq "$(n_agent quote)" "$q0" "invalid experts never reach billing"
echo "ok - invalid experts: too_few, duplicate, unknown, too_many (two providers), type: invalid_experts with the reason, no billing call"

# e3d_quote with experts: billing priced them, the answer shows the cost with and without
res="$(tool on "$SID" e3d_quote "$(jq -nc --arg q "$Q" --argjson p "$PR" --argjson e "$EX" '{question:$q,providers:$p,rounds:2,experts:$e}')")"
assert_eq "$(jq -r '.result.isError // false' <<< "$res")" "false" "$(jq -c . <<< "$res")"
sc="$(jq -c .result.structuredContent <<< "$res")"
QID_EX="$(jq -r .quote_id <<< "$sc")"
assert_eq "$(jq -c '[.max_credits, .experts]' <<< "$sc")" '[15,{"names":["skeptic","customer"],"credits_without":14}]' "the maximum with the lenses and the maximum without"
assert_contains "$(jq -r '.result.content[0].text' <<< "$res")" "With the experts (skeptic, customer); 14 credits without them"
echo "ok - e3d_quote with experts: max_credits 15 with, 14 without, names shown"

# the standard two steps: a quote_id brought in, the lenses run with the web run's planner flags
n0="$(n_debates)"; KEY1="key-ex-$(openssl rand -hex 6)"
res="$(tool on "$SID" e3d_debate "$(jq -nc --arg q "$Q" --argjson p "$PR" --argjson e "$EX" --arg k "$KEY1" --arg id "$QID_EX" '{question:$q,providers:$p,rounds:2,experts:$e,idempotency_key:$k,quote_id:$id}')")"
assert_eq "$(jq -r '.result.isError // false' <<< "$res")" "false" "$(jq -c . <<< "$res")"
assert_eq "$(( $(n_debates) - n0 ))" "1" "one debate process"
line="$(tail -1 "$ARGS")"
assert_contains "$line" "SPECIALISTS=1 " "E3D_SPECIALISTS=1 on the child"
for f in "--specialist skeptic --specialist customer" "--builtin-only" "--fill-pool" "--lens-bytes-max 640" "--expert-pin skeptic=$H_SKEPTIC" "--expert-pin customer=$H_CUSTOMER"; do assert_contains "$line" "$f" "debate flags"; done
assert_eq "$(jq -c '.result.structuredContent.experts | map(.name)' <<< "$res")" '["skeptic","customer"]' "the result names the experts"
assert_eq "$(jq -c '.result.structuredContent.experts | map(.version | type) | unique' <<< "$res")" '["string"]' "with this catalogue's versions"
assert_eq "$(ledger | jq -r --arg id "$QID_EX" '.reservations[] | select(.request_id == $id) | .state')" "settled" "reserved under the quote's id and settled"
echo "ok - quote then run with experts: begin matched, reserved under the quote id, run with --specialist x2 --builtin-only --fill-pool --lens-bytes-max 640 --expert-pin x2 and E3D_SPECIALISTS=1, result names them"

# a replay returns the stored result with the experts, and runs nothing
n1="$(n_debates)"; r1="$(n_res)"
res="$(tool on "$SID" e3d_debate "$(jq -nc --arg q "$Q" --argjson p "$PR" --argjson e "$EX" --arg k "$KEY1" --arg id "$QID_EX" '{question:$q,providers:$p,rounds:2,experts:$e,idempotency_key:$k,quote_id:$id}')")"
assert_eq "$(jq -c '.result.structuredContent | [.replayed, (.experts | map(.name))]' <<< "$res")" '[true,["skeptic","customer"]]' "replayed with the experts"
assert_eq "$(n_debates)" "$n1" "nothing ran"; assert_eq "$(n_res)" "$r1" "nothing reserved"
echo "ok - replay: stored result with experts, nothing ran, nothing reserved"

# one step: a key without a quote_id (this server quotes), same flags
n2="$(n_debates)"
res="$(tool on "$SID" e3d_debate "$(jq -nc --arg q "$Q" --argjson p "$PR" --argjson e '["customer","skeptic"]' --arg k "key-one-$(openssl rand -hex 6)" '{question:$q,providers:$p,rounds:2,experts:$e,idempotency_key:$k}')")"
assert_eq "$(jq -r '.result.isError // false' <<< "$res")" "false" "$(jq -c . <<< "$res")"
assert_contains "$(tail -1 "$ARGS")" "--specialist customer --specialist skeptic" "the order asked is the order run"
assert_eq "$(( $(n_debates) - n2 ))" "1" "one debate process"
echo "ok - key without quote_id: this server quotes with the experts and runs them in the order asked"

# experts need a key: the legacy path would run them unpriced
n3="$(n_debates)"
res="$(tool on "$SID" e3d_debate "$(jq -nc --arg q "$Q" --argjson p "$PR" --argjson e "$EX" '{question:$q,providers:$p,rounds:2,experts:$e}')")"
assert_eq "$(jq -r '.result.structuredContent.error.code' <<< "$res")" "invalid_request" "experts without an idempotency_key"
assert_contains "$(jq -r '.result.structuredContent.error.message' <<< "$res")" "idempotency_key"
assert_eq "$(n_debates)" "$n3" "nothing ran"
echo "ok - experts without an idempotency_key: invalid_request, nothing ran"

# the quote must be for the same experts
for variant in 'reordered:["customer","skeptic"]' 'none:null'; do
  name="${variant%%:*}"; val="${variant#*:}"
  q="$(tool on "$SID" e3d_quote "$(jq -nc --arg q "$Q" --argjson p "$PR" --argjson e "$EX" '{question:$q,providers:$p,rounds:2,experts:$e}')")"; qid="$(jq -r .result.structuredContent.quote_id <<< "$q")"
  args="$(jq -nc --arg q "$Q" --argjson p "$PR" --argjson e "$val" --arg k "key-mm-$(openssl rand -hex 6)" --arg id "$qid" '{question:$q,providers:$p,rounds:2,idempotency_key:$k,quote_id:$id} + (if $e == null then {} else {experts:$e} end)')"
  nm="$(n_debates)"
  res="$(tool on "$SID" e3d_debate "$args")"
  assert_eq "$(jq -c '.result.structuredContent.error | [.code, .mismatch]' <<< "$res")" '["quote_mismatch",["experts"]]' "$name experts against a quote for skeptic,customer"
  assert_eq "$(n_debates)" "$nm" "nothing ran ($name)"
done
echo "ok - begin: other order or no experts against a quote with experts is quote_mismatch [experts], nothing ran"

# ---------------------------------------------------------------- e3d_investigate with experts (hosted, E3D_MCP_CASE=1): priced as a case run WITH lenses
start_server inv $EXA E3D_MCP_CASE=1
SIDI="$(sid_of inv)"
tl="$(list inv "$SIDI")"
assert_eq "$(jq -c '[.result.tools[] | select(.name=="e3d_investigate") | .inputSchema.properties.experts | [.type, .minItems]]' <<< "$tl")" '[["array",2]]' "e3d_investigate lists experts when the use flag is on"
assert_contains "$(jq -r '.result.tools[] | select(.name=="e3d_investigate") | .inputSchema.properties.experts.description' <<< "$tl")" "on every round"
res="$(tool inv "$SIDI" e3d_quote "$(jq -nc --arg q "$Q inv" --argjson p "$PR" --argjson e "$EX" '{question:$q,providers:$p,rounds:2,experts:$e,investigate:true}')")"
assert_eq "$(jq -r '.result.structuredContent.experts.names | join(",")' <<< "$res")" "skeptic,customer" "quote of round 1 with experts and investigate: $(jq -c . <<< "$res" | head -c 300)"
QID_I="$(jq -r .result.structuredContent.quote_id <<< "$res")"
n0="$(n_debates)"
res="$(tool inv "$SIDI" e3d_investigate "$(jq -nc --arg q "$Q inv" --argjson p "$PR" --argjson e "$EX" '{question:$q,providers:$p,rounds:2,experts:$e}')")"
assert_eq "$(jq -r '.result.structuredContent.error.code' <<< "$res")" "invalid_request" "e3d_investigate with experts and no idempotency_key: refused"
assert_eq "$(n_debates)" "$n0" "nothing ran without the key"
b0="$(n_agent begin)"
res="$(tool inv "$SIDI" e3d_investigate "$(jq -nc --arg q "$Q inv" --argjson p "$PR" --argjson e "$EX" --arg k "key-inv-$(openssl rand -hex 6)" --arg id "$QID_I" '{question:$q,providers:$p,rounds:2,experts:$e,idempotency_key:$k,quote_id:$id}')")"
assert_eq "$(jq -r '.result.isError // false' <<< "$res")" "false" "e3d_investigate with experts ran: $(jq -c . <<< "$res" | head -c 400)"
assert_eq "$(jq -r '.result.structuredContent.experts | map(.name) | join(",")' <<< "$res")" "skeptic,customer" "the result names the experts"
assert_eq "$(( $(n_debates) - n0 ))" "1" "one debate ran, with the lenses"
assert_eq "$(( $(n_agent begin) - b0 ))" "1" "begin was called once"
# round 2 without experts on a hosted server: no stored case, priced and run without lenses
n1="$(n_debates)"
res="$(tool inv "$SIDI" e3d_investigate "$(jq -nc --arg q "$Q inv" --argjson p "$PR" --arg k "key-inv2-$(openssl rand -hex 6)" '{question:$q,providers:$p,rounds:2,idempotency_key:$k}')")"
assert_eq "$(jq -r '.result.structuredContent.experts // "none"' <<< "$res")" "none" "a case round without experts carries none"
echo "ok - hosted e3d_investigate takes experts: listed, quoted with investigate, key required, runs with the lenses, none unless named"

# the use flag OFF: e3d_investigate does not list experts and refuses them
start_server invoff E3D_MCP_EXPERTS=1 E3D_MCP_CASE=1
SIDF="$(sid_of invoff)"
assert_eq "$(jq -c '[.result.tools[] | select(.name=="e3d_investigate") | .inputSchema.properties | has("experts")]' <<< "$(list invoff "$SIDF")")" "[false]" "no experts argument on e3d_investigate with the use flag off"
res="$(tool invoff "$SIDF" e3d_investigate "$(jq -nc --arg q "$Q" --argjson p "$PR" --argjson e "$EX" --arg k "key-f-$(openssl rand -hex 6)" '{question:$q,providers:$p,rounds:2,experts:$e,idempotency_key:$k}')")"
assert_eq "$(jq -r '.result.isError' <<< "$res")" "true" "experts refused with the use flag off"
echo "ok - use flag off: e3d_investigate neither lists nor accepts experts"

# ---------------------------------------------------------------- an OLDER billing ignores the field: the lenses are never run unpriced
start_stub old STUB_AGENT_QUOTE_LIMITS=1
start_server old $EXA
SIDO="$(sid_of old)"
n4="$(n_debates)"
res="$(tool old "$SIDO" e3d_quote "$(jq -nc --arg q "$Q" --argjson p "$PR" --argjson e "$EX" '{question:$q,providers:$p,rounds:2,experts:$e}')")"
assert_eq "$(jq -r '.result.structuredContent.error | [.code, .retryable]' <<< "$res" | tr -d '\n ')" '["experts_unavailable",true]' "e3d_quote: billing did not price the experts"
res="$(tool old "$SIDO" e3d_debate "$(jq -nc --arg q "$Q" --argjson p "$PR" --argjson e "$EX" --arg k "key-old-$(openssl rand -hex 6)" '{question:$q,providers:$p,rounds:2,experts:$e,idempotency_key:$k}')")"
assert_eq "$(jq -r '.result.structuredContent.error.code' <<< "$res")" "experts_unavailable" "fresh quote path: the missing echo stops the run"
# a quote brought in (made WITHOUT experts through this server: an older billing cannot price them): begin ignores the field, the missing echo stops the run
q="$(tool old "$SIDO" e3d_quote "$(jq -nc --arg q "$Q" --argjson p "$PR" '{question:$q,providers:$p,rounds:2}')")"; qid="$(jq -r .result.structuredContent.quote_id <<< "$q")"
[[ -n "$qid" && "$qid" != null ]] || fail "no plain quote on the older billing: $q"
b0="$(n_agent begin)"
res="$(tool old "$SIDO" e3d_debate "$(jq -nc --arg q "$Q" --argjson p "$PR" --argjson e "$EX" --arg k "key-old2-$(openssl rand -hex 6)" --arg id "$qid" '{question:$q,providers:$p,rounds:2,experts:$e,idempotency_key:$k,quote_id:$id}')")"
assert_eq "$(jq -r '.result.structuredContent.error.code' <<< "$res")" "experts_unavailable" "brought quote path: begin answered without the echo"
assert_eq "$(( $(n_agent begin) - b0 ))" "1" "begin WAS called (the echo is checked on its answer), and the run still did not start"
assert_eq "$(n_debates)" "$n4" "an older billing: nothing ran, not even on the begin path"
assert_eq "$(n_res)" "0" "an older billing: nothing was reserved"
echo "ok - an older billing that ignores experts: experts_unavailable on the quote and on the run, nothing reserved, nothing ran"

# ---------------------------------------------------------------- billing with its flag off REFUSES: the code comes through
start_stub off STUB_AGENT_EXPERTS=refuse STUB_AGENT_QUOTE_LIMITS=1
start_server refuse $EXA
SIDR="$(sid_of refuse)"
res="$(tool refuse "$SIDR" e3d_quote "$(jq -nc --arg q "$Q" --argjson p "$PR" --argjson e "$EX" '{question:$q,providers:$p,rounds:2,experts:$e}')")"
assert_eq "$(jq -c '.result.structuredContent.error | [.code, .retryable]' <<< "$res")" '["experts_unavailable",true]' "billing's refusal is passed on"
res="$(tool refuse "$SIDR" e3d_quote "$(jq -nc --arg q "$Q" --argjson p "$PR" '{question:$q,providers:$p,rounds:2}')")"
assert_eq "$(jq -r '.result.isError // false' <<< "$res")" "false" "a quote without experts is unaffected"
assert_eq "$(jq -r '.result.structuredContent.max_credits' <<< "$res")" "14" "and priced as before"
echo "ok - billing with experts off refuses (experts_unavailable); a plain quote is unaffected"

# ---------------------------------------------------------------- no content, expert hash or key in the logs beyond ids
for f in "$TMP"/*.log; do
  assert_not_contains "$(cat "$f")" "QCONTENT" "no question in $f"
  assert_not_contains "$(cat "$f")" "$TOK_A" "no key in $f"
done
echo "mcp-experts-agent: all passed"
