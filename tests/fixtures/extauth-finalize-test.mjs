// Debate contract v1 (finalize, fetch, authorize-run): the contract pins, the client, the outbox record type and metering,
// against two reference stubs (tests/mcp-extauth.sh starts them).
// Environment: STUB_URL (advertises finalize, fetch, authorize-run), LEGACY_URL (advertises nothing), SVC_TOKEN, TOKEN_OK
// (an active key of acct_ok on both), STATE_ROOT (scratch directory), CLIENT_LOG (every log line is appended here).
import assert from 'node:assert/strict';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { appendFileSync, cpSync, existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createExternalAuth, SCHEMAS, schemaOf, validateSchema, canonicalJson, DEBATE_CONTRACT_VERSION, FEATURES } from '../../lib/mcp/external-auth.js';
import { createOutbox, fitFinalizeBody, truncateTranscript, outboxStatus, outboxExport, recordIdFor } from '../../lib/mcp/outbox.js';
import { createMetering, newDebateId, questionFitsContract } from '../../lib/mcp/metering.js';
import { createUsage } from '../../lib/mcp/usage.js';

const E = process.env;
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SCHEMA_DIR = join(ROOT, 'docs', 'external-auth');
const keepAlive = setInterval(() => {}, 1000); // the client's timers are unref'd; a test waiting only on them must not exit early
const lines = [];
const log = (l) => { lines.push(l); if (E.CLIENT_LOG) appendFileSync(E.CLIENT_LOG, `${l}\n`); };
let n = 0; const ok = (m) => { n++; console.log(`ok - finalize: ${m}`); };
const client = (url = E.STUB_URL, extra = {}) => createExternalAuth({ url, serviceToken: E.SVC_TOKEN, env: {}, log, ...extra });
const admin = async (path, body) => {
  const r = await fetch(`${E.STUB_URL}${path}`, body === undefined ? { headers: { authorization: `Bearer ${E.SVC_TOKEN}` } }
    : { method: 'POST', headers: { authorization: `Bearer ${E.SVC_TOKEN}`, 'content-type': 'application/json' }, body: JSON.stringify(body) });
  return r.json();
};
const state = () => admin('/_stub/state');
const inject = (mode, calls = ['finalize'], count = 1, ms) => admin('/_stub/inject', { mode, calls, count, ...(ms ? { ms } : {}) });
const raw = (url, call, body) => fetch(`${url}/${call}`, { method: 'POST', headers: { authorization: `Bearer ${E.SVC_TOKEN}`, 'x-e3d-auth-version': '1', 'content-type': 'application/json' }, body: typeof body === 'string' ? body : JSON.stringify(body) });
const reserve = async (auth, principal = 'acct_ok') => {
  const r = await auth.reserve({ principal, request_id: randomUUID(), kind: 'debate', tool: 'e3d_debate', units: { calls: 3, est_tokens: 3000 } });
  assert.equal(r.ok, true); return r.reservation_id;
};
const dir = (name) => { const d = join(E.STATE_ROOT, name); mkdirSync(d, { recursive: true }); return d; };
const MARK = randomBytes(4).toString('hex');
// planted content: none of these may appear in a log line, a stats object, a listing or an export
const Q = `QCONTENT-${MARK} a JSON file or SQLite?`;
const A = `ACONTENT-${MARK} use a JSON file`;
const T = `# Debate\n\n## Round 1 -- claude\n\nTCONTENT-${MARK} JSON file.\n\n## Round 1 -- codex\n\nSQLite.\n`;
const CONTENT = [`QCONTENT-${MARK}`, `ACONTENT-${MARK}`, `TCONTENT-${MARK}`];
const noContent = (where, text) => { for (const c of CONTENT) assert.ok(!String(text).includes(c), `${where} contains debate content`); };
const result = (final_answer = A) => ({ final_answer, consensus: 'split', dissent: 'codex prefers SQLite', positions: [{ provider: 'claude', model: 'unspecified', position: 'JSON file.' }, { provider: 'codex', model: 'unspecified', position: 'SQLite.' }] });
const body = (reservation_id, extra = {}) => ({
  reservation_id, debate_id: newDebateId(), source: 'connector', outcome: 'ok', actual: { calls: 2, est_input_tokens: 1200, est_output_tokens: 300 },
  models: [{ provider: 'claude', model: 'unspecified', calls: 2 }], duration_ms: 1500, question: Q, providers: ['claude', 'codex'], rounds: 1,
  result: result(), transcript: T, truncated: false, started_at: '2026-10-18T12:00:00.000Z', finished_at: '2026-10-18T12:00:01.500Z', ...extra,
});
const effectsOf = async (rid) => (await state()).effects.filter((e) => e.reservation_id === rid);
const balance = async (p = 'acct_ok') => (await state()).accounts[p].balance;

