#!/usr/bin/env bash
# Runs every tests/*.sh, never stops at the first failure, prints a summary, exits non-zero if any test failed.
# Tests listed in tests/ci-skip.txt ("name.sh: reason", one per line, # for comments) are skipped with the reason printed.
# Usage: scripts/run-tests.sh [test-name.sh ...]     (no arguments: all tests)
# E3D_TEST_TIMEOUT: per-test limit in seconds (default 600). E3D_TEST_NO_SKIP=1: ignore the skip list.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
LIMIT="${E3D_TEST_TIMEOUT:-600}"
SKIPFILE="tests/ci-skip.txt"

skip_reason() {
  [[ "${E3D_TEST_NO_SKIP:-0}" == "1" || ! -f "$SKIPFILE" ]] && return 1
  local line
  line="$(grep -E "^$1:" "$SKIPFILE" | head -1)" || return 1
  [[ -n "$line" ]] || return 1
  printf '%s' "${line#*:}" | sed 's/^ *//'
}

if [[ $# -gt 0 ]]; then names=("$@"); else names=(); for f in tests/*.sh; do names+=("$(basename "$f")"); done; fi

passed=(); failed=(); skipped=()
for name in "${names[@]}"; do
  name="$(basename "$name")"
  if reason="$(skip_reason "$name")"; then
    echo "=== SKIP $name: $reason"; skipped+=("$name: $reason"); continue
  fi
  echo "=== RUN  $name"
  start=$SECONDS
  perl -e 'alarm shift; exec @ARGV' "$LIMIT" bash "tests/$name" </dev/null
  rc=$?
  dur=$((SECONDS - start))
  if [[ $rc -eq 0 ]]; then echo "=== PASS $name (${dur}s)"; passed+=("$name")
  else
    [[ $rc -eq 142 ]] && echo "=== (timed out after ${LIMIT}s)"
    echo "=== FAIL $name (exit $rc, ${dur}s)"; failed+=("$name (exit $rc)")
  fi
done

echo
echo "=============== test summary ==============="
echo "passed:  ${#passed[@]}"
echo "failed:  ${#failed[@]}"
echo "skipped: ${#skipped[@]}"
if [[ ${#skipped[@]} -gt 0 ]]; then echo "-- skipped"; printf '   %s\n' "${skipped[@]}"; fi
if [[ ${#failed[@]} -gt 0 ]]; then echo "-- FAILED"; printf '   %s\n' "${failed[@]}"; exit 1; fi
exit 0
