// Hosted skill intake (docs/skills/phase3/plan-3c-hosted-user-skills.md, section 3, PR H1). Zero dependencies, pure: no file, no network, no model.
//
//   intakeSkill(definition, { principal, scopes }) -> { ok, errors[], warnings[], definition, entry, scan }
//
// A hosted service sends a skill DEFINITION (parsed JSON) instead of a folder. This module is the engine's answer to "can I trust it": it never trusts a
// claim. It recomputes the hash (a mismatch is refused, unlike a local folder where it is only a warning), checks the fields the hash does NOT cover
// (owner, status, visibility), applies the same text hygiene as a local SKILL.md (hidden characters, NFC, lens-marker spoofing), bounds size and shape
// BEFORE parsing deeper, and accepts instructional skills only. The result `entry` has the shape loadSkills() makes, so the seat and observer code that is
// already reviewed takes it unchanged. Nothing is written anywhere.
import { createHash } from 'node:crypto';
import { types } from 'node:util';
import { checkDefinition } from './definition.mjs';
import { scanSkill } from './scan.mjs';
import { LIMITS, LENS_MARKER, hasHiddenCharacters } from '../debate/specialists.mjs';

// The hosted tier. Its owner is a principal the hosted service names; it can never be "e3d" (reserved), a local owner, or anything with a hyphen form
// of those, because the pattern below starts with u_ and the local owners are local-user and local-repo.
export const HOSTED_TIER = 'hosted';
export const HOSTED_OWNER_RE = /^u_[a-z0-9]{6,36}$/;
const isProxy = types.isProxy;
export const INTAKE_LIMITS = Object.freeze({ jsonBytes: 48 * 1024, depth: 8, keys: 400, nodes: 2000, string: 32768, methodBytes: 8192, methodChars: LIMITS.bodyChars });
export const DEFAULT_SCOPES = Object.freeze(['debate_seat', 'debate_observer']);

const err = (code, message, path) => ({ code, message, ...(path ? { path } : {}) });

// ONE pass that both bounds and COPIES the value (a snapshot). Every check afterwards runs on the copy, and the copy is what the entry carries, so nothing the
// caller does later (a getter that changes, a mutation after return, a toJSON, a Proxy) can change what was accepted. Plain objects, arrays, strings, safe
// integers, booleans and null only; bounded depth, keys, array length, total bytes and total nodes; a shared or cyclic reference is refused (so a DAG cannot
// blow up); an accessor property, a hole in an array, a Proxy or a forbidden key is refused. Strings must be well formed, NFC and free of hidden characters:
// this covers EVERY string, including the fields the hash does not cover (extensions, license, tasks, tags, provenance), not only the instruction text.
function snapshot(root) {
  let nodes = 0;
  let bytes = 0;
  const seen = new Set();
  const text = (t, path) => {
    if (/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(t)) return `a string at ${path} has a lone surrogate`;
    if (t.length > INTAKE_LIMITS.string) return `a string at ${path} is longer than ${INTAKE_LIMITS.string}`;
    if (t.normalize('NFC') !== t) return `a string at ${path} is not in Unicode normalization form NFC`;
    if (hasHiddenCharacters(t)) return `a string at ${path} contains a control, zero-width or bidirectional character that hides what a model reads`;
    bytes += Buffer.byteLength(t, 'utf8');
    return null;
  };
  const walk = (x, depth, path) => {
    if (++nodes > INTAKE_LIMITS.nodes) return { problem: `more than ${INTAKE_LIMITS.nodes} values` };
    if (bytes > INTAKE_LIMITS.jsonBytes) return { problem: `larger than ${INTAKE_LIMITS.jsonBytes} bytes`, big: true };
    if (depth > INTAKE_LIMITS.depth) return { problem: `nesting deeper than ${INTAKE_LIMITS.depth}` };
    if (x === null || typeof x === 'boolean') return { v: x };
    if (typeof x === 'string') { const p = text(x, path); return p ? { problem: p } : { v: x }; }
    if (typeof x === 'number') return Number.isSafeInteger(x) ? { v: x } : { problem: `a non-integer or unsafe number at ${path}` };
    if (typeof x !== 'object') return { problem: `a value of type ${typeof x} at ${path}` };
    if (isProxy(x)) return { problem: `a Proxy at ${path}` };
    if (seen.has(x)) return { problem: `a repeated or cyclic reference at ${path}` };
    seen.add(x);
    if (Array.isArray(x)) {
      if (x.length > 100) return { problem: `an array longer than 100 at ${path}` };
      const out = [];
      for (let i = 0; i < x.length; i++) {
        const d = Object.getOwnPropertyDescriptor(x, i);
        if (!d || !Object.hasOwn(d, 'value')) return { problem: `a hole or accessor in an array at ${path}[${i}]` };
        const r = walk(d.value, depth + 1, `${path}[${i}]`);
        if (r.problem) return r;
        out.push(r.v);
      }
      return { v: out };
    }
    const proto = Object.getPrototypeOf(x);
    if (proto !== Object.prototype && proto !== null) return { problem: `a non-plain object at ${path}` };
    const keys = Object.keys(x);
    if (keys.length > INTAKE_LIMITS.keys) return { problem: `more than ${INTAKE_LIMITS.keys} keys at ${path}` };
    const out = {};
    for (const k of keys) {
      if (k === '__proto__' || k.length > 128) return { problem: `a forbidden or oversized key at ${path}` };
      const kp = text(k, `${path}.<key>`);
      if (kp) return { problem: kp };
      const d = Object.getOwnPropertyDescriptor(x, k);
      if (!d || !Object.hasOwn(d, 'value')) return { problem: `an accessor property at ${path}.${k}` };
      const r = walk(d.value, depth + 1, `${path}.${k}`);
      if (r.problem) return r;
      out[k] = r.v;
    }
    return { v: out };
  };
  const r = walk(root, 0, '$');
  return r.problem ? { problem: r.problem, big: Boolean(r.big) } : { value: r.v, bytes };
}

