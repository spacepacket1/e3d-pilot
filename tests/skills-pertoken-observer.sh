#!/usr/bin/env bash
# Skills phase 3c, PR H2b: a debate observer in a per-token (hosted) debate. The observer's one call is a quoted line of the bill: it runs only with the quoted limits
# (E3D_DEBATE_OBSERVER_MAX_TOKENS, E3D_DEBATE_OBSERVER_INPUT_BYTES_MAX), on a named API provider, is never retried and writes its own usage row. Real adapters against a fake
# vendor on 127.0.0.1; no network beyond that, no real keys.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

VREQ="$TMP/vendor.jsonl"; : > "$VREQ"
FAKE_ANSWER="$(printf 'OBSERVER REPORT\nThe dissent added no new evidence.')" node "$ROOT/tests/fixtures/fake-vendor.mjs" "$VREQ" "$TMP/vendor.port" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$TMP/vendor.port" ]] && break; sleep 0.05; done
VP="$(cat "$TMP/vendor.port")"
# a second vendor whose answer is longer than the skill's 1000 byte output limit: an unusable reply, which is what makes a retry_once skill ask for a second call
VREQ2="$TMP/vendor2.jsonl"; : > "$VREQ2"
FAKE_ANSWER="$(head -c 3000 /dev/zero | tr '\0' 'y')" node "$ROOT/tests/fixtures/fake-vendor.mjs" "$VREQ2" "$TMP/vendor2.port" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$TMP/vendor2.port" ]] && break; sleep 0.05; done
VP2="$(cat "$TMP/vendor2.port")"
vendor_env=(ANTHROPIC_API_KEY=k-anth ANTHROPIC_API_BASE_URL="http://127.0.0.1:$VP" OPENAI_API_KEY=k-oai OPENAI_API_BASE_URL="http://127.0.0.1:$VP/v1"
  GEMINI_API_KEY=k-gem GEMINI_API_BASE_URL="http://127.0.0.1:$VP/v1" ANTHROPIC_API_MODEL=claude-test OPENAI_API_MODEL=gpt-test
  OPENAI_API_TIMEOUT=2 ANTHROPIC_API_TIMEOUT=2 GEMINI_API_TIMEOUT=3 E3D_DEBATE_WEB_SEARCH=off TYPESAFE_API_KEY="")
P=u_abc123def456
mkdir -p "$TMP/home"
node "$ROOT/tests/fixtures/skills/hosted-make.mjs" "$TMP/obs.json" "$P" '[{"name":"reviewer","body":"Say whether the dissent added new evidence.","hooks":["observer"]}]'
node "$ROOT/tests/fixtures/skills/hosted-make.mjs" "$TMP/retry.json" "$P" '[{"name":"reviewer","body":"Say whether the dissent added new evidence.","hooks":["observer"],"on_invalid_output":"retry_once"}]'
SKILL="skill.$P.reviewer"
BASE=(E3D_SPECIALISTS=1 E3D_SKILLS_V1=1 E3D_SKILLS_OBSERVER=1 E3D_SKILLS_HOSTED=1 E3D_DEBATE_MAX_TOKENS='{"anthropic-api":300,"openai-api":300}' E3D_DEBATE_ANSWER_BYTES_MAX='{"anthropic-api":400,"openai-api":400}')
LIM=(E3D_DEBATE_OBSERVER_MAX_TOKENS=150 E3D_DEBATE_OBSERVER_INPUT_BYTES_MAX=20000)
# run <out-dir> <env...> -- <extra args...>: the real engine, a per-token debate of two API seats, the synthesizer anthropic-api; stdout and stderr to $TMP/run.out / $TMP/run.err
run() {
  local out="$1"; shift; local -a e=(); while [[ "$1" != -- ]]; do e+=("$1"); shift; done; shift
  : > "$VREQ"; rc=0
  env -u E3D_DEBATE_OBSERVER_MAX_TOKENS -u E3D_DEBATE_OBSERVER_INPUT_BYTES_MAX -u E3D_DEBATE_MAX_TOKENS "${vendor_env[@]}" HOME="$TMP/home" "${e[@]}" "$ROOT/bin/e3d-debate" "${QUESTION:-Which database?}" --providers anthropic-api,openai-api \
    --rounds 1 --synthesizer anthropic-api --max-words 60 --builtin-only --out-dir "$out" "$@" > "$TMP/run.out" 2> "$TMP/run.err" || rc=$?
}
nvend() { wc -l < "$VREQ" | tr -d ' '; }
HOSTED=(--hosted-skills "$TMP/obs.json")

