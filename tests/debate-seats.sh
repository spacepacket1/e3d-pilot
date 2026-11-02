#!/usr/bin/env bash
# Seats are not providers (docs/specs/experts-phase2a-seats-and-suggest-spec.md, Phase 2a.1): the debate script keeps a seat id (files, answers,
# labels, fate) apart from the adapter that answers. Nothing selects two seats on one adapter yet except the internal test seam
# E3D_DEBATE_SEAT_ADAPTERS, which this test uses. Stub adapters record every prompt they receive, so each case reads exactly what each seat saw.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/fixtures/specialists/harness.sh"
TMPS=()
trap 'for d in "${TMPS[@]}"; do rm -rf "$d"; done' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
newroot() { local T; T="$(mktemp -d)"; TMPS+=("$T"); printf '%s' "$T"; }

# A stub that is safe to call twice at once: one unique file per call, the answer names the seat read from the prompt ("You are <seat>,").
# $T/fail-<seat> makes that seat's call fail.
seatstub() { # seatstub <root> <adapter>
  local T="$1" n="$2"
  cat > "$T/lib/providers/$n" <<STUB
#!/usr/bin/env bash
if [[ "\${E3D_PILOT_CHECK:-}" == 1 ]]; then exit 0; fi
mkdir -p "$T/seen"; f="\$(mktemp "$T/seen/$n.XXXXXX")"; cp "\$1" "\$f"
seat="\$(grep -oE 'You are [A-Za-z0-9._-]+' "\$1" | head -1 | sed 's/^You are //')"
if [[ -n "\$seat" && -f "$T/fail-\$seat" ]]; then echo "error: stub failure for \$seat" >&2; exit 1; fi
printf 'VERDICT: x\nACTION: do the %s thing\nAGREES_WITH: none\nCONFIDENCE: high\n' "\${seat:-$n}"
STUB
  chmod +x "$T/lib/providers/$n"
}
build() { # build <adapter>... -> a fresh root path
  local T; T="$(newroot)"
  build_root "$T" "$ROOT/bin/e3d-debate" v3 "$@" >&2
  for n in "$@"; do seatstub "$T" "$n"; done
  printf '%s' "$T"
}
SEATS='{"alpha.2":"alpha"}'
run() { # run <root> <extra env as VAR=val|-> <args...>; sets rc, writes stdout/stderr files
  local T="$1" e="$2"; shift 2
  local -a env_args=(-u TYPESAFE_API_KEY HOME="$T/home")
  [[ "$e" == "-" ]] || env_args+=("$e")
  rc=0; env "${env_args[@]}" "$T/bin/e3d-debate" "$@" > "$T/stdout" 2> "$T/stderr" || rc=$?
}
seen_for() { grep -l -- "$2" "$1"/seen/* 2>/dev/null | wc -l | tr -d ' '; }

# ---- 1. two seats on one adapter are two independent participants ----
T="$(build alpha beta)"
run "$T" "E3D_DEBATE_SEAT_ADAPTERS=$SEATS" "q?" --providers alpha,alpha.2,beta --rounds 2 --synthesizer synth --prompts v3b --out-dir "$T/out"
[[ $rc -eq 0 ]] || fail "three seats on two adapters: the debate failed: $(cat "$T/stderr")"
for seat in alpha alpha.2 beta; do
  [[ "$(seen_for "$T" "You are $seat, one of 3 analysts who will each answer independently")" == 1 ]] || fail "$seat: expected exactly one round-1 prompt addressed to it"
  [[ "$(seen_for "$T" "You are $seat, one of 3 analysts debating one question")" == 1 ]] || fail "$seat: expected exactly one round-2 prompt addressed to it"
  grep -q "^## Round 1 -- $seat\$" "$T/out/transcript.md" || fail "$seat: no round-1 heading in the transcript"
  grep -q "^## Round 2 -- $seat\$" "$T/out/transcript.md" || fail "$seat: no round-2 heading in the transcript"
  grep -q "do the $seat thing" "$T/out/transcript.md" || fail "$seat: its own answer is missing, so its call or its file was shared"
done
[[ "$(ls "$T/seen" | grep -c '^alpha\.')" == 4 ]] || fail "the alpha adapter should have been called four times (two seats, two rounds), got $(ls "$T/seen" | grep -c '^alpha\.')"
[[ "$(ls "$T/seen" | grep -c '^beta\.')" == 2 ]] || fail "the beta adapter should have been called twice"
f2="$(grep -l 'You are alpha.2, one of 3 analysts debating one question' "$T"/seen/*)"
grep -q '^--- alpha ---$' "$f2" && grep -q '^--- beta ---$' "$f2" || fail "alpha.2's round-2 prompt must show the other two seats' answers, labelled by name"
grep -q 'The others are: alpha, beta\.' "$f2" || fail "alpha.2's round-2 prompt must name the other two seats"
grep -q -- '--- YOU (your own previous answer' "$f2" || fail "alpha.2's round-2 prompt must show its own answer as its own"
f1="$(grep -l 'You are alpha, one of 3 analysts debating one question' "$T"/seen/*)"
grep -q '^--- alpha.2 ---$' "$f1" && grep -q 'The others are: alpha.2, beta\.' "$f1" || fail "alpha's round-2 prompt must show alpha.2 as another participant"
! grep -q '^--- alpha ---$' "$f1" || fail "alpha must not see its own answer labelled as another participant's"
[[ "$(jq -c .providers "$T/out/decision-log.json")" == '["alpha","alpha.2","beta"]' ]] || fail "the decision log lists seat ids: $(jq -c .providers "$T/out/decision-log.json")"
[[ "$(jq -r '.seats_requested, .seats_answered' "$T/out/seats.json" | tr '\n' ' ')" == "3 3 " ]] || fail "seats.json counts three seats"
echo "seats 1 (independent participants): ok"

# ---- 2. one seat of an adapter can fail without dropping the other ----
T="$(build alpha beta)"; : > "$T/fail-alpha.2"
run "$T" "E3D_DEBATE_SEAT_ADAPTERS=$SEATS" "q?" --providers alpha,alpha.2,beta --rounds 2 --synthesizer synth --prompts v3b --out-dir "$T/out"
[[ $rc -eq 0 ]] || fail "a failing second seat: the debate failed: $(cat "$T/stderr")"
[[ "$(jq -c '[.seats_unavailable[] | [.provider, .round]]' "$T/out/seats.json")" == '[["alpha.2",1]]' ]] || fail "only alpha.2 should be lost: $(jq -c .seats_unavailable "$T/out/seats.json")"
grep -q '^## Seat dropped -- alpha.2$' "$T/out/transcript.md" || fail "alpha.2 should be reported dropped"
! grep -q '^## Seat dropped -- alpha$' "$T/out/transcript.md" || fail "alpha must NOT be dropped because alpha.2 failed"
grep -q '^## Round 2 -- alpha$' "$T/out/transcript.md" && grep -q '^## Round 2 -- beta$' "$T/out/transcript.md" || fail "alpha and beta continue to round 2"
! grep -q '^## Round 2 -- alpha.2$' "$T/out/transcript.md" || fail "alpha.2 takes no part in round 2"
[[ "$(jq -r '.seats_answered' "$T/out/seats.json")" == 2 ]] || fail "two of three answered"
T="$(build alpha beta)"; : > "$T/fail-alpha"
run "$T" "E3D_DEBATE_SEAT_ADAPTERS=$SEATS" "q?" --providers alpha,alpha.2,beta --rounds 2 --synthesizer synth --prompts v3b --out-dir "$T/out"
[[ $rc -eq 0 ]] || fail "a failing first seat: the debate failed: $(cat "$T/stderr")"
[[ "$(jq -c '[.seats_unavailable[] | .provider]' "$T/out/seats.json")" == '["alpha"]' ]] || fail "only alpha should be lost: $(jq -c .seats_unavailable "$T/out/seats.json")"
grep -q '^## Round 2 -- alpha.2$' "$T/out/transcript.md" || fail "alpha.2 continues when alpha fails"
echo "seats 2 (one fails, the other lives): ok"

# ---- 3. the seam refuses nonsense ----
T="$(build alpha beta)"
for bad in 'not json' '[]' '{"a.2":5}' '{"alpha.2":"../x"}' '{"alpha.2":"alpha/x"}' '{"bad seat":"alpha"}' '{"alpha.2":""}'; do
  run "$T" "E3D_DEBATE_SEAT_ADAPTERS=$bad" "q?" --providers alpha,alpha.2,beta --rounds 1 --synthesizer synth
  [[ $rc -eq 1 ]] || fail "a bad E3D_DEBATE_SEAT_ADAPTERS ($bad) must be refused with exit 1, got $rc"
  grep -q 'E3D_DEBATE_SEAT_ADAPTERS' "$T/stderr" || fail "the refusal must name the variable: $(cat "$T/stderr")"
done
run "$T" "E3D_DEBATE_SEAT_ADAPTERS={\"alpha.2\":\"nosuchadapter\"}" "q?" --providers alpha,alpha.2,beta --rounds 1 --synthesizer synth
[[ $rc -eq 1 ]] && grep -q 'no such provider adapter' "$T/stderr" || fail "an adapter that does not exist must be refused: $(cat "$T/stderr")"
echo "seats 3 (refusals): ok"

# ---- 4. token pricing prices one seat per provider, so two seats on one are refused ----
T="$(newroot)"; build_root "$T" "$ROOT/bin/e3d-debate" v2 anthropic-api openai-api >&2
cp "$ROOT/lib/debate/token-pricing.mjs" "$T/lib/debate/"
rc2=0; env -u TYPESAFE_API_KEY HOME="$T/home" E3D_DEBATE_SEAT_ADAPTERS='{"anthropic-api.2":"anthropic-api"}' E3D_DEBATE_MAX_TOKENS='{"anthropic-api":100,"openai-api":100}' "$T/bin/e3d-debate" "q?" --providers anthropic-api,anthropic-api.2,openai-api --rounds 1 --synthesizer anthropic-api > "$T/stdout" 2> "$T/stderr" || rc2=$?
[[ $rc2 -eq 1 ]] && grep -q 'per-token pricing prices one seat per provider' "$T/stderr" || fail "token limits with two seats on one provider must be refused: rc=$rc2 $(cat "$T/stderr")"
echo "seats 4 (token pricing guard): ok"

echo "debate-seats: PASS"
