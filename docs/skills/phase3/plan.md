# Skills phase 3: plan (seat, observer and chat attachment runtime)

Status: **plan for review. No code is written and nothing here is approved.** Date: 2026-11-23. Audited `main` at `3ffd0db`. Spec: `docs/skills/spec/e3d-pilot-user-defined-skills-spec-v0.1.md`, "Phase 3". Companion hosted spec: `e3d-pilot-cloud` `docs/skills-hosted-spec.md` (private).

## 1. What the spec asks for, and what the audit found

The spec's Phase 3 bundles six items. They are not equally ready, and one of them cannot be finished in the engine alone.

| Spec item | State on `main` | Finding |
| --- | --- | --- |
| Shared Attachment and ExecutionPlan interfaces | none. The schemas (`skill-attachment`, `skill-plan`, `skill-run`) and the resolver (`lib/skills/definition.mjs`) exist; nothing joins them | Build first; everything else uses it |
| `debate_seat/seat_prompt` | **works today** through `--specialist` (experts), and native skill folders already load as experts. Missing: version and hash pins on the CLI, `model_hints` from `skill.json`, per-seat failure policy, a plan | Mostly mapping and hardening |
| `debate_observer/after_synthesis` | **nothing**. No observer, no extra model call after the verdict, no `observers` receipt block | The real new runtime and the real new risk |
| `chat/before_response` | **works today** as `chat_skills_v1` (1 to 3 built-in lenses, `lib/mcp/chat-runner.js`), only on the hosted listener and only built-in skills | Unchanged in this phase |
| `chat/after_response` | **nothing**. It is a second model call per chat message | Money and contract change: needs the hosted pricing contract first (see 3) |
| Preview with versions, prompt summaries, conflicts, observer schedule, independence, worst-case cost | no panel or plan preview exists (`--show-panel` is listed as not built in `docs/experts.md`); `--show-specialist` shows one expert | New: `--preview-skills` |
| Legacy `experts` mapped to seat attachments | experts reach the engine as `--specialist` / `--expert-pin` | Map internally; old contracts and goldens must stay byte-identical |
| Hosted UI | hosted repo | Not this repo (hosted phase 3) |

Other facts that shape the plan:

- **There is no local chat command.** Chat only runs on the hosted listener (`lib/mcp/run-server.js` + `chat-runner.js`), and the hosted engine reads only the built-in catalogue (user folders are never read there). So user skills cannot reach a chat before hosted phase 7 (registry). Locally, Phase 3 is seats and observer.
- **The engine reports usage; the hosted service owns money.** An observer is a new paid model call. The engine can run and report it (a separate usage row), but quoting, charging and approving it are hosted decisions (ADR-0006 item 5). The cloud repo's rule applies: money or contract changes are run through a recorded debate before building.
- **Open PRs.** Engine: #3, #13, #14, #15 (ledger mirror and debate documents); none touch skills, experts, chat or the debate runtime. Cloud: none touch skills or experts; #332 (Ask-page threads marker) edits `site/app/views/ask.js`, next to the chat Skills composer, and matters only for hosted phase 3.
- **Reusable pieces:** `lib/debate/cost-model.mjs` (worst-case token and call counts, used by quotes), `lib/debate/specialists-plan.mjs` (`assign`, `independenceOf`, `lensBlock`), the schemas for plan, run and observation, and the advisory scan.

## 2. Recommended shape: split Phase 3 into 3a, 3b, 3c

| Part | Delivers | Needs from the owner |
| --- | --- | --- |
| **3a Plan and seats** | `lib/skills/plan.mjs` (resolve attachments, validate hook against target, detect conflicts, worst-case cost, plan digest); `--preview-skills`; seat attachments by skill reference with pins; per-seat failure policy; legacy `--specialist` mapped through the same layer, byte-identical; receipt additions | decisions D1 to D4 |
| **3b Observer** | `after_synthesis` runtime: one read-only model call after the verdict is stored; nonce-fenced prompt; output validation and fallback; `observers` receipt block; usage row; cancellation; failure isolation; a test that the verdict is byte-identical with and without it | D5 to D8, and approval of one metered canary |
| **3c Listener and chat** | the engine listener accepts `skill_attachments` (and `skill_plan_token` opaque to the engine); chat `after_response` if approved | the hosted pricing contract (a recorded debate in the cloud repo), then a cloud PR |

