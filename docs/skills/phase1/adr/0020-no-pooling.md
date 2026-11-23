# ADR-0020: No cross-user pooling for now

Status: **Owner-decided 2026-11-23; recorded here and awaiting reviewer sign-off like the other ADRs.** Phase: calibration 1. Spec: `spec/e3d-pilot-calibration-spec-v0.1.md`.

## Context

Pooled records give faster data and public evidence, but they are where poisoning, Goodhart pressure, re-identification and mixed populations enter.

## Decision

1. Records are private to the principal. The `track-record` schema allows `scope: principal` only, so a pooled record is not representable in v1 (fixture `track-record--pooled-scope`). 2. Calibration phase 7 (opt-in aggregation, public track records) stays in the plan as a gated option behind its own go/no-go ADR. 3. If it is ever approved: opt-in per user, at least 20 users in a stratum, source-diversity checks, pooled records labelled as such, and opting out recomputes.

## Consequences

Public skill pages show no pooled record until then; authors see only their own records and evaluation-backed claims.

## Alternatives considered

Never pool (removes the later option); plan to pool (commits to the riskiest part before the data exists).
