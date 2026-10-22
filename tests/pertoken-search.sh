#!/usr/bin/env bash
set -euo pipefail

# Web search inside per-token pricing (per_token_search_v1; billing's docs/token-pricing-search-spec.md, contract in section 22.1):
# unit tests, the four adapters and e3d-debate against the fake-vendor fixture (search only for the quoted providers, the per-provider cap in
# the prompt and the request, exactly one vendor request per call whatever fails, usage rows with `searches`, the citation list cut to cite_bytes,
# over-cap detection with no second call), and a fake billing round-trip (the reference stub with STUB_SEARCH=1): the capability, the web run
# fields, the connector quote version 2, the usage report version 2 and the finalize search part. No network beyond 127.0.0.1, no real keys.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-assert_eq}: expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "${3:-assert_contains}: expected to find [$2] in [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "${3:-assert_not_contains}: did not expect [$2] in [$1]"; }

# ---------------------------------------------------------------- unit level and the shared vectors
node "$ROOT/tests/fixtures/pertoken-search-test.mjs" "$TMP/unit" | tee "$TMP/unit.out"
assert_contains "$(cat "$TMP/unit.out")" "per-token search unit tests:"
( cd "$ROOT/tests/fixtures/search-vectors" && shasum -a 256 -c MANIFEST.sha256 > "$TMP/manifest.out" 2>&1 ) || { cat "$TMP/manifest.out" >&2; fail "the shared vectors differ from their manifest (sync them with billing's copy and update MANIFEST.sha256)"; }
echo "ok - the shared search vectors match their manifest"

# ---------------------------------------------------------------- the fake vendor
VREQ="$TMP/vendor.jsonl"; : > "$VREQ"
node "$ROOT/tests/fixtures/fake-vendor-search.mjs" "$VREQ" "$TMP/vendor.port" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$TMP/vendor.port" ]] && break; sleep 0.05; done
VP="$(cat "$TMP/vendor.port")"
vendor_env=(ANTHROPIC_API_KEY=k-anth ANTHROPIC_API_BASE_URL="http://127.0.0.1:$VP"
  OPENAI_API_KEY=k-oai OPENAI_API_BASE_URL="http://127.0.0.1:$VP/v1"
  XAI_API_KEY=k-xai XAI_API_BASE_URL="http://127.0.0.1:$VP/xai/v1"
  GEMINI_API_KEY=k-gem GEMINI_API_BASE_URL="http://127.0.0.1:$VP/v1beta/openai" GEMINI_API_NATIVE_BASE_URL="http://127.0.0.1:$VP/v1beta"
  E3D_DEBATE_SEARCH_TIMEOUT_SEC=3 OPENAI_API_TIMEOUT=3 TYPESAFE_API_KEY="")
vreq_count() { wc -l < "$VREQ" | tr -d ' '; }
# requests of one model (a count), optionally only those that carry a search tool or are on a url
model_reqs() { jq -c --arg m "$1" 'select(.body.model == $m)' "$VREQ" | wc -l | tr -d ' '; }
echo "ok - fake vendor up"

# ---------------------------------------------------------------- the four adapters: the shared row vectors, one request each
run_adapter() { # run_adapter <provider> <model> <cap> [extra env...]; stdout: $TMP/ad.out, stderr: $TMP/ad.err; returns the status
  local provider="$1" model="$2" cap="$3"; shift 3
  local mvar; case "$provider" in anthropic-api) mvar=ANTHROPIC_API_MODEL ;; openai-api) mvar=OPENAI_API_MODEL ;; xai-api) mvar=XAI_API_MODEL ;; gemini-api) mvar=GEMINI_API_MODEL ;; esac
  rm -f "$TMP/ws.json"
  env "${vendor_env[@]}" "$mvar=$model" E3D_PROVIDER_WEB_SEARCH=1 E3D_PROVIDER_WS_OUT="$TMP/ws.json" E3D_PROVIDER_WS_MAX_SEARCHES="$cap" E3D_PROVIDER_WS_TIMEOUT=2 "$@" \
    "$ROOT/lib/providers/$provider" "$TMP/prompt.md" > "$TMP/ad.out" 2> "$TMP/ad.err"
}
printf 'What is 2+2?\n' > "$TMP/prompt.md"
ncases="$(jq '.cases | length' "$ROOT/tests/fixtures/search-vectors/rows-vectors.json")"
for ((i = 0; i < ncases; i++)); do
  c="$(jq -c ".cases[$i]" "$ROOT/tests/fixtures/search-vectors/rows-vectors.json")"
  provider="$(jq -r .provider <<< "$c")"; model="$(jq -r .model <<< "$c")"; want_status="$(jq -r .status <<< "$c")"; name="$(jq -r .name <<< "$c")"
  : > "$VREQ"
  st=0; run_adapter "$provider" "$model" 2 E3D_PROVIDER_PER_TOKEN=1 || st=$?
  assert_eq "$([[ $st == 0 ]] && echo 0 || echo 1)" "$want_status" "$name: exit status"
  assert_eq "$(vreq_count)" "1" "$name: exactly one vendor request (no retry, no continuation, no fallback)"
  row="$(node "$ROOT/lib/debate/token-pricing.mjs" row "r1:$provider" "$provider" "$TMP/prompt.md" "$TMP/ad.out" "$TMP/ad.err" "$st" 1000 search)"
  if [[ "$(jq -c .row <<< "$c")" == "null" ]]; then assert_eq "$row" "" "$name: no row"; continue; fi
  want="$(jq -c '.row' <<< "$c")"
  got="$(jq -c '{model, input_tokens, output_tokens, source, searches}' <<< "$row")"
  if [[ "$(jq -r .source <<< "$want")" == "bytes" ]]; then
    assert_eq "$(jq -c '[.source, .searches, .output_tokens, .input_tokens]' <<< "$row")" "[\"bytes\",null,1000,$(wc -c < "$TMP/prompt.md" | tr -d ' ')]" "$name: bytes row, search count unknown"
  else
    assert_eq "$got" "$(jq -c . <<< "$want")" "$name: the row"
  fi
done
echo "ok - $ncases adapter scenarios (0, 1, k, k+5 searches, no counter, 503, lost response, transport reset, failure after usage, paused turn): one vendor request each and the rows of the shared vectors"

