#!/usr/bin/env bash
# Structured record of every reviewer turn in the negotiate stage, for the adversarial-reviewer dataset
# (see the RFC debate 2026-10-17-qwen-adversarial-reviewer-rfc). One JSON line per turn is appended to
# <run_dir>/negotiation-objections.jsonl:
#   run_id, invocation (UTC start of this negotiate invocation), round, reviewer_index, provider, status, reason,
#   spec_before_sha / spec_after_sha (the draft the reviewer saw / the draft after applying its replacement),
#   changed, lines_added, lines_removed.
# A "revise" turn applies its replacement spec immediately, so later reviewers in the round see it: there is no
# separate adopted/rejected choice to record. Whether a change survives to spec-final.md is derived offline from
# negotiation-log.md, which keeps every replacement spec. Recording must never fail the stage.

negotiate_record_objection() {
  local run_dir="$1" run_id="$2" invocation="$3" round="$4" index="$5" provider="$6" status="$7" reason="$8"
  local before_file="$9" after_file="${10}"
  local before_sha after_sha added removed
  before_sha="$(ideas_sha256 < "$before_file" 2>/dev/null)" || return 0
  after_sha="$(ideas_sha256 < "$after_file" 2>/dev/null)" || return 0
  added="$(diff "$before_file" "$after_file" 2>/dev/null | grep -c '^>' || true)"
  removed="$(diff "$before_file" "$after_file" 2>/dev/null | grep -c '^<' || true)"
  jq -nc \
    --arg run_id "$run_id" --arg invocation "$invocation" --argjson round "$round" --argjson index "$index" \
    --arg provider "$provider" --arg status "$status" --arg reason "${reason:0:1000}" \
    --arg before "$before_sha" --arg after "$after_sha" \
    --argjson added "${added:-0}" --argjson removed "${removed:-0}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema_version: "1", run_id: $run_id, invocation: $invocation, round: $round, reviewer_index: $index,
      provider: $provider, status: $status, reason: $reason, spec_before_sha: $before, spec_after_sha: $after,
      changed: ($before != $after), lines_added: $added, lines_removed: $removed, recorded_at: $at}' \
    >> "$run_dir/negotiation-objections.jsonl" 2>/dev/null || true
}

# One finding on the run's linked idea summarizing this invocation, then remove the per-turn scratch file.
negotiate_objections_signal() {
  local repo="$1" run_id="$2" run_dir="$3" invocation="$4" counts turns revised
  rm -f "$run_dir/.negotiation-turn-before.$$.md" 2>/dev/null || true
  [[ -f "$run_dir/negotiation-objections.jsonl" ]] || return 0
  counts="$(jq -s --arg inv "$invocation" '[.[] | select(.invocation == $inv)] | [length, (map(select(.status == "revise")) | length)] | @tsv' -r \
    "$run_dir/negotiation-objections.jsonl" 2>/dev/null)" || return 0
  IFS=$'\t' read -r turns revised <<<"$counts"
  record_pipeline_signal "$repo" "$run_id" "pipeline_signal: negotiate_objections stage=negotiate run_id=$run_id turns=${turns:-0} revised=${revised:-0} file=.e3d-pilot/runs/$run_id/negotiation-objections.jsonl"
}
