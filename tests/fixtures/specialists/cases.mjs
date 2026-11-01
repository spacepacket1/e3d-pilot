// Cases for lib/debate/specialists.mjs (run by tests/specialists-loader.sh). Builds every fixture in a temp directory; touches nothing else.
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync, utimesSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { LIMITS, hashFolder, loadExperts, validateFolder } from '../../../lib/debate/specialists.mjs';

const T = mkdtempSync(join(tmpdir(), 'specialists-'));
process.on('exit', () => rmSync(T, { recursive: true, force: true }));
let n = 0;
const ok = (name, fn) => { fn(); n += 1; };

let seq = 0;
const tier = () => { const d = join(T, `tier${seq += 1}`); mkdirSync(d, { recursive: true }); return d; };
const skill = (name, { front, body = 'Find the strongest reason this should not be done.', sidecar, extra = {} } = {}) => `---\nname: ${name}\ndescription: Finds the strongest reason a plan should not be done. Use for risk review.\n${front ?? ''}---\n${body}\n`;
function mk(root, name, { skillMd, sidecar, extra = {}, ...rest } = {}) {
  const dir = join(root, name);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'SKILL.md'), skillMd ?? skill(name, rest));
  if (sidecar !== undefined) { mkdirSync(join(dir, 'e3d'), { recursive: true }); writeFileSync(join(dir, 'e3d', 'expert.json'), typeof sidecar === 'string' ? sidecar : JSON.stringify(sidecar)); }
  for (const [rel, content] of Object.entries(extra)) { mkdirSync(dirname(join(dir, rel)), { recursive: true }); writeFileSync(join(dir, rel), content); }
  return dir;
}
const codes = (r) => r.errors.map((e) => e.code);
const bad = (label, code, fn) => ok(label, () => { const r = fn(); assert.equal(r.ok, false, `${label}: should be refused`); assert.ok(codes(r).includes(code), `${label}: expected ${code}, got ${JSON.stringify(codes(r))}`); });

// ---- a valid expert ----
ok('valid expert loads with its fields', () => {
  const root = tier();
  const dir = mk(root, 'skeptic', { front: 'license: MIT\nmetadata:\n  e3d.expert.version: "1"\n  e3d.expert.lens: "assume it fails"\n', sidecar: { schema: 'expert/v1', tasks: ['review-spec'], models: [{ provider: 'grok-build', effort: 'high' }, { provider: 'claude' }], tools: 'none', limits: { max_words: 300 } } });
  const r = validateFolder(dir, { root });
  assert.equal(r.ok, true, JSON.stringify(r.errors));
  assert.equal(r.expert.name, 'skeptic');
  assert.equal(r.expert.license, 'MIT');
  assert.equal(r.expert.metadata['e3d.expert.version'], '1');
  assert.equal(r.expert.sidecar.models[0].provider, 'grok-build');
  assert.match(r.expert.hash, /^sha256:[0-9a-f]{64}$/);
  assert.equal(r.warnings.length, 0);
});
ok('a skill with no sidecar still loads (tools none, no model preference)', () => {
  const root = tier();
  const r = validateFolder(mk(root, 'plain'), { root });
  assert.equal(r.ok, true);
  assert.equal(r.expert.sidecar.tools, 'none');
  assert.deepEqual(r.expert.sidecar.models, []);
  assert.equal(r.expert.sidecarPresent, false);
});

