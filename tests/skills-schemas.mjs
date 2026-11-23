// Schema harness for docs/skills/schemas/v1 (Phase 1 of the user-defined skills work; docs/skills/phase1/).
// A small validator for the JSON Schema subset those schemas use, so the repo stays zero-dependency: type, enum, const, pattern, length and
// range limits, required, properties, additionalProperties, items, uniqueItems, anyOf, not, $ref (local and sibling files) and the
// annotation "x-code" (the stable error code to report when that subschema fails). Each failure maps to one stable code
// (docs/skills/schemas/v1/error-codes.json). Reference semantic checks (hash, composition graph, hook/target fit, capability ceiling) live
// here only to prove the fixtures; the engine re-implements them in Phase 2 and 4.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { contentHash, compositionProblems } from './fixtures/skills/reference.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SCHEMAS = join(ROOT, 'docs/skills/schemas/v1');
const FX = join(ROOT, 'tests/fixtures/skills');
const cache = new Map();
const load = (file) => { if (!cache.has(file)) cache.set(file, JSON.parse(readFileSync(join(SCHEMAS, file), 'utf8'))); return cache.get(file); };
const SUPPORTED = new Set(['$schema', '$id', 'title', '$defs', 'type', 'enum', 'const', 'pattern', 'minLength', 'maxLength', 'minimum', 'maximum', 'minItems', 'maxItems', 'maxProperties', 'uniqueItems', 'required', 'properties', 'additionalProperties', 'items', 'anyOf', 'not', '$ref', 'x-code']);

const typeOf = (v) => (v === null ? 'null' : Array.isArray(v) ? 'array' : Number.isInteger(v) ? 'integer' : typeof v);
const isType = (v, t) => (t === 'number' ? typeof v === 'number' : t === 'integer' ? Number.isInteger(v) : typeOf(v) === t);
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

function resolve(schema, ctx) {
  if (!schema.$ref) return { schema, ctx };
  const [file, frag] = schema.$ref.split('#');
  const doc = file ? load(file) : ctx.doc;
  let node = doc;
  if (frag) for (const part of frag.split('/').slice(1)) node = node[part];
  return resolve(node, { doc: file ? doc : ctx.doc });
}

// returns [{ path, code, message }]
export function validate(value, schema, ctx, path = '$') {
  for (const k of Object.keys(schema)) if (!SUPPORTED.has(k)) throw new Error(`schema keyword not supported by the harness: ${k}`);
  const r = resolve(schema, ctx);
  const s = r.schema; ctx = r.ctx;
  const errs = [];
  const fail = (code, message) => errs.push({ path, code, message });
  if (s.type !== undefined) {
    const types = Array.isArray(s.type) ? s.type : [s.type];
    if (!types.some((t) => isType(value, t))) { fail('skill_schema_type', `expected ${types.join('|')}, got ${typeOf(value)}`); return override(errs, s); }
  }
  if (s.const !== undefined && !same(value, s.const)) fail('skill_schema_value', `must equal ${JSON.stringify(s.const)}`);
  if (s.enum && !s.enum.some((e) => same(e, value))) fail('skill_schema_value', 'not an allowed value');
  if (typeof value === 'string') {
    if (s.pattern && !new RegExp(s.pattern).test(value)) fail('skill_schema_format', `does not match ${s.pattern}`);
    if (s.minLength !== undefined && value.length < s.minLength) fail('skill_schema_limit', 'too short');
    if (s.maxLength !== undefined && value.length > s.maxLength) fail('skill_schema_limit', 'too long');
  }
  if (typeof value === 'number') {
    if (s.minimum !== undefined && value < s.minimum) fail('skill_schema_limit', `below ${s.minimum}`);
    if (s.maximum !== undefined && value > s.maximum) fail('skill_schema_limit', `above ${s.maximum}`);
  }
  if (Array.isArray(value)) {
    if (s.minItems !== undefined && value.length < s.minItems) fail('skill_schema_limit', `fewer than ${s.minItems} items`);
    if (s.maxItems !== undefined && value.length > s.maxItems) fail('skill_schema_limit', `more than ${s.maxItems} items`);
    if (s.uniqueItems && new Set(value.map((v) => JSON.stringify(v))).size !== value.length) fail('skill_schema_duplicate', 'items must be distinct');
    if (s.items) value.forEach((v, i) => errs.push(...validate(v, s.items, ctx, `${path}[${i}]`)));
  }
  if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
    const props = s.properties ?? {};
    for (const k of s.required ?? []) if (!(k in value)) errs.push({ path: `${path}.${k}`, code: 'skill_schema_missing_field', message: 'required' });
    if (s.maxProperties !== undefined && Object.keys(value).length > s.maxProperties) fail('skill_schema_limit', `more than ${s.maxProperties} properties`);
    for (const k of Object.keys(value)) {
      if (k in props) errs.push(...validate(value[k], props[k], ctx, `${path}.${k}`));
      else if (s.additionalProperties === false) errs.push({ path: `${path}.${k}`, code: 'skill_schema_unknown_field', message: 'unknown field' });
      else if (s.additionalProperties && typeof s.additionalProperties === 'object') errs.push(...validate(value[k], s.additionalProperties, ctx, `${path}.${k}`));
    }
  }
  if (s.anyOf) {
    const tries = s.anyOf.map((sub) => validate(value, sub, ctx, path));
    if (!tries.some((t) => t.length === 0)) {
      // report the closest alternative: the one with the fewest failures (a null or wrong-type branch is the farthest)
      const best = tries.reduce((a, b) => (b.length < a.length ? b : a));
      errs.push(...best);
    }
  }
  if (s.not && validate(value, s.not, ctx, path).length === 0) fail('skill_schema_value', 'this field is not allowed');
  return override(errs, s);
}
// a failing subschema with x-code reports that code instead of the generic ones it produced
function override(errs, s) {
  if (!s['x-code'] || errs.length === 0) return errs;
  return errs.map((e) => ({ ...e, code: s['x-code'] }));
}

