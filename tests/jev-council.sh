#!/usr/bin/env bash
# Jev council signal, shadow only (docs/jev-council.md, issue #66 Phase 1): --jev-propositions asks Jev typed yes/no statements
# before round 1, hides the answer from every model, and changes no output. Fake providers, a scripted Jev stub
# (E3D_PILOT_JEV_STUB_DIR, one file per call) and a fake vendor: no network beyond 127.0.0.1, no real keys.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done; rm -rf "$T"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "${3:-eq}: expected [$2], got [$1]"; }

jev_resp() { jq -nc --argjson n "$1" '{model:"jev-test", answers:{p:{type:"noul", noul:$n}}, usage:{input_tokens:100, output_tokens:5}}'; }
new_stub_dir() { local d; d="$(mktemp -d "$T/stub.XXXXXX")"; local i=1 v; for v in "$@"; do jev_resp "$v" > "$d/$i.json"; i=$((i + 1)); done; echo "$d"; }
calls_of() { [[ -f "$1/.calls" ]] && cat "$1/.calls" || echo 0; }
# With a key set, e3d-debate's existing obviousness pre-screen asks Jev first, so it takes scripted answer 1; the council's calls follow.
new_stub_dir_ps() {
  local d; d="$(mktemp -d "$T/stub.XXXXXX")"
  printf '%s' '{"model":"jev-test","answers":{"obviousness":{"type":"noul","noul":0.5}},"usage":{"input_tokens":10,"output_tokens":2}}' > "$d/1.json"
  local i=2 v; for v in "$@"; do jev_resp "$v" > "$d/$i.json"; i=$((i + 1)); done; echo "$d"
}

# ---------------------------------------------------------------- library: validation, bands, failures
source "$ROOT/lib/providers/jev.sh"
source "$ROOT/lib/debate/jev-council.sh"
export TYPESAFE_API_KEY=test-key

valid() { printf '%s' "$1" > "$T/v.json"; jev_council_validate "$T/v.json" 2>"$T/v.err"; }
valid '[{"id":"p1","text":"Do X."}]' || fail "a plain statement should validate"
valid '[{"id":"p1","text":"Do X.","negation":"Do not do X."}]' || fail "a statement with a negation should validate"
for bad in '{}' '[]' 'not json' '[{"id":"BAD ID","text":"x"}]' '[{"id":"a","text":""}]' '[{"id":"a","text":"x"},{"id":"a","text":"y"}]' \
           '[{"id":"a","text":"x","negation":"  "}]' '[1]' '[{"id":"a","text":"x"},{"id":"b","text":"x"},{"id":"c","text":"x"},{"id":"d","text":"x"},{"id":"e","text":"x"},{"id":"f","text":"x"}]'; do
  if valid "$bad"; then fail "should be rejected: $bad"; fi
  grep -q '^error: --jev-propositions' "$T/v.err" || fail "a rejection names the flag: $(cat "$T/v.err")"
done
if jev_council_validate "$T/missing.json" 2>/dev/null; then fail "a missing file must be rejected"; fi

