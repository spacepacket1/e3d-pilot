// Skill definitions from skill folders (docs/skills/phase1/adr/0001, 0002, 0003, 0014). Zero dependencies. Reads files only (through the
// hardened loader in ../debate/specialists.mjs, one read per file); writes nothing except exportSkill into a new folder; calls no model, no
// network, runs nothing from a skill folder.
//
//   skillFromFolder(dir, { root, tier }) -> { ok, errors[], warnings[], definition, lossy[], expert }
//       a folder with e3d/skill.json is a NATIVE skill (SKILL.md body = instructions.method, the rest from the JSON); a folder without it is an
//       expert folder, PROJECTED in memory to a definition (ADR-0002). Both are validated against the schema and get their definition_hash.
//   loadSkills({ tiers })                -> { skills[], errors[] }   tiers low to high; every skill has a resolved id, tier and hash
//   exportSkill(definition, outRoot)     -> { dir }                  writes a native skill folder into a NEW directory and proves it round-trips
import { existsSync, lstatSync, mkdirSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createSchemaSet } from './jsonschema.mjs';
import { canonicalize, definitionHash } from './canonical.mjs';
import { LIMITS, validateFolder } from '../debate/specialists.mjs';

export const SCHEMA_DIR = fileURLToPath(new URL('./schemas/v1', import.meta.url));
const schemas = createSchemaSet(SCHEMA_DIR);
export const ERROR_CODES = schemas.load('error-codes.json').codes;

const SKILL_JSON = 'e3d/skill.json';
const EPOCH = '1970-01-01T00:00:00Z';
const OWNER = { 'built-in': 'e3d', user: 'local-user', repo: 'local-repo' };
// fields a native skill.json may not carry: they come from SKILL.md or are set by the loader
const DERIVED = ['id', 'description', 'license', 'provenance', 'definition_hash', 'signature'];
const err = (code, message, path) => ({ code, message, ...(path ? { path } : {}) });
const ownerSeg = (owner) => owner.replace(/-/g, '_');

// ---------- the expert projection (ADR-0002) ----------

// An expert folder as a SkillDefinition, in memory. -> { definition, lossy[], notProjectable[] }
export function projectExpert(expert, tier = 'built-in') {
  const lossy = [];
  const notProjectable = [];
  const owner = OWNER[tier] ?? OWNER.user;
  const rawVersion = expert.metadata['e3d.expert.version'];
  let version = '1.0.0';
  if (rawVersion === undefined) lossy.push({ field: 'version', note: 'no e3d.expert.version: projected as 1.0.0 (inferred)' });
  else if (/^(0|[1-9][0-9]{0,5})$/.test(rawVersion)) version = `${rawVersion}.0.0`;
  else notProjectable.push({ field: 'version', note: `"${String(rawVersion).slice(0, 40)}" is not an integer version; the folder keeps working on the legacy path` });
  const tags = String(expert.metadata['e3d.expert.tags'] ?? '').split(',').map((t) => t.trim()).filter(Boolean);
  const goodTags = tags.filter((t) => /^[a-z0-9]+(-[a-z0-9]+)*$/.test(t) && t.length <= 40).slice(0, 20);
  if (goodTags.length !== tags.length) lossy.push({ field: 'tags', note: `dropped tags that are not slugs: ${tags.filter((t) => !goodTags.includes(t)).join(', ')}` });
  const sc = expert.sidecar;
  if (sc.required_evidence?.length) lossy.push({ field: 'required_evidence', note: 'not read into any prompt today; not carried' });
  if (sc.tests?.length) lossy.push({ field: 'tests', note: 'not read into any prompt today; not carried' });
  const extensions = {};
  const summary = expert.metadata['e3d.expert.lens'];
  if (summary) { if (summary.length <= 200) extensions.expert_lens_summary = summary; else lossy.push({ field: 'e3d.expert.lens', note: 'longer than 200 characters; not carried' }); }
  const limits = { max_input_bytes: 64000, max_output_bytes: 16000, max_model_calls: 0, max_tool_calls: 0, timeout_ms: 60000 };
  if (sc.limits?.max_words !== undefined) limits.max_words = sc.limits.max_words;
  const definition = {
    schema_version: 'e3d.skill/v1',
    id: `skill.${ownerSeg(owner)}.${expert.name}`,
    version,
    name: expert.name,
    description: expert.description,
    owner_ref: owner,
    visibility: tier === 'built-in' ? 'public' : 'private',
    status: 'active',
    capability_level: 'instructional',
    license: expert.license ?? 'NOASSERTION',
    tags: goodTags,
    tasks: sc.tasks ?? [],
    hooks: [{ scope: 'debate_seat', event: 'seat_prompt' }],
    instructions: { method: expert.lens, constraints: [] },
    input_schema_ref: 'e3d://schemas/seat-input/v1',
    output_schema_ref: 'e3d://schemas/seat-output/v1',
    requested_capabilities: [],
    memory_policy: { read: 'none', write: 'none', max_items: 0, allowed_scopes: [] },
    limits,
    model_hints: (sc.models ?? []).map((m) => ({ provider: m.provider, ...(m.effort ? { effort: m.effort } : {}) })),
    fallback: { on_unavailable_capability: 'fail', on_invalid_output: 'return_unstructured_with_warning' },
    ...(Object.keys(extensions).length ? { extensions } : {}),
    provenance: { parent: null, forked_from: null, source_format: 'expert-v1-projection', legacy_folder_hash: expert.hash, created_by: owner, created_at: EPOCH },
    signature: null,
  };
  if (expert.license === null) lossy.push({ field: 'license', note: 'the expert declares none: projected as NOASSERTION' });
  return { definition, lossy, notProjectable };
}

