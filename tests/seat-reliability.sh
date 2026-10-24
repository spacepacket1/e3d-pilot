#!/usr/bin/env bash
set -euo pipefail

# Seat reliability (docs/seat-reliability.md), end to end against a stateful fake vendor on 127.0.0.1 (tests/fixtures/seat-fake.mjs):
# one bounded retry of a call that answered 200 with no text, no retry of a 4xx, a seat that is lost is dropped and reported, the synthesis
# falls back to another participant (marked everywhere) and fails only when every candidate fails, and in a per-token debate a retry's usage
# is merged into the call's one row (the output limit is never raised). No network beyond 127.0.0.1, no real keys, no spend.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; [[ -f "$TMP/last.out" ]] && tail -20 "$TMP/last.out" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-assert_eq}: expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "${3:-assert_contains}: expected to find [$2] in [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "${3:-assert_not_contains}: did not expect [$2] in [$1]"; }

VREQ="$TMP/vendor.jsonl"; : > "$VREQ"
node "$ROOT/tests/fixtures/seat-fake.mjs" "$VREQ" "$TMP/vendor.port" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$TMP/vendor.port" ]] && break; sleep 0.05; done
VP="$(cat "$TMP/vendor.port")"; [[ -n "$VP" ]] || fail "fake vendor did not start"
vendor_env=(ANTHROPIC_API_KEY=k-anth ANTHROPIC_API_BASE_URL="http://127.0.0.1:$VP" OPENAI_API_KEY=k-oai OPENAI_API_BASE_URL="http://127.0.0.1:$VP/v1"
  GEMINI_API_KEY=k-gem GEMINI_API_BASE_URL="http://127.0.0.1:$VP/v1" XAI_API_KEY=k-xai XAI_API_BASE_URL="http://127.0.0.1:$VP/v1"
  XAI_API_MODEL=xai-test OPENAI_API_TIMEOUT=5 ANTHROPIC_API_TIMEOUT=5 E3D_DEBATE_WEB_SEARCH=off TYPESAFE_API_KEY=""
  E3D_DEBATE_PROVIDER_RETRY_DELAY=0 E3D_DEBATE_PROVIDER_RETRIES=2)
PROVS=anthropic-api,openai-api,gemini-api
# dbt <out-dir> <anthropic model> <openai model> <gemini model> [extra env...] -- [e3d-debate args...]; returns the debate's exit code
dbt() {
  local out="$1" am="$2" om="$3" gm="$4"; shift 4
  local envs=(); while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done; shift || true
  curl -s -X POST "http://127.0.0.1:$VP/reset" > /dev/null; : > "$VREQ"; rm -rf "$out"
  local rc=0
  env "${vendor_env[@]}" ANTHROPIC_API_MODEL="$am" OPENAI_API_MODEL="$om" GEMINI_API_MODEL="$gm" ${envs[@]+"${envs[@]}"} \
    "$ROOT/bin/e3d-debate" --providers "${PROVS_OVERRIDE:-$PROVS}" --synthesizer anthropic-api --out-dir "$out" "$@" > "$TMP/last.out" 2>&1 || rc=$?
  return "$rc"
}
calls() { jq -c --arg m "$1" --arg k "$2" 'select(.model == $m and .kind == $k)' "$VREQ" | wc -l | tr -d ' '; }
OK=(claude-ok gpt-ok gem-ok)
MAXT='{"anthropic-api":321,"openai-api":456,"gemini-api":200,"xai-api":300}'
ANSB='{"anthropic-api":400,"openai-api":400,"gemini-api":400,"xai-api":400}'

# ---- 1. no text on a participant, then success on the retry: the seat stays
rc=0; dbt "$TMP/t1" claude-ok gpt-nt1 gem-ok -- --rounds 1 "Which?" || rc=$?
assert_eq "$rc" 0 "t1 exit"
assert_eq "$(calls gpt-nt1 round)" 2 "t1: one no-text retry"
assert_contains "$(cat "$TMP/last.out")" "returned no text in round 1, retry 1 of 1"
assert_eq "$(jq -c '[.seats_requested, .seats_answered, .seats_unavailable, .flags.seats_lost]' "$TMP/t1/seats.json")" '[3,3,[],false]' "t1 seats"
assert_not_contains "$(cat "$TMP/t1/transcript.md")" "failed in round"
assert_eq "$(jq -c 'select(.model == "gpt-nt1") | .max_tokens' "$VREQ" | sort -u | tr '\n' ' ')" "null " "t1: no output limit outside per-token mode, and none added by the retry"
echo "ok - no text then success on the retry: the seat stays, 3 of 3 answered"