band_of() { # band_of <props-json> <values...> -> prints the artifact's compact summary
  local props="$1"; shift
  export E3D_PILOT_JEV_STUB_DIR; E3D_PILOT_JEV_STUB_DIR="$(new_stub_dir "$@")"
  printf '%s' "$props" > "$T/p.json"; jev_council_run "Which is better?" "$T/p.json" "$T/art.json"
}
PAIR='[{"id":"p1","text":"Do X.","negation":"Do not do X."}]'
band_of "$PAIR" 0.9 0.1
eq "$(jq -r '[.status, .propositions[0].band, .propositions[0].consistent, .propositions[0].combined, .propositions[0].basis] | join(",")' "$T/art.json")" "ok,decisive_yes,true,0.9,paired" "decisive yes"
eq "$(jq -r '.usage.calls' "$T/art.json")" 2 "a paired statement is two calls"
eq "$(jq -r '[.mode, .hidden_from_models, .framing, .thresholds.provisional] | join(",")' "$T/art.json")" "shadow,true,supplied,true" "the artifact says what it is"
band_of "$PAIR" 0.1 0.9
eq "$(jq -r '.propositions[0].band' "$T/art.json")" decisive_no "decisive no"
band_of "$PAIR" 0.42 0.42
eq "$(jq -r '[.propositions[0].band, .propositions[0].consistent] | join(",")' "$T/art.json")" "undecided,false" "a statement and its negation that both lean false are not a signal"
band_of "$PAIR" 0.67 0.44
eq "$(jq -r '[.propositions[0].band, .propositions[0].consistent] | join(",")' "$T/art.json")" "undecided,true" "consistent but between the thresholds"
band_of '[{"id":"p1","text":"Do X."}]' 0.2
eq "$(jq -r '[.propositions[0].band, .propositions[0].basis, .propositions[0].consistent] | join(",")' "$T/art.json")" "decisive_no,single," "single statement (no negation: consistent is null, which jq's join prints empty)"
eq "$(jq -r '.usage.calls' "$T/art.json")" 1
# a second call with no scripted answer = a vendor failure: no signal, never a guess
band_of "$PAIR" 0.9 2>/dev/null
eq "$(jq -r '[.status, .propositions[0].band, .propositions[0].combined] | join(",")' "$T/art.json")" "no_signal,no_signal," "a failed negation call leaves no signal (combined is null, printed empty)"
band_of '[{"id":"p1","text":"A."},{"id":"p2","text":"B."}]' 0.8 2>/dev/null
eq "$(jq -r '[.status, .propositions[0].band, .propositions[1].band] | join(",")' "$T/art.json")" "partial,decisive_yes,no_signal" "one failed statement does not erase the other"
# malformed and out-of-range answers
export E3D_PILOT_JEV_STUB_DIR; E3D_PILOT_JEV_STUB_DIR="$(mktemp -d "$T/stub.XXXXXX")"; echo '{"answers":{}}' > "$E3D_PILOT_JEV_STUB_DIR/1.json"
printf '%s' '[{"id":"p1","text":"A."}]' > "$T/p.json"; jev_council_run q "$T/p.json" "$T/art.json"
eq "$(jq -r .status "$T/art.json")" no_signal "a response with no answer is no signal"
E3D_PILOT_JEV_STUB_DIR="$(mktemp -d "$T/stub.XXXXXX")"; echo '{"answers":{"p":{"type":"noul","noul":7}}}' > "$E3D_PILOT_JEV_STUB_DIR/1.json"
jev_council_run q "$T/p.json" "$T/art.json"
eq "$(jq -r .status "$T/art.json")" no_signal "an out-of-range value is no signal"
unset E3D_PILOT_JEV_STUB_DIR
echo "ok - library: validation, polarity check, bands and failures"

# ---------------------------------------------------------------- the stub seam itself
D="$(new_stub_dir 0.1 0.2)"
export E3D_PILOT_JEV_STUB_DIR="$D"
a="$(jev_call m '{}' '{}')"; b="$(jev_call m '{}' '{}')"
eq "$(jq -r .answers.p.noul <<< "$a")" 0.1 "call 1 returns 1.json (through a subshell)"; eq "$(jq -r .answers.p.noul <<< "$b")" 0.2 "call 2 returns 2.json"
if jev_call m '{}' '{}' 2>/dev/null; then fail "a call with no scripted answer must fail"; fi
eq "$(calls_of "$D")" 3
unset E3D_PILOT_JEV_STUB_DIR
echo "ok - jev_call per-call stub"

# ---------------------------------------------------------------- e3d-debate with fake providers
TREE="$T/tree"
mkdir -p "$TREE/bin" "$TREE/lib/providers" "$TREE/lib/debate" "$TREE/lib/negotiate"
cp "$ROOT/lib/negotiate/convergence" "$TREE/lib/negotiate/"
cp "$ROOT/bin/e3d-debate" "$TREE/bin/"
cp "$ROOT/lib/debate/agreement" "$ROOT/lib/debate/jev-council.sh" "$TREE/lib/debate/"
echo '{"type":"module"}' > "$TREE/package.json"
cp "$ROOT/lib/providers/jev.sh" "$ROOT/lib/providers/common.sh" "$TREE/lib/providers/"
for p in alpha beta; do
  cat > "$TREE/lib/providers/$p" <<STUB
