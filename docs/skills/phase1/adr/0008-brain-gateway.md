# ADR-0008: Brain gateway boundary

Status: **Proposed** (needs a human decision before Phase 2). Date: 2026-11-22. Phase: 1.

## Context

Spec 9.2 needs principal, tenant, project, audience, purpose and resource-class on every read, destination-aware retrieval and read-side redaction. e3d-brain has one principal per process, stdio MCP, no such fields, scrub on writes only, and states there is no shared server.

## Decision

1. **The gateway lives in Pilot, not Brain**, as a policy-enforcing client (engine for local, hosted policy adapter for hosted). Brain stays an advisory store and is never asked to enforce tenancy. 2. **Local:** a skill may read the owner's own Brain only (`brain.read` scope `current_user`/`current_project`), through a read-only config, returning cited items (note id and revision, status, timestamp). The existing shell recall (`lib/ideas/brain_recall.sh`) is the precedent: optional, never fails a run, recalled text is data. 3. **Hosted:** no Brain access for hosted skills until a per-principal Brain design exists (separate ADR and Brain PR); the capability is denied with `skill_capability_denied`. 4. Writes are `brain.propose` only, landing in the Brain inbox as `proposed`; Pilot never writes accepted memory. 5. Destination-aware rule: memory used for a private response is not reused in a team or public artifact without a separate grant (`skill_audience_denied`). 6. **Taint rule.** Every Brain item carries its source scope and audience into the run. A run that used private memory records `audience_ceiling: private` in its receipt, and any attempt to share the result with a team or publish it is refused (`skill_audience_denied`); without the tag the destination rule could not be enforced once content is inside a prompt. 7. Pilot's ledger remains the record of requests, plans, grants and outcomes; Brain holds references.

## Consequences

Phase 5 on e3d-brain is optional and small (config and fixtures) instead of a multi-tenant rewrite. Hosted learning skills are blocked on a decision that is not this one.

## Alternatives considered

Add tenancy to Brain (large, contradicts its local-first design); give hosted skills the operator's Brain (cross-tenant leak).
