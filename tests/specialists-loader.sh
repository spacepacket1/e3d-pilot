#!/usr/bin/env bash
# Experts as standard skill folders, Phase 1.1 (docs/specs/experts-phase1-private-experts-spec.md): the loader, the validator and the content hash
# in lib/debate/specialists.mjs. Read-only and local: the cases build their fixtures in a temp directory and call no model, no network, no CLI.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node "$ROOT/tests/fixtures/specialists/cases.mjs"
echo "specialists-loader.sh: PASS"
