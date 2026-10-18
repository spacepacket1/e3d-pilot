#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; BIN="$ROOT/bin/e3d-pilot"
repo="$(mktemp -d)"; trap 'rm -rf "$repo"' EXIT
run="$repo/.e3d-pilot/runs/impl-idea-aaa-r-1"; ideas="$repo/.e3d-pilot/ideas/idea-aaa"
mkdir -p "$run" "$ideas" "$repo/.e3d-pilot/runs/impl-idea-bbb-r-2"
printf '# spec\n' > "$run/spec-final.md"; printf 'repo\t%s\tidea-aaa\n' "$repo" > "$run/idea-link.txt"
printf 'abc123\n' > "$run/execute-start-sha.txt"; printf '{"status":"implemented"}\n' > "$ideas/idea.json"
# a run with no spec-final.md must be skipped
out="$("$BIN" replay harvest --repo "$repo")"
[[ "$out" == *"harvested 1 run"* ]] || { echo "unexpected: $out" >&2; exit 1; }
t="$repo/.e3d-pilot/replay/impl-idea-aaa-r-1"
[[ "$(jq -r '.start_sha' "$t/task.json")" == abc123 && "$(jq -r '.replayable' "$t/task.json")" == true ]] || { echo "bad task.json" >&2; exit 1; }
[[ -f "$t/spec-final.md" ]] || { echo "spec not copied" >&2; exit 1; }
rm "$run/execute-start-sha.txt"; "$BIN" replay harvest --repo "$repo" >/dev/null
[[ "$(jq -r '.replayable' "$t/task.json")" == false ]] || { echo "missing sha should be unreplayable" >&2; exit 1; }
echo "replay-harvest: ok"
