// Schema harness for docs/skills/schemas/v1 (Phase 1 of the user-defined skills work; docs/skills/phase1/). The validator itself now lives in
// lib/skills/jsonschema.mjs (the engine uses it); this harness proves the schemas and fixtures with it. It handles the JSON Schema subset those schemas use: type, enum, const, pattern, length and
// range limits, required, properties, additionalProperties, items, uniqueItems, anyOf, not, $ref (local and sibling files) and the
// annotation "x-code" (the stable error code to report when that subschema fails). Each failure maps to one stable code
// (docs/skills/schemas/v1/error-codes.json). Reference semantic checks (hash, composition graph, hook/target fit, capability ceiling) live
// here only to prove the fixtures; the engine re-implements them in Phase 2 and 4.
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { definitionHash, compositionProblems } from './fixtures/skills/reference.mjs';
import { SUPPORTED, createSchemaSet } from '../lib/skills/jsonschema.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SCHEMAS = join(ROOT, 'docs/skills/schemas/v1');
const FX = join(ROOT, 'tests/fixtures/skills');
const set = createSchemaSet(SCHEMAS); // the engine's own validator (lib/skills/jsonschema.mjs), run against the documented schemas
const { load } = set;
export const validate = set.validate;
export const check = set.check;

// Calibration track record: derived numbers must agree with each other and with the minimum-evidence rule (calibration spec section 3.4 and 9).
export const MIN_RESOLVED = 10;
function recordProblems(d) {
  const tiers = d.by_tier.verified + d.by_tier.user_marked + d.by_tier.host_reported;
  if (d.n_resolved > d.n_uses || tiers !== d.n_resolved) return 'skill_schema_value';
  if (d.n_uses > 0 && d.resolution_rate !== null && Math.abs(d.resolution_rate - d.n_resolved / d.n_uses) > 0.001) return 'skill_schema_value';
  if (d.n_resolved < MIN_RESOLVED && (d.status !== 'insufficient_evidence' || d.success !== null || d.baseline !== null || d.calibration !== null)) return 'skill_record_insufficient';
  if (d.n_resolved >= MIN_RESOLVED && d.status === 'insufficient_evidence') return 'skill_schema_value';
  if (d.success) {
    if (d.success.count > d.n_resolved || Math.abs(d.success.rate - d.success.count / d.n_resolved) > 0.001) return 'skill_schema_value';
    if (d.success.interval95[0] > d.success.rate || d.success.rate > d.success.interval95[1]) return 'skill_schema_value';
  }
  if ((d.status === 'calibrated') !== (d.calibration !== null)) return 'skill_schema_value';
  return null;
}

// Reference semantic checks, run only after the schema passes. Returns a code or null.
const HOOK_TARGET = { chat: ['before_response', 'after_response'], debate_seat: ['seat_prompt'], debate_observer: ['after_round', 'after_synthesis'] };
export function semantic(kind, schema, doc) {
  if (kind === 'hash' && schema === 'skill-definition') return definitionHash(doc) === doc.definition_hash ? null : 'skill_hash_mismatch';
  if (kind === 'level' && doc.capability_level === 'instructional') return doc.requested_capabilities.length || doc.limits.max_tool_calls ? 'skill_capability_denied' : null;
  if (kind === 'composition') return compositionProblems(doc);
  if (kind === 'evaluation') return doc.uncertainty.ci_low > doc.uncertainty.ci_high || doc.uncertainty.level < 0.8 || (doc.quality_status !== 'unknown' && !doc.rubric.approved) ? 'skill_schema_value' : null;
  if (kind === 'attachment') return HOOK_TARGET[doc.target.type].includes(doc.hook) ? null : 'skill_conflict';
  if (kind === 'use') { const span = Date.parse(doc.expires_at) - Date.parse(doc.issued_at); return span <= 0 || span > 90 * 86400000 ? 'skill_schema_limit' : null; }
  if (kind === 'outcome') return (doc.tier === 'verified' && !doc.evidence_ref) || (doc.tier === 'inferred' && doc.result !== 'unknown') ? 'skill_outcome_invalid' : null;
  if (kind === 'record') return recordProblems(doc);
  return null;
}

