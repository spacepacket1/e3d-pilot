# ADR-0022: Local plan preview, seat skills and the plan digest

Status: **Owner-decided 2026-11-23** (the skills phase 3 plan, `docs/skills/phase3/plan.md`, approved as written). Phase: 3a.

## Context

Spec 5.5 defines an `ExecutionPlan` (`skill-plan` schema) that is a **hosted** object: it requires a principal, a quote, an approval and credit limits. The engine has none of those, so a local preview cannot validate against it. Seats already work through `--specialist`, and native skill folders load as experts, but a seat cannot be pinned to a skill version and hash, and nothing shows what a run will do before it runs.

## Decision

1. **One planning layer** (`lib/skills/plan.mjs`) resolves seat skills through the Phase 2 resolver, checks the hook against the target (`debate_seat` allows `seat_prompt`), refuses a skill that does not declare it, and builds the preview. The existing planner (`assign`, `lensBlock`) is reused unchanged; a skill is turned into an expert-shaped seat (`expertFromSkill`), so legacy `--specialist` and the new path share every rule.
2. **A separate engine-local contract, `skill-preview` (`e3d.skill-preview/v1`)**, holds what a run would do: seats with skill id, version, `definition_hash` and legacy folder hash, adapter and vendor family, prompt block size, plain seats and why, observers (empty until phase 3b), independence, a call and token estimate, conflicts and warnings. It carries no instruction text. The hosted `skill-plan` wraps the same facts with identity, quote and approval; the preview digest becomes its `request_digest` input. This is an additive schema in contracts v1.
3. **Seat prompt format is unchanged** (owner decision D2): `lensBlock` stays byte for byte; id, version and hash are in the receipt and the preview, not in the prompt.
4. **`--seat-skill <id|name>[@version][#sha256:hash][:provider]`** sits beside `--specialist` (owner decision D3), behind `E3D_SKILLS_V1=1` and `E3D_SKILLS_SEATS=1` (and `E3D_SPECIALISTS=1`, since it runs a debate). A pin that does not match, an unknown, withdrawn or non-seat skill stops the run before any model call (`skill_hash_mismatch`, `skill_version_invalid`, `skill_not_found`, `skill_withdrawn`, `skill_conflict`). `--on-seat-skill-failure plain_seat` is the only way a seat runs without its skill: that seat sends no lens and is recorded as a plain seat with the failure code, in the receipt, the preview and on stderr (ADR-0013). Provider hints come from the skill's hashed `model_hints`; an explicit `:provider` wins.
5. **Plan digest.** `plan_digest = sha256(JCS({request (question hash, rounds, max words, synthesizer), seats (seat, adapter, source, skill, legacy folder hash, lens bytes, forced provider), plain seats, observers}))`. `--preview-skills` prints it, `--expect-plan` refuses a run whose digest differs (`skill_quote_expired`), and the receipt records `skills_plan_digest`. Locally this protects preview-then-run; the signed token binding identity and audience is hosted (ADR-0012).
6. **The estimate is an estimate.** Model calls are counted exactly (seats times rounds, one synthesis, observers, and double with one retry each); tokens come from the cost model for a typical short question and are labelled as such. Credits are quoted by the hosted service, not by the engine.
7. **Receipts re-read nothing.** The skills block is built from the catalogue loaded at planning time and matched to the chosen experts by name, tier and folder bytes; an expert whose bytes match no entry is recorded with a null definition and a reason.

## Consequences

`tests/skills-plan.sh` covers the grammar, the equivalence of a built-in as a seat with the existing expert, hints and forced providers, pins and failure codes, the plain-seat fallback in the receipt, digest sensitivity (question, rounds, pool, forced provider, lens text, skill version) and the off-by-default behaviour. The observer (3b) fills the `observers` array; chat hooks (3c) need the hosted contract.

## Alternatives considered

Validate the local plan against `skill-plan` (it would need a fake principal, quote and approval); labelled seat blocks (changes every prompt golden); a digest over the prompt text (leaks nothing but ties the digest to wording rather than identity).
