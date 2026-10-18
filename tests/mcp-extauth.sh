#!/usr/bin/env bash
set -euo pipefail

# External auth and metering hook: protocol drift, conformance of the reference stub, and the client
# (lib/mcp/external-auth.js) against the stub. Loopback only, no model calls.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUB="$ROOT/examples/external-auth-stub.js"
CONF="$ROOT/examples/external-auth-conformance.js"
TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "${3:-assert_contains}: expected to find [$2] in [$1]"; }

# planted secret markers: none of these may appear in any captured log or output
SVC="svc-MARKER-$(openssl rand -hex 12)"
TOKEN_OK="caller-MARKER-ok-$(openssl rand -hex 12)"
TOKEN_REVOKED="caller-MARKER-revoked-$(openssl rand -hex 12)"
TOKEN_REVOCABLE="caller-MARKER-revocable-$(openssl rand -hex 12)"
TOKEN_SHORT_EXP="caller-MARKER-shortexp-$(openssl rand -hex 12)"
TOKEN_SIBLING="caller-MARKER-sibling-$(openssl rand -hex 12)"
export SVC_TOKEN="$SVC" TOKEN_OK TOKEN_REVOKED TOKEN_REVOCABLE TOKEN_SHORT_EXP TOKEN_SIBLING

jq -n --arg ok "$TOKEN_OK" --arg rv "$TOKEN_REVOKED" --arg rc "$TOKEN_REVOCABLE" --arg se "$TOKEN_SHORT_EXP" --arg sb "$TOKEN_SIBLING" '{accounts: [
  {principal: "acct_ok", balance: 1000000, keys: [
    {id: "key-ok", token: $ok, tools: ["e3d_debate", "e3d_usage"], limits: {rate_per_min: 60, max_inflight: 2}},
    {id: "key-revoked", token: $rv, revoked: true},
    {id: "key-revocable", token: $rc},
    {id: "key-sibling", token: $sb},
    {id: "key-short-exp", token: $se, expires_in_sec: 40}]},
  {principal: "acct_broke", balance: 0, keys: []},
  {principal: "acct_suspended", balance: 1000000, status: "suspended", keys: []},
  {principal: "acct_limited", balance: 1000000, max_holds: 0, keys: []}]}' > "$TMP/seed.json"
jq -n --arg ok "$TOKEN_OK" --arg rv "$TOKEN_REVOKED" '{active_token: $ok, inactive_token: $rv,
  principals: {ok: "acct_ok", insufficient_credits: "acct_broke", suspended: "acct_suspended", limit_reached: "acct_limited"}}' > "$TMP/fixtures.json"

start_stub() {  # start_stub <name> [ENV=VALUE...]  -> sets STUB_URL
  local name="$1"; shift
  env STUB_SERVICE_TOKEN="$SVC" STUB_SEED="$TMP/seed.json" STUB_URL_FILE="$TMP/$name.url" "$@" node "$STUB" > "$TMP/$name.out" 2> "$TMP/$name.log" &
  PIDS+=("$!")
  for _ in $(seq 1 100); do [[ -s "$TMP/$name.url" ]] && break; sleep 0.05; done
  [[ -s "$TMP/$name.url" ]] || fail "stub $name did not start: $(cat "$TMP/$name.log")"
  STUB_URL="$(cat "$TMP/$name.url")"
}

# --- the stub refuses to run without a strong service token or beyond loopback ---
if STUB_SERVICE_TOKEN=short node "$STUB" > /dev/null 2>&1; then fail "stub must refuse a short service token"; fi
if STUB_SERVICE_TOKEN="$SVC" STUB_HOST=0.0.0.0 node "$STUB" > /dev/null 2>&1; then fail "stub must refuse a non-loopback host"; fi
head -5 "$STUB" | grep -q "NOT PRODUCTION CODE" || fail "the stub must say it is not production code at the top"

