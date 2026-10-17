#!/usr/bin/env bash
# Covers lib/ideas/brain_recall.sh: the optional e3d-brain recall block in the ideate prompt.
# Uses a stub `ask` script and never needs e3d-brain or the network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/ideas/brain_recall.sh
source "$ROOT/lib/ideas/brain_recall.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

printf '{}' > "$tmp/config.json"
cat > "$tmp/ask.mjs" <<'JS'
console.log(`1. earlier attempt  [pilot/ideas/idea-1.md]\n   queried: ${process.argv[2]}`);
JS

# 1. off by default
out="$(brain_recall_block revenue)"
[[ -z "$out" ]] || fail "expected no output when the env vars are unset"

# 2. on: advisory block with the stub's hit, and the query includes the focus
out="$(E3D_PILOT_BRAIN_CONFIG="$tmp/config.json" E3D_PILOT_BRAIN_ASK="$tmp/ask.mjs" brain_recall_block revenue)"
[[ "$out" == *"advisory"* ]] || fail "missing advisory wording"
[[ "$out" == *"pilot/ideas/idea-1.md"* ]] || fail "missing recalled hit"
[[ "$out" == *"revenue"* ]] || fail "query should include the focus"

# 3. fails open: broken node, missing files
out="$(E3D_PILOT_BRAIN_CONFIG="$tmp/config.json" E3D_PILOT_BRAIN_ASK="$tmp/ask.mjs" E3D_PILOT_BRAIN_NODE=/nonexistent brain_recall_block x)" || fail "must not fail"
[[ -z "$out" ]] || fail "expected empty output when node is missing"
out="$(E3D_PILOT_BRAIN_CONFIG="$tmp/missing.json" E3D_PILOT_BRAIN_ASK="$tmp/ask.mjs" brain_recall_block x)" || fail "must not fail"
[[ -z "$out" ]] || fail "expected empty output when the config is missing"

# 4. the ideate prompt gets the block only when enabled
src="$(sed -n '/^build_ideate_prompt() {/,/^}/p' "$ROOT/bin/e3d-pilot")"
grep -q 'brain_recall_block "\$focus"' <<<"$src" || fail "build_ideate_prompt does not call brain_recall_block"

printf 'brain_recall: all checks passed\n'
