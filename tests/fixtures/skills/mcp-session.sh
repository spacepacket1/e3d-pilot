#!/usr/bin/env bash
# A stdio session with bin/e3d-mcp that ends when the answer to the last request has arrived (no fixed sleep). Sourced by tests/skills-compat.sh and
# tests/calibration-mcp-read.sh; the caller sets ROOT and TMP.
#   mcp_session <last_id> <env...> < requests    prints every response line; the server's stderr goes to $MCP_ERR (default $TMP/mcp-err)
mcp_session() {
  local last="$1"; shift
  local fifo="$TMP/mcp-fifo.$$.$RANDOM" out="$TMP/mcp-out.$$.$RANDOM" i
  : "${MCP_ERR:=$TMP/mcp-err}"
  mkfifo "$fifo"; : > "$out"
  env -i PATH="$PATH" HOME="$TMP/home" E3D_MCP_STATE_DIR="$TMP/state" "$@" "$ROOT/bin/e3d-mcp" < "$fifo" > "$out" 2> "$MCP_ERR" &
  local pid=$!
  exec 7> "$fifo"
  cat >&7
  for i in $(seq 1 200); do grep -q "\"id\":$last," "$out" 2>/dev/null && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  exec 7>&-
  for i in 1 2 3 4; do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  cat "$out"; rm -f "$fifo" "$out"
}
