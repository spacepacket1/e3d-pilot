#!/usr/bin/env bash
# Shared by tests/debate-specialists.sh and make-golden.sh: a temp copy of the engine with stub provider adapters, so a test can read the
# exact prompt file each seat receives. Nothing here calls a model or the network.
H_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# mkstub <root> <name> [v2|v3]: an adapter that answers the availability probe (exit 2 when <root>/down-<name> exists) and otherwise copies
# the prompt file it was given to <root>/seen-<name>-<k>.md, k = 0 for round 1, 1 for round 2.
mkstub() {
  local T="$1" n="$2" style="${3:-v2}" other=beta
  [[ "$n" == beta ]] && other=alpha
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [[ "${E3D_PILOT_CHECK:-}" == 1 ]]; then [[ -f "%s/down-%s" ]] && exit 2; exit 0; fi\n' "$T" "$n"
    printf 'cp "$1" "%s/seen-%s-$(grep -c . "%s/count-%s" 2>/dev/null || echo 0).md"\n' "$T" "$n" "$T" "$n"
    printf 'echo x >> "%s/count-%s"\n' "$T" "$n"
    if [[ "$style" == v3 ]]; then
      printf "printf 'VERDICT: x\\\\nACTION: do the %s thing\\\\nAGREES_WITH: %s\\\\nCONFIDENCE: high\\\\n'\n" "$n" "$other"
    else
      printf "printf 'Answer from %s.\\\\nPOSITION: %s position\\\\nstatus: revise\\\\n'\n" "$n" "$n"
    fi
  } > "$T/lib/providers/$n"
  chmod +x "$T/lib/providers/$n"
}

# build_root <root> <debate-script> <style> <provider>...: a temp engine tree with the given script and stub adapters (plus a synth stub).
build_root() {
  local T="$1" script="$2" style="$3"; shift 3
  mkdir -p "$T/bin" "$T/lib/providers" "$T/lib/debate" "$T/lib/mcp" "$T/lib/specialists" "$T/home"
  cp "$script" "$T/bin/e3d-debate"
  cp "$H_ROOT/lib/providers/jev.sh" "$H_ROOT/lib/providers/common.sh" "$T/lib/providers/"
  cp "$H_ROOT/lib/mcp/voices.js" "$T/lib/mcp/"
  for f in specialists.mjs specialists-plan.mjs specialists-cli.mjs; do [[ -f "$H_ROOT/lib/debate/$f" ]] && cp "$H_ROOT/lib/debate/$f" "$T/lib/debate/" || true; done
  [[ -f "$H_ROOT/lib/specialists/panels.json" ]] && cp "$H_ROOT/lib/specialists/panels.json" "$T/lib/specialists/" || true
  local n
  for n in "$@"; do mkstub "$T" "$n" "$style"; done
  cat > "$T/lib/providers/synth" <<STUB
#!/usr/bin/env bash
if [[ "\${E3D_PILOT_CHECK:-}" == 1 ]]; then exit 0; fi
cp "\$1" "$T/seen-synth.md"
printf 'FINAL ANSWER: ok\nCONSENSUS: split\nDISSENT: none\n'
STUB
  chmod +x "$T/lib/providers/synth"
}

# run_debate <root> <args...>: runs the engine copy in <root> with a private HOME; stdout and stderr go to <root>/stdout and <root>/stderr.
run_debate() {
  local T="$1"; shift
  env -u TYPESAFE_API_KEY HOME="$T/home" "$T/bin/e3d-debate" "$@" > "$T/stdout" 2> "$T/stderr"
}

# norm_prompt: the one volatile line of a prompt is today's date.
norm_prompt() { sed -E "s/^Today's date \(UTC\): [0-9-]+\./Today's date (UTC): DATE./"; }