# --- drift: document, schemas, client, stub and conformance vectors agree ---
node "$ROOT/tests/fixtures/extauth-drift.mjs" | tee "$TMP/drift.out"
# and the drift check really fails on drift: an undocumented-by-vectors transition, a code, or a changed schema
perl -pe 's/^(\| `T-expire` \|)/| `T-release-twice` | `held` | x | y | z |\n$1/' "$ROOT/docs/external-auth.md" > "$TMP/doc-extra-transition.md"
grep -q 'T-release-twice' "$TMP/doc-extra-transition.md" || fail "test setup: mutated document"
if node "$ROOT/tests/fixtures/extauth-drift.mjs" --doc "$TMP/doc-extra-transition.md" > "$TMP/drift1.out" 2>&1; then fail "drift check must fail when the document lists an uncovered transition"; fi
assert_contains "$(cat "$TMP/drift1.out")" "T-release-twice"
perl -pe 's/^(\| `reserve` \| `suspended` \|)/| `reserve` | `frozen` | made up |\n$1/' "$ROOT/docs/external-auth.md" > "$TMP/doc-extra-code.md"
if node "$ROOT/tests/fixtures/extauth-drift.mjs" --doc "$TMP/doc-extra-code.md" > "$TMP/drift2.out" 2>&1; then fail "drift check must fail when the document lists an extra code"; fi
assert_contains "$(cat "$TMP/drift2.out")" "reserve codes in the document"
mkdir -p "$TMP/schemas" && cp "$ROOT"/docs/external-auth/*.json "$TMP/schemas/"
jq '.properties.units.properties.calls.maximum = 5' "$ROOT/docs/external-auth/reserve.request.schema.json" > "$TMP/schemas/reserve.request.schema.json"
if node "$ROOT/tests/fixtures/extauth-drift.mjs" --schemas "$TMP/schemas" > "$TMP/drift3.out" 2>&1; then fail "drift check must fail when a schema file differs from the client"; fi
assert_contains "$(cat "$TMP/drift3.out")" "reserve.request.schema.json differs"
echo "ok - drift check detects drift"

# --- conformance: the reference stub passes every vector ---
start_stub conf STUB_RESERVATION_TTL_SEC=2
E3D_CONFORMANCE_FIXTURES="$TMP/fixtures.json" node "$CONF" "$STUB_URL" "$SVC" > "$TMP/conformance.out" 2>&1 || { cat "$TMP/conformance.out"; fail "conformance run against the stub"; }
cat "$TMP/conformance.out"
assert_contains "$(cat "$TMP/conformance.out")" "vectors passed"
# a non-conforming service fails the run with a non-zero exit (the stub injecting malformed reserve answers)
curl -fsS -X POST -H "authorization: Bearer $SVC" -H 'content-type: application/json' -d '{"mode":"invalid","calls":["reserve"]}' "$STUB_URL/_stub/inject" > /dev/null
if E3D_CONFORMANCE_FIXTURES="$TMP/fixtures.json" node "$CONF" "$STUB_URL" "$SVC" > "$TMP/conformance-bad.out" 2>&1; then fail "conformance must fail against a non-conforming service"; fi
assert_contains "$(cat "$TMP/conformance-bad.out")" "not ok"
echo "ok - conformance fails on a violation"

# --- the client against a fresh stub (default reservation lifetime) ---
start_stub client
STUB_URL="$STUB_URL" CLIENT_LOG="$TMP/client.log" node "$ROOT/tests/fixtures/extauth-client-test.mjs" | tee "$TMP/client.out"
assert_contains "$(cat "$TMP/client.out")" "client tests:"
grep -q "CONFIGURATION failure" "$TMP/client.log" || fail "a 401 for the service token must be logged distinctly as a configuration failure"
grep -q "service failure on settle: unavailable" "$TMP/client.log" || fail "service failures are logged"

# --- the durable settlement outbox (lib/mcp/outbox.js) and settleDurable/releaseDurable, against a fresh stub ---
start_stub outbox
mkdir -p "$TMP/outbox-state"
STUB_URL="$STUB_URL" OUTBOX_ROOT="$TMP/outbox-state" OUTBOX_LOG="$TMP/outbox-client.log" node "$ROOT/tests/fixtures/extauth-outbox-test.mjs" | tee "$TMP/outbox.out"
assert_contains "$(cat "$TMP/outbox.out")" "outbox tests:"
grep -q "moved to dead-letter" "$TMP/outbox-client.log" || fail "dead-lettering is logged as an error"
# every outbox record and state file: mode 0600 and no bearer or service token
n_records=0
while IFS= read -r -d '' f; do
  n_records=$((n_records + 1))
  mode="$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f")"
  [[ "$mode" == "600" ]] || fail "outbox file $f has mode $mode, expected 600"
done < <(find "$TMP/outbox-state" -path '*auth-outbox*' -type f -print0)
(( n_records > 0 )) || fail "the outbox tests left records to inspect"
for secret in "$SVC" "$TOKEN_OK" "$TOKEN_REVOKED" "$TOKEN_REVOCABLE" "$TOKEN_SHORT_EXP" "$TOKEN_SIBLING" "wrong-service-token"; do
  if grep -rlF -- "$secret" "$TMP/outbox-state"; then fail "a token leaked into the outbox files above"; fi
done
if grep -rl "MARKER" "$TMP/outbox-state"; then fail "a planted marker leaked into the outbox files above"; fi
echo "ok - outbox files are 0600 and contain no token ($n_records files)"

# --- lib/mcp/metering.js at the unit level (fake service, real local usage) ---
node --input-type=module - "$ROOT" "$TMP/metering-unit" <<'JS'
import assert from 'node:assert/strict';
import { readdirSync, statSync, readFileSync, existsSync } from 'node:fs';
const [root, dir] = process.argv.slice(2);
const { createMetering } = await import(`${root}/lib/mcp/metering.js`);
const { createUsage } = await import(`${root}/lib/mcp/usage.js`);
let n = 0; const ok = (m) => { n++; console.log(`ok - metering: ${m}`); };
const cost = { calls: 3, tokens: 3000 };
const spent = { calls: 2, inTokens: 400, outTokens: 100 };
function fakeExternal({ reserve } = {}) {
  const calls = { reserve: [], settle: [], release: [] };
  let settleOk = true;
  return {
    calls, setSettleOk: (v) => { settleOk = v; },
    async reserve(a) { calls.reserve.push(a); return reserve ? reserve(a, calls.reserve.length) : { ok: true, reservation_id: `res_${calls.reserve.length}`, expires_at: new Date().toISOString() }; },
    async settleDurable(p) { calls.settle.push(p); return { ok: settleOk }; },
    async releaseDurable(p) { calls.release.push(p); return { ok: true }; },
  };
}
const intents = (d) => (existsSync(`${d}/metering-intents`) ? readdirSync(`${d}/metering-intents`).filter((f) => f.endsWith('.json')) : []);

// no hook: plain delegation to the local usage object, nothing else on disk
{
  const d = `${dir}/nohook`; const u = createUsage({ env: { E3D_MCP_STATE_DIR: d, E3D_MCP_DAILY_CALLS: '5' } });
  const m = createMetering({ localUsage: u });
  assert.equal(m.hooked, false);
  const b = await m.begin('p', cost); assert.equal(b.ok, true); assert.equal(b.budget.calls_today, 3);
  const c = await m.commit(b.handle, spent); assert.equal(c.budget.calls_today, 2); assert.equal(c.billing, null);
  const r = await m.begin('p', { calls: 4, tokens: 1 }); assert.equal(r.ok, false); assert.equal(r.kind, 'local'); assert.match(r.reason, /only 3 of today's 5/);
  const b2 = await m.begin('p', cost); await m.abort(b2.handle); assert.equal((await u.snapshot('p')).calls_today, 2);
  assert.deepEqual(intents(d), []); assert.deepEqual(await m.recover(), { recovered: 0 });
  ok('without the hook it delegates to local usage unchanged');
}
// hook: external first; a refusal touches nothing locally
{
  const d = `${dir}/refused`; const u = createUsage({ env: { E3D_MCP_STATE_DIR: d } });
  const ext = fakeExternal({ reserve: () => ({ ok: false, code: 'insufficient_credits', message: 'no credits' }) });
  const m = createMetering({ localUsage: u, external: ext, dir: d });
  const r = await m.begin('acct', cost);
  assert.deepEqual([r.ok, r.kind, r.code, r.message], [false, 'billing', 'insufficient_credits', 'no credits']);
  assert.equal((await u.snapshot('acct')).calls_today, 0); assert.deepEqual(intents(d), []);
  ok('an external refusal returns its code and message and touches nothing locally');
}
// hook: the intent is on disk (0600, no secrets) before begin returns; the handle captures the principal
{
  const d = `${dir}/intent`; const u = createUsage({ env: { E3D_MCP_STATE_DIR: d } });
  const ext = fakeExternal(); const m = createMetering({ localUsage: u, external: ext, dir: d });
  const b = await m.begin('acct:one', cost, { tool: 'e3d_debate' });
  assert.equal(b.ok, true); assert.ok(Object.isFrozen(b.handle));
  const [f] = intents(d); assert.equal(f, `${b.handle.request_id}.json`);
  assert.equal(statSync(`${d}/metering-intents/${f}`).mode & 0o777, 0o600); assert.equal(statSync(`${d}/metering-intents`).mode & 0o777, 0o700);
  const it = JSON.parse(readFileSync(`${d}/metering-intents/${f}`, 'utf8'));
  assert.deepEqual(Object.keys(it).sort(), ['pid', 'principal', 'request_id', 'reservation_id', 'started_at', 'tool', 'units']);
  assert.deepEqual(it.units, { calls: 3, est_tokens: 3000 }); assert.equal(it.principal, 'acct:one');
  const c = await m.commit(b.handle, spent, { outcome: 'timeout', duration_ms: 1234, models: [{ provider: 'claude', model: 'unspecified', calls: 2 }] });
  assert.deepEqual(c.billing, { principal: 'acct:one', reservation_id: 'res_1' });
  assert.deepEqual(ext.calls.settle, [{ reservation_id: 'res_1', actual: { calls: 2, est_input_tokens: 400, est_output_tokens: 100 }, models: [{ provider: 'claude', model: 'unspecified', calls: 2 }], outcome: 'timeout', duration_ms: 1234 }]);
  assert.equal((await u.snapshot('acct:one')).calls_today, 2, 'local settle used the captured principal');
  assert.deepEqual(intents(d), [], 'removed once the settle is delivered');
  ok('intent persisted (0600) before begin returns; commit settles actual use with the captured principal');
}
// hook: zero actual calls is a release, never a settle
{
  const d = `${dir}/zero`; const u = createUsage({ env: { E3D_MCP_STATE_DIR: d } });
  const ext = fakeExternal(); const m = createMetering({ localUsage: u, external: ext, dir: d });
  const b = await m.begin('acct', cost);
  await m.commit(b.handle, { calls: 0, inTokens: 0, outTokens: 0 }, { outcome: 'error' });
  assert.deepEqual(ext.calls.settle, []); assert.deepEqual(ext.calls.release, [{ reservation_id: 'res_1', reason: 'zero_usage' }]);
  ok('zero actual calls releases');
}
// hook: a refused local cap releases the external hold
{
  const d = `${dir}/cap`; const u = createUsage({ env: { E3D_MCP_STATE_DIR: d, E3D_MCP_DAILY_CALLS: '2' } });
  const ext = fakeExternal(); const m = createMetering({ localUsage: u, external: ext, dir: d });
  const r = await m.begin('acct', cost);
  assert.equal(r.kind, 'local'); assert.deepEqual(ext.calls.release, [{ reservation_id: 'res_1', reason: 'local_cap' }]); assert.deepEqual(intents(d), []);
  ok('a refused local reserve releases the external reservation');
}
// hook: a failing local settle never skips the external settle
{
  const d = `${dir}/localfail`; const u = createUsage({ env: { E3D_MCP_STATE_DIR: d } });
  const broken = { ...u, reserve: u.reserve, settle: async () => { throw new Error('disk full'); } };
  const ext = fakeExternal(); const m = createMetering({ localUsage: broken, external: ext, dir: d });
  const b = await m.begin('acct', cost);
  const c = await m.commit(b.handle, spent, { outcome: 'ok' });
  assert.equal(c.budget, null); assert.equal(ext.calls.settle.length, 1);
  ok('local and external settlement are independent');
}
// hook: an external settle that is not yet durable keeps the intent; recover() replays the identical call
{
  const d = `${dir}/replay`; const u = createUsage({ env: { E3D_MCP_STATE_DIR: d } });
  const ext = fakeExternal(); const m = createMetering({ localUsage: u, external: ext, dir: d });
  const b = await m.begin('acct', cost);
  ext.setSettleOk(false); await m.commit(b.handle, spent, { outcome: 'ok', duration_ms: 50 });
  assert.equal(intents(d).length, 1, 'kept');
  ext.setSettleOk(true);
  const m2 = createMetering({ localUsage: u, external: ext, dir: d });
  assert.deepEqual(await m2.recover(), { recovered: 1 });
  assert.deepEqual(ext.calls.settle[1], ext.calls.settle[0], 'the same payload, so the service treats it as a no-op if it already arrived');
  assert.equal(m2.stats().settlements_replayed, 1); assert.equal(m2.stats().orphans, 0); assert.deepEqual(intents(d), []);
  assert.equal((await u.snapshot('acct')).calls_today, spent.calls, 'replay does not adjust the local counter a second time');
  // a crash before the local counter was settled: recovery settles it once
  {
    const d2 = `${dir}/replay-local`; const u2 = createUsage({ env: { E3D_MCP_STATE_DIR: d2 } });
    const ext2 = fakeExternal(); const ma = createMetering({ localUsage: u2, external: ext2, dir: d2 });
    await ma.begin('acct', cost); // reserves the worst case locally
    const f = `${d2}/metering-intents/${intents(d2)[0]}`; const rec = JSON.parse(readFileSync(f, 'utf8'));
    rec.pid = 999999999; rec.settlement = { call: 'settle', payload: { reservation_id: rec.reservation_id, actual: { calls: 2, est_input_tokens: 400, est_output_tokens: 100 }, models: [], outcome: 'ok', duration_ms: 5 } };
    (await import('node:fs')).writeFileSync(f, JSON.stringify(rec));
    await createMetering({ localUsage: u2, external: ext2, dir: d2 }).recover();
    assert.equal((await u2.snapshot('acct')).calls_today, 2, 'the worst-case local reservation is settled down to the actual use');
  }
  ok('an intent with a recorded settlement is replayed, not treated as an orphan');
}
// hook: orphan policies
for (const policy of ['charge', 'release']) {
  const d = `${dir}/orphan-${policy}`; const u = createUsage({ env: { E3D_MCP_STATE_DIR: d } });
  const ext = fakeExternal();
  await createMetering({ localUsage: u, external: ext, dir: d }).begin('acct', cost); // then "crash"
  const rec = JSON.parse(readFileSync(`${d}/metering-intents/${intents(d)[0]}`, 'utf8'));
  rec.pid = 999999999; // a process that is gone
  (await import('node:fs')).writeFileSync(`${d}/metering-intents/${intents(d)[0]}`, JSON.stringify(rec));
  const m = createMetering({ localUsage: u, external: ext, dir: d, env: { E3D_MCP_ORPHAN_POLICY: policy } });
  await m.recover();
  if (policy === 'charge') assert.deepEqual(ext.calls.settle, [{ reservation_id: 'res_1', actual: { calls: 3, est_input_tokens: 3000, est_output_tokens: 0 }, models: [], outcome: 'orphaned', duration_ms: 0 }]);
  else assert.deepEqual(ext.calls.release, [{ reservation_id: 'res_1', reason: 'orphaned' }]);
  assert.equal(m.stats().orphans, 1); assert.equal(m.stats()[`orphans_${policy === 'charge' ? 'charged' : 'released'}`], 1); assert.deepEqual(intents(d), []);
  assert.equal((await u.snapshot('acct')).calls_today, policy === 'charge' ? 3 : 0, `the local counter matches the external outcome under policy ${policy}`);
}
// crash boundaries of abort: the release decision is persisted before the local release, and the local release is keyed by
// the request id, so recovery after a crash at ANY point leaves the counter released exactly once and never charges the work
for (const crashAfterLocal of [false, true]) {
  const d = `${dir}/abort-crash-${crashAfterLocal}`; const u = createUsage({ env: { E3D_MCP_STATE_DIR: d } });
  const ext = fakeExternal(); const ma = createMetering({ localUsage: u, external: ext, dir: d });
  const b = await ma.begin('acct', cost); assert.equal((await u.snapshot('acct')).calls_today, 3);
  const f = `${d}/metering-intents/${intents(d)[0]}`; const rec = JSON.parse(readFileSync(f, 'utf8'));
  rec.pid = 999999999; rec.settlement = { call: 'release', payload: { reservation_id: rec.reservation_id, reason: 'not_run' } };
  (await import('node:fs')).writeFileSync(f, JSON.stringify(rec)); // "crashed" after persisting the decision
  if (crashAfterLocal) await u.release('acct', cost, 'debate', rec.request_id); // ...and after the local release
  const mr = createMetering({ localUsage: u, external: ext, dir: d, env: { E3D_MCP_ORPHAN_POLICY: 'charge' } });
  await mr.recover(); await createMetering({ localUsage: u, external: ext, dir: d }).recover();
  assert.equal((await u.snapshot('acct')).calls_today, 0, `released once (crash after local release: ${crashAfterLocal})`);
  assert.equal(ext.calls.settle.length, 0, 'unrun work is never charged'); assert.equal(ext.calls.release.length, 1);
}
ok('crash boundaries of abort: released once, never charged');
// two processes recovering one intent: it is reconciled exactly once (the loser sees the owner's lock or the removed file)
{
  const d = `${dir}/orphan-race`; const u = createUsage({ env: { E3D_MCP_STATE_DIR: d } });
  const ext = fakeExternal(); await createMetering({ localUsage: u, external: ext, dir: d }).begin('acct', cost);
  const f = `${d}/metering-intents/${intents(d)[0]}`; const rec = JSON.parse(readFileSync(f, 'utf8')); rec.pid = 999999999;
  (await import('node:fs')).writeFileSync(f, JSON.stringify(rec));
  const a = createMetering({ localUsage: u, external: ext, dir: d, env: { E3D_MCP_ORPHAN_POLICY: 'release' } });
  const b = createMetering({ localUsage: u, external: ext, dir: d, env: { E3D_MCP_ORPHAN_POLICY: 'release' } });
  await Promise.all([a.recover(), b.recover()]);
  assert.equal(ext.calls.release.length, 1, 'released once'); assert.equal((await u.snapshot('acct')).calls_today, 0, 'the local counter is released once, never twice');
  ok('concurrent recovery reconciles an intent exactly once');
}
// an intent of another live process is left alone
{
  const d = `${dir}/orphan-charge`; const u = createUsage({ env: { E3D_MCP_STATE_DIR: d } });
  const ext = fakeExternal(); await createMetering({ localUsage: u, external: ext, dir: d }).begin('acct', cost);
  const f = `${d}/metering-intents/${intents(d)[0]}`; const rec = JSON.parse(readFileSync(f, 'utf8')); rec.pid = process.ppid;
  (await import('node:fs')).writeFileSync(f, JSON.stringify(rec));
  await createMetering({ localUsage: u, external: ext, dir: d }).recover();
  assert.equal(ext.calls.settle.length, 0); assert.equal(intents(d).length, 1);
  ok('orphan policy charge settles the reserved units as orphaned; release releases; live processes are skipped');
}
// hook: an ambiguous reserve is retried with the same request_id; if never confirmed, released by request_id
{
  const d = `${dir}/ambig`; const u = createUsage({ env: { E3D_MCP_STATE_DIR: d } });
  const unavailable = Object.assign(new Error('timed out'), { kind: 'unavailable' });
  let ext = fakeExternal({ reserve: (a, i) => { if (i === 1) throw unavailable; return { ok: true, reservation_id: 'res_late', expires_at: new Date().toISOString() }; } });
  let m = createMetering({ localUsage: u, external: ext, dir: d, sleep: async () => {} });
  const b = await m.begin('acct', cost);
  assert.equal(b.ok, true); assert.equal(b.handle.reservation_id, 'res_late');
  assert.equal(ext.calls.reserve.length, 2); assert.equal(ext.calls.reserve[0].request_id, ext.calls.reserve[1].request_id);
  let t = 0;
  ext = fakeExternal({ reserve: () => { t += 1000; throw unavailable; } });
  m = createMetering({ localUsage: u, external: ext, dir: d, now: () => t, sleep: async () => {} });
  const r = await m.begin('acct', cost);
  assert.deepEqual([r.ok, r.kind], [false, 'unavailable']);
  assert.ok(ext.calls.reserve.every((a) => a.request_id === ext.calls.reserve[0].request_id), 'every retry uses the same request_id');
  assert.ok(ext.calls.reserve.length >= 2 && ext.calls.reserve.length <= 5, 'bounded by the budget');
  assert.deepEqual(ext.calls.release, [{ request_id: ext.calls.reserve[0].request_id, reason: 'reserve_unconfirmed' }]);
  assert.equal((await u.snapshot('acct')).calls_today, 3, 'only the first (confirmed) debate reserved locally');
  ok('an ambiguous reserve is retried with the same request_id, else released by request_id');
}
// hook: an outbox that cannot accept refuses before any reserve
{
  const d = `${dir}/bound`; const u = createUsage({ env: { E3D_MCP_STATE_DIR: d } });
  const ext = fakeExternal(); const m = createMetering({ localUsage: u, external: ext, outbox: { canAccept: () => false }, dir: d });
  const r = await m.begin('acct', cost);
  assert.deepEqual([r.ok, r.kind], [false, 'unavailable']); assert.equal(ext.calls.reserve.length, 0);
  ok('an outbox at its bound refuses new billed work before any reserve');
}
console.log(`metering unit tests: ${n} passed`);
JS

# ================= phase 3: the real server (--http) with the hook, against the stub; debate binary stubbed =================
SERVER="$ROOT/bin/e3d-mcp"
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-assert_eq}: expected [$2], got [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "${3:-assert_not_contains}: did not expect [$2] in [$1]"; }
TOKEN_BROKE="caller-MARKER-broke-$(openssl rand -hex 12)"; TOKEN_RATE="caller-MARKER-rate-$(openssl rand -hex 12)"
TOKEN_CAP="caller-MARKER-cap-$(openssl rand -hex 12)"; TOKEN_AB1="caller-MARKER-ab1-$(openssl rand -hex 12)"
TOKEN_AB2="caller-MARKER-ab2-$(openssl rand -hex 12)"; TOKEN_CRASH="caller-MARKER-crash-$(openssl rand -hex 12)"
SERVER_TOKENS=("$TOKEN_OK" "$TOKEN_SIBLING" "$TOKEN_REVOCABLE" "$TOKEN_BROKE" "$TOKEN_RATE" "$TOKEN_CAP" "$TOKEN_AB1" "$TOKEN_AB2" "$TOKEN_CRASH")
server_seed() {  # server_seed <sibling-tools-json|null>
  jq -n --arg ok "$TOKEN_OK" --arg sb "$TOKEN_SIBLING" --arg rc "$TOKEN_REVOCABLE" --arg br "$TOKEN_BROKE" --arg rt "$TOKEN_RATE" \
    --arg cp "$TOKEN_CAP" --arg a1 "$TOKEN_AB1" --arg a2 "$TOKEN_AB2" --arg cr "$TOKEN_CRASH" --argjson sbt "$1" '{accounts: [
    {principal: "acct_ok", balance: 1000000, keys: [
      {id: "key-ok", token: $ok, tools: ["e3d_debate", "e3d_usage"], limits: {rate_per_min: 60, max_inflight: 2}},
      ({id: "key-sibling", token: $sb} + (if $sbt then {tools: $sbt} else {} end)),
      {id: "key-revocable", token: $rc}]},
    {principal: "acct_broke", balance: 0, keys: [{id: "key-broke", token: $br}]},
    {principal: "acct_rate", balance: 1000000, keys: [{id: "key-rate", token: $rt, limits: {rate_per_min: 3}}]},
    {principal: "acct_cap", balance: 1000000, keys: [{id: "key-cap", token: $cp}]},
    {principal: "a:b", balance: 1000000, keys: [{id: "key-ab1", token: $a1}]},
    {principal: "a_b", balance: 1000000, keys: [{id: "key-ab2", token: $a2}]},
    {principal: "acct_crash", balance: 1000000, keys: [{id: "key-crash", token: $cr}]}]}'
}
server_seed null > "$TMP/seed-server.json"
server_seed '["e3d_usage"]' > "$TMP/seed-server-narrowed.json"

DEBATE="$TMP/stub-debate"; CALLS="$TMP/debate-calls"; MODE_FILE="$TMP/debate.mode"; STARTED="$TMP/debate.started"; : > "$CALLS"
cat > "$DEBATE" <<'STUBEOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do case "$1" in --out-dir) out="$2"; shift 2 ;; *) shift ;; esac; done
echo call >> "$STUB_CALLS"
mode="$(cat "$STUB_MODE_FILE" 2>/dev/null || echo ok)"
mkdir -p "$out"
round1() { printf '# Debate\n\n## Round 1 -- claude\n\nJSON file.\n\n## Round 1 -- codex\n\nSQLite.\n' > "$out/transcript.md"; }
case "$mode" in
  fail-early) echo "provider exploded before answering" >&2; exit 1 ;;
  partial) round1; exec sleep 8 ;;
  hang) round1; touch "$STUB_STARTED"; exec sleep 8 ;;
esac
round1
printf 'FINAL ANSWER: Use JSON.\nCONSENSUS: split\nDISSENT: Codex prefers SQLite.\n'
STUBEOF
chmod +x "$DEBATE"
echo ok > "$MODE_FILE"
ncalls() { wc -l < "$CALLS" | tr -d ' '; }

start_stub srv STUB_SEED="$TMP/seed-server.json"
SRV_URL="$STUB_URL"; SRV_PORT="${SRV_URL##*:}"; SRV_PID="${PIDS[${#PIDS[@]}-1]}"
ledger() { curl -fsS -H "authorization: Bearer $SVC" "$SRV_URL/_stub/state"; }
inject() { curl -fsS -X POST -H "authorization: Bearer $SVC" -H 'content-type: application/json' -d "$1" "$SRV_URL/_stub/inject" > /dev/null; }
n_res() { ledger | jq '.reservations | length'; }
res_of() { ledger | jq -c --arg r "$1" '.reservations[] | select(.reservation_id == $r)'; }

# start_server <name> [VAR=value ...]  -> PORT_<name>, PID_<name>; stderr appended to $TMP/<name>.log; state in $TMP/state-<name>
start_server() {
  local name="$1"; shift
  : > "$TMP/$name.port"
  env E3D_MCP_AUTH_URL="$SRV_URL" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" E3D_MCP_STATE_DIR="$TMP/state-$name" E3D_MCP_PORT_FILE="$TMP/$name.port" \
    E3D_MCP_DEBATE_BIN="$DEBATE" STUB_CALLS="$CALLS" STUB_MODE_FILE="$MODE_FILE" STUB_STARTED="$STARTED" TYPESAFE_API_KEY="" E3D_MCP_PRINCIPAL="" \
    E3D_MCP_AUTH_CACHE_SEC=1 E3D_MCP_TIMEOUT_SEC=2 E3D_MCP_AUTH_HEALTH_SEC=1 "$@" "$SERVER" --http --port 0 2>> "$TMP/$name.log" &
  local pid=$!; PIDS+=("$pid"); eval "PID_$name=$pid"
  for _ in $(seq 1 100); do [[ -s "$TMP/$name.port" ]] && break; sleep 0.1; done
  [[ -s "$TMP/$name.port" ]] || { cat "$TMP/$name.log" >&2; fail "server $name did not start"; }
  eval "PORT_$name=$(cat "$TMP/$name.port")"
}
sport() { local v="PORT_$1"; echo "${!v}"; }
# http <name> <path> <curl args...> -> "<status>\n<body>"; headers in $TMP/headers; every body is also kept in $TMP/bodies.out
http() {
  local name="$1" path="$2"; shift 2
  curl -s -m 60 -D "$TMP/headers" -o "$TMP/body" -w '%{http_code}' "$@" "http://127.0.0.1:$(sport "$name")$path"; echo; cat "$TMP/body"; echo
  { cat "$TMP/body"; echo; } >> "$TMP/bodies.out"
}
status() { head -1 <<< "$1"; }
body() { tail -n +2 <<< "$1"; }
hdr() { grep -i "^$1:" "$TMP/headers" | head -1 | sed -E 's/^[^:]+: *//' | tr -d '\r'; }
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"extauth-test","version":"0"}}}'
J=(-H 'content-type: application/json' -H 'accept: application/json')
init() { local srv="$1" tok="$2"; shift 2; http "$srv" /mcp -X POST "${J[@]}" -H "Authorization: Bearer $tok" "$@" -d "$INIT"; }   # init <server> <token> [extra curl args]
sid_of() { init "$1" "$2" > /dev/null; hdr mcp-session-id; }
rpc() { http "$1" /mcp -X POST "${J[@]}" -H "Authorization: Bearer $2" -H "mcp-session-id: $3" -d "$4"; }   # rpc <server> <token> <sid> <json>
ping() { rpc "$1" "$2" "$3" '{"jsonrpc":"2.0","id":3,"method":"ping"}'; }
tool() { rpc "$1" "$2" "$3" "$(jq -nc --arg n "$4" --argjson a "${5:-{\}}" '{jsonrpc:"2.0",id:7,method:"tools/call",params:{name:$n,arguments:$a}}')"; }
debate() { tool "$1" "$2" "$3" e3d_debate '{"question":"JSON or SQLite?","providers":["claude","codex"]}'; }
res() { body "$1" | jq -c .result.structuredContent; }
rtext() { body "$1" | jq -r '.result.content[0].text'; }
rerr() { body "$1" | jq -r '.result.isError // false'; }

