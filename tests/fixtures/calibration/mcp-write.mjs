// Cases for the calibration WRITE side over MCP (lib/mcp/calibration-write.js; plan-calibration-3-mcp.md P3-3). Deterministic: a fake clock, fake timers for the
// elicitation timeout, a stub MCP client (session capabilities + an rpc.request that accepts, declines, cancels, never answers or fails), temp stores built with the
// store's own functions. No model, no network. Run by tests/calibration-mcp-write.sh. Each case is named; every mutation check names the case that must fail.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { appendOutcome, deleteOutcome, newUse, registerUse, reportOutcome, tierAllows } from '../../../lib/calibration/store.mjs';
import { createLedger, ELICIT_TIMEOUT_MS, PAUSE_MS, TICKET_MS } from '../../../lib/calibration/mcp-ledger.mjs';
import { ASK_TIMEOUT_MS, CALIBRATION_WRITE_INSTRUCTION, USE_NOTE, WRITE_NOTICE, createCalibrationWrite, extendGetTool, hostFamily, writeTools } from '../../../lib/mcp/calibration-write.js';
import { GET_TOOL, createSkillsRead } from '../../../lib/mcp/skills-read.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '../../..');
const cases = [];
const test = (name, fn) => cases.push([name, fn]);
const tmp = () => mkdtempSync(join(tmpdir(), 'cal-mcp-write-'));
const BANNED = /\b(effective(ness)?|proven|improv(e|es|ed|ing)|best|better|accura(te|cy)|scores?|scoring|rank(s|ed|ing)?|leaderboards?|good|great|memory|learning|truth|audit|governance|knowledge base)\b|verified to/i;
const CAUSAL = /\b(because|caused?|causes|leads? to|led to|results? in|resulted in|thanks to|due to|makes? it|helps?|helped|boosts?|raises?|lifts?|works? better|recommend(s|ed)?|should use|improved?)\b/i;

// ---- the harness ----------------------------------------------------------------------------------------------------------------------------------------
function fakeTimers() {
  const live = new Set();
  return {
    set(fn, ms) { const h = { fn, ms }; live.add(h); return h; },
    clear(h) { live.delete(h); },
    fire(ms) { let n = 0; for (const h of [...live]) if (h.ms === ms) { live.delete(h); h.fn(); n += 1; } return n; },
    pending(ms) { return [...live].filter((h) => h.ms === ms).length; },
  };
}
const tick = () => new Promise((r) => setImmediate(r));

// A stub client. answer(params) -> a result object, or 'never' (stays pending until released), or 'reject'.
function client({ elicitation = { form: {} }, name = 'Claude Code', answer = () => ({ action: 'accept', content: { confirm: true } }) } = {}) {
  const asked = [];
  const held = [];
  const notes = [];
  const rpc = {
    request(method, params) {
      asked.push({ method, params });
      const a = answer(params);
      const p = a === 'never' ? new Promise((res) => held.push(res)) : a === 'reject' ? Promise.reject(Object.assign(new Error('method not found'), { code: -32601 })) : Promise.resolve(a);
      p.requestId = `s-${asked.length}`;
      return p;
    },
    notify(method, params) { notes.push({ method, params }); },
  };
  const caps = elicitation === null ? {} : { elicitation };
  return { asked, held, notes, ctx: { principal: 'local', hosted: false, session: { clientInfo: { name }, capabilities: caps }, rpc } };
}

