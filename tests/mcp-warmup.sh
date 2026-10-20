#!/usr/bin/env bash
set -euo pipefail

# Feature warm-up: e3d-mcp learns the billing service's advertised features from GET /health, with no client call.
# Fake billing over loopback; no model calls. See tests/fixtures/extauth-warmup-test.mjs.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node "$ROOT/tests/fixtures/extauth-warmup-test.mjs" x | tee /dev/stderr | grep -q "warm-up tests: 8 groups passed" || { echo "FAIL: warm-up tests" >&2; exit 1; }
echo "ok - mcp-warmup"