// ---------- a native skill folder ----------

function nativeDefinition(expert, jsonBytes, tier, errors, warnings) {
  let j;
  if (jsonBytes.length > LIMITS.sidecarBytes) { errors.push(err('skill_too_large', `${SKILL_JSON} is larger than ${LIMITS.sidecarBytes} bytes`, SKILL_JSON)); return null; }
  try { j = JSON.parse(jsonBytes.toString('utf8')); } catch { errors.push(err('skill_schema_invalid', `${SKILL_JSON} is not valid JSON`, SKILL_JSON)); return null; }
  if (j === null || typeof j !== 'object' || Array.isArray(j)) { errors.push(err('skill_schema_type', `${SKILL_JSON} must be a JSON object`, SKILL_JSON)); return null; }
  for (const k of DERIVED) if (Object.hasOwn(j, k) && k !== 'definition_hash') errors.push(err('skill_conflict', `${SKILL_JSON} may not set "${k}": it comes from SKILL.md or is set by the loader`, k));
  if (j.instructions && typeof j.instructions === 'object' && Object.hasOwn(j.instructions, 'method')) errors.push(err('skill_conflict', 'instructions.method is the SKILL.md body; do not repeat it in skill.json', 'instructions.method'));
  if (errors.length) return null;
  const owner = j.owner_ref ?? OWNER[tier] ?? OWNER.user;
  // "e3d" is the owner of the built-in skills only (ADR-0014): a user or repo folder is a different skill with its own owner segment, never skill.e3d.<name>.
  if (owner === 'e3d' && tier !== 'built-in') { errors.push(err('skill_conflict', 'owner_ref "e3d" is reserved for the built-in skills; a local skill has its own owner (for example "local-user")', 'owner_ref')); return null; }
  const def = {
    schema_version: 'e3d.skill/v1',
    ...j,
    id: `skill.${ownerSeg(String(owner))}.${expert.name}`,
    name: j.name ?? expert.name,
    description: expert.description,
    owner_ref: owner,
    visibility: j.visibility ?? 'private',
    status: j.status ?? 'draft',
    license: expert.license ?? 'NOASSERTION',
    instructions: { ...(j.instructions ?? {}), method: expert.lens },
    requested_capabilities: j.requested_capabilities ?? [],
    memory_policy: j.memory_policy ?? { read: 'none', write: 'none', max_items: 0, allowed_scopes: [] },
    fallback: j.fallback ?? { on_unavailable_capability: 'fail', on_invalid_output: 'return_unstructured_with_warning' },
    limits: j.limits ?? { max_input_bytes: 64000, max_output_bytes: 16000, max_model_calls: 0, max_tool_calls: 0, timeout_ms: 60000 },
    provenance: { parent: null, forked_from: null, source_format: 'e3d-native', legacy_folder_hash: expert.hash, created_by: String(owner), created_at: EPOCH },
    signature: null,
  };
  if (!def.instructions.constraints) def.instructions.constraints = [];
  const claimed = j.definition_hash;
  delete def.definition_hash;
  return { def, claimed };
}

