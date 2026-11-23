# ADR-0013: Failure policies

Status: **Accepted as written** by the owner on 2026-11-23 (it was Proposed). Date: 2026-11-22. Phase: 1.

## Context

Spec 6.5 lists behaviours. Today: a panel never shrinks silently, missing provider refuses, hosted fill-pool turns a vendor with no expert into a plain seat by design.

## Decision

Adopt spec 6.5 with these precisions: **hash/version mismatch** fails before spend; **seat skill fails before the call**: the debate does not run that seat unlensed unless the request set an explicit `on_seat_skill_failure: plain_seat` (default `fail`); a plain seat that exists by design (fill-pool) is not a failure; **observer** failure never fails the debate; **missing optional capability** applies the skill's declared `fallback` and shows a notice; **missing required capability** fails the preview; **invalid output** retries at most once and only inside the quote, else declared fallback; **Brain unavailable** continues only when memory is optional and never substitutes another scope; **composition node failure** follows the explicit policy (`fail_fast`, `continue_optional`, `fallback_node`), no implicit default. The schemas carry what this needs: `requested_capabilities[].required`, attachment `on_failure` (`fail` or `plain_seat`), composition node `optional` and `fallback_node`. Every failure is a receipt entry with a stable code; cost already incurred is reported.

## Consequences

Matches existing no-silent-substitution behaviour and the spec.

## Alternatives considered

Best-effort continuation by default (hides degraded runs).
