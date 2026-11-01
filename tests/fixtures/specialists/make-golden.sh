#!/usr/bin/env bash
# Regenerates golden/: the prompts each seat receives, the synthesis prompt and the decision log of a plain two-seat debate, for every prompt
# version. Run it ONLY against a copy of bin/e3d-debate from BEFORE the experts change; tests/debate-specialists.sh then proves the changed
# script still produces exactly these when no expert is named.   Usage: make-golden.sh <path-to-baseline-e3d-debate>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/harness.sh"
BASE="${1:?path to the baseline bin/e3d-debate}"
for v in v2 v3b v3c; do
  T="$(mktemp -d)"; style=v2; [[ "$v" != v2 ]] && style=v3
  build_root "$T" "$BASE" "$style" alpha beta
  run_debate "$T" "q?" --providers alpha,beta --rounds 2 --synthesizer synth --prompts "$v" --out-dir "$T/out"
  rm -rf "$HERE/golden/$v"; mkdir -p "$HERE/golden/$v"
  for f in seen-alpha-0 seen-alpha-1 seen-beta-0 seen-beta-1 seen-synth; do norm_prompt < "$T/$f.md" > "$HERE/golden/$v/$f.md"; done
  jq -S 'del(.ts, .seconds)' "$T/out/decision-log.json" > "$HERE/golden/$v/decision-log.json"
  rm -rf "$T"
done
echo "golden files written to $HERE/golden"
