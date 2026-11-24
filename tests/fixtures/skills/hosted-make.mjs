// Writes a hosted-skills file for a test: node hosted-make.mjs <outfile> <principal> <spec-json>
// spec: [{ name, body, hooks: ["seat"|"observer"...], mutate?: "tools"|"public" }]. Definitions are built from a real native skill folder (so the hash is real),
// then given the owner, id, visibility and status a hosted service would set. Pure; temp folders only.
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { skillFromFolder } from '../../../lib/skills/definition.mjs';
import { definitionHash } from '../../../lib/skills/canonical.mjs';

const HOOKS = { seat: { scope: 'debate_seat', event: 'seat_prompt' }, observer: { scope: 'debate_observer', event: 'after_synthesis' } };
export function makeHosted(principal, spec) {
  const T = mkdtempSync(join(tmpdir(), 'hosted-make-'));
  try {
    return spec.map((s) => {
      const dir = join(T, s.name); mkdirSync(join(dir, 'e3d'), { recursive: true });
      writeFileSync(join(dir, 'SKILL.md'), `---\nname: ${s.name}\ndescription: A hosted skill for tests.\nlicense: MIT\n---\n${s.body}\n`);
      writeFileSync(join(dir, 'e3d', 'skill.json'), JSON.stringify({ version: '1.0.0', capability_level: 'instructional', hooks: s.hooks.map((h) => HOOKS[h]), input_schema_ref: 'e3d://schemas/debate-receipt/v1', output_schema_ref: 'e3d://schemas/observer-report/v1', limits: { max_input_bytes: 64000, max_output_bytes: s.max_output_bytes || 1000, max_model_calls: s.hooks.includes('observer') ? 1 : 0, max_tool_calls: 0, timeout_ms: s.timeout_ms || 60000 }, fallback: { on_unavailable_capability: 'fail', on_invalid_output: s.on_invalid_output || 'return_unstructured_with_warning' } }));
      const r = skillFromFolder(dir, { root: T, tier: 'user' });
      if (!r.ok) throw new Error(JSON.stringify(r.errors));
      const d = structuredClone(r.definition);
      d.owner_ref = principal; d.id = `skill.${principal}.${s.name}`; d.visibility = s.mutate === 'public' ? 'public' : 'private'; d.status = 'active';
      if (s.mutate === 'tools') { d.capability_level = 'tool_enabled'; }
      if (s.rename) { d.name = s.rename; d.id = `skill.${principal}.${s.rename}`; }   // a name the local folder rules would refuse (over 64 characters), for the hosted checks
      d.definition_hash = definitionHash({ ...d, definition_hash: `sha256:${'0'.repeat(64)}` });
      return d;
    });
  } finally { rmSync(T, { recursive: true, force: true }); }
}
if (process.argv[1] && process.argv[1].endsWith('hosted-make.mjs')) {
  const [, , out, principal, spec] = process.argv;
  writeFileSync(out, JSON.stringify({ principal, skills: makeHosted(principal, JSON.parse(spec)) }));
}
