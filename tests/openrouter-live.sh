#!/usr/bin/env bash
set -euo pipefail

# Live check of the OpenRouter voices: one tiny real call each (about 64 output tokens). Costs a fraction of a cent, so it only runs when asked:
#   E3D_LIVE_OPENROUTER=1 OPENROUTER_API_KEY_FILE=... bash tests/openrouter-live.sh
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${E3D_LIVE_OPENROUTER:-0}" != "1" ]]; then echo "openrouter-live: skipped (set E3D_LIVE_OPENROUTER=1)"; exit 0; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf 'Reply with the single word: ready\n' > "$TMP/prompt.md"
status=0
for v in or-deepseek or-glm or-minimax or-mistral; do
  if out="$(OPENROUTER_MAX_TOKENS=64 "$ROOT/lib/providers/$v" "$TMP/prompt.md" 2> "$TMP/err")"; then
    usage="$(sed -n 's/^e3d_provider_usage=//p' "$TMP/err" | jq -c '{model, tokens, upstream: .routing.upstream, cost: .routing.cost}')"
    printf 'ok   %-12s %s\n' "$v" "$usage"
  else
    printf 'FAIL %-12s %s\n' "$v" "$(head -c 200 "$TMP/err" | tr '\n' ' ')"; status=1
  fi
done
exit "$status"