const loadSchema = (name) => ({ schema: load(`${name}.schema.json`), ctx: { doc: load(`${name}.schema.json`) } });
export function check(name, doc) {
  const { schema, ctx } = loadSchema(name);
  return validate(doc, schema, ctx);
}

// Reference semantic checks, run only after the schema passes. Returns a code or null.
const HOOK_TARGET = { chat: ['before_response', 'after_response'], debate_seat: ['seat_prompt'], debate_observer: ['after_round', 'after_synthesis'] };
export function semantic(kind, schema, doc) {
  if (kind === 'hash' && schema === 'skill-definition') return contentHash(doc) === doc.content_hash ? null : 'skill_hash_mismatch';
  if (kind === 'level' && doc.capability_level === 'instructional') return doc.requested_capabilities.length || doc.limits.max_tool_calls ? 'skill_capability_denied' : null;
  if (kind === 'composition') return compositionProblems(doc);
  if (kind === 'attachment') return HOOK_TARGET[doc.target.type].includes(doc.hook) ? null : 'skill_conflict';
  return null;
}

// ---------- the run ----------
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const manifest = JSON.parse(readFileSync(join(FX, 'manifest.json'), 'utf8'));
  let failures = 0;
  const bad = (m) => { failures++; console.error(`FAIL: ${m}`); };
  const read = (f) => JSON.parse(readFileSync(join(FX, f), 'utf8'));

  // 1. every schema file loads and uses only supported keywords (validate throws on the first unsupported one while walking a fixture)
  for (const v of manifest.valid) {
    const doc = read(v.file);
    const errs = check(v.schema, doc);
    if (errs.length) { bad(`${v.file} should validate: ${errs.map((e) => `${e.path} ${e.code}`).join('; ')}`); continue; }
    if (v.schema === 'skill-definition' && semantic('hash', v.schema, doc)) bad(`${v.file}: content_hash does not match the reference canonical hash`);
    if (v.schema === 'skill-definition' && semantic('level', v.schema, doc)) bad(`${v.file}: instructional skill requests capabilities`);
    if (v.schema === 'skill-composition' && semantic('composition', v.schema, doc)) bad(`${v.file}: composition graph invalid`);
    if (v.schema === 'skill-attachment' && semantic('attachment', v.schema, doc)) bad(`${v.file}: hook does not fit target`);
  }
  // 2. every invalid fixture fails with exactly the listed code
  for (const iv of manifest.invalid) {
    const doc = read(iv.file);
    const errs = check(iv.schema, doc);
    let codes = [...new Set(errs.map((e) => e.code))];
    if (!codes.length && iv.semantic) { const c = semantic(iv.semantic, iv.schema, doc); if (c) codes = [c]; }
    if (codes.length !== 1 || codes[0] !== iv.code) bad(`${iv.file}: expected ${iv.code}, got ${codes.join(',') || 'it validated'}`);
  }
  // 3. every code the fixtures use is in the stable catalogue, and the schema set is complete
  const catalogue = Object.keys(JSON.parse(readFileSync(join(SCHEMAS, 'error-codes.json'), 'utf8')).codes);
  for (const iv of manifest.invalid) if (!catalogue.includes(iv.code)) bad(`${iv.file}: ${iv.code} is not in error-codes.json`);
  const covered = new Set([...manifest.valid, ...manifest.invalid].map((x) => x.schema));
  for (const n of ['skill-definition', 'skill-composition', 'skill-attachment', 'skill-recommendation', 'skill-plan', 'skill-grant', 'skill-run', 'observation', 'evaluation', 'learning-proposal', 'skill-error', 'event']) {
    if (!covered.has(n)) bad(`no fixture covers ${n}`);
    if (!manifest.valid.some((x) => x.schema === n)) bad(`no valid fixture for ${n}`);
    if (!manifest.invalid.some((x) => x.schema === n)) bad(`no invalid fixture for ${n}`);
  }
  if (failures) { console.error(`skills-schemas: ${failures} failure(s)`); process.exit(1); }
  console.log(`skills-schemas: PASS (${manifest.valid.length} valid, ${manifest.invalid.length} invalid)`);
}
