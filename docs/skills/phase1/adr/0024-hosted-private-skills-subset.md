# ADR-0024: Hosted user skills, private subset first

Status: **Owner-decided 2026-11-23** (3c plan, decision D1 approved with defaults). Phase: 3c. Builds on ADR-0005 (names), ADR-0006 (observer), ADR-0014 (owner belongs to the tier).

## Context

The hosted spec (`docs/skills-hosted-spec.md` in the cloud repo) puts the user skill registry in hosted phase 7, which lists phases 2 to 6 as dependencies. The vision needs users to create, manage and run their own skills on the hosted service, and nothing in the cloud stores or sends user skill text today. Sharing, forking and publishing carry a different risk class (stored prompt injection reaching other people, tenant isolation, moderation).

## Decision

1. Ship a deliberate **subset** of phase 7 first: **private** skills only (visible to the owner and to nobody else), **instructional** only (no tools, memory or learning), hooks **debate seat** and **debate observer** only, no chat `after_response`, no sharing, teams, forking, Gallery or publishing. The full phases stay on the roadmap and keep their gates.
2. **The engine is the authority.** A hosted service sends a definition (parsed JSON) with an authenticated principal. The engine recomputes `definition_hash` and refuses a mismatch (a local folder only warns), checks the fields the hash does not cover (owner, status, visibility) against the principal and this policy, applies the same text hygiene as a local SKILL.md, bounds size and shape before parsing deeper, and refuses anything not instructional. Module: `lib/skills/intake.mjs`.
3. A hosted owner is a new tier, `hosted`, with an owner `u_<id>` that can never be `e3d` or a local owner. Visibility other than private, and any status other than active, do not run.
4. Everything is flag-gated and off by default; with the flags off the new fields are refused like any unknown field.
5. Sharing is not on any path in this release. Threat T-H10 (a poisoned shared skill reaches other users) is out of scope until a later phase adds moderation and abuse handling.

## Consequences

The first hosted release has a small, reviewable surface. The cost is that users cannot yet share skills hosted; they can still keep them private and, locally, use all of them over MCP. Each later step (sharing, tools, memory) needs its own ADR and review.
