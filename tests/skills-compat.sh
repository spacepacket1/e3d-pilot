#!/usr/bin/env bash
# Skills Phase 1 compatibility baseline (docs/skills/phase1/compat-baseline.md): what the no-skill and the current expert paths look like today,
# so the skills work can prove it changed neither. Deterministic: no model, no network. The prompt and decision-log goldens live in
# tests/debate-specialists.sh (tests/fixtures/specialists/golden); this file adds the built-in expert identity and the MCP tool surface.
#   bash tests/skills-compat.sh            check
#   node tests/fixtures/skills/snapshot.mjs --write   regenerate expert-baseline.json ON PURPOSE (a reviewed change of expert meaning)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FX="$ROOT/tests/fixtures/skills"
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
  out="$({ printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'; sleep 2; } \
    | env -i PATH="$PATH" HOME="$TMP" E3D_MCP_STATE_DIR="$TMP/state" "$@" "$ROOT/bin/e3d-mcp" 2>/dev/null | jq -c 'select(.id==2) | [.result.tools[] | {key: .name, value: ((.inputSchema.properties // {}) | keys)}] | from_entries')"
  [[ -n "$out" ]] || fail "e3d-mcp gave no tools/list answer (is node on PATH? config: $*)"
  printf '%s\n' "$out"
}
CAL3=(E3D_MCP_SKILLS=1 E3D_CALIBRATION_V1=1 E3D_CALIBRATION_MCP=1)
jq -n --argjson a "$(tools)" --argjson b "$(tools E3D_MCP_EXPERTS=1)" --argjson c "$(tools E3D_MCP_SKILLS=1)" --argjson d "$(tools "${CAL3[@]}")" '{note: "tool names and their input property names, with every skills/experts flag unset, with E3D_MCP_EXPERTS=1 and with E3D_MCP_SKILLS=1 (clean environment)", default: $a, experts_read: $b, skills_read: $c, skills_calibration_note: "skills_calibration: E3D_MCP_SKILLS=1 E3D_CALIBRATION_V1=1 E3D_CALIBRATION_MCP=1 (calibration phase 3, P3-2)", skills_calibration: $d}' > "$TMP/tools.json"

# 2b. the FULL initialize result and tools/list (descriptions, annotations, _meta, output schemas, instructions) for every flag combination of the calibration MCP
# switches (plan-calibration-3-mcp.md section 8, S4). Only the all-three combination may differ from "nothing set"; every other entry must stay byte-identical.
full() { # full <env...> -> {initialize, tools}
  local out
  out="$({ printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'; sleep 2; } \
    | env -i PATH="$PATH" HOME="$TMP" E3D_MCP_STATE_DIR="$TMP/state" "$@" "$ROOT/bin/e3d-mcp" 2>/dev/null | jq -sc '{initialize: (map(select(.id==1))[0].result), tools: (map(select(.id==2))[0].result)}')"
  [[ "$out" != *'"initialize":null'* && "$out" != *'"tools":null'* ]] || fail "e3d-mcp gave no initialize or tools/list answer (config: $*)"
  printf '%s\n' "$out"
}
S=E3D_MCP_SKILLS=1; C=E3D_CALIBRATION_V1=1; M=E3D_CALIBRATION_MCP=1
jq -n --argjson unset "$(full)" --argjson skills "$(full $S)" --argjson cal "$(full $C)" --argjson mcp "$(full $M)" --argjson skills_cal "$(full $S $C)" --argjson skills_mcp "$(full $S $M)" --argjson cal_mcp "$(full $C $M)" --argjson all "$(full $S $C $M)" \
  '{note: "the full initialize result and tools/list for each combination of E3D_MCP_SKILLS (S), E3D_CALIBRATION_V1 (C) and E3D_CALIBRATION_MCP (M), clean environment; only S+C+M may differ from unset and from S", unset: $unset, S: $skills, C: $cal, M: $mcp, "S+C": $skills_cal, "S+M": $skills_mcp, "C+M": $cal_mcp, "S+C+M": $all}' | jq -S . > "$TMP/full.json"
if [[ "${1:-}" == "--write-full" ]]; then cp "$TMP/full.json" "$FX/mcp-full-baseline.json"; echo "wrote mcp-full-baseline.json"; exit 0; fi
if [[ "${1:-}" != "--write-tools" ]]; then
  diff -u "$FX/mcp-full-baseline.json" "$TMP/full.json" >&2 || fail "the full MCP initialize/tools-list capture changed"
  jq -e '. as $r | (["C","M","C+M"] | all(. as $k | $r[$k] == $r.unset)) and (["S+C","S+M"] | all(. as $k | $r[$k] == $r.S)) and ($r.S.tools != $r.unset.tools)' "$TMP/full.json" >/dev/null || fail "a partial flag combination differs from its baseline family (partial flags must add no tool and change no text)"
  jq -e '. as $r | ($r."S+C+M".tools.tools | map(.name)) == ($r.S.tools.tools | map(.name)) + ["e3d_skill_record","e3d_my_calibration"] and ($r."S+C+M".tools.tools[:-2]) == $r.S.tools.tools and ($r."S+C+M".initialize.instructions | startswith($r.S.initialize.instructions)) and (($r."S+C+M".initialize | del(.instructions)) == ($r.S.initialize | del(.instructions)))' "$TMP/full.json" >/dev/null || fail "S+C+M must add exactly the two calibration read tools and one sentence of instructions to S"
fi
if [[ "${1:-}" == "--write-tools" ]]; then cp "$TMP/tools.json" "$FX/mcp-tools-baseline.json"; echo "wrote mcp-tools-baseline.json"; exit 0; fi
diff -u "$FX/mcp-tools-baseline.json" "$TMP/tools.json" >&2 || fail "the MCP tool list changed"
jq -e '[(.default | keys[]), (.experts_read | keys[])] | map(select(test("skill"))) | length == 0' "$TMP/tools.json" >/dev/null || fail "a skill tool is listed without E3D_MCP_SKILLS=1"
jq -e '.experts_read | has("e3d_list_experts") and has("e3d_get_expert")' "$TMP/tools.json" >/dev/null || fail "E3D_MCP_EXPERTS=1 must list the two expert tools"
jq -e '.default | (has("e3d_list_experts") | not)' "$TMP/tools.json" >/dev/null || fail "experts tools must be off by default"
jq -e '.skills_read | (keys | map(select(test("skill"))) | sort) == ["e3d_export_skill","e3d_get_skill","e3d_list_skills","e3d_validate_skill"]' "$TMP/tools.json" >/dev/null || fail "E3D_MCP_SKILLS=1 must list exactly the four skill tools"
jq -e '. as $r | ($r.skills_read | with_entries(select(.key | test("skill") | not))) == $r.default' "$TMP/tools.json" >/dev/null || fail "E3D_MCP_SKILLS=1 must add the four skill tools and change nothing else"
jq -e '. as $r | ($r.skills_calibration | keys | sort) == (($r.skills_read | keys) + ["e3d_my_calibration","e3d_skill_record"] | sort) and ($r.skills_calibration | with_entries(select(.key | test("e3d_skill_record|e3d_my_calibration") | not))) == $r.skills_read' "$TMP/tools.json" >/dev/null || fail "all three calibration flags must add exactly e3d_skill_record and e3d_my_calibration to the skills tools"
echo "skills-compat: PASS"
