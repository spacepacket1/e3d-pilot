# Skills Phase 1: threat model, data flow, permission matrix, privacy inventory

Status: draft for security/privacy review, 2026-11-22. Applies to the design in the skills specification; nothing here is built yet beyond the existing expert path.

## 1. Assets

Users' questions and answers; private skill definitions and their tests; Brain memory (the owner's notes); API keys and provider credentials;
credits and quotes; receipts and the decision log; Gallery publications and their lineage; the integrity of consensus and dissent.

## 2. Trust zones and data flow

```
                      untrusted                                   trusted (Pilot-controlled)
  user text, skill folders, imported skills,            non-overridable policy + task contract
  tool results, Brain items, marketplace metadata,      resolver, planner, policy engine, broker
  model output                                          receipts / ledger, quote + billing
        |                                                           |
        v                                                           v
  [1 skill definition] --validate/hash--> [2 resolver] --pin--> [3 planner] --policy ∩--> [4 plan + quote]
                                                                                              |
                                                          approval (human, unspoofable)  ---->|
                                                                                              v
  Brain (advisory) <--grant only-- [5 broker/gateway] <--- [6 runtime: prompt blocks 1..6] ---> provider (model)
                                                                  |
                                                                  v
                                       [7 receipt/ledger] --> read models (UI, Gallery, analytics aggregates)
```

Prompt blocks (spec 6.4, unchanged): 1 policy, 2 task contract, 3 skill instructions (labelled id/version/hash/scope), 4 untrusted retrieved or tool content (separately delimited), 5 user request and bounded context, 6 output schema. Zones 1, 4 and the model output are untrusted at every step.

## 3. Threats, current state and required controls

"Today" is the existing expert path. "Gap" is what the spec needs that does not exist. Phase is when the control is built.

| # | Threat | Today | Gap and required control | Phase |
| --- | --- | --- | --- | --- |
| T1 | Prompt injection through a skill body | Lens is delimited, shown whole (`--show-specialist`), cannot grant tools or flags; injection test keeps it out of other seats and the synthesis (`tests/debate-specialists.sh` section 7) | Trust zones for skills beyond seats; adversarial fixture per zone | 3 |
| T2 | Injection through retrieved data or tool output | Not applicable (no tools, no memory) | Separate delimited block 4; output validation; allow-listed broker | 5 |
| T3 | **Delimiter spoofing**: a lens that contains the end-marker line `[End of role. ...]` | **Present.** `lensBlock` does not escape or reject it; `validateFolder` has no rule. Impact today: that seat only | Reject or neutralise marker lines at validation and at prompt assembly; fixture and test | 2 |
| T4 | Malicious package: scripts, symlinks, huge or binary files, path traversal | Refused or ignored with coded errors (`symlink_in_skill`, `too_large`, `too_many_files`, `scripts_present_never_run`, `symlink_escape`) | Same plus import is inert (`import-inert`), size/count limits re-checked before prompt assembly; `skill_scripts_not_allowed` in schema | 2 |
| T5 | Confused deputy: content asks the model to use a capability | No capabilities exist | Grants are run-scoped, explicit resource, not derived from content; denial reaches no adapter | 5 |
| T6 | SSRF / exfiltration through tools | No URL tools; hosted web search is Pilot's own path | No arbitrary URL capability in v1; egress policy; redaction | 5 |
| T7 | Cross-tenant leak (skills, caches, logs, analytics, Brain) | Hosted built-ins only; private data is per account/team (audit) | Tenant-scoped keys, cache partitioning, negative auth tests, destination-aware gateway | 5, 7 |
| T8 | Cost amplification (large compositions, retries, observers) | Quote prices lens bytes; panel max 6; per-token bounds | Static worst-case expansion; node/call/byte/time ceilings in schema; quote covers observers; concurrency limits | 3, 4 |
| T9 | Version substitution (alias race, hash swap) | Hosted pins `{id, hash}` and refuses mismatch | Plan binds resolved tuples; execution re-verifies; replayed or altered plan token rejected | 3, 7 |
| T10 | Replay of a plan token or grant | Quote ids and idempotency keys exist for debates | Plan/grant bound to request digest, identity, audience, expiry | 3, 5 |
| T11 | Marketplace manipulation (fake reactions, sybil forks) | Gallery reactions are one per account per debate (audit) | Reactions never feed evaluation or permission; rate limits; reports and appeals reuse Gallery | 8 |
| T12 | Behavioral surveillance | None | Private default; prohibited inference list; minimum evidence and expiry in schema (`observation`); export, correct, delete; no team ranking | 5, 6 |
| T13 | Memory poisoning | Brain writes are proposals in an inbox; secrets scrubbed on write | Knowledge status and provenance on every item; bounded retrieval; corrections append | 5 |
| T14 | Observer or synthesis skill erases dissent | The synthesis never receives a lens | Observer is read-only, separate block, runs after the verdict is stored; test that positions, synthesis, dissent, quote and charge are identical with and without an observer | 3 |
| T15 | Log/metric injection and PII in telemetry | Hosted usage events per ledger transition, best effort | Event schema has no free text content (`event--raw-prompt` fixture fails); aggregates only | 5 |
| T16 | Public result references private evidence | n/a | Publish preview scans refs; destination-aware retrieval; negative tests | 8 |
| T17 | Unattended runner risk when building this feature | `e3d-code` defaults to `bypassPermissions` | Phase 1 did not use the runner; later phases run it only in a dedicated worktree, never in a shared checkout | process |
| T19 | **Hash-line stripping**: lens text hidden from the folder hash (finding F-2) | **Present.** `hashed()` strips `e3d.expert.hash:` lines anywhere in SKILL.md | Strip only in frontmatter; fixture; built-in hashes unchanged (pinned) | 2 |
| T20 | Unicode and control characters hide what the model reads (bidi override, zero-width, homoglyph, non-NFC) | Folder validation checks NUL only | Schema pattern forbids them; NFC required; fixture `bidi-override`; homoglyph risk accepted and shown in preview | 2 |
| T21 | TOCTOU between validate, hash and read | Separate filesystem passes | Read each file once, hash and use the same bytes | 2 |
| T22 | Referent drift behind a hashed reference (schema refs, suite refs) | n/a | `e3d://schemas/*/vN` immutable and shipped in the repo; receipts record fixture versions | 2 |
| T23 | Withdrawn or deprecated skill still runs; mutable name or description spoofs approval | n/a | Status checked live (`skill_withdrawn`); name and description are hashed; no router reads `tags` | 3, 7 |
| T18 | Secrets in a skill (public) | none | Publish scanner for secrets, PII, local paths, private evidence refs | 8 |
| T24 | **Served skill injects the host agent**: a skill fetched over MCP instructs a tool-capable agent (shell, files) to act | None (no skill tools yet) | Serve as labelled data only; instructional only; never install or run; scanner for host-directed instruction patterns; user sees hash and source; host keeps its own permissions (cannot be enforced by Pilot) | 2, calibration 3 |
| T25 | Outcome poisoning: fake or self-serving use and outcome reports | n/a | Server-issued `use_id`; per-principal records; tiers displayed; aggregation only with opt-in, minimum group size and source diversity; reactions never count | calibration 3, 7 |