# 1. a good run: the observer is called once on gemini-api with exactly the quoted output limit; the seats keep theirs; usage.json has a row for it
run "$TMP/o1" "${BASE[@]}" "${LIM[@]}" GEMINI_API_MODEL=gem-test -- "${HOSTED[@]}" --observer "$SKILL:gemini-api"
[[ $rc -eq 0 ]] || fail "a per-token observer run failed: $(tail -5 "$TMP/run.err")"
[[ "$(jq -s '[.[] | select(.body.model == "gem-test")] | length' "$VREQ")" == 1 ]] || fail "the observer makes exactly one vendor call: $(jq -c '.body.model' "$VREQ" | tr '\n' ' ')"
[[ "$(jq -s '[.[] | select(.body.model == "gem-test")][0].body.max_tokens' "$VREQ")" == 150 ]] || fail "the observer call carries the quoted output limit, got $(jq -s '[.[] | select(.body.model == "gem-test")][0].body.max_tokens' "$VREQ")"
[[ "$(jq -s '[.[] | select(.body.model != "gem-test") | (.body.max_tokens // .body.max_completion_tokens)] | map(select(. == 150)) | length' "$VREQ")" == 0 ]] || fail "the observer's limit never reaches a seat or the synthesis"
[[ "$(jq -s '[.[] | select(.body.model == "claude-test" or .body.model == "gpt-test") | select((.body.max_tokens // .body.max_completion_tokens) == 300)] | length' "$VREQ")" == 2 ]] || fail "the two seats keep their own quoted limit (300)"
jq -e '(map(.key) | index("observer:reviewer")) != null and (length == 4)' "$TMP/o1/usage.json" >/dev/null || fail "usage.json has the seat rows, the synthesis row and the observer row: $(jq -c 'map(.key)' "$TMP/o1/usage.json")"
jq -e '.[] | select(.key == "observer:reviewer") | .provider == "gemini-api" and .input_tokens > 0 and .output_tokens > 0' "$TMP/o1/usage.json" >/dev/null || fail "the observer row names its provider and carries vendor counts: $(jq -c '.[] | select(.key == "observer:reviewer")' "$TMP/o1/usage.json")"
jq -e '.[0].run.status == "completed"' "$TMP/o1/observers.json" >/dev/null || fail "the observer run is recorded: $(jq -c '.[0].run | {status, errors}' "$TMP/o1/observers.json" 2>&1)"
! grep -q '^## Observer report' "$TMP/run.out" || fail "the report never reaches stdout"
echo "skills-pertoken-observer 1 (a priced observer run): ok"