#!/usr/bin/env bash
touch "$T/called-$p"
printf 'VERDICT: x\nACTION: do the thing\nAGREES_WITH: none\nCONFIDENCE: high\n'
STUB
  chmod +x "$TREE/lib/providers/$p"
done
cat > "$TREE/lib/providers/synth" <<'STUB'
#!/usr/bin/env bash
printf 'FINAL ANSWER: ok\nCONSENSUS: split\nDISSENT: alpha: would not.\n'
STUB
chmod +x "$TREE/lib/providers/synth"

MARK="JEVMARK$$"
PROPS="$T/props.json"
jq -nc --arg m "$MARK" '[{id:"p1", text:("Ship it now. " + $m), negation:("Do not ship it now. " + $m)}]' > "$PROPS"

run() { # run <out-dir> [env...] -- [extra e3d-debate args]; the work dir lands in a private $T/tmp so it can be inspected
  local out="$1"; shift
  local envs=(); while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done; shift || true
  rm -rf "$T/tmp"; mkdir -p "$T/tmp"
  env -u TYPESAFE_API_KEY -u E3D_PILOT_JEV_STUB_DIR -u E3D_PILOT_JEV_STUB_RESPONSE TMPDIR="$T/tmp" ${envs[@]+"${envs[@]}"} \
    "$TREE/bin/e3d-debate" "Which is better?" --prompts v3c --providers alpha,beta --rounds 2 --synthesizer synth --out-dir "$out" "$@" > "$T/stdout" 2> "$T/stderr"
}

# baseline: no flag, no key
run "$T/base" --
cp "$T/stdout" "$T/base.stdout"
[[ ! -e "$T/base/jev-council.json" ]] || fail "no flag, no artifact"
if jq -e 'has("jev_council")' "$T/base/decision-log.json" >/dev/null; then fail "no flag, no jev_council in the decision log"; fi

# the feature on: a paired statement, decisive yes
S="$(new_stub_dir_ps 0.9 0.1)"
run "$T/on" TYPESAFE_API_KEY=test-key E3D_PILOT_JEV_STUB_DIR="$S" -- --jev-propositions "$PROPS"
eq "$(calls_of "$S")" 3 "one pre-screen call plus two council calls for one paired statement"
a="$T/on/jev-council.json"
eq "$(jq -r '[.status, .propositions[0].band, .propositions[0].consistent] | join(",")' "$a")" "ok,decisive_yes,true" "artifact in --out-dir"
grep -q 'Jev council signal (shadow, hidden from the models, informational only)' "$T/on/transcript.md" || fail "the transcript record carries a labelled line"
grep -q 'p1: decisive_yes' "$T/on/transcript.md" || fail "the transcript line names the band"
eq "$(jq -c '.jev_council' "$T/on/decision-log.json")" '{"status":"ok","mode":"shadow","propositions":1,"bands":{"decisive_yes":1}}' "decision-log summary"
if grep -q "$MARK" "$T/on/decision-log.json"; then fail "the decision log must not contain statement text"; fi

# hidden from every model: the statement text may appear in the artifact only (the transcript line carries ids and bands, not text), never in a round prompt or the synthesis prompt
WORK="$(ls -d "$T"/tmp/e3d-debate.* | head -1)"
holders="$(grep -rl "$MARK" "$WORK" | sed "s#^$WORK/##" | sort | tr '\n' ' ')"
eq "$holders" "jev-council.json " "only the artifact holds Jev's statements; no prompt and not even the record does"
[[ -s "$WORK/transcript.prompt.md" ]] || fail "the prompt copy of the transcript should exist"
if grep -q 'Jev council' "$WORK/transcript.prompt.md"; then fail "the synthesis prompt must not carry the Jev line"; fi

# no output changes: same stdout, same decision log apart from the new field and timing
eq "$(cat "$T/stdout")" "$(cat "$T/base.stdout")" "stdout is identical with and without the flag"
eq "$(jq -S 'del(.ts, .seconds, .jev_council)' "$T/on/decision-log.json")" "$(jq -S 'del(.ts, .seconds)' "$T/base/decision-log.json")" "decision log identical apart from jev_council"
echo "ok - e3d-debate: artifact, record, decision log, hidden from the prompts, output unchanged"