// ================= the contract pins =================
function verifyContract(d) {
  const [head, ...rest] = readFileSync(join(d, 'CONTRACT-VERSION'), 'utf8').trim().split('\n');
  assert.equal(head, `debate-contract ${DEBATE_CONTRACT_VERSION}`, 'contract version line');
  const pinned = rest.map((l) => { const [hash, file] = l.split(/\s+/); return { hash, file }; });
  for (const { hash, file } of pinned) assert.equal(createHash('sha256').update(readFileSync(join(d, file))).digest('hex'), hash, `${file} does not match its SHA-256 in CONTRACT-VERSION`);
  return pinned.map((p) => p.file).sort();
}
{
  assert.deepEqual(verifyContract(SCHEMA_DIR), ['authorize-run.schema.json', 'debate-fixtures.json', 'fetch.schema.json', 'finalize.schema.json'], 'every contract file is pinned');
  for (const call of FEATURES) assert.deepEqual(JSON.parse(readFileSync(join(SCHEMA_DIR, `${call}.schema.json`), 'utf8')), SCHEMAS[call], `${call}.schema.json equals the client's schema`);
  // a changed byte is detected
  const copy = dir('contract-copy'); cpSync(SCHEMA_DIR, copy, { recursive: true });
  writeFileSync(join(copy, 'finalize.schema.json'), readFileSync(join(copy, 'finalize.schema.json'), 'utf8').replace('"maxLength": 8000', '"maxLength": 9000'));
  assert.throws(() => verifyContract(copy), /finalize.schema.json does not match/);
  const fx = JSON.parse(readFileSync(join(SCHEMA_DIR, 'debate-fixtures.json'), 'utf8'));
  assert.equal(fx.contract_version, DEBATE_CONTRACT_VERSION); assert.deepEqual(fx.features, [...FEATURES]);
  for (const v of fx.canonical_json) assert.equal(canonicalJson(v.input), v.canonical);
  assert.equal(canonicalJson({ 9: 1, 10: 2, b: [{ y: 1, x: 2 }] }), '{"10":2,"9":1,"b":[{"x":2,"y":1}]}', 'integer-like keys sort by code unit, not numerically');
  for (const v of fx.transcript_truncation) assert.deepEqual(truncateTranscript(v.transcript, v.max_bytes), { transcript: v.expected, truncated: v.truncated });
  for (const [where, set] of [['request', fx.requests], ['response', fx.responses]]) {
    for (const [call, { valid, invalid }] of Object.entries(set)) {
      valid.forEach((x, i) => assert.deepEqual(validateSchema(schemaOf(call, where), x), [], `${call} ${where} valid[${i}]`));
      invalid.forEach((x, i) => assert.ok(validateSchema(schemaOf(call, where), x).length > 0, `${call} ${where} invalid[${i}] must be rejected`));
    }
  }
  assert.ok(questionFitsContract('😀'.repeat(8000)) && !questionFitsContract('a'.repeat(8001)) && !questionFitsContract('bell \u0007') && questionFitsContract('tab\tLF\nCR\r'), 'questions are counted in Unicode scalar values; only tab, LF and CR are allowed controls');
  ok('CONTRACT-VERSION and the fixture hashes match; canonical JSON, truncation and schema examples agree with the fixtures');
}

// ================= features (capability advertisement) =================
{
  const legacy = client(E.LEGACY_URL);
  assert.equal((await legacy.introspect(E.TOKEN_OK)).active, true);
  assert.deepEqual([...legacy.features()], []); assert.equal(legacy.hasFeature('finalize'), false);
  const full = client();
  assert.deepEqual([...(await full.introspect(E.TOKEN_OK)).features], ['finalize', 'fetch', 'authorize-run']);
  assert.deepEqual([...full.features()], ['finalize', 'fetch', 'authorize-run']);
  // the reverse skew: a feature this server does not know is ignored, the known ones are kept
  let answer = { active: true, principal: 'acct_ok', features: ['fetch', 'x-future-call', 'finalize'] };
  const fake = (status, payload, headers = {}) => async () => new Response(typeof payload === 'string' ? payload : JSON.stringify(payload), { status, headers: { 'content-type': 'application/json', ...headers } });
  const skew = client('http://127.0.0.1:9', { fetchImpl: async () => fake(200, answer)() });
  await skew.introspect('caller-token-0123456789abcdef');
  assert.deepEqual([...skew.features()], ['finalize', 'fetch'], 'unknown features ignored');
  answer = { active: true, principal: 'acct_ok' };
  await skew.introspect('caller-token-0123456789abcdeX');
  assert.deepEqual([...skew.features()], [], 'an answer without features means legacy again');
  answer = { active: true, principal: 'acct_ok', features: 'finalize' };
  await assert.rejects(skew.introspect('caller-token-0123456789abcdeY'), (e) => e.kind === 'bad-response', 'features must be an array');
  assert.deepEqual(skew.stats().features, []);
  ok('features: absent = legacy; parsed from introspect; unknown values ignored; malformed refused');
}

