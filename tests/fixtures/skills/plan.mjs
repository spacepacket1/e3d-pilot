// Library cases for lib/skills/plan.mjs and the planner (lib/debate/specialists-cli.mjs plan) with seat skills (run by tests/skills-plan.sh). Temp directories only.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadSkills } from '../../../lib/skills/definition.mjs';
import { buildPreview, expertFromSkill, parseSeatSkill, planDigest, renderPreview, resolveSeatSkill } from '../../../lib/skills/plan.mjs';
import { loadExperts } from '../../../lib/debate/specialists.mjs';
import { check } from '../../skills-schemas.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '../../..');
const BUILTIN = join(ROOT, 'lib/specialists');
const CLI = join(ROOT, 'lib/debate/specialists-cli.mjs');
const T = mkdtempSync(join(tmpdir(), 'skills-plan-'));
process.on('exit', () => rmSync(T, { recursive: true, force: true }));
let n = 0;
const ok = (name, fn) => { fn(); n += 1; };
let seq = 0;
const tier = () => { const d = join(T, `t${seq += 1}`); mkdirSync(d, { recursive: true }); return d; };
const FRONT = (name, extra = '') => `---\nname: ${name}\ndescription: A skill for seat tests.\nlicense: MIT\n${extra}---\n`;
const NATIVE = { version: '1.0.0', capability_level: 'instructional', hooks: [{ scope: 'debate_seat', event: 'seat_prompt' }], input_schema_ref: 'e3d://schemas/seat-input/v1', output_schema_ref: 'e3d://schemas/seat-output/v1' };
function mk(root, name, { body = 'Take the strongest opposing view.', json = NATIVE } = {}) {
  const dir = join(root, name); mkdirSync(join(dir, 'e3d'), { recursive: true });
  writeFileSync(join(dir, 'SKILL.md'), `${FRONT(name)}${body}\n`); writeFileSync(join(dir, 'e3d', 'skill.json'), JSON.stringify(json)); return dir;
}
const cat = (user) => loadSkills({ tiers: [{ name: 'built-in', dir: BUILTIN }, ...(user ? [{ name: 'user', dir: user }] : [])] });
// the planner as bin/e3d-debate runs it
function plan(args, user = join(T, 'no-user')) {
  const out = execFileSync(process.execPath, [CLI, 'plan', '--builtin', BUILTIN, '--user', user, '--repo', join(T, 'no-repo'), '--skills', '--rounds', '2', '--max-words', '200', '--synthesizer', 'claude', '--pool', 'claude,codex,gemini,grok-build', ...args], { encoding: 'utf8' }).trim();
  return JSON.parse(out);
}
const planFails = (args, user) => { try { plan(args, user); } catch (e) { return JSON.parse(e.stdout.toString().trim()); } assert.fail('the plan should have been refused'); };

