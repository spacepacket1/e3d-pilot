// REFERENCE implementation for the Phase 1 fixtures (docs/skills/phase1/adr/0003-hashing.md). It is test support, not engine code:
// nothing in bin/ or lib/ imports it. Phase 2 re-implements it in the engine and must reproduce these fixture hashes byte for byte.
import { createHash } from 'node:crypto';

export const HASH_CONTRACT = 'e3d.skill-hash/v1';

// Fields that do NOT contribute to a skill's executable meaning (ADR-0003). Everything else does, and an unknown field fails closed first.
export const NON_EXECUTABLE = Object.freeze(['content_hash', 'signature', 'name', 'description', 'tags', 'license', 'owner_ref', 'visibility', 'status', 'tests', 'provenance', 'extensions']);

// RFC 8785 (JCS) restricted to what a definition may hold: strings, integers, booleans, null, arrays, objects. A float is refused, so
// number formatting can never differ between implementations.
export function canonicalize(v) {
  if (v === null || typeof v === 'boolean' || typeof v === 'string') return JSON.stringify(v);
  if (typeof v === 'number') {
    if (!Number.isSafeInteger(v)) throw new Error('canonical_float: only safe integers are allowed in hashed fields');
    return String(v);
  }
  if (Array.isArray(v)) return `[${v.map(canonicalize).join(',')}]`;
  if (typeof v === 'object') return `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canonicalize(v[k])}`).join(',')}}`;
  throw new Error(`canonical_type: ${typeof v}`);
}

export function executableView(def) {
  const out = {};
  for (const k of Object.keys(def)) if (!NON_EXECUTABLE.includes(k)) out[k] = def[k];
  return out;
}

export function contentHash(def) {
  return `sha256:${createHash('sha256').update(`${HASH_CONTRACT}\0${canonicalize(executableView(def))}`, 'utf8').digest('hex')}`;
}

// Directed-graph cycle check for composition fixtures (node ids; an edge "a.output" -> "b.input" links node a to node b).
export function compositionProblems(c) {
  const ids = c.nodes.map((n) => n.node_id);
  if (new Set(ids).size !== ids.length) return 'skill_conflict';
  const adj = new Map(ids.map((i) => [i, []]));
  for (const e of c.edges) {
    const a = e.from.split('.')[0], b = e.to.split('.')[0];
    if (!adj.has(a) || !adj.has(b)) return 'skill_type_incompatible';
    adj.get(a).push(b);
  }
  const state = new Map();
  const visit = (n) => { if (state.get(n) === 1) return true; if (state.get(n) === 2) return false; state.set(n, 1); for (const m of adj.get(n)) if (visit(m)) return true; state.set(n, 2); return false; };
  return ids.some(visit) ? 'skill_composition_cycle' : null;
}