# ---- 2. no text twice: the seat is dropped, with the reason, from the rest of the debate; the debate still succeeds
rc=0; dbt "$TMP/t2" claude-ok gpt-ntall gem-ok -- --rounds 2 "Which?" || rc=$?
assert_eq "$rc" 0 "t2 exit"
assert_eq "$(calls gpt-ntall round)" 2 "t2: the bounded retry, then dropped: not asked in round 2"
assert_eq "$(jq -c '[.seats_requested, .seats_answered, .seats_unavailable, .flags.seats_lost, .flags.fewer_than_3_seats]' "$TMP/t2/seats.json")" '[3,2,[{"provider":"openai-api","round":1,"reason":"no_text"}],true,true]' "t2 seats"
assert_contains "$(jq -r .consensus_note "$TMP/t2/seats.json")" "2 of 3 seats that answered"
assert_contains "$(cat "$TMP/t2/transcript.md")" "provider openai-api failed in round 1 (no_text)"
assert_contains "$(cat "$TMP/t2/transcript.md")" "## Seat dropped -- openai-api"
assert_eq "$(calls claude-ok round)" 2 "t2: the other seats still ran both rounds"
assert_contains "$(cat "$TMP/last.out")" "SEATS: 2 of 3 participants answered; unavailable: openai-api (round 1: no_text)"
assert_eq "$(jq -c '.providers' "$TMP/t2/decision-log.json")" '["anthropic-api","openai-api","gemini-api"]' "the decision log names every requested seat"
echo "ok - no text twice: dropped with reason no_text, debate succeeds on the 2 seats that answered, consensus note present"

# ---- 3. synthesis no text, then the fallback synthesizer succeeds: marked everywhere, charged normally (the call count is the transcript's)
rc=0; dbt "$TMP/t3" claude-ntsynth gpt-ok gem-ok -- --rounds 1 "Which?" || rc=$?
assert_eq "$rc" 0 "t3 exit"
assert_eq "$(calls claude-ntsynth synth)" 2 "t3: the synthesizer's own bounded retry first"
assert_eq "$(calls gpt-ok synth)" 1 "t3: the next participant that answered round 1 writes the summary"
assert_eq "$(calls gem-ok synth)" 0 "t3: no further candidate once one succeeds"
assert_contains "$(cat "$TMP/last.out")" "SYNTHESIZER FALLBACK: anthropic-api failed (no_text), so openai-api wrote this summary"
assert_contains "$(cat "$TMP/last.out")" "FINAL ANSWER: verdict written by openai-api."
assert_eq "$(jq -c '.synthesizer_fallback, .flags.synthesizer_fallback, .synthesis_ok' "$TMP/t3/seats.json" | tr '\n' ' ')" '{"from":"anthropic-api","to":"openai-api","reason":"no_text"} true true ' "t3 seats.json"
assert_contains "$(cat "$TMP/t3/transcript.md")" "## Synthesis (openai-api; fallback for anthropic-api: no_text)"
assert_eq "$(jq -r .synthesizer "$TMP/t3/decision-log.json")" "openai-api"
echo "ok - synthesis no text: retry, then fallback to openai-api, flagged in the transcript, stdout and seats.json; the debate succeeds"

# ---- 3b. the synthesizer's own retry is enough: no fallback
rc=0; dbt "$TMP/t3b" claude-ntsynth1 gpt-ok gem-ok -- --rounds 1 "Which?" || rc=$?
assert_eq "$rc" 0; assert_eq "$(calls claude-ntsynth1 synth)" 2; assert_eq "$(jq -c .synthesizer_fallback "$TMP/t3b/seats.json")" "null"
assert_not_contains "$(cat "$TMP/last.out")" "SYNTHESIZER FALLBACK"
echo "ok - synthesis no text then success on the retry: no fallback"

# ---- 3c. the fallback can be turned off or ordered
rc=0; dbt "$TMP/t3c" claude-ntsynth gpt-ok gem-ok E3D_DEBATE_SYNTH_FALLBACK=off -- --rounds 1 "Which?" || rc=$?
assert_eq "$rc" 1 "fallback off: the debate fails as before"
rc=0; dbt "$TMP/t3d" claude-ntsynth gpt-ok gem-ok E3D_DEBATE_SYNTH_FALLBACK=gemini-api,openai-api -- --rounds 1 "Which?" || rc=$?
assert_eq "$rc" 0; assert_eq "$(jq -r .synthesizer_fallback.to "$TMP/t3d/seats.json")" "gemini-api" "the configured order wins"
echo "ok - E3D_DEBATE_SYNTH_FALLBACK: off, and an explicit order"