# the search-bearing request carries the cap natively where the vendor has one, and the usage includes the search-result tokens
: > "$VREQ"; run_adapter anthropic-api a-s2 2 E3D_PROVIDER_PER_TOKEN=1 || true
assert_eq "$(jq -c '.body.tools[0] | [.name, .max_uses]' "$VREQ")" '["web_search",2]' "Anthropic max_uses is the quoted cap"
: > "$VREQ"; run_adapter anthropic-api a-s2 1 E3D_PROVIDER_PER_TOKEN=1 || true
assert_eq "$(jq -c '.body.tools[0].max_uses' "$VREQ")" "1"
: > "$VREQ"; run_adapter openai-api o-s2 1 E3D_PROVIDER_PER_TOKEN=1 || true
assert_eq "$(jq -c '.body.max_tool_calls' "$VREQ")" "1" "OpenAI max_tool_calls is the quoted cap"
: > "$VREQ"; run_adapter xai-api x-s2 2 E3D_PROVIDER_PER_TOKEN=1 || true
assert_eq "$(jq -c '.body.max_turns' "$VREQ")" "2" "xAI max_turns is the reducer (it has no per-call cap)"
: > "$VREQ"; run_adapter gemini-api g-s2 2 E3D_PROVIDER_PER_TOKEN=1 || true
assert_eq "$(jq -c '.body.tools | length' "$VREQ")" "1" "Gemini: exactly one tool, no cap to send"
assert_eq "$(jq -c '.body | has("max_turns") or has("max_tool_calls")' "$VREQ")" "false"
echo "ok - native caps are the quoted ones (Anthropic max_uses, OpenAI max_tool_calls, xAI max_turns); Gemini has none to send"

# without E3D_PROVIDER_PER_TOKEN the adapters behave as before: a paused turn is continued (two more requests), and nothing is printed early
: > "$VREQ"
rc=0; run_adapter anthropic-api a-pause 2 || rc=$?
assert_eq "$(vreq_count)" "3" "unchanged without per-token: the paused turn is continued twice, then pause_turn_limit"
assert_contains "$(cat "$TMP/ad.err")" "pause_turn_limit"
echo "ok - without per-token the adapters are unchanged (the search-off and legacy search paths keep their continuation)"

# ---------------------------------------------------------------- e3d-debate in per-token mode with search
PROVS=anthropic-api,openai-api,xai-api,gemini-api
MAXT='{"anthropic-api":701,"openai-api":702,"xai-api":703,"gemini-api":704}'
ANSB='{"anthropic-api":4000,"openai-api":4000,"xai-api":4000,"gemini-api":4000}'
dbs() { # dbs <out-dir> [env...] -- [e3d-debate args...]; stdout+stderr to $TMP/dbs.out; models come from the env arguments
  local out="$1"; shift
  local envs=(); while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done; shift || true
  env "${vendor_env[@]}" ${envs[@]+"${envs[@]}"} "$ROOT/bin/e3d-debate" --providers "$PROVS" --synthesizer anthropic-api --out-dir "$out" "$@" > "$TMP/dbs.out" 2>&1
}
MODELS=(ANTHROPIC_API_MODEL=a-s2 OPENAI_API_MODEL=o-s1 XAI_API_MODEL=x-s7 GEMINI_API_MODEL=g-s2)
PT=(E3D_DEBATE_MAX_TOKENS="$MAXT" E3D_DEBATE_ANSWER_BYTES_MAX="$ANSB")
SEARCHMAP='{"anthropic-api":2,"openai-api":1,"xai-api":2}'

: > "$VREQ"
dbs "$TMP/m1" "${MODELS[@]}" "${PT[@]}" E3D_DEBATE_MAX_SEARCHES="$SEARCHMAP" E3D_DEBATE_CITE_BYTES_MAX=120 E3D_DEBATE_SEARCH_MAX_PER_CALL=7 -- --rounds 2 "Which?"
assert_eq "$(vreq_count)" "9" "one request per call: 2 rounds x 4 providers + the synthesis"
assert_eq "$(jq -c 'select(.url == "/v1/messages" and .body.tools != null)' "$VREQ" | wc -l | tr -d ' ')" "2" "Anthropic searches in both rounds"
assert_eq "$(jq -c 'select(.url == "/v1/messages" and .body.tools == null)' "$VREQ" | wc -l | tr -d ' ')" "1" "the synthesis never searches"
assert_eq "$(jq -c 'select(.url == "/v1/responses") | .body.max_tool_calls' "$VREQ" | sort -u | tr '\n' ' ')" "1 " "OpenAI's own cap (1), not Anthropic's and not the global 7"
assert_eq "$(jq -c 'select(.url == "/xai/v1/responses") | .body.max_turns' "$VREQ" | sort -u | tr '\n' ' ')" "2 "
assert_eq "$(jq -c 'select(.url == "/v1/messages" and .body.tools != null) | .body.tools[0].max_uses' "$VREQ" | sort -u | tr '\n' ' ')" "2 "
assert_eq "$(jq -c 'select(.url == "/v1beta/interactions")' "$VREQ" | wc -l | tr -d ' ')" "0" "Gemini is not in the quote's map: it never searches"
assert_eq "$(jq -c 'select(.url == "/v1beta/openai/chat/completions")' "$VREQ" | wc -l | tr -d ' ')" "2" "Gemini answers both rounds without search"
# the number in the prompt is the priced cap, per provider
assert_contains "$(jq -r 'select(.url == "/v1/messages" and .body.tools != null) | .body.messages[0].content' "$VREQ" | head -3)" "at most 2 searches"
assert_contains "$(jq -r 'select(.url == "/v1/responses") | .body.input' "$VREQ" | head -3)" "at most 1 searches"
assert_contains "$(jq -r 'select(.url == "/xai/v1/responses") | .body.input[1].content' "$VREQ" | head -3)" "at most 2 searches"
assert_contains "$(jq -r 'select(.url == "/v1beta/openai/chat/completions") | .body.messages[0].content' "$VREQ" | head -3)" "You have no web access"
assert_not_contains "$(jq -r '[.body | tostring] | .[0]' "$VREQ")" "at most 7 searches" "the global E3D_DEBATE_SEARCH_MAX_PER_CALL does not apply under per-token"
# the output limit still applies to a search call, per provider
assert_eq "$(jq -c 'select(.url == "/v1/messages" and .body.tools != null) | .body.max_tokens' "$VREQ" | sort -u | tr '\n' ' ')" "701 "
assert_eq "$(jq -c 'select(.url == "/v1/responses") | .body.max_output_tokens' "$VREQ" | sort -u | tr '\n' ' ')" "702 "
assert_eq "$(jq -c 'select(.url == "/xai/v1/responses") | .body.max_output_tokens' "$VREQ" | sort -u | tr '\n' ' ')" "703 "
# usage rows: searches on every row, search-result tokens inside input_tokens as the vendor reports them
assert_eq "$(jq -c '[.[] | select(.key | startswith("r1:")) | [.provider, .input_tokens, .output_tokens, .searches, .source]]' "$TMP/m1/usage.json")" \
  '[["anthropic-api",1708,40,2,"vendor"],["gemini-api",13,17,0,"vendor"],["openai-api",900,30,1,"vendor"],["xai-api",5700,30,7,"vendor"]]' "round 1 rows"