// ---- SKILL.md rules, one case each ----
const v = (name, o) => { const root = tier(); const dir = mk(root, name, o); return validateFolder(dir, { root }); };
bad('missing SKILL.md', 'missing_skill_md', () => { const root = tier(); mkdirSync(join(root, 'x')); return validateFolder(join(root, 'x'), { root }); });
bad('no frontmatter', 'no_frontmatter', () => v('x', { skillMd: 'just text\n' }));
bad('frontmatter not closed', 'no_frontmatter', () => v('x', { skillMd: '---\nname: x\ndescription: d\nbody\n' }));
bad('name missing', 'bad_name', () => v('x', { skillMd: '---\ndescription: d\n---\nbody\n' }));
bad('name with uppercase', 'bad_name', () => v('Skeptic', { skillMd: '---\nname: Skeptic\ndescription: d\n---\nbody\n' }));
bad('name with underscore', 'bad_name', () => v('my_x', { skillMd: '---\nname: my_x\ndescription: d\n---\nbody\n' }));
bad('name with double hyphen', 'bad_name', () => v('a--b', { skillMd: '---\nname: a--b\ndescription: d\n---\nbody\n' }));
bad('name with leading hyphen', 'bad_name', () => v('-ab', { skillMd: '---\nname: -ab\ndescription: d\n---\nbody\n' }));
bad('name over 64 characters', 'bad_name', () => { const nm = 'a'.repeat(65); return v(nm, { skillMd: `---\nname: ${nm}\ndescription: d\n---\nbody\n` }); });
bad('name differs from the folder', 'name_folder_mismatch', () => v('folder', { skillMd: '---\nname: other\ndescription: d\n---\nbody\n' }));
bad('description empty', 'bad_description', () => v('x', { skillMd: '---\nname: x\ndescription: ""\n---\nbody\n' }));
bad('description missing', 'bad_description', () => v('x', { skillMd: '---\nname: x\n---\nbody\n' }));
bad('description over 1024 characters', 'bad_description', () => v('x', { skillMd: `---\nname: x\ndescription: ${'d'.repeat(1025)}\n---\nbody\n` }));
bad('unknown frontmatter field', 'unknown_field', () => v('x', { skillMd: '---\nname: x\ndescription: d\nversion: 2\n---\nbody\n' }));
bad('duplicate frontmatter field', 'duplicate_field', () => v('x', { skillMd: '---\nname: x\ndescription: d\ndescription: e\n---\nbody\n' }));
bad('empty lens text', 'empty_body', () => v('x', { skillMd: '---\nname: x\ndescription: d\n---\n\n' }));
bad(`lens text over ${LIMITS.bodyChars} characters`, 'body_too_large', () => v('x', { body: 'w'.repeat(LIMITS.bodyChars + 1) }));
ok('lens text of exactly the limit is accepted', () => assert.equal(v('x', { body: 'w'.repeat(LIMITS.bodyChars) }).ok, true));
bad('SKILL.md over the size limit', 'skill_md_too_large', () => v('x', { skillMd: `---\nname: x\ndescription: d\n---\n${'w'.repeat(LIMITS.skillMdBytes)}\n` }));
bad('NUL byte in SKILL.md', 'binary_skill_md', () => v('x', { skillMd: '---\nname: x\ndescription: d\n---\nbo\0dy\n' }));
bad('a flow collection is not read', 'yaml_unsupported', () => v('x', { skillMd: '---\nname: x\ndescription: [a, b]\n---\nbody\n' }));
bad('an unclosed quote', 'yaml_unsupported', () => v('x', { skillMd: '---\nname: x\ndescription: "oops\n---\nbody\n' }));
bad('nested metadata', 'bad_metadata', () => v('x', { front: 'metadata:\n  a: "1"\n    b: "2"\n' }));
bad('a metadata key named __proto__', 'bad_metadata', () => v('x', { front: 'metadata:\n  __proto__: "1"\n' }));
bad('metadata value too long', 'bad_metadata', () => v('x', { front: `metadata:\n  k: "${'v'.repeat(LIMITS.metadataValueMax + 1)}"\n` }));
bad('license too long', 'bad_license', () => v('x', { front: `license: ${'L'.repeat(LIMITS.licenseMax + 1)}\n` }));