# ---- 4. every synthesizer fails: the debate fails, no verdict is stored as a success
rc=0; dbt "$TMP/t4" claude-ntsynth gpt-ntsynth gem-ntsynth -- --rounds 1 "Which?" || rc=$?
assert_eq "$rc" 1 "t4: no verdict, so a failed debate"
assert_eq "$(calls claude-ntsynth synth) $(calls gpt-ntsynth synth) $(calls gem-ntsynth synth)" "2 2 2" "t4: each candidate got its one bounded retry"
assert_not_contains "$(cat "$TMP/last.out")" "FINAL ANSWER"
assert_not_contains "$(cat "$TMP/t4/transcript.md")" "## Synthesis"
assert_eq "$(jq -c '[.synthesis_ok, .synthesizer_fallback]' "$TMP/t4/seats.json")" '[false,null]'
assert_eq "$(jq -r .synthesis_ok "$TMP/t4/decision-log.json")" "false"
echo "ok - every synthesizer fails: exit 1, no verdict, nothing recorded as a success"

# ---- 5. a 4xx that is not 429 is never retried; 429 and 5xx keep their own bounded retries
rc=0; dbt "$TMP/t5" claude-ok gpt-e400 gem-ok -- --rounds 1 "Which?" || rc=$?
assert_eq "$rc" 0; assert_eq "$(calls gpt-e400 round)" 1 "t5: HTTP 400 is not retried"
assert_eq "$(jq -r '.seats_unavailable[0].reason' "$TMP/t5/seats.json")" "http_400"
rc=0; dbt "$TMP/t5b" claude-ok gpt-e429 gem-ok -- --rounds 1 "Which?" || rc=$?
assert_eq "$rc" 0; assert_eq "$(calls gpt-e429 round)" 3 "t5b: HTTP 429 is retried (E3D_DEBATE_PROVIDER_RETRIES=2)"
assert_eq "$(jq -r '.seats_unavailable[0].reason' "$TMP/t5b/seats.json")" "http_429"
rc=0; dbt "$TMP/t5c" claude-e400 gpt-ok gem-ok -- --rounds 1 "Which?" || rc=$?
assert_eq "$rc" 0; assert_eq "$(calls claude-e400 synth)" 1 "t5c: a 400 on the synthesis is not retried, then the fallback runs"
assert_eq "$(jq -r .synthesizer_fallback.reason "$TMP/t5c/seats.json")" "http_400"
echo "ok - 400 is not retried (seat and synthesis); 429 is retried; reasons are http_400 / http_429"

# ---- 6. every seat fails: no synthesis call, a failed debate
rc=0; dbt "$TMP/t6" claude-e400 gpt-e400 gem-e400 -- --rounds 2 "Which?" || rc=$?
assert_eq "$rc" 1; assert_eq "$(jq -c 'select(.kind == "synth")' "$VREQ" | wc -l | tr -d ' ')" 0 "t6: nothing to synthesize"
assert_eq "$(jq -r .seats_answered "$TMP/t6/seats.json")" 0
echo "ok - no seat answered: no synthesis call, exit 1"

# ---- 7. per token: a retry repeats the same output limit and its usage is merged into the call's one row
PT=(E3D_DEBATE_MAX_TOKENS="$MAXT" E3D_DEBATE_ANSWER_BYTES_MAX="$ANSB")
rc=0; dbt "$TMP/p1" claude-ok gpt-nt1 gem-ok "${PT[@]}" -- --rounds 1 "Which?" || rc=$?
assert_eq "$rc" 0
assert_eq "$(jq -c 'select(.model == "gpt-nt1") | .max_tokens' "$VREQ" | tr '\n' ' ')" "456 456 " "p1: the retry sends the same limit, never a raised one"
assert_eq "$(jq -c '[.[] | .key]' "$TMP/p1/usage.json")" '["r1:anthropic-api","r1:gemini-api","r1:openai-api","synth"]' "p1: still one row per key"
# the failed attempt billed 20 in + 456 out (all of it spent on thinking); the retry 20 in + 8 out
assert_eq "$(jq -c '.[] | select(.key == "r1:openai-api") | [.input_tokens, .output_tokens, .source]' "$TMP/p1/usage.json")" '[40,464,"vendor"]' "p1: both attempts are counted in the one row"
echo "ok - per token: retry repeats the same output limit; usage of the failed attempt is counted (one merged row)"