# --- startup: the hook is hosted-only, and any configuration error refuses to start ---
rc=0; out="$(printf '' | E3D_MCP_AUTH_URL="$SRV_URL" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" "$SERVER" 2>&1)" || rc=$?
assert_eq "$rc" "2" "E3D_MCP_AUTH_URL without --http must refuse"; assert_contains "$out" "only supported in hosted mode"
out="$(E3D_MCP_AUTH_URL="$SRV_URL" E3D_MCP_AUTH_SERVICE_TOKEN="short-token" E3D_MCP_STATE_DIR="$TMP/state-bad" "$SERVER" --http --port 0 2>&1)" && fail "a short service token must refuse to start" || true
assert_contains "$out" "refusing to start"; assert_contains "$out" "shorter than 24"
out="$(E3D_MCP_AUTH_URL="http://auth.example.com" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" E3D_MCP_STATE_DIR="$TMP/state-bad" "$SERVER" --http --port 0 2>&1)" && fail "http: to a non-loopback host must refuse" || true
assert_contains "$out" "https"
out="$(E3D_MCP_AUTH_URL="$SRV_URL" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" E3D_MCP_ORPHAN_POLICY=forgive E3D_MCP_STATE_DIR="$TMP/state-bad" "$SERVER" --http --port 0 2>&1)" && fail "an unknown orphan policy must refuse" || true
assert_contains "$out" "E3D_MCP_ORPHAN_POLICY"
[[ ! -e "$TMP/state-bad/metering-intents" ]] || fail "nothing is set up when the configuration is refused"
echo "ok - startup refuses a bad hook configuration"

