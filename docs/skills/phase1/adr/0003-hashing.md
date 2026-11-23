# ADR-0003: Hashing and identity

Status: **Proposed** (needs a human decision before Phase 2). Date: 2026-11-22. Phase: 1.

## Context

Hosted and receipts already name experts by a **folder hash** (`hashFolder`: `path\0size\0sha256` per file, sorted) and refuse a pin mismatch. The spec asks for an RFC 8785 JSON hash. The engine also has a different, non-8785 canonicalizer (`canonicalJson`, `lib/mcp/external-auth.js`:199) used for request keys.

## Decision

Two hashes, never merged. **`legacy_folder_hash`** stays the identity of an expert folder, exactly as computed today; it is kept in provenance and in receipts for the expert path. **`definition_hash`** is the identity of a `SkillDefinition` (named differently on purpose: the existing MCP listing already calls the folder hash `definition_hash` (`lib/mcp/experts-read.js`:78)): `sha256` of the UTF-8 bytes of `"e3d.skill-hash/v1" + NUL + JCS(executable fields)`, where JCS is RFC 8785 restricted to strings, safe integers, booleans, null, arrays and objects (a float in a hashed field is refused, so number formatting cannot differ). The contract id is part of the preimage, so a future change makes a different hash, not a collision. **Excluded from the hash** (enumerated, as the spec requires): `definition_hash`, `signature`, `tags`, `license`, `owner_ref`, `visibility`, `status`, `tests`, `provenance`, `extensions`. `name` and `description` **are hashed**: the approval screen and listings show them, so editing them must make a new version. `tags` is display-only and no router or suggestion may use it; selection uses `tasks` and `hooks`, which are hashed. `status` and `visibility` are not hashed, so they are **checked live at execution** (a withdrawn version fails with `skill_withdrawn`; it is never only hidden from lists). Everything else, including `id`, `version`, `schema_version`, hooks, instructions, schema refs, capabilities, memory policy, limits and fallback, is executable meaning. The reference implementation and fixture hashes are in `tests/fixtures/skills/reference.mjs`; Phase 2 must reproduce them byte for byte. Strings are hashed in Unicode NFC and a lone surrogate is refused. **Which hash a pin names:** `skillRef.hash` is a `definition_hash`; the existing expert pins `{id, hash}` on the `experts` field keep naming the legacy folder hash; every receipt records `skill_source.verified_hash_kind` (`definition` or `legacy_folder`) so a verifier knows which one was checked. **Read once:** Phase 2 reads each file a single time into memory and hashes and uses those same bytes (no validate, hash and read as separate filesystem passes), or a swap between passes defeats the pin. A resolver that finds a different hash than the plan names fails before spend with `skill_hash_mismatch`.

**Finding F-2 (existing code, fix in Phase 2).** `hashed()` in `lib/debate/specialists.mjs` (:162-167) removes every line starting `e3d.expert.hash:` from SKILL.md with a global multiline pattern, including lines in the lens body. Two lenses that differ only by such a line have the **same** folder hash but different text (demonstrated on this branch with a scratch folder). Phase 2 must strip the line only inside the frontmatter block and add a fixture. No built-in expert contains such a line, so no existing hash changes (pinned by `tests/skills-compat.sh`). Also normalise line endings the same way for hashing and for the delivered lens, so one hash does not have two byte forms.

## Consequences

Hosted pins keep working. A skill has two names for the same content only on the expert path; hosted registry (Phase 7) stores `definition_hash` and, for built-ins, the legacy hash.

## Alternatives considered

Replace the folder hash (breaks pins); hash with the existing `canonicalJson` (not a standard; undefined-to-null behaviour differs from JCS).