rc=0; dbt "$TMP/p2" claude-ok gpt-ntall gem-ok "${PT[@]}" -- --rounds 2 "Which?" || rc=$?
assert_eq "$rc" 0
assert_eq "$(jq -c '.[] | select(.key == "r1:openai-api") | [.input_tokens, .output_tokens]' "$TMP/p2/usage.json")" '[40,912]' "p2: a seat lost after its retry is billed for both attempts, clamped by billing to its bound"
assert_eq "$(jq -c '[.[] | .key]' "$TMP/p2/usage.json" | grep -c 'r2:openai-api' || true)" 0 "p2: no row (no call) for the dropped seat in round 2"
echo "ok - per token: a dropped seat has its failed attempts counted and no later calls"

# ---- 8. per token synthesis: own retry merges; fallback reports ONE synth row (the call that wrote the verdict)
rc=0; dbt "$TMP/p3" claude-ntsynth1 gpt-ok gem-ok "${PT[@]}" -- --rounds 1 "Which?" || rc=$?
assert_eq "$rc" 0
assert_eq "$(jq -c '.[] | select(.key == "synth") | [.provider, .input_tokens, .output_tokens]' "$TMP/p3/usage.json")" '["anthropic-api",40,329]' "p3: synthesis retry merged into the one synth row (321 + 8 out)"
rc=0; dbt "$TMP/p4" claude-ntsynth gpt-ok gem-ok "${PT[@]}" -- --rounds 1 "Which?" || rc=$?
assert_eq "$rc" 0
assert_eq "$(jq -c '[.[] | select(.key == "synth")] | length' "$TMP/p4/usage.json")" 1 "p4: exactly one synth row (billing refuses a repeated key)"
assert_eq "$(jq -c '.[] | select(.key == "synth") | [.provider, .input_tokens, .output_tokens]' "$TMP/p4/usage.json")" '["openai-api",20,8]' "p4: the row is the fallback call"
assert_eq "$(jq -c '[.[] | [.key, .provider, .input_tokens, .output_tokens]]' "$TMP/p4/usage-unreported.json")" '[["synth-failed:anthropic-api","anthropic-api",40,642]]' "p4: the failed synthesizer attempts are kept for the operator, not sent as a row"
assert_eq "$(jq -c 'select(.kind == "synth" and .url == "/v1/chat/completions") | .max_tokens' "$VREQ" | tr '\n' ' ')" "456 " "p4: the fallback sends its own quoted limit"
echo "ok - per token synthesis: retry merges into one row; a fallback reports one synth row at its own provider, the failed attempts go to usage-unreported.json"

# ---- 9. per token: xai-api (uncapped reasoning) is never a synthesis fallback; without per token it may be
rc=0; PROVS_OVERRIDE=anthropic-api,xai-api dbt "$TMP/p5" claude-ntsynth gpt-ok gem-ok E3D_DEBATE_MAX_TOKENS='{"anthropic-api":321,"xai-api":300}' E3D_DEBATE_ANSWER_BYTES_MAX='{"anthropic-api":400,"xai-api":400}' -- --rounds 1 "Which?" || rc=$?
assert_eq "$rc" 1 "p5: the only candidate is xai-api, which a per-token debate never uses as a fallback"
assert_eq "$(jq -c 'select(.model == "xai-test" and .kind == "synth")' "$VREQ" | wc -l | tr -d ' ')" 0
rc=0; PROVS_OVERRIDE=anthropic-api,xai-api dbt "$TMP/p6" claude-ntsynth gpt-ok gem-ok -- --rounds 1 "Which?" || rc=$?
assert_eq "$rc" 0 "p6: not per token: the same candidate is used"
assert_eq "$(jq -r .synthesizer_fallback.to "$TMP/p6/seats.json")" "xai-api"
echo "ok - xai-api is excluded as a fallback only in a per-token debate"