# --- server S1 ---
start_server S1 E3D_MCP_AUTH_TOKENS="alice:alice-static-token-0123456789"
assert_eq "$(grep -c 'E3D_MCP_AUTH_TOKENS is ignored' "$TMP/S1.log")" "1" "one warning line when E3D_MCP_AUTH_TOKENS is set with the hook"
assert_contains "$(cat "$TMP/S1.log")" "auth: external hook"
r="$(init S1 alice-static-token-0123456789)"; assert_eq "$(status "$r")" "401" "static tokens are ignored in hook mode"
r="$(http S1 /readyz)"; assert_eq "$(status "$r")" "200" "readyz when healthy"; assert_eq "$(body "$r" | jq -r .status)" "ready"
assert_not_contains "$r" "$SRV_PORT" "readyz reveals no URL"; assert_not_contains "$r" "$SVC"
echo "ok - startup warning, static tokens ignored, readyz ready"

# a valid key runs a debate; the ledger is charged the actual use
r="$(init S1 "$TOKEN_OK")"; assert_eq "$(status "$r")" "200"; SID_OK="$(hdr mcp-session-id)"
r="$(rpc S1 "$TOKEN_OK" "$SID_OK" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
assert_eq "$(body "$r" | jq -r '.result.tools | map(.name) | sort | join(",")')" "e3d_debate,e3d_usage" "the service narrows the operator's tools"
r="$(tool S1 "$TOKEN_OK" "$SID_OK" e3d_list_providers)"; assert_contains "$(body "$r" | jq -r .error.message)" "unknown tool" "a narrowed-away tool is refused"
before="$(ncalls)"; bal0="$(ledger | jq .accounts.acct_ok.balance)"
r="$(debate S1 "$TOKEN_OK" "$SID_OK")"; assert_eq "$(status "$r")" "200"; assert_eq "$(rerr "$r")" "false" "debate with a valid key"
sc="$(res "$r")"; RID="$(jq -r .billing.reservation_id <<< "$sc")"
assert_eq "$(jq -r .billing.principal <<< "$sc")" "acct_ok"; assert_eq "$(jq -r .budget.principal <<< "$sc")" "acct_ok" "usage keys use the service principal"
assert_eq "$(ncalls)" "$((before + 1))"
want=$(( $(jq '.usage.model_calls' <<< "$sc") + ( $(jq '.usage.est_input_tokens + .usage.est_output_tokens' <<< "$sc") + 999 ) / 1000 ))
assert_eq "$(res_of "$RID" | jq -r .state)" "settled"; assert_eq "$(res_of "$RID" | jq -r .charge)" "$want" "charged the actual use"
assert_eq "$(ledger | jq .accounts.acct_ok.balance)" "$((bal0 - want))" "balance reduced exactly once"
n_before="$(ncalls)"
r="$(rpc S1 "$TOKEN_OK" "$SID_OK" '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"e3d_debate","arguments":{"question":"JSON or SQLite?","providers":["claude","codex"]}}}')"; assert_eq "$(status "$r")" "400" "a tools/call without an id is refused, not run outside the in-flight accounting"
assert_eq "$(ncalls)" "$n_before" "the refused notification ran nothing"
r="$(rpc S1 "$TOKEN_OK" "$SID_OK" '{"jsonrpc":"2.0","method":"notifications/initialized"}')"; assert_eq "$(status "$r")" "202" "real notifications still work"
assert_eq "$(ledger | jq -r --arg r "$RID" '[.settlements[] | select(.reservation_id==$r)] | .[0].outcome')" "ok"
[[ -z "$(ls -A "$TMP/state-S1/metering-intents")" ]] || fail "the intent is removed once the settle is delivered"
echo "ok - valid key: debate charged the actual use ($want credits)"

