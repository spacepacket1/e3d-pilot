#!/usr/bin/env bash
set -euo pipefail

# Token pricing (per_token_v1): unit tests, the four API adapters and e3d-debate against a fake vendor (output limits, answer-bytes
# truncation, usage rows, no retry), and a fake billing round-trip (the reference stub with STUB_PRICING=1): the capability, the web run
# fields, the connector quote, the usage report before finalize, and the pricing result. No network beyond 127.0.0.1, no real keys.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-assert_eq}: expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "${3:-assert_contains}: expected to find [$2] in [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "${3:-assert_not_contains}: did not expect [$2] in [$1]"; }

# ---------------------------------------------------------------- unit level
node "$ROOT/tests/fixtures/pertoken-test.mjs" "$TMP/unit" | tee "$TMP/unit.out"
assert_contains "$(cat "$TMP/unit.out")" "token pricing unit tests:"

# ---------------------------------------------------------------- the fake vendor
VREQ="$TMP/vendor.jsonl"; : > "$VREQ"
ANSWER='日本語のテスト回答です。これはとても長い回答ですね。'
FAKE_ANSWER="$ANSWER" node "$ROOT/tests/fixtures/fake-vendor.mjs" "$VREQ" "$TMP/vendor.port" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$TMP/vendor.port" ]] && break; sleep 0.05; done
VP="$(cat "$TMP/vendor.port")"
vendor_env=(ANTHROPIC_API_KEY=k-anth ANTHROPIC_API_BASE_URL="http://127.0.0.1:$VP" OPENAI_API_KEY=k-oai OPENAI_API_BASE_URL="http://127.0.0.1:$VP/v1"
  GEMINI_API_KEY=k-gem GEMINI_API_BASE_URL="http://127.0.0.1:$VP/v1" XAI_API_KEY=k-xai XAI_API_BASE_URL="http://127.0.0.1:$VP/v1"
  GEMINI_API_MODEL=gem-test XAI_API_MODEL=xai-test OPENAI_API_TIMEOUT=2 ANTHROPIC_API_TIMEOUT=2 E3D_DEBATE_WEB_SEARCH=off TYPESAFE_API_KEY="")
vreq_count() { wc -l < "$VREQ" | tr -d ' '; }
echo "ok - fake vendor up"

# ---------------------------------------------------------------- adapters: normalised usage and the output limit
printf 'What is 2+2?\n' > "$TMP/prompt.md"
usage_line() { grep '^e3d_provider_usage=' "$1" | tail -1 | sed 's/^e3d_provider_usage=//'; }
: > "$VREQ"
env "${vendor_env[@]}" ANTHROPIC_API_MODEL=claude-test ANTHROPIC_API_MAX_TOKENS=111 "$ROOT/lib/providers/anthropic-api" "$TMP/prompt.md" > /dev/null 2> "$TMP/a.err"
u="$(usage_line "$TMP/a.err")"
assert_eq "$(jq -c '[.input_tokens, .output_tokens, .tokens]' <<< "$u")" "[19,7,18]" "Anthropic: input counts every billed class (cache writes and reads), output is the vendor's"
assert_eq "$(jq '.body.max_tokens' "$VREQ")" "111"
env "${vendor_env[@]}" OPENAI_API_MODEL=gpt-test OPENAI_API_MAX_TOKENS=222 "$ROOT/lib/providers/openai-api" "$TMP/prompt.md" > /dev/null 2> "$TMP/o.err"
assert_eq "$(usage_line "$TMP/o.err" | jq -c '[.input_tokens, .output_tokens]')" "[13,17]" "OpenAI-compatible: output includes the 12 tokens completion_tokens leaves out (reasoning, thinking)"
assert_eq "$(tail -1 "$VREQ" | jq '.body.max_completion_tokens')" "222"
env "${vendor_env[@]}" GEMINI_API_MAX_TOKENS=333 "$ROOT/lib/providers/gemini-api" "$TMP/prompt.md" > /dev/null 2> "$TMP/g.err"
assert_eq "$(tail -1 "$VREQ" | jq '.body.max_tokens')" "333"; assert_eq "$(usage_line "$TMP/g.err" | jq -c '[.input_tokens, .output_tokens]')" "[13,17]"
env "${vendor_env[@]}" XAI_API_MAX_TOKENS=444 "$ROOT/lib/providers/xai-api" "$TMP/prompt.md" > /dev/null 2> "$TMP/x.err"
assert_eq "$(tail -1 "$VREQ" | jq '.body.max_tokens')" "444"; assert_eq "$(usage_line "$TMP/x.err" | jq -c '[.input_tokens, .output_tokens]')" "[13,17]"
# no limit set: nothing is sent, exactly as before (anthropic keeps its own default)
env "${vendor_env[@]}" OPENAI_API_MODEL=gpt-test "$ROOT/lib/providers/openai-api" "$TMP/prompt.md" > /dev/null 2> /dev/null
assert_eq "$(tail -1 "$VREQ" | jq '.body | has("max_completion_tokens")')" "false"
# no usage in the response: nulls, so the debate falls back to bytes
env "${vendor_env[@]}" OPENAI_API_MODEL=gpt-nousage "$ROOT/lib/providers/openai-api" "$TMP/prompt.md" > /dev/null 2> "$TMP/n.err"
assert_eq "$(usage_line "$TMP/n.err" | jq -c '[.input_tokens, .output_tokens]')" "[null,null]"
# a 200 with no content is billed: the usage line is printed before the failure
rc=0; env "${vendor_env[@]}" OPENAI_API_MODEL=gpt-empty "$ROOT/lib/providers/openai-api" "$TMP/prompt.md" > /dev/null 2> "$TMP/e.err" || rc=$?
assert_eq "$rc" "1"; assert_eq "$(usage_line "$TMP/e.err" | jq -c '[.input_tokens, .output_tokens]')" "[13,17]" "usage of an empty answer"
echo "ok - the four adapters send the output limit and report normalised billed tokens (reasoning, thinking and cache classes included)"

