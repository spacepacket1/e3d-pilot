# ADR-0005: API and tool names

Status: **Proposed** (needs a human decision before Phase 2). Date: 2026-11-22. Phase: 1.

## Context

Spec proposes `/v1/skills`, `e3d_list_skills`, and so on. Existing: MCP `e3d_list_experts`, `e3d_get_expert`; hosted public API under `/api`; loopback `/agent/v1` is internal; no OpenAPI file; recorded hosted tool list is stale (audit).

## Decision

1. **No new MCP tool or REST route before Phase 7.** Phase 2 adds CLI verbs only (`e3d-debate --list-skills | --show-skill | --validate-skill | --project-expert | --export-skill | --diff-skill`, all behind `E3D_SKILLS_V1=1`). 2. `e3d_list_experts` and `e3d_get_expert` keep their names and outputs forever; Phase 7 adds `e3d_list_skills` and `e3d_get_skill` as supersets and keeps the old pair as aliases. 3. Hosted REST lives under the existing public prefix (`/api/skills...`), not `/v1`; the spec path names are descriptive only. 4. Existing request fields `experts` and `skills` are unchanged and additive fields (`skill_attachments`, `skill_plan_token`) are optional (spec 7.3). 5. The error envelope is the spec's (`error.code`, `message`, `retryable`, `details`, `next_action`) with lowercase codes (ADR-0014), matching the shape the agent routes already return. 6. `tests/skills-compat.sh` fails if any tool name containing `skill` appears before the skills phases ship.

## Consequences

The MCP surface stays frozen until the registry exists. Hosted names are settled with the cloud owner in Phase 7.

## Alternatives considered

Mirror the spec's paths literally (they collide with nothing but are inconsistent with every existing route).
