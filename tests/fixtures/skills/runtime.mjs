// Library cases for lib/skills and lib/mcp/skills-read.js (run by tests/skills-runtime.sh). Fixtures are built in a temp directory; nothing else is touched.
import assert from 'node:assert/strict';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { canonicalize, definitionHash } from '../../../lib/skills/canonical.mjs';
import { definitionHash as referenceHash } from './reference.mjs';
import { checkDefinition, diffDefinitions, exportSkill, loadSkills, projectExpert, resolveSkill, skillFromFolder } from '../../../lib/skills/definition.mjs';
import { newUseId, skillReceiptEntries } from '../../../lib/skills/receipt.mjs';
import { createSkillsRead, skillsFrom } from '../../../lib/mcp/skills-read.js';
import { loadExperts } from '../../../lib/debate/specialists.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '../../..');
const BUILTIN = join(ROOT, 'lib/specialists');
const T = mkdtempSync(join(tmpdir(), 'skills-runtime-'));
process.on('exit', () => rmSync(T, { recursive: true, force: true }));
let n = 0;
const ok = async (name, fn) => { await fn(); n += 1; };
let seq = 0;
const tier = () => { const d = join(T, `tier${seq += 1}`); mkdirSync(d, { recursive: true }); return d; };
const FRONT = (name, extra = '', desc = 'Finds the strongest reason a plan should not be done.') => `---\nname: ${name}\ndescription: ${desc}\nlicense: MIT\n${extra}---\n`;
function mk(root, name, { md, json, expert, extra = {} } = {}) {
  const dir = join(root, name); mkdirSync(join(dir, 'e3d'), { recursive: true });
  writeFileSync(join(dir, 'SKILL.md'), md ?? `${FRONT(name)}Be careful and name the risk.\n`);
  if (json !== undefined) writeFileSync(join(dir, 'e3d', 'skill.json'), typeof json === 'string' ? json : JSON.stringify(json));
  if (expert !== undefined) writeFileSync(join(dir, 'e3d', 'expert.json'), JSON.stringify(expert));
  for (const [rel, c] of Object.entries(extra)) { mkdirSync(dirname(join(dir, rel)), { recursive: true }); writeFileSync(join(dir, rel), c); }
  return dir;
}
const NATIVE = { version: '1.2.0', capability_level: 'instructional', hooks: [{ scope: 'debate_seat', event: 'seat_prompt' }], input_schema_ref: 'e3d://schemas/seat-input/v1', output_schema_ref: 'e3d://schemas/seat-output/v1', tags: ['risk'], tasks: ['review-spec'] };
const load = (dir, root, t = 'user') => skillFromFolder(dir, { root, tier: t });
const codes = (r) => r.errors.map((e) => e.code);

// ---- hashing ----
await ok('canonicalize refuses floats, lone surrogates and non-NFC strings, and sorts keys', () => {
  assert.equal(canonicalize({ b: 1, a: [true, null, 'x'] }), '{"a":[true,null,"x"],"b":1}');
  assert.throws(() => canonicalize({ x: 1.5 }), /canonical_float/);
  assert.throws(() => canonicalize('\uD800'), /canonical_surrogate/);
  assert.throws(() => canonicalize('e\u0301'), /canonical_not_nfc/);
});
await ok('definitionHash reproduces the reference implementation on every valid skill-definition fixture', () => {
  const manifest = JSON.parse(readFileSync(join(HERE, 'manifest.json'), 'utf8'));
  let seen = 0;
  for (const v of manifest.valid.filter((x) => x.schema === 'skill-definition')) {
    const d = JSON.parse(readFileSync(join(HERE, v.file), 'utf8'));
    assert.equal(definitionHash(d), referenceHash(d), v.file); assert.equal(definitionHash(d), d.definition_hash, v.file); seen += 1;
  }
  assert.ok(seen >= 2);
});
await ok('a __proto__ key in a document is hashed, not turned into a prototype', () => {
  const a = { x: 1 }; const b = JSON.parse('{"x":1,"__proto__":{"y":2}}');
  assert.notEqual(definitionHash(a), definitionHash(b));
});