// ================= the client calls: transport, limits, validation, coded answers =================
const auth = client(); await auth.introspect(E.TOKEN_OK);
{
  let calledWith = 0;
  const hang = client('http://127.0.0.1:9', { timeouts: { finalize: 60, fetch: 60 }, fetchImpl: (_u, init) => { calledWith++; return new Promise((_r, rej) => init.signal.addEventListener('abort', () => rej(new Error('aborted')))); } });
  await assert.rejects(hang.finalize(body('rsv_x')), (e) => e.kind === 'unavailable' && /timed out after 60 ms/.test(e.message));
  // request cap and request validation: nothing is sent
  calledWith = 0;
  const over = body('rsv_x', { transcript: '"'.repeat(480 * 1024 - 10) }); // schema-valid, but JSON escaping doubles it past 512 KB
  await assert.rejects(hang.finalize(over), (e) => e instanceof TypeError && /exceeds 524288 bytes/.test(e.message), 'a body over 512 KB is refused before sending');
  await assert.rejects(hang.finalize(body('rsv_x', { result: null })), /invalid finalize request/, 'ok without a result is invalid');
  await assert.rejects(hang.finalize(body('rsv_x', { outcome: 'error' })), /invalid finalize request/, 'error with a result is invalid');
  await assert.rejects(hang.fetchDebate({ debate_id: 'dbt_1', principal: 'acct_ok', include_transcript: false }), /invalid fetch request/);
  await assert.rejects(hang.authorizeRun({ reservation_id: 'rsv_x' }), /invalid authorize-run request/);
  assert.equal(calledWith, 0, 'invalid requests never reach the network');
  // response cap: 2 MB for fetch, 64 KB elsewhere
  const big = client('http://127.0.0.1:9', { fetchImpl: async () => new Response('x'.repeat(2 * 1024 * 1024 + 10), { status: 200 }) });
  await assert.rejects(big.fetchDebate({ debate_id: newDebateId(), principal: 'acct_ok', include_transcript: true }), (e) => e.kind === 'bad-response' && /larger than 2097152/.test(e.message));
  // coded answers: a retryable code is thrown as unavailable; a terminal one is returned; an uncoded error status is a service failure
  const coded = (status, payload) => client('http://127.0.0.1:9', { fetchImpl: async () => new Response(typeof payload === 'string' ? payload : JSON.stringify(payload), { status }) });
  await assert.rejects(coded(503, { ok: false, code: 'not_ready' }).finalize(body('rsv_x')), (e) => e.kind === 'unavailable' && /not_ready/.test(e.message));
  await assert.rejects(coded(503, { ok: false, code: 'unavailable' }).finalize(body('rsv_x')), (e) => e.kind === 'unavailable');
  await assert.rejects(coded(503, '<html>bad gateway</html>').finalize(body('rsv_x')), (e) => e.kind === 'unavailable' && /HTTP 503/.test(e.message));
  await assert.rejects(coded(404, { error: 'not_found' }).finalize(body('rsv_x')), (e) => e.kind === 'unavailable', 'a 404 without a contract answer (a service that lacks the call) is a service failure, never terminal');
  await assert.rejects(coded(409, { ok: false, code: 'not_found' }).finalize(body('rsv_x')), (e) => e.kind === 'unavailable', 'a code with the wrong status is not a contract answer');
  assert.deepEqual(await coded(409, { ok: false, code: 'conflict' }).finalize(body('rsv_x')), { ok: false, code: 'conflict' });
  assert.deepEqual(await coded(404, { ok: false, code: 'not_found' }).fetchDebate({ debate_id: newDebateId(), principal: 'acct_ok', include_transcript: false }), { ok: false, code: 'not_found' });
  await assert.rejects(coded(200, { ok: true, stored: false, charged: 3 }).finalize(body('rsv_x')), (e) => e.kind === 'bad-response', 'stored:false with a charge is a schema violation');
  // redirects are refused
  await inject('redirect');
  await assert.rejects(auth.finalize(body(await reserve(auth))), (e) => e.kind === 'unavailable' && /redirect refused/.test(e.message));
  await inject(null);
  ok('client: timeouts, request and response caps, schema validation before sending, coded answers, redirect refusal');
}

// ================= finalize at the stub: charge only with a stored result, idempotent per reservation =================
let OWNED;
{
  const rid = await reserve(auth); const b = body(rid); const bal = await balance();
  const a = await auth.finalize(b);
  assert.deepEqual(a, { ok: true, stored: true, charged: 4 }, 'ok: stored and charged (2 calls + 2 k-tokens)');
  assert.equal(await balance(), bal - 4);
  assert.deepEqual(await auth.finalize(structuredClone(b)), a, 'the same body again: the original answer');
  assert.deepEqual(await auth.finalize({ ...b, x_future_field: undefined }), a);
  assert.deepEqual(await auth.finalize({ ...b, duration_ms: 1501 }), { ok: false, code: 'conflict' }, 'a different body: conflict');
  assert.deepEqual(await auth.finalize(body(await reserve(auth), { debate_id: b.debate_id })), { ok: false, code: 'conflict' }, 'a debate_id bound to another reservation: conflict');
  assert.equal((await effectsOf(rid)).length, 1, 'one effect'); assert.equal(await balance(), bal - 4, 'charged once');
  OWNED = b;
  // stored:false (the debate was deleted while it ran) charges zero and releases the hold
  const rid2 = await reserve(auth); const b2 = body(rid2);
  await admin('/_stub/tombstone', { debate_id: b2.debate_id });
  const bal2 = await balance();
  assert.deepEqual(await auth.finalize(b2), { ok: true, stored: false, charged: 0 });
  assert.equal(await balance(), bal2); const r2 = (await state()).reservations.find((r) => r.reservation_id === rid2);
  assert.deepEqual([r2.state, r2.hold], ['released', 0], 'the hold is released');
  // error and timeout: the failed price (default 0), stored without a result; zero calls charge zero
  const rid3 = await reserve(auth); const b3 = body(rid3, { outcome: 'error', result: null });
  assert.deepEqual(await auth.finalize(b3), { ok: true, stored: true, charged: 0 });
  const f3 = await auth.fetchDebate({ debate_id: b3.debate_id, principal: 'acct_ok', include_transcript: false });
  assert.deepEqual([f3.debate.status, f3.debate.outcome, f3.debate.result], ['failed', 'error', null]);
  assert.deepEqual(await auth.finalize(body(await reserve(auth), { actual: { calls: 0, est_input_tokens: 0, est_output_tokens: 0 }, models: [] })), { ok: true, stored: true, charged: 0 });
  assert.deepEqual(await auth.finalize(body(`res_unknown_${MARK}`)), { ok: false, code: 'not_found' });
  // malformed and oversized bodies are refused by the service with their codes
  let r = await raw(E.STUB_URL, 'finalize', { ...body(rid3), result: null });
  assert.deepEqual([r.status, await r.json()], [400, { ok: false, code: 'invalid' }]);
  r = await raw(E.STUB_URL, 'finalize', '{"not json');
  assert.deepEqual([r.status, await r.json()], [400, { ok: false, code: 'invalid' }]);
  r = await raw(E.STUB_URL, 'finalize', { ...body(rid3), transcript: 'x'.repeat(600 * 1024) });
  assert.deepEqual([r.status, await r.json()], [413, { ok: false, code: 'too_large' }]);
  // the legacy stub has no such call: a plain 404, which the client treats as a service failure
  r = await raw(E.LEGACY_URL, 'finalize', body(rid3)); assert.equal(r.status, 404); assert.equal((await r.json()).ok, undefined);
  ok('finalize: ok charged only with stored:true; stored:false charges zero; replay = same answer, one effect; conflict, not_found, invalid, too_large');
}