# ---------------------------------------------------------------- e3d-debate in per-token mode
PROVS=anthropic-api,openai-api
dbt() { # dbt <out-dir> [extra env...] -- [e3d-debate args...]; stdout+stderr to $TMP/dbt.out
  local out="$1"; shift
  local envs=(); while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done; shift || true
  env "${vendor_env[@]}" ANTHROPIC_API_MODEL=claude-test OPENAI_API_MODEL=gpt-test ${envs[@]+"${envs[@]}"} "$ROOT/bin/e3d-debate" --providers "$PROVS" --synthesizer anthropic-api --out-dir "$out" "$@" > "$TMP/dbt.out" 2>&1
}
MAXT='{"anthropic-api":321,"openai-api":456}'
ANSB='{"anthropic-api":40,"openai-api":50}'

: > "$VREQ"
dbt "$TMP/o1" E3D_DEBATE_MAX_TOKENS="$MAXT" E3D_DEBATE_ANSWER_BYTES_MAX="$ANSB" -- --rounds 2 "Which?"
assert_eq "$(vreq_count)" "5" "exactly the planned calls: 2 rounds x 2 providers + the synthesis"
assert_eq "$(jq -c 'select(.url == "/v1/messages") | .body.max_tokens' "$VREQ" | sort -u | tr '\n' ' ')" "321 " "every Anthropic call sends max_tokens = 321"
assert_eq "$(jq -c 'select(.url != "/v1/messages") | .body.max_completion_tokens' "$VREQ" | sort -u | tr '\n' ' ')" "456 " "every OpenAI call sends max_completion_tokens = 456"
# prior answers inserted into the round 2 and synthesis prompts are cut to the per-provider byte limit, on a character boundary
node - "$VREQ" "$ANSWER" <<'JS'
const fs = require('node:fs');
const [file, answer] = process.argv.slice(2);
const reqs = fs.readFileSync(file, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
const prompt = (r) => r.body.messages[0].content;
const section = (text, name) => { const m = new RegExp(`--- ${name}[^\\n]*---\\n([\\s\\S]*?)\\n\\n(?:---|Every participant)`).exec(text); return m && m[1]; };
const round2 = reqs.filter((r) => /round 2 of a structured debate/.test(prompt(r)));
if (round2.length !== 2) throw new Error(`expected 2 round 2 prompts, got ${round2.length}`);
for (const r of round2) {
  const other = /^--- (anthropic-api|openai-api) \(previous round\)/m.exec(prompt(r))[1];
  const limit = other === 'anthropic-api' ? 40 : 50;
  const got = section(prompt(r), `${other} \\(previous round\\)`);
  const own = section(prompt(r), 'YOU');
  if (Buffer.byteLength(got) > limit || !answer.startsWith(got) || got.length < 5) throw new Error(`the other answer is cut to <= ${limit} bytes: ${Buffer.byteLength(got)} [${got}]`);
  const ownLimit = other === 'anthropic-api' ? 50 : 40; // the receiver's own answer is cut by its own provider's limit
  if (Buffer.byteLength(own) > ownLimit || !answer.startsWith(own)) throw new Error(`own answer is cut to <= ${ownLimit} bytes: ${Buffer.byteLength(own)}`);
  for (const t of [got, own]) if (Buffer.from(t, 'utf8').toString('utf8') !== t || t.includes('\uFFFD')) throw new Error('cut on a character boundary');
}
const synth = reqs.filter((r) => /Below is the full transcript/.test(prompt(r)));
if (synth.length !== 1) throw new Error('one synthesis prompt');
const blocks = [...prompt(synth[0]).matchAll(/## Round (\d) -- (anthropic-api|openai-api)\n\n([\s\S]*?)\n\n(?=## |Read the transcript)/g)];
if (blocks.length !== 4) throw new Error(`4 answers in the synthesis transcript, got ${blocks.length}`);
for (const [, , p, raw] of blocks) { const body = raw.trimEnd(); if (Buffer.byteLength(body) > (p === 'anthropic-api' ? 40 : 50) || !answer.startsWith(body)) throw new Error(`synthesis answer for ${p} is cut`); }
JS
# the record keeps the whole answers
assert_contains "$(cat "$TMP/o1/transcript.md")" "$ANSWER" "transcript.md has the full answer"
assert_eq "$(grep -c "$ANSWER" "$TMP/o1/transcript.md")" "5" "four round answers and the synthesis, whole"
assert_eq "$(jq -c '[.[] | .key]' "$TMP/o1/usage.json")" '["r1:anthropic-api","r1:openai-api","r2:anthropic-api","r2:openai-api","synth"]' "one row per attempted call"
assert_eq "$(jq -c '[.[] | select(.provider == "anthropic-api") | [.input_tokens, .output_tokens, .source, .model]] | unique' "$TMP/o1/usage.json")" '[[19,7,"vendor","claude-test-20261001"]]'
assert_eq "$(jq -c '[.[] | select(.provider == "openai-api") | [.input_tokens, .output_tokens, .source]] | unique' "$TMP/o1/usage.json")" '[[13,17,"vendor"]]'
echo "ok - e3d-debate sends each provider's output limit, makes exactly the planned calls, cuts inserted answers to the byte limit and reports one vendor row per call"

# without the variables nothing changes: no usage.json, whole answers in prompts, no output limit sent
: > "$VREQ"
dbt "$TMP/o2" -- --rounds 2 "Which?"
assert_eq "$(vreq_count)" "5"
[[ ! -e "$TMP/o2/usage.json" ]] || fail "no usage.json without per-token mode"
assert_eq "$(jq -c 'select(.url != "/v1/messages") | .body | has("max_completion_tokens")' "$VREQ" | sort -u | tr '\n' ' ')" "false " "no limit sent when the variable is unset"
assert_eq "$(jq -c 'select(.url == "/v1/messages") | .body.max_tokens' "$VREQ" | sort -u | tr '\n' ' ')" "4096 " "the adapter default is untouched"
assert_contains "$(jq -r 'select(.body.messages[0].content | test("round 2 of a structured")) | .body.messages[0].content' "$VREQ" | head -20)" "$ANSWER" "whole answers in the prompts"
assert_eq "$(jq -c '.body.messages[0].content | select(test("round 2 of"))' "$VREQ" | grep -c "$ANSWER")" "2"
echo "ok - without the new variables e3d-debate behaves as before"

# answer truncation alone (no output limits): the prompts are cut, nothing else changes, no usage.json
: > "$VREQ"
dbt "$TMP/o3" E3D_DEBATE_ANSWER_BYTES_MAX="$ANSB" -- --rounds 2 "Which?"
[[ ! -e "$TMP/o3/usage.json" ]] || fail "truncation alone is not per-token mode"
assert_eq "$(jq -c 'select(.url == "/v1/messages") | .body.max_tokens' "$VREQ" | sort -u | tr '\n' ' ')" "4096 "
assert_eq "$(jq -c '.body.messages[0].content | select(test("round 2 of")) | contains("'"$ANSWER"'")' "$VREQ" | sort -u | tr '\n' ' ')" "false "
echo "ok - E3D_DEBATE_ANSWER_BYTES_MAX works on its own"

# invalid settings stop the debate before any call
: > "$VREQ"
for bad in '{"anthropic-api":321}' 'nonsense' '{"anthropic-api":0,"openai-api":1}'; do
  rc=0; dbt "$TMP/o4" E3D_DEBATE_MAX_TOKENS="$bad" -- --rounds 1 "Which?" || rc=$?
  assert_eq "$rc" "1" "refused: $bad"
done
rc=0; env "${vendor_env[@]}" E3D_DEBATE_MAX_TOKENS='{"claude":1,"codex":1}' "$ROOT/bin/e3d-debate" --providers claude,codex --synthesizer claude "Which?" > "$TMP/dbt.out" 2>&1 || rc=$?
assert_eq "$rc" "1"; assert_contains "$(cat "$TMP/dbt.out")" "API providers only"
assert_eq "$(vreq_count)" "0" "no vendor call for an invalid setting"
echo "ok - invalid or incomplete limits, and non-API providers, are refused before any call"

# failures: no retry after the vendor may have been reached; rows only for attempted calls
run_fail() { # run_fail <name> <openai model>
  : > "$VREQ"
  dbt "$TMP/$1" E3D_DEBATE_MAX_TOKENS="$MAXT" OPENAI_API_MODEL="$2" E3D_DEBATE_PROVIDER_RETRY_DELAY=0 -- --rounds 1 "Which?" || true
}
run_fail f429 gpt-429
assert_eq "$(jq -c 'select(.body.model == "gpt-429")' "$VREQ" | wc -l | tr -d ' ')" "1" "a 429 is not retried per token (it would be a second call)"
assert_eq "$(jq -c '[.[] | .key]' "$TMP/f429/usage.json")" '["r1:anthropic-api","synth"]' "a vendor HTTP error is not a billed call: no row"
run_fail f500 gpt-500
assert_eq "$(jq -c 'select(.body.model == "gpt-500")' "$VREQ" | wc -l | tr -d ' ')" "1"
assert_eq "$(jq -c '[.[] | .key]' "$TMP/f500/usage.json")" '["r1:anthropic-api","synth"]'
run_fail fnousage gpt-nousage
row="$(jq -c '.[] | select(.key == "r1:openai-api")' "$TMP/fnousage/usage.json")"
assert_eq "$(jq -r .source <<< "$row")" "bytes" "usage missing: an estimate"
assert_eq "$(jq -r .input_tokens <<< "$row")" "$(jq -j 'select(.body.model | startswith("gpt-nousage")) | .body.messages[0].content' "$VREQ" | wc -c | tr -d ' ')" "input = UTF-8 bytes of the prompt sent"
assert_eq "$(jq -r .output_tokens <<< "$row")" "$(printf '%s\n' "$ANSWER" | wc -c | tr -d ' ')" "output = UTF-8 bytes of the output received (the adapter ends it with a newline)"
run_fail fhang gpt-hang
row="$(jq -c '.[] | select(.key == "r1:openai-api")' "$TMP/fhang/usage.json")"
assert_eq "$(jq -c '[.source, .output_tokens]' <<< "$row")" '["bytes",456]' "a lost response is charged at its output limit, never an undercount"
assert_eq "$(jq -c 'select(.body.model == "gpt-hang")' "$VREQ" | wc -l | tr -d ' ')" "1" "a timed out call is not retried"
run_fail fempty gpt-empty
# a 200 with no text is retried once (E3D_DEBATE_NO_TEXT_RETRIES, same request, same limit); both attempts are counted in the call's ONE row
assert_eq "$(jq -c 'select(.body.model == "gpt-empty")' "$VREQ" | wc -l | tr -d ' ')" "2" "one retry of a 200 with no text"
assert_eq "$(jq -c 'select(.body.model == "gpt-empty") | .body.max_completion_tokens' "$VREQ" | sort -u | tr '\n' ' ')" "456 " "the retry never raises the output limit"
assert_eq "$(jq -c '.[] | select(.key == "r1:openai-api") | [.source, .input_tokens, .output_tokens]' "$TMP/fempty/usage.json")" '["vendor",26,34]' "a call that failed after the vendor returned usage keeps its vendor rows, summed over its attempts"
: > "$VREQ"
dbt "$TMP/fempty0" E3D_DEBATE_MAX_TOKENS="$MAXT" OPENAI_API_MODEL=gpt-empty E3D_DEBATE_PROVIDER_RETRY_DELAY=0 E3D_DEBATE_NO_TEXT_RETRIES=0 -- --rounds 1 "Which?" || true
assert_eq "$(jq -c '.[] | select(.key == "r1:openai-api") | [.source, .input_tokens, .output_tokens]' "$TMP/fempty0/usage.json")" '["vendor",13,17]' "no retry with E3D_DEBATE_NO_TEXT_RETRIES=0: one vendor row"
echo "ok - failures: no retry after a possible vendor call, no row for a call the vendor refused, bytes rows when usage is missing, max_tokens when the response was lost"

# a stopped debate (SIGTERM, as e3d-mcp sends on a timeout) still reports the calls that were under way
: > "$VREQ"
env "${vendor_env[@]}" ANTHROPIC_API_MODEL=claude-test OPENAI_API_MODEL=gpt-hang OPENAI_API_TIMEOUT=60 E3D_DEBATE_MAX_TOKENS="$MAXT" \
  "$ROOT/bin/e3d-debate" --providers "$PROVS" --synthesizer anthropic-api --out-dir "$TMP/term" --rounds 1 "Which?" > "$TMP/term.out" 2>&1 &
DPID=$!
for _ in $(seq 1 100); do [[ "$(vreq_count)" == "2" ]] && break; sleep 0.1; done
sleep 0.5
kill -TERM "$DPID"; rc=0; wait "$DPID" || rc=$?
assert_eq "$rc" "143"
assert_eq "$(jq -c '[.[] | [.key, .source, .output_tokens]]' "$TMP/term/usage.json")" '[["r1:anthropic-api","vendor",7],["r1:openai-api","bytes",456]]' "the finished call keeps its vendor row; the call under way is an estimate at its limit"
pkill -f "e3d-pilot-openai" 2>/dev/null || true
echo "ok - a stopped debate leaves a row for every call that was under way"

# the prompt overhead measurement (docs/token-pricing.md): fixed text of each prompt kind with empty inputs
ov="$(E3D_DEBATE_PROMPT_OVERHEAD=1 "$ROOT/bin/e3d-debate" --providers anthropic-api,openai-api --rounds 2)"
assert_eq "$(jq -c '.promptOverheadBytes | keys' <<< "$ov")" '["round1","roundN","synthesis"]'
assert_eq "$(jq -r '[.promptOverheadBytes[] | select(. > 0)] | length' <<< "$ov")" "3"
assert_eq "$(jq -r .prompt_version <<< "$ov")" "v2"
ov2="$(E3D_DEBATE_PROMPT_OVERHEAD=1 "$ROOT/bin/e3d-debate" --providers anthropic-api,openai-api --rounds 3)"
[[ "$(jq -r .promptOverheadBytes.synthesis <<< "$ov2")" -gt "$(jq -r .promptOverheadBytes.synthesis <<< "$ov")" ]] || fail "the synthesis overhead grows with the rounds (empty answer slots)"
# the measurement is exact for the fixed text: a real round 1 prompt is the overhead plus the question's bytes
: > "$VREQ"; dbt "$TMP/oh" -- --rounds 2 "Q"
r1len="$(jq -j -s 'map(select(.body.messages[0].content | test("independently answering"))) | .[0].body.messages[0].content' "$VREQ" | wc -c | tr -d ' ')"
assert_eq "$r1len" "$(( $(jq -r .promptOverheadBytes.round1 <<< "$ov") + 1 ))" "round 1 prompt = fixed text + the question"
echo "ok - E3D_DEBATE_PROMPT_OVERHEAD prints the byte counts of each prompt kind: $(jq -c .promptOverheadBytes <<< "$ov")"

# ---------------------------------------------------------------- the fake billing round-trip
STUB="$ROOT/examples/external-auth-stub.js"
SERVER="$ROOT/bin/e3d-mcp"
SVC="svc-MARKER-$(openssl rand -hex 12)"
RUNTOK="runtok-MARKER-$(openssl rand -hex 16)"
TOK_A="caller-MARKER-a-$(openssl rand -hex 12)"
jq -n --arg a "$TOK_A" '{accounts: [{principal: "acct_web", balance: 1000000, keys: [{id: "key-a", token: $a}]}]}' > "$TMP/seed.json"
env STUB_SERVICE_TOKEN="$SVC" STUB_SEED="$TMP/seed.json" STUB_URL_FILE="$TMP/stub.url" STUB_FEATURES="finalize,fetch,authorize-run" STUB_PRICING=1 STUB_QUOTE_MAX_CREDITS=15 node "$STUB" > "$TMP/stub.out" 2> "$TMP/stub.log" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$TMP/stub.url" ]] && break; sleep 0.05; done
URL="$(cat "$TMP/stub.url")"
ledger() { curl -fsS -H "authorization: Bearer $SVC" "$URL/_stub/state"; }
new_id() { echo "dbt_$(openssl rand -hex 12)"; }
billing() { curl -sS -X POST -H "authorization: Bearer $SVC" -H 'content-type: application/json' "${@:2}" "$URL/$1"; }   # billing <path> -H ... -d ...

DEBATE="$TMP/stub-debate"; ARGS="$TMP/debate.args"; ENVS="$TMP/debate.envs"; : > "$ARGS"; : > "$ENVS"
cat > "$DEBATE" <<STUBEOF
#!/usr/bin/env bash
out=""; provs=""; rounds=1; all="\$*"
while [[ \$# -gt 0 ]]; do case "\$1" in --out-dir) out="\$2"; shift 2 ;; --providers) provs="\$2"; shift 2 ;; --rounds) rounds="\$2"; shift 2 ;; *) shift ;; esac; done
echo "\$all" >> "$ARGS"
env | grep '^E3D_DEBATE_' | sort | tr '\n' ' ' >> "$ENVS"; echo >> "$ENVS"
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

BASE_ENV=(E3D_MCP_AUTH_URL="$URL" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" E3D_MCP_DEBATE_BIN="$DEBATE" TYPESAFE_API_KEY="" E3D_MCP_PRINCIPAL=""
  E3D_MCP_AUTH_CACHE_SEC=1 E3D_MCP_TIMEOUT_SEC=20 E3D_MCP_AUTH_HEALTH_SEC=1 E3D_MCP_RATE_PER_MIN=100000)

# configuration errors
out="$(env "${BASE_ENV[@]}" E3D_MCP_STATE_DIR="$TMP/state-bad" E3D_MCP_PRICING=per_debate "$SERVER" --http --port 0 2>&1)" && fail "an unknown pricing mode must refuse to start" || true
assert_contains "$out" "E3D_MCP_PRICING must be unset or per_token"
out="$(env "${BASE_ENV[@]}" E3D_MCP_STATE_DIR="$TMP/state-bad" E3D_MCP_PRICING=per_token "$SERVER" --http --port 0 2>&1)" && fail "per_token needs the customer limits" || true
assert_contains "$out" "E3D_MCP_CUSTOMER_LIMITS"
out="$(printf '' | env E3D_MCP_PRICING=per_token E3D_MCP_CUSTOMER_LIMITS=rounds=2,max_words=300 "$SERVER" 2>&1)" && fail "stdio must refuse per_token" || true
assert_contains "$out" "hosted mode"
echo "ok - E3D_MCP_PRICING is validated at startup"

start_server() { # start_server <name> [VAR=value ...]
  local name="$1"; shift
  : > "$TMP/$name.port"; : > "$TMP/$name.runport"
  env "${BASE_ENV[@]}" E3D_MCP_STATE_DIR="$TMP/state-$name" E3D_MCP_PORT_FILE="$TMP/$name.port" E3D_MCP_RUN_PORT=0 E3D_MCP_RUN_PORT_FILE="$TMP/$name.runport" E3D_MCP_RUN_TOKEN="$RUNTOK" "$@" \
    "$SERVER" --http --port 0 2>> "$TMP/$name.log" &
  PIDS+=("$!")
  for _ in $(seq 1 100); do [[ -s "$TMP/$name.runport" ]] && break; sleep 0.1; done
  [[ -s "$TMP/$name.runport" ]] || { cat "$TMP/$name.log" >&2; fail "server $name did not start"; }
}
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"pertoken-test","version":"0"}}}'
J=(-H 'content-type: application/json' -H 'accept: application/json')
# an introspect teaches the server the service's features (a restart needs one)
learn() { curl -s -o /dev/null -X POST "${J[@]}" -H "Authorization: Bearer $TOK_A" -d "$INIT" "http://127.0.0.1:$(cat "$TMP/$1.port")/mcp"; }
sid_of() { curl -s -D "$TMP/h" -o /dev/null -X POST "${J[@]}" -H "Authorization: Bearer $TOK_A" -d "$INIT" "http://127.0.0.1:$(cat "$TMP/$1.port")/mcp"; grep -i '^mcp-session-id:' "$TMP/h" | sed -E 's/^[^:]+: *//' | tr -d '\r'; }
tool() { curl -s -m 60 -X POST "${J[@]}" -H "Authorization: Bearer $TOK_A" -H "mcp-session-id: $2" -d "$(jq -nc --arg n "$3" --argjson a "$4" '{jsonrpc:"2.0",id:7,method:"tools/call",params:{name:$n,arguments:$a}}')" "http://127.0.0.1:$(cat "$TMP/$1.port")/mcp"; }

# --- a server WITHOUT E3D_MCP_PRICING: no capability, the new fields are refused, an older billing keeps working ---
start_server old
RPORT="$(cat "$TMP/old.runport")"; RUN="http://127.0.0.1:$RPORT/internal/runs"
learn old
rpost() { curl -s -o "$TMP/rbody" -w '%{http_code}' -X POST -H "authorization: Bearer $RUNTOK" -H 'content-type: application/json' -d "$1" "$RUN"; echo; cat "$TMP/rbody"; echo; }
code() { head -1 <<< "$1"; }
js() { tail -n +2 <<< "$1"; }
health="$(rpost '{}')"
assert_eq "$(code "$health")" "400"; assert_eq "$(js "$health" | jq -c '[.ok, .code, has("capabilities")]')" '[false,"invalid",false]' "no capability without E3D_MCP_PRICING=per_token"
Q="QCONTENT: a JSON file or SQLite?"
web_reserve() { # web_reserve <request id> <calls> -> reservation id
  billing reserve -H 'x-e3d-auth-version: 1' -d "$(jq -nc --arg r "$1" --argjson c "$2" '{principal:"acct_web",request_id:$r,kind:"debate",tool:"web",units:{calls:$c,est_tokens:0}}')" | jq -r .reservation_id
}
web_debate() { billing _stub/web-debate -d "$(jq -nc --arg r "$1" --arg d "$2" --arg q "$Q" '{reservation_id:$r,debate_id:$d,question:$q}')" > /dev/null; }
rget() { curl -s -H "authorization: Bearer $RUNTOK" -H "x-e3d-run-token: $2" "$RUN/$1"; }
wait_run() { for _ in $(seq 1 150); do [[ "$(rget "$1" "$2" | jq -r '.run.status // empty')" == "$3" ]] && return 0; sleep 0.2; done; fail "run $1 did not reach $3: $(rget "$1" "$2")"; }
ledger_pricing() { ledger | jq -c "$1"; }
RID0="$(uuidgen | tr 'A-Z' 'a-z')"; R0="$(web_reserve "$RID0" 3)"; D0="$(new_id)"; web_debate "$R0" "$D0"
r="$(rpost "$(jq -nc --arg r "$R0" --arg d "$D0" --arg q "$Q" '{reservation_id:$r,debate_id:$d,question:$q,providers:["anthropic-api","openai-api"]}')")"
assert_eq "$(code "$r")" "202" "an older billing (no new fields): $(js "$r")"; RT0="$(js "$r" | jq -r .run_token)"; wait_run "$D0" "$RT0" done
assert_not_contains "$(tail -1 "$ENVS")" "E3D_DEBATE_MAX_TOKENS" "no limits without the fields"
assert_eq "$(ledger | jq -c --arg r "$R0" '.pricing.reports[$r] // "none"')" '"none"' "no usage report for a debate without the fields"
R0b="$(web_reserve "$(uuidgen | tr 'A-Z' 'a-z')" 3)"; D0b="$(new_id)"; web_debate "$R0b" "$D0b"
FIELDS='{"rounds":2,"max_words":300,"max_tokens":{"anthropic-api":728,"openai-api":728},"answer_bytes":{"anthropic-api":2000,"openai-api":2000}}'
r="$(rpost "$(jq -nc --arg r "$R0b" --arg d "$D0b" --arg q "$Q" --argjson f "$FIELDS" '{reservation_id:$r,debate_id:$d,question:$q,providers:["anthropic-api","openai-api"]} + $f')")"
assert_eq "$(code "$r")" "400" "fields sent to a listener without per_token_v1 are refused"; assert_eq "$(js "$r" | jq -r .code)" "invalid"
echo "ok - without E3D_MCP_PRICING: no capability, the new fields are refused (400 invalid), and a body without them runs as before"

# --- a server WITH E3D_MCP_PRICING=per_token ---
start_server pt E3D_MCP_PRICING=per_token E3D_MCP_CUSTOMER_LIMITS='rounds=2,max_words=300,providers=3'
RPORT="$(cat "$TMP/pt.runport")"; RUN="http://127.0.0.1:$RPORT/internal/runs"
learn pt
health="$(rpost '{}')"
assert_eq "$(code "$health")" "400"; assert_eq "$(js "$health" | jq -c '[.ok, .code, .capabilities]')" '[false,"invalid",["per_token_v1"]]' "the health answer advertises per_token_v1"
echo "ok - the run listener's health answer advertises per_token_v1 with E3D_MCP_PRICING=per_token"

# billing's side of a web debate: quote (write-once), reserve with calls = P x R + 1, the debate record, then the run body with the quoted limits
QRID="$(uuidgen | tr 'A-Z' 'a-z')"
SHA="$(printf '%s' "$Q" | shasum -a 256 | cut -d' ' -f1)"
quote="$(billing pricing/v1/quote -H 'x-e3d-pricing-version: 1' -d "$(jq -nc --arg r "$QRID" --arg s "$SHA" --argjson b "$(printf '%s' "$Q" | wc -c | tr -d ' ')" '{principal:"acct_web",request_id:$r,providers:["anthropic-api","openai-api"],rounds:2,max_words:300,question_bytes:$b,question_sha256:$s,prompt_version:"v2"}')")"
assert_eq "$(jq -r .ok <<< "$quote")" "true"
R1="$(web_reserve "$QRID" 5)"; D1="$(new_id)"; web_debate "$R1" "$D1"
body1="$(jq -nc --arg r "$R1" --arg d "$D1" --arg q "$Q" --argjson m "$(jq -c .max_tokens <<< "$quote")" --argjson a "$(jq -c .answer_bytes <<< "$quote")" \
  '{reservation_id:$r,debate_id:$d,question:$q,providers:["anthropic-api","openai-api"],rounds:2,max_words:300,max_tokens:$m,answer_bytes:$a}')"
n_before="$(wc -l < "$ARGS" | tr -d ' ')"
r="$(rpost "$body1")"; assert_eq "$(code "$r")" "202" "accepted: $(js "$r")"; RT1="$(js "$r" | jq -r .run_token)"
wait_run "$D1" "$RT1" done
last_args="$(tail -1 "$ARGS")"
assert_contains "$last_args" "--rounds 2"; assert_contains "$last_args" "--max-words 300"; assert_contains "$last_args" "--web-search off" "web search is not priced, so it is off"
assert_eq "$(( $(wc -l < "$ARGS" | tr -d ' ') - n_before ))" "1" "one debate process"
assert_contains "$(tail -1 "$ENVS")" 'E3D_DEBATE_ANSWER_BYTES_MAX={"anthropic-api":6000,"openai-api":6000}'
assert_contains "$(tail -1 "$ENVS")" 'E3D_DEBATE_MAX_TOKENS={"anthropic-api":700,"openai-api":700}'
rep="$(ledger | jq -c --arg r "$R1" '.pricing.reports[$r]')"
assert_eq "$(jq -c '[.rows[] | .key]' <<< "$rep")" '["r1:anthropic-api","r1:openai-api","r2:anthropic-api","r2:openai-api","synth"]' "the usage report has every row of usage.json"
assert_eq "$(jq -c '[.rows[] | .source] | unique' <<< "$rep")" '["bytes","vendor"]'
assert_eq "$(ledger | jq -c --arg r "$R1" '[.pricing.order[] | select(.[1] == $r) | .[0]]')" '["reserve","usage","finalize"]' "quote, then reserve, the usage report BEFORE finalize"
assert_eq "$(ledger | jq -c --arg r "$QRID" '[.pricing.quotes[] | select(.request_id == $r) | [.calls, .rounds, .max_words]]')" "[[5,2,300]]"
assert_eq "$(ledger | jq -r --arg d "$D1" '[.effects[] | select(.debate_id == $d)] | length')" "1" "one finalize"
echo "ok - web round-trip: the quoted rounds, word cap, limits and answer-bytes reach the debate, and the usage report goes to billing before finalize"

# refusals: a body that cannot be honoured is 400 invalid, nothing runs, nothing is clamped or defaulted
n_before="$(wc -l < "$ARGS" | tr -d ' ')"
for bad in '.rounds = 3' '.max_words = 301' 'del(.max_tokens)' 'del(.answer_bytes)' 'del(.rounds)' 'del(.max_words)' '.max_tokens["openai-api"] = 0' '.max_tokens |= del(.["openai-api"])' '.answer_bytes |= del(.["openai-api"])' '.max_tokens["gemini-api"] = 9 | .answer_bytes["gemini-api"] = 9 | .max_tokens |= del(.["openai-api"]) | .answer_bytes |= del(.["openai-api"])'; do
  RB="$(web_reserve "$(uuidgen | tr 'A-Z' 'a-z')" 5)"; DB="$(new_id)"; web_debate "$RB" "$DB"
  r="$(rpost "$(jq -c --arg r "$RB" --arg d "$DB" "$bad | .reservation_id = \$r | .debate_id = \$d" <<< "$body1")")"
  assert_eq "$(code "$r")" "400" "refused [$bad]: $(js "$r")"; assert_eq "$(js "$r" | jq -r '[.code, .accepted] | join(",")')" "invalid,false"
done
# a provider that cannot be priced (CLI voice) or whose reasoning is uncapped (xAI) is refused, not run
for prov in claude xai-api; do
  RB="$(web_reserve "$(uuidgen | tr 'A-Z' 'a-z')" 5)"; DB="$(new_id)"; web_debate "$RB" "$DB"
  r="$(rpost "$(jq -c --arg r "$RB" --arg d "$DB" --arg p "$prov" '.reservation_id = $r | .debate_id = $d | .providers = ["anthropic-api", $p] | .max_tokens[$p] = 100 | .answer_bytes[$p] = 100' <<< "$body1")")"
  assert_eq "$(code "$r")" "400" "[$prov] is not offered per token: $(js "$r")"
done
sleep 0.5; assert_eq "$(wc -l < "$ARGS" | tr -d ' ')" "$n_before" "no debate ran for any refused body"
# an identical retry is the same run; changed limits are a conflict
r="$(rpost "$body1")"; assert_eq "$(code "$r")" "200"; assert_eq "$(js "$r" | jq -r '.run_token == "'"$RT1"'"')" "true"
r="$(rpost "$(jq -c '.max_tokens["openai-api"] = 729' <<< "$body1")")"; assert_eq "$(code "$r")" "409" "the limits are part of the idempotency key"
echo "ok - refused: rounds or max_words above the customer limits, missing or partial fields, uncapped or unpriced providers; limits are part of the idempotency key"

# rounds and max_words are older optional fields: without max_tokens and answer_bytes they are clamped to the customer maxima as before
R2c="$(web_reserve "$(uuidgen | tr 'A-Z' 'a-z')" 3)"; D2c="$(new_id)"; web_debate "$R2c" "$D2c"
r="$(rpost "$(jq -nc --arg r "$R2c" --arg d "$D2c" --arg q "$Q" '{reservation_id:$r,debate_id:$d,question:$q,providers:["anthropic-api","openai-api"],rounds:3,max_words:300}')")"
assert_eq "$(code "$r")" "202" "a legacy body with rounds above the maximum is clamped, not refused: $(js "$r")"; wait_run "$D2c" "$(js "$r" | jq -r .run_token)" done
assert_contains "$(tail -1 "$ARGS")" "--rounds 2"; assert_not_contains "$(tail -1 "$ENVS")" "E3D_DEBATE_MAX_TOKENS"
echo "ok - a body without max_tokens and answer_bytes is the older behaviour (rounds clamped, no limits, no usage report)"

# a lower rounds/max_words than the customer limits is honoured as sent (never replaced by a default)
QRID2="$(uuidgen | tr 'A-Z' 'a-z')"
quote2="$(billing pricing/v1/quote -H 'x-e3d-pricing-version: 1' -d "$(jq -nc --arg r "$QRID2" --arg s "$SHA" '{principal:"acct_web",request_id:$r,providers:["anthropic-api","openai-api"],rounds:1,max_words:120,question_bytes:40,question_sha256:$s,prompt_version:"v2"}')")"
R2="$(web_reserve "$QRID2" 3)"; D2="$(new_id)"; web_debate "$R2" "$D2"
r="$(rpost "$(jq -nc --arg r "$R2" --arg d "$D2" --arg q "$Q" --argjson m "$(jq -c .max_tokens <<< "$quote2")" --argjson a "$(jq -c .answer_bytes <<< "$quote2")" '{reservation_id:$r,debate_id:$d,question:$q,providers:["anthropic-api","openai-api"],rounds:1,max_words:120,max_tokens:$m,answer_bytes:$a}')")"
assert_eq "$(code "$r")" "202"; wait_run "$D2" "$(js "$r" | jq -r .run_token)" done
assert_contains "$(tail -1 "$ARGS")" "--rounds 1"; assert_contains "$(tail -1 "$ARGS")" "--max-words 120"
assert_eq "$(ledger | jq -c --arg r "$R2" '.pricing.reports[$r].rows | length')" "3"
echo "ok - quoted rounds and word cap below the customer limits are run exactly"

# --- the connector path: quote with the reserve's request id, units.calls = P x R + 1, limits from the quote, pricing in the result ---
SID="$(sid_of pt)"
n_res="$(ledger | jq '.reservations | length')"
res="$(tool pt "$SID" e3d_debate '{"question":"JSON or SQLite?","providers":["anthropic-api","openai-api"],"rounds":2}')"
assert_eq "$(jq -r '.result.isError // false' <<< "$res")" "false" "$(jq -c . <<< "$res")"
sc="$(jq -c .result.structuredContent <<< "$res")"
assert_eq "$(jq -c '[.billing.quote_credits, .billing.charged_credits, .billing.usage.source, .billing.usage.input_tokens, .billing.usage.output_tokens]' <<< "$sc")" '[14,4,"estimate",600,260]' "the billing object gains the quote, the charge and the usage (estimate: one row was bytes)"
assert_eq "$(jq -r '.billing | has("pricing")' <<< "$sc")" "false"
assert_eq "$(jq -r .usage.estimate <<< "$sc")" "true" "usage.estimate stays true when the source is an estimate"
assert_contains "$(jq -r '.result.content[0].text' <<< "$res")" "Charged 4 credits (at most 14 were held)"
QL="$(ledger | jq -c '.pricing.quotes | map(select(.rounds == 2 and .providers == ["anthropic-api","openai-api"] and .max_words == 80)) | last')"
assert_eq "$(jq -r .calls <<< "$QL")" "5" "units.calls = providers x rounds + 1"
assert_eq "$(jq -r '.reservation_id != null' <<< "$QL")" "true" "the reserve used the quote's request id"
RV="$(jq -r .reservation_id <<< "$QL")"
assert_eq "$(ledger | jq -c --arg r "$RV" '[.pricing.order[] | select(.[1] == $r) | .[0]]')" '["reserve","usage","finalize"]'
assert_eq "$(ledger | jq -c --arg r "$RV" '.pricing.reports[$r].rows | length')" "5"
assert_contains "$(tail -1 "$ENVS")" 'E3D_DEBATE_MAX_TOKENS={"anthropic-api":700,"openai-api":700}'
assert_contains "$(tail -1 "$ARGS")" "--web-search off"
echo "ok - connector round-trip: quote first, reserve with providers x rounds + 1, limits from the quote, usage report before finalize, pricing in the tool result"

# quote refusals stop the call before any reserve
res="$(tool pt "$SID" e3d_debate '{"question":"JSON or SQLite?","providers":["anthropic-api","openai-api"],"rounds":3}')"
assert_eq "$(jq -r '.result.isError' <<< "$res")" "true"; assert_contains "$(jq -r '.result.content[0].text' <<< "$res")" "above the per-debate maximum of 15"
res="$(tool pt "$SID" e3d_debate '{"question":"JSON or SQLite?","providers":["claude","codex"]}')"
assert_eq "$(jq -r '.result.isError' <<< "$res")" "true"; assert_contains "$(jq -r '.result.content[0].text' <<< "$res")" "cannot be priced"
assert_eq "$(ledger | jq '.reservations | length')" "$(( n_res + 1 ))" "refused quotes reserved nothing"
echo "ok - a refused quote (over the maximum, an unpriced voice) stops the tool call before any reserve"

# the async tool: the same quote-then-reserve, the limits survive in the run
res="$(tool pt "$SID" e3d_debate_start '{"question":"JSON or SQLite async?","providers":["anthropic-api","openai-api"],"rounds":2}')"
assert_eq "$(jq -r '.result.isError // false' <<< "$res")" "false" "$(jq -c . <<< "$res")"
DID="$(jq -r .result.structuredContent.debate_id <<< "$res")"
for _ in $(seq 1 100); do [[ "$(jq -r .result.structuredContent.status <<< "$(tool pt "$SID" e3d_debate_status "{\"debate_id\":\"$DID\"}")")" == "done" ]] && break; sleep 0.2; done
assert_eq "$(ledger | jq '.pricing.reports | length')" "4" "an async debate reports its usage too"
assert_contains "$(tail -1 "$ENVS")" 'E3D_DEBATE_MAX_TOKENS='
echo "ok - e3d_debate_start quotes, reserves and runs under the quoted limits"

# --- privacy: no content or token in any log ---
for f in "$TMP/old.log" "$TMP/pt.log" "$TMP/stub.log"; do
  if grep -lE "QCONTENT" "$f"; then fail "debate content leaked into $f"; fi
  for secret in "$SVC" "$RUNTOK" "$TOK_A" "$RT1"; do if grep -qF -- "$secret" "$f"; then fail "a token leaked into $f"; fi; done
done
echo "ok - no content or token in logs"
echo "pertoken: all passed"
