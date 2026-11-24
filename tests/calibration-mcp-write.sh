#!/usr/bin/env bash
# Calibration phase 3, P3-3: the write side over the stdio MCP server (lib/mcp/calibration-write.js): the use ticket in e3d_get_skill, e3d_skill_report_use,
# e3d_skill_report_outcome and e3d_skill_delete_outcome behind an MCP elicitation, the tier rule inside the store's lock, the unconfirmed switch (D3).
# No model, no network. Library cases (stub client, fake clock and timers) in tests/fixtures/calibration/mcp-write.mjs; this file adds the real server over stdio
# with a stub client (tests/fixtures/calibration/mcp-write-client.mjs), the strict unconfirmed switch, and proof that the flags-off server loads none of this code.
# The full flag-off proof (every byte of initialize and tools/list) is tests/skills-compat.sh; the CLI TTY rule (D12) is in tests/calibration-local.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
FX="$ROOT/tests/fixtures/calibration"

node "$FX/mcp-write.mjs" || fail "library cases"
echo "calibration-mcp-write 1 (library cases): ok"

# 2. over stdio with a stub client: accept writes user_marked with the user's choice; decline, cancel and no elicitation write nothing
client() { local mode="$1"; shift; mkdir -p "$TMP/$mode/home"; node "$FX/mcp-write-client.mjs" "$mode" "$TMP/$mode/store" "$TMP/$mode/home" "$@" > "$TMP/$mode.json" || fail "client $mode"; }
client accept
J="$TMP/accept.json"
jq -e '.use_id | test("^use_[0-9a-f]{32}$")' "$J" >/dev/null || fail "e3d_get_skill returns a use_id"
jq -e '.outcome.structuredContent | .status == "recorded" and .tier == "user_marked"' "$J" >/dev/null || fail "accept records user_marked: $(jq -c .outcome "$J")"
jq -e '.again.structuredContent.status == "unchanged"' "$J" >/dev/null || fail "report_use after the outcome: unchanged"
jq -e '(.elicitations | length) == 1 and (.elicitations[0].mode == "form") and (.elicitations[0].message | test("\"skill.e3d.skeptic\"")) and (.elicitations[0].message | test("\"code-review\""))' "$J" >/dev/null || fail "one form elicitation, quoted data"
jq -e '[.tools[] | select(.name | test("^e3d_skill_(report_use|report_outcome|delete_outcome)$"))] | length == 3 and all(._meta["anthropic/requiresUserInteraction"] == true and .annotations.readOnlyHint == false)' "$J" >/dev/null || fail "write tools on the wire"
jq -e '[.tools[] | select(.name == "e3d_skill_delete_outcome")][0].annotations.destructiveHint == true' "$J" >/dev/null || fail "delete is destructive on the wire"
jq -e '.instructions | test("only after the user confirms in a dialog")' "$J" >/dev/null || fail "instructions mention the confirmation"
U="$(jq -r .use_id "$J")"
[[ "$(wc -l < "$TMP/accept/store/uses.jsonl" | tr -d ' ')" == 1 ]] || fail "one use row"
jq -e --arg u "$U" '.use_id == $u and .mode == "host_chat" and .host.family == "claude-code" and .task_class == "code-review" and .task_class_source == "declared" and .skill.id == "skill.e3d.skeptic"' "$TMP/accept/store/uses.jsonl" >/dev/null || fail "the use row is built from the ledger"
jq -e '.doc.result == "failed" and .doc.tier == "user_marked" and .doc.reported_by == "user"' "$TMP/accept/store/outcomes.jsonl" >/dev/null || fail "the user's choice (failed), not the agent's (worked)"
jq -c '[.outcome, .again, .mine]' "$J" | grep -q "$U" && fail "a persisted use_id came back to the agent"
for mode in decline cancel noelicit; do
  client "$mode"
  [[ ! -e "$TMP/$mode/store" ]] || fail "$mode wrote to the store"
  jq -e '.outcome.isError != true and .outcome.structuredContent.status == "not_recorded"' "$TMP/$mode.json" >/dev/null || fail "$mode: a relayable refusal: $(jq -c .outcome "$TMP/$mode.json")"
