# ADR-0001: Canonical skill schema and authoring format

Status: **Accepted by the owner, 2026-11-23** (approved as written when skills phase 2 was authorized; the independent reviews of the phase 2 work are in `review-record.md`). Date: 2026-11-22. Phase: 1.

## Context

The spec wants one `SkillDefinition` (`e3d.skill/v1`) for chat, seat, observer and composition scopes. Authoring today is a standard Agent Skill folder (`SKILL.md` + `e3d/expert.json`), read by a deliberately tiny YAML subset that refuses inline lists and nested maps (`lib/debate/specialists.mjs` `scalar`, `parseFrontmatter`). The spec's YAML example cannot be parsed by it.

## Decision

1. The canonical wire and storage form is **JSON** (`docs/skills/schemas/v1/skill-definition.schema.json`). 2. A skill folder keeps `SKILL.md` (frontmatter name, description, license, metadata; the body is `instructions.method`) and gains an optional sidecar `e3d/skill.json` that holds everything structured (hooks, requested capabilities, memory policy, limits, fallback, constraints, schema refs). `e3d/expert.json` stays valid and means a v1 expert projection (ADR-0002). 3. The engine does **not** gain a YAML library; structured data is JSON only. 4. Unknown executable fields fail closed with `skill_schema_unknown_field`; unknown metadata may live in `extensions` and never affects runtime. 5. `scripts`, `install`, `mcp_servers` and `network` are rejected with `skill_scripts_not_allowed`; v1 has no way to request them. 6. **Text hygiene.** Free text in a definition (`name`, `description`, `instructions.*`, capability `purpose`) must not contain C0 controls other than newline and tab, DEL, zero-width characters, bidirectional overrides or the byte-order mark (schema pattern, fixture `bidi-override`); validation also requires Unicode NFC, because a reviewer must be able to see what the model reads. Length caps count characters in the schema and bytes in the engine (`instructions` is capped in both). 7. **Schema refs are immutable per version.** `e3d://schemas/<name>/vN` names content that never changes once shipped (a change is `vN+1`), and the schema registry ships in the engine repository, so a hash over the reference string pins the referent. 8. `extensions` holds string values only (200 characters, 20 keys); no part of the engine may read it to decide behaviour; if a field ever needs to influence a run it is promoted to a defined, hashed field. 9. `signature` must be null in v1 (the service signature is a later, additive change). 10. `input_schema_ref`/`output_schema_ref` use `e3d://schemas/<name>/v<N>`; the registry of those schemas is a Phase 2 deliverable and v1 ships two: `seat-input/v1` and `seat-output/v1` (free text).

## Consequences

The folder stays valid for any tool that reads Agent Skills. Authors write JSON for structure, which is verbose but unambiguous. The harness in `tests/skills-schemas.mjs` proves the schema against 13 valid and 37 invalid fixtures.

## Alternatives considered

Adopt a full YAML parser (adds a dependency to a zero-dependency engine and a larger attack surface); keep YAML nested examples as the spec shows (cannot be parsed).
