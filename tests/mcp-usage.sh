#!/usr/bin/env bash
set -euo pipefail

# Usage accounting and daily caps for e3d_debate (stub debate binary, no model calls).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER="$ROOT/bin/e3d-mcp"
CLIENT="$ROOT/tests/fixtures/mcp-test-client.mjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-assert_eq}: expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "${3:-assert_contains}: expected to find [$2] in [$1]"; }

STUB="$TMP/stub-debate"; ARGS="$TMP/stub-calls"; : > "$ARGS"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do case "$1" in --out-dir) out="$2"; shift 2 ;; *) shift ;; esac; done
echo call >> "$STUB_CALLS"
sleep "${STUB_SLEEP:-0}"
mkdir -p "$out"
printf '# Debate\n\n## Round 1 -- claude\n\nJSON file.\n\n## Round 1 -- codex\n\nSQLite.\n' > "$out/transcript.md"
if [[ "${STUB_FAIL:-0}" == "1" ]]; then echo "provider exploded" >&2; exit 1; fi
printf 'FINAL ANSWER: Use JSON.\nCONSENSUS: split\nDISSENT: Codex prefers SQLite.\n'
STUBEOF
chmod +x "$STUB"

state() { echo "$TMP/state-$1"; }
call() {  # call <state-id> <tool> <args-json> [env-json]
  node "$CLIENT" "$(jq -nc --arg s "$SERVER" --arg n "$2" --argjson a "$3" --arg sd "$(state "$1")" --arg stub "$STUB" --arg ca "$ARGS" --argjson e "${4:-{\}}" \
    '{server:$s, env:({E3D_MCP_DEBATE_BIN:$stub, STUB_CALLS:$ca, E3D_MCP_STATE_DIR:$sd, TYPESAFE_API_KEY:""}+$e), calls:[{name:$n, arguments:$a}]}')"
}
sc() { jq -c '.results[0].structuredContent'; }
iserr() { jq -r '.results[0].isError // false'; }
Q='{"question":"JSON or SQLite?"}'

# unlimited by default: usage is reported, nothing is refused
out="$(call a e3d_debate "$Q")"
assert_eq "$(iserr <<< "$out")" "false"
assert_eq "$(sc <<< "$out" | jq -r .usage.model_calls)" "3" "2 voices x 1 round + 1 synthesis"
assert_eq "$(sc <<< "$out" | jq -r .usage.estimate)" "true" "tokens are labeled estimates"
[[ "$(sc <<< "$out" | jq -r .usage.est_output_tokens)" -gt 0 ]] || fail "estimated output tokens"
assert_eq "$(sc <<< "$out" | jq -r .budget.principal)" "local"
assert_eq "$(sc <<< "$out" | jq -r .budget.calls_limit)" "null" "no limit in stdio mode by default"

# a daily call cap: refuse BEFORE spending, state untouched
CAP='{"E3D_MCP_DAILY_CALLS":"7"}'
out="$(call b e3d_debate "$Q" "$CAP")"; assert_eq "$(sc <<< "$out" | jq -r .budget.calls_today)" "3"; assert_eq "$(sc <<< "$out" | jq -r .budget.remaining_calls)" "4"
out="$(call b e3d_debate "$Q" "$CAP")"; assert_eq "$(sc <<< "$out" | jq -r .budget.calls_today)" "6" "usage persists across server restarts"
before="$(wc -l < "$ARGS" | tr -d ' ')"
out="$(call b e3d_debate "$Q" "$CAP")"
assert_eq "$(iserr <<< "$out")" "true" "6 + worst case 3 > 7"
assert_contains "$(jq -r '.results[0].content[0].text' <<< "$out")" "daily budget"
assert_contains "$(jq -r '.results[0].content[0].text' <<< "$out")" "only 1 of today's 7"
assert_eq "$(wc -l < "$ARGS" | tr -d ' ')" "$before" "a refused debate must not start the debate binary (no spend)"
out="$(call b e3d_usage '{}' "$CAP")"
assert_eq "$(sc <<< "$out" | jq -r .calls_today)" "6" "the refusal recorded nothing"
assert_eq "$(sc <<< "$out" | jq -r .calls_limit)" "7"
assert_contains "$(jq -r '.results[0].content[0].text' <<< "$out")" "of 7 calls"
resets="$(sc <<< "$out" | jq -r .resets_at)"
[[ "$resets" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T00:00:00\.000Z$ ]] || fail "budget must say when it resets (UTC midnight), got [$resets]"
[[ "$resets" > "$(date -u +%Y-%m-%dT%H:%M:%S)" ]] || fail "resets_at must be in the future"

# a token cap uses the worst-case estimate
out="$(call c e3d_debate "$Q" '{"E3D_MCP_DAILY_EST_TOKENS":"100"}')"
assert_eq "$(iserr <<< "$out")" "true"; assert_contains "$(jq -r '.results[0].content[0].text' <<< "$out")" "tokens (estimate)"

# day rollover: yesterday's counts do not count today
mkdir -p "$(state d)"
printf '{"day":"2000-01-01","calls":999,"est_input_tokens":999999,"est_output_tokens":999999,"debates":50}\n' > "$(state d)/local.json"
out="$(call d e3d_usage '{}' "$CAP")"
assert_eq "$(sc <<< "$out" | jq -r .calls_today)" "0" "a new UTC day resets the counters"
out="$(call d e3d_debate "$Q" "$CAP")"; assert_eq "$(iserr <<< "$out")" "false" "and debates are allowed again"
assert_eq "$(jq -r .day "$(state d)/local.json")" "$(date -u +%Y-%m-%d)"

