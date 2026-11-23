# ADR-0010: Public license policy

Status: **Accepted as written** by the owner on 2026-11-23 (it was Proposed). Date: 2026-11-22. Phase: 1.

## Context

Publishing needs a license; built-ins are MIT; forks must carry attribution. This is a legal and product decision, not only an engineering one.

## Decision

**Approved by the owner on 2026-11-23:** a public or unlisted skill must declare an SPDX identifier from an allow-list: `MIT`, `Apache-2.0`, `CC0-1.0`, `CC-BY-4.0`, `CC-BY-SA-4.0`; anything else is refused at publish preview (`skill_moderation_blocked`, reason `license`). Private and team skills may carry any license string. A fork inherits the parent's license and attribution in `provenance.forked_from` and may not relicense. Withdrawal stops new use; it cannot recall copies already forked or exported, and the UI says so. Not decided here: any terms for creators (payouts are out of scope for the whole project until a separate ADR).

## Consequences

Phase 8 blocks on this. The schema already carries `license` and `provenance.forked_from`.

## Alternatives considered

Free-text license (cannot be scanned or enforced); MIT only (forbids reasonable CC content skills).
