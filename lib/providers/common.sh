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

# Machine-wide mutex around the local provider's real model call. The local
# adapter typically points at a shared, memory-resident inference process
# (e.g. a single Qwen instance also serving other repos' agents); running two
# calls against it at once is a real OOM risk, not just a slowdown, so every
# e3d-pilot invocation on the box -- regardless of which target repo or run
# started it -- serializes through this one lock rather than each provider
# call managing its own concurrency.
LOCAL_MODEL_LOCK_DIR="${LOCAL_MODEL_LOCK_DIR:-${TMPDIR:-/tmp}/e3d-pilot-qwen.lock}"
LOCAL_MODEL_LOCK_TIMEOUT="${LOCAL_MODEL_LOCK_TIMEOUT:-900}"

local_model_lock_acquire() {
  local waited=0 holder_pid
  while ! mkdir "$LOCAL_MODEL_LOCK_DIR" 2>/dev/null; do
    holder_pid="$(cat "$LOCAL_MODEL_LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -n "$holder_pid" ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
      # Lock holder is gone (crashed/killed) -- reclaim rather than deadlock.
      rm -rf "$LOCAL_MODEL_LOCK_DIR"
      continue
    fi
    if (( waited >= LOCAL_MODEL_LOCK_TIMEOUT )); then
      echo "error: timed out after ${LOCAL_MODEL_LOCK_TIMEOUT}s waiting for the local-model lock ($LOCAL_MODEL_LOCK_DIR) -- another e3d-pilot run appears to be using the local endpoint" >&2
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  printf '%s' "$$" > "$LOCAL_MODEL_LOCK_DIR/pid"
}

local_model_lock_release() {
  rm -rf "$LOCAL_MODEL_LOCK_DIR"
}

# Run one provider process with a portable wall-clock timeout. This avoids a
# dependency on GNU `timeout` (not shipped by macOS), forwards cancellation,
# and leaves stdout/stderr attached so callers can capture them normally.
provider_run_with_timeout() {
  local timeout_seconds="$1"
  shift
  [[ "$timeout_seconds" =~ ^[0-9]+$ ]] && (( timeout_seconds > 0 )) || {
    echo "error: provider timeout must be a positive integer (got: $timeout_seconds)" >&2
    return "$PROVIDER_EXIT_FAILURE"
  }

  "$@" &
  local child_pid=$! elapsed=0 status
  trap 'kill -TERM "$child_pid" 2>/dev/null || true; exit 130' INT
  trap 'kill -TERM "$child_pid" 2>/dev/null || true; exit 143' TERM HUP

  while kill -0 "$child_pid" 2>/dev/null; do
    if (( elapsed >= timeout_seconds )); then
      kill -TERM "$child_pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$child_pid" 2>/dev/null || true
      wait "$child_pid" 2>/dev/null || true
      trap - INT TERM HUP
      echo "error: provider timed out after ${timeout_seconds}s" >&2
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  if wait "$child_pid"; then status=0; else status=$?; fi
  trap - INT TERM HUP
  return "$status"
}
