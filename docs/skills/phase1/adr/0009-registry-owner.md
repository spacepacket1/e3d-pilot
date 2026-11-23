# ADR-0009: Database and registry owner; migration rules

Status: **Proposed** (needs a human decision before Phase 2). Date: 2026-11-22. Phase: 1.

## Context

Spec 14.2 assumes relational tables and forward/backward commands. Hosted uses MongoDB with idempotent index creation at start-up and no migration framework; data changes are dry-run-first scripts with `--apply --i-have-a-backup`. Engine state is files.

## Decision

1. **e3d-pilot-cloud owns every hosted skill collection, route and migration; e3d-pilot owns local files, schemas, resolver, runtime and receipts.** 2. Hosted additions are **new collections** with their indexes declared in the existing index list (additive, created at start-up, idempotent). 3. Backfill (built-in catalogue to registry, hashes) is a script that is dry-run by default, bounded in batches, idempotent, and prints counts and hash reconciliation; applying needs the backup flag. 4. "Backward" means: reads fall back to the legacy catalogue path behind a per-tenant flag; collections are dropped only in a separate approved release. 5. Every migration PR states lock and runtime estimate, backup/restore test, partial-failure recovery and a tenant-isolation test. 6. `tenant_id` in plans, events and runs means a **team id** and is null for an individual account, until a tenant concept exists. 7. The run and evaluation ledger is append-only: local `decision-log.json`/receipts in the engine, a write-once collection hosted.

## Consequences

The spec's migration discipline is kept; its vocabulary is translated. Phase 7 cannot start until teams/audience tests exist.

## Alternatives considered

Introduce a SQL database for skills (a second datastore); store skills inside the debate row (no versions, no lineage).
