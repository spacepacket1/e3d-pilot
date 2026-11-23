# ADR-0007: Tool broker boundary

Status: **Proposed** (needs a human decision before Phase 2). Date: 2026-11-22. Phase: 1.

## Context

Spec: definitions request, policy grants. Today experts have `tools: none` and no broker exists; web search is a per-debate Pilot setting.

## Decision

1. The broker is an **engine-side interface** with allow-listed adapters; nothing is built before Phase 5. 2. v1 capability vocabulary is the spec's nine names and no others (`skill_capability_unknown` for anything else); filesystem, shell, network, credentials, repository write, messaging, publication, billing and account management are not representable. 3. An **instructional** skill may request no capability at all (reference check `skill_capability_denied`, fixture `instructional-with-tools`). `web.search` stays a Pilot debate/chat setting until a `tool_enabled` skill is approved by Phase 5. 4. Effective grant = skill request ∩ deployment ∩ principal ∩ tenant/team ∩ resource ACL ∩ audience ∩ run approval ∩ budget; a grant is bound to plan id and run, expires in minutes, names explicit resources (no wildcard scope, fixture `wildcard-scope`), and is unusable outside that run. 5. A denied capability must never reach an adapter (test in Phase 5 with a counting adapter). 6. The broker holds no credentials the skill can read; adapters receive only the grant.

## Consequences

No tool surface to attack in Phases 2 to 4. Phase 5 starts from a vocabulary and grant schema already frozen and tested as data.

## Alternatives considered

A generic tool-call pass-through with a deny list; letting a lens text enable `web.search` by wording.
