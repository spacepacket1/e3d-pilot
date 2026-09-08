#!/usr/bin/env bash

# Derive the provenance graph from the repository idea event ledger.
# The graph is disposable output: events.jsonl remains the only source of truth.
provenance_export_repo() {
  local kind="$1" workspace="$2" out_file="${3:-}" events_file ideas_dir workspace_dir out_dir out_name tmp
  workspace="$(ideas_canonical_path "$workspace")" || return 1
  events_file="$(ideas_events_file "$kind" "$workspace")" || return 1
  ideas_dir="$(ideas_snapshots_dir "$kind" "$workspace")" || return 1
  workspace_dir="$(ideas_workspace_dir "$kind" "$workspace")" || return 1
  [[ -n "$out_file" ]] || out_file="$workspace_dir/provenance.jsonl"

  out_dir="$(dirname "$out_file")"
  mkdir -p "$out_dir"
  out_dir="$(cd "$out_dir" && pwd -P)"
  out_name="$(basename "$out_file")"
  out_file="$out_dir/$out_name"

  if [[ "$out_file" == "$events_file" || "$out_file" == "$ideas_dir"/* ]]; then
    ideas_die "provenance output must not overwrite the idea ledger: $out_file"
    return 1
  fi

  if [[ -f "$events_file" ]]; then
    ideas_validate_stream "$events_file" || return 1
  fi

  tmp="$(mktemp "$out_dir/.provenance.jsonl.XXXXXX")"
  if [[ ! -f "$events_file" ]]; then
    mv "$tmp" "$out_file"
    printf '%s\n' "$out_file"
    return 0
  fi

  if ! jq -R -s -cS --arg kind "$kind" --arg self_repo "$workspace" --arg source "${events_file#"$workspace/"}" '
    def event_data:
      del(.schema_version, .event_id, .idea_id, .event, .timestamp, .actor);
    def normalize_repo($r):
      if $kind == "repo" and $r == $self_repo then "." else ($r | split("/") | last) end;
    def idea_node_id($id): "idea:" + $id;
    def actor_node_id($actor): "actor:" + $actor;
    def model_node_id($model): "model:" + $model;
    def repo_node_id($repo): "repo:" + $repo;
    def target_commit_node_id($repo; $sha): "target_commit:" + $repo + "@" + $sha;
    def event_targets:
      [(.targets // [])[], (.observations // [])[], (.outcome.targets // [])[]];
    def target_commit:
      . as $target
      | ($target.repo // $target.path // null) as $raw_repo
      | ($target.reviewed_head_sha // $target.head_sha // $target.final_pr_head_sha // null) as $sha
      | select($raw_repo | type == "string" and length > 0)
      | select($sha | type == "string" and length > 0)
      | normalize_repo($raw_repo) as $repo
      | {
          repo: $repo,
          sha: $sha,
          node_id: target_commit_node_id($repo; $sha)
        };
    def edge($event; $from; $to; $relation):
      {
        kind: "edge",
        edge_id: ("edge:" + $event.event_id + ":" + $relation),
        from: $from,
        to: $to,
        relation: $relation,
        event_id: $event.event_id,
        timestamp: $event.timestamp,
        source: ($source + "#" + $event.event_id),
        confidence: "observed",
        data: null
      };
    def commit_edge($event; $target; $relation):
      edge($event; idea_node_id($event.idea_id); $target.node_id; $relation)
      | .edge_id = ("edge:" + $event.event_id + ":" + $relation + ":" + $target.node_id);

    [split("\n")[] | select(length > 0) | fromjson] as $events
    | (
        [
          ($events
            | sort_by(.idea_id, .timestamp, .event_id)
            | group_by(.idea_id)[]
            | . as $idea_events
            | ($idea_events | map(select(.event == "idea_proposed"))[0]) as $proposal
            | {
                kind: "node",
                node_id: idea_node_id($idea_events[0].idea_id),
                type: "idea",
                label: ($proposal.candidate.title // $idea_events[0].idea_id),
                external_id: $idea_events[0].idea_id,
                first_seen: ($idea_events | map(.timestamp) | min),
                last_seen: ($idea_events | map(.timestamp) | max)
              }
          ),
          ($events
            | sort_by(.actor, .timestamp, .event_id)
            | group_by(.actor)[]
            | {
                kind: "node",
                node_id: actor_node_id(.[0].actor),
                type: "actor",
                label: .[0].actor,
                external_id: .[0].actor,
                first_seen: (map(.timestamp) | min),
                last_seen: (map(.timestamp) | max)
              }
          ),
          ($events
            | map(select(.event == "idea_proposed")
                  | select(.candidate.provenance.model? | type == "string" and length > 0))
            | sort_by(.candidate.provenance.model, .timestamp, .event_id)
            | group_by(.candidate.provenance.model)[]
            | {
                kind: "node",
                node_id: model_node_id(.[0].candidate.provenance.model),
                type: "model",
                label: .[0].candidate.provenance.model,
                external_id: .[0].candidate.provenance.model,
                first_seen: (map(.timestamp) | min),
                last_seen: (map(.timestamp) | max)
              }
          ),
          (if $kind == "fleet" then
             $events
             | map(select(.event == "idea_proposed") as $event
                   | ($event.candidate.repos // [])[]
                   | select(type == "string" and length > 0)
                   | {repo: normalize_repo(.), timestamp: $event.timestamp})
             | sort_by(.repo, .timestamp)
             | group_by(.repo)[]
             | {
                 kind: "node",
                 node_id: repo_node_id(.[0].repo),
                 type: "repo",
                 label: .[0].repo,
                 external_id: .[0].repo,
                 first_seen: (map(.timestamp) | min),
                 last_seen: (map(.timestamp) | max)
               }
           else empty end
          ),
          ($events
            | map(. as $event
                  | $event
                  | event_targets[]
                  | target_commit
                  | . + {timestamp: $event.timestamp})
            | sort_by(.node_id, .timestamp)
            | group_by(.node_id)[]
            | {
                kind: "node",
                node_id: .[0].node_id,
                type: "target_commit",
                label: (.[0].repo + "@" + .[0].sha),
                external_id: (.[0].repo + "@" + .[0].sha),
                first_seen: (map(.timestamp) | min),
                last_seen: (map(.timestamp) | max)
              }
          )
        ]
        | sort_by(.type, .node_id)
      ) as $nodes
    | (
        [
          $events[] as $event
          | if $event.event == "idea_proposed" then
              edge($event; actor_node_id($event.actor); idea_node_id($event.idea_id); "proposed_by"),
              (if ($event.candidate.provenance.model? | type == "string" and length > 0) then
                 edge($event; idea_node_id($event.idea_id); model_node_id($event.candidate.provenance.model); "proposed_by_model")
               else empty end),
              (if $kind == "fleet" then
                 ($event.candidate.repos // [])
                 | to_entries[]
                 | select(.value | type == "string" and length > 0)
                 | normalize_repo(.value) as $repo
                 | (edge($event; idea_node_id($event.idea_id); repo_node_id($repo); "proposes_repo")
                    | .edge_id += ":" + (.key | tostring) + ":" + repo_node_id($repo))
               else empty end)
            elif $event.event == "note_appended" then
              (edge($event; actor_node_id($event.actor); idea_node_id($event.idea_id);
                    (if $event.kind == "decision" then "decision" else "finding" end))
               | if ($event.evidence_ref? | type == "string" and length > 0)
                 then .data = {evidence_ref: $event.evidence_ref}
                 else . end)
            elif (["implementation_approved", "idea_rejected", "changes_requested", "merge_approved"] | index($event.event)) != null then
              edge($event; actor_node_id($event.actor); idea_node_id($event.idea_id); "decided:" + $event.event)
            elif (["implementation_completed", "merge_completed", "merge_partially_completed"] | index($event.event)) != null then
              ($event
               | event_targets
               | map(target_commit)
               | unique_by(.node_id)[]
               | commit_edge($event; .; "produced_commit"))
            elif $event.event == "forge_sync" then
              ($event
               | event_targets
               | map(target_commit)
               | unique_by(.node_id)[]
               | commit_edge($event; .; "observed_commit"))
            elif $event.event == "implementation_failed" then
              edge($event; idea_node_id($event.idea_id); idea_node_id($event.idea_id); "failed")
            elif $event.event == "outcome_recorded" then
              (edge($event; idea_node_id($event.idea_id); idea_node_id($event.idea_id); "reported_outcome")
               | .data = ($event | event_data))
            else empty end
        ]
        | sort_by(.timestamp, .event_id, .edge_id)
      ) as $edges
    | ($nodes[], $edges[])
  ' "$events_file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  mv "$tmp" "$out_file"
  printf '%s\n' "$out_file"
}

# Re-derive a compact, chronological trace for one idea directly from the
# append-only event ledger. The derived export is intentionally not consulted.
provenance_trace_json() {
  local kind="$1" workspace="$2" idea_id="$3" events_file
  workspace="$(ideas_canonical_path "$workspace")" || return 1
  events_file="$(ideas_events_file "$kind" "$workspace")" || return 1
  [[ -f "$events_file" ]] || {
    ideas_die "idea event ledger not found: $events_file"
    return 1
  }
  ideas_validate_stream "$events_file" || return 1
  if ! jq -e --arg idea_id "$idea_id" 'select(.idea_id == $idea_id)' "$events_file" >/dev/null; then
    ideas_die "idea not found: $idea_id"
    return 1
  fi

  jq -R -s -cS --arg idea_id "$idea_id" --arg kind "$kind" --arg self_repo "$workspace" '
    def event_data:
      del(.schema_version, .event_id, .idea_id, .event, .timestamp, .actor);
    def normalize_repo($r):
      if $kind == "repo" and $r == $self_repo then "." else ($r | split("/") | last) end;
    def event_targets:
      [(.targets // [])[], (.observations // [])[], (.outcome.targets // [])[]];
    def target_commit:
      . as $target
      | ($target.repo // $target.path // null) as $raw_repo
      | ($target.reviewed_head_sha // $target.head_sha // $target.final_pr_head_sha // null) as $sha
      | select($raw_repo | type == "string" and length > 0)
      | select($sha | type == "string" and length > 0)
      | {
          repo: normalize_repo($raw_repo),
          commit: $sha,
          pr: ($target.pr_url // $target.pr_number // null)
        };
    def is_decision:
      . as $event
      | ($event.event == "note_appended" and $event.kind == "decision")
        or (["implementation_approved", "idea_rejected", "changes_requested", "merge_approved"] | index($event.event)) != null;
    def decision_relation:
      if .event == "note_appended" then "decision" else "decided:" + .event end;
    def context_item:
      {
        relation: (if .kind == "decision" then "decision" else "finding" end),
        actor,
        timestamp,
        event_id,
        text: (.text // .note // null)
      }
      + if (.evidence_ref? | type == "string" and length > 0)
        then {evidence_ref: .evidence_ref}
        else {} end;
    def commit_items($event; $relation):
      $event
      | event_targets
      | map(target_commit)
      | unique_by(.repo, .commit)[]
      | . + {
          relation: $relation,
          actor: $event.actor,
          timestamp: $event.timestamp,
          event_id: $event.event_id
        };

    [split("\n")[] | select(length > 0) | fromjson | select(.idea_id == $idea_id)]
    | sort_by(.timestamp, .event_id) as $events
    | [$events[] | select(is_decision)] as $decision_events
    | [$events[] | select(.event == "note_appended" and .kind != "decision")] as $finding_events
    | [
        $events[] as $event
        | select(["implementation_completed", "merge_completed", "merge_partially_completed"] | index($event.event))
        | commit_items($event; "produced_commit")
      ] as $produced
    | ($produced | map(.repo + "@" + .commit) | unique) as $produced_ids
    | [
        $events[] as $event
        | select($event.event == "forge_sync")
        | commit_items($event; "observed_commit")
        | select((.repo + "@" + .commit) as $id | $produced_ids | index($id) == null)
      ] as $observed
    | [
        $events[]
        | select(.event == "implementation_failed") as $failure
        | ([($decision_events + $finding_events)[]
            | select(.timestamp < $failure.timestamp)]
           | sort_by(.timestamp, .event_id)
           | last) as $prior
        | {
            actor: $failure.actor,
            timestamp: $failure.timestamp,
            event_id: $failure.event_id,
            nearest_prior_context: ($prior.event_id // null)
          }
      ] as $failures
    | {
        idea_id: $idea_id,
        proposed: [
          $events[]
          | select(.event == "idea_proposed")
          | {
              actor,
              model: (.candidate.provenance.model // null),
              timestamp,
              event_id
            }
        ],
        decisions: [
          $decision_events[]
          | {
              relation: decision_relation,
              actor,
              timestamp,
              event_id,
              text: (.text // .note // null)
            }
            + if (.evidence_ref? | type == "string" and length > 0)
              then {evidence_ref: .evidence_ref}
              else {} end
        ],
        findings: [$finding_events[] | context_item],
        produced: $produced,
        observed: $observed,
        outcomes: [
          $events[]
          | select(.event == "outcome_recorded")
          | {actor, timestamp, event_id, data: event_data}
        ]
      }
      + if $failures | length > 0 then {failure: $failures} else {} end
  ' "$events_file"
}

provenance_trace_render() {
  local kind="$1" trace_json="$2"
  jq -r '
    def value($v): if $v == null or $v == "" then "-" else ($v | tostring) end;
    def section($name; $lines):
      $name,
      (if $lines | length == 0 then "  (none)"
       else $lines[] | "  " + .
       end),
      "";

    "Idea: " + .idea_id,
    "",
    section("Proposed"; [.proposed[] |
      "actor=" + value(.actor) + " model=" + value(.model) +
      " timestamp=" + .timestamp + " event_id=" + .event_id]),
    section("Decisions"; [.decisions[] |
      "relation=" + .relation + " actor=" + value(.actor) +
      " text=" + value(.text) + " timestamp=" + .timestamp + " event_id=" + .event_id +
      (if has("evidence_ref") then " evidence_ref=" + .evidence_ref else "" end)]),
    section("Findings"; [.findings[] |
      "actor=" + value(.actor) + " text=" + value(.text) +
      " timestamp=" + .timestamp + " event_id=" + .event_id +
      (if has("evidence_ref") then " evidence_ref=" + .evidence_ref else "" end)]),
    section("Produced"; [.produced[] |
      "repo=" + .repo + " commit=" + .commit + " pr=" + value(.pr) +
      " timestamp=" + .timestamp + " event_id=" + .event_id]),
    section("Observed"; [.observed[] |
      "repo=" + .repo + " commit=" + .commit + " pr=" + value(.pr) +
      " timestamp=" + .timestamp + " event_id=" + .event_id]),
    section("Outcome"; [.outcomes[] |
      "data=" + (.data | tojson) + " timestamp=" + .timestamp + " event_id=" + .event_id]),
    (if has("failure") then
       section("Failure"; [.failure[] |
         "event_id=" + .event_id + " actor=" + value(.actor) +
         " timestamp=" + .timestamp +
         " nearest_prior_context=" + value(.nearest_prior_context) +
         "; no invalidation is claimed; this is the nearest preceding entry in time only"])
     else empty end)
  ' <<<"$trace_json"
}

provenance_trace_repo() {
  local kind="$1" workspace="$2" idea_id="$3" json_flag="${4:-0}" trace_json
  trace_json="$(provenance_trace_json "$kind" "$workspace" "$idea_id")" || return 1
  if [[ "$json_flag" == "1" ]]; then
    printf '%s\n' "$trace_json"
  else
    provenance_trace_render "$kind" "$trace_json"
  fi
}
