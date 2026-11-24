#!/usr/bin/env bash
# Hosted skills, PR H2d, engine level: (a) the observer's outcome block built from the engine's own files, (b) a stop that arrives while the observer runs leaves a finished
# debate finished (exit 0, the verdict on stdout byte-identical to a run without an observer), (c) the measured fixed overhead of the observer prompt.
# Real bin/e3d-debate against fake vendors on 127.0.0.1; no network beyond that, no real keys, no model.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------- (c) the fixed overhead of the observer prompt
node --input-type=module - "$ROOT" <<'EOF' || exit 1
import { pathToFileURL } from 'node:url';
const lib = (f) => import(pathToFileURL(`${process.argv[2]}/${f}`).href);
const { buildObserverPrompt, OBSERVER_PROMPT_OVERHEAD_BYTES, OBSERVER_POSITION_OVERHEAD_BYTES, OBSERVER_LIMITS } = await lib('lib/skills/observer.mjs');
const { makeHosted } = await lib('tests/fixtures/skills/hosted-make.mjs');
const B = (s) => Buffer.byteLength(s);
const fixed = (definition, tier, { question = '', positions = [], synthesis = '' } = {}) => {
  const prompt = buildObserverPrompt({ definition, tier, question, data: { positions, synthesis }, nonce: 'a'.repeat(24), date: '2026-11-23' });
  const data = positions.reduce((n, p) => n + B(p.text), 0) + B(synthesis);
  return { prompt_bytes: B(prompt), overhead: B(prompt) - B(definition.instructions.method) - B(question) - data };
};
// a minimal real skill, an empty debate, an empty question
const [def] = makeHosted('u_abc123def456', [{ name: 'reviewer', body: 'x', hooks: ['observer'] }]);
const real = fixed(def, 'user');
// the longest id, version and limits the schemas allow, an empty method
const worst = fixed({ id: `skill.${'a'.repeat(40)}.${'b'.repeat(64)}`, version: '999999.999999.999999', definition_hash: `sha256:${'a'.repeat(64)}`, limits: { max_output_bytes: 9999999 }, instructions: { method: '' } }, 'built-in');
// the framing of one participant at its longest name and round
const one = fixed({ ...def }, 'user', { positions: [{ who: 'a'.repeat(48), round: 1000, text: '' }] }).overhead - real.overhead;
console.log(`observer prompt fixed overhead: minimal real skill ${real.overhead} bytes (prompt ${real.prompt_bytes}), longest id/version/limits ${worst.overhead} bytes, one participant's heading ${one} bytes; constants ${OBSERVER_PROMPT_OVERHEAD_BYTES} / ${OBSERVER_POSITION_OVERHEAD_BYTES}`);
if (real.overhead > OBSERVER_PROMPT_OVERHEAD_BYTES) throw new Error(`the fixed observer prompt text (${real.overhead}) is over OBSERVER_PROMPT_OVERHEAD_BYTES (${OBSERVER_PROMPT_OVERHEAD_BYTES})`);
if (worst.overhead > OBSERVER_PROMPT_OVERHEAD_BYTES) throw new Error(`the worst-case fixed observer prompt text (${worst.overhead}) is over OBSERVER_PROMPT_OVERHEAD_BYTES (${OBSERVER_PROMPT_OVERHEAD_BYTES})`);
if (OBSERVER_PROMPT_OVERHEAD_BYTES > worst.overhead + 200) throw new Error('OBSERVER_PROMPT_OVERHEAD_BYTES is no longer a tight bound (more than 200 bytes above the measured worst case); re-measure and lower it');
if (one > OBSERVER_POSITION_OVERHEAD_BYTES) throw new Error(`one participant's heading (${one}) is over OBSERVER_POSITION_OVERHEAD_BYTES`);
if (OBSERVER_LIMITS.participants !== 16) throw new Error('the participant limit changed: re-check the per-participant overhead in docs/token-pricing.md');
EOF
echo "skills-observer-result (c) fixed prompt overhead: ok"