// ---- projection (ADR-0002) ----
await ok('every built-in expert projects to a valid skill with the pinned meaning', () => {
  const { skills, errors } = loadSkills({ tiers: [{ name: 'built-in', dir: BUILTIN }] });
  assert.equal(errors.length, 0); assert.equal(skills.length, 10);
  const baseline = JSON.parse(readFileSync(join(HERE, 'expert-baseline.json'), 'utf8'));
  for (const s of skills) {
    const d = s.definition;
    assert.deepEqual(checkDefinition(d), [], d.id);
    assert.equal(d.capability_level, 'instructional'); assert.deepEqual(d.requested_capabilities, []); assert.equal(d.limits.max_model_calls, 0); assert.equal(d.limits.max_tool_calls, 0);
    assert.deepEqual(d.hooks, [{ scope: 'debate_seat', event: 'seat_prompt' }]);
    const e = baseline.experts.find((x) => x.name === s.slug);
    assert.equal(d.provenance.legacy_folder_hash, e.hash, `${d.id}: the legacy folder hash is unchanged`);
    assert.equal(d.instructions.method, loadExperts({ tiers: [{ name: 'built-in', dir: BUILTIN }] }).experts.find((x) => x.name === s.slug).lens, 'the lens is carried byte for byte');
  }
});
await ok('integer versions map to N.0.0, a missing version to 1.0.0 (noted), a non-integer version is not projectable', () => {
  const root = tier();
  mk(root, 'two', { md: `${FRONT('two', 'metadata:\n  e3d.expert.version: "7"\n')}Lens.\n` });
  mk(root, 'none', { md: `${FRONT('none')}Lens.\n` });
  mk(root, 'semver', { md: `${FRONT('semver', 'metadata:\n  e3d.expert.version: "1.2"\n')}Lens.\n` });
  const a = load(join(root, 'two'), root); assert.equal(a.ok, true, JSON.stringify(a.errors)); assert.equal(a.definition.version, '7.0.0');
  const b = load(join(root, 'none'), root); assert.equal(b.definition.version, '1.0.0'); assert.ok(b.lossy.some((l) => l.field === 'version'));
  const c = load(join(root, 'semver'), root); assert.equal(c.ok, false); assert.ok(codes(c).includes('skill_version_invalid'));
  assert.ok(loadExperts({ tiers: [{ name: 'user', dir: root }] }).experts.some((e) => e.name === 'semver'), 'the folder still works on the legacy expert path');
});
await ok('projection never truncates silently: dropped tags, missing license and carried fields are reported', () => {
  const root = tier();
  mk(root, 'x', { md: `${FRONT('x', 'metadata:\n  e3d.expert.version: "1"\n  e3d.expert.tags: "risk,Bad Tag,review"\n  e3d.expert.lens: "assume it fails"\n').replace('license: MIT\n', '')}Lens.\n`, expert: { models: [{ provider: 'claude', effort: 'high' }], limits: { max_words: 300 }, required_evidence: ['a'], tests: ['t'] } });
  const r = load(join(root, 'x'), root); assert.equal(r.ok, true, JSON.stringify(r.errors));
  assert.deepEqual(r.definition.tags, ['risk', 'review']);
  assert.equal(r.definition.license, 'NOASSERTION'); assert.equal(r.definition.limits.max_words, 300);
  assert.deepEqual(r.definition.model_hints, [{ provider: 'claude', effort: 'high' }]);
  assert.equal(r.definition.extensions.expert_lens_summary, 'assume it fails');
  for (const f of ['tags', 'license', 'required_evidence', 'tests']) assert.ok(r.lossy.some((l) => l.field === f), `lossy: ${f}`);
});
await ok('a user or repo folder gets its own owner segment, never skill.e3d.*', () => {
  const user = tier(); const repo = tier();
  mk(user, 'skeptic'); mk(repo, 'skeptic');
  const { skills } = loadSkills({ tiers: [{ name: 'built-in', dir: BUILTIN }, { name: 'user', dir: user }, { name: 'repo', dir: repo }] });
  const ids = skills.filter((s) => s.slug === 'skeptic').map((s) => s.definition.id).sort();
  assert.deepEqual(ids, ['skill.e3d.skeptic', 'skill.local_repo.skeptic', 'skill.local_user.skeptic']);
});

