# Fixtures that need runtime code (not covered by Phase 1)

Phase 1 proves the schemas with a harness and a small reference checker (`tests/skills-schemas.mjs`). These invalid cases from the spec need the engine to exist and are therefore tests for the phase that builds the behaviour. Codes are already stable in `schemas/v1/error-codes.json`.

| Case (spec 15.3) | Expected code | Test lands in |
| --- | --- | --- |
| Lens containing the end-marker line | `skill_schema_invalid` (validation) | Phase 2 |
| Symlink, path traversal, oversize, script-bearing import folder | `symlink_in_skill`/`skill_too_large`/`skill_scripts_not_allowed` (existing folder codes plus new) | Phase 2 |
| Alias race, hash substitution between preview and run | `skill_hash_mismatch`, `skill_quote_expired` | Phase 3 |
| Replayed or altered plan token, price change | `skill_quote_expired` | Phase 3 |
| Observer overwriting a seat position | none allowed; byte-identical positions/synthesis/dissent | Phase 3 |
| Huge or deeply nested composition, schema-incompatible edge, ambiguous merge | `skill_budget_exceeded`, `skill_type_incompatible`, `skill_conflict` | Phase 4 |
| Denied capability reaching an adapter, expired grant, cross-run grant | `skill_capability_denied` | Phase 5 |
| Cross-tenant ids, cache-key collision, forbidden Brain scope | `skill_tenant_denied`, `skill_memory_error`, `skill_audience_denied` | Phase 5, 7 |
| SSRF attempt, log injection, output smuggling | `skill_tool_error`, `skill_output_invalid` | Phase 5 |
| Quota race, duplicate publish, moderation bypass, private evidence in a public result | `skill_moderation_blocked` | Phase 7, 8 |
| Lens containing a line `e3d.expert.hash: ...` (two lenses, one folder hash; finding F-2) | folder hash must differ | Phase 2 |
| Non-NFC text, lone surrogate, CRLF vs LF producing two byte forms of one hash | `skill_schema_format` / hash equality | Phase 2 |
| File swapped between validate and read (read-once rule) | `skill_hash_mismatch` | Phase 2 |
| Withdrawn version still resolvable | `skill_withdrawn` | Phase 3, 7 |
| Edit without a version bump (`(id, version)` with a second hash) | `skill_version_invalid` | Phase 2 |
