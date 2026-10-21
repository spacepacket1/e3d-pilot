#!/usr/bin/env bash
# lib/mcp/redact.js: secrets in logs and tool output are redacted; ordinary text and token COUNTS are not.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }
red() { node -e "import('$ROOT/lib/mcp/redact.js').then(m=>process.stdout.write(m.redact(process.argv[1])))" -- "$1"; }
must_hide() { # input secret
  local out; out="$(red "$1")"
  [[ "$out" != *"$2"* ]] || fail "'$2' survived redaction in: $out"
  [[ "$out" == *"[REDACTED]"* ]] || fail "no [REDACTED] marker for: $1 -> $out"
}
must_keep() { local out; out="$(red "$1")"; [[ "$out" == "$1" ]] || fail "ordinary text changed: '$1' -> '$out'"; }

# the gaps this fix closes
must_hide 'AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYzzzzzzzzzzzz' 'wJalrXUtnFEMI'
must_hide 'aws_secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYzzzzzzzzzzzz"' 'wJalrXUtnFEMI'
must_hide 'AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE' 'AKIAIOSFODNN7EXAMPLE'
must_hide 'connecting to postgres://admin:s3cr3tpw@db.internal:5432/app' 's3cr3tpw'
must_hide 'mongodb+srv://u:p%40ss-w0rd@cluster0.mongodb.net/db' 'p%40ss-w0rd'
must_hide 'redis://:hunter2hunter2@cache:6379' 'hunter2hunter2'
must_hide 'https://user:tok3n-value@example.com/x' 'tok3n-value'
must_hide 'private_key: abcdef123456' 'abcdef123456'
must_hide 'client_secret=zzzzzzzz1234' 'zzzzzzzz1234'
must_hide 'stripe sk_live_abcdefgh12345678 and whsec_abcdefgh12345678' 'abcdefgh12345678'
must_hide 'key e3d_pilot_ABCDEFGHijklmnop and token e3d_pat_ABCDEFGHijklmnop' 'ABCDEFGHijklmnop'
must_hide 'xoxb-1234567890-abcdefghij' 'abcdefghij'
must_hide 'xai-abcdefghijklmnopqrstuvwxyz0123' 'abcdefghijklmnopqrstuvwxyz0123'
# the user and the host of a URL stay, the password goes
[[ "$(red 'postgres://admin:s3cr3tpw@db.internal:5432/app')" == 'postgres://admin:[REDACTED]@db.internal:5432/app' ]] || fail "URL redaction should keep user and host"
# what already worked still works
must_hide 'k=sk-abcdefghijklmnopqrstuvwx' 'abcdefghijklmnopqrstuvwx'
must_hide 'ANTHROPIC_API_KEY=hunter2' 'hunter2'
must_hide '{"password":"p4ss"}' 'p4ss'
must_hide 'Authorization: Bearer abcdefghijklmnop' 'abcdefghijklmnop'
# ordinary text, numbers and token COUNTS are left alone
must_keep 'plain text, calls: 5, tokens: 1234, est_input_tokens=900, key rotation at noon'
must_keep 'see https://example.com/docs/tokens and http://localhost:3001/internal/jobs'
must_keep 'user@example.com wrote at 10:30'
echo "mcp-redact: ok"
