# ADR-0004: Immutable version storage

Status: **Accepted by the owner, 2026-11-23** (approved as written when skills phase 2 was authorized; the independent reviews of the phase 2 work are in `review-record.md`). Date: 2026-11-22. Phase: 1.

## Context

Spec invariant: versions are immutable; receipts pin versions. Local skills are files a user can edit; hosted has a database.

## Decision

**Local:** a folder is a draft until a version is recorded; "immutable" is enforced by verification, not by the filesystem. A pinned reference `(id, version, definition_hash)` is checked at resolve time and a differing folder fails (`skill_hash_mismatch`). v1 does not keep a version store inside the tool: the user keeps versions in git. A local create or version command writes only to an explicit output path and refuses to overwrite an existing folder. **Hosted (Phase 7):** an append-only collection keyed `(skill id, version)` with a unique index on that pair and on `definition_hash`; no update path for executable fields; deprecate and withdraw flip `status` only. Receipts store `{id, version, definition_hash}` plus the tier, never a slug alone.

## Consequences

No new local storage in Phase 2. Hosted needs a unique-index and a write-once rule tested with a concurrent-publish race.

## Alternatives considered

A local version store inside the tool (a second source of truth beside git); updating hosted rows in place.

**Additions after review.** Creating a version whose `(id, version)` already exists with a different hash fails with `skill_version_invalid` (an edit needs a version bump). `status` is checked live at execution (`skill_withdrawn`). Files are read once (ADR-0003).