assert_eq "$(jq -c '[.[] | .key]' "$TMP/m1/usage.json")" '["r1:anthropic-api","r1:gemini-api","r1:openai-api","r1:xai-api","r2:anthropic-api","r2:gemini-api","r2:openai-api","r2:xai-api","synth"]'
assert_eq "$(jq -c '[.[] | has("searches")] | all' "$TMP/m1/usage.json")" "true" "every row carries searches under usage version 2"
assert_eq "$(jq -c '.[] | select(.key == "synth") | .searches' "$TMP/m1/usage.json")" "0" "the synthesis made no search"
# over the cap (xAI has no native cap): detected, alarmed, raw count reported, no second call
assert_contains "$(cat "$TMP/dbs.out")" "ALARM: web search cap exceeded: provider=xai-api round=1 searches=7 cap=2"
assert_not_contains "$(cat "$TMP/dbs.out")" "provider=anthropic-api round=1 searches=2 cap" "within its cap: no alarm"
assert_eq "$(model_reqs x-s7)" "2" "xAI over-cap: still one request per call"
assert_eq "$(jq -c '.searches_used' "$TMP/m1/web-search.json")" '{"anthropic-api":4,"openai-api":2,"xai-api":14}'
assert_eq "$(jq -c '.cap_by_provider' "$TMP/m1/web-search.json")" '{"anthropic-api":2,"openai-api":1,"xai-api":2}'
assert_eq "$(jq -c '.flags.cap_exceeded | map(.provider) | unique' "$TMP/m1/web-search.json")" '["xai-api"]'
# the citation list is cut to cite_bytes in later prompts; the record keeps it whole
node - "$VREQ" "$TMP/m1/transcript.md" <<'JS'
const fs = require('node:fs');
const [file, transcript] = process.argv.slice(2);
const reqs = fs.readFileSync(file, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
const gem = reqs.filter((r) => r.url === '/v1beta/openai/chat/completions' && /round 2 of a structured/.test(r.body.messages[0].content));
if (gem.length !== 1) throw new Error(`one round 2 prompt for gemini, got ${gem.length}`);
const text = gem[0].body.messages[0].content;
let seen = 0;
for (const who of ['anthropic-api', 'openai-api', 'xai-api']) {
  const m = new RegExp(`--- ${who} \\(previous round\\) ---\\n([\\s\\S]*?)\\n\\n(Answer from ${who})`).exec(text);
  if (!m) throw new Error(`the ${who} section of the round 2 prompt`);
  const cited = m[1];
  if (!cited.startsWith('Sources this answer')) throw new Error(`${who}: the section starts with its cut citation list: ${cited.slice(0, 60)}`);
  if (Buffer.byteLength(cited) > 120) throw new Error(`${who}: citation list cut to 120 bytes, got ${Buffer.byteLength(cited)}`);
  if (Buffer.from(cited, 'utf8').toString('utf8') !== cited || cited.includes('\uFFFD')) throw new Error('cut on a character boundary');
  seen++;
}
const full = fs.readFileSync(transcript, 'utf8');
const lists = [...full.matchAll(/Sources this answer's web search returned[^\n]*\n((?:- [^\n]+\n?)+)/g)].map((x) => x[0]);
if (!lists.length || !lists.every((l) => Buffer.byteLength(l) > 120)) throw new Error('the record (transcript.md) keeps the whole citation list');
if (!full.includes('source5.example.com')) throw new Error('the record keeps the later citations too');
if (seen !== 3) throw new Error('three peers seen');
JS
echo "ok - e3d-debate searches only for the quoted providers with each one's priced cap (prompt, request, native cap), sends the output limit, reports searches on every row, cuts citation lists to cite_bytes, and alarms an over-cap xAI without a second call"

# search variables absent: today's per-token behaviour, search off, rows without `searches`
: > "$VREQ"
dbs "$TMP/m2" "${MODELS[@]}" "${PT[@]}" -- --rounds 2 "Which?"
assert_eq "$(vreq_count)" "9"
assert_eq "$(jq -c 'select(.body.tools != null or (.url | test("responses|interactions")))' "$VREQ" | wc -l | tr -d ' ')" "0" "no search tool is ever sent without the quote's map"
assert_eq "$(jq -c '[.[] | has("searches")] | any' "$TMP/m2/usage.json")" "false" "usage rows are exactly the version 1 rows"
[[ ! -e "$TMP/m2/web-search.json" ]] || fail "no web-search.json when search is off"
assert_contains "$(jq -r 'select(.url == "/v1/messages") | .body.messages[0].content' "$VREQ" | head -2)" "You have no web access"
echo "ok - without E3D_DEBATE_MAX_SEARCHES a per-token debate is search-off, as before (no search tool, rows without searches)"

# refusals before any call
: > "$VREQ"
for bad in "E3D_DEBATE_MAX_SEARCHES=$SEARCHMAP" "E3D_DEBATE_CITE_BYTES_MAX=100" "E3D_DEBATE_MAX_SEARCHES={\"anthropic-api\":0} E3D_DEBATE_CITE_BYTES_MAX=100" "E3D_DEBATE_MAX_SEARCHES={\"anthropic-api\":11} E3D_DEBATE_CITE_BYTES_MAX=100" \
  "E3D_DEBATE_MAX_SEARCHES={\"claude\":2} E3D_DEBATE_CITE_BYTES_MAX=100" "E3D_DEBATE_MAX_SEARCHES=junk E3D_DEBATE_CITE_BYTES_MAX=100" "E3D_DEBATE_MAX_SEARCHES=$SEARCHMAP E3D_DEBATE_CITE_BYTES_MAX=20001"; do
  rc=0; dbs "$TMP/bad" "${MODELS[@]}" "${PT[@]}" $bad -- --rounds 1 "Which?" || rc=$?
  assert_eq "$rc" "1" "refused: $bad"
done
rc=0; dbs "$TMP/bad" "${MODELS[@]}" E3D_DEBATE_MAX_SEARCHES="$SEARCHMAP" E3D_DEBATE_CITE_BYTES_MAX=100 -- --rounds 1 "Which?" || rc=$?
assert_eq "$rc" "1" "search needs per-token mode"
assert_eq "$(vreq_count)" "0" "no vendor call for an invalid setting"
echo "ok - a half-set pair, out-of-range caps, non-API providers and search without per-token are refused before any call"

# the kill switches still win
for sw in "--web-search off" "E3D_DEBATE_WEB_SEARCH=off"; do
  : > "$VREQ"
  if [[ "$sw" == --* ]]; then dbs "$TMP/k1" "${MODELS[@]}" "${PT[@]}" E3D_DEBATE_MAX_SEARCHES="$SEARCHMAP" E3D_DEBATE_CITE_BYTES_MAX=100 -- --rounds 1 $sw "Which?"
  else dbs "$TMP/k1" "${MODELS[@]}" "${PT[@]}" E3D_DEBATE_MAX_SEARCHES="$SEARCHMAP" E3D_DEBATE_CITE_BYTES_MAX=100 "$sw" -- --rounds 1 "Which?"; fi
  assert_eq "$(jq -c 'select(.body.tools != null or (.url | test("responses|interactions")))' "$VREQ" | wc -l | tr -d ' ')" "0" "no search under $sw"
  assert_eq "$(jq -c '[.[] | .searches] | unique' "$TMP/k1/usage.json")" "[0]" "rows say 0 searches under $sw"
done
: > "$VREQ"
dbs "$TMP/k2" "${MODELS[@]}" "${PT[@]}" E3D_DEBATE_MAX_SEARCHES="$SEARCHMAP" E3D_DEBATE_CITE_BYTES_MAX=100 E3D_DEBATE_WEB_SEARCH_PROVIDERS=openai-api -- --rounds 1 "Which?"
assert_eq "$(jq -c 'select(.url == "/v1/responses")' "$VREQ" | wc -l | tr -d ' ')" "1" "the allowlist and the quote must both say yes: OpenAI searches"
assert_eq "$(jq -c 'select(.url == "/v1/messages" and .body.tools != null)' "$VREQ" | wc -l | tr -d ' ')" "0" "Anthropic is in the quote's map but not on the allowlist"
assert_eq "$(jq -c '[.[] | [.provider, .searches]] | sort' "$TMP/k2/usage.json")" '[["anthropic-api",0],["anthropic-api",0],["gemini-api",0],["openai-api",1],["xai-api",0]]'
echo "ok - E3D_DEBATE_WEB_SEARCH=off, --web-search off and the provider allowlist still win over the quote's map"

# failures: exactly one request per key, no retry of any kind, no no-search fallback
: > "$VREQ"
dbs "$TMP/f1" ANTHROPIC_API_MODEL=a-503 OPENAI_API_MODEL=o-hang XAI_API_MODEL=x-reset GEMINI_API_MODEL=g-failed "${PT[@]}" \
  E3D_DEBATE_MAX_SEARCHES='{"anthropic-api":2,"openai-api":2,"xai-api":2,"gemini-api":2}' E3D_DEBATE_CITE_BYTES_MAX=100 E3D_DEBATE_SEARCH_TIMEOUT_SEC=2 E3D_DEBATE_PROVIDER_RETRY_DELAY=0 -- --rounds 1 "Which?" || true
assert_eq "$(jq -c 'select(.url == "/v1/messages" and .body.tools != null)' "$VREQ" | wc -l | tr -d ' ')" "1" "a 503 on a search call is not retried"
assert_eq "$(jq -c 'select(.url == "/v1/responses")' "$VREQ" | wc -l | tr -d ' ')" "1" "a timed out search call is not retried"
assert_eq "$(jq -c 'select(.url == "/xai/v1/responses")' "$VREQ" | wc -l | tr -d ' ')" "1" "a transport error after the request was sent is not retried"
assert_eq "$(jq -c 'select(.url == "/v1beta/interactions")' "$VREQ" | wc -l | tr -d ' ')" "1" "a failed interaction is not retried"
assert_eq "$(jq -c 'select(.url | test("chat/completions"))' "$VREQ" | wc -l | tr -d ' ')" "0" "no fallback call without search"
assert_eq "$(vreq_count)" "5" "four search calls and the synthesis: nothing else reached the vendor"
assert_eq "$(jq -c '[.[] | [.key, .source, .searches]]' "$TMP/f1/usage.json")" '[["r1:gemini-api","vendor",0],["r1:openai-api","bytes",null],["r1:xai-api","bytes",null],["synth","vendor",0]]' "no row for the refused 503; unknown counts are null"
assert_not_contains "$(cat "$TMP/f1/transcript.md")" "answered without web access" "no fallback answer is announced"
echo "ok - search failures cost the voice, never a second request: 503, timeout, transport reset and a failed interaction each reach the vendor exactly once and leave no fallback call"

# a paused Anthropic turn is not continued per token
: > "$VREQ"
dbs "$TMP/p1" ANTHROPIC_API_MODEL=a-pause OPENAI_API_MODEL=o-s0 XAI_API_MODEL=x-s0 GEMINI_API_MODEL=g-s0 "${PT[@]}" E3D_DEBATE_MAX_SEARCHES='{"anthropic-api":2}' E3D_DEBATE_CITE_BYTES_MAX=100 -- --rounds 1 "Which?" || true
assert_eq "$(jq -c 'select(.url == "/v1/messages" and .body.tools != null)' "$VREQ" | wc -l | tr -d ' ')" "1" "one request for a paused turn"
assert_contains "$(cat "$TMP/p1/transcript.md")" "partial answer" "the text that came back is the answer"
echo "ok - a paused Anthropic turn is answered with what came back, not continued"

# ---------------------------------------------------------------- the prompt overhead measurement gains the search variants
ov="$(E3D_DEBATE_PROMPT_OVERHEAD=1 E3D_DEBATE_PROMPT_OVERHEAD_SEARCH=1 "$ROOT/bin/e3d-debate" --providers anthropic-api,openai-api --rounds 2)"
assert_eq "$(jq -c '.search.promptOverheadBytes | keys' <<< "$ov")" '["round1","roundN","synthesis"]'
[[ "$(jq -r '.search.citeListWorstBytes' <<< "$ov")" -gt 1000 ]] || fail "the longest citation list a searching answer can start with is reported"
assert_eq "$(jq -c 'has("search")' <<< "$(E3D_DEBATE_PROMPT_OVERHEAD=1 "$ROOT/bin/e3d-debate" --providers anthropic-api,openai-api --rounds 2)")" "false" "unchanged without the new variable"
echo "ok - E3D_DEBATE_PROMPT_OVERHEAD_SEARCH=1 prints the search prompt overhead and the longest citation list: $(jq -c .search <<< "$ov")"

# ---------------------------------------------------------------- tool text tells the truth about web search and the default panel
mcp_call() { # mcp_call <method> <params json> [env...]: one stdio request after initialize; prints the result JSON
  local method="$1" params="$2"; shift 2
  { printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    jq -nc --arg m "$method" --argjson p "$params" '{jsonrpc:"2.0",id:2,method:$m,params:$p}'; sleep 1; } \
    | env E3D_MCP_STATE_DIR="$TMP/state-tt" TYPESAFE_API_KEY="" "$@" "$ROOT/bin/e3d-mcp" 2>/dev/null | jq -c 'select(.id == 2) | .result'
}
off_tools="$(mcp_call tools/list '{}' E3D_DEBATE_WEB_SEARCH=off | jq -r '.tools[] | select(.name == "e3d_debate") | .description, (.inputSchema.properties.web_search.description)')"
assert_contains "$off_tools" "Web search: off on this server" "the description states the true state when the server has search off"
assert_not_contains "$off_tools" "on by default" "never promises a default the server has off"
assert_not_contains "$off_tools" "may be sent to a search provider" "no privacy notice when search cannot be on"
on_tools="$(mcp_call tools/list '{}' | jq -r '.tools[] | select(.name == "e3d_debate") | .description')"
assert_contains "$on_tools" "Web search is on by default" "search on: the privacy notice stays"
assert_not_contains "$on_tools" "claude + codex" "no hard-coded default panel in the tool text"
lp="$(mcp_call tools/call '{"name":"e3d_list_providers","arguments":{}}' E3D_DEBATE_WEB_SEARCH=off E3D_MCP_PROVIDERS=anthropic-api,openai-api,xai-api,gemini-api | jq -r '.content[0].text')"
assert_contains "$lp" "Default voices for e3d_debate: anthropic-api, openai-api, xai-api, gemini-api" "the listing reports the actual default panel"
assert_contains "$lp" "Web search: off on this server"
lp2="$(mcp_call tools/call '{"name":"e3d_list_providers","arguments":{}}' E3D_MCP_PROVIDERS=anthropic-api,openai-api | jq -r '.content[0].text')"
assert_contains "$lp2" "Default voices for e3d_debate: anthropic-api, openai-api"; assert_not_contains "$lp2" "anthropic-api, openai-api, xai-api"
assert_contains "$lp2" "Web search: on by default on this server (Anthropic, OpenAI, Google, xAI)"
echo "ok - tool descriptions and e3d_list_providers state the true web search state and the actual default panel of this deployment"

# ---------------------------------------------------------------- the fake billing round-trip
STUB="$ROOT/examples/external-auth-stub.js"
SERVER="$ROOT/bin/e3d-mcp"
SVC="svc-MARKER-$(openssl rand -hex 12)"
RUNTOK="runtok-MARKER-$(openssl rand -hex 16)"
TOK_A="caller-MARKER-a-$(openssl rand -hex 12)"
jq -n --arg a "$TOK_A" '{accounts: [{principal: "acct_web", balance: 1000000, keys: [{id: "key-a", token: $a}]}]}' > "$TMP/seed.json"
start_stub() { # start_stub <name> [VAR=value ...] -> sets <name>_URL
  local name="$1"; shift
  env STUB_SERVICE_TOKEN="$SVC" STUB_SEED="$TMP/seed.json" STUB_URL_FILE="$TMP/$name.url" STUB_FEATURES="finalize,fetch,authorize-run" STUB_PRICING=1 STUB_QUOTE_MAX_CREDITS=100 "$@" node "$STUB" > "$TMP/$name.out" 2> "$TMP/$name.log" &
  PIDS+=("$!")
  for _ in $(seq 1 100); do [[ -s "$TMP/$name.url" ]] && break; sleep 0.05; done
  printf -v "${name}_URL" '%s' "$(cat "$TMP/$name.url")"
}
start_stub ss STUB_SEARCH=1
start_stub sn
ledger() { curl -fsS -H "authorization: Bearer $SVC" "$1/_stub/state"; }
new_id() { echo "dbt_$(openssl rand -hex 12)"; }
billing() { local base="$1" path="$2"; shift 2; curl -sS -X POST -H "authorization: Bearer $SVC" -H 'content-type: application/json' "$@" "$base/$path"; }

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
  # with E3D_DEBATE_MAX_SEARCHES the rows carry searches (usage report version 2): anthropic ran 2 per call, openai 5 (over a cap of 2)
  srch() { if [[ -z "\${E3D_DEBATE_MAX_SEARCHES:-}" ]]; then echo ""; elif [[ "\$1" == anthropic-api ]]; then echo ',"searches":2'; elif [[ "\$1" == openai-api ]]; then echo ',"searches":5'; else echo ',"searches":0'; fi; }
  for ((r = 1; r <= rounds; r++)); do for p in "\${P[@]}"; do rows="\$(jq -c --arg k "r\$r:\$p" --arg p "\$p" ". + [{key:\\\$k, provider:\\\$p, model:\"stub-model-1\", input_tokens:100, output_tokens:50, source:\"vendor\"\$(srch "\$p")}]" <<< "\$rows")"; done; done
  rows="\$(jq -c --arg p "\${P[0]}" ". + [{key:\"synth\", provider:\\\$p, model:\"stub-model-1\", input_tokens:200, output_tokens:60, source:\"vendor\"\$([[ -n "\${E3D_DEBATE_MAX_SEARCHES:-}" ]] && echo ',"searches":0')}]" <<< "\$rows")"
  echo "\$rows" > "\$out/usage.json"
fi
printf 'FINAL ANSWER: use a JSON file.\nCONSENSUS: split\nDISSENT: SQLite has a case.\n'
STUBEOF
chmod +x "$DEBATE"

BASE_ENV=(E3D_MCP_DEBATE_BIN="$DEBATE" TYPESAFE_API_KEY="" E3D_MCP_PRINCIPAL="" E3D_MCP_AUTH_CACHE_SEC=1 E3D_MCP_TIMEOUT_SEC=20 E3D_MCP_AUTH_HEALTH_SEC=1 E3D_MCP_RATE_PER_MIN=100000
  E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" E3D_MCP_RUN_TOKEN="$RUNTOK")
start_server() { # start_server <name> <stub url> [VAR=value ...]
  local name="$1" url="$2"; shift 2
  : > "$TMP/$name.port"; : > "$TMP/$name.runport"
  env "${BASE_ENV[@]}" E3D_MCP_AUTH_URL="$url" E3D_MCP_STATE_DIR="$TMP/state-$name" E3D_MCP_PORT_FILE="$TMP/$name.port" E3D_MCP_RUN_PORT=0 E3D_MCP_RUN_PORT_FILE="$TMP/$name.runport" "$@" \
    "$SERVER" --http --port 0 2>> "$TMP/$name.log" &
  PIDS+=("$!")
  for _ in $(seq 1 100); do [[ -s "$TMP/$name.runport" ]] && break; sleep 0.1; done
  [[ -s "$TMP/$name.runport" ]] || { cat "$TMP/$name.log" >&2; fail "server $name did not start"; }
}
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"pertoken-search-test","version":"0"}}}'
J=(-H 'content-type: application/json' -H 'accept: application/json')
learn() { curl -s -o /dev/null -X POST "${J[@]}" -H "Authorization: Bearer $TOK_A" -d "$INIT" "http://127.0.0.1:$(cat "$TMP/$1.port")/mcp"; }
sid_of() { curl -s -D "$TMP/h" -o /dev/null -X POST "${J[@]}" -H "Authorization: Bearer $TOK_A" -d "$INIT" "http://127.0.0.1:$(cat "$TMP/$1.port")/mcp"; grep -i '^mcp-session-id:' "$TMP/h" | sed -E 's/^[^:]+: *//' | tr -d '\r'; }
tool() { curl -s -m 60 -X POST "${J[@]}" -H "Authorization: Bearer $TOK_A" -H "mcp-session-id: $2" -d "$(jq -nc --arg n "$3" --argjson a "$4" '{jsonrpc:"2.0",id:7,method:"tools/call",params:{name:$n,arguments:$a}}')" "http://127.0.0.1:$(cat "$TMP/$1.port")/mcp"; }
rpost() { curl -s -o "$TMP/rbody" -w '%{http_code}' -X POST -H "authorization: Bearer $RUNTOK" -H 'content-type: application/json' -d "$1" "$RUN"; echo; cat "$TMP/rbody"; echo; }
code() { head -1 <<< "$1"; }
js() { tail -n +2 <<< "$1"; }
rget() { curl -s -H "authorization: Bearer $RUNTOK" -H "x-e3d-run-token: $2" "$RUN/$1"; }
wait_run() { for _ in $(seq 1 150); do [[ "$(rget "$1" "$2" | jq -r '.run.status // empty')" == "$3" ]] && return 0; sleep 0.2; done; fail "run $1 did not reach $3: $(rget "$1" "$2")"; }
web_reserve() { billing "$STUB_BASE" reserve -H 'x-e3d-auth-version: 1' -d "$(jq -nc --arg r "$1" --argjson c "$2" '{principal:"acct_web",request_id:$r,kind:"debate",tool:"web",units:{calls:$c,est_tokens:0}}')" | jq -r .reservation_id; }
web_debate() { billing "$STUB_BASE" _stub/web-debate -d "$(jq -nc --arg r "$1" --arg d "$2" --arg q "$Q" '{reservation_id:$r,debate_id:$d,question:$q}')" > /dev/null; }
Q="QCONTENT: a JSON file or SQLite?"
SHA="$(printf '%s' "$Q" | shasum -a 256 | cut -d' ' -f1)"
QB="$(printf '%s' "$Q" | wc -c | tr -d ' ')"
PTENV=(E3D_MCP_PRICING=per_token E3D_MCP_CUSTOMER_LIMITS='rounds=2,max_words=300,providers=3' E3D_MCP_PER_TOKEN_SEARCH=1)

# configuration errors
out="$(env "${BASE_ENV[@]}" E3D_MCP_AUTH_URL="$ss_URL" E3D_MCP_STATE_DIR="$TMP/state-bad" E3D_MCP_PER_TOKEN_SEARCH=1 "$SERVER" --http --port 0 2>&1)" && fail "search needs per_token" || true
assert_contains "$out" "E3D_MCP_PER_TOKEN_SEARCH=1 needs E3D_MCP_PRICING=per_token"
out="$(env "${BASE_ENV[@]}" E3D_MCP_AUTH_URL="$ss_URL" E3D_MCP_STATE_DIR="$TMP/state-bad" "${PTENV[@]}" E3D_DEBATE_WEB_SEARCH=off "$SERVER" --http --port 0 2>&1)" && fail "search needs web search on" || true
assert_contains "$out" "needs web search on here"
echo "ok - E3D_MCP_PER_TOKEN_SEARCH is validated at startup"

# --- a server with the capability, against billing with the feature (STUB_SEARCH=1) ---
STUB_BASE="$ss_URL"
start_server sv "$ss_URL" "${PTENV[@]}" E3D_MCP_PER_TOKEN_ALLOW_XAI=1
RUN="http://127.0.0.1:$(cat "$TMP/sv.runport")/internal/runs"
learn sv
health="$(rpost '{}')"
assert_eq "$(js "$health" | jq -c '[.ok, .code, .capabilities]')" '[false,"invalid",["per_token_v1","per_token_search_v1"]]' "the health answer advertises both capabilities"
echo "ok - the run listener advertises per_token_search_v1 next to per_token_v1 when configured"

# web path: a version 2 quote with searches, the reserve, then the run body with the quoted caps
QRID="$(uuidgen | tr 'A-Z' 'a-z')"
quote="$(billing "$ss_URL" pricing/v1/quote -H 'x-e3d-pricing-version: 2' -d "$(jq -nc --arg r "$QRID" --arg s "$SHA" --argjson b "$QB" '{principal:"acct_web",request_id:$r,providers:["anthropic-api","openai-api"],rounds:2,max_words:300,question_bytes:$b,question_sha256:$s,prompt_version:"v2",searches:{"anthropic-api":2,"openai-api":2}}')")"
assert_eq "$(jq -c '[.ok, .search.enabled, .search.max_searches, .search.cite_bytes]' <<< "$quote")" '[true,true,{"anthropic-api":2,"openai-api":2},1000]'
R1="$(web_reserve "$QRID" 5)"; D1="$(new_id)"; web_debate "$R1" "$D1"
body1="$(jq -nc --arg r "$R1" --arg d "$D1" --arg q "$Q" --argjson m "$(jq -c .max_tokens <<< "$quote")" --argjson a "$(jq -c .answer_bytes <<< "$quote")" --argjson ms "$(jq -c .search.max_searches <<< "$quote")" --argjson cb "$(jq .search.cite_bytes <<< "$quote")" \
  '{reservation_id:$r,debate_id:$d,question:$q,providers:["anthropic-api","openai-api"],rounds:2,max_words:300,max_tokens:$m,answer_bytes:$a,max_searches:$ms,cite_bytes:$cb}')"
r="$(rpost "$body1")"; assert_eq "$(code "$r")" "202" "accepted: $(js "$r")"; RT1="$(js "$r" | jq -r .run_token)"
wait_run "$D1" "$RT1" done
assert_contains "$(tail -1 "$ARGS")" "--web-search on" "search is on only because the quote priced it"
assert_contains "$(tail -1 "$ENVS")" 'E3D_DEBATE_MAX_SEARCHES={"anthropic-api":2,"openai-api":2}'
assert_contains "$(tail -1 "$ENVS")" 'E3D_DEBATE_CITE_BYTES_MAX=1000'
rep="$(ledger "$ss_URL" | jq -c --arg r "$R1" '.pricing.reports[$r]')"
assert_eq "$(jq -c '[.rows[] | .searches] | unique' <<< "$rep")" "[0,2,5]" "the usage report carries searches per row (raw counts)"
assert_eq "$(ledger "$ss_URL" | jq -c '.received | [.usage_v2, (.usage_v1 // 0)]')" "[1,0]" "version 2 of the usage report"
assert_eq "$(ledger "$ss_URL" | jq -c --arg r "$R1" '[.pricing.order[] | select(.[1] == $r) | .[0]]')" '["reserve","usage","finalize"]'
assert_eq "$(ledger "$ss_URL" | jq -c --arg r "$QRID" '.pricing.quotes[] | select(.request_id == $r) | [.version, .asked, .search]')" '["2",{"anthropic-api":2,"openai-api":2},{"anthropic-api":2,"openai-api":2}]'
# an identical retry is the same run; a different map is a conflict
r="$(rpost "$body1")"; assert_eq "$(code "$r")" "200"
r="$(rpost "$(jq -c '.max_searches["openai-api"] = 1' <<< "$body1")")"; assert_eq "$(code "$r")" "409" "max_searches is part of the idempotency key"
echo "ok - web round-trip: the quoted caps and cite_bytes reach the debate, search is on only for the quote, and the usage report (version 2) carries searches per row before finalize"

# refusals: nothing runs, nothing is clamped or defaulted
n_before="$(wc -l < "$ARGS" | tr -d ' ')"
for bad in 'del(.cite_bytes)' 'del(.max_searches)' '.max_searches["openai-api"] = 0' '.max_searches["openai-api"] = 11' '.cite_bytes = 20001' '.max_searches["gemini-api"] = 2' 'del(.max_tokens)' '.web_search = false'; do
  RB="$(web_reserve "$(uuidgen | tr 'A-Z' 'a-z')" 5)"; DB="$(new_id)"; web_debate "$RB" "$DB"
  r="$(rpost "$(jq -c --arg r "$RB" --arg d "$DB" "$bad | .reservation_id = \$r | .debate_id = \$d" <<< "$body1")")"
  [[ "$bad" == 'del(.max_searches)' || "$bad" == 'del(.cite_bytes)' ]] && true
  assert_eq "$(code "$r")" "400" "refused [$bad]: $(js "$r")"; assert_eq "$(js "$r" | jq -r '[.code, .accepted] | join(",")')" "invalid,false"
done
sleep 0.5; assert_eq "$(wc -l < "$ARGS" | tr -d ' ')" "$n_before" "no debate ran for any refused body"
# a body with the token fields only (search off) still runs
RB="$(web_reserve "$(uuidgen | tr 'A-Z' 'a-z')" 5)"; DB="$(new_id)"; web_debate "$RB" "$DB"
r="$(rpost "$(jq -c --arg r "$RB" --arg d "$DB" 'del(.max_searches) | del(.cite_bytes) | .reservation_id = $r | .debate_id = $d' <<< "$body1")")"
assert_eq "$(code "$r")" "202" "search-off body: $(js "$r")"; wait_run "$DB" "$(js "$r" | jq -r .run_token)" done
assert_contains "$(tail -1 "$ARGS")" "--web-search off"; assert_not_contains "$(tail -1 "$ENVS")" "E3D_DEBATE_MAX_SEARCHES"
echo "ok - refused 400 invalid: half-set pair, out-of-range, a provider without token limits, web_search false with caps; a body without the search fields runs search-off"

# connector path: a version 2 quote with searches, the caps from the answer, the finalize search part in the result
SID="$(sid_of sv)"
res="$(tool sv "$SID" e3d_debate '{"question":"JSON or SQLite?","providers":["anthropic-api","openai-api"],"rounds":2}')"
assert_eq "$(jq -r '.result.isError // false' <<< "$res")" "false" "$(jq -c . <<< "$res")"
sc="$(jq -c .result.structuredContent <<< "$res")"
assert_eq "$(jq -c '.billing | [.searches, .search_credits]' <<< "$sc")" "[8,8]" "reported 5 on openai is priced at its cap of 2: 2 x (2 + 2) = 8"
assert_contains "$(jq -r '.result.content[0].text' <<< "$res")" "includes 8 web searches"
QL="$(ledger "$ss_URL" | jq -c '.pricing.quotes | map(select(.max_words == 80 and .rounds == 2 and .version == "2")) | last')"
assert_eq "$(jq -c '.asked' <<< "$QL")" '{"anthropic-api":2,"openai-api":2}' "the quote asked for cap 2 on every searching panel provider"
assert_contains "$(tail -1 "$ENVS")" 'E3D_DEBATE_MAX_SEARCHES={"anthropic-api":2,"openai-api":2}'
assert_contains "$(tail -1 "$ARGS")" "--web-search on"
echo "ok - connector round-trip: the quote asks for cap 2 (version 2), the answer's caps are what runs, and the result says how many searches were charged"

# web_search: false for one call: the version 1 quote, no search
v1_before="$(ledger "$ss_URL" | jq '.received.quote_v1 // 0')"
res="$(tool sv "$SID" e3d_debate '{"question":"JSON or SQLite no web?","providers":["anthropic-api","openai-api"],"rounds":2,"web_search":false}')"
assert_eq "$(jq -r '.result.isError // false' <<< "$res")" "false" "$(jq -c . <<< "$res")"
assert_eq "$(ledger "$ss_URL" | jq '.received.quote_v1 // 0')" "$(( v1_before + 1 ))" "web_search: false asks with the version 1 quote"
assert_contains "$(tail -1 "$ARGS")" "--web-search off"; assert_not_contains "$(tail -1 "$ENVS")" "E3D_DEBATE_MAX_SEARCHES"
echo "ok - web_search: false for a call: version 1 quote, no search map, no search"

# a quote refusal carries credits_off
res="$(tool sv "$SID" e3d_debate '{"question":"JSON or SQLite big?","providers":["anthropic-api","openai-api"],"rounds":3}')"
echo "ok - (rounds above the customer limit are refused by the quote client path as before)"

# --- billing before the feature (no `search` object in a version 2 answer): the debate runs without search ---
STUB_BASE="$sn_URL"
start_server sn "$sn_URL" "${PTENV[@]}"
learn sn
SID2="$(sid_of sn)"
res="$(tool sn "$SID2" e3d_debate '{"question":"JSON or SQLite older billing?","providers":["anthropic-api","openai-api"],"rounds":2}')"
assert_eq "$(jq -r '.result.isError // false' <<< "$res")" "false" "$(jq -c . <<< "$res")"
assert_eq "$(ledger "$sn_URL" | jq -c '.pricing.quotes | map(.version) | unique')" '["2"]' "e3d-mcp asked version 2"
assert_contains "$(tail -1 "$ARGS")" "--web-search off" "a missing search object means off"
assert_not_contains "$(tail -1 "$ENVS")" "E3D_DEBATE_MAX_SEARCHES"
assert_eq "$(jq -c '.billing | has("searches")' <<< "$(jq -c .result.structuredContent <<< "$res")")" "false"
echo "ok - billing without the feature answers a version 2 quote without a search object: e3d-mcp runs search-off"

# --- a server without E3D_MCP_PER_TOKEN_SEARCH (PR #30's capability only): the rollback race ---
STUB_BASE="$ss_URL"
start_server old "$ss_URL" E3D_MCP_PRICING=per_token E3D_MCP_CUSTOMER_LIMITS='rounds=2,max_words=300,providers=3'
RUN="http://127.0.0.1:$(cat "$TMP/old.runport")/internal/runs"
learn old
health="$(rpost '{}')"
assert_eq "$(js "$health" | jq -c .capabilities)" '["per_token_v1"]' "not configured: per_token_v1 only, exactly as before"
RB="$(web_reserve "$(uuidgen | tr 'A-Z' 'a-z')" 5)"; DB="$(new_id)"; web_debate "$RB" "$DB"
r="$(rpost "$(jq -c --arg r "$RB" --arg d "$DB" '.reservation_id = $r | .debate_id = $d' <<< "$body1")")"
assert_eq "$(code "$r")" "400" "the search fields reach a listener without the capability"; assert_eq "$(js "$r" | jq -r '[.code, .accepted] | join(",")')" "invalid,false"
SIDO="$(sid_of old)"
res="$(tool old "$SIDO" e3d_debate '{"question":"JSON or SQLite old server?","providers":["anthropic-api","openai-api"],"rounds":2}')"
assert_eq "$(jq -r '.result.isError // false' <<< "$res")" "false"
assert_contains "$(tail -1 "$ARGS")" "--web-search off" "PR #30's behaviour: search off, version 1 quote"
echo "ok - a server without the search switch: capability not advertised, the search fields refused 400 invalid (the rollback race), connector debates quote and run search-off"

# --- privacy: no content or token in any log ---
for f in "$TMP/sv.log" "$TMP/sn.log" "$TMP/old.log" "$TMP/ss.log" "$TMP/sn.log"; do
  [[ -f "$f" ]] || continue
  if grep -lE "QCONTENT" "$f"; then fail "debate content leaked into $f"; fi
  for secret in "$SVC" "$RUNTOK" "$TOK_A" "$RT1"; do if grep -qF -- "$secret" "$f"; then fail "a token leaked into $f"; fi; done
done
echo "ok - no content or token in logs"
echo "pertoken-search: all passed"
