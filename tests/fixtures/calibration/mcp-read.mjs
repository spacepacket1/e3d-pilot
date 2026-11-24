// Cases for the calibration READ tools over MCP (lib/mcp/calibration-read.js, lib/mcp/calibration-config.js; plan-calibration-3-mcp.md P3-2). Deterministic:
// a temp store built with the store's own functions, a fake clock for the rate limit, no model, no network. Run by tests/calibration-mcp-read.sh.
// Each case is named; the mutation checks in the plan name the case that must fail. `node mcp-read.mjs --make-store <dir>` builds the store the stdio cases read.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, mkdtempSync, readdirSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { newUse, registerUse, reportOutcome, trackRecords } from '../../../lib/calibration/store.mjs';
import { describeRecord } from '../../../lib/calibration/record.mjs';
import { CALIBRATION_INSTRUCTION, calibrationMcpFrom, principalOk } from '../../../lib/mcp/calibration-config.js';
import { CALIBRATION_NOTICE, MINE_TOOL, NO_RATE, RECORD_TOOL, createCalibrationRead } from '../../../lib/mcp/calibration-read.js';

const SK = { id: 'skill.e3d.skeptic', version: '1.0.0', hash: `sha256:${'a'.repeat(64)}` };
let seq = 0;
// n uses of a skill, each with one outcome: tiers is a list of [tier, result]
export function fill(dir, tiers, { skill = SK, task_class = 'code-review' } = {}) {
  const ids = [];
  for (const [tier, result] of tiers) {
    seq += 1;
    const use_id = `use_${String(seq).padStart(8, '0')}${'ab'.repeat(8)}`;
    registerUse(dir, newUse({ use_id, skill, mode: 'host_chat', host: { family: 'claude-code', model_family: 'unknown' }, task_class, task_class_source: 'declared' }));
    reportOutcome(dir, { use_id, result, tier, reported_by: tier === 'host_reported' ? 'host' : 'user', evidence_ref: tier === 'verified' ? { type: 'artifact', id: `art_${'b'.repeat(16)}`, digest: `sha256:${'b'.repeat(64)}` } : null });
    ids.push(use_id);
  }
  return ids;
}
const rep = (n, tier, worked = Math.ceil(n * 0.7)) => Array.from({ length: n }, (_, i) => [tier, i < worked ? 'worked' : 'failed']);

if (process.argv[2] === '--make-store') {
  const d = process.argv[3];
  fill(d, rep(12, 'user_marked'));
  fill(d, rep(12, 'host_reported'), { skill: { id: 'skill.e3d.premortem', version: '2.0.0', hash: `sha256:${'c'.repeat(64)}` }, task_class: 'planning' });
  fill(d, rep(3, 'user_marked'), { skill: { id: 'skill.e3d.customer', version: '1.0.0', hash: `sha256:${'d'.repeat(64)}` }, task_class: 'research' });
  process.exit(0);
}

const cases = [];
const test = (name, fn) => cases.push([name, fn]);
const tmp = () => mkdtempSync(join(tmpdir(), 'cal-mcp-read-'));
const mk = (dir, over = {}) => createCalibrationRead({ env: { E3D_CALIBRATION_DIR: dir }, ...over });
const call = (r, tool, args = {}, ctx = { principal: 'local' }) => r.handlers[tool](args, null, ctx);
const rec = (r, args) => call(r, 'e3d_skill_record', args);
const allText = (res) => `${res.content.map((c) => c.text).join('\n')}\n${JSON.stringify(res.structuredContent)}`;
const errCode = (res) => res.structuredContent?.error?.code;
// ADR-0021's banned words (the same pattern as tests/fixtures/calibration/local.mjs) plus claim-shaped words about a cause
const BANNED = /\b(effective(ness)?|proven|improv(e|es|ed|ing)|best|better|accura(te|cy)|scores?|scoring|rank(s|ed|ing)?|leaderboards?|good|great|memory|learning|truth|audit|governance|knowledge base)\b|verified to/i;
const CAUSAL = /\b(because|caused?|causes|leads? to|led to|results? in|resulted in|thanks to|due to|makes? it|helps?|helped|boosts?|raises?|lifts?|works? better|recommend(s|ed)?|should use|improved?)\b/i;

