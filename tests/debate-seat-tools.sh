#!/usr/bin/env bash
# Debate seats, the synthesis and the recap run with provider tools off (CLAUDE_TOOLS="" reaches the adapter); E3D_DEBATE_SEAT_TOOLS=1 opts out.
# A stub adapter records CLAUDE_TOOLS for every call (cloud issue 476).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/fixtures/specialists/harness.sh"
TMPS=(); trap 'for d in "${TMPS[@]}"; do rm -rf "$d"; done' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
build() { # build -> root; two stub adapters that log CLAUDE_TOOLS (set/unset and value) per call
  local T; T="$(mktemp -d)"; TMPS+=("$T")
  build_root "$T" "$ROOT/bin/e3d-debate" v3 alpha beta >&2
  mkdir -p "$T/lib/negotiate"; cp "$ROOT/lib/negotiate/convergence" "$T/lib/negotiate/"; cp "$ROOT/lib/debate/agreement" "$ROOT/lib/debate/recap.mjs" "$T/lib/debate/"; echo '{"type":"module"}' > "$T/package.json"
  for n in alpha beta synth recapper; do
    cat > "$T/lib/providers/$n" <<STUB
#!/usr/bin/env bash
if [[ "\${E3D_PILOT_CHECK:-}" == 1 ]]; then exit 0; fi
echo "$n tools=[\${CLAUDE_TOOLS-unset}]" >> "$T/calls.log"
printf 'VERDICT: x\nACTION: do the thing\nAGREES_WITH: none\nCONFIDENCE: high\n'
STUB
    chmod +x "$T/lib/providers/$n"
  done
  printf '%s' "$T"
}
run() { local T="$1"; shift; env -u TYPESAFE_API_KEY -u CLAUDE_TOOLS HOME="$T/home" "$@" "$T/bin/e3d-debate" "Is a monorepo right for two people?" --providers alpha,beta --rounds 1 --synthesizer synth --recap recapper > "$T/stdout" 2> "$T/stderr" || true; }

T="$(build)"; run "$T" env
[[ -s "$T/calls.log" ]] || { cat "$T/stderr" >&2; fail "stub adapters were never called"; }
[[ "$(wc -l < "$T/calls.log")" -ge 3 ]] || fail "expected seat, synthesis and recap calls, got: $(cat "$T/calls.log")"
grep -qv 'tools=\[\]' "$T/calls.log" && fail "a debate call ran with provider tools on: $(grep -v 'tools=\[\]' "$T/calls.log")"
echo "ok: every debate call ($(wc -l < "$T/calls.log" | tr -d ' ')) ran with CLAUDE_TOOLS empty"

T="$(build)"; run "$T" env E3D_DEBATE_SEAT_TOOLS=1
[[ -s "$T/calls.log" ]] || fail "opt-in run made no calls"
grep -q 'tools=\[unset\]' "$T/calls.log" || fail "E3D_DEBATE_SEAT_TOOLS=1 did not leave tools alone: $(cat "$T/calls.log")"
echo "ok: E3D_DEBATE_SEAT_TOOLS=1 leaves the adapter's default"
echo "debate-seat-tools: ok"
