# ADR-0011: Retention and deletion

Status: **Proposed** (needs a human decision before Phase 2). Date: 2026-11-22. Phase: 1.

## Context

Spec 11.4 wants retention and deletion defined per data class before hosted launch. Hosted today: transcripts 90 days, decision records 365 days (configurable), account deletion cascades and keeps financial rows (audit).

## Decision

**Proposed, needs the owner's approval of the numbers.** A skill definition (private) lives until the author deletes it or the account closes (new closeAccount step in Phase 7). A **receipt** keeps `{id, version, definition_hash}` and metrics, never the skill body, and follows the debate's retention. Skill **run inputs/outputs** follow transcript retention (90 days). **Observations** require `expires_at` (schema) with a 30-day default and 180-day maximum proposed; expired ones are deleted by a job, corrections append and link. **Evaluation records** are kept as long as the skill version exists, private by default. **Audit minimum** (event ids, principal ref, skill ref, capability, decision, no content) 365 days, the same as decision records. Analytics get aggregates only, never prompts, skill bodies or memory text. Public withdrawal keeps minimal lineage so forks stay attributed. **Clarifications:** the append-only ledger (ADR-0009) keeps ids, digests and metrics; deleting content leaves a **tombstone** (digest and reference remain, body gone, reads return `skill_not_found`). Observer output text is stored as an artifact and follows the observation retention above, not the 365-day audit minimum. A skill run follows the 90-day transcript default unless it is part of a decision record. The 180-day cap on `expires_at` cannot be expressed in a schema (it compares to now) and is enforced in code. Observation text is user-derived data and is classed as private under the same rules; the prohibited-inference list (spec 10.2) is enforced at output validation in Phase 6.

## Consequences

Fixes the data classes the threat model inventories. Numbers can be changed before Phase 5 without a schema change.

## Alternatives considered

Indefinite retention of observations (surveillance risk, spec 11.3).