// ---- the switch ----------------------------------------------------------------------------------------------------------------------------------------
test('config: E3D_CALIBRATION_MCP is strict unset/empty/0/1', () => {
  for (const v of [undefined, '', '0']) assert.deepEqual(calibrationMcpFrom({ E3D_CALIBRATION_MCP: v }), { ok: true, errors: [], on: false, missing: [] });
  for (const v of ['2', 'yes', 'true', 'on', '01', '-1', '1x', ' 1', 'TRUE', '1\n']) { const c = calibrationMcpFrom({ E3D_CALIBRATION_MCP: v, E3D_CALIBRATION_V1: '1' }, { skillsOn: true }); assert.equal(c.ok, false, `[${v}]`); assert.equal(c.on, false); assert.match(c.errors[0], /E3D_CALIBRATION_MCP must be unset, 0 or 1/); }
});
test('config: the tools are on only with all three flags', () => {
  for (const skillsOn of [false, true]) for (const v1 of [undefined, '', '0', '1']) {
    const c = calibrationMcpFrom({ E3D_CALIBRATION_MCP: '1', E3D_CALIBRATION_V1: v1 }, { skillsOn });
    assert.equal(c.ok, true, 'a missing companion is never an error');
    assert.equal(c.on, skillsOn && v1 === '1', `skills=${skillsOn} v1=${v1}`);
    assert.deepEqual(c.missing, [...(skillsOn ? [] : ['E3D_MCP_SKILLS=1']), ...(v1 === '1' ? [] : ['E3D_CALIBRATION_V1=1'])]);
  }
  for (const [env, skillsOn] of [[{ E3D_CALIBRATION_V1: '1' }, true], [{ E3D_CALIBRATION_V1: '1', E3D_CALIBRATION_MCP: '0' }, true], [{}, true]]) assert.equal(calibrationMcpFrom(env, { skillsOn }).on, false, 'E3D_CALIBRATION_MCP is the third switch');
});
test('config: a bad E3D_CALIBRATION_V1 is an error only when E3D_CALIBRATION_MCP=1', () => {
  for (const v of ['2', 'yes', 'on', '01']) { assert.equal(calibrationMcpFrom({ E3D_CALIBRATION_MCP: '1', E3D_CALIBRATION_V1: v }, { skillsOn: true }).ok, false); assert.deepEqual(calibrationMcpFrom({ E3D_CALIBRATION_V1: v }, { skillsOn: true }), { ok: true, errors: [], on: false, missing: [] }); }
});
test('config: refuses the HTTP server itself, even with every other flag set', () => {
  const c = calibrationMcpFrom({ E3D_CALIBRATION_MCP: '1', E3D_CALIBRATION_V1: '1' }, { http: true, skillsOn: true });
  assert.equal(c.ok, false); assert.equal(c.on, false); assert.match(c.errors[0], /stdio server only/);
  assert.equal(calibrationMcpFrom({ E3D_CALIBRATION_MCP: '1', E3D_CALIBRATION_V1: '1' }, { http: true, skillsOn: false }).ok, false, 'refused whatever the skills flag says');
  assert.equal(calibrationMcpFrom({}, { http: true }).ok, true, 'off on HTTP is fine');
});
test('principal: only the local principal on a stdio connection', () => {
  assert.equal(principalOk({ principal: 'local' }), true); assert.equal(principalOk({}), true);
  assert.equal(principalOk({ principal: 'alice' }), false); assert.equal(principalOk({ principal: 'local', hosted: true }), false);
});

// ---- the tools' descriptions and annotations -----------------------------------------------------------------------------------------------------------
test('tools: read-only annotations, closed bounded inputs', () => {
  for (const t of [RECORD_TOOL, MINE_TOOL]) {
    assert.deepEqual(t.annotations, { title: t.annotations.title, readOnlyHint: true, destructiveHint: false, openWorldHint: false, idempotentHint: true }, t.name);
    assert.equal(t.inputSchema.additionalProperties, false);
    for (const [k, p] of Object.entries(t.inputSchema.properties)) assert.ok(Number.isInteger(p.maxLength) && p.maxLength <= 128, `${t.name}.${k} maxLength`);
    assert.equal(t._meta, undefined);
  }
  assert.deepEqual(RECORD_TOOL.inputSchema.required, ['skill']); assert.deepEqual(Object.keys(MINE_TOOL.inputSchema.properties), []);
  assert.deepEqual(Object.keys(RECORD_TOOL.inputSchema.properties).sort(), ['hash', 'skill', 'task_class', 'version']);
});
test('handlers: registered under the tool names, nothing else', () => {
  const r = createCalibrationRead({ env: {} });
  assert.deepEqual(r.tools.map((t) => t.name), ['e3d_skill_record', 'e3d_my_calibration']); assert.deepEqual(Object.keys(r.handlers).sort(), ['e3d_my_calibration', 'e3d_skill_record']);
});

