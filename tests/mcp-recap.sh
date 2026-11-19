#!/usr/bin/env bash
set -euo pipefail

# The recap job and its route on the internal run listener (lib/mcp/recap-runner.js, lib/mcp/run-server.js). Unit tests over loopback with a fake adapter.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$(node "$ROOT/tests/fixtures/recap-run-test.mjs")" || { echo "$out"; echo "FAIL: recap run tests" >&2; exit 1; }
echo "$out" | tail -3
[[ "$out" == *"recap run-server unit tests:"* ]] || { echo "FAIL: no summary line" >&2; exit 1; }
echo "mcp-recap: ok"
