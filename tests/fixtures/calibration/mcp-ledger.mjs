// Unit cases for lib/calibration/mcp-ledger.mjs. Deterministic: fake clock, seeded RNG, no file, no network, no model.
import assert from 'node:assert/strict';
import { createLedger, MAX_OUTSTANDING, ISSUE_PER_WINDOW, WRITES_PER_WINDOW, PAUSE_MS, TICKET_MS, MAX_SUPERSESSIONS } from '../../../lib/calibration/mcp-ledger.mjs';

const cases = [];
const test = (name, fn) => cases.push([name, fn]);

// seeded xorshift: deterministic, not sequential
const seeded = (seed = 12345) => (n) => { const b = Buffer.alloc(n); let s = seed; for (let i = 0; i < n; i++) { s ^= s << 13; s >>>= 0; s ^= s >>> 17; s ^= s << 5; s >>>= 0; b[i] = s & 255; } seed = s; return b; };
const mk = (over = {}) => { const clock = { t: 1_000_000_000_000 }; const l = createLedger({ now: () => clock.t, rng: seeded(), sessionId: 'sess-a', ...over }); return { l, clock }; };
const S = { id: 'skeptic', version: '1.0.0', definition_hash: 'sha256:aaaa' };
const issueOne = (l, skill = S) => { const r = l.issue({ skill }); assert.equal(r.ok, true, JSON.stringify(r)); return r.use_id; };

