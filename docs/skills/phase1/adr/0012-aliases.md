# ADR-0012: Alias and update rules

Status: **Proposed** (needs a human decision before Phase 2). Date: 2026-11-22. Phase: 1.

## Context

Spec: aliases are mutable pointers and must never be stored alone in a receipt; published compositions pin children.

## Decision

1. Aliases are `latest` and named channels (`stable`, `canary`), per skill, owned by the skill's author. 2. An alias is resolved **once, at plan time**, to `(id, version, content_hash)`; the plan token and the receipt carry only the resolved tuple. 3. A pinned reference that no longer matches fails before spend (`skill_hash_mismatch`); an alias that moved between preview and run invalidates the plan token (`skill_quote_expired`). 4. No semver ranges, no automatic upgrade of published compositions or forks; an update is a notification and a new composition or fork version. 5. Local skills have no alias file in Phase 2; a path plus an explicit version is the reference.

## Consequences

Replay of old receipts never depends on current state.

## Alternatives considered

Semver ranges (ambiguous resolution, harder cost bound).
