#!/usr/bin/env bash
# Harvest finished pipeline runs into replayable tasks under <repo>/.e3d-pilot/replay/<run-id>/.
# Each holds the frozen spec (spec-final.md) and task.json: idea id, start SHA, idea status.
# Idempotent: re-running refreshes the status snapshot. A run with no recorded start SHA is
# still kept but marked replayable=false (it predates execute-start-sha.txt).
# Usage: harvest.sh <repo>
set -euo pipefail
repo="${1:?usage: harvest.sh <repo>}"
runs="$repo/.e3d-pilot/runs"; out="$repo/.e3d-pilot/replay"
[[ -d "$runs" ]] || exit 0
count=0
for run_dir in "$runs"/*/; do
  run_id="$(basename "$run_dir")"
  [[ -f "$run_dir/spec-final.md" && -f "$run_dir/idea-link.txt" ]] || continue
  idea_id="$(awk -F'\t' '{print $3}' "$run_dir/idea-link.txt")"
  [[ -n "$idea_id" ]] || continue
  start_sha=""
  [[ -f "$run_dir/execute-start-sha.txt" ]] && start_sha="$(tr -d '[:space:]' < "$run_dir/execute-start-sha.txt")"
  status="unknown"
  idea_json="$repo/.e3d-pilot/ideas/$idea_id/idea.json"
  [[ -f "$idea_json" ]] && status="$(jq -r '.status // "unknown"' "$idea_json")"
  mkdir -p "$out/$run_id"
  cp "$run_dir/spec-final.md" "$out/$run_id/spec-final.md"
  jq -n --arg run "$run_id" --arg idea "$idea_id" --arg sha "$start_sha" --arg status "$status" \
    '{run_id:$run, idea_id:$idea, start_sha:(if $sha=="" then null else $sha end), idea_status:$status, replayable:($sha != "")}' \
    > "$out/$run_id/task.json"
  count=$((count + 1))
done
printf 'replay: harvested %s run(s) into %s\n' "$count" "$out"