// ---- the YAML subset ----
ok('quoted strings, escapes, block scalars and colons in plain text parse', () => {
  const md = '---\nname: x\ndescription: >\n  Finds the strongest reason\n  a plan should not be done.\nlicense: "MIT"\ncompatibility: Use for: risk review # a comment\nmetadata:\n  a: "line\\nbreak and \\"quote\\""\n  b: \'it\'\'s\'\n  c: plain\n---\nbody\n';
  const r = v('x', { skillMd: md });
  assert.equal(r.ok, true, JSON.stringify(r.errors));
  assert.equal(r.expert.description, 'Finds the strongest reason a plan should not be done.');
  assert.equal(r.expert.metadata.a, 'line\nbreak and "quote"');
  assert.equal(r.expert.metadata.b, "it's");
  assert.equal(r.expert.metadata.c, 'plain');
});
ok('a literal block scalar keeps its line breaks', () => {
  const r = v('x', { skillMd: '---\nname: x\ndescription: |\n  line one\n  line two\n---\nbody\n' });
  assert.equal(r.ok, true);
  assert.equal(r.expert.description, 'line one\nline two');
});
ok('CRLF line endings are read', () => {
  const r = v('x', { skillMd: '---\r\nname: x\r\ndescription: d\r\n---\r\nbody\r\n' });
  assert.equal(r.ok, true, JSON.stringify(r.errors));
  assert.equal(r.expert.lens, 'body');
});

// ---- allowed-tools and scripts: warned, never granted or run ----
ok('allowed-tools is ignored with a warning', () => {
  const r = v('x', { front: 'allowed-tools: Bash(git:*) Read\n' });
  assert.equal(r.ok, true);
  assert.ok(r.warnings.some((w) => w.code === 'allowed_tools_ignored'));
  assert.equal(JSON.stringify(r.expert).includes('Bash'), false, 'the tool list must not survive into the expert');
});
ok('scripts/ is present: warned, never run', () => {
  const root = tier();
  const marker = join(T, 'RAN');
  const dir = mk(root, 'x', { extra: { 'scripts/run.sh': `#!/bin/sh\ntouch ${marker}\n`, 'scripts/run.mjs': `import {writeFileSync} from 'node:fs'; writeFileSync(${JSON.stringify(marker)}, '1');\n` } });
  const r = validateFolder(dir, { root });
  assert.equal(r.ok, true);
  assert.ok(r.warnings.some((w) => w.code === 'scripts_present_never_run'));
  assert.throws(() => readFileSync(marker), 'a script must never run');
});

// ---- the sidecar ----
bad('tools other than none', 'bad_sidecar', () => v('x', { sidecar: { tools: 'read' } }));
bad('an unknown sidecar field', 'bad_sidecar', () => v('x', { sidecar: { favourite: 1 } }));
bad('a sidecar that is not JSON', 'bad_sidecar', () => v('x', { sidecar: '{nope' }));
bad('a sidecar that is not an object', 'bad_sidecar', () => v('x', { sidecar: '[]' }));
bad('a wrong sidecar schema', 'bad_sidecar', () => v('x', { sidecar: { schema: 'expert/v9' } }));
bad('a model with a bad effort', 'bad_sidecar', () => v('x', { sidecar: { models: [{ provider: 'claude', effort: 'extreme' }] } }));
bad('a model with an invalid provider name', 'bad_sidecar', () => v('x', { sidecar: { models: [{ provider: 'Claude Code!' }] } }));
bad('a model with an extra key', 'bad_sidecar', () => v('x', { sidecar: { models: [{ provider: 'claude', url: 'http://x' }] } }));
bad('max_words below the minimum', 'bad_sidecar', () => v('x', { sidecar: { limits: { max_words: 5 } } }));
bad('an unknown limit', 'bad_sidecar', () => v('x', { sidecar: { limits: { max_cost: 1 } } }));
bad('too many tasks', 'bad_sidecar', () => v('x', { sidecar: { tasks: Array.from({ length: LIMITS.sidecarList + 1 }, (_, i) => `t${i}`) } }));
ok('required_evidence and tests are accepted and stored, not run', () => {
  const r = v('x', { sidecar: { required_evidence: ['source-code'], tests: [{ fixture_id: 'f1' }, 'plain'] } });
  assert.equal(r.ok, true, JSON.stringify(r.errors));
  assert.deepEqual(r.expert.sidecar.required_evidence, ['source-code']);
});