function setup({ unconfirmed = false } = {}) {
  const dir = join(tmp(), 'store');
  const clock = { t: Date.now() };
  const now = () => clock.t;
  const timers = fakeTimers();
  const ledger = createLedger({ now, timers });
  const w = createCalibrationWrite({ env: { E3D_CALIBRATION_DIR: dir }, now, ledger, timers, unconfirmed });
  const skills = createSkillsRead({ dirs: { builtin: join(ROOT, 'lib/specialists'), user: join(dir, 'nouser'), repo: join(dir, 'norepo') }, now });
  const get = w.wrapGet(skills.handlers.e3d_get_skill);
  const call = (tool, args, ctx) => w.handlers[tool](args, null, ctx);
  const fetch = async (ctx, args = { id: 'skeptic' }) => { const r = await get(args, null, ctx); assert.ok(!r.isError, JSON.stringify(r)); return r; };
  return { dir, clock, timers, ledger, w, get, call, fetch };
}
const rows = (dir, f) => (existsSync(join(dir, f)) ? readFileSync(join(dir, f), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []);
const text = (res) => `${res.content.map((c) => c.text).join('\n')}\n${JSON.stringify(res.structuredContent)}`;
const ACCEPT = (content) => () => ({ action: 'accept', content });

// ---- tool definitions -----------------------------------------------------------------------------------------------------------------------------------
test('tools: three write tools, strict bounded schemas, annotations and requiresUserInteraction', () => {
  const t = Object.fromEntries(writeTools().map((x) => [x.name, x]));
  assert.deepEqual(Object.keys(t), ['e3d_skill_report_use', 'e3d_skill_report_outcome', 'e3d_skill_delete_outcome']);
  for (const x of Object.values(t)) {
    assert.equal(x.inputSchema.additionalProperties, false, x.name);
    assert.deepEqual(x.inputSchema.properties.use_id, { type: 'string', minLength: 36, maxLength: 36, pattern: '^use_[0-9a-f]{32}$', description: 'The use_id from e3d_get_skill in this session.' });
    assert.equal(x.annotations.readOnlyHint, false); assert.equal(x.annotations.openWorldHint, false); assert.equal(x.annotations.idempotentHint, true);
    assert.equal(x._meta['anthropic/requiresUserInteraction'], true, `${x.name} requiresUserInteraction`);
    for (const k of ['skill', 'version', 'hash', 'definition_hash', 'tier', 'reported_by', 'evidence_ref']) assert.ok(!(k in x.inputSchema.properties), `${x.name} has no ${k} input`);
  }
  assert.deepEqual(Object.keys(t.e3d_skill_report_outcome.inputSchema.properties).sort(), ['result', 'use_id']);
  assert.deepEqual(t.e3d_skill_report_outcome.inputSchema.properties.result.enum, ['worked', 'failed', 'unknown']);
  assert.deepEqual(Object.keys(t.e3d_skill_report_use.inputSchema.properties), ['use_id']);
  assert.deepEqual(Object.keys(t.e3d_skill_delete_outcome.inputSchema.properties), ['use_id']);
});
test('tools: destructiveHint true only for delete', () => {
  const t = Object.fromEntries(writeTools().map((x) => [x.name, x]));
  assert.equal(t.e3d_skill_delete_outcome.annotations.destructiveHint, true);
  assert.equal(t.e3d_skill_report_use.annotations.destructiveHint, false); assert.equal(t.e3d_skill_report_outcome.annotations.destructiveHint, false);
});
test('get tool: only task_class, use and idempotentHint false are added', () => {
  const g = extendGetTool(GET_TOOL);
  assert.deepEqual(Object.keys(g.inputSchema.properties), [...Object.keys(GET_TOOL.inputSchema.properties), 'task_class']);
  assert.equal(g.inputSchema.additionalProperties, false); assert.equal(g.inputSchema.properties.task_class.maxLength, 40);
  assert.deepEqual({ ...g.annotations, idempotentHint: true }, GET_TOOL.annotations); assert.equal(g.annotations.idempotentHint, false); assert.equal(g.annotations.readOnlyHint, true);
  assert.ok(g.description.startsWith(GET_TOOL.description));
  assert.ok(!('_meta' in g), 'the read tool needs no user interaction');
});

// ---- the ticket -----------------------------------------------------------------------------------------------------------------------------------------
test('get: issues a ticket bound to the served id, version, hash and this session; a fetch writes nothing', async () => {
  const s = setup(); const c = client();
  const r = await s.fetch(c.ctx, { id: 'skeptic', task_class: 'code-review' });
  const d = r.structuredContent.definition; const u = r.structuredContent.use;
  assert.match(u.use_id, /^use_[0-9a-f]{32}$/); assert.equal(u.expires_in_hours, 24); assert.equal(u.note, USE_NOTE);
  const lk = s.ledger.lookup(u.use_id, { skill: { id: d.id, version: d.version, definition_hash: d.definition_hash } });
  assert.equal(lk.ok, true); assert.equal(lk.ticket.task_class, 'code-review'); assert.equal(lk.ticket.session_id, s.ledger.session_id);
  assert.match(r.content[r.content.length - 1].text, new RegExp(`use_id: "${u.use_id}"`));
  assert.equal(existsSync(s.dir), false, 'a fetch creates no store directory or file'); assert.equal(c.asked.length, 0, 'a fetch asks nothing');
  const r2 = await s.fetch(c.ctx); assert.notEqual(r2.structuredContent.use.use_id, u.use_id, 'each fetch issues a new handle');
});
test('get: a bad task_class is refused before anything is issued; an error from the read tool issues nothing', async () => {
  const s = setup(); const c = client();
  for (const tc of ['ab', 'Has Space', 'x'.repeat(41), 7, 'a--b']) { const r = await s.get({ id: 'skeptic', task_class: tc }, null, c.ctx); assert.equal(r.isError, true, String(tc)); assert.match(r.content[0].text, /invalid_task_class/); }
  const r = await s.get({ id: 'no-such-skill' }, null, c.ctx); assert.equal(r.isError, true); assert.ok(!('use' in (r.structuredContent ?? {})));
  assert.equal(s.ledger.outstanding(), 0);
});

// ---- report_outcome with elicitation -------------------------------------------------------------------------------------------------------------------
test('accept: the user\'s choice is stored as user_marked in a row built from the ledger; the agent\'s result is ignored', async () => {
  const s = setup(); const c = client({ answer: ACCEPT({ result: 'failed' }) });
  const u = (await s.fetch(c.ctx, { id: 'skeptic', task_class: 'code-review' })).structuredContent;
  const res = await s.call('e3d_skill_report_outcome', { use_id: u.use.use_id, result: 'worked' }, c.ctx);
  assert.ok(!res.isError, text(res)); assert.equal(res.structuredContent.status, 'recorded'); assert.equal(res.structuredContent.tier, 'user_marked');
  const t = s.ledger.lookup(u.use.use_id).ticket;
  assert.deepEqual(rows(s.dir, 'uses.jsonl'), [newUse({ use_id: u.use.use_id, skill: { id: u.definition.id, version: u.definition.version, hash: u.definition.definition_hash }, mode: 'host_chat', host: { family: 'claude-code', model_family: 'unknown' }, task_class: 'code-review', task_class_source: 'declared' }, t.issued_at)]);
  const o = rows(s.dir, 'outcomes.jsonl'); assert.equal(o.length, 1);
  assert.equal(o[0].doc.result, 'failed', 'the user picked failed; the agent said worked'); assert.equal(o[0].doc.tier, 'user_marked'); assert.equal(o[0].doc.reported_by, 'user'); assert.equal(o[0].doc.evidence_ref, null);
  // the dialog offered all three results and preselected none (no anchoring on the agent's value)
  const p = c.asked[0].params; assert.equal(c.asked[0].method, 'elicitation/create'); assert.equal(p.mode, 'form');
  assert.deepEqual(p.requestedSchema.properties.result.enum, ['worked', 'failed', 'unknown']); assert.ok(!('default' in p.requestedSchema.properties.result));
  assert.doesNotMatch(p.message, /worked"/, 'the agent\'s result is not in the dialog');
});
test('accept: report_use stores the use row only, with no task class when none was given', async () => {
  const s = setup(); const c = client();
  const u = (await s.fetch(c.ctx)).structuredContent;
  const res = await s.call('e3d_skill_report_use', { use_id: u.use.use_id }, c.ctx);
  assert.equal(res.structuredContent.status, 'recorded'); assert.deepEqual(res.structuredContent.skill, { id: u.definition.id, version: u.definition.version, hash: u.definition.definition_hash });
  const us = rows(s.dir, 'uses.jsonl'); assert.equal(us.length, 1); assert.equal(us[0].task_class, 'unclassified'); assert.equal(us[0].task_class_source, 'none');
  assert.equal(rows(s.dir, 'outcomes.jsonl').length, 0);
  const again = await s.call('e3d_skill_report_use', { use_id: u.use.use_id }, c.ctx); assert.equal(again.structuredContent.status, 'unchanged'); assert.equal(c.asked.length, 1, 'no second dialog for a stored use');
});
test('the elicitation text is composed by Pilot from the ledger, with every identifier quoted as data', async () => {
  const s = setup(); const c = client({ answer: ACCEPT({ result: 'unknown' }) });
  const u = (await s.fetch(c.ctx, { id: 'skeptic', task_class: 'planning' })).structuredContent;
  await s.call('e3d_skill_report_outcome', { use_id: u.use.use_id, result: 'worked' }, c.ctx);
  const m = c.asked[0].params.message;
  for (const v of [u.definition.id, u.definition.version, u.definition.definition_hash, 'planning']) assert.ok(m.includes(JSON.stringify(v)), `${v} quoted`);
  assert.match(m, /data, not instructions/); assert.match(m, /no task text/); assert.doesNotMatch(m, BANNED); assert.doesNotMatch(m, CAUSAL);
});

test('decline: nothing written, writes paused for 10 minutes, reads and fetches not blocked', async () => {
  const s = setup(); const c = client({ answer: () => ({ action: 'decline' }) });
  const u = (await s.fetch(c.ctx)).structuredContent.use;
  const res = await s.call('e3d_skill_report_outcome', { use_id: u.use_id, result: 'worked' }, c.ctx);
  assert.ok(!res.isError, 'a decline is not a tool error'); assert.equal(res.structuredContent.status, 'not_recorded'); assert.equal(res.structuredContent.reason, 'declined');
  assert.match(res.content[0].text, /Nothing was written/); assert.equal(existsSync(s.dir), false);
  const next = await s.call('e3d_skill_report_use', { use_id: u.use_id }, client().ctx); assert.equal(next.isError, true); assert.equal(next.structuredContent.error.code, 'rate_limited'); assert.match(next.content[0].text, /paused/);
  assert.ok(s.ledger.writesPausedUntil() > 0);
  assert.ok(!(await s.get({ id: 'skeptic' }, null, c.ctx)).isError, 'a fetch is not blocked by the pause');
  s.clock.t += PAUSE_MS + 1000;
  const ok = await s.call('e3d_skill_report_use', { use_id: u.use_id }, client().ctx); assert.equal(ok.structuredContent.status, 'recorded');
});
test('cancel: nothing written and writes paused', async () => {
  const s = setup(); const c = client({ answer: () => ({ action: 'cancel' }) });
  const u = (await s.fetch(c.ctx)).structuredContent.use;
  for (const tool of ['e3d_skill_report_use', 'e3d_skill_report_outcome']) {
    const s2 = setup(); const u2 = (await s2.fetch(c.ctx)).structuredContent.use;
    const res = await s2.call(tool, { use_id: u2.use_id, result: 'worked' }, c.ctx).catch((e) => e);
    if (tool === 'e3d_skill_report_use') { assert.equal(res.isError, true); continue; } // report_use takes no result: an unknown argument
    assert.equal(res.structuredContent.reason, 'cancelled'); assert.equal(existsSync(s2.dir), false); assert.ok(s2.ledger.writesPausedUntil() > 0);
  }
  const res = await s.call('e3d_skill_report_use', { use_id: u.use_id }, c.ctx);
  assert.equal(res.structuredContent.reason, 'cancelled'); assert.equal(existsSync(s.dir), false); assert.ok(s.ledger.writesPausedUntil() > 0, 'cancel starts the pause');
});
test('an accept with other content than the form asked for is a decline', async () => {
  for (const content of [{ result: 'worked', extra: 1 }, { result: 'maybe' }, {}, null, { confirm: true }, { result: ['worked'] }]) {
    const s = setup(); const c = client({ answer: ACCEPT(content) });
    const u = (await s.fetch(c.ctx)).structuredContent.use;
    const res = await s.call('e3d_skill_report_outcome', { use_id: u.use_id, result: 'worked' }, c.ctx);
    assert.equal(res.structuredContent.status, 'not_recorded', JSON.stringify(content)); assert.equal(existsSync(s.dir), false); assert.ok(s.ledger.writesPausedUntil() > 0);
  }
  for (const content of [{ confirm: false }, { confirm: 'true' }, { confirm: true, x: 1 }]) {
    const s = setup(); const c = client({ answer: ACCEPT(content) });
    const u = (await s.fetch(c.ctx)).structuredContent.use;
    assert.equal((await s.call('e3d_skill_report_use', { use_id: u.use_id }, c.ctx)).structuredContent.status, 'not_recorded', JSON.stringify(content)); assert.equal(existsSync(s.dir), false);
  }
});
test('timeout: nothing written, a late answer writes nothing, no pause, not counted toward the refusal streak', async () => {
  const s = setup(); const c = client({ answer: () => 'never' });
  const ids = []; for (let i = 0; i < 6; i++) ids.push((await s.fetch(c.ctx)).structuredContent.use.use_id);
  for (let i = 0; i < 6; i++) { // six timeouts in a row: more than the five refusals that would pause
    const p = s.call('e3d_skill_report_outcome', { use_id: ids[i], result: 'worked' }, c.ctx);
    for (let k = 0; k < 5 && s.timers.pending(ASK_TIMEOUT_MS) === 0; k++) await tick();
    assert.equal(s.timers.fire(ASK_TIMEOUT_MS), 1, 'the ask timer was armed');
    const res = await p; assert.ok(!res.isError); assert.equal(res.structuredContent.reason, 'timeout'); assert.equal(res.structuredContent.code, 'elicitation_timeout');
  }
  for (const release of c.held) release({ action: 'accept', content: { result: 'failed' } }); // the user answers late
  await tick(); await tick();
  assert.equal(existsSync(s.dir), false, 'a late accept writes nothing');
  assert.deepEqual(c.notes.map((n) => [n.method, n.params.requestId]), c.asked.map((a, k) => ['notifications/cancelled', `s-${k + 1}`]), 'each abandoned dialog is cancelled at the host');
  assert.equal(s.ledger.writesPausedUntil(), 0, 'a timeout does not pause');
  const c2 = client({ answer: ACCEPT({ result: 'worked' }) });
  assert.equal((await s.call('e3d_skill_report_outcome', { use_id: ids[0], result: 'worked' }, c2.ctx)).structuredContent.status, 'recorded');
  assert.ok(ASK_TIMEOUT_MS < ELICIT_TIMEOUT_MS, 'the ask gives up before the ledger lock backstop');
});
test('a client whose elicitation request fails: nothing written, a refusal', async () => {
  const s = setup(); const c = client({ answer: () => 'reject' });
  const u = (await s.fetch(c.ctx)).structuredContent.use;
  const res = await s.call('e3d_skill_report_outcome', { use_id: u.use_id, result: 'worked' }, c.ctx);
  assert.equal(res.structuredContent.status, 'not_recorded'); assert.equal(existsSync(s.dir), false);
});

// ---- hosts without elicitation (D3) ---------------------------------------------------------------------------------------------------------------------
test('no elicitation capability: every write is refused, nothing written, counted as a refusal', async () => {
  for (const caps of [null, 'url-only', 'not-an-object', 'form-false', 'form-null', 'form-true']) {
    const s = setup();
    const c = client({ elicitation: caps === 'url-only' ? { url: {} } : caps === 'not-an-object' ? true : caps === 'form-false' ? { form: false } : caps === 'form-null' ? { form: null } : caps === 'form-true' ? { form: true } : null });
    const u = (await s.fetch(c.ctx)).structuredContent.use;
    for (const [tool, args] of [['e3d_skill_report_use', {}], ['e3d_skill_report_outcome', { result: 'worked' }], ['e3d_skill_delete_outcome', {}]]) {
      const res = await s.call(tool, { use_id: u.use_id, ...args }, c.ctx);
      assert.ok(!res.isError, `${tool}: a relayable refusal`); assert.equal(res.structuredContent.status, 'not_recorded'); assert.equal(res.structuredContent.reason, 'no_elicitation'); assert.equal(res.structuredContent.code, 'skill_scope_denied');
    }
    assert.equal(existsSync(s.dir), false, String(caps)); assert.equal(c.asked.length, 0);
  }
  // the refusals count: five in a row pause the write tools
  const s = setup(); const c = client({ elicitation: null }); const u = (await s.fetch(c.ctx)).structuredContent.use;
  for (let i = 0; i < 5; i++) await s.call('e3d_skill_report_use', { use_id: u.use_id }, c.ctx);
  assert.equal((await s.call('e3d_skill_report_use', { use_id: u.use_id }, c.ctx)).structuredContent.error.code, 'rate_limited');
});
test('unconfirmed switch without elicitation: host_reported only, from the agent\'s result; deletion never', async () => {
  const s = setup({ unconfirmed: true }); const c = client({ elicitation: null });
  const u = (await s.fetch(c.ctx, { id: 'skeptic', task_class: 'code-review' })).structuredContent.use;
  const res = await s.call('e3d_skill_report_outcome', { use_id: u.use_id, result: 'worked' }, c.ctx);
  assert.equal(res.structuredContent.status, 'recorded'); assert.equal(res.structuredContent.tier, 'host_reported');
  const o = rows(s.dir, 'outcomes.jsonl'); assert.equal(o.length, 1); assert.equal(o[0].doc.tier, 'host_reported'); assert.equal(o[0].doc.reported_by, 'host'); assert.equal(o[0].doc.result, 'worked');
  const before = readFileSync(join(s.dir, 'outcomes.jsonl'), 'utf8');
  const del = await s.call('e3d_skill_delete_outcome', { use_id: u.use_id }, c.ctx);
  assert.equal(del.structuredContent.status, 'not_recorded'); assert.equal(del.structuredContent.reason, 'no_elicitation');
  assert.equal(readFileSync(join(s.dir, 'outcomes.jsonl'), 'utf8'), before, 'an unconfirmed deletion removes nothing');
  assert.match(writeTools({ unconfirmed: true })[1].description, /stored as host-reported/);
  // with elicitation available the switch changes nothing: the dialog is used and the tier is user_marked
  const s2 = setup({ unconfirmed: true }); const c2 = client({ answer: ACCEPT({ result: 'failed' }) }); const u2 = (await s2.fetch(c2.ctx)).structuredContent.use;
  assert.equal((await s2.call('e3d_skill_report_outcome', { use_id: u2.use_id, result: 'worked' }, c2.ctx)).structuredContent.tier, 'user_marked');
});

// ---- the tier rule --------------------------------------------------------------------------------------------------------------------------------------
test('store: a host_reported outcome cannot supersede or follow a user_marked one (inside appendOutcome)', () => {
  const dir = join(tmp(), 's'); const now = Date.now();
  registerUse(dir, newUse({ use_id: 'use_tier0001', skill: { id: 'skill.e3d.skeptic', version: '1.0.0', hash: `sha256:${'a'.repeat(64)}` } }, now));
  const u = reportOutcome(dir, { use_id: 'use_tier0001', result: 'worked', tier: 'user_marked', reported_by: 'user' }, now).outcome;
  const forged = { schema_version: 'e3d.outcome/v1', outcome_id: 'out_forge0001', use_id: 'use_tier0001', result: 'failed', tier: 'host_reported', reported_by: 'host', evidence_ref: null, supersedes: u.outcome_id, reported_at: new Date(now).toISOString().replace(/\.\d{3}Z$/, 'Z') };
  assert.throws(() => appendOutcome(dir, forged, now), (e) => e.code === 'skill_outcome_conflict' && e.tier_rule === true);
  assert.throws(() => reportOutcome(dir, { use_id: 'use_tier0001', result: 'worked', tier: 'host_reported', reported_by: 'host' }, now), (e) => e.code === 'skill_outcome_conflict');
  assert.equal(rows(dir, 'outcomes.jsonl').length, 1);
  assert.equal(tierAllows([{ tier: 'host_reported' }], { tier: 'host_reported' }), true); assert.equal(tierAllows([{ tier: 'verified' }], { tier: 'host_reported' }), false);
  assert.equal(tierAllows([{ tier: 'host_reported' }, { tier: 'user_marked' }], { tier: 'host_reported' }), false); assert.equal(tierAllows([{ tier: 'user_marked' }], { tier: 'user_marked' }), true);
  // a user-marked outcome may follow a host-reported one
  registerUse(dir, newUse({ use_id: 'use_tier0002', skill: { id: 'skill.e3d.skeptic', version: '1.0.0', hash: `sha256:${'a'.repeat(64)}` } }, now));
  reportOutcome(dir, { use_id: 'use_tier0002', result: 'worked', tier: 'host_reported', reported_by: 'host' }, now);
  assert.equal(reportOutcome(dir, { use_id: 'use_tier0002', result: 'failed', tier: 'user_marked', reported_by: 'user' }, now).superseded !== null, true);
});
test('MCP: an unconfirmed host_reported report cannot overwrite an accepted user_marked one', async () => {
  const s = setup({ unconfirmed: true }); const yes = client({ answer: ACCEPT({ result: 'worked' }) }); const no = client({ elicitation: null });
  const u = (await s.fetch(yes.ctx)).structuredContent.use;
  assert.equal((await s.call('e3d_skill_report_outcome', { use_id: u.use_id, result: 'worked' }, yes.ctx)).structuredContent.tier, 'user_marked');
  const before = readFileSync(join(s.dir, 'outcomes.jsonl'), 'utf8');
  for (const r of ['failed', 'worked', 'unknown']) {
    const res = await s.call('e3d_skill_report_outcome', { use_id: u.use_id, result: r }, no.ctx);
    assert.equal(res.isError, true, r); assert.match(res.content[0].text, /skill_outcome_conflict/);
  }
  assert.equal(readFileSync(join(s.dir, 'outcomes.jsonl'), 'utf8'), before);
});
test('concurrent: a host_reported writer racing a user_marked writer cannot follow it (the predicate holds inside the lock)', async () => {
  const dir = join(tmp(), 's'); const hooks = tmp(); const now = Date.now();
  registerUse(dir, newUse({ use_id: 'use_race0001', skill: { id: 'skill.e3d.skeptic', version: '1.0.0', hash: `sha256:${'a'.repeat(64)}` } }, now));
  // process B: a host_reported report that read the (empty) chain and stops just before taking the lock
  const b = spawn(process.execPath, [join(HERE, 'mcp-write-worker.mjs'), dir, 'use_race0001', 'host_reported', 'failed'], { env: { ...process.env, E3D_CALIBRATION_TEST_HOOKS: hooks }, stdio: ['ignore', 'pipe', 'pipe'] });
  let out = ''; b.stdout.on('data', (d) => { out += d; });
  const done = new Promise((res) => b.on('exit', res));
  const t0 = Date.now(); while (!readdirSync(hooks).some((f) => f.startsWith('at-beforeOutcomeLock-'))) { if (Date.now() - t0 > 15000) throw new Error('worker never reached the hook'); await new Promise((r) => setTimeout(r, 10)); }
  // meanwhile the user marks it (this process, no hook)
  reportOutcome(dir, { use_id: 'use_race0001', result: 'worked', tier: 'user_marked', reported_by: 'user' }, now);
  writeFileSync(join(hooks, 'go-beforeOutcomeLock'), 'x');
  await done;
  assert.deepEqual(JSON.parse(out), { ok: false, code: 'skill_outcome_conflict' });
  const o = rows(dir, 'outcomes.jsonl'); assert.equal(o.length, 1); assert.equal(o[0].doc.tier, 'user_marked');
});

// ---- tickets the agent cannot forge ---------------------------------------------------------------------------------------------------------------------
test('forged, malformed, foreign-session, expired and evicted tickets: the same skill_use_not_found, nothing written', async () => {
  const s = setup(); const c = client({ answer: ACCEPT({ result: 'worked' }) });
  const other = setup(); const foreign = (await other.fetch(c.ctx)).structuredContent.use.use_id; // issued by another process's ledger
  const mine = (await s.fetch(c.ctx)).structuredContent.use.use_id;
  const answers = [];
  for (const id of [`use_${'0'.repeat(32)}`, `use_${'f'.repeat(32)}`, 'use_abcd', 'not-an-id', foreign, `${mine.slice(0, -1)}${mine.endsWith('a') ? 'b' : 'a'}`]) {
    for (const tool of ['e3d_skill_report_use', 'e3d_skill_report_outcome', 'e3d_skill_delete_outcome']) {
      const res = await s.call(tool, { use_id: id, ...(tool === 'e3d_skill_report_outcome' ? { result: 'worked' } : {}) }, c.ctx);
      assert.equal(res.isError, true, `${tool} ${id}`); answers.push(res.content[0].text);
      s.clock.t += 61 * 60 * 1000; // stay under the write rate and outside any pause from the refusal streak
    }
  }
  s.clock.t += TICKET_MS + 1000; // now `mine` is expired
  for (const tool of ['e3d_skill_report_use', 'e3d_skill_report_outcome']) answers.push((await s.call(tool, { use_id: mine, ...(tool === 'e3d_skill_report_outcome' ? { result: 'worked' } : {}) }, c.ctx)).content[0].text);
  assert.equal(new Set(answers).size, 1, `one answer for all: ${[...new Set(answers)].join(' | ')}`); assert.match(answers[0], /skill_use_not_found/);
  assert.equal(c.asked.length, 0, 'no dialog for a ticket that is not live'); assert.equal(existsSync(s.dir), false);
});
test('the agent cannot supply the skill, version, hash, tier or task class of a write', async () => {
  const s = setup(); const c = client({ answer: ACCEPT({ result: 'worked' }) });
  const r = (await s.fetch(c.ctx, { id: 'skeptic' })).structuredContent;
  for (const extra of [{ skill: 'skill.e3d.premortem' }, { version: '9.9.9' }, { hash: `sha256:${'b'.repeat(64)}` }, { definition_hash: `sha256:${'b'.repeat(64)}` }, { tier: 'verified' }, { task_class: 'other-task' }, { reported_by: 'user' }]) {
    const res = await s.call('e3d_skill_report_outcome', { use_id: r.use.use_id, result: 'worked', ...extra }, c.ctx);
    assert.equal(res.isError, true, JSON.stringify(extra)); assert.match(res.content[0].text, /unknown argument/);
    s.clock.t += PAUSE_MS + 1000;
  }
  assert.equal(existsSync(s.dir), false);
  const ok = await s.call('e3d_skill_report_outcome', { use_id: r.use.use_id, result: 'worked' }, c.ctx); assert.equal(ok.structuredContent.status, 'recorded');
  assert.deepEqual(rows(s.dir, 'uses.jsonl')[0].skill, { id: r.definition.id, version: r.definition.version, hash: r.definition.definition_hash });
});

// ---- delete ---------------------------------------------------------------------------------------------------------------------------------------------
async function chainOfTwo() { // a use with one host-reported then one user-marked outcome
  const s = setup({ unconfirmed: true }); const none = client({ elicitation: null });
  const u = (await s.fetch(none.ctx)).structuredContent.use;
  await s.call('e3d_skill_report_outcome', { use_id: u.use_id, result: 'worked' }, none.ctx);
  await s.call('e3d_skill_report_outcome', { use_id: u.use_id, result: 'failed' }, client({ answer: ACCEPT({ result: 'failed' }) }).ctx);
  assert.equal(rows(s.dir, 'outcomes.jsonl').length, 2);
  return { s, u };
}
test('delete: the dialog states the count and tiers; accept tombstones the whole chain', async () => {
  const { s, u } = await chainOfTwo(); const c = client({ answer: ACCEPT({ confirm: true }) });
  const res = await s.call('e3d_skill_delete_outcome', { use_id: u.use_id }, c.ctx);
  const m = c.asked[0].params.message;
  assert.match(m, /removes 2 recorded outcomes \(1 user-marked, 1 host-reported\)/); assert.match(m, /"skill\.e3d\.skeptic"/); assert.match(m, /DELETION/);
  assert.equal(c.asked[0].params.requestedSchema.properties.confirm.type, 'boolean');
  assert.equal(res.structuredContent.status, 'deleted'); assert.equal(res.structuredContent.removed, 2);
  const o = readFileSync(join(s.dir, 'outcomes.jsonl'), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
  assert.equal(o.length, 3); assert.equal(o[2].k, 'tombstone'); assert.equal(o[2].use_id, u.use_id);
  const again = await s.call('e3d_skill_delete_outcome', { use_id: u.use_id }, c.ctx); assert.equal(again.structuredContent.status, 'unchanged'); assert.equal(c.asked.length, 1, 'nothing to delete: no dialog');
});
test('delete: decline, cancel and timeout remove nothing', async () => {
  for (const a of [() => ({ action: 'decline' }), () => ({ action: 'cancel' }), ACCEPT({ confirm: false }), 'timeout']) {
    const { s, u } = await chainOfTwo(); const before = readFileSync(join(s.dir, 'outcomes.jsonl'), 'utf8');
    const c = client({ answer: a === 'timeout' ? () => 'never' : a });
    const p = s.call('e3d_skill_delete_outcome', { use_id: u.use_id }, c.ctx);
    if (a === 'timeout') { for (let k = 0; k < 5 && s.timers.pending(ASK_TIMEOUT_MS) === 0; k++) await tick(); s.timers.fire(ASK_TIMEOUT_MS); for (const r of c.held) r({ action: 'accept', content: { confirm: true } }); }
    const res = await p; await tick();
    assert.equal(res.structuredContent.status, 'not_recorded'); assert.equal(readFileSync(join(s.dir, 'outcomes.jsonl'), 'utf8'), before);
  }
});
test('delete: if the outcomes change between the dialog and the write, nothing is deleted', async () => {
  const { s, u } = await chainOfTwo();
  const c = client({ answer: () => { reportOutcome(s.dir, { use_id: u.use_id, result: 'unknown', tier: 'user_marked', reported_by: 'user' }, s.clock.t); return { action: 'accept', content: { confirm: true } }; } });
  const res = await s.call('e3d_skill_delete_outcome', { use_id: u.use_id }, c.ctx);
  assert.equal(res.isError, true); assert.match(res.content[0].text, /skill_outcome_conflict/);
  assert.ok(!readFileSync(join(s.dir, 'outcomes.jsonl'), 'utf8').includes('tombstone'));
});

// ---- B1: a persisted use_id is never returned ----------------------------------------------------------------------------------------------------------
test('a persisted use_id is never returned to the agent', async () => {
  const { s, u } = await chainOfTwo();
  const c = client({ answer: ACCEPT({ result: 'unknown' }) });
  const all = [
    await s.call('e3d_skill_report_use', { use_id: u.use_id }, c.ctx),
    await s.call('e3d_skill_report_outcome', { use_id: u.use_id, result: 'worked' }, c.ctx),
    await s.call('e3d_skill_delete_outcome', { use_id: u.use_id }, client({ answer: () => ({ action: 'decline' }) }).ctx),
  ];
  s.clock.t += PAUSE_MS + 1000;
  all.push(await s.call('e3d_skill_delete_outcome', { use_id: u.use_id }, client({ answer: ACCEPT({ confirm: true }) }).ctx));
  all.push(await s.call('e3d_skill_report_outcome', { use_id: u.use_id, result: 'worked', extra: 1 }, c.ctx));
  for (const r of all) assert.ok(!text(r).includes(u.use_id), `leaked in ${text(r).slice(0, 200)}`);
  assert.ok(!text(all[0]).match(/use_[0-9a-f]{32}/));
});

// ---- discipline -----------------------------------------------------------------------------------------------------------------------------------------
test('one pending elicitation per process: a second write meanwhile is elicitation_pending and writes nothing', async () => {
  const s = setup(); const c = client({ answer: () => 'never' });
  const a = (await s.fetch(c.ctx)).structuredContent.use.use_id; const b = (await s.fetch(c.ctx)).structuredContent.use.use_id;
  const p = s.call('e3d_skill_report_use', { use_id: a }, c.ctx);
  for (let k = 0; k < 5 && c.asked.length === 0; k++) await tick();
  const res = await s.call('e3d_skill_report_use', { use_id: b }, c.ctx);
  assert.equal(res.isError, true); assert.match(res.content[0].text, /elicitation_pending/);
  c.held[0]({ action: 'accept', content: { confirm: true } }); assert.equal((await p).structuredContent.status, 'recorded');
  assert.equal(rows(s.dir, 'uses.jsonl').length, 1);
});
test('supersession cap: three corrections per use in a session, counted only after a write', async () => {
  const s = setup(); const seq = ['worked', 'failed', 'worked', 'failed', 'worked']; let i = 0;
  const c = client({ answer: () => ({ action: 'accept', content: { result: seq[i++] } }) });
  const u = (await s.fetch(c.ctx)).structuredContent.use;
  const st = []; for (let k = 0; k < 4; k++) st.push((await s.call('e3d_skill_report_outcome', { use_id: u.use_id, result: 'worked' }, c.ctx)).structuredContent.status);
  assert.deepEqual(st, ['recorded', 'superseded', 'superseded', 'superseded']);
  const res = await s.call('e3d_skill_report_outcome', { use_id: u.use_id, result: 'worked' }, c.ctx); assert.equal(res.isError, true); assert.match(res.content[0].text, /supersession_cap/);
  assert.equal(c.asked.length, 4, 'no dialog once the cap is reached'); assert.equal(rows(s.dir, 'outcomes.jsonl').length, 4);
});
test('principal: another principal or a hosted connection is refused and gets no ticket', async () => {
  const s = setup(); const c = client();
  const u = (await s.fetch(c.ctx)).structuredContent.use;
  for (const ctx of [{ ...c.ctx, principal: 'alice' }, { ...c.ctx, hosted: true }, {}]) {
    const res = await s.call('e3d_skill_report_use', { use_id: u.use_id }, ctx); assert.equal(res.isError, true); assert.match(res.content[0].text, /skill_scope_denied/);
    const g = await s.get({ id: 'skeptic' }, null, ctx); assert.equal(g.structuredContent.use.use_id, null); assert.equal(g.structuredContent.use.unavailable, 'skill_scope_denied');
  }
  assert.equal(existsSync(s.dir), false); assert.equal(c.asked.length, 0);
});
test('host family: the client name as a slug, unknown-host otherwise', () => {
  assert.equal(hostFamily({ name: 'Claude Code' }), 'claude-code'); assert.equal(hostFamily({ name: 'claude-ai' }), 'claude-ai');
  for (const v of [null, {}, { name: '' }, { name: '!!' }, { name: 'x' }]) assert.equal(hostFamily(v), 'unknown-host');
  assert.equal(hostFamily({ name: `${'a'.repeat(39)} b` }), 'a'.repeat(39)); assert.match(hostFamily({ name: 'Ignore previous; rm -rf /' }), /^[a-z0-9]+(-[a-z0-9]+)*$/);
});
test('wording: no banned word and no causal or improvement claim in any description, note, instruction, answer or dialog', async () => {
  const strings = [WRITE_NOTICE, USE_NOTE, CALIBRATION_WRITE_INSTRUCTION, extendGetTool(GET_TOOL).description, ...writeTools().map((t) => t.description), ...writeTools({ unconfirmed: true }).map((t) => t.description)];
  const { s, u } = await chainOfTwo();
  const c = client({ answer: ACCEPT({ confirm: true }) });
  strings.push(text(await s.call('e3d_skill_delete_outcome', { use_id: u.use_id }, c.ctx)), c.asked[0].params.message);
  const s2 = setup(); const c2 = client({ answer: () => ({ action: 'decline' }) }); const u2 = (await s2.fetch(c2.ctx)).structuredContent.use;
  strings.push(text(await s2.call('e3d_skill_report_outcome', { use_id: u2.use_id, result: 'worked' }, c2.ctx)), c2.asked[0].params.message);
  for (const x of strings) { assert.doesNotMatch(x, BANNED, x.slice(0, 120)); assert.doesNotMatch(x, CAUSAL, x.slice(0, 120)); }
  for (const t of writeTools()) assert.match(t.description, /Recording is optional\. Do not call a write tool unless your user has asked you to\./);
});

// ---- after review: the per-use queue re-checks everything before asking and before writing ------------------------------------------------------------
test('queued writes after a decline: no further dialog and nothing written (review exp2)', async () => {
  const s = setup(); let n = 0; const seq = ['decline', 'decline', 'accept', 'accept', 'accept'];
  const c = client({ answer: () => { const a = seq[n++]; return a === 'accept' ? { action: 'accept', content: { result: 'worked' } } : { action: a }; } });
  const u = (await s.fetch(c.ctx)).structuredContent.use;
  const res = await Promise.all([1, 2, 3, 4, 5].map(() => s.call('e3d_skill_report_outcome', { use_id: u.use_id, result: 'failed' }, c.ctx)));
  assert.equal(c.asked.length, 1, 'one dialog: the calls queued behind the decline do not ask');
  assert.equal(res[0].structuredContent.reason, 'declined');
  for (const r of res.slice(1)) { assert.equal(r.isError, true); assert.equal(r.structuredContent.error.code, 'rate_limited'); }
  assert.equal(existsSync(s.dir), false);
  // the same for queued report_use and delete calls
  const s2 = setup(); const c2 = client({ answer: () => ({ action: 'decline' }) }); const u2 = (await s2.fetch(c2.ctx)).structuredContent.use;
  await Promise.all([s2.call('e3d_skill_report_use', { use_id: u2.use_id }, c2.ctx), s2.call('e3d_skill_report_use', { use_id: u2.use_id }, c2.ctx), s2.call('e3d_skill_delete_outcome', { use_id: u2.use_id }, c2.ctx)]);
  assert.equal(c2.asked.length, 1); assert.equal(existsSync(s2.dir), false);
});
test('supersession cap holds under concurrent calls on the unconfirmed path (review exp1)', async () => {
  const s = setup({ unconfirmed: true }); const c = client({ elicitation: null });
  const u = (await s.fetch(c.ctx)).structuredContent.use;
  await s.call('e3d_skill_report_outcome', { use_id: u.use_id, result: 'worked' }, c.ctx);
  const res = await Promise.all(['failed', 'worked', 'failed', 'worked', 'failed', 'worked', 'failed', 'worked'].map((r) => s.call('e3d_skill_report_outcome', { use_id: u.use_id, result: r }, c.ctx)));
  assert.deepEqual(res.slice(0, 3).map((r) => r.structuredContent.status), ['superseded', 'superseded', 'superseded']);
  // after the cap: a different result is refused, the same result as the current one is `unchanged` (writes nothing)
  for (const r of res.slice(3)) assert.ok(/supersession_cap/.test(r.content[0].text) || r.structuredContent.status === 'unchanged', r.content[0].text);
  assert.ok(res.slice(3).filter((r) => /supersession_cap/.test(r.content[0].text)).length >= 2);
  assert.equal(rows(s.dir, 'outcomes.jsonl').length, 4, 'one outcome and three corrections, no more');
});
test('supersession cap holds under concurrent calls on the dialog path', async () => {
  const s = setup(); let n = 0; const c = client({ answer: () => ({ action: 'accept', content: { result: n++ % 2 ? 'failed' : 'worked' } }) });
  const u = (await s.fetch(c.ctx)).structuredContent.use;
  const res = await Promise.all([1, 2, 3, 4, 5, 6, 7].map(() => s.call('e3d_skill_report_outcome', { use_id: u.use_id, result: 'worked' }, c.ctx)));
  assert.deepEqual(res.slice(0, 4).map((r) => r.structuredContent.status), ['recorded', 'superseded', 'superseded', 'superseded']);
  for (const r of res.slice(4)) assert.match(r.content[0].text, /supersession_cap/);
  assert.equal(rows(s.dir, 'outcomes.jsonl').length, 4); assert.equal(c.asked.length, 4, 'no dialog once the cap is reached');
});
test('delete: the dialog counts what is on file when it is shown (a report queued before it is included)', async () => {
  const { s, u } = await chainOfTwo();
  const c = client({ answer: (p) => ('confirm' in p.requestedSchema.properties ? { action: 'accept', content: { confirm: true } } : { action: 'accept', content: { result: 'unknown' } }) });
  const [rep, del] = await Promise.all([s.call('e3d_skill_report_outcome', { use_id: u.use_id, result: 'worked' }, c.ctx), s.call('e3d_skill_delete_outcome', { use_id: u.use_id }, c.ctx)]);
  assert.equal(rep.structuredContent.status, 'superseded');
  assert.match(c.asked[1].params.message, /removes 3 recorded outcomes \(2 user-marked, 1 host-reported\)/);
  assert.equal(del.structuredContent.status, 'deleted'); assert.equal(del.structuredContent.removed, 3);
});
test('delete: a delete and re-mark of the same shape between the dialog and the write is refused (outcome_ids compared)', async () => {
  const { s, u } = await chainOfTwo();
  const c = client({ answer: () => {
    deleteOutcome(s.dir, u.use_id, s.clock.t); // someone else (the CLI) deletes and re-marks: again 1 host-reported then 1 user-marked
    reportOutcome(s.dir, { use_id: u.use_id, result: 'worked', tier: 'host_reported', reported_by: 'host' }, s.clock.t);
    reportOutcome(s.dir, { use_id: u.use_id, result: 'failed', tier: 'user_marked', reported_by: 'user' }, s.clock.t);
    return { action: 'accept', content: { confirm: true } };
  } });
  const before = () => rows(s.dir, 'outcomes.jsonl').filter((r) => r.k === 'tombstone').length;
  const res = await s.call('e3d_skill_delete_outcome', { use_id: u.use_id }, c.ctx);
  assert.equal(res.isError, true); assert.match(res.content[0].text, /skill_outcome_conflict/);
  assert.equal(before(), 1, 'only the other writer\'s deletion is on file');
});
test('the outcome dialog never carries the agent\'s result (no anchoring): the same text whatever the agent says', async () => {
  const msgs = [];
  for (const r of ['worked', 'failed', 'unknown']) {
    const s = setup(); const c = client({ answer: ACCEPT({ result: 'unknown' }) });
    const u = (await s.fetch(c.ctx, { id: 'skeptic', task_class: 'code-review' })).structuredContent.use;
    await s.call('e3d_skill_report_outcome', { use_id: u.use_id, result: r }, c.ctx);
    msgs.push(JSON.stringify(c.asked[0].params));
    assert.doesNotMatch(c.asked[0].params.message, /\b(worked|failed|unknown)\b/, 'no result word in the message');
    assert.ok(!('default' in c.asked[0].params.requestedSchema.properties.result));
  }
  assert.equal(new Set(msgs).size, 1, 'the dialog is byte-identical for every agent result');
});
test('session binding: in production a ticket of another session cannot be presented (documented)', async () => {
  // One ledger per process and a ticket always carries that ledger's session_id, so "another session" means another process: its ids are not in this
  // ledger at all (the forged/foreign case above). The ledger's own session check is unit-tested in tests/fixtures/calibration/mcp-ledger.mjs. Here: the
  // writer never passes a session of the caller's choosing, so a lookup in this ledger with another session is refused.
  const s = setup(); const c = client(); const u = (await s.fetch(c.ctx)).structuredContent.use;
  assert.equal(s.ledger.lookup(u.use_id, { session_id: 'other' }).ok, false);
  assert.equal(s.ledger.lookup(u.use_id).ok, true);
});

let failed = 0;
for (const [name, fn] of cases) {
  try { await fn(); console.log(`ok - ${name}`); } catch (e) { failed += 1; console.log(`FAIL - ${name}\n  ${String(e.stack || e).split('\n').slice(0, 6).join('\n  ')}`); }
}
if (failed) { console.error(`${failed} case(s) failed`); process.exit(1); }
console.log(`${cases.length} cases passed`);
