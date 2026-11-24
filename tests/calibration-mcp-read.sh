#!/usr/bin/env bash
# Calibration phase 3, P3-2: the read tools e3d_skill_record and e3d_my_calibration over the stdio MCP server (lib/mcp/calibration-config.js, lib/mcp/calibration-read.js).
# No model, no network. Library cases in tests/fixtures/calibration/mcp-read.mjs; this file adds the real server: strict flags (exit 2), tools absent unless all
# three flags are set, HTTP refused, and a stdio round trip against a temp store. The full flag-off proof (every byte of initialize and tools/list) is tests/skills-compat.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

node "$ROOT/tests/fixtures/calibration/mcp-read.mjs" || fail "library cases"
echo "calibration-mcp-read 1 (library cases): ok"

STORE="$TMP/store"; node "$ROOT/tests/fixtures/calibration/mcp-read.mjs" --make-store "$STORE"
# serve <extra requests (json lines)> -- <env...>: a clean-environment stdio session; prints every response line
serve() {
  local reqs="$1"; shift
  { printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    [[ -n "$reqs" ]] && printf '%s\n' "$reqs"; sleep 2; } \
    | env -i PATH="$PATH" HOME="$TMP/home" E3D_MCP_STATE_DIR="$TMP/state" E3D_CALIBRATION_DIR="$STORE" "$@" "$ROOT/bin/e3d-mcp" 2>"$TMP/stderr"
}
names() { serve "" "$@" | jq -r 'select(.id==2) | .result.tools[].name' | sort | tr '\n' ' '; }
CAL='e3d_my_calibration e3d_skill_record'
S=E3D_MCP_SKILLS=1; C=E3D_CALIBRATION_V1=1; M=E3D_CALIBRATION_MCP=1

# 2. strict flag: anything but unset/empty/0/1 exits 2 at startup, before any output
for v in 2 yes true on 01 -1 1x " 1"; do
  rc=0; env -i PATH="$PATH" HOME="$TMP/home" "$S" "$C" "E3D_CALIBRATION_MCP=$v" "$ROOT/bin/e3d-mcp" </dev/null >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
  [[ $rc -eq 2 ]] || fail "E3D_CALIBRATION_MCP='$v' must exit 2, got $rc"; grep -q 'E3D_CALIBRATION_MCP must be unset, 0 or 1' "$TMP/stderr" || fail "message for '$v'"; [[ ! -s "$TMP/stdout" ]] || fail "nothing on stdout when refusing"
done
rc=0; env -i PATH="$PATH" HOME="$TMP/home" "$S" E3D_CALIBRATION_V1=yes "$M" "$ROOT/bin/e3d-mcp" </dev/null >/dev/null 2>"$TMP/stderr" || rc=$?
[[ $rc -eq 2 ]] || fail "E3D_CALIBRATION_MCP=1 with an invalid E3D_CALIBRATION_V1 must exit 2, got $rc"; grep -q 'E3D_CALIBRATION_V1 must be 0 or 1' "$TMP/stderr" || fail "V1 message"
[[ -n "$(names E3D_CALIBRATION_V1=yes)" ]] || fail "an invalid E3D_CALIBRATION_V1 alone must not stop the server (flag off behaves as before)"
for v in "" 0; do [[ "$(names "$S" "$C" "E3D_CALIBRATION_MCP=$v")" == "$(names "$S" "$C")" ]] || fail "E3D_CALIBRATION_MCP='$v' must equal unset"; done
echo "calibration-mcp-read 2 (strict flag, exit 2): ok"

# 3. the tools exist only with all three flags; a partial set is never an error and adds nothing
for combo in "" "$S" "$C" "$M" "$S $C" "$S $M" "$C $M"; do
  # shellcheck disable=SC2086
  n="$(names $combo)"; [[ -n "$n" ]] || fail "server did not answer with [$combo]"
  [[ "$n" != *e3d_skill_record* && "$n" != *e3d_my_calibration* ]] || fail "calibration tool listed with only [$combo]"