// ---- the folder ----
bad('a symbolic link inside the skill', 'symlink_in_skill', () => {
  const root = tier();
  const dir = mk(root, 'x');
  symlinkSync('/etc/hostname', join(dir, 'link.txt'));
  return validateFolder(dir, { root });
});
bad('a folder that is a link leaving its tier', 'symlink_escape', () => {
  const root = tier();
  const outside = tier();
  const real = mk(outside, 'x');
  symlinkSync(real, join(root, 'x'));
  return validateFolder(join(root, 'x'), { root });
});
bad(`more than ${LIMITS.files} files`, 'too_many_files', () => {
  const root = tier();
  const extra = {};
  for (let i = 0; i <= LIMITS.files; i++) extra[`refs/f${i}.txt`] = 'x';
  return validateFolder(mk(root, 'x', { extra }), { root });
});
bad('a folder larger than the byte limit', 'too_large', () => {
  const root = tier();
  return validateFolder(mk(root, 'x', { extra: { 'assets/big.bin': Buffer.alloc(LIMITS.totalBytes + 1) } }), { root });
});
bad('a path that does not exist', 'not_found', () => validateFolder(join(T, 'nope')));

// ---- the content hash ----
ok('hash is stable across copies in different places', () => {
  const a = mk(tier(), 'x', { extra: { 'references/r.md': 'ref\n' } });
  const b = mk(tier(), 'x', { extra: { 'references/r.md': 'ref\n' } });
  assert.equal(hashFolder(a), hashFolder(b));
});
ok('hash changes when the lens text, a file, or a file name changes', () => {
  const base = hashFolder(mk(tier(), 'x', { extra: { 'references/r.md': 'ref\n' } }));
  assert.notEqual(base, hashFolder(mk(tier(), 'x', { body: 'a different lens', extra: { 'references/r.md': 'ref\n' } })));
  assert.notEqual(base, hashFolder(mk(tier(), 'x', { extra: { 'references/r.md': 'ref2\n' } })));
  assert.notEqual(base, hashFolder(mk(tier(), 'x', { extra: { 'references/s.md': 'ref\n' } })));
  assert.notEqual(base, hashFolder(mk(tier(), 'x', { extra: { 'references/r.md': 'ref\n', 'extra.txt': 'more' } })));
});
ok('hash ignores line-ending style, .DS_Store and .git', () => {
  const lf = hashFolder(mk(tier(), 'x', { extra: { 'references/r.md': 'one\ntwo\n' } }));
  const crlf = hashFolder(mk(tier(), 'x', { extra: { 'references/r.md': 'one\r\ntwo\r\n' } }));
  assert.equal(lf, crlf);
  const withJunk = hashFolder(mk(tier(), 'x', { extra: { 'references/r.md': 'one\ntwo\n', '.DS_Store': 'junk', '.git/HEAD': 'ref: x' } }));
  assert.equal(lf, withJunk);
});
ok('hash does not depend on file times', () => {
  const dir = mk(tier(), 'x');
  const before = hashFolder(dir);
  utimesSync(join(dir, 'SKILL.md'), new Date(2001, 1, 1), new Date(2001, 1, 1));
  assert.equal(hashFolder(dir), before);
});
ok('binary files hash by their bytes', () => {
  const a = hashFolder(mk(tier(), 'x', { extra: { 'assets/a.bin': Buffer.from([0, 1, 2, 3]) } }));
  const b = hashFolder(mk(tier(), 'x', { extra: { 'assets/a.bin': Buffer.from([0, 1, 2, 4]) } }));
  assert.notEqual(a, b);
});
ok('the metadata hash line is left out of the hash, a stale one is reported, a right one is not', () => {
  const root = tier();
  const dir = mk(root, 'x', { front: 'metadata:\n  e3d.expert.version: "1"\n' });
  const h = hashFolder(dir);
  const withHash = (hash) => writeFileSync(join(dir, 'SKILL.md'), skill('x', { front: `metadata:\n  e3d.expert.version: "1"\n  e3d.expert.hash: "${hash}"\n` }));
  withHash(h);
  assert.equal(hashFolder(dir), h, 'adding the hash line must not change the hash');
  const good = validateFolder(dir, { root });
  assert.equal(good.ok, true);
  assert.equal(good.warnings.some((w) => w.code === 'stale_metadata_hash'), false);
  withHash('sha256:' + '0'.repeat(64));
  const stale = validateFolder(dir, { root });
  assert.equal(stale.ok, true);
  assert.ok(stale.warnings.some((w) => w.code === 'stale_metadata_hash'));
  assert.equal(stale.expert.hash, h, 'the computed hash is the one used, never the claimed one');
});