# 2. refusals before any call
refuse() { # <label> <env...> -- <extra args...>
  local label="$1"; shift; run "$TMP/ref" "$@"; [[ $rc -eq 1 ]] || fail "$label must be refused (exit 1), got $rc: $(tail -3 "$TMP/run.err")"; [[ "$(nvend)" == 0 ]] || fail "$label: no vendor call may be made"
}
refuse "an observer in a per-token debate without the quoted limits" "${BASE[@]}" -- "${HOSTED[@]}" --observer "$SKILL:gemini-api"; grep -q 'needs the quoted limits' "$TMP/run.err" || fail "says why"
refuse "limits without --observer" "${BASE[@]}" "${LIM[@]}" -- "${HOSTED[@]}"; grep -q 'no --observer' "$TMP/run.err" || fail "says why"
refuse "only one of the two limits" "${BASE[@]}" E3D_DEBATE_OBSERVER_MAX_TOKENS=150 -- "${HOSTED[@]}" --observer "$SKILL:gemini-api"
refuse "only the input bound" "${BASE[@]}" E3D_DEBATE_OBSERVER_INPUT_BYTES_MAX=20000 -- "${HOSTED[@]}" --observer "$SKILL:gemini-api"
for bad in 0 abc 5000 -1 1.5; do refuse "observer max tokens $bad" "${BASE[@]}" E3D_DEBATE_OBSERVER_MAX_TOKENS=$bad E3D_DEBATE_OBSERVER_INPUT_BYTES_MAX=20000 -- "${HOSTED[@]}" --observer "$SKILL:gemini-api"; done
for bad in 0 abc 300000; do refuse "observer input bytes $bad" "${BASE[@]}" E3D_DEBATE_OBSERVER_MAX_TOKENS=150 E3D_DEBATE_OBSERVER_INPUT_BYTES_MAX=$bad -- "${HOSTED[@]}" --observer "$SKILL:gemini-api"; done
refuse "an observer that does not name its provider" "${BASE[@]}" "${LIM[@]}" -- "${HOSTED[@]}" --observer "$SKILL"; grep -q 'names its provider' "$TMP/run.err" || fail "says why"
refuse "an adapter without an output-limit setting (claude)" "${BASE[@]}" "${LIM[@]}" -- "${HOSTED[@]}" --observer "$SKILL:claude"; grep -q 'no output-limit setting' "$TMP/run.err" || fail "says why: $(tail -2 "$TMP/run.err")"
refuse "observer limits without a per-token debate" E3D_SPECIALISTS=1 E3D_SKILLS_V1=1 E3D_SKILLS_OBSERVER=1 E3D_SKILLS_HOSTED=1 "${LIM[@]}" -- "${HOSTED[@]}" --observer "$SKILL:gemini-api"; grep -q 'apply to a per-token debate' "$TMP/run.err" || fail "says why"
echo "skills-pertoken-observer 2 (refusals before any call): ok"

# 3. never retried: a skill that asks for retry_once makes ONE vendor call when the reply is unusable (a second would be unquoted)
run "$TMP/o3" "${BASE[@]}" "${LIM[@]}" GEMINI_API_MODEL=gem-test GEMINI_API_BASE_URL="http://127.0.0.1:$VP2/v1" -- --hosted-skills "$TMP/retry.json" --observer "$SKILL:gemini-api"
[[ $rc -eq 0 ]] || fail "an observer with an unusable reply leaves the debate's exit status alone: $(tail -3 "$TMP/run.err")"
[[ "$(jq -s '[.[] | select(.body.model == "gem-test")] | length' "$VREQ2")" == 1 ]] || fail "the observer is not retried in a per-token debate: $(jq -s '[.[] | select(.body.model == "gem-test")] | length' "$VREQ2") calls"
jq -e '(map(.key) | index("observer:reviewer")) != null' "$TMP/o3/usage.json" >/dev/null || fail "the observer call has its usage row"
# and a plain failure (the vendor answers with nothing) is one call, one row, and the debate is unaffected
run "$TMP/o3b" "${BASE[@]}" "${LIM[@]}" GEMINI_API_MODEL=gem-empty -- "${HOSTED[@]}" --observer "$SKILL:gemini-api"
[[ $rc -eq 0 ]] || fail "a failing observer leaves the debate's exit status alone: $(tail -3 "$TMP/run.err")"
[[ "$(jq -s '[.[] | select(.body.model == "gem-empty")] | length' "$VREQ")" == 1 ]] || fail "one call"
jq -e '(map(.key) | index("observer:reviewer")) != null' "$TMP/o3b/usage.json" >/dev/null || fail "the failed observer call still has its usage row"
grep -q 'OBSERVER FAILED' "$TMP/run.err" || fail "a failure is said on stderr"
echo "skills-pertoken-observer 3 (no retry, failure leaves the debate alone): ok"

