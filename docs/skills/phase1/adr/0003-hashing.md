# ADR-0003: Hashing and identity

Status: **Proposed** (needs a human decision before Phase 2). Date: 2026-11-22. Phase: 1.

## Context

Hosted and receipts already name experts by a **folder hash** (`hashFolder`: `path\0size\0sha256` per file, sorted) and refuse a pin mismatch. The spec asks for an RFC 8785 JSON hash. The engine also has a different, non-8785 canonicalizer (`canonicalJson`, `lib/mcp/external-auth.js`:199) used for request keys.

## Decision

Two hashes, never merged. **`legacy_folder_hash`** stays the identity of an expert folder, exactly as computed today; it is kept in provenance and in receipts for the expert path. **`content_hash`** is the identity of a `SkillDefinition`: `sha256` of the UTF-8 bytes of `"e3d.skill-hash/v1" + NUL + JCS(executable fields)`, where JCS is RFC 8785 restricted to strings, safe integers, booleans, null, arrays and objects (a float in a hashed field is refused, so number formatting cannot differ). The contract id is part of the preimage, so a future change makes a different hash, not a collision. **Excluded from the hash** (enumerated, as the spec requires): `content_hash`, `signature`, `name`, `description`, `tags`, `license`, `owner_ref`, `visibility`, `status`, `tests`, `provenance`, `extensions`. Everything else, including `id`, `version`, `schema_version`, hooks, instructions, schema refs, capabilities, memory policy, limits and fallback, is executable meaning. The reference implementation and fixture hashes are in `tests/fixtures/skills/reference.mjs`; Phase 2 must reproduce them byte for byte. A resolver that finds a different hash than the plan names fails before spend with `skill_hash_mismatch`.

## Consequences

Hosted pins keep working. A skill has two names for the same content only on the expert path; hosted registry (Phase 7) stores `content_hash` and, for built-ins, the legacy hash.

## Alternatives considered

Replace the folder hash (breaks pins); hash with the existing `canonicalJson` (not a standard; undefined-to-null behaviour differs from JCS).