// ---- the tiers ----
ok('a later tier wins by name and the override is recorded', () => {
  const builtin = tier(), user = tier(), repo = tier();
  mk(builtin, 'skeptic', { skillMd: '---\nname: skeptic\ndescription: built-in version\n---\nlens b\n' });
  mk(user, 'skeptic', { skillMd: '---\nname: skeptic\ndescription: user version\n---\nlens u\n' });
  mk(repo, 'skeptic', { skillMd: '---\nname: skeptic\ndescription: repo version\n---\nlens r\n' });
  mk(builtin, 'customer');
  const r = loadExperts({ tiers: [{ name: 'built-in', dir: builtin }, { name: 'user', dir: user }, { name: 'repo', dir: repo }] });
  assert.deepEqual(r.experts.map((e) => e.name), ['customer', 'skeptic']);
  const s = r.experts.find((e) => e.name === 'skeptic');
  assert.equal(s.tier, 'repo');
  assert.equal(s.description, 'repo version');
  assert.deepEqual(r.overridden, [{ name: 'skeptic', from: 'built-in', by: 'user' }, { name: 'skeptic', from: 'user', by: 'repo' }]);
  assert.equal(r.errors.length, 0);
});
ok('a bad folder in a higher tier does not hide the lower-tier expert', () => {
  const builtin = tier(), user = tier();
  mk(builtin, 'skeptic');
  mk(user, 'skeptic', { skillMd: '---\nname: skeptic\n---\nno description\n' });
  const r = loadExperts({ tiers: [{ name: 'built-in', dir: builtin }, { name: 'user', dir: user }] });
  assert.equal(r.experts.length, 1);
  assert.equal(r.experts[0].tier, 'built-in');
  assert.equal(r.errors.length, 1);
  assert.equal(r.errors[0].tier, 'user');
  assert.ok(r.errors[0].errors.some((e) => e.code === 'bad_description'));
});
ok('a missing tier directory is empty, not an error; stray files and dot folders are skipped', () => {
  const builtin = tier();
  mk(builtin, 'skeptic');
  writeFileSync(join(builtin, 'README.md'), 'not a skill');
  mkdirSync(join(builtin, '.hidden'));
  const r = loadExperts({ tiers: [{ name: 'built-in', dir: builtin }, { name: 'user', dir: join(T, 'does-not-exist') }, { name: 'repo', dir: undefined }] });
  assert.equal(r.experts.length, 1);
  assert.equal(r.errors.length, 0);
});

// ---- the module is read-only and local ----
ok('the module opens no network connection, runs no process, writes nothing', () => {
  const src = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../../lib/debate/specialists.mjs'), 'utf8');
  for (const word of ['child_process', 'node:net', 'node:http', 'node:https', 'node:dgram', 'node:dns', 'fetch(', 'writeFile', 'appendFile', 'mkdirSync', 'rmSync', 'unlinkSync', 'renameSync', 'spawn', 'execSync', 'execFile', 'eval(', 'import(', 'new Function']) {
    assert.equal(src.includes(word), false, `the module must not use ${word}`);
  }
  assert.equal(/(^|[^.\w])exec\(/m.test(src), false, 'the module must not call a bare exec(); RegExp .exec( is fine');
});
ok('loading leaves the folders exactly as they were', () => {
  const root = tier();
  const dir = mk(root, 'x', { sidecar: { schema: 'expert/v1' }, extra: { 'scripts/a.sh': 'echo hi\n' } });
  const before = hashFolder(dir);
  loadExperts({ tiers: [{ name: 'repo', dir: root }] });
  validateFolder(dir, { root });
  assert.equal(hashFolder(dir), before);
});

console.log(`specialists loader: ${n} cases passed`);
