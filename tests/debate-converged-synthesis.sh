#!/usr/bin/env bash
set -euo pipefail

# A unanimous panel still stops early, but the synthesizer still writes the summary (so "What would change this", "Key claims" and the seat note exist
# for it too). E3D_DEBATE_FAST_SYNTHESIS=1 restores the old shortcut (no synthesizer call). Stub adapters record the prompts; no model calls, no network.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/fixtures/specialists/harness.sh"
TMPS=(); trap 'for d in "${TMPS[@]}"; do rm -rf "$d"; done' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

newroot() {
  local T; T="$(mktemp -d)"; TMPS+=("$T"); build_root "$T" "$ROOT/bin/e3d-debate" v2 alpha beta >&2
  mkdir -p "$T/lib/negotiate" && cp "$ROOT"/lib/negotiate/* "$T/lib/negotiate/"   # the early-convergence checker
  local n
  for n in alpha beta; do
    cat > "$T/lib/providers/$n" <<STUB
#!/usr/bin/env bash
if [[ "\${E3D_PILOT_CHECK:-}" == 1 ]]; then exit 0; fi
k="\$(grep -c . "$T/count-$n" 2>/dev/null || echo 0)"; cp "\$1" "$T/seen-$n-\$k.md"; echo x >> "$T/count-$n"
printf 'Answer from %s.\nPOSITION: use the plan\nstatus: approved\n' "$n"
STUB
    chmod +x "$T/lib/providers/$n"
  done
  cat > "$T/lib/providers/synth" <<STUB
#!/usr/bin/env bash
if [[ "\${E3D_PILOT_CHECK:-}" == 1 ]]; then exit 0; fi
cp "\$1" "$T/seen-synth.md"
printf 'FINAL ANSWER: use the plan.\nCONSENSUS: full\nDISSENT: none\n\n## What would change this\n- A benchmark above the limit\n'
STUB
  chmod +x "$T/lib/providers/synth"
  printf '%s' "$T"
}

# default: stops after round 2 (everyone approved) and still calls the synthesizer
T="$(newroot)"
env -u TYPESAFE_API_KEY HOME="$T/home" "$T/bin/e3d-debate" "q?" --providers alpha,beta --rounds 3 --synthesizer synth --out-dir "$T/out" > "$T/stdout" 2> "$T/stderr" || { cat "$T/stderr" >&2; fail "default run"; }
grep -q "Converged after round 2" "$T/stderr" || fail "the early stop should still happen after round 2"
[[ "$(grep -c . "$T/count-alpha")" == 2 ]] || fail "round 3 should not run: alpha was called $(grep -c . "$T/count-alpha") times"
[[ -e "$T/seen-synth.md" ]] || fail "a unanimous debate must still call the synthesizer"
grep -q "converged after round 2 of a max 3" "$T/seen-synth.md" || fail "the synthesis prompt should say how the debate ended"
grep -q "## What would change this" "$T/seen-synth.md" || fail "the synthesis prompt should ask for the sections"
grep -q "^## What would change this" "$T/stdout" || fail "the verdict should carry the section the synthesizer wrote"
! grep -q "fast path" "$T/stderr" || fail "no fast path by default"
[[ "$(jq -r '[.fast_synthesis, .stop_reason, .converged_at_round] | @csv' "$T/out/decision-log.json")" == 'false,"converged",2' ]] || fail "decision log: $(jq -c '[.fast_synthesis, .stop_reason, .converged_at_round]' "$T/out/decision-log.json")"
echo "ok - unanimous panel: still stops after round 2, still synthesizes, sections present"

# opt-in: the old shortcut
T2="$(newroot)"
env -u TYPESAFE_API_KEY E3D_DEBATE_FAST_SYNTHESIS=1 HOME="$T2/home" "$T2/bin/e3d-debate" "q?" --providers alpha,beta --rounds 3 --synthesizer synth --out-dir "$T2/out" > "$T2/stdout" 2> "$T2/stderr" || { cat "$T2/stderr" >&2; fail "opt-in run"; }
[[ ! -e "$T2/seen-synth.md" ]] || fail "E3D_DEBATE_FAST_SYNTHESIS=1 should skip the synthesizer"
grep -q "fast path" "$T2/stderr" || fail "the opt-in should say it took the fast path"
grep -q "^FINAL ANSWER: use the plan" "$T2/stdout" || fail "the opt-in emits the first POSITION as the answer"
[[ "$(jq -r .fast_synthesis "$T2/out/decision-log.json")" == true ]] || fail "decision log should record the fast path"
echo "ok - E3D_DEBATE_FAST_SYNTHESIS=1 restores the old shortcut"
echo "debate-converged-synthesis: all passed"