# an invalid key: 401, the stub saw no reserve
n0="$(n_res)"; before="$(ncalls)"
r="$(init S1 "wrong-key-0123456789abcdef")"; assert_eq "$(status "$r")" "401"; assert_eq "$(hdr www-authenticate)" 'Bearer realm="e3d-mcp"'
r="$(debate S1 "wrong-key-0123456789abcdef" "$SID_OK")"; assert_eq "$(status "$r")" "401"
assert_eq "$(n_res)" "$n0" "no reserve for an invalid key"; assert_eq "$(ncalls)" "$before"
echo "ok - invalid key is 401 and reaches no reserve"

# two keys of one principal: separate sessions, one budget
r="$(init S1 "$TOKEN_SIBLING")"; SID_SIB="$(hdr mcp-session-id)"
r="$(rpc S1 "$TOKEN_SIBLING" "$SID_SIB" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
assert_eq "$(body "$r" | jq -r '.result.tools | map(.name) | sort | join(",")')" "e3d_debate,e3d_list_providers,e3d_usage" "no service narrowing = the operator's list"
r="$(ping S1 "$TOKEN_SIBLING" "$SID_OK")"; assert_eq "$(status "$r")" "404" "a session is bound to its token, even within one account"
r="$(tool S1 "$TOKEN_SIBLING" "$SID_SIB" e3d_usage)"; assert_eq "$(res "$r" | jq -r .calls_today)" "3" "two keys of one principal share one budget"
echo "ok - sessions bound to the token; sibling keys share the budget"

# a debate that times out after answering some rounds is charged those rounds
echo partial > "$MODE_FILE"
r="$(debate S1 "$TOKEN_SIBLING" "$SID_SIB")"; assert_eq "$(rerr "$r")" "true"; assert_contains "$(rtext "$r")" "timed out"
last="$(ledger | jq -c '.reservations[-1]')"
assert_eq "$(jq -r .state <<< "$last")" "settled"; assert_eq "$(ledger | jq -r '.settlements[-1].outcome')" "timeout"
[[ "$(jq -r .charge <<< "$last")" -ge 2 ]] || fail "the two answered rounds are charged: $last"
r="$(tool S1 "$TOKEN_SIBLING" "$SID_SIB" e3d_usage)"; assert_eq "$(res "$r" | jq -r .calls_today)" "5" "locally too"
# a debate that fails before any answer is released
echo fail-early > "$MODE_FILE"; before="$(ncalls)"
r="$(debate S1 "$TOKEN_SIBLING" "$SID_SIB")"; assert_eq "$(rerr "$r")" "true"; assert_contains "$(rtext "$r")" "debate failed"
assert_eq "$(ncalls)" "$((before + 1))"
last="$(ledger | jq -c '.reservations[-1]')"; assert_eq "$(jq -r .state <<< "$last")" "released"; assert_eq "$(jq -r .charge <<< "$last")" "0"
echo ok > "$MODE_FILE"
echo "ok - timeout charges the answered rounds; failure before any answer is released"

# a lost reserve response is recovered with the same request_id: one reservation, no unreleased hold
inject '{"mode":"drop-after-commit","calls":["reserve"],"count":1}'; n0="$(n_res)"
r="$(debate S1 "$TOKEN_OK" "$SID_OK")"; assert_eq "$(rerr "$r")" "false" "the debate runs after the reserve is recovered"
assert_eq "$(n_res)" "$((n0 + 1))" "exactly one reservation for the lost response"
assert_eq "$(res_of "$(res "$r" | jq -r .billing.reservation_id)" | jq -r .state)" "settled"; assert_eq "$(ledger | jq .accounts.acct_ok.holds)" "0"
# a reserve that never answers: nothing runs, the possible hold is released by request_id
inject '{"mode":"5xx","calls":["reserve"]}'; n0="$(n_res)"; before="$(ncalls)"
r="$(debate S1 "$TOKEN_OK" "$SID_OK")"; assert_eq "$(rtext "$r")" "error: billing: temporarily unavailable"
assert_eq "$(ncalls)" "$before" "no debate without a reservation id"; assert_eq "$(n_res)" "$n0"
inject '{"mode":null}'
assert_contains "$(cat "$TMP/S1.log")" "reserve unconfirmed"
echo "ok - lost reserve response recovered by request_id; an unanswered reserve runs nothing"

