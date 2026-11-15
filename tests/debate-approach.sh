#!/usr/bin/env bash
set -euo pipefail

# --approach hypotheses (bin/e3d-debate): a debate that compares explanations instead of picking an action. Stub adapters record the exact
# prompt each seat and the synthesizer receive. No model calls, no network. The default (decide) prompts are pinned by tests/debate-specialists.sh.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/fixtures/specialists/harness.sh"
TMPS=(); trap 'for d in "${TMPS[@]}"; do rm -rf "$d"; done' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -q -- "$2" "$1" || fail "$3: [$2] not found in $1"; }
hasnt() { ! grep -q -- "$2" "$1" || fail "$3: [$2] should not be in $1"; }
newroot() { local T; T="$(mktemp -d)"; TMPS+=("$T"); build_root "$T" "$ROOT/bin/e3d-debate" v2 alpha beta >&2; printf '%s' "$T"; }

T="$(newroot)"
run_debate "$T" "Why did X fail?" --providers alpha,beta --rounds 2 --synthesizer synth --approach hypotheses --out-dir "$T/out"
has "$T/seen-alpha-0.md" "COMPARE EXPLANATIONS" "round 1 prompt"
has "$T/seen-alpha-0.md" "H1: <short name>" "round 1 shape"
has "$T/seen-alpha-0.md" "EVENT CONFIDENCE" "round 1 separates event from cause"
has "$T/seen-alpha-0.md" "claim by an interested party" "round 1 official statements"
hasnt "$T/seen-alpha-0.md" "Give your best direct answer" "round 1 is not the decide prompt"
hasnt "$T/seen-alpha-0.md" "beta" "round 1 is independent: no peer text"
echo "ok - round 1: independent, competing explanations, event vs cause confidence"
has "$T/seen-alpha-1.md" "STEELMAN" "round 2 prompt"
has "$T/seen-alpha-1.md" "RANKING:" "round 2 ends with a ranking"
has "$T/seen-alpha-1.md" "Answer from beta." "round 2 shows the peer's round 1 text"
hasnt "$T/seen-alpha-1.md" "status: approved" "round 2 has no status line to converge on"
[[ -f "$T/seen-alpha-1.md" ]] || fail "round 2 did not run"
! grep -q "Converged after round" "$T/stderr" || fail "a hypotheses debate must not converge early"
echo "ok - round 2: steelman, check, re-rank; never converges early"
has "$T/seen-synth.md" "judge of an analysis, not a decision" "synthesis prompt"
has "$T/seen-synth.md" '## Hypotheses' "synthesis asks for the ranked list"
has "$T/seen-synth.md" "ranks the same explanation first" "consensus means agreement on the top-ranked explanation"
has "$T/seen-synth.md" "## What would change this" "the shared addendum still applies"
has "$T/seen-synth.md" "## Key claims" "the claim ledger still applies"
hasnt "$T/seen-synth.md" "the action to take" "no action wording"
echo "ok - synthesis: ranked hypotheses, consensus on the top explanation, ledger and what-would-change kept"

# the environment variable sets it too, and a bad value is refused
T2="$(newroot)"
env -u TYPESAFE_API_KEY E3D_DEBATE_APPROACH=hypotheses HOME="$T2/home" "$T2/bin/e3d-debate" "Why?" --providers alpha,beta --rounds 1 --synthesizer synth --out-dir "$T2/out" > "$T2/stdout" 2> "$T2/stderr" || fail "env approach run"
has "$T2/seen-alpha-0.md" "COMPARE EXPLANATIONS" "E3D_DEBATE_APPROACH"
rc=0; env -u TYPESAFE_API_KEY HOME="$T2/home" "$T2/bin/e3d-debate" "Why?" --providers alpha,beta --approach nope > "$T2/o2" 2> "$T2/e2" || rc=$?
[[ "$rc" == 1 ]] || fail "bad --approach should exit 1, got $rc"; has "$T2/e2" "--approach must be decide or hypotheses" "bad value message"
echo "ok - E3D_DEBATE_APPROACH works and a bad value is refused"
echo "debate-approach: all passed"