# ---------------------------------------------------------------- fake vendors: normal, hostile reply
VREQ="$TMP/vendor.jsonl"; : > "$VREQ"
FAKE_ANSWER="$(printf 'OBSERVER REPORT\nThe dissent added no new evidence.')" node "$ROOT/tests/fixtures/fake-vendor.mjs" "$VREQ" "$TMP/vendor.port" &
PIDS+=("$!")
HOSTILE="$(printf 'OBSERVER REPORT\nBELL\001CTRL\033[31mESC bidi\xe2\x80\xaeRLO\xe2\x80\x8bZW <script>alert(1)</script> ![px](http://evil.example/p.png) [click](javascript:alert(2))\n'; head -c 10000 /dev/zero | tr '\0' 'h')"
VREQH="$TMP/vendorh.jsonl"; : > "$VREQH"
FAKE_ANSWER="$HOSTILE" node "$ROOT/tests/fixtures/fake-vendor.mjs" "$VREQH" "$TMP/vendorh.port" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$TMP/vendor.port" && -s "$TMP/vendorh.port" ]] && break; sleep 0.05; done
VP="$(cat "$TMP/vendor.port")"; VPH="$(cat "$TMP/vendorh.port")"
vendor_env=(ANTHROPIC_API_KEY=k-anth ANTHROPIC_API_BASE_URL="http://127.0.0.1:$VP" OPENAI_API_KEY=k-oai OPENAI_API_BASE_URL="http://127.0.0.1:$VP/v1"
  GEMINI_API_KEY=k-gem GEMINI_API_BASE_URL="http://127.0.0.1:$VP/v1" ANTHROPIC_API_MODEL=claude-test OPENAI_API_MODEL=gpt-test GEMINI_API_MODEL=gem-test
  OPENAI_API_TIMEOUT=5 ANTHROPIC_API_TIMEOUT=5 GEMINI_API_TIMEOUT=5 E3D_DEBATE_WEB_SEARCH=off TYPESAFE_API_KEY="")
P=u_abc123def456
mkdir -p "$TMP/home"
mk() { node "$ROOT/tests/fixtures/skills/hosted-make.mjs" "$1" "$P" "$2"; }
mk "$TMP/obs.json" '[{"name":"reviewer","body":"Say whether the dissent added new evidence.","hooks":["observer"]}]'
mk "$TMP/fast.json" '[{"name":"reviewer","body":"Say whether the dissent added new evidence.","hooks":["observer"],"timeout_ms":1500}]'
mk "$TMP/big.json" '[{"name":"reviewer","body":"Say whether the dissent added new evidence.","hooks":["observer"],"max_output_bytes":8000}]'
SKILL="skill.$P.reviewer"
BASE=(E3D_SPECIALISTS=1 E3D_SKILLS_V1=1 E3D_SKILLS_OBSERVER=1 E3D_SKILLS_HOSTED=1 E3D_DEBATE_MAX_TOKENS='{"anthropic-api":300,"openai-api":300}' E3D_DEBATE_ANSWER_BYTES_MAX='{"anthropic-api":400,"openai-api":400}')
LIM=(E3D_DEBATE_OBSERVER_MAX_TOKENS=150 E3D_DEBATE_OBSERVER_INPUT_BYTES_MAX=20000)
# run <out-dir> <env...> -- <extra args...>: a per-token debate of two API seats; stdout to $TMP/run.out, stderr to $TMP/run.err
run() {
  local out="$1"; shift; local -a e=(); while [[ "$1" != -- ]]; do e+=("$1"); shift; done; shift
  : > "$VREQ"; rc=0
  env -u E3D_DEBATE_OBSERVER_MAX_TOKENS -u E3D_DEBATE_OBSERVER_INPUT_BYTES_MAX -u E3D_DEBATE_MAX_TOKENS "${vendor_env[@]}" HOME="$TMP/home" "${e[@]}" "$ROOT/bin/e3d-debate" "Which database?" --providers anthropic-api,openai-api \
    --rounds 1 --synthesizer anthropic-api --max-words 60 --builtin-only --out-dir "$out" "$@" > "$TMP/run.out" 2> "$TMP/run.err" || rc=$?
}
# result <out-dir> [max_output_bytes]: the block e3d-mcp puts in the run result, from the engine's files in that directory
result() { node --input-type=module - "$ROOT" "$1" "${2:-}" <<'EOF'
import { pathToFileURL } from 'node:url';
const { observerResult } = await import(pathToFileURL(`${process.argv[2]}/lib/skills/observer-result.mjs`).href);
console.log(JSON.stringify(observerResult({ outDir: process.argv[3], slug: 'reviewer', maxOutputBytes: process.argv[4] ? Number(process.argv[4]) : undefined })));
EOF
}
HOSTED=(--hosted-skills "$TMP/obs.json")