# calls that ran are counted even when the debate fails; the error is still returned
out="$(call e e3d_debate "$Q" '{"STUB_FAIL":"1","E3D_MCP_DAILY_CALLS":"50"}')"
assert_eq "$(iserr <<< "$out")" "true" "failed debate"
out="$(call e e3d_usage '{}')"
assert_eq "$(sc <<< "$out" | jq -r .calls_today)" "3" "calls that ran before the failure are counted"

# principals are separate
out="$(call f e3d_debate "$Q" '{"E3D_MCP_PRINCIPAL":"alice"}')"
assert_eq "$(sc <<< "$out" | jq -r .budget.principal)" "alice"
out="$(call f e3d_usage '{}')"
assert_eq "$(sc <<< "$out" | jq -r .calls_today)" "0" "the 'local' principal is untouched by alice"
[[ -f "$(state f)/alice.json" ]] || fail "per-principal state file"
# state files are valid JSON written atomically (no stray .tmp)
ls "$(state f)" | grep -q '\.tmp$' && fail "no temp files should be left behind"

# e3d_usage is listed and read-only/free
tools="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | "$SERVER" 2>/dev/null)"
assert_eq "$(jq -r '.result.tools[] | select(.name=="e3d_usage") | .annotations.readOnlyHint' <<< "$tools")" "true"
jq -e '.result.tools[] | select(.name=="e3d_usage") | .description | test("FREE")' <<< "$tools" >/dev/null || fail "e3d_usage description must say FREE"

# a debate result starts with a block the agent must pass on: consensus, dissent, warnings (an agent dropped them before)
out="$(call c e3d_debate "$Q")"
first="$(jq -r '.results[0].content[0].text' <<< "$out" | head -1)"
assert_contains "$first" "REPORT THIS TO THE USER" "the first line of a debate result is the must-report block"
assert_contains "$first" "dissent: Codex prefers SQLite." "dissent is in that block in full"
assert_contains "$first" "SPLIT" "and the consensus level"

# concurrent debates cannot both pass the same cap: each reserves its worst case (3 calls) atomically before it runs,
# even from separate server processes sharing one counter file; the winner settles to what it actually used
CC='{"E3D_MCP_DAILY_CALLS":"4","STUB_SLEEP":"3"}'
call conc e3d_debate "$Q" "$CC" > "$TMP/c1.json" &
call conc e3d_debate "$Q" "$CC" > "$TMP/c2.json" &
wait
errs=0; for f in "$TMP/c1.json" "$TMP/c2.json"; do [[ "$(jq -r '.results[0].isError // false' "$f")" == "true" ]] && errs=$((errs+1)); done
assert_eq "$errs" "1" "exactly one of two simultaneous debates fits a cap of 4 calls (worst case 3 each)"
refused="$(for f in "$TMP/c1.json" "$TMP/c2.json"; do jq -r 'select(.results[0].isError==true) | .results[0].content[0].text' "$f"; done)"
assert_contains "$refused" "daily budget"
out="$(call conc e3d_usage '{}' "$CC")"
assert_eq "$(sc <<< "$out" | jq -r .calls_today)" "3" "the winner settled to its actual 3 calls and the loser recorded nothing"

# reserve / settle / release at the unit level (the pieces the budget guarantees rest on)
node --input-type=module - "$ROOT" "$TMP/unit-state" <<'JS'
import assert from 'node:assert/strict';
const { createUsage, jobCost } = await import(`${process.argv[2]}/lib/mcp/usage.js`);
const u = createUsage({ env: { E3D_MCP_STATE_DIR: process.argv[3], E3D_MCP_DAILY_CALLS: '10', E3D_MCP_DAILY_EST_TOKENS: '100000' } });
let r = await u.reserve('p', { calls: 4, tokens: 20000 }, 'job');
assert.equal(r.ok, true); assert.equal(r.budget.calls_today, 4);
r = await u.reserve('p', { calls: 7, tokens: 1 }, 'job');
assert.equal(r.ok, false, 'a reservation that would break the call cap is refused'); assert.match(r.reason, /only 6 of today's 10/);
assert.equal((await u.snapshot('p')).calls_today, 4, 'a refusal records nothing');
r = await u.reserve('p', { calls: 1, tokens: 90000 }, 'job');
assert.equal(r.ok, false, 'the token cap is enforced too'); assert.match(r.reason, /tokens/);
assert.equal((await u.release('p', { calls: 4, tokens: 20000 }, 'job')).calls_today, 0, 'release gives a reservation back');
await u.reserve('p', { calls: 3, tokens: 9000 }, 'debate');
const st = await u.settle('p', { calls: 3, tokens: 9000 }, { calls: 2, inTokens: 500, outTokens: 100 });
assert.equal(st.calls_today, 2, 'settle replaces the worst case with actual use'); assert.equal(st.est_tokens_today, 600);
assert.deepEqual(jobCost('stage', { providers: 2 }), { calls: 4, tokens: 80000 }, 'a stage costs 2 calls per configured provider');
assert.deepEqual(jobCost('implement', { drafters: 1, negotiators: 2 }), { calls: 5, tokens: 75000 });
assert.equal(jobCost('execute', { phases: 3, reviewers: 1 }).calls, 10);
assert.throws(() => jobCost('nope'));
console.log('usage unit ok');
JS

echo "mcp-usage.sh: ok"
