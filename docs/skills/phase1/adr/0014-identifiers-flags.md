# ADR-0014: Identifiers, error codes and flags

Status: **Proposed** (needs a human decision before Phase 2). Date: 2026-11-22. Phase: 1.

## Context

Names, ids, flags and codes already exist in two lower-case conventions.

## Decision

1. **Name** is the existing slug (`^[a-z0-9]+(-[a-z0-9]+)*$`, equals folder name). **Id** is derived: `skill.<owner>.<name>` where owner is `e3d` for built-ins, otherwise the owner reference (lowercase letters, digits, underscore); compositions use `composition.<owner>.<name>`. Within a principal's own space an unqualified name resolves as today. 2. **Error codes** are lowercase snake case prefixed `skill_` (`docs/skills/schemas/v1/error-codes.json`), matching the codes already returned (`invalid_experts`, `experts_unavailable`); the spec's upper-case names map one to one and are accepted in documentation only. Codes are never renamed or reused. 3. **Flags:** `E3D_SKILLS_V1` (Phase 2), then one per scope and per adapter; all validate as unset, `0` or `1` and any other value **refuses to start**, like `E3D_SPECIALISTS` and `E3D_MCP_EXPERTS`. Existing flags keep their meaning; `E3D_SKILLS_V1` needs `E3D_SPECIALISTS=1` for anything that runs a debate. 4. Default for every new flag is off in release defaults.

## Consequences

One grammar everywhere; the schema patterns encode it.

## Alternatives considered

Upper-case codes (two conventions in one API).
