# ADR-0017: Evidence tiers, attribution and the track record

Status: **Owner-decided 2026-11-23; recorded here and awaiting reviewer sign-off like the other ADRs.** Phase: calibration 1. Spec: `spec/e3d-pilot-calibration-spec-v0.1.md`.

## Context

An outcome can be attributed only to something fixed. The skills contracts give that unit (id, version, definition hash). Reports come from several sources of very different reliability.

## Decision

1. A record is keyed to `(skill id, version, definition_hash)` plus a stratum (task class, mode, model family). A new version starts an empty record. 2. Every outcome has a tier: `verified` (needs an artifact digest), `user_marked`, `host_reported`, `inferred` (stored, never resolved: it may only carry `unknown`). 3. Likes, saves, forks, views, accepted answers, consensus and silence never create an outcome. 4. A record shows `n_uses`, `n_resolved`, the resolution rate, tier mix, a Wilson 95% interval, and a baseline only from the same principal's uses without the skill, always labelled observational. 5. Co-active skills each get the use; no model apportions credit. 6. Uses younger than their horizon are unresolved, not failures. 7. A record holds no free text. 8. `use_id` is issued by Pilot when a skill is fetched and an outcome must reference one.

## Consequences

Records are descriptions, not causal claims. Host-reported outcomes are self-asserted and are displayed as such. Schemas: `skill-use`, `prediction`, `outcome`, `track-record`, with fixtures proving the rules.

## Alternatives considered

Per-skill scores without strata (mixes tasks and models); crediting skills by model-estimated contribution (unfalsifiable).