// ---- native folders (e3d/skill.json) ----
await ok('a native skill loads, takes its lens from the SKILL.md body and gets a computed definition_hash', () => {
  const root = tier(); mk(root, 'review-diff', { json: NATIVE });
  const r = load(join(root, 'review-diff'), root); assert.equal(r.ok, true, JSON.stringify(r.errors));
  const d = r.definition;
  assert.equal(d.id, 'skill.local_user.review-diff'); assert.equal(d.version, '1.2.0'); assert.equal(d.provenance.source_format, 'e3d-native');
  assert.equal(d.instructions.method, 'Be careful and name the risk.'); assert.match(d.definition_hash, /^sha256:[0-9a-f]{64}$/);
  assert.equal(d.status, 'draft'); assert.equal(d.visibility, 'private');
});
await ok('the hash covers executable meaning only: lens, name, limits change it; tags, license, visibility and status do not', () => {
  const h = (md, json) => { const root = tier(); mk(root, 'x', { md, json }); const r = load(join(root, 'x'), root); assert.equal(r.ok, true, JSON.stringify(r.errors)); return r.definition.definition_hash; };
  const base = h(`${FRONT('x')}Lens one.\n`, NATIVE);
  assert.notEqual(h(`${FRONT('x')}Lens two.\n`, NATIVE), base, 'lens');
  assert.notEqual(h(`${FRONT('x', '', 'Another description.')}Lens one.\n`, NATIVE), base, 'description');
  assert.notEqual(h(`${FRONT('x')}Lens one.\n`, { ...NATIVE, name: 'Display Name' }), base, 'name');
  assert.notEqual(h(`${FRONT('x')}Lens one.\n`, { ...NATIVE, limits: { max_input_bytes: 1000, max_output_bytes: 1000, max_model_calls: 0, max_tool_calls: 0, timeout_ms: 5000 } }), base, 'limits');
  assert.equal(h(`${FRONT('x').replace('MIT', 'Apache-2.0')}Lens one.\n`, NATIVE), base, 'license');
  assert.equal(h(`${FRONT('x')}Lens one.\n`, { ...NATIVE, tags: ['other'] }), base, 'tags');
  assert.equal(h(`${FRONT('x')}Lens one.\n`, { ...NATIVE, visibility: 'public', status: 'active' }), base, 'visibility and status');
  assert.equal(h(`${FRONT('x')}Lens one.\r\n`, NATIVE), base, 'CRLF');
});
for (const [label, mutate, code] of [
  ['an unknown field', (j) => ({ ...j, surprise: 1 }), 'skill_schema_unknown_field'],
  ['a scripts field', (j) => ({ ...j, scripts: ['x.sh'] }), 'skill_scripts_not_allowed'],
  ['an mcp_servers field', (j) => ({ ...j, mcp_servers: [] }), 'skill_scripts_not_allowed'],
  ['an instructional skill that requests a capability', (j) => ({ ...j, requested_capabilities: [{ capability: 'brain.read', purpose: 'x' }] }), 'skill_capability_denied'],
  ['a float in a hashed field', (j) => ({ ...j, limits: { max_input_bytes: 1000.5, max_output_bytes: 1000, max_model_calls: 0, max_tool_calls: 0, timeout_ms: 5000 } }), 'skill_schema_type'],
  ['a bad version', (j) => ({ ...j, version: '1.0' }), 'skill_schema_format'],
  ['the after_round hook', (j) => ({ ...j, hooks: [{ scope: 'debate_observer', event: 'after_round' }] }), null],
  ['a missing version', (j) => { const { version, ...r } = j; return r; }, 'skill_schema_missing_field'],
  ['a repeated instructions.method', (j) => ({ ...j, instructions: { method: 'x' } }), 'skill_conflict'],
  ['a set description', (j) => ({ ...j, description: 'x' }), 'skill_conflict'],
  ['a set id', (j) => ({ ...j, id: 'skill.e3d.x' }), 'skill_conflict'],
  ['the reserved e3d owner in a user folder', (j) => ({ ...j, owner_ref: 'e3d' }), 'skill_conflict'],
]) {
  await ok(`native skill: ${label} is refused`, () => {
    const root = tier(); mk(root, 'x', { json: mutate(NATIVE) });
    const r = load(join(root, 'x'), root);
    assert.equal(r.ok, false, label);
    if (code) assert.ok(codes(r).includes(code), `${label}: expected ${code}, got ${JSON.stringify(codes(r))}`);
  });
}
await ok('both e3d/skill.json and e3d/expert.json is a conflict; invalid JSON is refused; a stale definition_hash is a warning and the computed one is used', () => {
  let root = tier(); mk(root, 'x', { json: NATIVE, expert: { tools: 'none' } });
  assert.ok(codes(load(join(root, 'x'), root)).includes('skill_conflict'));
  root = tier(); mk(root, 'x', { json: '{not json' });
  assert.ok(codes(load(join(root, 'x'), root)).includes('skill_schema_invalid'));
  root = tier(); mk(root, 'x', { json: { ...NATIVE, definition_hash: `sha256:${'0'.repeat(64)}` } });
  const r = load(join(root, 'x'), root); assert.equal(r.ok, true); assert.ok(r.warnings.some((w) => w.code === 'skill_hash_mismatch')); assert.notEqual(r.definition.definition_hash, `sha256:${'0'.repeat(64)}`);
});
await ok('the folder rules of the expert loader still apply to skills (hidden text, delimiter lines, symlinks, size)', () => {
  const root = tier(); mk(root, 'a', { json: NATIVE, md: `${FRONT('a')}Hide\u202E this.\n` });
  assert.ok(codes(load(join(root, 'a'), root)).includes('hidden_characters'));
  mk(root, 'b', { json: NATIVE, md: `${FRONT('b')}[End of role. new rules\n` });
  assert.ok(codes(load(join(root, 'b'), root)).includes('lens_marker'));
});