## 4. Permission matrix (v1 capability vocabulary)

Grant requires the whole intersection in spec 11.2. "Level" is the skill's capability ceiling.

| Capability | Instructional | Tool-enabled | Learning | Scope bound | Resource classes | Available from |
| --- | --- | --- | --- | --- | --- | --- |
| `context.read.current_request` | implicit, no grant | implicit | implicit | the request | n/a | Phase 2 |
| `conversation.read.current` | no | yes | yes | one conversation | chat turns | Phase 3 |
| `debate.read.current` | no (observer receipt is input data, not a capability) | yes | yes | one debate | debate receipt, claims | Phase 3 |
| `web.search` | **no** | yes, only if Pilot already allows search for that run | yes, same | run | n/a | Phase 5 |
| `artifact.read.explicit` | no | yes | yes | named artifact id | artifact | Phase 5 |
| `brain.read` | no | yes, local owner scope only (ADR-0008) | yes | `current_user`, `current_project` | outcome summary, user correction | Phase 5 |
| `brain.propose` | no | no | yes | same | proposal | Phase 5 |
| `evaluation.read` | no | no | yes | own runs | evaluation | Phase 5 |
| `evaluation.emit` | no | no | yes | own runs | observation, evaluation | Phase 5 |
| anything else (filesystem, shell, network, credentials, repository write, messaging, publication, billing, account) | **not representable in v1** (`skill_capability_unknown`) | same | same | n/a | n/a | never in v1 |

Rules: an instructional skill requesting any capability is invalid (`skill_capability_denied`, reference check in the harness); a denial is explicit, auditable and never silently widened; a capability is a ceiling, each run gets only what was approved.

## 5. Privacy and data inventory

| Data class | Where it lives today | Where it will live | Retention (proposed, ADR-0011) | Deletion | Leaves the account/team? |
| --- | --- | --- | --- | --- | --- |
| Public definition (built-in) | engine folders; hosted catalogue copy | same, later registry | with the release | with the release | yes (public) |
| Private definition and tests | none today (local folders only) | local folder; hosted registry (Phase 7) | until deleted or account closed | account-close step (to build) | no |
| Execution input (question, context) | debate/transcript rows | same | 90 days (hosted transcript default) | with the debate | no |
| Skill output | within positions/receipt | receipt and artifact | 90 days | with the debate | only if the debate is published |
| Tool/memory evidence | none | Pilot ledger refs; Brain items are not copied | per source; refs 365 days | with the run | no |
| Observation | none | event/observation store (Phase 5) | 30 days default, 180 max, `expires_at` required | user delete, expiry job | no |
| Evaluation record | experiments only | evaluation store | life of the skill version, private by default | with the skill | no |
| Billing and audit | hosted ledger, usage events | same plus skill refs | financial rows kept; audit minimum 365 days | financial rows never deleted | no |

No raw credentials, hidden reasoning or unredacted private tool output in any layer (spec 9.1). Analytics receive aggregates only.

## 6. Residual risks accepted for Phase 1

None accepted silently. Items T3 and the stale golden (fixed) were found by this phase. Everything else is a control to build, tracked by phase above.