// ---------- the run ----------
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const manifest = JSON.parse(readFileSync(join(FX, 'manifest.json'), 'utf8'));
  let failures = 0;
  const bad = (m) => { failures++; console.error(`FAIL: ${m}`); };
  const read = (f) => JSON.parse(readFileSync(join(FX, f), 'utf8'));

  // 0. static walk of every schema file: only supported keywords anywhere, and x-code only on leaf subschemas (it overrides every error below it)
  const walkSchema = (node, where) => {
    if (node === null || typeof node !== 'object') return;
    if (Array.isArray(node)) { node.forEach((n, i) => walkSchema(n, `${where}[${i}]`)); return; }
    for (const k of Object.keys(node)) {
      if (!SUPPORTED.has(k)) { bad(`${where}: unsupported schema keyword ${k}`); continue; }
      if (k === 'properties' || k === '$defs') for (const [pk, pv] of Object.entries(node[k])) walkSchema(pv, `${where}.${k}.${pk}`);
      else if (k === 'items' || k === 'not' || k === 'additionalProperties' || k === 'anyOf') walkSchema(node[k], `${where}.${k}`);
    }
    if (node.$ref && Object.keys(node).some((k) => k !== '$ref')) bad(`${where}: $ref must not have sibling keywords (the harness ignores them)`);
    if (node['x-code'] && (node.properties || node.items || node.anyOf)) bad(`${where}: x-code must be on a leaf schema`);
  };
  for (const f of ['common', 'skill-definition', 'skill-composition', 'skill-attachment', 'skill-recommendation', 'skill-plan', 'skill-grant', 'skill-run', 'observation', 'evaluation', 'learning-proposal', 'skill-error', 'event', 'skill-use', 'prediction', 'outcome', 'track-record', 'skill-preview']) walkSchema(load(`${f}.schema.json`), f);
  // 1. every schema file loads and uses only supported keywords (validate throws on the first unsupported one while walking a fixture)
  for (const v of manifest.valid) {
    const doc = read(v.file);
    const errs = check(v.schema, doc);
    if (errs.length) { bad(`${v.file} should validate: ${errs.map((e) => `${e.path} ${e.code}`).join('; ')}`); continue; }
    if (v.schema === 'skill-definition' && semantic('hash', v.schema, doc)) bad(`${v.file}: content_hash does not match the reference canonical hash`);
    if (v.schema === 'skill-definition' && semantic('level', v.schema, doc)) bad(`${v.file}: instructional skill requests capabilities`);
    if (v.schema === 'skill-composition' && semantic('composition', v.schema, doc)) bad(`${v.file}: composition graph invalid`);
    if (v.schema === 'evaluation' && semantic('evaluation', v.schema, doc)) bad(`${v.file}: evaluation cross-field rule`);
    if (v.schema === 'skill-attachment' && semantic('attachment', v.schema, doc)) bad(`${v.file}: hook does not fit target`);
    if (v.schema === 'skill-use' && semantic('use', v.schema, doc)) bad(`${v.file}: use id expiry rule`);
    if (v.schema === 'outcome' && semantic('outcome', v.schema, doc)) bad(`${v.file}: outcome tier rule`);
    if (v.schema === 'track-record' && semantic('record', v.schema, doc)) bad(`${v.file}: track record consistency or minimum-evidence rule`);
  }
  // 2. every invalid fixture fails with exactly the listed code
  for (const iv of manifest.invalid) {
    const doc = read(iv.file);
    const errs = check(iv.schema, doc);
    let codes = [...new Set(errs.map((e) => e.code))];
    if (!codes.length && iv.semantic) { const c = semantic(iv.semantic, iv.schema, doc); if (c) codes = [c]; }
    if (codes.length !== 1 || codes[0] !== iv.code) bad(`${iv.file}: expected ${iv.code}, got ${codes.join(',') || 'it validated'}`);
  }
  // 2b. the schemas the engine ships (lib/skills/schemas/v1) are byte-identical to the documented ones
  const shipped = join(ROOT, 'lib/skills/schemas/v1');
  const docFiles = readdirSync(SCHEMAS).filter((f) => f.endsWith('.json')).sort();
  const libFiles = readdirSync(shipped).filter((f) => f.endsWith('.json')).sort();
  if (JSON.stringify(docFiles) !== JSON.stringify(libFiles)) bad(`lib/skills/schemas/v1 holds ${libFiles.join(',')} but docs/skills/schemas/v1 holds ${docFiles.join(',')}`);
  for (const f of docFiles) if (libFiles.includes(f) && !readFileSync(join(SCHEMAS, f)).equals(readFileSync(join(shipped, f)))) bad(`lib/skills/schemas/v1/${f} differs from docs/skills/schemas/v1/${f}; copy the documented file`);
  // 3. every code the fixtures use is in the stable catalogue, and the schema set is complete
  const catalogue = Object.keys(JSON.parse(readFileSync(join(SCHEMAS, 'error-codes.json'), 'utf8')).codes);
  for (const iv of manifest.invalid) if (!catalogue.includes(iv.code)) bad(`${iv.file}: ${iv.code} is not in error-codes.json`);
  const covered = new Set([...manifest.valid, ...manifest.invalid].map((x) => x.schema));
  for (const n of ['skill-definition', 'skill-composition', 'skill-attachment', 'skill-recommendation', 'skill-plan', 'skill-grant', 'skill-run', 'observation', 'evaluation', 'learning-proposal', 'skill-error', 'event', 'skill-use', 'prediction', 'outcome', 'track-record', 'skill-preview']) {
    if (!covered.has(n)) bad(`no fixture covers ${n}`);
    if (!manifest.valid.some((x) => x.schema === n)) bad(`no valid fixture for ${n}`);
    if (!manifest.invalid.some((x) => x.schema === n)) bad(`no invalid fixture for ${n}`);
  }
  if (failures) { console.error(`skills-schemas: ${failures} failure(s)`); process.exit(1); }
  console.log(`skills-schemas: PASS (${manifest.valid.length} valid, ${manifest.invalid.length} invalid)`);
}