test('issue: format use_ + 32 hex, 24 h, bound to skill, hash, time and session', () => {
  const { l, clock } = mk();
  const r = l.issue({ skill: S, task_class: 'code-review' });
  assert.match(r.use_id, /^use_[0-9a-f]{32}$/); assert.equal(r.expires_in_hours, 24);
  const t = l.lookup(r.use_id).ticket;
  assert.deepEqual(t.skill, S); assert.equal(t.session_id, 'sess-a'); assert.equal(t.issued_at, clock.t); assert.equal(t.expires_at, clock.t + TICKET_MS); assert.equal(t.task_class, 'code-review');
  assert.equal(l.isPersisted(r.use_id), false);
});
test('issue: refuses a malformed skill or task_class', () => {
  const { l } = mk();
  assert.equal(l.issue({}).code, 'invalid_ticket'); assert.equal(l.issue({ skill: { id: 'x', version: '1' } }).code, 'invalid_ticket');
  for (const tc of ['ab', 'Has Space', 'x'.repeat(41), 'a;rm -rf', 7]) assert.equal(l.issue({ skill: S, task_class: tc }).code, 'invalid_task_class', String(tc));
});
test('unknown id: same answer for absent, malformed and wrong type', () => {
  const { l } = mk();
  for (const id of ['use_' + '0'.repeat(32), 'use_abcd', '', null, undefined, 42, {}, 'USE_' + 'a'.repeat(32)]) assert.deepEqual(l.lookup(id), { ok: false, code: 'skill_use_not_found' });
});
test('foreign session: an id used from another session is not found', () => {
  const { l } = mk(); const id = issueOne(l);
  assert.deepEqual(l.lookup(id, { session_id: 'sess-b' }), { ok: false, code: 'skill_use_not_found' });
  assert.equal(l.lookup(id, { session_id: 'sess-a' }).ok, true);
});
test('foreign session: another ledger (another process) has no such ticket', () => {
  const a = mk().l, b = createLedger({ sessionId: 'sess-b', rng: seeded(99) }); const id = issueOne(a);
  assert.equal(b.lookup(id).code, 'skill_use_not_found');
});
test('foreign skill, version or hash: not found, identical answer', () => {
  const { l } = mk(); const id = issueOne(l);
  for (const skill of [{ ...S, id: 'other' }, { ...S, version: '1.0.1' }, { ...S, definition_hash: 'sha256:bbbb' }]) assert.deepEqual(l.lookup(id, { skill }), { ok: false, code: 'skill_use_not_found' });
  assert.equal(l.lookup(id, { skill: S }).ok, true);
});
test('expired: valid just before 24 h, not found at 24 h, and no longer counted', () => {
  const { l, clock } = mk(); const id = issueOne(l);
  clock.t += TICKET_MS - 1; assert.equal(l.lookup(id).ok, true);
  clock.t += 1; assert.deepEqual(l.lookup(id), { ok: false, code: 'skill_use_not_found' }); assert.equal(l.outstanding(), 0);
});
test('replay: a persisted ticket is still found in-session, is flagged, and never changes identity', () => {
  const { l } = mk(); const id = issueOne(l);
  assert.equal(l.markPersisted(id).ok, true); assert.equal(l.markPersisted(id).ok, true);
  assert.equal(l.isPersisted(id), true); assert.deepEqual(l.lookup(id).ticket.skill, S);
  assert.equal(l.markPersisted('use_' + '1'.repeat(32)).code, 'skill_use_not_found');
});
test('replay: a returned ticket copy cannot be used to alter the ledger', () => {
  const { l } = mk(); const id = issueOne(l); const t = l.lookup(id).ticket; t.skill.id = 'evil'; t.session_id = 'x';
  assert.equal(l.lookup(id, { skill: S }).ok, true);
});
test('supersession cap: 3 per use, then refused', () => {
  const { l } = mk(); const id = issueOne(l);
  for (let i = 1; i <= MAX_SUPERSESSIONS; i++) assert.equal(l.noteSupersession(id).count, i);
  assert.equal(l.noteSupersession(id).code, 'supersession_cap'); assert.equal(l.noteSupersession('use_' + '2'.repeat(32)).code, 'skill_use_not_found');
});
test('ids are not sequential or guessable: 500 ids are distinct, differ in many digits, neighbours share no structure', () => {
  const { l, clock } = mk({ limits: { issuePerWindow: 1000, maxOutstanding: 1000 } }); const ids = [];
  for (let i = 0; i < 500; i++) { ids.push(issueOne(l)); clock.t += 1; }
  assert.equal(new Set(ids).size, 500);
  const n = (id) => BigInt('0x' + id.slice(4));
  let sequential = 0, closeCount = 0;
  for (let i = 1; i < ids.length; i++) { const d = n(ids[i]) - n(ids[i - 1]); if (d === 1n || d === -1n) sequential++; if ((d < 0n ? -d : d) < 1n << 64n) closeCount++; }
  assert.equal(sequential, 0, 'no consecutive ids'); assert.ok(closeCount < 5, `neighbouring ids are far apart (${closeCount} close)`);
  const a = ids[0], b = ids[1]; let same = 0; for (let i = 4; i < a.length; i++) if (a[i] === b[i]) same++; assert.ok(same < 20, 'prefixes are not shared');
});
test('ids come from the injected rng: 16 bytes per id; the id is never a counter', () => {
  const calls = []; const l = createLedger({ now: () => 0, sessionId: 's', rng: (n) => { calls.push(n); return Buffer.alloc(n, calls.length); } });
  const r = l.issue({ skill: S }); assert.equal(r.use_id, 'use_' + '01'.repeat(16)); assert.ok(calls.includes(16));
  const r2 = l.issue({ skill: S }); assert.notEqual(r2.use_id, r.use_id, 'a colliding draw is redrawn');
});
test('collision: an id already in the ledger is redrawn, never reused', () => {
  let k = 0; const l = createLedger({ now: () => 0, sessionId: 's', rng: (n) => Buffer.alloc(n, k++ < 3 ? 7 : k) }); // session 8 bytes, id1, then id2 first draw collides
  const a = l.issue({ skill: S }).use_id, b = l.issue({ skill: S }).use_id; assert.notEqual(a, b);
});
test('cap: 64 outstanding tickets, the 65th is refused, and an expiry frees a slot', () => {
  const { l, clock } = mk({ limits: { issuePerWindow: 10000 } });
  for (let i = 0; i < MAX_OUTSTANDING; i++) { issueOne(l); clock.t += 1000; }
  const r = l.issue({ skill: S }); assert.equal(r.code, 'ticket_cap'); assert.ok(r.retry_after_s >= 1); assert.equal(l.outstanding(), MAX_OUTSTANDING);
  clock.t += TICKET_MS - 64 * 1000 + 1; assert.equal(l.issue({ skill: S }).ok, true);
});
test('loop limit: 20 issues per 10 minutes, then rate_limited with a retry hint, then free again', () => {
  const { l, clock } = mk({ limits: { maxOutstanding: 1000 } });
  for (let i = 0; i < ISSUE_PER_WINDOW; i++) issueOne(l);
  const r = l.issue({ skill: S }); assert.equal(r.code, 'rate_limited'); assert.ok(r.retry_after_s > 0 && r.retry_after_s <= 600);
  clock.t += 10 * 60 * 1000 + 1; assert.equal(l.issue({ skill: S }).ok, true);
});
test('loop limit: 30 write attempts per hour, then rate_limited, then free again', () => {
  const { l, clock } = mk();
  for (let i = 0; i < WRITES_PER_WINDOW; i++) assert.equal(l.admitWrite().ok, true);
  const r = l.admitWrite(); assert.equal(r.code, 'rate_limited'); assert.equal(r.reason, 'write_rate');
  clock.t += 3600 * 1000 + 1; assert.equal(l.admitWrite().ok, true);
});
test('decline pause: a decline blocks writes for 10 minutes, then expires', () => {
  const { l, clock } = mk(); assert.equal(l.admitWrite().ok, true);
  l.noteDecline();
  let r = l.admitWrite(); assert.equal(r.code, 'rate_limited'); assert.equal(r.reason, 'paused'); assert.ok(r.retry_after_s <= 600 && r.retry_after_s > 590);
  clock.t += PAUSE_MS - 1; assert.equal(l.admitWrite().ok, false);
  clock.t += 1; assert.equal(l.admitWrite().ok, true); assert.equal(l.writesPausedUntil(), 0);
});
test('decline pause: reads are never blocked (pause, refusal streak, write rate)', () => {
  const { l } = mk(); const id = issueOne(l);
  l.noteDecline(); for (let i = 0; i < 10; i++) l.noteRefusal();
  assert.equal(l.admitRead().ok, true); assert.equal(l.lookup(id).ok, true); assert.equal(l.issue({ skill: S }).ok, true, 'a fetch is not a write');
});
test('refusal streak: 5 refusals in a row pause writes; an accepted write resets the streak', () => {
  const { l } = mk();
  for (let i = 0; i < 4; i++) l.noteRefusal(); l.noteAccepted(); for (let i = 0; i < 4; i++) l.noteRefusal();
  assert.equal(l.admitWrite().ok, true);
  l.noteRefusal(); assert.equal(l.admitWrite().ok, false);
});
test('one pending elicitation per process: a second is refused until the first is done, done is idempotent', () => {
  const { l } = mk(); const a = l.beginElicitation('use_a'); assert.equal(a.ok, true); assert.equal(l.elicitationPending(), true);
  assert.equal(l.beginElicitation('use_b').code, 'elicitation_pending'); assert.equal(l.beginElicitation('use_a').code, 'elicitation_pending');
  a.done(); a.done(); assert.equal(l.elicitationPending(), false);
  const b = l.beginElicitation('use_b'); assert.equal(b.ok, true); a.done(); assert.equal(l.elicitationPending(), true, 'a stale done does not release the next one'); b.done();
});
test('concurrency: calls on one use_id run one after another, in order, even when an earlier one fails', async () => {
  const { l } = mk(); const log = []; const gate = (ms, tag, fail) => () => new Promise((res, rej) => setTimeout(() => { log.push(tag); fail ? rej(new Error(tag)) : res(tag); }, ms));
  const p = [l.serialize('use_x', gate(30, 'a')), l.serialize('use_x', gate(1, 'b', true)), l.serialize('use_x', gate(1, 'c'))];
  const r = await Promise.allSettled(p); assert.deepEqual(log, ['a', 'b', 'c']); assert.deepEqual(r.map((x) => x.status), ['fulfilled', 'rejected', 'fulfilled']);
});
test('concurrency: different use_ids do not wait for each other', async () => {
  const { l } = mk(); const log = [];
  await Promise.all([l.serialize('use_x', () => new Promise((r) => setTimeout(() => { log.push('slow'); r(); }, 40))), l.serialize('use_y', async () => { log.push('fast'); })]);
  assert.deepEqual(log, ['fast', 'slow']);
});
test('concurrency: 100 simultaneous issues never exceed the cap and never share an id', async () => {
  const { l } = mk({ limits: { issuePerWindow: 1000 } });
  const rs = await Promise.all(Array.from({ length: 100 }, () => Promise.resolve().then(() => l.issue({ skill: S }))));
  const ok = rs.filter((r) => r.ok); assert.equal(ok.length, MAX_OUTSTANDING); assert.equal(new Set(ok.map((r) => r.use_id)).size, MAX_OUTSTANDING); assert.ok(rs.filter((r) => !r.ok).every((r) => r.code === 'ticket_cap'));
});

let failed = 0;
for (const [name, fn] of cases) {
  try { await fn(); console.log(`ok   ${name}`); } catch (e) { failed++; console.log(`FAIL ${name}\n     ${String(e.message).split('\n')[0]}`); }
}
console.log(`${cases.length - failed}/${cases.length} passed`);
process.exit(failed ? 1 : 0);