# insufficient_credits: the billing error, nothing runs
r="$(init S1 "$TOKEN_BROKE")"; SID_BROKE="$(hdr mcp-session-id)"; before="$(ncalls)"
r="$(debate S1 "$TOKEN_BROKE" "$SID_BROKE")"; assert_eq "$(rerr "$r")" "true"
[[ "$(rtext "$r")" == "error: billing: "*credits* ]] || fail "billing refusal text: $(rtext "$r")"
assert_eq "$(ncalls)" "$before"; assert_eq "$(ledger | jq .accounts.acct_broke.balance)" "0"
echo "ok - insufficient_credits returns the billing error and runs nothing"

# a refused local cap releases the external reservation (hosted default cap: 100 calls a day)
printf '{"day":"%s","calls":99,"est_input_tokens":0,"est_output_tokens":0,"debates":0}\n' "$(date -u +%Y-%m-%d)" > "$TMP/state-S1/acct_cap.json"
r="$(init S1 "$TOKEN_CAP")"; SID_CAP="$(hdr mcp-session-id)"; before="$(ncalls)"
r="$(debate S1 "$TOKEN_CAP" "$SID_CAP")"; assert_eq "$(rerr "$r")" "true"; assert_contains "$(rtext "$r")" "error: daily budget:" "local refusal text unchanged"
assert_eq "$(ncalls)" "$before"
assert_eq "$(ledger | jq -c '[.reservations[] | select(.principal=="acct_cap") | .state]')" '["released"]' "the external hold was released"
echo "ok - local cap refusal releases the external reservation"

# principals a:b and a_b never share a local file
r="$(init S1 "$TOKEN_AB1")"; S_AB1="$(hdr mcp-session-id)"; r="$(debate S1 "$TOKEN_AB1" "$S_AB1")"; assert_eq "$(rerr "$r")" "false"
r="$(init S1 "$TOKEN_AB2")"; S_AB2="$(hdr mcp-session-id)"; r="$(debate S1 "$TOKEN_AB2" "$S_AB2")"; assert_eq "$(rerr "$r")" "false"
assert_eq "$(jq .calls "$TMP/state-S1/a_b.json")" "3" "a_b has its own file"
hashed="$(ls "$TMP/state-S1" | grep -E '^a_b~[0-9a-f]{8}\.json$')" || fail "a:b gets a hashed file name"
assert_eq "$(jq .calls "$TMP/state-S1/$hashed")" "3" "a:b is counted separately"
echo "ok - a:b and a_b have separate state files"

# the service's lower rate limit is honored (3 a minute; the server allows 60)
r="$(init S1 "$TOKEN_RATE")"; S_RT="$(hdr mcp-session-id)"
for i in 2 3; do r="$(ping S1 "$TOKEN_RATE" "$S_RT")"; assert_eq "$(status "$r")" "200" "request $i of 3"; done
r="$(ping S1 "$TOKEN_RATE" "$S_RT")"; assert_eq "$(status "$r")" "429" "4th request in a minute"; [[ -n "$(hdr retry-after)" ]] || fail "retry-after"
echo "ok - the service's lower rate limit is honored"

# readiness: a dead-letter record makes it 503
DEAD="$TMP/state-S1/auth-outbox/dead/settle.reservation_id.x.json"
printf '{"record_id":"settle.reservation_id.x","created_at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$DEAD"
sleep 2.2; r="$(http S1 /readyz)"; assert_eq "$(status "$r")" "503" "dead-letter records"; assert_contains "$(body "$r")" "dead-letter"
mv "$DEAD" "$TMP/dead-record-handled.json"
sleep 2.2; r="$(http S1 /readyz)"; assert_eq "$(status "$r")" "200" "ready again once the operator acted"
echo "ok - readyz reports dead-letter records"

# revoking a key drops only its sessions; a sibling key of the same account keeps working
r="$(init S1 "$TOKEN_REVOCABLE")"; SID_RV="$(hdr mcp-session-id)"
r="$(ping S1 "$TOKEN_REVOCABLE" "$SID_RV")"; assert_eq "$(status "$r")" "200"
curl -fsS -X POST -H "authorization: Bearer $SVC" -H 'content-type: application/json' -d '{"key_id":"key-revocable"}' "$SRV_URL/_stub/revoke" > /dev/null
sleep 1.3   # the cache TTL (E3D_MCP_AUTH_CACHE_SEC=1)
r="$(ping S1 "$TOKEN_REVOCABLE" "$SID_RV")"; assert_eq "$(status "$r")" "401" "revoked within the cache TTL"
assert_contains "$(cat "$TMP/S1.log")" "dropped 1 session(s) of a token that is no longer active principal=acct_ok"
r="$(ping S1 "$TOKEN_SIBLING" "$SID_SIB")"; assert_eq "$(status "$r")" "200" "the sibling key keeps its session"
r="$(ping S1 "$TOKEN_SIBLING" "$SID_RV")"; assert_eq "$(status "$r")" "404" "the revoked key's session is gone"
echo "ok - revocation drops only that key's sessions"

# the service down: 503 with retry-after, no debate runs; readyz turns 503 from the background probe
kill "$SRV_PID"; wait "$SRV_PID" 2>/dev/null || true
sleep 1.3; before="$(ncalls)"
r="$(debate S1 "$TOKEN_SIBLING" "$SID_SIB")"; assert_eq "$(status "$r")" "503"; assert_eq "$(hdr retry-after)" "5"
assert_eq "$(ncalls)" "$before" "no debate when the service is down"
sleep 1.5; r="$(http S1 /readyz)"; assert_eq "$(status "$r")" "503"; assert_contains "$(body "$r")" "health check failed"
assert_not_contains "$r" "$SRV_PORT"
echo "ok - service down: 503, nothing runs, readyz 503"

# back up (same port) with key-sibling narrowed to e3d_usage: the existing session sees it on its next request
: > "$TMP/srv.url"; start_stub srv STUB_SEED="$TMP/seed-server-narrowed.json" STUB_PORT="$SRV_PORT"; SRV_PID="${PIDS[${#PIDS[@]}-1]}"
sleep 1.3
r="$(rpc S1 "$TOKEN_SIBLING" "$SID_SIB" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"; assert_eq "$(status "$r")" "200"
assert_eq "$(body "$r" | jq -r '.result.tools | map(.name) | join(",")')" "e3d_usage" "tools are recomputed on every request"
r="$(debate S1 "$TOKEN_SIBLING" "$SID_SIB")"; assert_contains "$(body "$r" | jq -r .error.message)" "unknown tool" "and enforced on the same session"
sleep 1.2; r="$(http S1 /readyz)"; assert_eq "$(status "$r")" "200" "ready once the probe succeeds again"
echo "ok - tools narrowed by the service and enforced per request"

# --- S3: unique-token storms stop at the per-IP limiter without reaching the service ---
start_server S3 E3D_MCP_AUTH_IP_PER_MIN=5
r="$(init S3 "$TOKEN_OK")"; assert_eq "$(status "$r")" "200"; S3_OK="$(hdr mcp-session-id)"    # a successful introspection does not count against the limit
intro0="$(grep -c '"call":"introspect"' "$TMP/srv.log" || true)"
codes=""; for i in $(seq 1 20); do r="$(init S3 "storm-$i-$(openssl rand -hex 8)")"; codes+="$(status "$r") "; done
r="$(init S3 "$(head -c 600 /dev/zero | tr '\0' 'x')")"; codes+="$(status "$r")"
assert_eq "$(tr ' ' '\n' <<< "$codes" | grep -c '^401$')" "5" "5 failed attempts are allowed per minute"
assert_eq "$(tr ' ' '\n' <<< "$codes" | grep -c '^429$')" "16" "the rest are stopped by the IP limiter"
intro1="$(grep -c '"call":"introspect"' "$TMP/srv.log" || true)"
[[ $((intro1 - intro0)) -le 5 ]] || fail "the storm reached the service $((intro1 - intro0)) times"
sleep 1.2; r="$(ping S3 "$TOKEN_OK" "$S3_OK")"; assert_eq "$(status "$r")" "200" "a known active key is not blocked by the storm"
echo "ok - unique-token storm stopped by the IP limiter ($((intro1 - intro0)) introspect calls reached the stub)"