done
n="$(names "$S" "$C" "$M")"; [[ "$n" == *"e3d_skill_record"* && "$n" == *"e3d_my_calibration"* ]] || fail "all three flags must list both tools"
serve "" "$S" "$C" "$M" | jq -e 'select(.id==2) | .result.tools | map(select(.name=="e3d_skill_record" or .name=="e3d_my_calibration")) | length == 2 and all(.annotations.readOnlyHint == true and .annotations.idempotentHint == true and .annotations.openWorldHint == false and .annotations.destructiveHint == false)' >/dev/null || fail "annotations on the wire"
serve "" "$S" "$C" "$M" | jq -e 'select(.id==1) | .result.instructions | test("e3d_skill_record")' >/dev/null || fail "instructions mention the read tools"
env -i PATH="$PATH" HOME="$TMP/home" "$S" "$M" "$ROOT/bin/e3d-mcp" </dev/null >/dev/null 2>"$TMP/stderr" || true
grep -q 'E3D_CALIBRATION_V1=1 are also set\|E3D_CALIBRATION_V1=1 is also set' "$TMP/stderr" || fail "a partial set logs what is missing"
echo "calibration-mcp-read 3 (tools exist only with all three flags): ok"

# 4. HTTP is refused by this switch itself (checked WITHOUT E3D_MCP_SKILLS, whose own HTTP refusal would otherwise answer first). A server that wrongly starts is killed after 8 s.
http() { # http <env...>: sets HRC and the stderr file
  env -i PATH="$PATH" HOME="$TMP/home" E3D_PORT=0 "$@" "$ROOT/bin/e3d-mcp" --http </dev/null >/dev/null 2>"$TMP/stderr" & local pid=$! i
  for i in $(seq 1 80); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; HRC=still-running; else HRC=0; wait "$pid" || HRC=$?; fi
}
http "$C" "$M"; [[ "$HRC" == 2 ]] || fail "E3D_CALIBRATION_MCP=1 with E3D_CALIBRATION_V1=1 on the HTTP server must exit 2 itself, got $HRC"
grep -q 'E3D_CALIBRATION_MCP=1 is for the local stdio server only' "$TMP/stderr" || fail "HTTP refusal message: $(cat "$TMP/stderr")"
http "$M"; [[ "$HRC" == 2 ]] || fail "E3D_CALIBRATION_MCP=1 alone on the HTTP server must exit 2, got $HRC"
http "$S" "$C" "$M"; [[ "$HRC" == 2 ]] || fail "all three flags on the HTTP server must exit 2, got $HRC"
echo "calibration-mcp-read 4 (refuses HTTP): ok"

# 5. a stdio round trip: the answers, the principal check, bad input
CALL() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$1" "$2" "$3"; }
REQS="$(CALL 10 e3d_my_calibration '{}')"$'\n'"$(CALL 11 e3d_skill_record '{"skill":"skeptic"}')"$'\n'"$(CALL 12 e3d_skill_record '{"skill":"premortem"}')"$'\n'"$(CALL 13 e3d_skill_record '{"skill":"skeptic","extra":1}')"$'\n'"$(CALL 14 e3d_skill_record '{"skill":"nothing-here"}')"
serve "$REQS" "$S" "$C" "$M" > "$TMP/out.jsonl"
r() { jq -c "select(.id==$1) | .result" "$TMP/out.jsonl"; }
jq -e '.isError != true and (.structuredContent.skills | length == 3)' <<<"$(r 10)" >/dev/null || fail "e3d_my_calibration over stdio: $(r 10)"
jq -e '.isError != true and (.structuredContent.records[0].rate_shown == true) and (.structuredContent.records[0].text | test("approximate 95% interval"))' <<<"$(r 11)" >/dev/null || fail "12 user-marked outcomes give a rate: $(r 11)"
jq -e '.isError != true and (.structuredContent.records[0].rate_shown == false) and (.structuredContent.records[0].text | test("not enough user-marked outcomes for a rate"))' <<<"$(r 12)" >/dev/null || fail "12 host-reported outcomes give no rate: $(r 12)"
jq -e '.isError == true and (.structuredContent.error.code == "invalid_request")' <<<"$(r 13)" >/dev/null || fail "unknown argument refused"
jq -e '.isError == true and (.content[0].text | test("skill_not_found"))' <<<"$(r 14)" >/dev/null || fail "unknown skill"
for id in 10 11 12; do
  r $id | grep -Eq 'use_[0-9A-Za-z]{4,}|[0-9]{4}-[0-9]{2}-[0-9]{2}T|issued_at|reported_at|computed_at|/tmp|/private|/var/' && fail "the answer to $id leaks an id, a time or a path"
done
serve "$(CALL 20 e3d_my_calibration '{}')" "$S" "$C" "$M" E3D_MCP_PRINCIPAL=alice | jq -e 'select(.id==20) | .result | .isError == true and (.content[0].text | test("skill_scope_denied"))' >/dev/null || fail "another principal is refused skill_scope_denied"
echo "calibration-mcp-read 5 (stdio round trip): ok"
echo "calibration-mcp-read: PASS"
