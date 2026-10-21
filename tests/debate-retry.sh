#!/usr/bin/env bash
# e3d-debate retries a provider that fails with a transient vendor error (HTTP 429/500/502/503/504, curl timeout), a bounded
# number of times, and never retries anything else.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
mkdir -p "$T/bin" "$T/lib/providers"
cp "$ROOT/bin/e3d-debate" "$T/bin/"
cp "$ROOT/lib/providers/jev.sh" "$ROOT/lib/providers/common.sh" "$T/lib/providers/"

# flaky: fails with the given stderr for the first $FAILS calls, then answers. Counts calls in $T/calls-flaky.
stub_flaky() { # name fails stderr-line
  cat > "$T/lib/providers/$1" <<STUB
#!/usr/bin/env bash
echo x >> "$T/calls-$1"
n=\$(wc -l < "$T/calls-$1" | tr -d ' ')
if (( n <= $2 )); then printf '%s\n' '$3' >&2; exit 1; fi
printf 'Answer from $1.\nPOSITION: p\nstatus: revise\n'
STUB
  chmod +x "$T/lib/providers/$1"
}
cat > "$T/lib/providers/steady" <<'STUB'
#!/usr/bin/env bash
printf 'Answer from steady.\nPOSITION: p\nstatus: revise\n'
STUB
cat > "$T/lib/providers/synth" <<'STUB'
#!/usr/bin/env bash
printf 'FINAL ANSWER: ok\nCONSENSUS: split\nDISSENT: none\n'
STUB
chmod +x "$T/lib/providers/steady" "$T/lib/providers/synth"

run() { rm -f "$T"/calls-*; env -u TYPESAFE_API_KEY E3D_DEBATE_PROVIDER_RETRY_DELAY=0 "$@" "$T/bin/e3d-debate" "q?" --providers flaky,steady --rounds 1 --synthesizer synth --out-dir "$T/out" > "$T/stdout" 2> "$T/stderr" || { cat "$T/stderr"; exit 1; }; }
calls() { [[ -f "$T/calls-flaky" ]] && wc -l < "$T/calls-flaky" | tr -d ' ' || echo 0; }

# 1. two 503s then success: the model stays in the debate
stub_flaky flaky 2 'error: gemini-api HTTP 503: This model is currently experiencing high demand.'
run env
[[ "$(calls)" == 3 ]] || fail "expected 3 calls (2 retries), got $(calls)"
grep -q 'Answer from flaky' "$T/stdout" || fail "the retried model should have answered"
grep -q 'retry 2 of 2' "$T/stderr" || fail "retries should be announced"

# 2. a permanent failure (HTTP 401) is not retried
stub_flaky flaky 99 'error: gemini-api HTTP 401: API key not valid'
run env
[[ "$(calls)" == 1 ]] || fail "a 401 must not be retried (calls $(calls))"
grep -q 'provider flaky failed' "$T/stdout" || fail "the failure should be reported in the transcript"

# 3. a transient failure that never clears gives up after the configured retries
stub_flaky flaky 99 'error: gemini-api HTTP 429: rate limited'
run env
[[ "$(calls)" == 3 ]] || fail "expected 3 calls then give up, got $(calls)"

# 4. retries can be turned off
stub_flaky flaky 99 'error: gemini-api HTTP 503: busy'
run env E3D_DEBATE_PROVIDER_RETRIES=0
[[ "$(calls)" == 1 ]] || fail "with retries 0 expected 1 call, got $(calls)"

# 5. a curl timeout is transient
stub_flaky flaky 1 'error: gemini-api request failed (curl exit 28): Operation timed out'
run env
[[ "$(calls)" == 2 ]] || fail "a curl timeout should be retried once here, got $(calls)"

# 6. garbage settings fall back to the defaults instead of looping
stub_flaky flaky 99 'error: gemini-api HTTP 503: busy'
run env E3D_DEBATE_PROVIDER_RETRIES=9999
[[ "$(calls)" == 3 ]] || fail "an out-of-range retry setting should fall back to 2 retries, got $(calls) calls"
echo "debate-retry: ok"