// ================= fetch and authorize-run =================
{
  const own = await auth.fetchDebate({ debate_id: OWNED.debate_id, principal: 'acct_ok', include_transcript: false });
  assert.equal(own.ok, true); assert.equal(own.debate.result.final_answer, A); assert.equal(own.debate.question, Q);
  assert.ok(!('transcript' in own.debate), 'no transcript unless asked');
  const full = await auth.fetchDebate({ debate_id: OWNED.debate_id, principal: 'acct_ok', include_transcript: true });
  assert.equal(full.debate.transcript, T);
  const foreign = await raw(E.STUB_URL, 'fetch', { debate_id: OWNED.debate_id, principal: 'acct_broke', include_transcript: true });
  const unknown = await raw(E.STUB_URL, 'fetch', { debate_id: newDebateId(), principal: 'acct_ok', include_transcript: true });
  const [fb, ub] = [await foreign.text(), await unknown.text()];
  assert.deepEqual([foreign.status, unknown.status], [404, 404]); assert.equal(fb, ub, 'a foreign debate and an unknown one answer identically');
  assert.deepEqual(await auth.fetchDebate({ debate_id: OWNED.debate_id, principal: 'acct_broke', include_transcript: false }), { ok: false, code: 'not_found' });
  let r = await raw(E.STUB_URL, 'fetch', { debate_id: OWNED.debate_id, principal: 'acct_ok' });
  assert.deepEqual([r.status, await r.json()], [400, { ok: false, code: 'invalid' }]);
  // a large stored transcript (over 64 KB) comes back through the 2 MB fetch cap
  const rid = await reserve(auth); const sections = Array.from({ length: 40 }, (_, i) => `## Round 1 -- p${i}\n\n${'w'.repeat(10000)}\n`).join('\n');
  const bigBody = body(rid, { transcript: `# Debate\n\n${sections}` });
  assert.equal((await auth.finalize(bigBody)).stored, true);
  assert.equal((await auth.fetchDebate({ debate_id: bigBody.debate_id, principal: 'acct_ok', include_transcript: true })).debate.transcript, bigBody.transcript);
  // authorize-run: the same pair gets the same answer; any other pairing is a conflict
  const rid2 = await reserve(auth); const d2 = newDebateId();
  const a = await auth.authorizeRun({ reservation_id: rid2, debate_id: d2 });
  assert.equal(a.ok, true); assert.equal(a.principal, 'acct_ok'); assert.equal(a.status, 'reserved'); assert.ok(a.price_credits > 0);
  assert.deepEqual(await auth.authorizeRun({ reservation_id: rid2, debate_id: d2 }), a);
  assert.deepEqual(await auth.authorizeRun({ reservation_id: rid2, debate_id: newDebateId() }), { ok: false, code: 'conflict' });
  assert.deepEqual(await auth.authorizeRun({ reservation_id: await reserve(auth), debate_id: d2 }), { ok: false, code: 'conflict' });
  assert.deepEqual(await auth.authorizeRun({ reservation_id: `res_unknown_${MARK}`, debate_id: newDebateId() }), { ok: false, code: 'not_found' });
  assert.deepEqual(await auth.finalize(body(rid2)), { ok: false, code: 'conflict' }, 'finalize must use the bound debate id');
  // a web debate created before its run: bound, and visible to its owner as queued
  const rid3 = await reserve(auth); const d3 = newDebateId();
  await admin('/_stub/web-debate', { reservation_id: rid3, debate_id: d3, question: Q });
  assert.equal((await auth.authorizeRun({ reservation_id: rid3, debate_id: d3 })).status, 'bound');
  const q = await auth.fetchDebate({ debate_id: d3, principal: 'acct_ok', include_transcript: true });
  assert.deepEqual([q.debate.status, q.debate.outcome, q.debate.result, q.debate.finished_at, q.debate.transcript], ['queued', null, null, null, null]);
  ok('fetch: the owner reads it (transcript only when asked), foreign and unknown are identical not_found; authorize-run binds immutably');
}

