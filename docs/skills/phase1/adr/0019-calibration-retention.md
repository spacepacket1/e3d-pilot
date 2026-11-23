# ADR-0019: Calibration retention

Status: **Owner-decided 2026-11-23; recorded here and awaiting reviewer sign-off like the other ADRs.** Phase: calibration 1. Spec: `spec/e3d-pilot-calibration-spec-v0.1.md`.

## Context

Real outcomes can take months. The hosted decision record keeps records 365 days.

## Decision

1. A `use_id` expires **90 days** after issue (`skill_use_expired` afterwards; the schema caps `expires_at - issued_at` at 90 days). 2. Calibration records are kept **365 days**. 3. Deleting a decision, a skill or an account removes the linked uses and outcomes and recomputes derived records. 4. Corrections supersede and keep the earlier outcome until it ages out. 5. The user can export and delete every record about their own uses.

## Consequences

Hosted retention steps and the account-closing step are added in the hosted adapter. Numbers are owner-approved; changing one needs an ADR.

## Alternatives considered

30-day `use_id` (refuses outcomes that arrive after a month); 180 days / 730 days (more stored data to protect).