# ---------------------------------------------------------------- stdout without an observer, for the byte comparison
run "$TMP/n0" "${BASE[@]}" -- "${HOSTED[@]}"
[[ $rc -eq 0 ]] || fail "a run without an observer: $(tail -3 "$TMP/run.err")"; cp "$TMP/run.out" "$TMP/stdout.none"
[[ -s "$TMP/stdout.none" ]] || fail "the verdict is on stdout"
[[ ! -e "$TMP/n0/observers.json" && ! -e "$TMP/n0/observer-skip.json" ]] || fail "a run without an observer leaves no observer file"

# ---------------------------------------------------------------- (a) status mapping from the engine's own files
# ok
run "$TMP/o1" "${BASE[@]}" "${LIM[@]}" -- "${HOSTED[@]}" --observer "$SKILL:gemini-api"
[[ $rc -eq 0 ]] || fail "ok run: $(tail -3 "$TMP/run.err")"; cmp -s "$TMP/run.out" "$TMP/stdout.none" || fail "stdout with an observer is byte-identical to stdout without one"
R="$(result "$TMP/o1" 1000)"
jq -e '. == {status:"ok", code:null, report:"OBSERVER REPORT\nThe dissent added no new evidence.", tokens:{input:13,output:17}, latency_ms:.latency_ms} and (.latency_ms | type == "number" and . >= 0)' <<< "$R" >/dev/null || fail "ok block: $R"
# failed: the vendor answers 200 with no text (billed): a row, no report
run "$TMP/o2" "${BASE[@]}" "${LIM[@]}" GEMINI_API_MODEL=gem-empty -- "${HOSTED[@]}" --observer "$SKILL:gemini-api"
[[ $rc -eq 0 ]] || fail "failed run keeps exit 0"; cmp -s "$TMP/run.out" "$TMP/stdout.none" || fail "stdout unchanged when the observer fails"
R="$(result "$TMP/o2" 1000)"; jq -e '.status == "failed" and .code == "skill_provider_error" and .report == null and .tokens == {input:13,output:17}' <<< "$R" >/dev/null || fail "failed (empty reply) block: $R"
# failed before the vendor: HTTP 500 -> the adapter fails, no usage row, tokens null
run "$TMP/o2b" "${BASE[@]}" "${LIM[@]}" GEMINI_API_MODEL=gem-500 -- "${HOSTED[@]}" --observer "$SKILL:gemini-api"
[[ $rc -eq 0 ]] || fail "500 run keeps exit 0"
R="$(result "$TMP/o2b" 1000)"; jq -e '.status == "failed" and .code == "skill_provider_error" and .report == null and .tokens == null' <<< "$R" >/dev/null || fail "failed (vendor error) block: $R"
# timeout: the skill's own deadline (1500 ms) against a vendor that never answers
run "$TMP/o3" "${BASE[@]}" "${LIM[@]}" GEMINI_API_MODEL=gem-hang GEMINI_API_TIMEOUT=30 -- --hosted-skills "$TMP/fast.json" --observer "$SKILL:gemini-api"
[[ $rc -eq 0 ]] || fail "timeout run keeps exit 0"; cmp -s "$TMP/run.out" "$TMP/stdout.none" || fail "stdout unchanged when the observer times out"
R="$(result "$TMP/o3" 1000)"; jq -e '.status == "timeout" and .code == "skill_timeout" and .report == null and .tokens.output == 150 and .latency_ms >= 1000' <<< "$R" >/dev/null || fail "timeout block: $R"
# skipped: the quoted input bound is too small for the smallest prompt: no call, no usage row
run "$TMP/o4" "${BASE[@]}" E3D_DEBATE_OBSERVER_MAX_TOKENS=150 E3D_DEBATE_OBSERVER_INPUT_BYTES_MAX=50 -- "${HOSTED[@]}" --observer "$SKILL:gemini-api"
[[ $rc -eq 0 ]] || fail "skipped run keeps exit 0"; cmp -s "$TMP/run.out" "$TMP/stdout.none" || fail "stdout unchanged when the observer is skipped"
R="$(result "$TMP/o4" 1000)"; jq -e '. == {status:"skipped", code:"skill_too_large", report:null, tokens:null, latency_ms:null}' <<< "$R" >/dev/null || fail "skipped block: $R"
jq -e 'map(.key) | index("observer:reviewer") == null' "$TMP/o4/usage.json" >/dev/null || fail "skipped: no usage row"
# no files at all (an observer was asked for, nothing was written): skipped, never a missing block
mkdir -p "$TMP/empty"; R="$(result "$TMP/empty" 1000)"; jq -e '.status == "skipped" and .tokens == null' <<< "$R" >/dev/null || fail "no files: $R"
echo "skills-observer-result (a) ok / failed / failed before the vendor / timeout / skipped: ok"