ok('parseSeatSkill: the grammar <id|name>[@version][#hash][:provider]', () => {
  assert.deepEqual(parseSeatSkill('skeptic'), { ref: 'skeptic', version: undefined, hash: undefined, override: null });
  assert.deepEqual(parseSeatSkill('skill.e3d.skeptic@1.2.0#sha256:' + 'a'.repeat(64) + ':claude'), { ref: 'skill.e3d.skeptic', version: '1.2.0', hash: 'sha256:' + 'a'.repeat(64), override: 'claude' });
  assert.equal(parseSeatSkill('skeptic:claude').override, 'claude');
  for (const bad of ['', 'Skeptic', 'skeptic@1.0', 'skeptic#abc', 'skeptic:', 'skeptic:Claude', '../x', 'a b', 'skill.e3d.']) assert.equal(parseSeatSkill(bad), null, bad);
});
ok('expertFromSkill: a built-in as a seat is the same expert the planner already uses (lens, hash, hints)', () => {
  const { experts } = loadExperts({ tiers: [{ name: 'built-in', dir: BUILTIN }] });
  const c = cat();
  for (const e of experts) {
    const x = expertFromSkill(c.skills.find((s) => s.slug === e.name));
    assert.equal(x.lens, e.lens, e.name); assert.equal(x.hash, e.hash, e.name); assert.equal(x.tier, e.tier);
    assert.deepEqual(x.sidecar.models, e.sidecar.models, `${e.name} model hints`);
    assert.deepEqual(x.sidecar.limits, e.sidecar.limits, `${e.name} limits`);
  }
});
for (const [label, spec, code] of [
  ['an unknown skill', 'nonesuch', 'skill_not_found'],
  ['a wrong hash pin', `skeptic#sha256:${'f'.repeat(64)}`, 'skill_hash_mismatch'],
  ['a wrong version pin', 'skeptic@9.0.0', 'skill_version_invalid'],
  ['a bad spec', 'Skeptic!', 'skill_schema_format'],
]) {
  ok(`resolveSeatSkill refuses ${label} with ${code}`, () => { const r = resolveSeatSkill(cat(), spec); assert.equal(r.ok, false); assert.equal(r.error.code, code); });
}
ok('resolveSeatSkill refuses a withdrawn skill and a skill without the seat hook', () => {
  const user = tier();
  mk(user, 'gone', { json: { ...NATIVE, status: 'withdrawn' } });
  mk(user, 'chatonly', { json: { ...NATIVE, hooks: [{ scope: 'chat', event: 'before_response' }] } });
  assert.equal(resolveSeatSkill(cat(user), 'gone').error.code, 'skill_withdrawn');
  assert.equal(resolveSeatSkill(cat(user), 'chatonly').error.code, 'skill_conflict');
});
ok('a native skill: model hints steer the provider, an explicit provider wins, the lens is the skill text', () => {
  const user = tier(); mk(user, 'steered', { json: { ...NATIVE, model_hints: [{ provider: 'gemini' }] } });
  const p = plan(['--specialist', 'skeptic', '--seat-skill', 'steered'].concat([]), user);
  const seat = p.panel.experts.find((e) => e.name === 'steered');
  assert.equal(p.ok, true); assert.equal(seat.adapter, 'gemini'); assert.equal(seat.hint_used, true);
  assert.match(p.lens.gemini, /Take the strongest opposing view\./);
  const forced = plan(['--specialist', 'skeptic', '--seat-skill', 'steered:codex'], user);
  assert.equal(forced.panel.experts.find((e) => e.name === 'steered').adapter, 'codex');
});
ok('the planner mixes --specialist and --seat-skill, records each source, and builds a schema-valid preview', () => {
  const user = tier(); mk(user, 'mine');
  const p = plan(['--specialist', 'skeptic', '--seat-skill', 'premortem', '--seat-skill', 'mine'], user);
  assert.deepEqual(p.preview.seats.map((s) => s.source), ['specialist', 'seat-skill', 'seat-skill']);
  assert.deepEqual(check('skill-preview', p.preview), []);
  assert.deepEqual(p.skills.map((s) => s.source), ['specialist', 'seat-skill', 'seat-skill']);
  assert.ok(p.skills.every((s) => /^use_[0-9a-f]{20}$/.test(s.use_id) && /^att_[0-9a-f]{16}$/.test(s.attachment_id) && s.hook === 'seat_prompt' && s.scope === 'debate_seat'));
  assert.equal(p.skills[2].id, 'skill.local_user.mine');
  assert.match(renderPreview(p.preview), /Seats \(each receives its skill as a role block/);
});
ok('the same skill named twice, or fewer than two seats, is refused', () => {
  assert.match(planFails(['--specialist', 'skeptic', '--seat-skill', 'skeptic']).error, /named twice/);
  assert.match(planFails(['--seat-skill', 'skeptic']).error, /at least two/);
  assert.match(planFails(['--panel', 'risk-review', '--seat-skill', 'skeptic']).error, /not both/);
});
ok('a failing skill stops the plan by default, naming the code; plain_seat makes that seat plain and says so everywhere', () => {
  const bad = `skeptic#sha256:${'e'.repeat(64)}`;
  assert.match(planFails(['--specialist', 'premortem', '--seat-skill', bad]).error, /^skill_hash_mismatch:/);
  const p = plan(['--specialist', 'premortem', '--seat-skill', bad, '--on-seat-skill-failure', 'plain_seat']);
  assert.equal(p.ok, true); assert.equal(p.panel.experts.length, 1); assert.equal(p.panel.plain_seats.length, 1);
  assert.equal(p.panel.plain_seats[0].expert, null); assert.equal(p.panel.plain_seats[0].skill_failed.code, 'skill_hash_mismatch');
  assert.equal(p.lens[p.panel.plain_seats[0].seat], '', 'a plain seat gets no lens');
  assert.equal(p.providers.length, 2);
  assert.equal(p.preview.plain_seats[0].reason, 'skill_failed'); assert.equal(p.preview.plain_seats[0].code, 'skill_hash_mismatch');
  assert.ok(p.skills.some((s) => s.status === 'failed' && s.code === 'skill_hash_mismatch'));
  assert.ok(p.warnings.some((w) => /runs plain/.test(w)));
  assert.deepEqual(check('skill-preview', p.preview), []);
});
ok('the plan digest follows exactly what a run would do', () => {
  const user = tier(); mk(user, 'mine', { body: 'Lens one.' });
  const base = plan(['--specialist', 'skeptic', '--seat-skill', 'mine'], user).preview.plan_digest;
  assert.equal(plan(['--specialist', 'skeptic', '--seat-skill', 'mine'], user).preview.plan_digest, base, 'stable');
  const dig = (args, u = user, extra = []) => execFileSync(process.execPath, [CLI, 'plan', '--builtin', BUILTIN, '--user', u, '--repo', join(T, 'no-repo'), '--skills', '--rounds', '2', '--max-words', '200', '--synthesizer', 'claude', '--pool', 'claude,codex,gemini,grok-build', ...extra, ...args], { encoding: 'utf8' }).trim();
  const d = (extra, args = ['--specialist', 'skeptic', '--seat-skill', 'mine'], u = user) => JSON.parse(dig(args, u, extra)).preview.plan_digest;
  assert.notEqual(d(['--question-sha', `sha256:${'1'.repeat(64)}`]), base, 'the question');
  assert.notEqual(d(['--pool', 'claude,codex']) , d(['--pool', 'codex,gemini']), 'the pool');
  assert.notEqual(d([], ['--specialist', 'skeptic', '--seat-skill', 'mine:codex']) , d([], ['--specialist', 'skeptic', '--seat-skill', 'mine:gemini']), 'a forced provider');
  const user2 = tier(); mk(user2, 'mine', { body: 'Lens two.' });
  assert.notEqual(d([], undefined, user2), base, 'the lens text of a skill');
  const user3 = tier(); mk(user3, 'mine', { body: 'Lens one.', json: { ...NATIVE, version: '1.0.1' } });
  assert.notEqual(d([], undefined, user3), base, 'a skill version');
  assert.equal(JSON.parse(dig(['--specialist', 'skeptic', '--seat-skill', 'mine'], user, ['--rounds', '3'])).preview.plan_digest === base, false, 'the rounds (a later --rounds wins)');
});
ok('buildPreview refuses to emit something that does not validate, and never carries lens text', () => {
  const c = cat(); const sk = c.skills.find((s) => s.slug === 'skeptic'); const e = expertFromSkill(sk);
  const pv = buildPreview({ seats: [{ seat: 'claude', adapter: 'claude', expert: e, source: 'specialist', hint_used: true, override: null }, { seat: 'codex', adapter: 'codex', expert: expertFromSkill(c.skills.find((s) => s.slug === 'premortem')), source: 'specialist', hint_used: false, override: null }], rounds: 2, maxWords: 200, synthesizer: 'claude', questionSha256: null, catalogue: c });
  assert.ok(!JSON.stringify(pv).includes(sk.definition.instructions.method.slice(0, 40)), 'no instruction text in a preview');
  assert.throws(() => buildPreview({ seats: [], rounds: 2, maxWords: 200, synthesizer: 'claude', catalogue: c }), /does not validate/);
  assert.match(planDigest({ a: 1 }), /^sha256:[0-9a-f]{64}$/);
});

console.log(`skills-plan library: ${n} cases ok`);