# ---- 10. the retry budget is configurable and 0 turns it off (no wait, no second call)
rc=0; dbt "$TMP/t10" claude-ok gpt-nt1 gem-ok E3D_DEBATE_NO_TEXT_RETRIES=0 -- --rounds 1 "Which?" || rc=$?
assert_eq "$rc" 0; assert_eq "$(calls gpt-nt1 round)" 1; assert_eq "$(jq -r '.seats_unavailable[0].reason' "$TMP/t10/seats.json")" "no_text"
echo "ok - E3D_DEBATE_NO_TEXT_RETRIES=0 disables the retry"

# ---- 11. web search: no text on a search call
calls_t() { jq -c --arg m "$1" --argjson t "$2" 'select(.model == $m and .kind == "round" and .tools == $t)' "$VREQ" | wc -l | tr -d ' '; }
SRCH=(E3D_DEBATE_WEB_SEARCH=on E3D_DEBATE_WEB_SEARCH_PROVIDERS=anthropic-api)
rc=0; PROVS_OVERRIDE=anthropic-api,openai-api dbt "$TMP/s1" claude-nt1 gpt-ok gem-ok "${SRCH[@]}" -- --rounds 1 --web-search on "Which?" || rc=$?
assert_eq "$rc" 0; assert_eq "$(calls_t claude-nt1 1)" 2 "s1: the search call is retried once, as a search call"; assert_eq "$(calls_t claude-nt1 0)" 0 "s1: the retry worked, so no fallback without search"
rc=0; PROVS_OVERRIDE=anthropic-api,openai-api dbt "$TMP/s2" claude-ntsearch gpt-ok gem-ok "${SRCH[@]}" -- --rounds 1 --web-search on "Which?" || rc=$?
assert_eq "$rc" 0; assert_eq "$(calls_t claude-ntsearch 1)" 2 "s2: search call, one retry"; assert_eq "$(calls_t claude-ntsearch 0)" 1 "s2: then one call without search (no second retry)"
assert_eq "$(jq -c '.flags.unavailable' "$TMP/s2/web-search.json")" '[{"provider":"anthropic-api","round":1,"reason":"no_text"}]' "s2: the seat answered without web access, and says why"
assert_eq "$(jq -r .seats_answered "$TMP/s2/seats.json")" 2
echo "ok - web search: no text is retried once as a search call, then once without search, and flagged"
# per token: the search call is never repeated; one no-search call joins the first call's row (sums, one row, same limit)
PTS=(E3D_DEBATE_MAX_TOKENS='{"anthropic-api":321,"openai-api":456}' E3D_DEBATE_ANSWER_BYTES_MAX='{"anthropic-api":400,"openai-api":400}' E3D_DEBATE_MAX_SEARCHES='{"anthropic-api":2}' E3D_DEBATE_CITE_BYTES_MAX=200)
rc=0; PROVS_OVERRIDE=anthropic-api,openai-api dbt "$TMP/s3" claude-ntsearch gpt-ok gem-ok "${SRCH[@]}" "${PTS[@]}" -- --rounds 1 --web-search on "Which?" || rc=$?
assert_eq "$rc" 0; assert_eq "$(calls_t claude-ntsearch 1)" 1 "s3: per token, the search call is made once (a second request could search again)"
assert_eq "$(calls_t claude-ntsearch 0)" 1 "s3: one retry without search"
assert_eq "$(jq -c 'select(.model == "claude-ntsearch" and .kind == "round") | .max_tokens' "$VREQ" | tr '\n' ' ')" "321 321 " "s3: same output limit on the retry"
assert_eq "$(jq -c '.[] | select(.key == "r1:anthropic-api") | [.input_tokens, .output_tokens, .searches]' "$TMP/s3/usage.json")" '[40,329,1]' "s3: one row: both calls' tokens, the vendor's search count"
echo "ok - per-token web search: one search call, one no-search retry, one merged row, same limit"
# a search call cut at max_tokens with only its pre-search sentence is no_text, not an answer (measured on the real API, docs/seat-reliability.md)
rc=0; PROVS_OVERRIDE=anthropic-api,openai-api dbt "$TMP/s4" claude-trunc gpt-ok gem-ok "${SRCH[@]}" -- --rounds 1 --web-search on "Which?" || rc=$?
assert_eq "$rc" 0; assert_eq "$(calls_t claude-trunc 1)" 2 "s4: the truncated search call is retried once"; assert_eq "$(calls_t claude-trunc 0)" 1 "s4: then asked without search"
assert_not_contains "$(cat "$TMP/s4/transcript.md")" "I'll check the current release" "the preamble is never taken as the answer"
assert_contains "$(cat "$TMP/s4/transcript.md")" "Answer from anthropic-api." "the no-search answer is used"
assert_eq "$(jq -c '.flags.unavailable' "$TMP/s4/web-search.json")" '[{"provider":"anthropic-api","round":1,"reason":"no_text"}]'
rc=0; PROVS_OVERRIDE=anthropic-api,openai-api dbt "$TMP/s5" claude-trunc gpt-ok gem-ok "${SRCH[@]}" "${PTS[@]}" -- --rounds 1 --web-search on "Which?" || rc=$?
assert_eq "$rc" 0; assert_eq "$(calls_t claude-trunc 1)" 1 "s5: per token, one search call"; assert_eq "$(calls_t claude-trunc 0)" 1 "s5: one retry without search"
assert_eq "$(jq -c '.[] | select(.key == "r1:anthropic-api") | [.input_tokens, .output_tokens, .searches]' "$TMP/s5/usage.json")" '[3020,409,1]' "s5: the truncated call's tokens (321 + 80 over the cap) and the retry's are both in the one row"
echo "ok - a search call cut at max_tokens with only its preamble is no_text: retried, then answered without search"