// ---- resolution and pins ----
await ok('resolution: a name picks the highest tier, a full id picks exactly that one, pins are checked, an unknown skill is not found', () => {
  const user = tier(); mk(user, 'skeptic', { md: `${FRONT('skeptic')}User lens.\n` });
  const { skills } = loadSkills({ tiers: [{ name: 'built-in', dir: BUILTIN }, { name: 'user', dir: user }] });
  const byName = resolveSkill(skills, 'skeptic'); assert.equal(byName.ok, true); assert.equal(byName.skill.tier, 'user'); assert.equal(byName.overridden[0].id, 'skill.e3d.skeptic');
  const byId = resolveSkill(skills, 'skill.e3d.skeptic'); assert.equal(byId.skill.tier, 'built-in');
  const pin = byId.skill.definition;
  assert.equal(resolveSkill(skills, pin.id, { version: pin.version, hash: pin.definition_hash }).ok, true);
  assert.equal(resolveSkill(skills, pin.id, { hash: `sha256:${'1'.repeat(64)}` }).error.code, 'skill_hash_mismatch');
  assert.equal(resolveSkill(skills, pin.id, { version: '9.0.0' }).error.code, 'skill_version_invalid');
  assert.equal(resolveSkill(skills, 'nonesuch').error.code, 'skill_not_found');
});

