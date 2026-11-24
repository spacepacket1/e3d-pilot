#!/usr/bin/env bash
# Skills Phase 1 compatibility baseline (docs/skills/phase1/compat-baseline.md): what the no-skill and the current expert paths look like today,
# so the skills work can prove it changed neither. Deterministic: no model, no network. The prompt and decision-log goldens live in
# tests/debate-specialists.sh (tests/fixtures/specialists/golden); this file adds the built-in expert identity and the MCP tool surface.
#   bash tests/skills-compat.sh            check
#   node tests/fixtures/skills/snapshot.mjs --write   regenerate expert-baseline.json ON PURPOSE (a reviewed change of expert meaning)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FX="$ROOT/tests/fixtures/skills"
source "$FX/mcp-session.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. built-in expert identity: names, versions, content hashes, lens bytes, tools none, presets
node "$FX/snapshot.mjs" > "$TMP/now.json"
diff -u "$FX/expert-baseline.json" "$TMP/now.json" > "$TMP/d.txt" || { cat "$TMP/d.txt" >&2; fail "built-in experts or presets changed; if on purpose, regenerate expert-baseline.json and say so in the PR"; }
[[ "$(jq '.experts | length' "$FX/expert-baseline.json")" == 10 ]] || fail "expected 10 built-in experts"
[[ "$(jq '[.experts[] | select(.tools != "none")] | length' "$FX/expert-baseline.json")" == 0 ]] || fail "an expert has tools other than none"

# 2. MCP tool surface (names only): the no-flag server and the experts-read server. No tool may mention skills before the skills phases ship.
tools() { # tools <env...>  -> {tool: [input property names]} with a clean environment (no ambient E3D_MCP_*, PILOT_* or key variables)
  local out
  out="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    | mcp_session 2 "$@" | jq -c 'select(.id==2) | [.result.tools[] | {key: .name, value: ((.inputSchema.properties // {}) | keys)}] | from_entries')"
  [[ -n "$out" ]] || fail "e3d-mcp gave no tools/list answer (is node on PATH? config: $*)"
  printf '%s\n' "$out"
}
CAL3=(E3D_MCP_SKILLS=1 E3D_CALIBRATION_V1=1 E3D_CALIBRATION_MCP=1)
jq -n --argjson a "$(tools)" --argjson b "$(tools E3D_MCP_EXPERTS=1)" --argjson c "$(tools E3D_MCP_SKILLS=1)" --argjson d "$(tools "${CAL3[@]}")" '{note: "tool names and their input property names, with every skills/experts flag unset, with E3D_MCP_EXPERTS=1 and with E3D_MCP_SKILLS=1 (clean environment)", default: $a, experts_read: $b, skills_read: $c, skills_calibration_note: "skills_calibration: E3D_MCP_SKILLS=1 E3D_CALIBRATION_V1=1 E3D_CALIBRATION_MCP=1 (calibration phase 3, P3-2 reads and P3-3 writes)", skills_calibration: $d}' > "$TMP/tools.json"

# 2b. the FULL initialize result and tools/list (descriptions, annotations, _meta, output schemas, instructions) for every flag combination of the calibration MCP
# switches (plan-calibration-3-mcp.md section 8, S4). Only the all-three combination may differ from "skills only"; every other entry must stay byte-identical. Regenerate on purpose with: bash tests/skills-compat.sh --write-full
full() { # full <env...> -> {initialize, tools}
  local out
  # the server's version (package.json) is dropped from the capture, so a release bump does not fail this test; stderr is captured whole (an extra line with the flags off is a change)
  local raw; raw="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | MCP_ERR="$TMP/full-err" mcp_session 2 "$@")"
  out="$(printf '%s\n' "$raw" | jq -sc --rawfile err "$TMP/full-err" '{initialize: (map(select(.id==1))[0].result | del(.serverInfo.version)), tools: (map(select(.id==2))[0].result), stderr: ($err | split("\n") | map(select(. != "")))}')"
  [[ "$out" != *'"initialize":null'* && "$out" != *'"tools":null'* ]] || fail "e3d-mcp gave no initialize or tools/list answer (config: $*)"
  printf '%s\n' "$out"
}
S=E3D_MCP_SKILLS=1; C=E3D_CALIBRATION_V1=1; M=E3D_CALIBRATION_MCP=1
jq -n --argjson unset "$(full)" --argjson skills "$(full $S)" --argjson cal "$(full $C)" --argjson mcp "$(full $M)" --argjson skills_cal "$(full $S $C)" --argjson skills_mcp "$(full $S $M)" --argjson cal_mcp "$(full $C $M)" --argjson all "$(full $S $C $M)" \
  '{note: "the full initialize result and tools/list for each combination of E3D_MCP_SKILLS (S), E3D_CALIBRATION_V1 (C) and E3D_CALIBRATION_MCP (M), clean environment, serverInfo.version dropped, stderr included; only S+C+M may differ from S, and E3D_CALIBRATION_MCP=1 without its companions adds one stderr line", unset: $unset, S: $skills, C: $cal, M: $mcp, "S+C": $skills_cal, "S+M": $skills_mcp, "C+M": $cal_mcp, "S+C+M": $all}' | jq -S . > "$TMP/full.json"
