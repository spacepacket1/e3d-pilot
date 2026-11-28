#!/usr/bin/env bash
set -euo pipefail

# The curl adapters must never leave a vendor key behind. A call that hangs is stopped the way provider_run_with_timeout stops
# it (TERM, one second, KILL): afterwards no e3d-pilot-<name>.* work directory may remain in TMPDIR and no file may hold the
# key, and while the call runs the key must not be on any process's command line. Also: the startup sweep of stale work dirs.
# Fake keys and a local server that never answers; no network beyond 127.0.0.1, no spend.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P="$ROOT/lib/providers"
T="$(mktemp -d)"
SERVER_PID=""
trap '[[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# shellcheck source=../lib/providers/common.sh
source "$P/common.sh"

cat > "$T/hang.mjs" <<'JS'
import http from 'node:http';
import { writeFileSync } from 'node:fs';
const srv = http.createServer(() => { /* reads the request, never answers */ });
srv.listen(0, '127.0.0.1', () => writeFileSync(process.argv[2], String(srv.address().port)));
JS
node "$T/hang.mjs" "$T/port" & SERVER_PID=$!
for _ in $(seq 1 50); do [[ -s "$T/port" ]] && break; sleep 0.1; done
[[ -s "$T/port" ]] || fail "hanging server did not start"
BASE="http://127.0.0.1:$(cat "$T/port")"
printf 'What is 2+2?\n' > "$T/prompt.md"

# Every bash at hand: how a signal reaches a script blocked in a command substitution differs between versions (bash 3.2, the macOS
# /bin/bash, leaves the old work dir behind where bash 5.3 happens not to). E3D_KEYCLEAN_BASHES overrides the list.
BASHES=()
for b in ${E3D_KEYCLEAN_BASHES:-$(command -v bash) /bin/bash}; do
  [[ -x "$b" ]] || continue
  for seen in "${BASHES[@]:-}"; do [[ "$seen" -ef "$b" ]] && continue 2; done
  BASHES+=("$b")
done

# run_case <label> <provider> <key> <env...>: run the provider against the hanging server under provider_run_with_timeout, once per bash
run_case() {
  local i
  # E3D_KEYCLEAN_ONLY="anthropic openai-ws ...": run only these cases (mutation checks)
  [[ -z "${E3D_KEYCLEAN_ONLY:-}" || " $E3D_KEYCLEAN_ONLY " == *" $1 "* ]] || return 0
  for i in "${!BASHES[@]}"; do run_one "${BASHES[$i]}" "$1-bash$i" "${@:2}"; done
}
run_one() {
  local sh="$1" label="$2" provider="$3" key="$4" rc=0 tmp
  shift 4
  tmp="$T/tmp-$label"
  mkdir -p "$tmp"
  ( export TMPDIR="$tmp" "$@"; provider_run_with_timeout 3 "$sh" "$P/$provider" "$T/prompt.md" > "$T/$label.out" 2> "$T/$label.err" ) & local pid=$!
  # while the call hangs: the key is on no command line (curl's included)
  sleep 1.5
  ps -axww -o args= > "$T/$label.ps"
  grep -qF "$BASE" "$T/$label.ps" || fail "$label: no curl process seen while the call hangs"
  if grep -qF "$key" "$T/$label.ps"; then fail "$label: the key is on a process command line"; fi
  wait "$pid" || rc=$?
  [[ "$rc" == 124 ]] || fail "$label: expected the timeout status 124, got $rc ($(cat "$T/$label.err"))"
  grep -q 'provider timed out after 3s' "$T/$label.err" || fail "$label: timeout message missing"
  # TERM must have run the cleanup: nothing of the adapter's work dir is left, and no file anywhere in TMPDIR holds the key
  local left
  left="$(find "$tmp" -mindepth 1 -maxdepth 1 -name 'e3d-pilot-*' | head -5)"
  [[ -z "$left" ]] || fail "$label: work dir left after TERM/KILL: $left ($(ls "$left" 2>/dev/null | tr '\n' ' '))"
  if grep -rqF "$key" "$tmp" 2>/dev/null; then fail "$label: the key is in a file under TMPDIR"; fi
  # and the vendor call itself was stopped, not orphaned
  if ps -axww -o args= | grep -v grep | grep -qF "$BASE"; then fail "$label: curl still running after the provider was stopped"; fi
  echo "ok: $label ($("$sh" -c 'echo "$BASH_VERSION"'))"
}

AKEY="sk-ant-FAKE-KEYLEAK-1111111111"
OKEY="sk-oai-FAKE-KEYLEAK-2222222222"
XKEY="xai-FAKE-KEYLEAK-3333333333"
GKEY="AIza-FAKE-KEYLEAK-4444444444"
RKEY="sk-or-FAKE-KEYLEAK-5555555555"
ZKEY="azure-FAKE-KEYLEAK-6666666666"