// -> { ok, errors, warnings, definition, lossy, expert }
export function skillFromFolder(dir, { root, tier = 'user' } = {}) {
  const r = validateFolder(dir, { root, wantFiles: [SKILL_JSON, 'e3d/expert.json'] });
  const errors = r.errors.map((e) => ({ code: e.code, message: e.message, ...(e.file ? { path: e.file } : {}) }));
  const warnings = r.warnings.map((w) => ({ code: w.code, message: w.message, ...(w.file ? { path: w.file } : {}) }));
  if (!r.ok) return { ok: false, errors, warnings, definition: null, lossy: [], expert: null };
  const expert = r.expert;
  const jsonBytes = expert.extras[SKILL_JSON];
  let definition; let lossy = []; let claimed;
  if (jsonBytes) {
    if (expert.extras['e3d/expert.json']) errors.push(err('skill_conflict', 'e3d/skill.json and e3d/expert.json are both present; keep one', 'e3d'));
    const n = errors.length ? null : nativeDefinition(expert, jsonBytes, tier, errors, warnings);
    if (n) { definition = n.def; claimed = n.claimed; }
  } else {
    const p = projectExpert(expert, tier);
    lossy = p.lossy;
    for (const x of p.notProjectable) errors.push(err('skill_version_invalid', `${x.field}: ${x.note}`, x.field));
    if (!p.notProjectable.length) definition = p.definition;
  }
  if (!definition) return { ok: false, errors, warnings, definition: null, lossy, expert };
  // structure first (precise codes: a float is skill_schema_type, not a hashing failure), then the hash, which is computed here and never trusted
  definition.definition_hash = PLACEHOLDER_HASH;
  const structural = schemaProblems(definition);
  if (structural.length) { errors.push(...structural); return { ok: false, errors, warnings, definition: null, lossy, expert }; }
  try { definition.definition_hash = definitionHash(definition); } catch (e) { errors.push(err('skill_schema_invalid', e.message)); return { ok: false, errors, warnings, definition: null, lossy, expert }; }
  errors.push(...checkDefinition(definition));
  if (claimed !== undefined && claimed !== definition.definition_hash) warnings.push(err('skill_hash_mismatch', `skill.json names definition_hash ${claimed} but the computed value is ${definition.definition_hash}; the computed value is used`, 'definition_hash'));
  return { ok: errors.length === 0, errors, warnings, definition: errors.length ? null : definition, lossy, expert };
}

const PLACEHOLDER_HASH = `sha256:${'0'.repeat(64)}`;

// The schema alone. -> [{ code, message, path }] (one per code and path)
function schemaProblems(def) {
  const out = schemas.check('skill-definition', def).map((e) => ({ code: e.code, message: e.message, path: e.path }));
  const seen = new Set();
  return out.filter((e) => { const k = `${e.code}|${e.path}`; if (seen.has(k)) return false; seen.add(k); return true; });
}

// Schema check plus the rules the schema cannot say (the hash, the capability ceiling). -> [{ code, message, path }]
export function checkDefinition(def) {
  const uniq = schemaProblems(def);
  if (uniq.length) return uniq;
  const problems = [];
  let computed;
  try { computed = definitionHash(def); } catch (e) { return [err('skill_schema_invalid', e.message)]; }
  if (computed !== def.definition_hash) problems.push(err('skill_hash_mismatch', `definition_hash ${def.definition_hash} differs from the computed ${computed}`, 'definition_hash'));
  if (def.capability_level === 'instructional' && (def.requested_capabilities.length || def.limits.max_tool_calls)) problems.push(err('skill_capability_denied', 'an instructional skill may not request capabilities or tool calls', 'requested_capabilities'));
  const slug = def.id.split('.').slice(2).join('.');
  if (def.name !== slug && !def.name.trim()) problems.push(err('skill_schema_value', 'name may not be blank', 'name'));
  return problems;
}

// ---------- the tiers ----------

// tiers: low to high precedence [{ name: 'built-in'|'user'|'repo', dir }]. Every valid folder is a skill with its own id; a later tier hides an earlier
// one only for an unqualified name (see resolveSkill). One bad folder never hides the others.
export function loadSkills({ tiers }) {
  const skills = [];
  const errors = [];
  for (const tier of tiers) {
    if (!tier.dir || !existsSync(tier.dir)) continue;
    let entries;
    try { entries = readdirSync(tier.dir).sort(); } catch { continue; }
    for (const entry of entries) {
      if (entry.startsWith('.')) continue;
      const dir = join(tier.dir, entry);
      let st;
      try { st = lstatSync(dir); } catch { continue; }
      if (!st.isDirectory() && !st.isSymbolicLink()) continue;
      const r = skillFromFolder(dir, { root: tier.dir, tier: tier.name });
      if (!r.ok) { errors.push({ tier: tier.name, folder: entry, errors: r.errors }); continue; }
      skills.push({ definition: r.definition, tier: tier.name, folder: entry, dir, warnings: r.warnings, lossy: r.lossy, slug: entry });
    }
  }
  return { skills, errors };
}