done
jq -e '.outcome.structuredContent.reason == "declined" and .again.structuredContent.error.code == "rate_limited"' "$TMP/decline.json" >/dev/null || fail "decline pauses writes"
jq -e '.outcome.structuredContent.reason == "cancelled"' "$TMP/cancel.json" >/dev/null || fail "cancel"
jq -e '.outcome.structuredContent.reason == "no_elicitation" and (.elicitations | length) == 0' "$TMP/noelicit.json" >/dev/null || fail "no elicitation"
# the unconfirmed switch (D3): host_reported, from the agent's result
client noelicit E3D_CALIBRATION_MCP_UNCONFIRMED=1; mv "$TMP/noelicit.json" "$TMP/unconfirmed.json"
jq -e '.outcome.structuredContent | .status == "recorded" and .tier == "host_reported"' "$TMP/unconfirmed.json" >/dev/null || fail "unconfirmed: host_reported"
jq -e '.doc.result == "worked" and .doc.tier == "host_reported" and .doc.reported_by == "host"' "$TMP/noelicit/store/outcomes.jsonl" >/dev/null || fail "unconfirmed row"
echo "calibration-mcp-write 2 (stdio round trip with a stub client): ok"

# 3. E3D_CALIBRATION_MCP_UNCONFIRMED is strict when the tools are on, and not even read when they are off
for v in 2 yes true 01 " 1"; do
  rc=0; env -i PATH="$PATH" HOME="$TMP/home" E3D_MCP_SKILLS=1 E3D_CALIBRATION_V1=1 E3D_CALIBRATION_MCP=1 "E3D_CALIBRATION_MCP_UNCONFIRMED=$v" "$ROOT/bin/e3d-mcp" </dev/null >"$TMP/o" 2>"$TMP/e" || rc=$?
  [[ $rc -eq 2 ]] || fail "E3D_CALIBRATION_MCP_UNCONFIRMED='$v' must exit 2, got $rc"; grep -q 'E3D_CALIBRATION_MCP_UNCONFIRMED must be unset, 0 or 1' "$TMP/e" || fail "message"; [[ ! -s "$TMP/o" ]] || fail "nothing on stdout"
done
rc=0; env -i PATH="$PATH" HOME="$TMP/home" E3D_MCP_SKILLS=1 E3D_CALIBRATION_MCP_UNCONFIRMED=junk "$ROOT/bin/e3d-mcp" </dev/null >/dev/null 2>"$TMP/e" || rc=$?
[[ $rc -eq 0 ]] || fail "with the calibration tools off the switch is not read (got exit $rc: $(cat "$TMP/e"))"
echo "calibration-mcp-write 3 (strict unconfirmed switch): ok"

# 4. with the flags off (any partial set) none of the calibration code is loaded; with all three it is
loaded() { # loaded <env...> -> the module URLs the server resolved while answering initialize
  local log="$TMP/load.$RANDOM"; : > "$log"
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
    | env -i PATH="$PATH" HOME="$TMP/home" E3D_MCP_STATE_DIR="$TMP/state" NODE_OPTIONS="--import=$FX/load-log.mjs" E3D_TEST_LOAD_LOG="$log" "$@" "$ROOT/bin/e3d-mcp" >/dev/null 2>&1 || true
  cat "$log"
}
CODE='lib/mcp/calibration-write\.js|lib/mcp/calibration-read\.js|lib/calibration/'
for combo in "" "E3D_MCP_SKILLS=1" "E3D_CALIBRATION_V1=1" "E3D_CALIBRATION_MCP=1" "E3D_MCP_SKILLS=1 E3D_CALIBRATION_V1=1" "E3D_MCP_SKILLS=1 E3D_CALIBRATION_MCP=1" "E3D_CALIBRATION_V1=1 E3D_CALIBRATION_MCP=1"; do
  # shellcheck disable=SC2086
  out="$(loaded $combo)"; [[ -n "$out" ]] || fail "the load log is empty for [$combo] (is the hook working?)"
  ! grep -Eq "$CODE" <<<"$out" || fail "calibration code loaded with only [$combo]: $(grep -E "$CODE" <<<"$out" | tr '\n' ' ')"
done
out="$(loaded E3D_MCP_SKILLS=1 E3D_CALIBRATION_V1=1 E3D_CALIBRATION_MCP=1)"
grep -q 'lib/mcp/calibration-write\.js' <<<"$out" && grep -q 'lib/calibration/mcp-ledger\.mjs' <<<"$out" || fail "with all three flags the write side is loaded (the check above is meaningful)"
echo "calibration-mcp-write 4 (flags off: none of the code is loaded): ok"
echo "calibration-mcp-write: PASS"
