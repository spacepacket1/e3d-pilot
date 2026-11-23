# ADR-0006: Observer semantics

Status: **Proposed** (needs a human decision before Phase 2). Date: 2026-11-22. Phase: 1.

## Context

Spec 3.3: `after_round` (shadow only, flag off) and `after_synthesis`. The synthesis prompt never contains a lens today, and a debate's verdict, consensus and dissent are the product.

## Decision

1. Phase 3 implements **`after_synthesis` only**. 2. **`after_round` is not approved** in Phase 1: it adds a model call per round, changes cost and quote shape, and cannot be shown to be non-influencing without a design for reading debate state mid-run. It can be reconsidered with its own ADR after Phase 3 measurements. 3. An observer receives the finished receipt (positions, synthesis, dissent) as **read-only data**, runs after the verdict is stored, and writes to a separate block (`observers[]`). It cannot change positions, synthesis, dissent, the quote or the charge for the debate. 4. Observer failure never fails the debate; the receipt records `skill_*` code and status `failed`. 5. Observer cost is quoted and approved separately (it is a new paid call). 6. Results show seats, synthesis, dissent, then observer reports, never merged into the verdict.

## Consequences

Smallest change that delivers the showcase (behavioral evaluation of a finished debate) without touching debate independence.

## Alternatives considered

Interactive facilitation during rounds (changes independence and cost; the spec itself defers it).