# the report is bounded and plain text: hostile reply, the skill's limit (1000, then 8000) and the platform cap (4096)
run "$TMP/h1" "${BASE[@]}" "${LIM[@]}" GEMINI_API_BASE_URL="http://127.0.0.1:$VPH/v1" -- "${HOSTED[@]}" --observer "$SKILL:gemini-api"
R="$(result "$TMP/h1" 1000)"
jq -e '.status == "ok" and (.report | type == "string")' <<< "$R" >/dev/null || fail "hostile (limit 1000): $R"
[[ "$(jq -j .report <<< "$R" | wc -c | tr -d ' ')" -le 1000 ]] || fail "the report is within the skill's max_output_bytes (1000)"
run "$TMP/h2" "${BASE[@]}" "${LIM[@]}" GEMINI_API_BASE_URL="http://127.0.0.1:$VPH/v1" -- --hosted-skills "$TMP/big.json" --observer "$SKILL:gemini-api"
R="$(result "$TMP/h2" 8000)"
jq -e '.status == "ok"' <<< "$R" >/dev/null || fail "hostile (limit 8000): $R"
REP="$(jq -r .report <<< "$R")"
[[ "$(jq -j .report <<< "$R" | wc -c | tr -d ' ')" -le 4096 ]] || fail "the report is within the platform cap of 4096 bytes even when the skill allows 8000"
[[ "$(jq -j .report <<< "$R" | wc -c | tr -d ' ')" -gt 3000 ]] || fail "the report keeps its text up to the cap"
for bad in '<script' 'evil.example/p.png' 'javascript:alert' $'\001' $'\033' $'\xe2\x80\xae' $'\xe2\x80\x8b'; do [[ "$REP" != *"$bad"* ]] || fail "the report still holds $(printf '%q' "$bad")"; done
[[ "$REP" == *"BELL"* && "$REP" == *"[html removed]"* ]] || fail "the harmless text stays and markup is neutralised: ${REP:0:200}"
# the cap is the minimum of the skill's limit and 4096, whatever the engine wrote
cp -r "$TMP/h2" "$TMP/h3"; node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1]+"/observer-reviewer.md","z".repeat(9000)+"\n")' "$TMP/h3"
[[ "$(jq -j .report <<< "$(result "$TMP/h3" 8000)" | wc -c | tr -d ' ')" -le 4096 ]] || fail "a 9000 byte report file is cut to 4096"
[[ "$(jq -j .report <<< "$(result "$TMP/h3" 300)" | wc -c | tr -d ' ')" -le 300 ]] || fail "and to a smaller skill limit"
# no debate data, prompt or skill text in the block
for f in "$TMP/o1" "$TMP/o3" "$TMP/h2"; do R="$(result "$f" 1000)"; for m in "Which database" "Say whether the dissent" "$P" "sha256:" "POSITION of"; do [[ "$R" != *"$m"* ]] || fail "the block carries $m"; done; done
jq -e 'keys == ["code","latency_ms","report","status","tokens"]' <<< "$(result "$TMP/o1" 1000)" >/dev/null || fail "the block has exactly its five keys"
echo "skills-observer-result (a) the report is bounded and plain text, the block carries nothing of the debate or the skill: ok"