3a and 3b are engine-only, local, flag-gated and do not need the hosted service. 3c cannot start before the hosted contract is agreed. Starting with 3a and 3b delivers the user-visible value (seat skills with pins and a plan, an observer) without touching billing.

## 3. Design decisions to settle (each becomes an ADR before its code)

**D1. One attachment layer for chat and debate.** `lib/skills/plan.mjs` takes `[{ target, hook, skill_ref, parameters, priority, enabled }]`, resolves each skill to `(id, version, definition_hash)` through the Phase 2 resolver, checks hook against target with the existing rule (`debate_seat` allows `seat_prompt`; `debate_observer` allows `after_synthesis`; `chat` allows the two chat hooks), and returns a plan that validates against `skill-plan.schema.json`. At most one lens-style skill per seat (spec 5.3). Recommended: yes.

**D2. Seat prompt format.** Phase 2 kept `lensBlock` byte for byte and carried id, version and hash in the receipt only. Spec 6.4 wants labelled blocks. Recommended: **keep `lensBlock` for seats** (the delimiters are the trust zone; labels live in the receipt and the preview). Labelled blocks apply to observer and chat blocks, which are new. This keeps every prompt golden unchanged.

**D3. Seat surface.** Recommended: keep `--specialist name[:provider]` exactly as is, and add `--seat-skill <id|name>[@version][#sha256:hash][:provider]`, which feeds the same layer and lets a seat be pinned. Both can be mixed in one panel. `model_hints` from a native skill's `skill.json` become provider hints, as `expert.json` models do today.

**D4. Failure policy for a seat skill** (ADR-0013). A seat skill that fails to resolve or whose pin does not match stops the run before any model call (`skill_*` code, exit 1). It never runs unlensed unless the request says `--on-seat-skill-failure plain_seat`. Recommended: as written.

**D5. Observer prompt layout and trust zones.** Blocks in order: (1) fixed policy, (2) task contract, (3) the skill, labelled with id, version, hash and scope, (4) the debate content (positions, synthesis, dissent) as untrusted data inside a **fence made of a per-run random token**, so debate text can never close or forge the fence, (5) the user's question, (6) the output schema and limits. Debate content is model output and may carry injection; the nonce fence and the observer having no tools and no write path are the controls. Recommended: as written, with an adversarial test set.

**D6. Observer output and what it may do.** The observer returns a bounded report (`max_output_bytes` from the skill) and optionally structured `observations` that validate against `observation.schema.json`. It is written to its own file and to `observers[]` in the receipt, never into the verdict, and it cannot change positions, synthesis, dissent, the quote or the charge. Invalid output follows the skill's declared fallback. Failure never fails the debate (ADR-0006).

**D7. Observer provider and independence.** The observer needs a model. Options: the synthesizer's provider (simple, but it grades its own verdict) or an explicit `--observer-provider` (recommended, defaulting to a provider that did not synthesize when one is available, and showing the family in the preview). Cap: **one observer per debate in 3b**; more later. Recommended: explicit provider, default non-synthesizer, one observer.

**D8. Flags.** Per ADR-0014, one per scope, all strict unset/0/1 and off: `E3D_SKILLS_SEATS`, `E3D_SKILLS_OBSERVER` (each also needs `E3D_SKILLS_V1`). Preview needs only `E3D_SKILLS_V1`. The no-flag path loads no new code (same pattern as 2b).

**D9. Plan digest.** `plan_digest = sha256(JCS(request digest, resolved tuples, hooks, providers, limits, price inputs))`, recomputed at run time; a difference is `skill_quote_expired`. Locally this protects preview-then-run; the signed token that binds identity and audience is hosted (3c).

**D10. After-response chat hook.** Defer to 3c. It needs a second priced call per message, a quote shape and a decision on whether the draft is shown. Recommended: not in 3a or 3b.

