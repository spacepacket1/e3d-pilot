#!/usr/bin/env bash
# Calibration phase 3, P3-1: the in-memory use-ticket ledger (lib/calibration/mcp-ledger.mjs). No model, no network, no files written.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node "$ROOT/tests/fixtures/calibration/mcp-ledger.mjs" || { echo "FAIL: calibration-mcp-ledger cases" >&2; exit 1; }
echo "calibration-mcp-ledger: PASS"
