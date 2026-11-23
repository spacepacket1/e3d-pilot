#!/usr/bin/env bash
# Hardening of the expert loader (skills phase 2a): hash-line stripping (F-2), lens delimiter spoofing (T3), hidden and non-NFC text (T20) and
# read-once (T21). Local and read-only: fixtures are built in a temp directory; no model, network or CLI.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node "$ROOT/tests/fixtures/specialists/hardening.mjs"
echo "specialists-hardening.sh: PASS"