# 4. the input bound: the prompt sent never exceeds the quoted bytes; when even the minimum does not fit the observer is skipped and the debate is unaffected
run "$TMP/o4" "${BASE[@]}" E3D_DEBATE_OBSERVER_MAX_TOKENS=150 E3D_DEBATE_OBSERVER_INPUT_BYTES_MAX=2500 GEMINI_API_MODEL=gem-test -- "${HOSTED[@]}" --observer "$SKILL:gemini-api"
[[ $rc -eq 0 ]] || fail "run with a small input bound: $(tail -3 "$TMP/run.err")"
SENT="$(jq -s '[.[] | select(.body.model == "gem-test")][0] | [.body.messages[].content] | join("") | utf8bytelength' "$VREQ")"
[[ "$SENT" =~ ^[0-9]+$ && "$SENT" -le 2500 && "$SENT" -gt 0 ]] || fail "the observer prompt must fit the quoted input bound (2500), got $SENT"
run "$TMP/o4b" "${BASE[@]}" E3D_DEBATE_OBSERVER_MAX_TOKENS=150 E3D_DEBATE_OBSERVER_INPUT_BYTES_MAX=50 GEMINI_API_MODEL=gem-test -- "${HOSTED[@]}" --observer "$SKILL:gemini-api"
[[ $rc -eq 0 ]] || fail "a debate whose observer cannot fit is unaffected: $(tail -3 "$TMP/run.err")"
[[ "$(jq -s '[.[] | select(.body.model == "gem-test")] | length' "$VREQ")" == 0 ]] || fail "an observer that cannot fit its quoted input is never called"
jq -e '(map(.key) | index("observer:reviewer")) == null' "$TMP/o4b/usage.json" >/dev/null || fail "no call, no usage row"
grep -q 'observer was not run' "$TMP/run.err" || fail "it says the observer was not run"
echo "skills-pertoken-observer 4 (the input bound): ok"

# 5. a debate stopped (after its verdict) while the observer is under way still reports its call (an estimate at the quoted limit), never an undercount
: > "$VREQ"
( env -u E3D_DEBATE_OBSERVER_MAX_TOKENS -u E3D_DEBATE_OBSERVER_INPUT_BYTES_MAX "${vendor_env[@]}" GEMINI_API_TIMEOUT=30 HOME="$TMP/home" "${BASE[@]}" "${LIM[@]}" GEMINI_API_MODEL=gem-hang "$ROOT/bin/e3d-debate" "Which database?" --providers anthropic-api,openai-api \
    --rounds 1 --synthesizer anthropic-api --max-words 60 --builtin-only --out-dir "$TMP/o5" "${HOSTED[@]}" --observer "$SKILL:gemini-api" > "$TMP/run5.out" 2> "$TMP/run5.err" ) &
EP=$!; PIDS+=("$EP")
for _ in $(seq 1 200); do [[ "$(jq -s '[.[] | select(.body.model == "gem-hang")] | length' "$VREQ" 2>/dev/null || echo 0)" == 1 ]] && break; sleep 0.1; done
[[ "$(jq -s '[.[] | select(.body.model == "gem-hang")] | length' "$VREQ")" == 1 ]] || fail "the observer call never reached the vendor: $(tail -3 "$TMP/run5.err")"
kill -TERM "$EP" 2>/dev/null || true
rc=0; wait "$EP" || rc=$?
[[ $rc -eq 0 ]] || fail "a stop during the observer (after the verdict) leaves the finished debate's exit status at 0 (H2d), got $rc"
jq -e '.[] | select(.key == "observer:reviewer") | .output_tokens == 150 and .provider == "gemini-api"' "$TMP/o5/usage.json" >/dev/null || fail "the call under way has a row estimated at the quoted limit: $(jq -c 'map({key, output_tokens})' "$TMP/o5/usage.json")"
echo "skills-pertoken-observer 5 (a stopped debate reports the observer's call): ok"

