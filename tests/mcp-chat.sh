#!/usr/bin/env bash
set -euo pipefail

# The single-model chat run and its route on the internal run listener (lib/mcp/chat-runner.js, lib/mcp/run-server.js). Unit tests over loopback with a fake adapter.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$(node "$ROOT/tests/fixtures/chat-run-test.mjs")" || { echo "$out"; echo "FAIL: chat run tests" >&2; exit 1; }
echo "$out" | tail -3
[[ "$out" == *"chat run-server unit tests:"* ]] || { echo "FAIL: no summary line" >&2; exit 1; }
echo "mcp-chat: ok"
