#!/usr/bin/env bash
# e3d-debate decision log (idea-bf6be2834a60) and computed agreement (lib/debate/agreement).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# --- agreement unit cases ---
agree() { printf '%s' "$1" | node "$ROOT/lib/debate/agreement"; }
mk() { jq -nc --arg a "$1" --arg b "$2" '{participants:["alpha","beta"],answers:{alpha:$a,beta:$b}}'; }
B=$'ACTION: ship it\nAGREES_WITH: alpha\nCONFIDENCE: high'
r="$(agree "$(mk $'ACTION: ship it\nAGREES_WITH: beta (with a caveat about rollout)\nCONFIDENCE: high' "$B")")"
[[ "$(jq -r .converged <<< "$r")" == true ]] || fail "a parenthetical caveat should not break agreement: $r"
[[ "$(jq -r .basis <<< "$r")" == computed ]] || fail "basis should be computed"
r="$(agree "$(mk $'ACTION: ship it\nAGREES_WITH: not beta\nCONFIDENCE: high' "$B")")"
[[ "$(jq -r .converged <<< "$r")" == false ]] || fail "'not beta' must not count as naming beta: $r"
r="$(agree "$(mk $'ACTION: ship it\nAGREES_WITH: none\nCONFIDENCE: high' "$B")")"
[[ "$(jq -r .participants.alpha.computed_status <<< "$r")" == revise ]] || fail "none names nobody"
r="$(agree "$(mk $'ACTION: ship it\nAGREES_WITH: beta' $'ACTION: \nAGREES_WITH: alpha')")"
[[ "$(jq -r .participants.beta.computed_status <<< "$r")" == revise ]] || fail "an empty ACTION is not agreement"
r="$(agree "$(mk $'Answer\nPOSITION: p\nstatus: approved' $'Answer\nPOSITION: p\nstatus: approved')")"
[[ "$(jq -r .basis <<< "$r")" == declared && "$(jq -r .converged <<< "$r")" == true ]] || fail "v2 answers fall back to the declared status: $r"
echo '{}' | node "$ROOT/lib/debate/agreement" 2>/dev/null && fail "bad input should exit non-zero" || true

# --- end to end with stub providers ---
mkdir -p "$T/bin" "$T/lib/providers" "$T/lib/debate" "$T/lib/negotiate"
cp "$ROOT/lib/negotiate/convergence" "$T/lib/negotiate/"
cp "$ROOT/bin/e3d-debate" "$T/bin/"
cp "$ROOT/lib/debate/agreement" "$T/lib/debate/"
echo '{"type":"module"}' > "$T/package.json"
cp "$ROOT/lib/providers/jev.sh" "$ROOT/lib/providers/common.sh" "$T/lib/providers/"
stub() { # name agrees-with-text
  cat > "$T/lib/providers/$1" <<STUB
#!/usr/bin/env bash
printf 'VERDICT: x\nACTION: do the thing\nAGREES_WITH: $2\nCONFIDENCE: high\n'
STUB
  chmod +x "$T/lib/providers/$1"
}
cat > "$T/lib/providers/synth" <<'STUB'
#!/usr/bin/env bash
printf 'FINAL ANSWER: ok\nCONSENSUS: split\nDISSENT: alpha: would not.\n'
STUB
chmod +x "$T/lib/providers/synth"
SECRET_Q="top secret question text $$"
run() { env -u TYPESAFE_API_KEY E3D_DEBATE_DECISION_LOG="$T/log/decisions.jsonl" "$T/bin/e3d-debate" "$SECRET_Q" --prompts v3c --providers alpha,beta --rounds 3 --synthesizer synth --out-dir "$1" > "$T/stdout" 2> "$T/stderr" || { cat "$T/stderr"; exit 1; }; }

# converged: both name each other
stub alpha "beta (partly)"; stub beta "alpha"
run "$T/out1"
l="$T/out1/decision-log.json"
[[ -s "$l" ]] || fail "decision-log.json not written"
[[ "$(jq -r .stop_reason "$l")" == converged ]] || fail "expected converged: $(cat "$l")"
[[ "$(jq -r .rounds_ran "$l")" == 2 ]] || fail "should stop after round 2"
[[ "$(jq -r '.rounds[1].converged' "$l")" == true && "$(jq -r '.rounds[1].basis' "$l")" == computed ]] || fail "round 2 should record computed convergence"
[[ "$(jq -r .question_sha256 "$l")" =~ ^[0-9a-f]{64}$ ]] || fail "question hash missing"
grep -q "$SECRET_Q" "$l" && fail "the log must not contain the question text"

# not converged: alpha names no one
stub alpha "none"
run "$T/out2"
l="$T/out2/decision-log.json"
[[ "$(jq -r .stop_reason "$l")" == max_rounds && "$(jq -r .rounds_ran "$l")" == 3 ]] || fail "expected max_rounds after 3: $(cat "$l")"
[[ "$(jq -r .dissent_present "$l")" == true && "$(jq -r .consensus "$l")" == split ]] || fail "synthesis fields missing"
[[ "$(jq -r '.rounds[2].providers[0].computed_status' "$l")" == revise ]] || fail "per-provider computed status missing"

# the shared log got both runs, one line each
[[ "$(wc -l < "$T/log/decisions.jsonl" | tr -d ' ')" == 2 ]] || fail "E3D_DEBATE_DECISION_LOG should hold 2 lines"
jq -e . "$T/log/decisions.jsonl" >/dev/null || fail "shared log is not valid JSONL"

# an unwritable shared log never fails the debate
E3D_DEBATE_DECISION_LOG=/proc/nope/x.jsonl env -u TYPESAFE_API_KEY "$T/bin/e3d-debate" "q" --prompts v3c --providers alpha,beta --rounds 2 --synthesizer synth > /dev/null 2>&1 || fail "a log write failure must not fail the debate"
echo "debate-decision-log: ok"
