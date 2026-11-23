# User-defined skills: implementation record

Source: the "E3D Pilot User-Defined Skills: Implementation Specification" (v0.1, 2026-11-22), implemented one phase at a time. Skills generalise the expert lens system; the no-skill path and the existing expert, debate, chat, quote, billing and provenance behaviour stay as they are.

## Phase 1 (grounding, ADRs, schemas, threat model, evaluation freeze): documents, schemas, fixtures and tests only

| Deliverable | Where |
| --- | --- |
| **Engine specification v0.1 (part 1 of 2; phases 1 to 6; runnable by e3d-code).** The hosted part is in the private `e3d-pilot-cloud` repository, `docs/skills-hosted-spec.md` | [spec/e3d-pilot-user-defined-skills-spec-v0.1.md](spec/e3d-pilot-user-defined-skills-spec-v0.1.md) |
| **Calibration specification v0.1 (part 3; builds on the skills contracts)** | [spec/e3d-pilot-calibration-spec-v0.1.md](spec/e3d-pilot-calibration-spec-v0.1.md) |
| Grounding report, gap table, contradictions, phase map | [phase1/grounding-report.md](phase1/grounding-report.md) |
| 21 ADRs: 0001-0015 **Proposed**; 0016-0021 (calibration) **owner-decided 2026-11-23**, awaiting reviewer sign-off | [phase1/adr/](phase1/adr/) |
| User guide for the local skills commands (phase 2b) | [../skills.md](../skills.md) |
| Phase 3 plan (seat, observer and chat attachment runtime), for review | [phase3/plan.md](phase3/plan.md) |
| 12 JSON Schemas, shared definitions, stable error codes | [schemas/v1/](schemas/v1/) |
| Fixtures (19 valid, 56 invalid; 16 schemas including the calibration records) and the harness | `tests/fixtures/skills/`, `tests/skills-schemas.{sh,mjs}` |
| Threat model, permission matrix, privacy inventory | [phase1/threat-model.md](phase1/threat-model.md) |
| Evaluation freeze (**proposed, not frozen**) | [phase1/evaluation-freeze.md](phase1/evaluation-freeze.md) |
| Compatibility baseline and its tests | [phase1/compat-baseline.md](phase1/compat-baseline.md), `tests/skills-compat.sh` |
| Fixtures that need runtime code | [phase1/deferred-fixtures.md](phase1/deferred-fixtures.md) |

Run: `bash tests/skills-schemas.sh && bash tests/skills-compat.sh && bash tests/debate-specialists.sh`

### Exit gate (spec section 16, Phase 1)

No runtime work starts until architecture, security/privacy and evaluation reviewers approve. Status:

| Gate | Reviewer | Status | Date | Notes |
| --- | --- | --- | --- | --- |
| ADRs 0001-0004, 0012, 0014, 0015 (the phase 2 set) | owner | **accepted as written** | 2026-11-23 | Given when skills phase 2 was authorized; phase 2a and 2b have independent reviews in `phase1/review-record.md` |
| Architecture (ADRs 0005-0009, 0013, 0017) | pending | not approved | | |
| Security and privacy (threat model, ADR-0007, 0008, 0011, 0016, 0019, 0020) | pending | not approved | | |
| Evaluation thresholds (evaluation-freeze.md) | pending | not approved | | |
| Owner decisions (ADR-0010 license policy, ADR-0011 numbers) | pending | not approved | | |

Remaining dissent and open risks are recorded here when reviews return.

## Implementation status (spec appendix B)

Last verified 2026-11-22 against engine `511cce9` plus this branch; hosted `54b4740`; Brain `fc9effa`.

| Capability | Status | Flag | Code owner | Evidence |
| --- | --- | --- | --- | --- |
| Built-in instructional experts | implemented | `E3D_SPECIALISTS` (engine); hosted flags off by default | e3d-pilot | `lib/specialists/`, `tests/skills-compat.sh` |
| User-local instructional skills | **implemented locally in phase 2b** (projection of experts, native folders, resolver, six CLI commands, four stdio MCP tools, receipt block); flag off | `E3D_SKILLS_V1`, `E3D_MCP_SKILLS` | e3d-pilot | `tests/skills-runtime.sh`, `docs/skills.md` |
| Chat attachment | partial (built-in lenses, 1 to 3) | hosted chat flags | e3d-pilot / cloud | `lib/mcp/chat-runner.js` |
| Debate seat attachment | implemented as `experts` | `E3D_SPECIALISTS`, `E3D_MCP_EXPERTS_*` | e3d-pilot / cloud | `lib/debate/specialists-plan.mjs` |
| Debate observer | proposed | observer flag | e3d-pilot / cloud | ADR-0006 |
| Composition | proposed | composition flag | e3d-pilot | schema + fixtures only |
| Tool broker | proposed | per adapter | e3d-pilot | ADR-0007, permission matrix |
| Brain gateway | proposed; Brain has no per-request scoping | per adapter | e3d-pilot (gateway), e3d-brain | ADR-0008 |
| Evaluation / learning proposals | proposed | eval flag | e3d-pilot / cloud | schemas + freeze |
| Hosted user lifecycle | proposed | tenant canary | e3d-pilot-cloud | ADR-0009 |
| Public catalogue / forking | proposed | public flag | e3d-pilot-cloud | ADR-0010 |
