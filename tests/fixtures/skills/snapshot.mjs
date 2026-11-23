// Prints the current expert catalogue facts the skills work must preserve (docs/skills/phase1/compat-baseline.md). Used by
// tests/skills-compat.sh to compare against tests/fixtures/skills/expert-baseline.json; run with --write to regenerate that file on purpose.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadExperts } from '../../../lib/debate/specialists.mjs';
import { lensBlock } from '../../../lib/debate/specialists-plan.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '../../..');
const { experts, errors } = loadExperts({ tiers: [{ name: 'built-in', dir: join(ROOT, 'lib/specialists') }] });
if (errors.length) { console.error(JSON.stringify(errors)); process.exit(1); }
const panels = JSON.parse(readFileSync(join(ROOT, 'lib/specialists/panels.json'), 'utf8'));
const snap = {
  note: 'Built-in expert identity as of the skills Phase 1 grounding. A change here is a deliberate, reviewed change of expert meaning (the content hash is what hosted pins and receipts name).',
  experts: experts.map((e) => ({
    name: e.name, version: e.metadata['e3d.expert.version'] ?? null, hash: e.hash, license: e.license, tools: e.sidecar.tools, tasks: e.sidecar.tasks,
    models: e.sidecar.models, lens_block_bytes: Buffer.byteLength(lensBlock(e), 'utf8'),
  })),
  presets: Object.fromEntries(Object.entries(panels.presets).map(([k, v]) => [k, { min_seats: v.min_seats, experts: v.experts }])),
};
if (process.argv.includes('--write')) writeFileSync(join(ROOT, 'tests/fixtures/skills/expert-baseline.json'), JSON.stringify(snap, null, 2) + '\n');
else process.stdout.write(JSON.stringify(snap, null, 2) + '\n');
