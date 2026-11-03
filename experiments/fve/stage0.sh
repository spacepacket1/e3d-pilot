#!/usr/bin/env bash
# Stage 0: one haiku seat per task, N repeats, no debate. Writes answers to $OUT/<task>.<k>.txt and sums reported tokens.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="$1"; N="${2:-2}"; mkdir -p "$OUT"
export ANTHROPIC_API_THINKING="${ANTHROPIC_API_THINKING-}" ANTHROPIC_API_KEY_FILE=$HOME/.config/e3d-pilot/anthropic-api-key ANTHROPIC_API_MODEL=claude-haiku-5-5
: > "$OUT/tokens.txt"
for t in t01 t02 t03 t04 t05 t06 t07 t08 t09 t10 t11 t12; do
  node experiments/fve/ask.mjs $t > "$OUT/$t.prompt.md"
  for k in $(seq 1 "$N"); do
    lib/providers/anthropic-api "$OUT/$t.prompt.md" > "$OUT/$t.$k.raw" 2> "$OUT/$t.$k.err" || echo "FAIL $t.$k" >&2
    { grep -ho '"tokens":[0-9]*' "$OUT/$t.$k.err" "$OUT/$t.$k.raw" 2>/dev/null || true; } | head -1 | cut -d: -f2 >> "$OUT/tokens.txt"
    { grep -v '^e3d_provider_usage=' "$OUT/$t.$k.raw" || true; } > "$OUT/$t.$k.txt"
  done
done
echo "total tokens: $(paste -sd+ "$OUT/tokens.txt" | bc)"
