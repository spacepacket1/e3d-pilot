// Prints (or with --write regenerates ON PURPOSE) tests/fixtures/skills/projection-baseline.json: the id, version, definition_hash and legacy folder hash
// of every built-in expert projected to a skill by lib/skills/definition.mjs. tests/skills-runtime.sh compares against it, so a change of a built-in
// expert's meaning or of the projection cannot pass unnoticed.
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadSkills } from '../../../lib/skills/definition.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '../../..');
const { skills, errors } = loadSkills({ tiers: [{ name: 'built-in', dir: join(ROOT, 'lib/specialists') }] });
if (errors.length) { console.error('a built-in expert does not project:', JSON.stringify(errors)); process.exit(1); }
const out = {
  note: 'id, version, definition_hash and legacy folder hash of every built-in expert projected to a skill (docs/skills ADR-0002, ADR-0003). A change here means a built-in expert changed meaning or the projection changed: regenerate ON PURPOSE (node tests/fixtures/skills/projection-snapshot.mjs --write) and say so in the PR.',
  skills: Object.fromEntries(skills.map((s) => [s.definition.id, { version: s.definition.version, definition_hash: s.definition.definition_hash, legacy_folder_hash: s.definition.provenance.legacy_folder_hash }])),
};
const text = `${JSON.stringify(out, null, 2)}\n`;
if (process.argv.includes('--write')) { writeFileSync(join(ROOT, 'tests/fixtures/skills/projection-baseline.json'), text); console.log('wrote projection-baseline.json'); } else process.stdout.write(text);