# 6. review findings (billing): a call killed by the skill's own deadline may have been billed: it has a row at the quoted limit, never nothing
node "$ROOT/tests/fixtures/skills/hosted-make.mjs" "$TMP/fast.json" "$P" '[{"name":"reviewer","body":"Say whether the dissent added new evidence.","hooks":["observer"],"timeout_ms":1500}]'
run "$TMP/o6" "${BASE[@]}" "${LIM[@]}" GEMINI_API_MODEL=gem-hang GEMINI_API_TIMEOUT=30 -- --hosted-skills "$TMP/fast.json" --observer "$SKILL:gemini-api"
[[ $rc -eq 0 ]] || fail "an observer that times out leaves the debate's exit status alone, got $rc: $(tail -3 "$TMP/run.err")"
[[ "$(jq -s '[.[] | select(.body.model == "gem-hang")] | length' "$VREQ")" == 1 ]] || fail "the request reached the vendor once"
jq -e '.[] | select(.key == "observer:reviewer") | .output_tokens == 150' "$TMP/o6/usage.json" >/dev/null || fail "a timed-out observer call has a row at the quoted limit (it may have been billed): $(jq -c 'map(.key)' "$TMP/o6/usage.json")"
# a failed attempt is recorded in the receipt even when the skill asked for retry_once and the reply was unusable (one call, no second)
run "$TMP/o6b" "${BASE[@]}" "${LIM[@]}" GEMINI_API_MODEL=gem-test GEMINI_API_BASE_URL="http://127.0.0.1:$VP2/v1" -- --hosted-skills "$TMP/retry.json" --observer "$SKILL:gemini-api"
[[ -s "$TMP/o6b/observers.json" ]] && jq -e '.[0].run.status == "failed"' "$TMP/o6b/observers.json" >/dev/null || fail "the failed observer attempt is recorded (observers.json): $(ls "$TMP/o6b")"
jq -e '.observers | length == 1' "$TMP/o6b/decision-log.json" >/dev/null || fail "decision-log.json carries the observers block for a failed attempt"
# an observer call is never a search call, even when the quote priced search for that provider
run "$TMP/o6c" "${BASE[@]}" "${LIM[@]}" E3D_DEBATE_WEB_SEARCH=on E3D_DEBATE_MAX_SEARCHES='{"anthropic-api":2}' E3D_DEBATE_CITE_BYTES_MAX=500 E3D_PROVIDER_WEB_SEARCH=1 -- "${HOSTED[@]}" --observer "$SKILL:anthropic-api"
[[ $rc -eq 0 ]] || fail "a per-token run with search quoted and an observer: $(tail -3 "$TMP/run.err")"
[[ "$(jq -s '[.[] | select((.body.messages // []) | map(.content | tostring) | join("") | contains("Scope: debate_observer")) | select(.body.tools != null)] | length' "$VREQ")" == 0 ]] || fail "the observer request carries no search tool even when the caller exported search settings"
jq -e '.[] | select(.key == "observer:reviewer") | .searches == 0' "$TMP/o6c/usage.json" >/dev/null || fail "the observer row says it made no search: $(jq -c '.[] | select(.key == "observer:reviewer")' "$TMP/o6c/usage.json")"
echo "skills-pertoken-observer 6 (deadline, failed attempt record, no search): ok"

# 7. the observer's input bound counts BYTES: multibyte text is bounded as bytes, not characters
QUESTION="$(printf '日本語の質問です。%.0s' $(seq 1 30))" run "$TMP/o7" "${BASE[@]}" E3D_DEBATE_OBSERVER_MAX_TOKENS=150 E3D_DEBATE_OBSERVER_INPUT_BYTES_MAX=2500 GEMINI_API_MODEL=gem-test QUESTION="$(printf '日本語の質問です。%.0s' $(seq 1 30))" -- "${HOSTED[@]}" --observer "$SKILL:gemini-api"
if [[ "$(jq -s '[.[] | select(.body.model == "gem-test")] | length' "$VREQ")" == 1 ]]; then
  SENT="$(jq -s '[.[] | select(.body.model == "gem-test")][0] | [.body.messages[].content] | join("") | utf8bytelength' "$VREQ")"
  [[ "$SENT" -le 2500 ]] || fail "a multibyte prompt must fit the quoted input bound in bytes, got $SENT"
fi
echo "skills-pertoken-observer 7 (bytes, not characters): ok"

# 8. a stopped debate leaves no observer process behind
sleep 1
! pgrep -f "observer.mjs call" >/dev/null 2>&1 || fail "an observer call process outlived the stopped debate"
echo "skills-pertoken-observer 8 (no leftover process): ok"
echo "skills-pertoken-observer: ok"