const deepFreeze = (v) => { if (v && typeof v === 'object' && !Object.isFrozen(v)) { Object.freeze(v); for (const k of Object.keys(v)) deepFreeze(v[k]); } return v; };

const ownerSeg = (owner) => owner.replace(/-/g, '_');

// definition: the parsed JSON the hosted service sent. principal: the owner the SERVICE authenticated for this request (never read from the definition).
// scopes: the hook scopes this listener runs; a definition that declares a hook outside them is refused.
export function intakeSkill(definition, opts) {
  const o = opts !== null && typeof opts === 'object' ? opts : {};
  const principal = o.principal;
  const errors = [];
  const fail = (...e) => ({ ok: false, errors: [...errors, ...e], warnings: [], definition: null, entry: null, scan: null });

  if (typeof principal !== 'string' || !HOSTED_OWNER_RE.test(principal)) return fail(err('skill_tenant_denied', 'the hosted principal is missing or not a valid hosted owner', 'principal'));
  // the accepted scopes are the listener's own configuration: anything but an array of known scopes fails closed (never a substring or a callable)
  const scopes = o.scopes === undefined ? DEFAULT_SCOPES : o.scopes;
  if (!Array.isArray(scopes) || scopes.length === 0 || scopes.some((x) => typeof x !== 'string' || !DEFAULT_SCOPES.includes(x))) return fail(err('skill_scope_denied', 'the accepted hook scopes must be a non-empty list drawn from debate_seat and debate_observer', 'scopes'));
  if (definition === null || typeof definition !== 'object' || Array.isArray(definition)) return fail(err('skill_schema_type', 'a definition must be a JSON object'));
  // bound AND copy in one pass, before anything else reads the value; every later check runs on the copy
  const snap = snapshot(definition);
  if (snap.problem) return fail(err(snap.big ? 'skill_too_large' : 'skill_schema_limit', snap.problem));
  const def = snap.value;

  // the claims the hash does not cover are checked against the authenticated principal and this release's policy, never against the definition's own word
  if (def.owner_ref !== principal) return fail(err('skill_tenant_denied', 'owner_ref is not the authenticated principal', 'owner_ref'));
  if (def.visibility !== 'private') return fail(err('skill_scope_denied', 'only private skills are accepted in this release', 'visibility'));
  if (def.status !== 'active') return fail(err(def.status === 'withdrawn' ? 'skill_withdrawn' : 'skill_not_found', `a skill with status "${typeof def.status === 'string' ? def.status.replace(/[^\x20-\x7E]/g, '?').slice(0, 20) : '?'}" does not run`, 'status'));
  const name = def.name;
  if (typeof name !== 'string' || def.id !== `skill.${ownerSeg(principal)}.${name}`) return fail(err('skill_conflict', 'id must be skill.<owner>.<name> for the authenticated owner', 'id'));
  // provenance is not hashed, so it is not the sender's to claim: it is rewritten to what the engine knows (no legacy folder hash, no parent or fork it did not verify)
  if (def.provenance === null || typeof def.provenance !== 'object' || Array.isArray(def.provenance)) return fail(err('skill_schema_type', 'provenance must be an object', 'provenance'));
  def.provenance = { parent: null, forked_from: null, source_format: 'e3d-native', created_by: principal, created_at: def.provenance.created_at };

  // structure, then the rules the schema cannot say: this recomputes the hash and refuses a mismatch, and refuses any non-instructional capability
  const problems = checkDefinition(def);
  if (problems.length) return fail(...problems);

  for (const h of def.hooks) if (!scopes.includes(h.scope)) return fail(err('skill_scope_denied', `hook scope "${h.scope}" is not accepted here`, 'hooks'));

  // the instruction text: bounded (D2), and no role-delimiter line (the same rule as a local SKILL.md). Hidden characters and NFC were refused for every string in the snapshot.
  const method = def.instructions.method;
  if (Buffer.byteLength(method, 'utf8') > INTAKE_LIMITS.methodBytes || method.length > INTAKE_LIMITS.methodChars) return fail(err('skill_too_large', `the instruction text is larger than ${INTAKE_LIMITS.methodBytes} bytes or ${INTAKE_LIMITS.methodChars} characters`, 'instructions.method'));
  if (LENS_MARKER.test(method)) return fail(err('skill_schema_value', 'the instruction text carries a role-delimiter line; remove or reword it', 'instructions.method'));

  deepFreeze(def);
  // an entry of the shape loadSkills() makes, so plan.mjs (seats) and observer.mjs take it as they take a folder skill. The "expert" half is the lens only.
  const entry = {
    definition: def,
    tier: HOSTED_TIER,
    folder: null,
    dir: null,
    warnings: [],
    lossy: [],
    slug: name,
    scan: scanSkill(def),
    expert: { name, description: def.description, license: def.license ?? null, metadata: {}, lens: method, sidecar: { tools: 'none', models: [], limits: {} }, sidecarPresent: false, hash: def.definition_hash, dir: null },
  };
  return { ok: true, errors: [], warnings: [], definition: def, entry, scan: entry.scan };
}

// A short digest of what intake accepted, for receipts and logs that must never carry the text (plan section 6, T-H7).
export const intakeDigest = (definition) => createHash('sha256').update(`${definition.id}\0${definition.version}\0${definition.definition_hash}`).digest('hex');