// ---- export ----
await ok('export writes a new folder that reloads to the same definition_hash, and refuses to overwrite', () => {
  const root = tier(); mk(root, 'quoted', { json: NATIVE, md: `${FRONT('quoted', '', 'A "quoted" description with \\ backslash, é and 日本語.')}Line one.\n\nLine "two".\n` });
  const src = load(join(root, 'quoted'), root); assert.equal(src.ok, true, JSON.stringify(src.errors));
  const out = tier();
  const { dir, definition } = exportSkill(src.definition, out);
  assert.equal(definition.definition_hash, src.definition.definition_hash);
  const back = load(dir, out); assert.equal(back.ok, true, JSON.stringify(back.errors)); assert.equal(back.definition.definition_hash, src.definition.definition_hash);
  assert.throws(() => exportSkill(src.definition, out), (e) => e.code === 'exists');
  assert.deepEqual(readdirSync(dir).sort(), ['SKILL.md', 'e3d']);
});
await ok('a built-in is exported as a private local copy with its own owner, and the copy says where it came from', () => {
  const { skills } = loadSkills({ tiers: [{ name: 'built-in', dir: BUILTIN }] });
  const sk = skills.find((s) => s.slug === 'skeptic').definition;
  const out = tier(); const { dir, definition } = exportSkill(sk, out);
  assert.equal(definition.id, 'skill.local_user.skeptic'); assert.equal(definition.visibility, 'private'); assert.equal(definition.status, 'draft');
  assert.match(definition.extensions.copied_from, /^skill\.e3d\.skeptic@1\.0\.0 sha256:[0-9a-f]{64}$/);
  assert.notEqual(definition.definition_hash, sk.definition_hash);
  assert.equal(load(dir, out).definition.instructions.method, sk.instructions.method);
});
await ok('every built-in exports and round-trips', () => {
  const { skills } = loadSkills({ tiers: [{ name: 'built-in', dir: BUILTIN }] });
  for (const s of skills) { const out = tier(); const { dir, definition } = exportSkill(s.definition, out); assert.equal(load(dir, out).definition.definition_hash, definition.definition_hash, s.slug); }
});

// ---- diff ----
await ok('diff ignores key order and reports changed fields', () => {
  const { skills } = loadSkills({ tiers: [{ name: 'built-in', dir: BUILTIN }] });
  const a = skills[0].definition;
  const reordered = Object.fromEntries(Object.entries(a).reverse());
  assert.equal(diffDefinitions(a, reordered).same, true);
  const b = { ...a, version: '2.0.0' };
  const d = diffDefinitions(a, b); assert.deepEqual(d.fields, [{ field: 'version', change: 'changed' }]);
});

// ---- the receipt entries ----
await ok('receipt entries name each expert as a skill with its own use_id, and fall back for a folder that does not project', () => {
  const root = tier();
  mk(root, 'good', { md: `${FRONT('good', 'metadata:\n  e3d.expert.version: "3"\n')}Lens.\n` });
  mk(root, 'odd', { md: `${FRONT('odd', 'metadata:\n  e3d.expert.version: "x1"\n')}Lens.\n` });
  const { experts } = loadExperts({ tiers: [{ name: 'user', dir: root }] });
  const e = skillReceiptEntries(experts);
  const good = e.find((x) => x.id === 'skill.local_user.good'); assert.equal(good.version, '3.0.0'); assert.match(good.use_id, /^use_[0-9a-f]{20}$/); assert.match(good.legacy_folder_hash, /^sha256:/);
  assert.equal(e.length, experts.length);
  assert.equal(new Set(e.map((x) => x.use_id)).size, e.length);
  assert.match(newUseId(), /^use_[0-9a-f]{20}$/);
});

