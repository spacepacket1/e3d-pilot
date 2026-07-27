#!/usr/bin/env bash
# Shared helpers for provider adapters (lib/providers/claude|codex|local).
#
# Exit code contract (docs/build-e3d-pilot.md, Phase 2):
#   0 - success
#   1 - failure (provider invoked but errored)
#   2 - unavailable (provider not configured/reachable; documented, not a crash)
#
# Availability check contract:
#   Invoking a provider script with E3D_PILOT_CHECK=1 skips the real prompt
#   call entirely (the $1 prompt-file path is not required), prints a short
#   human-readable status line, and exits 0 (available) or 2 (unavailable).
#   This is what `e3d-pilot providers list` calls to stay generic instead of
#   branching per provider name outside lib/providers/.
#
# Dry-run contract:
#   E3D_PILOT_DRY_RUN=1 makes a provider print the exact command it would run
#   (including the prompt file path) instead of invoking the real binary.

PROVIDER_EXIT_OK=0
PROVIDER_EXIT_FAILURE=1
PROVIDER_EXIT_UNAVAILABLE=2

provider_require_prompt_file() {
  local prompt_file="${1:-}"
  if [[ -z "$prompt_file" ]]; then
    echo "error: prompt file path required as \$1" >&2
    exit "$PROVIDER_EXIT_FAILURE"
  fi
  if [[ ! -f "$prompt_file" ]]; then
    echo "error: prompt file not found: $prompt_file" >&2
    exit "$PROVIDER_EXIT_FAILURE"
  fi
}

provider_binary_available() {
  command -v "$1" >/dev/null 2>&1
}

local_endpoint_configured() {
  [[ -n "${LOCAL_MODEL_ENDPOINT:-}" ]]
}

local_endpoint_reachable() {
  local endpoint="${LOCAL_MODEL_ENDPOINT:-}"
  [[ -n "$endpoint" ]] || return 1
  curl -s -o /dev/null -m "${LOCAL_MODEL_CHECK_TIMEOUT:-3}" "$endpoint"
}