# --- S3b: behind a trusted reverse proxy the limiter keys on the client address from X-Forwarded-For, not the proxy's ---
start_server S3B E3D_MCP_AUTH_IP_PER_MIN=3 E3D_MCP_TRUST_PROXY_HOPS=1
codes=""; for i in 1 2 3 4 5; do r="$(init S3B "bad-$i-$(openssl rand -hex 8)" -H "X-Forwarded-For: 198.51.100.7")"; codes+="$(status "$r") "; done
assert_eq "$(tr ' ' '\n' <<< "$codes" | grep -c '^429$')" "2" "one abusive client is stopped by its own address"
r="$(init S3B "$TOKEN_OK" -H "X-Forwarded-For: 203.0.113.9")"; assert_eq "$(status "$r")" "200" "another client behind the same proxy is not locked out"
r="$(init S3B "bad-x-$(openssl rand -hex 8)" -H "X-Forwarded-For: 203.0.113.9")"; assert_eq "$(status "$r")" "401" "and its own failures count separately"
echo "ok - the failed-key limiter is per client address behind a trusted proxy"

# --- S3c: a CONCURRENT storm cannot pass the per-IP check before any attempt has failed ---
start_server S3C E3D_MCP_AUTH_IP_PER_MIN=3
intro0="$(grep -c '"call":"introspect"' "$TMP/srv.log" || true)"
inject '{"mode":"slow","calls":["introspect"],"ms":1500}'
rm -rf "$TMP/storm"; mkdir -p "$TMP/storm"
storm_pids=()
for i in $(seq 1 12); do ( curl -s -m 30 -o /dev/null -w '%{http_code}' -X POST "${J[@]}" -H "Authorization: Bearer storm-c-$i-$(openssl rand -hex 8)" -d "$INIT" "http://127.0.0.1:$(sport S3C)/mcp" > "$TMP/storm/$i" ) & storm_pids+=($!); done
wait "${storm_pids[@]}"
inject '{"mode":null}'
c429="$(for f in "$TMP"/storm/*; do cat "$f"; echo; done | grep -c '^429$')"
intro1="$(grep -c '"call":"introspect"' "$TMP/srv.log" || true)"
[[ "$c429" -ge 9 ]] || fail "a concurrent storm of 12 got only $c429 refusals with a limit of 3"
[[ $((intro1 - intro0)) -le 3 ]] || fail "the concurrent storm reached the service $((intro1 - intro0)) times"
echo "ok - a concurrent unknown-token storm is bounded by the per-IP limit ($((intro1 - intro0)) introspect calls reached the stub)"

# --- S4: the outbox bound refuses new billed work ---
start_server S4 E3D_MCP_OUTBOX_MAX=1
r="$(init S4 "$TOKEN_OK")"; S4_OK="$(hdr mcp-session-id)"
inject '{"mode":"5xx","calls":["settle"]}'
r="$(debate S4 "$TOKEN_OK" "$S4_OK")"; assert_eq "$(rerr "$r")" "false" "the settle is queued, the debate result is returned"
RID4="$(res "$r" | jq -r .billing.reservation_id)"; assert_eq "$(res_of "$RID4" | jq -r .state)" "held"
[[ -n "$(ls "$TMP/state-S4/auth-outbox/pending")" ]] || fail "the settle is in the outbox"
[[ -z "$(ls -A "$TMP/state-S4/metering-intents")" ]] || fail "the intent is removed once the settle is durably enqueued"
before="$(ncalls)"
r="$(debate S4 "$TOKEN_OK" "$S4_OK")"; assert_eq "$(rtext "$r")" "error: billing: temporarily unavailable"; assert_eq "$(ncalls)" "$before" "nothing runs at the bound"
sleep 2.2; r="$(http S4 /readyz)"; assert_eq "$(status "$r")" "503"; assert_contains "$(body "$r")" "outbox is at its bound"
inject '{"mode":null}'
# deliver the queued settle (an hour later, past its backoff); the ledger is then charged exactly once
E3D_MCP_AUTH_URL="$SRV_URL" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" node --input-type=module - "$ROOT" "$TMP/state-S4" <<'JS'
const [root, dir] = process.argv.slice(2);
const { createExternalAuth } = await import(`${root}/lib/mcp/external-auth.js`);
const { createOutbox } = await import(`${root}/lib/mcp/outbox.js`);
const r = await createOutbox({ dir, auth: createExternalAuth({}), now: () => Date.now() + 3600e3 }).flush();
if (r.delivered.length !== 1) { console.error(JSON.stringify(r)); process.exit(1); }
JS
assert_eq "$(res_of "$RID4" | jq -r .state)" "settled"; assert_eq "$(ledger | jq --arg r "$RID4" '[.settlements[] | select(.reservation_id==$r)] | length')" "1"
r="$(debate S4 "$TOKEN_OK" "$S4_OK")"; assert_eq "$(rerr "$r")" "false" "accepting again once the outbox drained"
echo "ok - the outbox bound refuses new billed work; the queued settle is charged once"

# --- S5/S6: kill the server between reserve and the end of the debate; startup recovery applies the orphan policy ---
crash_run() {  # crash_run <name> [VAR=value...] -> CRASH_RID
  local name="$1"; shift
  mv -f "$STARTED" "$TMP/debate.started.old" 2>/dev/null || true
  echo hang > "$MODE_FILE"
  start_server "$name" "$@"
  local sid; sid="$(sid_of "$name" "$TOKEN_CRASH")"
  ( debate "$name" "$TOKEN_CRASH" "$sid" > /dev/null 2>&1 || true ) &
  for _ in $(seq 1 100); do [[ -e "$STARTED" ]] && break; sleep 0.05; done
  [[ -e "$STARTED" ]] || fail "the debate did not start on $name"
  local intent; intent="$(ls "$TMP/state-$name/metering-intents"/*.json)"
  local mode; mode="$(stat -f '%Lp' "$intent" 2>/dev/null || stat -c '%a' "$intent")"; assert_eq "$mode" "600" "intent file mode"
  CRASH_RID="$(jq -r .reservation_id "$intent")"; assert_eq "$(jq -r .principal "$intent")" "acct_crash"
  assert_eq "$(res_of "$CRASH_RID" | jq -r .state)" "held" "the hold exists while the debate runs"
  local pid="PID_$name"; kill -9 "${!pid}"; wait "${!pid}" 2>/dev/null || true
  echo ok > "$MODE_FILE"
}
crash_run S5
start_server S5
assert_eq "$(res_of "$CRASH_RID" | jq -r .state)" "settled" "startup recovery charged the orphan"
assert_eq "$(ledger | jq -r --arg r "$CRASH_RID" '.settlements[] | select(.reservation_id==$r) | .outcome')" "orphaned"
[[ "$(res_of "$CRASH_RID" | jq -r .charge)" -gt 0 ]] || fail "an orphan is never free"
[[ -z "$(ls -A "$TMP/state-S5/metering-intents")" ]] || fail "the recovered intent is removed"
assert_contains "$(cat "$TMP/S5.log")" "orphaned debate charged (policy charge)"
crash_run S6 E3D_MCP_ORPHAN_POLICY=release
start_server S6 E3D_MCP_ORPHAN_POLICY=release
assert_eq "$(res_of "$CRASH_RID" | jq -r .state)" "released" "the release policy releases the orphan"; assert_eq "$(res_of "$CRASH_RID" | jq -r .charge)" "0"
assert_contains "$(cat "$TMP/S6.log")" "orphaned debate released (policy release)"
echo "ok - crash recovery charges per policy (and releases when configured)"

# --- phase 4: e3d_usage in hook mode, --doctor, and the operator commands expose no credential and no URL path ---
r="$(tool S6 "$TOKEN_OK" "$(sid_of S6 "$TOKEN_OK")" e3d_usage)"; assert_eq "$(rerr "$r")" "false"
sc="$(res "$r")"
assert_eq "$(jq -r .billing.principal <<< "$sc")" "acct_ok"; jq -e '.outbox | has("pending") and has("claimed") and has("dead") and has("stale") and has("oldest_age_sec")' <<< "$sc" > /dev/null || fail "e3d_usage reports outbox counts"
assert_eq "$(jq -r .recovered_orphans <<< "$sc")" "1" "e3d_usage reports the orphan this server recovered"
for secret in "$SVC" "$TOKEN_OK" "http://" "127.0.0.1"; do assert_not_contains "$(rtext "$r")$sc" "$secret" "e3d_usage exposes nothing sensitive"; done
echo "ok - e3d_usage reports billing principal, outbox counts and recovered orphans"

