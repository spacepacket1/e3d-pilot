#!/usr/bin/env bash
# Skills phase 3c, PR H1: lib/skills/intake.mjs (hosted skill definitions). Pure library cases; no model, no network, no listener.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node "$ROOT/tests/fixtures/skills/intake.mjs"
echo "skills-intake: ok"