// ================= the outbox: the finalize record type =================
{
  // fitting a body: the transcript is cut at a section boundary to 480 KB, the body stays under 512 KB
  const sections = Array.from({ length: 120 }, (_, i) => `## Round ${i} -- claude\n\n${'s'.repeat(8000)}\n`);
  const long = `# Debate\n\n${sections.join('\n')}`;
  const fitted = fitFinalizeBody(body('rsv_fit', { transcript: long }));
  assert.ok(Buffer.byteLength(fitted.transcript) <= 480 * 1024 && fitted.truncated === true);
  assert.ok(long.startsWith(fitted.transcript) && long.slice(fitted.transcript.length).startsWith('\n## '), 'cut at a section boundary');
  assert.ok(Buffer.byteLength(JSON.stringify(fitted)) <= 512 * 1024);
  // JSON escaping doubles quotes: the body is cut further until the whole JSON fits
  const quoted = `# Debate\n\n${Array.from({ length: 60 }, (_, i) => `## Round ${i} -- claude\n\n${'"'.repeat(7000)}\n`).join('\n')}`;
  const q = fitFinalizeBody(body('rsv_fit', { transcript: quoted }));
  assert.ok(Buffer.byteLength(JSON.stringify(q)) <= 512 * 1024 && q.truncated && quoted.startsWith(q.transcript));
  assert.equal(fitFinalizeBody(body('rsv_fit')).truncated, false, 'a small body is unchanged');
  assert.equal(fitFinalizeBody(body('rsv_fit', { result: result('x'.repeat(600 * 1024)) })), null, 'metadata alone over the limit does not fit');
  assert.equal(recordIdFor('finalize', { reservation_id: 'res_1' }), 'finalize.reservation_id.res_1');

  // a queued finalize that is later answered stored:false tells the hook (so the run store drops its local copy)
  {
    const seen = [];
    const fakeAuth = { settle: async () => ({ ok: true }), release: async () => ({ ok: true }), finalize: async () => ({ ok: true, stored: false, charged: 0 }) };
    const hooked = createOutbox({ dir: dir('outbox-hook'), auth: fakeAuth, log, env: {} });
    hooked.setFinalizeHook((x) => { seen.push(x); });
    const hb = body(`rsv_hook_${MARK}`);
    await hooked.enqueue('finalize', hb);
    await hooked.flush();
    assert.deepEqual(seen, [{ debate_id: hb.debate_id, stored: false }], 'the hook hears about the unstored debate');
    const stored = createOutbox({ dir: dir('outbox-hook2'), auth: { ...fakeAuth, finalize: async () => ({ ok: true, stored: true, charged: 3 }) }, log, env: {} });
    const seen2 = []; stored.setFinalizeHook((x) => { seen2.push(x); });
    await stored.enqueue('finalize', body(`rsv_hook2_${MARK}`)); await stored.flush();
    assert.deepEqual(seen2, [], 'a stored debate does not trigger the hook');
  }
  const d = dir('outbox');
  const ob = createOutbox({ dir: d, auth, log, env: {} }); auth.attachOutbox(ob);
  // one immutable logical intent per reservation
  const rid = await reserve(auth); const b = body(rid);
  assert.equal((await ob.enqueue('finalize', b)).queued, true);
  assert.equal((await ob.enqueue('finalize', structuredClone(b))).duplicate, true);
  const c = await ob.enqueue('finalize', { ...b, outcome: 'error', result: null });
  assert.equal(c.conflict, true); assert.match(c.record_id, /^conflict-[0-9a-f]{8}\.finalize\.reservation_id\./);
  const conflictRec = JSON.parse(readFileSync(join(ob.dir, 'dead', `${c.record_id}.json`), 'utf8'));
  assert.equal(conflictRec.payload.content_removed, true); noContent('a conflict dead record', JSON.stringify(conflictRec));
  await assert.rejects(ob.enqueue('finalize', body('res_big', { transcript: '"'.repeat(480 * 1024) })), /exceeds/, 'an unfitted oversized body is refused');
  for (const f of readdirSync(join(ob.dir, 'pending'))) assert.equal(statSync(join(ob.dir, 'pending', f)).mode & 0o777, 0o600);
  // delivery: identical replay at the service keeps one effect
  let fl = await ob.flush(); assert.deepEqual(fl.delivered, [`finalize.reservation_id.${rid}`]);
  assert.equal((await effectsOf(rid)).length, 1);
  // retryable answers back off and are delivered later; the record is kept
  for (const mode of ['not_ready', 'unavailable', '5xx']) {
    const r = await reserve(auth); await inject(mode);
    const q1 = await auth.finalizeDurable(body(r));
    assert.deepEqual([q1.ok, q1.delivered, q1.queued, q1.dead], [true, false, true, false], `${mode} is retried`);
    const rec = JSON.parse(readFileSync(join(ob.dir, 'pending', `finalize.reservation_id.${r}.json`), 'utf8'));
    assert.equal(rec.attempts, 1); assert.ok(Date.parse(rec.next_attempt_at) > Date.now() + 20000, 'backoff');
    const later = createOutbox({ dir: d, auth, log, env: {}, now: () => Date.now() + 3600e3 }); // a restart, an hour later
    fl = await later.flush(); assert.ok(fl.delivered.includes(`finalize.reservation_id.${r}`), `${mode} delivered after the outage`);
    assert.equal((await effectsOf(r)).length, 1);
  }
  // a lost answer (the service committed, the server never heard): the redelivery is a no-op at the service
  const lost = await reserve(auth); await inject('drop-after-commit'); const bal = await balance();
  assert.equal((await auth.finalizeDurable(body(lost))).queued, true);
  await createOutbox({ dir: d, auth, log, env: {}, now: () => Date.now() + 3600e3 }).flush();
  const st = await state();
  assert.equal(st.finalize_requests[lost], 2, 'delivered twice'); assert.equal((await effectsOf(lost)).length, 1, 'one effect');
  assert.equal(await balance(), bal - 4, 'charged once');
  // a terminal answer is dead-lettered (ids and code only) and does not block the records behind it
  const dead = body(`res_unknown_${MARK}_2`); const behind = await reserve(auth);
  await ob.enqueue('finalize', dead); await ob.enqueue('finalize', body(behind));
  fl = await ob.flush();
  assert.deepEqual(fl.dead, [`finalize.reservation_id.res_unknown_${MARK}_2`]); assert.ok(fl.delivered.includes(`finalize.reservation_id.${behind}`), 'the record behind it is delivered');
  const deadRec = JSON.parse(readFileSync(join(ob.dir, 'dead', `finalize.reservation_id.res_unknown_${MARK}_2.json`), 'utf8'));
  assert.equal(deadRec.dead_reason, 'service answered not_found'); assert.equal(deadRec.payload.content_removed, true);
  assert.deepEqual(deadRec.payload.actual, dead.actual); assert.equal(deadRec.payload.debate_id, dead.debate_id); noContent('a dead record', JSON.stringify(deadRec));
  assert.equal((await ob.enqueue('finalize', dead)).duplicate, true, 'a replay of a dead-lettered intent is recognized, not a new conflict');
  // a stripped terminal finalize is audit only: it must not trip the dead-letter cap and wedge every later billed debate
  assert.equal(deadRec.stripped, true);
  assert.equal(ob.canAccept(), true, 'a permanent finalize refusal does not stop new billed work');
  { const st0 = await ob.stats(); assert.equal(st0.dead, 0); assert.ok(st0.dead_terminal >= 1, 'it is still listed, as terminal'); }
  // finalizeDurable with a terminal answer: dead-lettered at once, never retried
  const fd = await auth.finalizeDurable(body(`res_unknown_${MARK}_3`));
  assert.deepEqual([fd.delivered, fd.dead], [false, true], 'recorded in dead/ (durable, like a dead settle), not queued for retry');
  assert.ok(!existsSync(join(ob.dir, 'pending', `finalize.reservation_id.res_unknown_${MARK}_3.json`)));
  // no content in stats, the status listing or the export
  const s = await ob.stats(); noContent('outbox stats', JSON.stringify(s)); assert.equal(s.counters.finalized_stored, 2, "this instance delivered two");
  const status = await outboxStatus(d); noContent('--outbox-status', status.lines.join('\n')); assert.ok(status.lines.some((l) => l.includes('call=finalize')));
  await ob.enqueue('finalize', body(await reserve(auth))); // one pending with content
  const exp = join(d, 'export.json'); await outboxExport(d, exp); const ex = readFileSync(exp, 'utf8');
  noContent('--outbox-export', ex); assert.ok(JSON.parse(ex).records.some((r) => r.call === 'finalize' && r.payload.content_omitted === true && r.payload.actual));
  ok('outbox: one intent per reservation, retry with backoff, duplicate delivery = one effect, permanent answers dead-letter (content removed) without blocking, no content in listings');

  // the total byte cap refuses new work, never drops a record
  const capped = createOutbox({ dir: dir('outbox-cap'), auth, log, env: { E3D_MCP_OUTBOX_MAX_BYTES: '3000' } });
  assert.equal(capped.canAccept(), true);
  await capped.enqueue('finalize', body(await reserve(auth), { transcript: `${T}${'z'.repeat(4000)}` }));
  assert.equal(capped.canAccept(), false); const cs = await capped.stats();
  assert.equal(cs.accepting, false); assert.ok(cs.bytes > 3000 && cs.byte_bound === 3000);
  await createOutbox({ dir: join(E.STATE_ROOT, 'outbox-cap'), auth, log, env: {} }).flush();
  assert.equal(capped.canAccept(), true, 'accepting again once delivered');
  ok('outbox: E3D_MCP_OUTBOX_MAX_BYTES refuses new billed work at the bound until delivery drains it');
}