if [[ "${1:-}" == "--write-full" ]]; then cp "$TMP/full.json" "$FX/mcp-full-baseline.json"; echo "wrote mcp-full-baseline.json"; exit 0; fi
if [[ "${1:-}" != "--write-tools" ]]; then
  diff -u "$FX/mcp-full-baseline.json" "$TMP/full.json" >&2 || fail "the full MCP initialize/tools-list capture changed"
  jq -e '. as $r | def nostd: del(.stderr); (["C","M","C+M"] | all(. as $k | ($r[$k] | nostd) == ($r.unset | nostd))) and (["S+C","S+M"] | all(. as $k | ($r[$k] | nostd) == ($r.S | nostd))) and ($r.S.tools != $r.unset.tools)' "$TMP/full.json" >/dev/null || fail "a partial flag combination differs from its baseline family (partial flags must add no tool and change no text)"
  # stderr: exactly main's for every combination, except the one documented line when E3D_CALIBRATION_MCP=1 is set without its companions
  jq -e '. as $r | def miss: .stderr[0] | test("^\\[e3d-mcp\\] E3D_CALIBRATION_MCP=1 is set but the calibration tools stay off until "); ($r.C.stderr == $r.unset.stderr) and ($r."S+C".stderr == $r.S.stderr) and ($r."S+C+M".stderr == $r.S.stderr) and ($r.M | miss) and ($r.M.stderr[1:] == $r.unset.stderr) and ($r."C+M" | miss) and ($r."C+M".stderr[1:] == $r.unset.stderr) and ($r."S+M" | miss) and ($r."S+M".stderr[1:] == $r.S.stderr)' "$TMP/full.json" >/dev/null || fail "stderr differs from main's for some flag combination (only the documented 'tools stay off' line may be added, and only with E3D_CALIBRATION_MCP=1)"
  # S+C+M: the five calibration tools appended (P3-2 reads, P3-3 writes); e3d_get_skill gains only task_class, `use`, a description sentence and idempotentHint false (P3-3)
  jq -e '. as $r | def noget: map(select(.name != "e3d_get_skill")); ($r."S+C+M".tools.tools | map(.name)) == ($r.S.tools.tools | map(.name)) + ["e3d_skill_record","e3d_my_calibration","e3d_skill_report_use","e3d_skill_report_outcome","e3d_skill_delete_outcome"] and ($r."S+C+M".tools.tools[:-5] | noget) == ($r.S.tools.tools | noget) and ($r."S+C+M".initialize.instructions | startswith($r.S.initialize.instructions)) and (($r."S+C+M".initialize | del(.instructions)) == ($r.S.initialize | del(.instructions)))' "$TMP/full.json" >/dev/null || fail "S+C+M must add exactly the five calibration tools and the instruction sentences to S, and change no other tool"
  jq -e '. as $r | ($r.S.tools.tools | map(select(.name == "e3d_get_skill"))[0]) as $a | ($r."S+C+M".tools.tools | map(select(.name == "e3d_get_skill"))[0]) as $b | ($b.description | startswith($a.description)) and ($b.inputSchema | del(.properties.task_class)) == $a.inputSchema and ($b.outputSchema | del(.properties.use)) == $a.outputSchema and ($b.annotations | .idempotentHint = true) == $a.annotations and $b.annotations.idempotentHint == false and ($b | del(.description, .inputSchema, .outputSchema, .annotations)) == ($a | del(.description, .inputSchema, .outputSchema, .annotations))' "$TMP/full.json" >/dev/null || fail "with all three flags e3d_get_skill may only gain task_class, use, a description sentence and idempotentHint false"
fi
if [[ "${1:-}" == "--write-tools" ]]; then cp "$TMP/tools.json" "$FX/mcp-tools-baseline.json"; echo "wrote mcp-tools-baseline.json"; exit 0; fi
diff -u "$FX/mcp-tools-baseline.json" "$TMP/tools.json" >&2 || fail "the MCP tool list changed"
jq -e '[(.default | keys[]), (.experts_read | keys[])] | map(select(test("skill"))) | length == 0' "$TMP/tools.json" >/dev/null || fail "a skill tool is listed without E3D_MCP_SKILLS=1"
jq -e '.experts_read | has("e3d_list_experts") and has("e3d_get_expert")' "$TMP/tools.json" >/dev/null || fail "E3D_MCP_EXPERTS=1 must list the two expert tools"
jq -e '.default | (has("e3d_list_experts") | not)' "$TMP/tools.json" >/dev/null || fail "experts tools must be off by default"
jq -e '.skills_read | (keys | map(select(test("skill"))) | sort) == ["e3d_export_skill","e3d_get_skill","e3d_list_skills","e3d_validate_skill"]' "$TMP/tools.json" >/dev/null || fail "E3D_MCP_SKILLS=1 must list exactly the four skill tools"
jq -e '. as $r | ($r.skills_read | with_entries(select(.key | test("skill") | not))) == $r.default' "$TMP/tools.json" >/dev/null || fail "E3D_MCP_SKILLS=1 must add the four skill tools and change nothing else"
CALT='["e3d_my_calibration","e3d_skill_delete_outcome","e3d_skill_record","e3d_skill_report_outcome","e3d_skill_report_use"]'
jq -e --argjson c "$CALT" '. as $r | ($r.skills_calibration | keys | sort) == (($r.skills_read | keys) + $c | sort) and ($r.skills_calibration | with_entries(select(.key as $k | ($c | index($k)) == null)) | .e3d_get_skill -= ["task_class"]) == $r.skills_read and ($r.skills_calibration.e3d_get_skill | index("task_class")) != null' "$TMP/tools.json" >/dev/null || fail "all three calibration flags must add exactly the five calibration tools and task_class on e3d_get_skill"
echo "skills-compat: PASS"
