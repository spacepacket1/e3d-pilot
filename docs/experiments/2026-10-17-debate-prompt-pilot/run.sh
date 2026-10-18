#!/usr/bin/env bash
# Pilot: 3 questions x variants v2 (A), v3b (B), v3c (C). Panel: claude (anthropic-api), gpt-5.5 (openai-api),
# grok-build (CLI, spend not measurable). Synthesizer: anthropic-api in every variant. 3 debates at a time.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
HERE="$PWD"; ROOT="$(cd ../../.. && pwd)"
set -a; source "$HOME/.config/e3d-pilot/anthropic-api-key"; set +a
export OPENAI_API_KEY_FILE="$HOME/.config/e3d-pilot/openai-api-key" OPENAI_API_MODEL=gpt-5.5
export TMPDIR="$HERE/tmp"; unset TYPESAFE_API_KEY
run_one() {
  local q="$1" v="$2" out="$HERE/runs/$q-$v"
  mkdir -p "$out"
  "$ROOT/bin/e3d-debate" --question-file "$HERE/questions/$q.md" --providers anthropic-api,openai-api,grok-build \
    --synthesizer anthropic-api --rounds 2 --max-words 450 --prompts "$v" --out-dir "$out" > "$out/stdout.txt" 2> "$out/stderr.txt"
  echo "$q $v exit=$?"
}
for q in q1-federated q2-spec-review q3-fact-sheet; do
  for v in v2 v3b v3c; do run_one "$q" "$v" & done
  wait
done
echo ALL-DONE