// ================= metering: finalize instead of settle =================
const intents = (d) => (existsSync(`${d}/metering-intents`) ? readdirSync(`${d}/metering-intents`).filter((f) => f.endsWith('.json')) : []);
const cost = { calls: 3, tokens: 3000 };
const spent = { calls: 2, inTokens: 1200, outTokens: 300 };
const debate = { question: Q, providers: ['claude', 'codex'], rounds: 1 };
function hooked(name, ext = auth) {
  const d = dir(name); const u = createUsage({ env: { E3D_MCP_STATE_DIR: d } });
  const ob = createOutbox({ dir: d, auth: ext, log, env: {} }); ext.attachOutbox(ob);
  return { d, u, ob, m: createMetering({ localUsage: u, external: ext, outbox: ob, log, dir: d, env: {} }) };
}
{
  const { d, u, m } = hooked('meter-ok');
  assert.equal(m.finalizeEnabled(), true);
  const b = await m.begin('acct_ok', cost, { tool: 'e3d_debate', debate });
  assert.equal(b.ok, true); assert.equal(b.handle.finalize, true); assert.match(b.handle.debate_id, /^dbt_[0-9a-f]{24}$/);
  const it = JSON.parse(readFileSync(`${d}/metering-intents/${intents(d)[0]}`, 'utf8'));
  assert.equal(it.finalize, true); assert.equal(it.debate_id, b.handle.debate_id); assert.equal(statSync(`${d}/metering-intents/${intents(d)[0]}`).mode & 0o777, 0o600);
  await m.start(b.handle);
  const settles0 = (await state()).settlements.filter((x) => x.call !== 'finalize').length;
  const c = await m.commit(b.handle, spent, { outcome: 'ok', duration_ms: 900, models: [{ provider: 'claude', model: 'unspecified', calls: 2 }], result: result(), transcript: T });
  assert.deepEqual(c.billing, { principal: 'acct_ok', reservation_id: b.handle.reservation_id, debate_id: b.handle.debate_id, stored: true, charged: 4 });
  assert.equal((await state()).settlements.filter((x) => x.call !== 'finalize').length, settles0, 'no settle is ever sent');
  const f = await auth.fetchDebate({ debate_id: b.handle.debate_id, principal: 'acct_ok', include_transcript: true });
  assert.deepEqual([f.debate.outcome, f.debate.result.final_answer, f.debate.question, f.debate.transcript], ['ok', A, Q, T]);
  assert.deepEqual(intents(d), []); assert.equal((await u.snapshot('acct_ok')).calls_today, 2, 'the local counter is settled to actual use');
  // zero calls: still one finalize (not a release), charged zero
  const z = await m.begin('acct_ok', cost, { debate }); await m.start(z.handle);
  const zc = await m.commit(z.handle, { calls: 0, inTokens: 0, outTokens: 0 }, { outcome: 'error' });
  assert.deepEqual([zc.billing.stored, zc.billing.charged], [true, 0]); assert.equal((await effectsOf(z.handle.reservation_id)).length, 1);
  // ok without a result is an error; an answer too large to store is finalized as an error, never charged as a result
  const e = await m.begin('acct_ok', cost, { debate }); await m.start(e.handle);
  await m.commit(e.handle, spent, { outcome: 'ok' });
  assert.equal((await auth.fetchDebate({ debate_id: e.handle.debate_id, principal: 'acct_ok', include_transcript: false })).debate.outcome, 'error');
  const big = await m.begin('acct_ok', cost, { debate }); await m.start(big.handle);
  const bc = await m.commit(big.handle, spent, { outcome: 'ok', result: result('x'.repeat(25000)), transcript: T });
  assert.equal(bc.billing.charged, 0); assert.equal(m.stats().finalize_unfit, 1);
  const bf = await auth.fetchDebate({ debate_id: big.handle.debate_id, principal: 'acct_ok', include_transcript: true });
  assert.deepEqual([bf.debate.outcome, bf.debate.result, bf.debate.truncated], ['error', null, true]);
  // a huge transcript is cut and flagged
  const tr = await m.begin('acct_ok', cost, { debate }); await m.start(tr.handle);
  await m.commit(tr.handle, spent, { outcome: 'ok', result: result(), transcript: `# Debate\n\n${Array.from({ length: 80 }, (_, i) => `## Round 1 -- p${i}\n\n${'t'.repeat(9000)}\n`).join('\n')}` });
  const tf = (await state()).debates.find((x) => x.debate_id === tr.handle.debate_id);
  assert.equal(tf.truncated, true); assert.ok(tf.transcript_bytes <= 480 * 1024 && tf.has_result);
  // a question that cannot be finalized is refused before anything is reserved
  const n0 = (await state()).reservations.length;
  const bad = await m.begin('acct_ok', cost, { debate: { ...debate, question: 'bell \u0007 inside' } });
  assert.deepEqual([bad.ok, bad.kind], [false, 'invalid']); assert.equal((await state()).reservations.length, n0, 'nothing reserved');
  ok('metering: with finalize advertised every outcome is one finalize (never settle); ok carries the result; zero calls charge zero; unfit results become errors; bad questions refused before reserve');
}
{
  // an outage at commit: the finalize is queued durably and the intent removed; delivery later charges once
  const { d, m } = hooked('meter-outage');
  const b = await m.begin('acct_ok', cost, { debate }); await m.start(b.handle);
  await inject('5xx', ['finalize'], 100);
  const c = await m.commit(b.handle, spent, { outcome: 'ok', result: result(), transcript: T });
  assert.equal(c.billing.queued, true); assert.deepEqual(intents(d), [], 'durable in the outbox, so the intent goes');
  await inject(null);
  await createOutbox({ dir: d, auth, log, env: {}, now: () => Date.now() + 3600e3 }).flush();
  assert.deepEqual((await effectsOf(b.handle.reservation_id)).map((x) => [x.stored, x.charged]), [[true, 4]]);
  ok('metering: a finalize during an outage is queued and delivered once afterwards');
}
{
  // a crash after the models started and before an outcome: recovery finalizes as error without a result
  const { d, u, m } = hooked('meter-crash');
  const b = await m.begin('acct_ok', cost, { debate }); await m.start(b.handle);
  const f = `${d}/metering-intents/${intents(d)[0]}`; const rec = JSON.parse(readFileSync(f, 'utf8')); rec.pid = 999999999; writeFileSync(f, JSON.stringify(rec));
  const m2 = createMetering({ localUsage: u, external: auth, log, dir: d, env: { E3D_MCP_ORPHAN_POLICY: 'release' } });
  assert.deepEqual(await m2.recover(), { recovered: 1 });
  assert.equal(m2.stats().orphans_finalized, 1); assert.equal(m2.stats().orphans_released, 0, 'the orphan policy does not apply with finalize');
  const fx = await auth.fetchDebate({ debate_id: b.handle.debate_id, principal: 'acct_ok', include_transcript: true });
  assert.deepEqual([fx.debate.outcome, fx.debate.result, fx.debate.transcript, fx.debate.usage.calls], ['error', null, null, 3]);
  assert.deepEqual((await effectsOf(b.handle.reservation_id)).map((x) => x.charged), [0], 'the failed price (0)');
  assert.deepEqual(intents(d), []);
  // a process killed after the outcome was journaled but before delivery: recovery replays the identical body, one effect
  const { d: d2, u: u2, m: m3 } = hooked('meter-kill');
  const k = await m3.begin('acct_ok', cost, { debate }); await m3.start(k.handle);
  await inject('slow', ['finalize'], 1, 400); // the delivery is in flight...
  const commitP = m3.commit(k.handle, spent, { outcome: 'ok', result: result(), transcript: T });
  for (let i = 0; i < 100; i++) { const it = JSON.parse(readFileSync(`${d2}/metering-intents/${intents(d2)[0]}`, 'utf8')); if (it.settlement) break; await new Promise((r) => setTimeout(r, 5)); }
  const kf = `${d2}/metering-intents/${intents(d2)[0]}`; const krec = JSON.parse(readFileSync(kf, 'utf8'));
  assert.equal(krec.settlement.call, 'finalize'); assert.equal(krec.settlement.payload.outcome, 'ok');
  // ...and the process "dies": its journaled intent is what a restart sees (a copy, under a dead pid)
  const restart = dir('meter-kill-restart'); mkdirSync(`${restart}/metering-intents`, { recursive: true });
  writeFileSync(`${restart}/metering-intents/${intents(d2)[0]}`, JSON.stringify({ ...krec, pid: 999999999 }));
  await commitP; // the first delivery lands at the service (it was only slow)
  const mr = createMetering({ localUsage: createUsage({ env: { E3D_MCP_STATE_DIR: restart } }), external: auth, log, dir: restart, env: {} });
  assert.deepEqual(await mr.recover(), { recovered: 1 }); assert.equal(mr.stats().settlements_replayed, 1);
  assert.equal((await state()).finalize_requests[k.handle.reservation_id], 2, 'delivered twice');
  assert.deepEqual((await effectsOf(k.handle.reservation_id)).map((x) => [x.stored, x.charged]), [[true, 4]], 'one effect, charged once');
  assert.ok(u2);
  ok('metering: restart finalizes an interrupted run as error (no result); a journaled outcome is replayed identically, one effect');
}
{
  // a service without features: legacy behavior exactly (settle, release, orphan policy), and no new call reaches it
  const legacy = client(E.LEGACY_URL); await legacy.introspect(E.TOKEN_OK);
  const { d, m } = hooked('meter-legacy', legacy);
  assert.equal(m.finalizeEnabled(), false);
  const b = await m.begin('acct_ok', cost, { debate: { ...debate, question: 'bell \u0007 is fine without finalize' } });
  assert.equal(b.ok, true); assert.equal(b.handle.finalize, undefined); assert.equal(b.handle.debate_id, undefined);
  await m.start(b.handle);
  const c = await m.commit(b.handle, spent, { outcome: 'ok', result: result(), transcript: T });
  assert.deepEqual(c.billing, { principal: 'acct_ok', reservation_id: b.handle.reservation_id });
  const z = await m.begin('acct_ok', cost, { debate }); await m.commit(z.handle, { calls: 0, inTokens: 0, outTokens: 0 }, { outcome: 'error' });
  const s = legacy.stats().calls;
  assert.equal(s.settle, 1); assert.equal(s.release, 1); assert.equal(s.finalize, undefined); assert.equal(s.fetch, undefined); assert.equal(s['authorize-run'], undefined);
  assert.deepEqual(intents(d), []);
  ok('legacy: without features the debate settles and releases exactly as before and no new call is sent');
}

// ================= no content anywhere a log, stat or listing can show it =================
noContent('client log lines', lines.join('\n'));
noContent('client stats', JSON.stringify(auth.stats()));
assert.ok(lines.some((l) => /moved to dead-letter/.test(l)), 'dead-lettering is logged');
clearInterval(keepAlive);
console.log(`finalize tests: ${n} passed`);