# an undecided pair is recorded as such
run "$T/und" TYPESAFE_API_KEY=test-key E3D_PILOT_JEV_STUB_DIR="$(new_stub_dir_ps 0.42 0.42)" -- --jev-propositions "$PROPS"
eq "$(jq -r '.propositions[0].band' "$T/und/jev-council.json")" undecided
eq "$(jq -c '.jev_council.bands' "$T/und/decision-log.json")" '{"undecided":1}'

# a Jev failure never fails or changes the debate
run "$T/fail" TYPESAFE_API_KEY=test-key E3D_PILOT_JEV_STUB_DIR="$(new_stub_dir)" -- --jev-propositions "$PROPS"
eq "$(jq -r .status "$T/fail/jev-council.json")" no_signal "no scripted answer = vendor failure"
eq "$(cat "$T/stdout")" "$(cat "$T/base.stdout")" "stdout unchanged when Jev fails"

# no key: no_signal artifact, no call
run "$T/nokey" -- --jev-propositions "$PROPS"
eq "$(jq -r '[.status, .reason] | join(": ")' "$T/nokey/jev-council.json")" "no_signal: TYPESAFE_API_KEY is not set"
eq "$(cat "$T/stdout")" "$(cat "$T/base.stdout")"

# a bad file fails before any provider runs
rm -f "$T"/called-*
printf '%s' '[{"id":"BAD ID","text":"x"}]' > "$T/bad.json"
rc=0; run "$T/bad" -- --jev-propositions "$T/bad.json" || rc=$?
[[ "$rc" != 0 ]] || fail "an invalid --jev-propositions file must fail the run"
grep -q '^error: --jev-propositions' "$T/stderr" || fail "the error names the flag: $(cat "$T/stderr")"
[[ ! -e "$T/called-alpha" && ! -e "$T/called-beta" ]] || fail "no provider may run before the file is validated"
rc=0; run "$T/miss" -- --jev-propositions "$T/does-not-exist.json" || rc=$?
[[ "$rc" != 0 ]] || fail "a missing file must fail the run"
echo "ok - failures degrade to no_signal; a bad file fails before any provider runs"

# ---------------------------------------------------------------- per-token mode makes no Jev call
VREQ="$T/vendor.jsonl"; : > "$VREQ"
FAKE_ANSWER="a plain answer" node "$ROOT/tests/fixtures/fake-vendor.mjs" "$VREQ" "$T/vendor.port" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$T/vendor.port" ]] && break; sleep 0.05; done
VP="$(cat "$T/vendor.port")"
S2="$(new_stub_dir 0.9 0.1)"
rc=0
env -u E3D_PILOT_JEV_STUB_RESPONSE ANTHROPIC_API_KEY=k-anth ANTHROPIC_API_BASE_URL="http://127.0.0.1:$VP" OPENAI_API_KEY=k-oai OPENAI_API_BASE_URL="http://127.0.0.1:$VP/v1" \
  ANTHROPIC_API_MODEL=claude-test OPENAI_API_MODEL=gpt-test OPENAI_API_TIMEOUT=2 ANTHROPIC_API_TIMEOUT=2 E3D_DEBATE_WEB_SEARCH=off \
  TYPESAFE_API_KEY=test-key E3D_PILOT_JEV_STUB_DIR="$S2" E3D_DEBATE_MAX_TOKENS='{"anthropic-api":321,"openai-api":456}' \
  "$ROOT/bin/e3d-debate" "Which?" --providers anthropic-api,openai-api --synthesizer anthropic-api --rounds 1 --out-dir "$T/pt" --jev-propositions "$PROPS" > "$T/pt.out" 2>&1 || rc=$?
eq "$rc" 0 "the per-token debate runs: $(tail -3 "$T/pt.out")"
eq "$(calls_of "$S2")" 0 "per-token mode makes no Jev call"
eq "$(jq -r '[.status, .reason] | join(": ")' "$T/pt/jev-council.json")" "skipped: per-token mode makes no Jev call"
eq "$(wc -l < "$VREQ" | tr -d ' ')" 3 "exactly the planned vendor calls: 2 seats + the synthesis, no extra call"
echo "ok - per-token mode: no Jev call, planned vendor calls only"

echo "jev-council: ok"
