// Canonical form and the definition hash of a skill (docs/skills/phase1/adr/0003-hashing.md). Zero dependencies, pure functions.
//
// definition_hash = sha256("e3d.skill-hash/v1" + NUL + JCS(executable fields)). JCS is RFC 8785 restricted to what a definition may hold: strings
// (well-formed, NFC), safe integers, booleans, null, arrays and objects; a float is refused, so number formatting can never differ between
// implementations. It is a NEW hash; the file-tree hash of an expert folder (hashFolder) is unchanged and is kept as legacy_folder_hash.
// tests/fixtures/skills/reference.mjs is the independent reference implementation the fixtures were made with; tests/skills-runtime.sh checks that
// this module reproduces its hashes.
import { createHash } from 'node:crypto';

export const HASH_CONTRACT = 'e3d.skill-hash/v1';

// Fields that do NOT contribute to a skill's executable meaning (ADR-0003). Everything else does, and an unknown field fails closed first.
export const NON_EXECUTABLE = Object.freeze(['definition_hash', 'signature', 'tags', 'license', 'owner_ref', 'visibility', 'status', 'tests', 'provenance', 'extensions']);

export function canonicalize(v) {
  if (typeof v === 'string') {
    if (/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(v)) throw new Error('canonical_surrogate: lone surrogate (RFC 8785 needs well-formed strings)');
    if (v !== v.normalize('NFC')) throw new Error('canonical_not_nfc: strings are hashed in Unicode NFC');
    return JSON.stringify(v);
  }
  if (v === null || typeof v === 'boolean') return JSON.stringify(v);
  if (typeof v === 'number') {
    if (!Number.isSafeInteger(v)) throw new Error('canonical_float: only safe integers are allowed in hashed fields');
    return String(v);
  }
  if (Array.isArray(v)) return `[${v.map(canonicalize).join(',')}]`;
  if (typeof v === 'object') return `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canonicalize(v[k])}`).join(',')}}`;
  throw new Error(`canonical_type: ${typeof v}`);
}

// Object.fromEntries defines own properties, so a key such as "__proto__" in a (malformed) document is hashed, never turned into a prototype.
export function executableView(def) {
  return Object.fromEntries(Object.keys(def).filter((k) => !NON_EXECUTABLE.includes(k)).map((k) => [k, def[k]]));
}

export function definitionHash(def) {
  return `sha256:${createHash('sha256').update(`${HASH_CONTRACT}\0${canonicalize(executableView(def))}`, 'utf8').digest('hex')}`;
}