# ---- 12. e3d-mcp: seats.json reaches the structured result, the warnings and the text; the stored (finalize) contract is untouched
STUB="$TMP/stub-debate"
cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
out=""; while [[ $# -gt 0 ]]; do case "$1" in --out-dir) out="$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p "$out"
printf '# Debate\n\n## Round 1 -- anthropic-api\n\nJSON.\n\n## Round 1 -- openai-api\n\nSQLite.\n\n## Synthesis (openai-api; fallback for anthropic-api: no_text)\n\nx\n' > "$out/transcript.md"
cat > "$out/seats.json" <<'EOJ'
{"schema":1,"seats_requested":3,"seats_answered":2,"seats_unavailable":[{"provider":"gemini-api","round":1,"reason":"no_text"}],"synthesizer":"openai-api","synthesizer_fallback":{"from":"anthropic-api","to":"openai-api","reason":"no_text"},"synthesis_ok":true,"flags":{"synthesizer_fallback":true,"seats_lost":true,"fewer_than_3_seats":true},"consensus_note":"Consensus is computed from the 2 of 3 seats that answered, not from all 3."}
EOJ
printf 'SYNTHESIZER FALLBACK: anthropic-api failed (no_text), so openai-api wrote this summary\nFINAL ANSWER: use JSON.\nCONSENSUS: majority\nDISSENT: none\n'
EOS
chmod +x "$STUB"
call='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"e3d_debate","arguments":{"question":"JSON or SQLite?","providers":["anthropic-api","openai-api"],"web_search":false}}}'
resp="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$call" \
  | env E3D_MCP_STATE_DIR="$TMP/state" E3D_MCP_DEBATE_BIN="$STUB" E3D_MCP_PROVIDERS=anthropic-api,openai-api ANTHROPIC_API_KEY=k OPENAI_API_KEY=k "$ROOT/bin/e3d-mcp" 2>"$TMP/mcp.log")"
r="$(jq -c 'select(.id==2)' <<< "$resp")"
assert_eq "$(jq -c '.result.structuredContent | [.seats_requested, .seats_answered, .seats_unavailable, .synthesizer_fallback, .flags]' <<< "$r")" '[3,2,[{"provider":"gemini-api","round":1,"reason":"no_text"}],{"from":"anthropic-api","to":"openai-api","reason":"no_text"},{"synthesizer_fallback":true,"seats_lost":true,"fewer_than_3_seats":true}]' "structured result"
assert_contains "$(jq -r '.result.structuredContent.warnings | join(" | ")' <<< "$r")" "Only 2 of 3 models answered: gemini-api was unavailable in round 1 (no_text)"
assert_contains "$(jq -r '.result.structuredContent.warnings | join(" | ")' <<< "$r")" "The summary was written by openai-api because the synthesizer anthropic-api failed (no_text)."
assert_contains "$(jq -r '.result.content[0].text' <<< "$r")" "**WARNING:** The summary was written by openai-api because the synthesizer anthropic-api failed (no_text)."
assert_contains "$(jq -r '.result.content[0].text' <<< "$r")" "warnings: Only 2 of 3 models answered"
echo "ok - e3d-mcp reports seats_requested/seats_answered/seats_unavailable/synthesizer_fallback/flags, a warning line for each, and the text says so"

echo "seat-reliability: all passed"
