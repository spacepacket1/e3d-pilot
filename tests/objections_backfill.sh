#!/usr/bin/env bash
# Covers bin/e3d-objections-backfill: it rebuilds per-reviewer objection records from a historical negotiation-log.md
# (same shape the negotiate stage writes now), replaying that a later reviewer sees an earlier reviewer's replacement.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/bin/e3d-objections-backfill"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

draft() { printf '# Spec v%s\n\n## Overview\n\nBuild the thing.\n\n### Requirements\n\n- requirement %s\n' "$1" "$1"; }

repo="$(mktemp -d)"
run="$repo/.e3d-pilot/runs/r1"
mkdir -p "$run"
{
  printf -- '---\nrun_id: r1\n---\n\n# Negotiation Log\n\n'
  printf '## Round 1\n\n### Draft Before Round\n\n```text\n%s```\n\n' "$(draft 1)"$'\n'
  printf '### Reviewer 1: claude\n\nStatus: approved\n\nReason: fine.\n\nRaw Response:\n\n```text\n---STATUS---\nstatus: approved\n```\n\n'
  printf '### Reviewer 2: codex\n\nStatus: revise\n\nReason: missing idempotency.\n\nReplacement Spec:\n\n```spec\n%s\n```\n\nRaw Response:\n\n```text\n---STATUS---\nstatus: revise\n```\n\n' "$(draft 2)"
  printf '## Round 2\n\n### Draft Before Round\n\n```text\n%s\n```\n\n' "$(draft 2)"
  printf '### Reviewer 1: claude\n\nStatus: approved\n\nReason: ok.\n\nRaw Response:\n\n```text\n---STATUS---\nstatus: approved\n```\n\n'
  printf '### Reviewer 2: codex\n\nStatus: approved\n\nReason: ok.\n\nRaw Response:\n\n```text\n---STATUS---\nstatus: approved\n```\n\n'
  printf '## Final Outcome\n\nConverged in round 2.\n'
} > "$run/negotiation-log.md"
draft 2 > "$run/spec-final.md"
out="$run/negotiation-objections.jsonl"

# dry run writes nothing
summary="$(node "$TOOL" --repo "$repo" --dry-run)"
[[ "$summary" == *'"written":1'* ]] || fail "dry run summary: $summary"
[[ ! -f "$out" ]] || fail "dry run must not write"

summary="$(node "$TOOL" --repo "$repo")"
[[ "$summary" == *'"written":1'* && "$summary" == *'"records":4'* ]] || fail "summary: $summary"
[[ "$(wc -l < "$out" | tr -d '[:space:]')" == "4" ]] || fail "expected 4 records"

[[ "$(jq -s 'map(.status) | join(",")' -r "$out")" == "approved,revise,approved,approved" ]] || fail "statuses"
[[ "$(jq -s '[.[] | select(.backfilled)] | length' "$out")" == "4" ]] || fail "backfilled flag"
[[ "$(jq -s '.[1] | .changed and .lines_added == 2 and .lines_removed == 2' "$out")" == "true" ]] || fail "the revise turn's line counts: $(jq -sc '.[1]' "$out")"
[[ "$(jq -s '.[1].survives_in_final' "$out")" == "1" ]] || fail "replacement survives in the final spec"
[[ "$(jq -s '.[2].spec_before_sha == .[1].spec_after_sha' "$out")" == "true" ]] || fail "round 2 saw round 1's replacement"
[[ "$(jq -s 'map(select(.changed)) | length' "$out")" == "1" ]] || fail "only the revise turn changes the draft"

# idempotent: a second run skips; --force rewrites
summary="$(node "$TOOL" --repo "$repo")"
[[ "$summary" == *'"skippedExisting":1'* && "$summary" == *'"written":0'* ]] || fail "second run should skip: $summary"
summary="$(node "$TOOL" --repo "$repo" --force)"
[[ "$summary" == *'"written":1'* ]] || fail "--force should rewrite: $summary"

# a missing --repo value is an error, not "use the current directory"
if (cd "$repo" && node "$TOOL" --repo --force >/dev/null 2>&1); then fail "--repo without a value must be rejected"; fi

# deterministic: a --force rewrite reproduces the same bytes
cp "$out" "$out.first"; node "$TOOL" --repo "$repo" --force >/dev/null
cmp -s "$out" "$out.first" || fail "--force output should be reproducible (recorded_at comes from the log's mtime)"

# a spec that quotes pilot-looking headings must not create fake turns, and reordered lines count as a diff
repo2="$(mktemp -d)"; run2="$repo2/.e3d-pilot/runs/r2"; mkdir -p "$run2"
tricky=$'# Spec\n\nNotes quoting a log:\n\n### Reviewer 9: ghost\n\nStatus: revise\n\nmore text\n\nalpha\nbeta\n'
reordered=$'# Spec\n\nNotes quoting a log:\n\n### Reviewer 9: ghost\n\nStatus: revise\n\nmore text\n\nbeta\nalpha\n'
{
  printf -- '---\nrun_id: r2\n---\n\n# Negotiation Log\n\n'
  printf '## Round 1\n\n### Draft Before Round\n\n```text\n%s```\n\n' "$tricky"
  printf '### Reviewer 1: claude\n\nStatus: revise\n\nReason: reorder.\n\nReplacement Spec:\n\n```spec\n%s```\n\nRaw Response:\n\n```text\n---STATUS---\nstatus: revise\n```\n\n' "$reordered"
  printf '## Final Outcome\n\nNeeds human.\n'
} > "$run2/negotiation-log.md"
printf '%s' "$reordered" > "$run2/spec-final.md"
summary="$(node "$TOOL" --repo "$repo2")"
out2="$run2/negotiation-objections.jsonl"
[[ "$(wc -l < "$out2" | tr -d '[:space:]')" == "1" ]] || fail "the quoted heading created a fake turn: $summary / $(cat "$out2")"
[[ "$(jq -s '.[0] | .provider == "claude" and .changed and .lines_added > 0 and .lines_removed > 0' "$out2")" == "true" ]] || fail "a pure reorder must count as added/removed lines like diff(1): $(cat "$out2")"

# the original log is never modified
grep -q "Converged in round 2." "$run/negotiation-log.md" || fail "log was modified"

printf 'objections_backfill: all checks passed\n'
