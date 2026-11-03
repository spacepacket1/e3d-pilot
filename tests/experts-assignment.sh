#!/usr/bin/env bash
# Experts, Phase 2a.2 (docs/specs/experts-phase2a-seats-and-suggest-spec.md sections 2.3 and 2.5): several seats on one adapter, the 6-seat
# bound, --min-families and the independence block. Stub adapters record every prompt, so each case reads what every seat saw. No model, no network.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/fixtures/specialists/harness.sh"
TMPS=()
trap 'for d in "${TMPS[@]}"; do rm -rf "$d"; done' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
newroot() { local T; T="$(mktemp -d)"; TMPS+=("$T"); printf '%s' "$T"; }

# One call = one unique file. The answer names the seat read from the prompt ("You are <seat>,"). $T/fail-<seat> makes that seat fail.
seatstub() {
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
# build <adapter>... -> a root with experts e1..e7 (lens text carries LENS-E<k>-MARK and no "You are")
build() {
  local T n k; T="$(newroot)"
  build_root "$T" "$ROOT/bin/e3d-debate" v3 "$@" >&2
  for n in "$@"; do seatstub "$T" "$n"; done
  for k in 1 2 3 4 5 6 7; do
    mkdir -p "$T/lib/specialists/e$k"
    printf -- '---\nname: e%s\ndescription: Lens %s. Use it in tests.\nlicense: MIT\nmetadata:\n  e3d.expert.version: "1"\n---\nLENS-E%s-MARK.\n' "$k" "$k" "$k" > "$T/lib/specialists/e$k/SKILL.md"
  done
  printf '{"schema":"panels/v1","presets":{"six":{"description":"d","min_seats":2,"experts":["e1","e2","e3","e4","e5","e6"]},"seven":{"description":"d","min_seats":2,"experts":["e1","e2","e3","e4","e5","e6","e7"]}}}' > "$T/lib/specialists/panels.json"
  printf '%s' "$T"
}
# run <root> <E3D_SPECIALISTS value or unset> <args...>; sets rc
run() {
  local T="$1" es="$2"; shift 2
  local -a e=(-u TYPESAFE_API_KEY -u E3D_SPECIALISTS)
  [[ "$es" == unset ]] || e+=("E3D_SPECIALISTS=$es")
  rc=0; env "${e[@]}" HOME="$T/home" "$T/bin/e3d-debate" "$@" > "$T/stdout" 2> "$T/stderr" || rc=$?
}
go() { # go <root> <providers> <expert numbers...> -- <extra args>; experts on, 2 rounds, v3b
  local T="$1" provs="$2"; shift 2
  local -a sp=() extra=()
  while [[ $# -gt 0 && "$1" != -- ]]; do sp+=(--specialist "$1"); shift; done
  [[ "${1:-}" == -- ]] && shift; extra=("$@")
  run "$T" 1 "q?" "${sp[@]}" --providers "$provs" --rounds 2 --synthesizer synth --prompts v3b --out-dir "$T/out" ${extra[@]+"${extra[@]}"}
}
seats_of() { jq -c '.providers' "$1/out/decision-log.json"; }
seen_for() { grep -l -- "$2" "$1"/seen/* 2>/dev/null | wc -l | tr -d ' '; }

# ---- 1. enough providers: the spread is what Phase 1 did, no suffixes, independence counted ----
T="$(build claude codex gemini grok-build)"
go "$T" claude,codex,gemini,grok-build e1 e2 e3
[[ $rc -eq 0 ]] || fail "three experts on four providers failed: $(cat "$T/stderr")"
[[ "$(seats_of "$T")" == '["claude","codex","gemini"]' ]] || fail "distinct providers in pool order, no suffix: $(seats_of "$T")"
[[ "$(jq -c '.panel.independence' "$T/out/decision-log.json")" == '{"seats":3,"adapters":3,"families":3}' ]] || fail "independence block: $(jq -c .panel.independence "$T/out/decision-log.json")"
[[ "$(jq -r '[.panel.experts[] | .seat == .adapter] | all' "$T/out/decision-log.json")" == true ]] || fail "each seat carries its adapter"
! grep -q 'vendor family' "$T/stderr" || fail "a multi-family panel prints no one-family line"
! grep -q '^\*\*Independence' "$T/out/transcript.md" || fail "no one-family note in the transcript header of a multi-family panel"
# a family that already holds a seat is only used after the others (anthropic-api and claude are one family)
T="$(build claude anthropic-api codex)"
go "$T" claude,anthropic-api,codex e1 e2 e3
[[ "$(seats_of "$T")" == '["claude","codex","anthropic-api"]' ]] || fail "spread across vendor families first: $(seats_of "$T")"
echo "assignment 1 (spread unchanged): ok"

# ---- 2. extras go to the least-used family, then the least-used adapter ----
T="$(build claude anthropic-api codex)"
go "$T" claude,anthropic-api,codex e1 e2 e3 e4
[[ $rc -eq 0 ]] || fail "four experts on three adapters failed: $(cat "$T/stderr")"
[[ "$(seats_of "$T")" == '["claude","codex","anthropic-api","codex.2"]' ]] || fail "the extra seat goes to the family with fewer seats (openai 1 vs anthropic 2): $(seats_of "$T")"
[[ "$(jq -c '.panel.independence' "$T/out/decision-log.json")" == '{"seats":4,"adapters":3,"families":2}' ]] || fail "independence: $(jq -c .panel.independence "$T/out/decision-log.json")"
echo "assignment 2 (extras on the least-used family): ok"

# ---- 3. adapter.2 and adapter.3; each seat is independent: its own lens, its own prompts, its own calls ----
T="$(build claude codex)"
go "$T" claude,codex e1 e2 e3 e4 e5
[[ $rc -eq 0 ]] || fail "five experts on two providers failed: $(cat "$T/stderr")"
[[ "$(seats_of "$T")" == '["claude","codex","claude.2","codex.2","claude.3"]' ]] || fail "seat ids: $(seats_of "$T")"
[[ "$(jq -c '[.panel.experts[] | .adapter]' "$T/out/decision-log.json")" == '["claude","codex","claude","codex","claude"]' ]] || fail "adapters: $(jq -c .panel "$T/out/decision-log.json")"
for i in 1 2 3 4 5; do
  seat="$(jq -r ".providers[$((i - 1))]" "$T/out/decision-log.json")"
  [[ "$(seen_for "$T" "You are $seat, one of 5 analysts who will each answer independently")" == 1 ]] || fail "$seat: exactly one round-1 prompt"
  [[ "$(seen_for "$T" "You are $seat, one of 5 analysts debating one question")" == 1 ]] || fail "$seat: exactly one round-2 prompt"
  f="$(grep -l "You are $seat, one of 5 analysts who will each answer independently" "$T"/seen/*)"
  [[ "$(grep -c "LENS-E$i-MARK" "$f")" == 1 ]] || fail "$seat: its own lens exactly once"
  for j in 1 2 3 4 5; do [[ $j -eq $i ]] || ! grep -q "LENS-E$j-MARK" "$f" || fail "$seat saw the lens of e$j"; done
  grep -q "^## Round 1 -- $seat\$" "$T/out/transcript.md" && grep -q "^## Round 2 -- $seat\$" "$T/out/transcript.md" || fail "$seat: transcript headings"
  grep -q "do the $seat thing" "$T/out/transcript.md" || fail "$seat: own answer"
done
[[ "$(ls "$T/seen" | grep -c '^claude\.')" == 6 && "$(ls "$T/seen" | grep -c '^codex\.')" == 4 ]] || fail "calls per adapter: 3 claude seats x 2 rounds, 2 codex seats x 2 rounds"
echo "assignment 3 (adapter.2, adapter.3, independent seats): ok"

# ---- 4. one of two same-adapter seats failing does not drop the other ----
T="$(build claude codex)"; : > "$T/fail-claude.2"
go "$T" claude,codex e1 e2 e3
[[ $rc -eq 0 ]] || fail "a failing second seat: $(cat "$T/stderr")"
[[ "$(jq -c '[.seats_unavailable[] | .provider]' "$T/out/seats.json")" == '["claude.2"]' ]] || fail "only claude.2 is lost: $(jq -c .seats_unavailable "$T/out/seats.json")"
grep -q '^## Round 2 -- claude$' "$T/out/transcript.md" || fail "claude continues when claude.2 fails"
T="$(build claude codex)"; : > "$T/fail-claude"
go "$T" claude,codex e1 e2 e3
[[ "$(jq -c '[.seats_unavailable[] | .provider]' "$T/out/seats.json")" == '["claude"]' ]] && grep -q '^## Round 2 -- claude.2$' "$T/out/transcript.md" || fail "claude.2 continues when claude fails"
echo "assignment 4 (independent fate): ok"

# ---- 5. the 6-seat bound ----
T="$(build claude codex)"
go "$T" claude,codex e1 e2 e3 e4 e5 e6
[[ $rc -eq 0 ]] || fail "six seats are allowed: $(cat "$T/stderr")"
[[ "$(jq '.providers | length' "$T/out/decision-log.json")" == 6 ]] || fail "six seats: $(seats_of "$T")"
go "$T" claude,codex e1 e2 e3 e4 e5 e6 e7
[[ $rc -eq 1 ]] && grep -q 'at most 6 seats' "$T/stderr" || fail "seven named experts must refuse: rc=$rc $(cat "$T/stderr")"
run "$T" 1 "q?" --panel six --providers claude,codex --rounds 1 --synthesizer synth --out-dir "$T/o6"
[[ $rc -eq 0 ]] && [[ "$(jq '.providers | length' "$T/o6/decision-log.json")" == 6 && "$(jq -c .panel.dropped "$T/o6/decision-log.json")" == '[]' ]] || fail "a six-expert preset is seated whole on two providers: $(cat "$T/stderr")"
run "$T" 1 "q?" --panel seven --providers claude,codex --rounds 1 --synthesizer synth --out-dir "$T/o7"
[[ $rc -eq 0 && "$(jq -c .panel.dropped "$T/o7/decision-log.json")" == '["e7"]' ]] || fail "a seven-expert preset drops only for the bound: $(cat "$T/stderr")"
echo "assignment 5 (the 6-seat bound): ok"

# ---- 6. one vendor family: refused by default, allowed on purpose, always labelled ----
T="$(build claude anthropic-api)"
go "$T" claude,anthropic-api e1 e2 e3
[[ $rc -eq 1 ]] && grep -q 'vendor family' "$T/stderr" && grep -q -- '--min-families 1' "$T/stderr" || fail "one family must refuse and say how to lower it: rc=$rc $(cat "$T/stderr")"
[[ ! -e "$T/seen" ]] || fail "a refused panel must not call a model"
go "$T" claude,anthropic-api e1 e2 e3 -- --min-families 2
[[ $rc -eq 1 ]] || fail "--min-families 2 is the default"
go "$T" claude,anthropic-api e1 e2 e3 -- --min-families 1
[[ $rc -eq 0 ]] || fail "--min-families 1 allows lenses on one family: $(cat "$T/stderr")"
grep -qx '3 seats on 1 vendor family: lenses differ, the model does not' "$T/stderr" || fail "the one-family line, exactly: $(cat "$T/stderr")"
[[ "$(grep -c 'on 1 vendor family' "$T/stderr")" == 1 ]] || fail "the line is printed once"
grep -qx '\*\*Independence:\*\* 3 seats on 1 vendor family: lenses differ, the model does not\.' "$T/out/transcript.md" || fail "the transcript header repeats it"
[[ "$(jq -c '.panel.independence' "$T/out/decision-log.json")" == '{"seats":3,"adapters":2,"families":1}' ]] || fail "independence: $(jq -c .panel.independence "$T/out/decision-log.json")"
go "$T" claude,anthropic-api e1 e2 -- --min-families 3
[[ $rc -eq 1 ]] || fail "a panel on 1 family must refuse --min-families 3"
# a single adapter is enough for lens-only runs
T="$(build claude)"
go "$T" claude e1 e2 e3 -- --min-families 1
[[ $rc -eq 0 && "$(seats_of "$T")" == '["claude","claude.2","claude.3"]' ]] || fail "three lenses on one adapter: $(seats_of "$T") $(cat "$T/stderr")"
grep -qx '3 seats on 1 vendor family: lenses differ, the model does not' "$T/stderr" || fail "one-adapter line"
go "$T" claude e1 e2 e3
[[ $rc -eq 1 ]] || fail "one adapter refuses by default"
# a bad value, and a plain debate is untouched by the flag's existence
go "$T" claude e1 e2 -- --min-families 0; [[ $rc -eq 1 ]] && grep -q 'whole number' "$T/stderr" || fail "--min-families 0 refused"
T="$(build claude anthropic-api)"
run "$T" unset "q?" --providers claude,anthropic-api --rounds 1 --synthesizer synth --out-dir "$T/plain"
[[ $rc -eq 0 ]] && ! grep -q 'vendor family' "$T/stderr" && jq -e 'has("panel") | not' "$T/plain/decision-log.json" >/dev/null || fail "a plain debate on one family runs as before: $(cat "$T/stderr")"
run "$T" 1 "q?" --providers claude,anthropic-api --min-families 1 --rounds 1 --synthesizer synth
[[ $rc -eq 1 ]] && grep -q 'applies to a panel' "$T/stderr" || fail "--min-families without a panel is refused: $(cat "$T/stderr")"
echo "assignment 6 (--min-families and the independence line): ok"

# ---- 7. the switch, and per-token pricing ----
T="$(build claude codex)"
for es in unset "" 0; do
  run "$T" "$es" "q?" --specialist e1 --specialist e2 --providers claude,codex --min-families 1
  [[ $rc -eq 1 ]] && grep -q 'experts are off' "$T/stderr" || fail "E3D_SPECIALISTS='$es' --min-families must refuse: rc=$rc"
  run "$T" "$es" "q?" --providers claude,codex --min-families 1
  [[ $rc -eq 1 ]] && grep -q 'experts are off' "$T/stderr" || fail "E3D_SPECIALISTS='$es' --min-families alone must refuse: rc=$rc"
done
T="$(build claude codex)"; cp "$ROOT/lib/debate/token-pricing.mjs" "$T/lib/debate/"
rc=0; env -u TYPESAFE_API_KEY E3D_SPECIALISTS=1 HOME="$T/home" E3D_DEBATE_MAX_TOKENS='{"claude":100,"codex":100}' "$T/bin/e3d-debate" "q?" --specialist e1 --specialist e2 --specialist e3 --providers claude,codex --synthesizer claude > "$T/stdout" 2> "$T/stderr" || rc=$?
[[ $rc -eq 1 ]] && grep -q 'per-token pricing prices one seat per provider' "$T/stderr" || fail "token limits with two seats on one provider stay refused: rc=$rc $(cat "$T/stderr")"
echo "assignment 7 (switch, per-token): ok"

echo "experts-assignment: PASS"
