#!/usr/bin/env bash

# Build the disposable provenance graph as a JSONL stream from an event ledger.
provenance_build_graph() {
  local kind="$1" workspace="$2" events_file="$3"
  [[ -f "$events_file" ]] || return 0
  jq -R -s -cS --arg kind "$kind" --arg self_repo "$workspace" --arg source "${events_file#"$workspace/"}" '
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
  ' "$events_file"
}

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
    local empty_manifest_file
    empty_manifest_file="$out_dir/$(basename "$out_file" .jsonl).manifest.json"
    jq -n -cS '{
      nodes: 0, edges: 0, nodes_by_type: {}, edges_by_relation: {},
      orphan_nodes: 0, max_degree: null, graph_size_bytes: 0,
      source_events_count: 0, graph_events_ratio: null
    }' > "$empty_manifest_file"
    printf '%s\n' "$out_file"
    printf '%s\n' "$empty_manifest_file"
    return 0
  fi

  if ! provenance_build_graph "$kind" "$workspace" "$events_file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$out_file"

  local manifest_file manifest_tmp
  manifest_file="$out_dir/$(basename "$out_file" .jsonl).manifest.json"
  if [[ "$manifest_file" == "$events_file" || "$manifest_file" == "$ideas_dir"/* ]]; then
    ideas_die "provenance manifest must not overwrite the idea ledger: $manifest_file"
    return 1
  fi
  manifest_tmp="$(mktemp "$out_dir/.provenance.manifest.json.XXXXXX")"
  if ! provenance_manifest_json "$out_file" "$events_file" > "$manifest_tmp"; then
    rm -f "$manifest_tmp"
    return 1
  fi
  mv "$manifest_tmp" "$manifest_file"

  printf '%s\n' "$out_file"
  printf '%s\n' "$manifest_file"
}

# Engineering telemetry over an already-written provenance export: counts,
# a degree/orphan check, and a size ratio against the source ledger. Fully
# derived from provenance.jsonl + events.jsonl -- never a second source of
# truth, never read by any other e3d-pilot command as an input, safe to
# regenerate any time provenance_export_repo runs.
provenance_manifest_json() {
  local provenance_file="$1" events_file="$2" graph_size_bytes source_events_count
  graph_size_bytes="$(wc -c < "$provenance_file" | tr -d ' ')"
  source_events_count="$(wc -l < "$events_file" | tr -d ' ')"
  jq -n -cS \
    --slurpfile entries "$provenance_file" \
    --argjson graph_size_bytes "$graph_size_bytes" \
    --argjson source_events_count "$source_events_count" '
    ($entries) as $entries
    | ($entries | map(select(.kind == "node"))) as $nodes
    | ($entries | map(select(.kind == "edge"))) as $edges
    | ($edges | map(.from, .to)) as $touched
    | ([$nodes[].node_id] - ($touched | unique)) as $orphans
    | ($touched | group_by(.) | map({key: .[0], count: length})) as $degree_counts
    | (if ($degree_counts | length) > 0 then ($degree_counts | max_by(.count)) else null end) as $max
    | {
        nodes: ($nodes | length),
        edges: ($edges | length),
        nodes_by_type: ($nodes | group_by(.type) | map({key: .[0].type, value: length}) | from_entries),
        edges_by_relation: ($edges | group_by(.relation) | map({key: .[0].relation, value: length}) | from_entries),
        orphan_nodes: ($orphans | length),
        max_degree: (if $max == null then null else {node_id: $max.key, degree: $max.count} end),
        graph_size_bytes: $graph_size_bytes,
        source_events_count: $source_events_count,
        graph_events_ratio: (if $source_events_count > 0
          then ((($nodes | length) + ($edges | length)) / $source_events_count)
          else null end)
      }
  '
}

# Summarize every idea's progress using only the shared derived graph.
provenance_lineage_json() {
  local kind="$1" workspace="$2" events_file graph
  workspace="$(ideas_canonical_path "$workspace")" || return 1
  events_file="$(ideas_events_file "$kind" "$workspace")" || return 1
  if [[ ! -f "$events_file" ]]; then
    jq -n -cS '[]'
    return 0
  fi
  ideas_validate_stream "$events_file" || return 1
  graph="$(provenance_build_graph "$kind" "$workspace" "$events_file")" || return 1

  jq -s -cS '
    [.[] | select(.kind == "node" and .type == "idea")] as $ideas
    | [.[] | select(.kind == "edge")] as $edges
    | [
        $ideas[] as $idea
        | ($idea.node_id) as $idea_node_id
        | [$edges[]
            | select(.from == $idea_node_id or .to == $idea_node_id)
            | select(.relation == "proposed_by"
                     or .relation == "decision"
                     or (.relation | startswith("decided:"))
                     or .relation == "produced_commit"
                     or .relation == "observed_commit"
                     or .relation == "reported_outcome")
          ] as $relevant
        | ($relevant | any(.relation == "produced_commit")) as $produced
        | ($relevant | any(.relation == "observed_commit")) as $observed
        | ($relevant | any(.relation == "reported_outcome")) as $outcome
        | ($relevant | any(.relation == "decision" or (.relation | startswith("decided:")))) as $decision
        | ($relevant | any(.relation == "decided:idea_rejected")) as $rejected
        | {
            idea_id: $idea.external_id,
            title: $idea.label,
            has_produced_commit: $produced,
            has_observed_commit: $observed,
            has_outcome: $outcome,
            status_summary: (
              if $rejected then "rejected"
              elif $produced then "shipped"
              elif $observed then "shipped_externally"
              elif $decision then "in_progress"
              else "no_activity"
              end
            ),
            evidence: ($relevant | map(.event_id) | unique)
          }
      ]
    | sort_by(.idea_id)
  ' <<<"$graph"
}

provenance_lineage_render() {
  local lineage_json="$1"
  jq -r '
    if length == 0 then "No ideas found."
    else .[] |
      .idea_id + "\t" + .status_summary
      + "\tproduced=" + (.has_produced_commit | tostring)
      + " observed=" + (.has_observed_commit | tostring)
      + " outcome=" + (.has_outcome | tostring)
      + "\ttitle=" + .title
      + "\tevidence=" + (.evidence | join(","))
    end
  ' <<<"$lineage_json"
}

provenance_query_lineage() {
  local kind="$1" workspace="$2" json_flag="${3:-0}" lineage_json
  lineage_json="$(provenance_lineage_json "$kind" "$workspace")" || return 1
  if [[ "$json_flag" == "1" ]]; then
    printf '%s\n' "$lineage_json"
  else
    provenance_lineage_render "$lineage_json"
  fi
}

# Find ideas with repeated changes-requested decisions using the shared graph.
provenance_reversals_json() {
  local kind="$1" workspace="$2" events_file graph
  workspace="$(ideas_canonical_path "$workspace")" || return 1
  events_file="$(ideas_events_file "$kind" "$workspace")" || return 1
  if [[ ! -f "$events_file" ]]; then
    jq -n -cS '[]'
    return 0
  fi
  ideas_validate_stream "$events_file" || return 1
  graph="$(provenance_build_graph "$kind" "$workspace" "$events_file")" || return 1

  jq -s -cS '
    [.[] | select(.kind == "node" and .type == "idea")] as $ideas
    | [.[] | select(.kind == "edge")] as $edges
    | def final_status($idea_node_id):
        [$edges[]
         | select(.from == $idea_node_id or .to == $idea_node_id)
         | select((.relation | startswith("decided:"))
                  or .relation == "failed"
                  or .relation == "produced_commit"
                  or .relation == "observed_commit"
                  or .relation == "reported_outcome")]
        | sort_by(.timestamp, .event_id, .edge_id)
        | last
        | if . == null then null
          elif .relation | startswith("decided:") then .relation | ltrimstr("decided:")
          elif .relation == "failed" then "implementation_failed"
          elif .relation == "produced_commit" then "shipped"
          elif .relation == "observed_commit" then "shipped_externally"
          else "outcome_recorded"
          end;
    [
      $ideas[] as $idea
      | [$edges[]
         | select(.to == $idea.node_id and .relation == "decided:changes_requested")
        ] as $requests
      | select(($requests | length) >= 2)
      | {
          idea_id: $idea.external_id,
          title: $idea.label,
          changes_requested_count: ($requests | length),
          event_ids: ($requests | sort_by(.timestamp, .event_id) | map(.event_id)),
          final_status: final_status($idea.node_id)
        }
    ]
    | sort_by(.idea_id)
  ' <<<"$graph"
}

provenance_reversals_render() {
  local reversals_json="$1"
  jq -r '
    if length == 0 then "No decision reversals found."
    else .[] |
      .idea_id + "\tchanges_requested=" + (.changes_requested_count | tostring)
      + "\tfinal_status=" + (.final_status // "-")
      + "\ttitle=" + .title
      + "\tevent_ids=" + (.event_ids | join(","))
    end
  ' <<<"$reversals_json"
}

provenance_query_reversals() {
  local kind="$1" workspace="$2" json_flag="${3:-0}" reversals_json
  reversals_json="$(provenance_reversals_json "$kind" "$workspace")" || return 1
  if [[ "$json_flag" == "1" ]]; then
    printf '%s\n' "$reversals_json"
  else
    provenance_reversals_render "$reversals_json"
  fi
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

# Aggregate the existing per-idea trace for every idea carrying a failed edge.
# Keeping the trace object intact preserves its nearest-prior-context semantics
# and exposes the surrounding decisions, findings, commits, and outcomes.
provenance_failures_json() {
  local kind="$1" workspace="$2" events_file graph failed_ideas idea_id title trace_json
  workspace="$(ideas_canonical_path "$workspace")" || return 1
  events_file="$(ideas_events_file "$kind" "$workspace")" || return 1
  if [[ ! -f "$events_file" ]]; then
    jq -n -cS '[]'
    return 0
  fi
  ideas_validate_stream "$events_file" || return 1
  graph="$(provenance_build_graph "$kind" "$workspace" "$events_file")" || return 1
  failed_ideas="$(jq -s -cS '
    [.[] | select(.kind == "node" and .type == "idea")] as $ideas
    | [.[] | select(.kind == "edge" and .relation == "failed") | .from] | unique as $failed
    | [$ideas[] | select(.node_id as $id | $failed | index($id) != null)
       | {idea_id: .external_id, title: .label}]
    | sort_by(.idea_id)
  ' <<<"$graph")" || return 1

  while IFS= read -r idea_id; do
    [[ -n "$idea_id" ]] || continue
    title="$(jq -r --arg idea_id "$idea_id" '.[] | select(.idea_id == $idea_id) | .title' <<<"$failed_ideas")"
    trace_json="$(provenance_trace_json "$kind" "$workspace" "$idea_id")" || return 1
    jq -cS --arg title "$title" '. + {title: $title}' <<<"$trace_json"
  done < <(jq -r '.[].idea_id' <<<"$failed_ideas") | jq -s -cS 'sort_by(.idea_id)'
}

provenance_failures_render() {
  local failures_json="$1" item
  if [[ "$(jq 'length' <<<"$failures_json")" -eq 0 ]]; then
    printf '%s\n' "No implementation failures found."
    return 0
  fi
  while IFS= read -r item; do
    printf 'Failure neighborhood: %s\n' "$(jq -r '.title' <<<"$item")"
    provenance_trace_render "" "$item"
  done < <(jq -c '.[]' <<<"$failures_json")
}

provenance_query_failures() {
  local kind="$1" workspace="$2" json_flag="${3:-0}" failures_json
  failures_json="$(provenance_failures_json "$kind" "$workspace")" || return 1
  if [[ "$json_flag" == "1" ]]; then
    printf '%s\n' "$failures_json"
  else
    provenance_failures_render "$failures_json"
  fi
}

# Compare a fleet idea's proposed repositories with repositories carrying an
# observed or produced commit. Repo mode deliberately has no proposes_repo
# edges, so its symmetric query returns an empty result.
provenance_cross_repo_json() {
  local kind="$1" workspace="$2" events_file graph
  if [[ "$kind" != "fleet" ]]; then
    jq -n -cS '[]'
    return 0
  fi
  workspace="$(ideas_canonical_path "$workspace")" || return 1
  events_file="$(ideas_events_file "$kind" "$workspace")" || return 1
  if [[ ! -f "$events_file" ]]; then
    jq -n -cS '[]'
    return 0
  fi
  ideas_validate_stream "$events_file" || return 1
  graph="$(provenance_build_graph "$kind" "$workspace" "$events_file")" || return 1

  jq -s -cS '
    . as $entries
    | [$entries[] | select(.kind == "node" and .type == "idea")] as $ideas
    | ([$entries[] | select(.kind == "node" and .type == "repo")
        | {key: .node_id, value: .external_id}] | from_entries) as $repo_by_node
    | ([$entries[] | select(.kind == "node" and .type == "target_commit")
        | {key: .node_id, value: (.external_id | sub("@[^@]+$"; ""))}]
       | from_entries) as $repo_by_commit
    | [$entries[] | select(.kind == "edge")] as $edges
    | [
        $ideas[] as $idea
        | [$edges[]
           | select(.from == $idea.node_id and .relation == "proposes_repo")
          ] as $proposals
        | [$edges[]
           | select(.from == $idea.node_id)
           | select(.relation == "produced_commit" or .relation == "observed_commit")
          ] as $actual_edges
        | select(($actual_edges | length) > 0)
        | ($proposals | map($repo_by_node[.to]) | map(select(. != null)) | unique | sort) as $proposed
        | ($actual_edges | map($repo_by_commit[.to]) | map(select(. != null)) | unique | sort) as $actual
        | {
            idea_id: $idea.external_id,
            title: $idea.label,
            proposed_repos: $proposed,
            actual_repos: $actual,
            matches: ($proposed == $actual),
            evidence: (($proposals + $actual_edges) | map(.event_id) | unique | sort)
          }
      ]
    | sort_by(.idea_id)
  ' <<<"$graph"
}

provenance_cross_repo_render() {
  local cross_repo_json="$1"
  jq -r '
    if length == 0 then "No cross-repo propagation found."
    else .[] |
      .idea_id + "\tmatches=" + (.matches | tostring)
      + "\tproposed=" + (.proposed_repos | join(","))
      + " actual=" + (.actual_repos | join(","))
      + "\ttitle=" + .title
      + "\tevidence=" + (.evidence | join(","))
    end
  ' <<<"$cross_repo_json"
}

provenance_query_cross_repo() {
  local kind="$1" workspace="$2" json_flag="${3:-0}" cross_repo_json
  cross_repo_json="$(provenance_cross_repo_json "$kind" "$workspace")" || return 1
  if [[ "$json_flag" == "1" ]]; then
    printf '%s\n' "$cross_repo_json"
  else
    provenance_cross_repo_render "$cross_repo_json"
  fi
}