run_case anthropic anthropic-api "$AKEY" ANTHROPIC_API_KEY="$AKEY" ANTHROPIC_API_BASE_URL="$BASE" ANTHROPIC_API_TIMEOUT=60
run_case openai openai-api "$OKEY" OPENAI_API_KEY="$OKEY" OPENAI_API_BASE_URL="$BASE" OPENAI_API_MODEL=gpt-test OPENAI_API_TIMEOUT=60
run_case xai xai-api "$XKEY" XAI_API_KEY="$XKEY" XAI_API_BASE_URL="$BASE" XAI_API_MODEL=grok-test XAI_API_TIMEOUT=60
run_case gemini gemini-api "$GKEY" GEMINI_API_KEY="$GKEY" GEMINI_API_BASE_URL="$BASE" GEMINI_API_MODEL=gemini-test GEMINI_API_TIMEOUT=60
run_case openrouter openrouter "$RKEY" OPENROUTER_API_KEY="$RKEY" OPENROUTER_BASE_URL="$BASE" OPENROUTER_MODEL=test/model OPENROUTER_TIMEOUT=60
run_case or-deepseek or-deepseek "$RKEY" OPENROUTER_API_KEY="$RKEY" OPENROUTER_BASE_URL="$BASE" OPENROUTER_TIMEOUT=60
run_case azure azure-openai "$ZKEY" AZURE_OPENAI_API_KEY="$ZKEY" AZURE_OPENAI_ENDPOINT="$BASE" AZURE_OPENAI_DEPLOYMENT=d AZURE_OPENAI_TIMEOUT=60
# the web-search paths make their own calls (anthropic loop, OpenAI/xAI Responses API, Gemini Interactions API)
WS=(E3D_PROVIDER_WEB_SEARCH=1 E3D_PROVIDER_WS_TIMEOUT=60)
run_case anthropic-ws anthropic-api "$AKEY" ANTHROPIC_API_KEY="$AKEY" ANTHROPIC_API_BASE_URL="$BASE" "${WS[@]}"
run_case openai-ws openai-api "$OKEY" OPENAI_API_KEY="$OKEY" OPENAI_API_BASE_URL="$BASE" OPENAI_API_MODEL=gpt-test "${WS[@]}"
run_case xai-ws xai-api "$XKEY" XAI_API_KEY="$XKEY" XAI_API_BASE_URL="$BASE" XAI_API_MODEL=grok-test "${WS[@]}"
run_case gemini-ws gemini-api "$GKEY" GEMINI_API_KEY="$GKEY" GEMINI_API_BASE_URL="$BASE" GEMINI_API_MODEL=gemini-test GEMINI_API_NATIVE_BASE_URL="$BASE" "${WS[@]}"

# ---------------- startup sweep (bin/e3d-mcp): stale provider work dirs ----------------
S="$T/sweep"; mkdir -p "$S"
mk() { mkdir -m "$2" "$S/$1"; for f in "${@:3}"; do printf 'x' > "$S/$1/$f"; done; }
mk e3d-pilot-anthropic.AAAAAA 700 headers payload.json response.json curl.err   # legacy leftover (key header file): removed
mk e3d-pilot-gemini-api.BBBBBB 700 payload.json native-headers provider.json                  # removed
mk e3d-pilot-openai.CCCCCC 755 payload.json                                       # not private: kept
mk e3d-pilot-xai-api.DDDDDD 700 payload.json other.txt                            # an unknown file inside: kept
mk e3d-pilot-azure.EEEEEE 700 payload.json                                        # fresh (mtime below): kept
mk e3d-pilot-qwen.lock 700 pid                                                    # not a work dir: kept
mkdir -m 700 "$S/target"; printf 'x' > "$S/target/headers"; ln -s "$S/target" "$S/e3d-pilot-openrouter.FFFFFF"   # symlink: never followed
for d in "$S"/e3d-pilot-anthropic.AAAAAA "$S"/e3d-pilot-gemini-api.BBBBBB "$S"/e3d-pilot-openai.CCCCCC "$S"/e3d-pilot-xai-api.DDDDDD "$S"/e3d-pilot-qwen.lock; do
  touch -t 202001010000 "$d"
done
n="$(node --input-type=module -e "import('$ROOT/lib/mcp/chat-runner.js').then(async (m) => console.log(await m.sweepStaleProviderDirs({ base: process.argv[1] })))" "$S")"
[[ "$n" == 2 ]] || fail "sweep: expected 2 dirs removed, got $n"
[[ ! -e "$S/e3d-pilot-anthropic.AAAAAA" && ! -e "$S/e3d-pilot-gemini-api.BBBBBB" ]] || fail "sweep: stale private work dirs must be removed"
for k in e3d-pilot-openai.CCCCCC e3d-pilot-xai-api.DDDDDD e3d-pilot-azure.EEEEEE e3d-pilot-qwen.lock target/headers; do [[ -e "$S/$k" ]] || fail "sweep: $k must be kept"; done
[[ -L "$S/e3d-pilot-openrouter.FFFFFF" ]] || fail "sweep: a symlink is left alone"
grep -q 'sweepStaleProviderDirs()' "$ROOT/bin/e3d-mcp" || fail "bin/e3d-mcp must sweep stale provider dirs at start"
echo "ok: sweep"

echo "PASS provider-key-cleanup"