## 4. Work breakdown (engine PRs, each flag-off and independently reviewable)

| PR | Content | Tests |
| --- | --- | --- |
| 3a-1 | `lib/skills/plan.mjs`, `--preview-skills` (JSON and a readable form: versions, hashes, prompt block sizes, seat to skill map, families, observer schedule, worst-case calls and tokens from `cost-model`, conflicts), schema-validated plan, `plan_digest` | plan unit cases; invalid attachments (wrong hook, two lenses on one seat, unknown skill, pin mismatch); digest changes on request, version, hash, provider, limits; no model call |
| 3a-2 | `--seat-skill`, pins, `model_hints`, `--on-seat-skill-failure`, legacy mapping through the layer, receipt fields (`hook`, `scope`, `attachment_id`) | goldens unchanged; three seats with three skills on stub providers; a failing pin stops before any call; `plain_seat` fallback is explicit |
| 3b-1 | observer runtime: prompt build, one adapter call, output validation, atomic file write, `observers[]`, usage row `observer:<skill>`, timeout and cancellation | verdict, positions, dissent and the seat usage rows byte-identical with and without an observer; observer failure keeps exit 0 and records the code; invalid output falls back; observer text cannot appear in the synthesis |
| 3b-2 | adversarial set for the observer (debate content that tries to close the fence, forge a notice, instruct the observer), then the independent security review | each case: the output is a report, the verdict is untouched |
| 3b-3 | one **metered** live canary (small question, three seats, one observer) and a latency check of the no-skill path | owner approves the spend first |
| 3c-1 | engine listener accepts `skill_attachments` after the hosted contract is agreed | with the cloud PR |

Docs for each PR (`docs/skills.md` sections, ADRs, the threat model rows T1, T8, T10, T14), and the independent review recorded in `review-record.md`, as in 2a and 2b.

## 5. Acceptance (from the spec, made testable)

- The spec's "four end-to-end scenarios" are read as: (1) a chat skill (exists; unchanged), (2) three seats with three skills on a diverse stub pool showing exact hashes, (3) an observer that fails while the debate completes with the failure visible, and (10) the no-skill regression (goldens byte-identical).
- Observer output cannot overwrite positions, synthesis or dissent: proven by byte comparison, not by reading.
- Plan digest invalidates on request, version, hash, provider, limits or price input.
- Receipts and the preview agree on the active skills and their order.
- No-skill path: with every flag off, no new module is loaded and prompts and receipts are byte-identical; a stub-timed comparison shows no added process or file read.
- Independent security review of the observer before it is enabled anywhere but a canary; the live canary is metered and needs your approval of the spend.

## 6. Risks

| Risk | Control |
| --- | --- |
| Debate text injects the observer (T1, T14) | nonce fence, no tools, no write path, report kept apart from the verdict, adversarial tests, security review |
| Cost amplification (T8): an observer is a new paid call | one observer, bounded output and time, worst-case shown in the preview, quoted and approved by the hosted service before it can run there |
| The observer grades its own synthesis | explicit provider, default a non-synthesizer, family shown in the preview |
| A seat skill silently falls back to a plain seat | explicit policy, default fail, a test |
| Replay or edit between preview and run (T10) | plan digest, recomputed |
| Scope creep into hosted work | 3a and 3b are engine-only; 3c waits for the hosted contract |
| Calibration needs a `use_id` per observer run | the receipt already issues one per skill use; the observer run gets its own |

## 7. Questions for you

1. Split Phase 3 into 3a, 3b and 3c as above, and start with 3a?
2. D2: keep `lensBlock` for seats (receipt carries the labels)?
3. D3: add `--seat-skill` beside `--specialist`, or only extend `--specialist` with pins?
4. D7: observer provider explicit, default a non-synthesizer, one observer per debate?
5. D10: defer the chat `after_response` hook to 3c?
6. May 3b-3 spend a small amount on the metered key for a live canary (I would state the cost class first)?
7. Do you want a minimal built-in **observer skill** for demos in 3b, or leave showcase skills to Phase 6?
8. Hosted contract: do you want the cloud-repo debate on observer pricing run now, in parallel with 3a?
