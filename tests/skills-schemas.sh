#!/usr/bin/env bash
# Phase 1 skills schemas and fixtures (docs/skills/phase1/). No model, no network, no files written.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node "$ROOT/tests/skills-schemas.mjs"