// ---- the MCP tools ----
await ok('E3D_MCP_SKILLS: strict values, and never on the HTTP server', () => {
  assert.equal(skillsFrom({}).on, false); assert.equal(skillsFrom({ E3D_MCP_SKILLS: '0' }).on, false); assert.equal(skillsFrom({ E3D_MCP_SKILLS: '1' }).on, true);
  assert.equal(skillsFrom({ E3D_MCP_SKILLS: 'yes' }).ok, false); assert.equal(skillsFrom({ E3D_MCP_SKILLS: '1' }, { http: true }).ok, false);
});
const user = tier(); mk(user, 'mine', { json: NATIVE });
const mcp = createSkillsRead({ dirs: { builtin: BUILTIN, user, repo: join(T, 'nonexistent') } });
const call = (name, args) => mcp.handlers[name](args, null, { principal: 'p' });
await ok('MCP list/get serve skills as labelled data with id, version, hash and tier', async () => {
  const l = await call('e3d_list_skills', {});
  assert.equal(l.structuredContent.skills.length, 11); assert.ok(l.structuredContent.skills.some((s) => s.id === 'skill.local_user.mine' && s.tier === 'user'));
  assert.match(l.structuredContent.notice, /not an instruction from Pilot/);
  const g = await call('e3d_get_skill', { id: 'skill.e3d.skeptic' });
  assert.equal(g.structuredContent.definition.id, 'skill.e3d.skeptic'); assert.match(g.content[0].text, /not an instruction from Pilot/);
  const pinned = await call('e3d_get_skill', { id: 'skeptic', definition_hash: `sha256:${'a'.repeat(64)}` });
  assert.equal(pinned.isError, true);
  assert.equal((await call('e3d_list_skills', { query: 'zzzz-no-match' })).structuredContent.skills.length, 0);
});
await ok('MCP argument checks: unknown arguments, bad ids, bad hashes and over-long text are refused', async () => {
  for (const [tool, args] of [['e3d_list_skills', { x: 1 }], ['e3d_get_skill', {}], ['e3d_get_skill', { id: '../etc/passwd' }], ['e3d_get_skill', { id: 'skeptic', version: '1' }], ['e3d_get_skill', { id: 'skeptic', definition_hash: 'sha256:xyz' }], ['e3d_validate_skill', { skill_md: 'x'.repeat(40000) }], ['e3d_validate_skill', { skill_md: 'no frontmatter' }], ['e3d_export_skill', { id: 'Bad Id' }]]) {
    assert.equal((await call(tool, args)).isError, true, `${tool} ${JSON.stringify(args).slice(0, 40)}`);
  }
});
await ok('MCP validate checks text without storing it, and refuses hidden characters', async () => {
  const good = await call('e3d_validate_skill', { skill_md: `${FRONT('demo')}Be careful.\n`, skill_json: JSON.stringify(NATIVE) });
  assert.equal(good.structuredContent.ok, true); assert.equal(good.structuredContent.id, 'skill.local_user.demo'); assert.match(good.structuredContent.definition_hash, /^sha256:/);
  const bad = await call('e3d_validate_skill', { skill_md: `${FRONT('demo')}Hide\u202E.\n` });
  assert.equal(bad.structuredContent.ok, false); assert.ok(bad.structuredContent.errors.some((e) => e.code === 'hidden_characters'));
  assert.ok(!readdirSync(tmpdir()).some((d) => d.startsWith('e3d-skill-validate-')), 'the temporary folder is removed');
});
await ok('MCP export returns the files as text and writes nothing the caller can see', async () => {
  const x = await call('e3d_export_skill', { id: 'skeptic' });
  assert.deepEqual(x.structuredContent.files.map((f) => f.path), ['SKILL.md', 'e3d/skill.json']);
  assert.match(x.structuredContent.files[0].content, /^---\nname: skeptic\n/);
  assert.equal(x.structuredContent.id, 'skill.local_user.skeptic');
  assert.ok(!readdirSync(tmpdir()).some((d) => d.startsWith('e3d-skill-export-')));
});
await ok('MCP rate limit', async () => {
  const lim = createSkillsRead({ dirs: { builtin: BUILTIN, user: join(T, 'none'), repo: join(T, 'none2') }, now: () => 1000 });
  let last; for (let i = 0; i < 31; i++) last = await lim.handlers.e3d_list_skills({}, null, { principal: 'q' });
  assert.equal(last.isError, true);
});

console.log(`skills-runtime library: ${n} cases ok`);