// Resolve a reference to ONE skill. ref: a full id ("skill.e3d.skeptic") or a slug ("skeptic": the highest tier wins). pin: { version?, hash? }:
// a mismatch fails with a stable code (ADR-0004, ADR-0012: no ranges, no aliases in this phase).
export function resolveSkill(skills, ref, pin = {}) {
  const byId = skills.filter((s) => s.definition.id === ref);
  const pool = byId.length ? byId : skills.filter((s) => s.slug === ref);
  if (!pool.length) return { ok: false, error: err('skill_not_found', `no skill "${ref}" (try --list-skills)`) };
  const order = ['built-in', 'user', 'repo'];
  const chosen = pool.reduce((a, b) => (order.indexOf(b.tier) > order.indexOf(a.tier) ? b : a));
  if (pin.version !== undefined && chosen.definition.version !== pin.version) return { ok: false, error: err('skill_version_invalid', `${chosen.definition.id} is at version ${chosen.definition.version}, not the pinned ${pin.version}`) };
  if (pin.hash !== undefined && chosen.definition.definition_hash !== pin.hash) return { ok: false, error: err('skill_hash_mismatch', `${chosen.definition.id} does not match its pinned definition_hash (the definition changed); nothing was run`) };
  return { ok: true, skill: chosen, overridden: pool.filter((s) => s !== chosen).map((s) => ({ id: s.definition.id, tier: s.tier })) };
}

// ---------- export ----------

const yamlQuote = (v) => `"${v.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n').replace(/\t/g, '\\t')}"`;

// Writes a native folder <outRoot>/<slug> (SKILL.md + e3d/skill.json) for a definition and proves it round-trips to the same definition_hash.
// Refuses to overwrite anything. A new folder only: nothing existing is touched.
export function exportSkill(sourceDef, outRoot) {
  let def = sourceDef;
  if (def.owner_ref === 'e3d') {
    // A built-in is exported as a local COPY: it gets a local owner (so its id cannot collide with the built-in), is private and a draft, and records where it came from.
    const copy = { ...def, owner_ref: 'local-user', visibility: 'private', status: 'draft', extensions: { ...(def.extensions ?? {}), copied_from: `${def.id}@${def.version} ${def.definition_hash}` } };
    copy.id = `skill.${ownerSeg(copy.owner_ref)}.${def.id.split('.').slice(2).join('.')}`;
    copy.definition_hash = definitionHash(copy);
    def = copy;
  }
  const slug = def.id.split('.').slice(2).join('.');
  const dir = join(outRoot, slug);
  if (existsSync(dir)) throw Object.assign(new Error(`${dir} already exists; choose a new output folder (nothing is overwritten)`), { code: 'exists' });
  if (existsSync(outRoot) && !statSync(outRoot).isDirectory()) throw Object.assign(new Error(`${outRoot} is not a folder`), { code: 'not_a_folder' });
  const { id, description, license, provenance, definition_hash, signature, instructions, ...rest } = def; // eslint-disable-line no-unused-vars
  const json = { ...rest, instructions: { constraints: instructions.constraints ?? [] } };
  mkdirSync(join(dir, 'e3d'), { recursive: true });
  writeFileSync(join(dir, 'SKILL.md'), `---\nname: ${slug}\ndescription: ${yamlQuote(description)}\nlicense: ${yamlQuote(license)}\n---\n${instructions.method}\n`, { flag: 'wx' });
  writeFileSync(join(dir, SKILL_JSON), `${JSON.stringify(json, null, 2)}\n`, { flag: 'wx' });
  const back = skillFromFolder(dir, { root: outRoot, tier: 'user' });
  if (!back.ok || back.definition.definition_hash !== def.definition_hash) throw Object.assign(new Error(`the exported folder does not reproduce ${def.definition_hash}${back.ok ? '' : ` (${back.errors.map((e) => e.code).join(', ')})`}; it was left at ${dir} for inspection`), { code: 'roundtrip' });
  return { dir, definition: def };
}

// ---------- diff ----------

const sameValue = (x, y) => { try { return canonicalize(x ?? null) === canonicalize(y ?? null) && (x === undefined) === (y === undefined); } catch { return JSON.stringify(x) === JSON.stringify(y); } };

// Field-level difference of two definitions (key order does not matter). -> { same, hashEqual, fields: [{ field, change }] }
export function diffDefinitions(a, b) {
  const keys = [...new Set([...Object.keys(a), ...Object.keys(b)])].sort();
  const fields = [];
  for (const k of keys) {
    if (k === 'definition_hash') continue;
    if (!sameValue(a[k], b[k])) fields.push({ field: k, change: a[k] === undefined ? 'added' : b[k] === undefined ? 'removed' : 'changed' });
  }
  return { same: fields.length === 0, hashEqual: a.definition_hash === b.definition_hash, fields };
}