// ---- outputs -------------------------------------------------------------------------------------------------------------------------------------------
test('empty store: says so, creates nothing, a record of an unknown skill is skill_not_found', async () => {
  const d = join(tmp(), 'never-made'); const r = mk(d);
  const a = await call(r, 'e3d_my_calibration');
  assert.ok(!a.isError); assert.deepEqual(a.structuredContent.skills, []); assert.match(a.content[0].text, /\(no skill uses recorded\)/);
  const b = await rec(r, { skill: 'skeptic' });
  assert.equal(b.isError, true); assert.match(b.content[0].text, /skill_not_found/);
  assert.equal(existsSync(d), false, 'a read creates nothing');
});
test('under 10 resolved: counts only, no rate, no interval', async () => {
  const d = tmp(); fill(d, rep(5, 'user_marked', 5)); const r = mk(d);
  const res = await rec(r, { skill: 'skeptic' });
  assert.ok(!res.isError); const row = res.structuredContent.records[0];
  assert.equal(row.rate_shown, false); assert.equal(row.n_resolved, 5); assert.equal(row.n_uses, 5);
  assert.match(row.text, /not enough resolved outcomes \(5 of 10 needed; 5 uses recorded; 0 marked unknown\)/);
  assert.equal(row.success, undefined); assert.equal(row.by_tier, undefined);
  assert.doesNotMatch(allText(res), /interval|rate"|"success"|were marked worked|\d+%/);
});
test('boundary: 9 resolved is counts only, 10 resolved user-marked is a rate', async () => {
  const d = tmp(); fill(d, rep(9, 'user_marked', 9)); const r = mk(d);
  let row = (await rec(r, { skill: 'skeptic' })).structuredContent.records[0];
  assert.equal(row.rate_shown, false); assert.match(row.text, /not enough resolved outcomes \(9 of 10 needed/); assert.equal(row.success, undefined);
  fill(d, [['user_marked', 'worked']]);
  row = (await rec(r, { skill: 'skeptic' })).structuredContent.records[0]; assert.equal(row.rate_shown, true); assert.equal(row.success.count, 10);
});
test('10 or more resolved but only host_reported: counts and source mix, no rate', async () => {
  const d = tmp(); fill(d, rep(14, 'host_reported', 14)); const r = mk(d);
  const res = await rec(r, { skill: 'skill.e3d.skeptic' }); const row = res.structuredContent.records[0];
  assert.equal(row.rate_shown, false); assert.equal(row.n_resolved, 14); assert.deepEqual(row.by_tier, { verified: 0, user_marked: 0, host_reported: 14 });
  assert.ok(row.text.includes(NO_RATE), row.text); assert.match(row.text, /14 host-reported/);
  assert.equal(row.success, undefined); assert.equal(row.resolution_rate, undefined);
  assert.doesNotMatch(allText(res), /interval|"rate"|"success"|"count"|were marked worked|\d+%/);
});
test('boundary: 9 user-marked plus host_reported is no rate, exactly 10 is a rate', async () => {
  const d = tmp(); fill(d, [...rep(9, 'user_marked', 9), ...rep(6, 'host_reported', 6)]); const r = mk(d);
  let row = (await rec(r, { skill: 'skeptic' })).structuredContent.records[0];
  assert.equal(row.n_resolved, 15); assert.equal(row.rate_shown, false); assert.ok(row.text.includes(`${NO_RATE} (9 of 10 needed)`), row.text);
  fill(d, [['user_marked', 'failed']]);
  row = (await rec(r, { skill: 'skeptic' })).structuredContent.records[0];
  assert.equal(row.rate_shown, true); assert.ok(!row.text.includes(NO_RATE));
});
test('10 or more user-marked: the rate and interval, in the unchanged describeRecord sentence', async () => {
  const d = tmp(); fill(d, rep(12, 'user_marked', 9)); const r = mk(d);
  const res = await rec(r, { skill: 'skeptic' }); const row = res.structuredContent.records[0];
  assert.equal(row.rate_shown, true); assert.equal(row.success.count, 9); assert.equal(row.success.rate, 0.75); assert.equal(row.success.interval95.length, 2); assert.equal(row.success.method, 'wilson');
  const t = trackRecords(d, { skill: SK.id }); assert.equal(row.text, describeRecord(t.records[0], t.details[0]), 'the sentence is describeRecord, unchanged');
  assert.match(row.text, /in your 12 resolved uses, 9 were marked worked \(approximate 95% interval \d+% to \d+%\)/);
  assert.equal(res.content[0].text.includes(row.text), true);
});
test('verified outcomes count toward the 10 like user-marked ones', async () => {
  const d = tmp(); fill(d, [...rep(5, 'user_marked', 4), ...rep(5, 'verified', 4)]); const r = mk(d);
  assert.equal((await rec(r, { skill: 'skeptic' })).structuredContent.records[0].rate_shown, true);
});
test('reliability bins need 30: no calibration block is printed below that', async () => {
  const d = tmp(); fill(d, rep(12, 'user_marked')); const r = mk(d);
  const res = await rec(r, { skill: 'skeptic' });
  assert.doesNotMatch(allText(res), /"calibration"|"bins"|brier|"baseline"|reliability/i);
  assert.equal(trackRecords(d, { skill: SK.id }).records[0].calibration, null);
  assert.equal(Object.keys(res.structuredContent.records[0]).includes('calibration'), false);
});
test('e3d_my_calibration: grouped by skill, same wording, mixed rate rules per record', async () => {
  const d = tmp(); fill(d, rep(12, 'user_marked'));
  fill(d, rep(12, 'host_reported'), { skill: { id: 'skill.e3d.premortem', version: '2.0.0', hash: `sha256:${'c'.repeat(64)}` }, task_class: 'planning' });
  fill(d, rep(3, 'user_marked'), { skill: { id: 'skill.e3d.customer', version: '1.0.0', hash: `sha256:${'d'.repeat(64)}` }, task_class: 'research' });
  const r = mk(d); const res = await call(r, 'e3d_my_calibration');
  const by = Object.fromEntries(res.structuredContent.skills.map((s) => [s.skill, s.records]));
  assert.deepEqual(Object.keys(by), ['skill.e3d.customer', 'skill.e3d.premortem', 'skill.e3d.skeptic']);
  assert.equal(by['skill.e3d.skeptic'][0].rate_shown, true); assert.equal(by['skill.e3d.premortem'][0].rate_shown, false); assert.equal(by['skill.e3d.customer'][0].rate_shown, false);
  assert.match(by['skill.e3d.customer'][0].text, /not enough resolved outcomes \(3 of 10 needed/);
  for (const s of res.structuredContent.skills) for (const x of s.records) assert.ok(res.content[0].text.includes(x.text));
});
test('record filters: a task class and a version select, strata stay separate', async () => {
  const d = tmp(); fill(d, rep(10, 'user_marked'), { task_class: 'code-review' }); fill(d, rep(2, 'user_marked'), { task_class: 'planning' }); const r = mk(d);
  const all = await rec(r, { skill: 'skeptic' }); assert.equal(all.structuredContent.records.length, 2);
  const one = await rec(r, { skill: 'skeptic', task_class: 'planning' }); assert.equal(one.structuredContent.records.length, 1); assert.equal(one.structuredContent.records[0].task_class, 'planning');
  assert.equal((await rec(r, { skill: 'skeptic', version: '9.9.9' })).isError, true);
  assert.equal((await rec(r, { skill: 'skeptic', hash: SK.hash })).structuredContent.records.length, 2);
});
test('record: a bare name that matches two skills is refused, the full id works', async () => {
  const d = tmp(); fill(d, rep(2, 'user_marked'), { skill: { id: 'skill.alice.review', version: '1.0.0', hash: `sha256:${'e'.repeat(64)}` } }); fill(d, rep(2, 'user_marked'), { skill: { id: 'skill.bob.review', version: '1.0.0', hash: `sha256:${'f'.repeat(64)}` } });
  const r = mk(d); assert.match((await rec(r, { skill: 'review' })).content[0].text, /skill_not_found: that name matches more than one/);
  assert.ok(!(await rec(r, { skill: 'skill.alice.review' })).isError);
});

// ---- what must never be in an answer -------------------------------------------------------------------------------------------------------------------
test('no use_id, timestamp, path, task text or evidence reference in any answer', async () => {
  const d = tmp();
  const ids = [...fill(d, rep(12, 'user_marked')), ...fill(d, rep(11, 'host_reported'), { task_class: 'planning' }), ...fill(d, [...rep(5, 'user_marked'), ...rep(5, 'verified')], { task_class: 'research' })];
  const r = mk(d);
  for (const res of [await call(r, 'e3d_my_calibration'), await rec(r, { skill: 'skeptic' }), await rec(r, { skill: 'skeptic', task_class: 'planning' }), await rec(r, { skill: 'skeptic', task_class: 'research' })]) {
    const s = allText(res);
    for (const id of ids) assert.ok(!s.includes(id), `use id ${id} leaked`);
    assert.doesNotMatch(s, /\buse_[0-9A-Za-z]{4,}/); assert.doesNotMatch(s, /\bout_[0-9a-f]{4,}/);
    assert.doesNotMatch(s, /\b\d{4}-\d{2}-\d{2}(T|\b)/, 'a date'); assert.doesNotMatch(s, /\d{2}:\d{2}:\d{2}/, 'a time'); assert.doesNotMatch(s, /\b1[5-9]\d{11}\b/, 'an epoch time');
    assert.doesNotMatch(s, /computed_at|issued_at|expires_at|reported_at|run_ref|evidence_ref|attachment|principal_ref|outcome_id|use_id/);
    assert.ok(!s.includes(d) && !s.includes(tmpdir()), 'a path'); assert.doesNotMatch(s, /\/(Users|home|tmp|var|private)\//);
    const j = JSON.stringify(res.structuredContent); assert.doesNotMatch(j, new RegExp(`sha256:${'b'.repeat(64)}`));
  }
});
test('row keys are an allowlist', async () => {
  const d = tmp(); fill(d, rep(12, 'user_marked')); fill(d, rep(3, 'user_marked'), { task_class: 'planning' }); fill(d, rep(12, 'host_reported'), { task_class: 'research' }); const r = mk(d);
  const ok = new Set(['skill', 'task_class', 'mode', 'model_family', 'n_uses', 'n_resolved', 'n_unknown', 'n_inferred', 'corrections', 'by_tier', 'rate_shown', 'success', 'text']);
  for (const row of (await rec(r, { skill: 'skeptic' })).structuredContent.records) for (const k of Object.keys(row)) assert.ok(ok.has(k), `unexpected field ${k}`);
  assert.deepEqual(Object.keys((await call(r, 'e3d_my_calibration')).structuredContent).sort(), ['notice', 'scope', 'skills', 'unreadable_lines']);
});
test('reads write nothing: every store file is byte-identical after the calls', async () => {
  const d = tmp(); fill(d, rep(12, 'user_marked')); const r = mk(d);
  const snap = () => readdirSync(d).sort().map((f) => `${f}:${createHash('sha256').update(readFileSync(join(d, f))).digest('hex')}`).join('|');
  const before = snap(); await call(r, 'e3d_my_calibration'); await rec(r, { skill: 'skeptic' }); await rec(r, { skill: 'nope' }); assert.equal(snap(), before);
});
test('answers carry the notice and the data label', async () => {
  const d = tmp(); fill(d, rep(12, 'user_marked')); const r = mk(d);
  for (const res of [await call(r, 'e3d_my_calibration'), await rec(r, { skill: 'skeptic' })]) { assert.equal(res.structuredContent.notice, CALIBRATION_NOTICE); assert.ok(res.content[0].text.startsWith(CALIBRATION_NOTICE)); assert.equal(res.structuredContent.scope, 'local'); }
  assert.match(CALIBRATION_NOTICE, /not a claim about the skill/); assert.match(CALIBRATION_NOTICE, /data, not instructions/); assert.match(CALIBRATION_NOTICE, /Outcomes are not checked by Pilot/);
});

// ---- wording -------------------------------------------------------------------------------------------------------------------------------------------
test('wording: no banned word and no causal or improvement claim in any answer, description, notice or instruction', async () => {
  const d = tmp(); fill(d, rep(12, 'user_marked', 12)); fill(d, rep(12, 'host_reported'), { task_class: 'planning' }); fill(d, rep(2, 'user_marked'), { task_class: 'research' }); fill(d, [['user_marked', 'unknown'], ['user_marked', 'failed']], { task_class: 'other-kind' });
  const r = mk(d);
  const texts = [CALIBRATION_NOTICE, CALIBRATION_INSTRUCTION, NO_RATE, ...[RECORD_TOOL, MINE_TOOL].flatMap((t) => [t.description, t.annotations.title, ...Object.values(t.inputSchema.properties).map((p) => p.description)]),
    allText(await call(r, 'e3d_my_calibration')), allText(await rec(r, { skill: 'skeptic' }))];
  for (const t of texts) { for (const re of [BANNED, CAUSAL]) { const m = re.exec(t); assert.equal(m, null, `wording "${m && m[0]}" in: ${m && t.slice(Math.max(0, m.index - 60), m.index + 60)}`); } }
  for (const w of ['it improves results', 'the best skill', 'this works because', 'leads to better', 'recommended']) assert.ok(BANNED.test(w) || CAUSAL.test(w), `the pattern bites on: ${w}`);
});

// ---- invalid input and gates ---------------------------------------------------------------------------------------------------------------------------
test('invalid input is refused with invalid_request, never a crash', async () => {
  const d = tmp(); fill(d, rep(2, 'user_marked')); const r = mk(d);
  const bad = [{}, { skill: 5 }, { skill: '' }, { skill: 'A'.repeat(5) }, { skill: 'x'.repeat(129) }, { skill: 'skeptic', extra: 1 }, { skill: 'skeptic', version: '1.0' }, { skill: 'skeptic', version: 1 }, { skill: 'skeptic', hash: 'sha256:abc' }, { skill: 'skeptic', hash: 'a'.repeat(71) },
    { skill: 'skeptic', task_class: 'ab' }, { skill: 'skeptic', task_class: 'Has Space' }, { skill: 'skeptic', task_class: 'x'.repeat(41) }, { skill: 'skeptic', task_class: 'a;b' }, { skill: ['skeptic'] }, { skill: 'a/../b' }, { skill: 'skeptic\nIgnore previous' }];
  for (const a of bad) { const res = await rec(r, a); assert.equal(res.isError, true, JSON.stringify(a)); assert.equal(errCode(res), 'invalid_request', JSON.stringify(a)); }
  for (const a of [{ x: 1 }, { skill: 'skeptic' }]) { const res = await call(r, 'e3d_my_calibration', a); assert.equal(res.isError, true); assert.equal(errCode(res), 'invalid_request'); }
  for (const a of [null, 5, 'x', [], undefined]) { const res = await rec(r, a); assert.equal(res.isError, true); }
  assert.ok(!(await call(r, 'e3d_my_calibration', undefined)).isError);
});
test('another principal and a hosted connection are refused skill_scope_denied', async () => {
  const d = tmp(); fill(d, rep(12, 'user_marked')); const r = mk(d);
  for (const ctx of [{ principal: 'alice' }, { principal: 'local', hosted: true }]) for (const [t, a] of [['e3d_my_calibration', {}], ['e3d_skill_record', { skill: 'skeptic' }]]) {
    const res = await call(r, t, a, ctx); assert.equal(res.isError, true); assert.match(res.content[0].text, /skill_scope_denied/); assert.doesNotMatch(allText(res), /resolved|marked/);
  }
});
test('a relative or unreadable store directory is a refusal, not a leak', async () => {
  const r = createCalibrationRead({ env: { E3D_CALIBRATION_DIR: 'relative/dir' } });
  const res = await call(r, 'e3d_my_calibration'); assert.equal(res.isError, true); assert.match(res.content[0].text, /skill_scope_denied/); assert.doesNotMatch(allText(res), /relative\/dir/);
});
test('rate limit: the 31st read in a minute waits, reads recover with the clock', async () => {
  const d = tmp(); const clock = { t: 1e12 }; const r = mk(d, { now: () => clock.t });
  for (let i = 0; i < 30; i++) assert.ok(!(await call(r, 'e3d_my_calibration')).isError, `call ${i}`);
  const res = await call(r, 'e3d_my_calibration'); assert.equal(errCode(res), 'rate_limited'); assert.equal(res.structuredContent.error.retryable, true);
  clock.t += 61000; assert.ok(!(await call(r, 'e3d_my_calibration')).isError);
});

let failed = 0;
for (const [name, fn] of cases) {
  try { await fn(); console.log(`ok - ${name}`); } catch (e) { failed += 1; console.log(`FAIL - ${name}\n  ${String(e.stack || e).split('\n').slice(0, 6).join('\n  ')}`); }
}
if (failed) { console.error(`${failed} case(s) failed`); process.exit(1); }
console.log(`${cases.length} cases passed`);
