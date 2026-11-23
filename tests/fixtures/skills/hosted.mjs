// Library cases for lib/skills/hosted.mjs (run by tests/skills-hosted.sh). Temp files only; no model, no network.
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { addHosted, readHostedFile, HOSTED_FILE_MAX } from '../../../lib/skills/hosted.mjs';
import { makeHosted } from './hosted-make.mjs';

const T = mkdtempSync(join(tmpdir(), 'skills-hosted-'));
process.on('exit', () => rmSync(T, { recursive: true, force: true }));
const P = 'u_abc123def456';
let n = 0; const ok = (name, fn) => { fn(); n += 1; };
const put = (name, obj) => { const f = join(T, name); writeFileSync(f, typeof obj === 'string' ? obj : JSON.stringify(obj)); return f; };
const base = { skills: [] };
const two = makeHosted(P, [{ name: 'lens-a', body: 'LENS-A-MARK. Argue the opposite.', hooks: ['seat'] }, { name: 'lens-b', body: 'LENS-B-MARK. Look for the cost.', hooks: ['seat', 'observer'] }]);

ok('a good file adds each definition as tier hosted, reachable by full id', () => {
  const r = addHosted(base, put('good.json', { principal: P, skills: two }));
  assert.ok(r.ok, JSON.stringify(r.error)); assert.equal(r.catalogue.skills.length, 2);
  assert.deepEqual(r.catalogue.skills.map((s) => s.tier), ['hosted', 'hosted']); assert.equal(r.principal, P);
});
ok('the file must be exactly { principal, skills }, 1 to 4 definitions, a regular file under the size cap', () => {
  for (const [name, body, code] of [['extra.json', { principal: P, skills: two, note: 'x' }, 'skill_schema_unknown_field'], ['nop.json', { skills: two }, 'skill_schema_unknown_field'], ['none.json', { principal: P, skills: [] }, 'skill_schema_limit'], ['five.json', { principal: P, skills: [two[0], two[1], two[0], two[1], two[0]] }, 'skill_schema_limit'], ['arr.json', [1], 'skill_schema_unknown_field'], ['bad.json', '{not json', 'skill_schema_invalid'], ['str.json', { principal: P, skills: 'x' }, 'skill_schema_limit']]) {
    const r = readHostedFile(put(name, body)); assert.ok(!r.ok && r.error.code === code, `${name}: ${JSON.stringify(r)}`);
  }
  assert.equal(readHostedFile(join(T, 'missing.json')).error.code, 'skill_not_found');
  assert.equal(readHostedFile(T).error.code, 'skill_invalid', 'a directory');
  symlinkSync(join(T, 'good.json'), join(T, 'link.json')); assert.ok(!readHostedFile(join(T, 'link.json')).ok, 'a symlink is refused');
  assert.equal(readHostedFile(put('big.json', ' '.repeat(HOSTED_FILE_MAX + 1))).error.code, 'skill_too_large');
});
ok('all or nothing: one refused definition refuses the whole file, and the error carries codes, not text', () => {
  const bad = makeHosted(P, [{ name: 'lens-a', body: 'LENS-A-MARK.', hooks: ['seat'] }, { name: 'sneaky', body: 'SECRET-BODY-TEXT', hooks: ['seat'], mutate: 'tools' }]);
  const r = addHosted(base, put('mix.json', { principal: P, skills: bad }));
  assert.ok(!r.ok && r.error.code === 'skill_capability_denied'); assert.ok(!JSON.stringify(r).includes('SECRET-BODY-TEXT'));
  assert.ok(!addHosted(base, put('pub.json', { principal: P, skills: makeHosted(P, [{ name: 'p', body: 'x', hooks: ['seat'], mutate: 'public' }]) })).ok, 'a public skill');
});
ok('a principal that does not own the definitions, an invalid principal, and a repeated id are refused', () => {
  assert.equal(addHosted(base, put('other.json', { principal: 'u_someoneelse1', skills: two })).error.code, 'skill_tenant_denied');
  assert.equal(addHosted(base, put('e3d.json', { principal: 'e3d', skills: two })).error.code, 'skill_tenant_denied');
  assert.equal(addHosted(base, put('dup.json', { principal: P, skills: [two[0], two[0]] })).error.code, 'skill_conflict');
});
ok('the base catalogue is not mutated', () => {
  const b = { skills: [], errors: [] }; addHosted(b, put('g2.json', { principal: P, skills: two })); assert.equal(b.skills.length, 0);
});
console.log(`hosted library cases: ${n} ok`);