OPDIR="$TMP/state-OP"; mkdir -p "$OPDIR"
node --input-type=module -e "
import { createOutbox } from '$ROOT/lib/mcp/outbox.js';
const ob = createOutbox({ dir: process.argv[1], auth: { settle() {}, release() {} } });
const settle = (id) => ({ reservation_id: id, actual: { calls: 2, est_input_tokens: 10, est_output_tokens: 5 }, models: [], outcome: 'ok', duration_ms: 5 });
await ob.enqueue('settle', settle('res_pending_1'));
await ob.enqueue('settle', settle('res_dead_1'), { dead: 'conflict from the service' });
await ob.enqueue('release', { reservation_id: 'res_dead_2', reason: 'aborted' }, { dead: 'conflict' });
" "$OPDIR"
opcmd() { env E3D_MCP_STATE_DIR="$OPDIR" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" TOKEN_PLANT="$TOKEN_OK" "$SERVER" "$@"; }
st="$(opcmd --outbox-status 2>&1)"
assert_contains "$st" "1 pending, 0 claimed, 2 dead"; assert_contains "$st" "settle.reservation_id.res_dead_1"; assert_contains "$st" "call=settle"; assert_contains "$st" "age="
assert_not_contains "$st" "est_input_tokens" "status prints no payload"
EXPORT="$TMP/op-export.json"
exp="$(opcmd --outbox-export "$EXPORT" 2>&1)"; assert_contains "$exp" "exported 3 record(s) (2 dead)"
mode="$(stat -f '%Lp' "$EXPORT" 2>/dev/null || stat -c '%a' "$EXPORT")"; assert_eq "$mode" "600" "export file mode"
assert_eq "$(jq '.records | length' "$EXPORT")" "3"; jq -e '.records[] | select(.record_id == "settle.reservation_id.res_dead_1") | .payload.actual.calls == 2' "$EXPORT" > /dev/null || fail "export carries payloads"
for secret in "$SVC" "$TOKEN_OK" "$TOKEN_SIBLING"; do assert_not_contains "$(cat "$EXPORT")" "$secret" "export has no token"; done
if opcmd --outbox-export "$EXPORT" > /dev/null 2>&1; then fail "export must not overwrite an existing file"; fi
for bad in "settle.reservation_id.res_dead" "res_dead_1" "settle.reservation_id.res_dead_*" "../pending/settle.reservation_id.res_pending_1" "settle.reservation_id.res_pending_1" "all" ""; do
  if opcmd --outbox-retry-dead "$bad" > "$TMP/retry-bad.out" 2>&1; then fail "retry-dead must refuse [$bad]"; fi
done
if opcmd --outbox-retry-dead > /dev/null 2>&1; then fail "retry-dead without an id must fail"; fi
assert_contains "$(opcmd --outbox-status 2>&1)" "1 pending, 0 claimed, 2 dead"
rt="$(opcmd --outbox-retry-dead settle.reservation_id.res_dead_1 2>&1)"; assert_contains "$rt" "moved settle.reservation_id.res_dead_1 back to pending"
st="$(opcmd --outbox-status 2>&1)"; assert_contains "$st" "2 pending, 0 claimed, 1 dead"
[[ -f "$OPDIR/auth-outbox/pending/settle.reservation_id.res_dead_1.json" ]] || fail "record is in pending"
jq -e 'has("dead_reason") | not' "$OPDIR/auth-outbox/pending/settle.reservation_id.res_dead_1.json" > /dev/null || fail "dead markers cleared"
for out in "$st" "$rt" "$exp"; do for secret in "$SVC" "$TOKEN_OK"; do assert_not_contains "$out" "$secret"; done; done
echo "ok - operator commands: status, export (0600, no token), retry-dead (exact id only)"

doc="$(env E3D_MCP_STATE_DIR="$OPDIR" E3D_MCP_AUTH_URL="$SRV_URL" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" "$SERVER" --doctor 2>&1 || true)"
assert_contains "$doc" "External auth and metering hook"; assert_contains "$doc" "service host: 127.0.0.1:$SRV_PORT"; assert_contains "$doc" "service token: present"
assert_contains "$doc" "auth service health answers"; assert_contains "$doc" "1 dead"; assert_contains "$doc" "release.reservation_id.res_dead_2"
pdoc="$(env E3D_MCP_STATE_DIR="$OPDIR" E3D_MCP_AUTH_URL="$SRV_URL/v1/PATHMARK-secret?x=1" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" "$SERVER" --doctor 2>&1 || true)"
doc2="$(env E3D_MCP_STATE_DIR="$OPDIR" E3D_MCP_AUTH_URL="$SRV_URL/v1/PATHMARK-secret" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" "$SERVER" --doctor 2>&1 || true)"
assert_contains "$doc2" "did not answer"
for out in "$doc" "$pdoc" "$doc2"; do
  for secret in "$SVC" "$TOKEN_OK" "PATHMARK"; do assert_not_contains "$out" "$secret" "--doctor exposes nothing sensitive"; done
  section="$(sed -n '/^External auth and metering hook/,/^Optional:/p' <<< "$out")"   # the provider list may legitimately show other URLs
  for secret in "http://" "https://" "/v1" "x=1"; do assert_not_contains "$section" "$secret" "--doctor hook section shows no URL path"; done
done
echo "ok - --doctor reports the hook, health and dead records without credentials or URL paths"

# the README documents every hook variable and the docs carry the checklist and the runbook
for v in E3D_MCP_AUTH_URL E3D_MCP_AUTH_SERVICE_TOKEN E3D_MCP_AUTH_SERVICE_TOKEN_FILE E3D_MCP_AUTH_CACHE_SEC E3D_MCP_AUTH_MAX_INFLIGHT E3D_MCP_AUTH_IP_PER_MIN E3D_MCP_AUTH_HEALTH_SEC E3D_MCP_OUTBOX_MAX E3D_MCP_OUTBOX_CLAIM_SEC E3D_MCP_ORPHAN_POLICY; do
  grep -q "| \`$v\` |" "$ROOT/README.md" || fail "README table is missing $v"
done
grep -q "^### Hosting with an external auth and metering service" "$ROOT/README.md" || fail "README section missing"
grep -q "^## Implementer's security checklist" "$ROOT/docs/external-auth.md" && grep -q "^## Operator runbook" "$ROOT/docs/external-auth.md" || fail "docs checklist/runbook missing"
echo "ok - README variables table and docs sections present"

# --- the ledger: never free, never double ---
ledger > "$TMP/ledger-final.json"
jq -e '[.settlements[].reservation_id] | (length == (unique | length))' "$TMP/ledger-final.json" > /dev/null || fail "a reservation was charged twice"
jq -e '[.reservations[] | select(.state == "held")] | length == 0' "$TMP/ledger-final.json" > /dev/null || fail "an unreleased hold is left: $(jq -c '[.reservations[] | select(.state=="held")]' "$TMP/ledger-final.json")"
echo "ok - final ledger: no double charge, no hold left behind"

# --- no token in server logs, results, intents, outbox records or state files ---
for secret in "$SVC" "${SERVER_TOKENS[@]}"; do
  if grep -rlF -- "$secret" "$TMP"/S*.log "$TMP/bodies.out" "$TMP"/state-S*; then fail "a token leaked into the files above"; fi
done
if grep -rl "MARKER" "$TMP"/S*.log "$TMP/bodies.out" "$TMP"/state-S*; then fail "a planted marker leaked into the files above"; fi
while IFS= read -r -d '' f; do
  mode="$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f")"; [[ "$mode" == "600" ]] || fail "$f has mode $mode, expected 600"
done < <(find "$TMP"/state-S* \( -path '*metering-intents*' -o -path '*auth-outbox*' \) -type f -print0)
echo "ok - no token in server logs, results or state; intents and records are 0600"

# --- no token in any captured log or output ---
for secret in "$SVC" "$TOKEN_OK" "$TOKEN_REVOKED" "$TOKEN_REVOCABLE" "$TOKEN_SHORT_EXP" "$TOKEN_SIBLING"; do
  if grep -rlF -- "$secret" "$TMP"/*.log "$TMP"/*.out; then fail "a token leaked into the logs above"; fi
done
if grep -rl "MARKER" "$TMP"/*.log "$TMP"/*.out; then fail "a planted marker leaked into the logs above"; fi
[[ -s "$TMP/client.log" && -s "$TMP/conf.log" && -s "$TMP/outbox-client.log" ]] || fail "logs were captured"
echo "ok - no token in captured logs"

echo "mcp-extauth: all tests passed"