# ---------------------------------------------------------------- (b) a stop during the observer leaves a finished debate finished
: > "$VREQ"
( env -u E3D_DEBATE_OBSERVER_MAX_TOKENS -u E3D_DEBATE_OBSERVER_INPUT_BYTES_MAX "${vendor_env[@]}" GEMINI_API_TIMEOUT=30 GEMINI_API_MODEL=gem-hang HOME="$TMP/home" "${BASE[@]}" "${LIM[@]}" "$ROOT/bin/e3d-debate" "Which database?" --providers anthropic-api,openai-api \
    --rounds 1 --synthesizer anthropic-api --max-words 60 --builtin-only --out-dir "$TMP/s1" "${HOSTED[@]}" --observer "$SKILL:gemini-api" > "$TMP/s1.out" 2> "$TMP/s1.err" ) &
EP=$!; PIDS+=("$EP")
for _ in $(seq 1 200); do [[ "$(jq -s '[.[] | select(.body.model == "gem-hang")] | length' "$VREQ" 2>/dev/null || echo 0)" == 1 ]] && break; sleep 0.1; done
[[ "$(jq -s '[.[] | select(.body.model == "gem-hang")] | length' "$VREQ")" == 1 ]] || fail "the observer call never reached the vendor: $(tail -3 "$TMP/s1.err")"
kill -TERM "$EP" 2>/dev/null || true
rc=0; wait "$EP" || rc=$?
[[ $rc -eq 0 ]] || fail "a stop during the observer leaves the finished debate's exit status at 0, got $rc: $(tail -3 "$TMP/s1.err")"
cmp -s "$TMP/s1.out" "$TMP/stdout.none" || fail "stdout after a stop during the observer is byte-identical to a run without an observer"
jq -e '.[] | select(.key == "observer:reviewer") | .output_tokens == 150 and .provider == "gemini-api"' "$TMP/s1/usage.json" >/dev/null || fail "the stopped call has its inflight row at the quoted limit: $(jq -c 'map(.key)' "$TMP/s1/usage.json")"
jq -e 'map(.key) | index("synth") != null and index("r1:anthropic-api") != null' "$TMP/s1/usage.json" >/dev/null || fail "the seat and synthesis rows are still reported"
jq -e '.[0].run.status == "failed" and .[0].run.errors[0].code == "skill_timeout"' "$TMP/s1/observers.json" >/dev/null || fail "the observer record says it was stopped"
jq -e '.observers | length == 1' "$TMP/s1/decision-log.json" >/dev/null || fail "decision-log.json carries the observers block"
R="$(result "$TMP/s1" 1000)"; jq -e '.status == "timeout" and .code == "skill_timeout" and .tokens.output == 150' <<< "$R" >/dev/null || fail "stopped observer block: $R"
sleep 1; ! pgrep -f "observer.mjs call" >/dev/null 2>&1 || fail "an observer call process outlived the stopped debate"
echo "skills-observer-result (b) a stop during the observer: exit 0, the same stdout, an inflight row, status timeout: ok"

# a stop BEFORE the verdict is unchanged: the seat is under way, the debate exits 143 and writes the rows of the calls under way
: > "$VREQ"
( env -u E3D_DEBATE_OBSERVER_MAX_TOKENS -u E3D_DEBATE_OBSERVER_INPUT_BYTES_MAX "${vendor_env[@]}" ANTHROPIC_API_TIMEOUT=30 ANTHROPIC_API_MODEL=claude-hang HOME="$TMP/home" "${BASE[@]}" "${LIM[@]}" "$ROOT/bin/e3d-debate" "Which database?" --providers anthropic-api,openai-api \
    --rounds 1 --synthesizer openai-api --max-words 60 --builtin-only --out-dir "$TMP/s2" "${HOSTED[@]}" --observer "$SKILL:gemini-api" > "$TMP/s2.out" 2> "$TMP/s2.err" ) &
EP=$!; PIDS+=("$EP")
for _ in $(seq 1 200); do [[ "$(jq -s '[.[] | select(.body.model == "claude-hang")] | length' "$VREQ" 2>/dev/null || echo 0)" -ge 1 ]] && break; sleep 0.1; done
kill -TERM "$EP" 2>/dev/null || true
rc=0; wait "$EP" || rc=$?
[[ $rc -eq 143 ]] || fail "a stop before the verdict still exits 143, got $rc"
[[ ! -s "$TMP/s2.out" ]] || fail "no verdict on stdout"
[[ ! -e "$TMP/s2/observers.json" ]] || fail "no observer ran"
echo "skills-observer-result (b) a stop before the verdict is unchanged (exit 143, nothing on stdout): ok"
echo "skills-observer-result: ok"
