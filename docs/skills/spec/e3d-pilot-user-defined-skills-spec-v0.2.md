# E3D Pilot User-Defined Skills — Implementation Specification

**Version:** 0.2
**Date:** 2026-11-23
**Supersedes:** v0.1 (2026-11-22). v0.1 is kept unchanged in Drive for history.
**Status:** Implementation proposal, reconciled with the four repositories on fresh `main` (Phase 1 grounding, draft PR `spacepacket1/e3d-pilot#92`). ADRs 0001-0014 are **Proposed** and need human approval before Phase 2 starts. Facts about the code carry a commit; everything else is still a proposal.
**Primary repositories:** `spacepacket1/e3d-pilot`, `spacepacket1/e3d-pilot-cloud`
**Companion repositories:** `spacepacket1/e3d-code`, `spacepacket1/e3d-brain`
**Audience:** E3D maintainers and e3d-code implementation agents

> **Governing principle:** Pilot orchestrates. Skills provide specialized intelligence. E3D Brain remembers. Evaluation determines what works.

## Revision notes (v0.1 to v0.2)

v0.2 changes only what Phase 1 showed to be wrong, missing or unrunnable. Section numbers are unchanged. The evidence is in `docs/skills/phase1/grounding-report.md`; each decision is an ADR in `docs/skills/phase1/adr/`.

| Area | v0.1 said | v0.2 says | ADR |
|---|---|---|---|
| Authoring format | nested YAML with inline lists | JSON for structure (`e3d/skill.json`); `SKILL.md` frontmatter stays the engine's small subset, which refuses `[`, `{` and nesting | 0001 |
| Hash | one `content_hash`, RFC 8785 | two hashes: the existing folder hash (`legacy_folder_hash`, unchanged) and a new `definition_hash`. `content_hash` is already the MCP field that holds the folder hash, so it is not reused | 0003 |
| Name, description | not stated | hashed, so editing them is a new version; `tags` never hashed and never used for routing | 0003 |
| Version | semantic version | existing integer string `"N"` projects to `N.0.0` | 0002 |
| Identifiers | `skill.user_01hxyz.slug` | slug is the existing name (`^[a-z0-9]+(-[a-z0-9]+)*$`, equals folder name); id derived as `skill.<owner>.<name>` | 0014 |
| Error codes | upper case | lower-case `skill_*` (the engine and hosted already return lower-case codes) | 0014 |
| Flags | `E3D_SKILLS_V1` | kept, added next to the existing `E3D_SPECIALISTS`, `E3D_MCP_EXPERTS*`, `E3D_MCP_CHAT_TOOL`; strict unset/`0`/`1` | 0014 |
| API names | `/v1/skills`, `e3d_*_skill` | no new MCP tool or route before Phase 7; Phase 2 adds CLI verbs only; `e3d_list_experts` / `e3d_get_expert` stay forever | 0005 |
| Observer hooks | `after_round` (shadow) and `after_synthesis` | `after_synthesis` only; `after_round` not approved and rejected by the v1 schema | 0006 |
| Brain gateway | Brain enforces principal, tenant, audience, purpose | Brain has one principal per process and none of those fields; the gateway lives in Pilot and Brain stays advisory | 0008 |
| Database | tables, forward/backward migrations | hosted is MongoDB: new collections, start-up index creation, dry-run backfill scripts (`--apply --i-have-a-backup`); no tenant concept, `tenant_id` is a nullable team id | 0009 |
| Chat attachment | proposed, Phase 3 | partly built and flagged (`chat_skills_v1`, 1 to 3 built-in lenses); Phase 3 extends it | grounding 3 |
| Evaluation | at least 50 tasks | 90 tasks, one primary test, thresholds proposed (not frozen until a human approves and the signed tag exists) | `evaluation-freeze.md` |
| Existing defects | not known | hash-line stripping (F-2) and lens delimiter spoofing (T3) are in the engine today; fixed first in Phase 2 | 0003, threat model |
| Runner | e3d-code runs this file | the v0.1 heading "1.2 ... Phase 1 must resolve" made e3d-code stop with `duplicate phase number`; fixed here (see section 16) | n/a |

## 0. Executive decision

Build user-defined skills as a backwards-compatible generalization of Pilot's current expert-lens system, not as a separate metacognition or behavioral-intelligence subsystem.

A skill is a versioned, permission-declaring capability that can be attached to:

1. an ordinary chat;
2. an individual debate seat/expert;
3. a debate-wide observer; or
4. a composition of other skills.

Skills advance through three capability levels:

- **Instructional:** bounded instructions plus typed input/output; no tools and no durable writes.
- **Tool-enabled:** requests capabilities through Pilot's policy-enforced broker; a skill definition never grants authority.
- **Learning:** observes permissioned outcomes and proposes evidence-backed changes or routing recommendations; it never silently edits its own published definition or changes Pilot policy.

Metacognition and behavioral intelligence are the first showcase skills. Metacognition recommends an execution strategy; it does not execute it. Behavioral intelligence evaluates interactions and outcomes; it does not create permanent claims about a person, model, or workflow without evidence, provenance, scope, and expiry.

The implementation begins local/private and instructional, then adds attachment scopes, composition, permissioned tools, evaluation, hosted user lifecycle, publishing/forking, and finally evidence-backed learning and marketplace ranking. Existing debate calls with no skill parameters must remain behaviorally and schema compatible.

## 1. Evidence base and implementation-status boundary

This specification was prepared from the referenced product discussion, connected Google Drive documents, current repository metadata/content, and the connected Pilot tool catalogue. It is not a claim that all described capabilities exist.

### 1.1 Verified current state

Audited on fresh `main`: engine `511cce9`, hosted `54b4740`, Brain `fc9effa`, e3d-code `40222a5`. "Flagged" means it exists and is off by default. Anything not listed here is proposed.

- **Experts are skill folders.** `SKILL.md` plus optional `e3d/expert.json`; built-in, user and repo tiers, later wins by name (`lib/debate/specialists.mjs` `loadExperts`). Ten built-in experts and four presets in the engine; the hosted browser suggest list has one preset.
- **Safety rules hold.** Tools are `none`; symlinks, oversize, malformed sidecars refused; `scripts/` never run; `allowed-tools` ignored; hosted never reads operator home directories.
- **Identity.** Expert version is an integer string. The hash is a file-tree hash (`path`, size, sha256 per file); hosted pins `{id, hash}` and refuses a mismatch. Receipts carry name, version, hash, tier.
- **Seats.** One lens per seat, at most six seats; the synthesis prompt never receives a lens.
- **Chat.** `chat_skills_v1` already attaches one to three built-in lenses to one model's answers (flagged; needs the hosted run listener).
- **MCP.** `e3d_list_experts` and `e3d_get_expert` (`E3D_MCP_EXPERTS=1`), experts on `e3d_debate` (`E3D_MCP_EXPERTS_RUN`, `E3D_MCP_EXPERTS_AGENT`), `e3d_chat` (`E3D_MCP_CHAT_TOOL`): all flagged.
- **Hosted.** MongoDB; no migration framework; accounts and flag-gated teams (default off); OAuth has one scope (`debates:run`); Gallery reports, appeals and fork counts exist per debate; quotes and idempotency keys exist and price lens bytes.
- **Brain.** Local-first Markdown memory, one principal per process, stdio MCP, six read tools plus an inbox-mode `capture`. No tenant, audience, purpose or resource-class fields.
- **e3d-code** `0.4.0`. Executes numbered Markdown phases; see section 16 for the heading rule and permission default.
- **Not built:** user-hosted skills, registry, aliases, composition, grants and plans, observer, observations, evaluation store, per-skill telemetry, publishing. Effectiveness is not proven (the one measured comparison, 2026-11-02, was inconclusive: +2.8 points, interval -4.6 to +10.2).
- **Open PRs** in the four repositories do not change expert or skill behaviour. One hosted PR (Ask-page threads marker) edits the file next to the chat Skills composer: recheck at the start of Phase 3.
- **Baseline.** The no-expert prompt goldens were stale after the per-model-summary change (PR #91); the Phase 1 PR regenerates them (12 added lines). The nine expert, MCP and case suites pass.

### 1.2 Open questions, answered in the grounding review

| Question | Answer |
|---|---|
| Database, migrations, boundaries | Hosted: MongoDB, start-up index creation, dry-run data scripts. Engine: files. The engine runs debates behind a loopback listener; quote, billing and idempotency are hosted (ADR-0009) |
| Shared code path | One engine, `bin/e3d-debate`; entry points are the hosted run listener, `bin/e3d-mcp` + `lib/mcp/agent.js`, `lib/mcp/case.js` (Investigate), `lib/mcp/chat-runner.js` (chat). Experts arrive as `--specialist` / `--expert-pin` |
| Canonical expert fields; drift | Engine `SKILL.md` frontmatter + `e3d/expert.json`. Hosted copies the built-in catalogue from the engine folders and pins its suggest table by sha256. No code drift; one doc contradiction in `docs/experts.md` (fixed in Phase 2) |
| Brain contracts; per-principal adapter | No safe per-principal advisory adapter exists; the gateway is built in Pilot (ADR-0008) |
| Telemetry, retention, deletion, consent, billing, moderation, lineage | Transcripts 90 days, decision records 365 days, account deletion cascades, financial rows are never deleted; Gallery moderation exists per debate. A skills collection needs its own deletion step and numbers the owner approves (ADR-0011) |
| Active PRs changing expert or skill behaviour | None |

These answers are a snapshot. Phase 2 and every later phase start by re-auditing `main` and active PRs; no phase may rely on this section instead of looking.

## 2. Goals, non-goals, and product invariants

### 2.1 Goals

1. Let a user create, validate, preview, test, version, reuse, export, publish, fork, and retire a skill.
2. Support instructional, tool-enabled, and learning capability levels behind explicit gates.
3. Attach skills to chats, debate seats, and debate-wide observer hooks with visible provenance.
4. Compose skills into deterministic, cycle-free workflows with typed handoffs and bounded budgets.
5. Keep Pilot as the sole authority for model/tool/routing/spend decisions.
6. Use E3D Brain for permissioned advisory retrieval and durable evidence references without making Brain an execution authority or duplicating Pilot's audit ledger.
7. Measure usefulness against strong baselines before claiming improvement or using performance in default routing.
8. Reuse Gallery identity, publication, reactions, moderation, billing, and lineage infrastructure rather than creating a parallel social system.
9. Preserve local-first/private skill use and Git/Markdown portability.

### 2.2 Non-goals for the initial release

- Arbitrary execution of code, install hooks, bundled scripts, remote MCP servers, or network requests from a community skill.
- Silent model, tool, permission, audience, or spending escalation.
- Self-modifying published skills.
- Treating likes, saves, acceptance, model consensus, or user silence as correctness.
- Inferring sensitive traits or durable personality judgments about users.
- Cross-user learning from private data without explicit, revocable authorization and aggregation rules.
- A paid creator marketplace or payouts before security, evaluation, moderation, fraud, tax, and support gates pass.
- Replacing existing chat/debate/investigate contracts or forcing every request through a metacognitive model call.

### 2.3 Invariants

1. **Definitions request; policy grants.** A skill may declare required capabilities. Only Pilot policy and the user/tenant authorization grant them.
2. **Content is untrusted.** Skill instructions, tool results, retrieved memory, marketplace metadata, tests, and model output are data—not authority.
3. **Versions are immutable.** Any executable meaning change creates a new version and content hash.
4. **Receipts pin resolved versions.** A run never points only to a mutable slug.
5. **Memory is advisory.** Pilot's append-only run/evaluation ledger is authoritative for actions and outcomes; Brain stores or indexes permissioned context and references.
6. **Learning proposes.** Evidence may create a version proposal or routing-policy candidate, never an automatic production mutation.
7. **Dissent survives.** Observer or synthesis skills cannot erase seat positions or disagreement.
8. **Private by default.** New skills, tests, memories, and evaluations are private until an explicit scope transition.
9. **No hidden injection.** Every active skill, version, scope, tool grant, memory source class, and composition step is visible in preview and receipt.
10. **Backward-compatible default.** No skill attachment means the existing execution path and result shape remain unchanged except additive optional telemetry fields that are absent by default.

## 3. Terminology and capability model

### 3.1 Core objects

| Object | Meaning |
|---|---|
| `SkillDefinition` | Immutable, canonical version of instructions, contracts, capability requests, hooks, and provenance. |
| `SkillAlias` | Mutable user-facing pointer such as `latest` or a channel; never stored alone in a run receipt. |
| `SkillAttachment` | A resolved request to apply one skill version at one scope/hook. |
| `SkillComposition` | A versioned DAG referencing pinned skill versions or declared update policies. |
| `ExecutionPlan` | Pilot-produced, policy-checked plan of skill steps, model calls, tools, memory reads/writes, budgets, and gates. |
| `PermissionGrant` | Run-scoped authorization issued by Pilot after policy and user checks. |
| `SkillRunReceipt` | Append-only record of resolved definitions, inputs, outputs, grants, costs, and status. |
| `Observation` | Structured, scoped event emitted by a run. It is not automatically a fact. |
| `EvaluationRecord` | Versioned evidence comparing a run or skill to a stated rubric/baseline. |
| `LearningProposal` | Evidence-linked proposal for a skill version or routing policy; requires review/approval. |

### 3.2 Capability levels

| Level | May do | Must not do |
|---|---|---|
| Instructional | Add bounded instructions; transform typed data; recommend actions | Call tools, read Brain, write durable data, authorize execution |
| Tool-enabled | Request allow-listed reads/actions through broker; cite results | Receive raw credentials; bypass broker; expand scope; execute bundled scripts |
| Learning | Read permissioned outcome summaries; emit observations/evaluations/proposals | Self-edit; silently profile; promote inference to fact; change router policy |

Capability level is a ceiling. A `learning` skill still receives only the grants approved for a particular run.

### 3.3 Attachment scopes and hooks

| Scope | Hook | Purpose | Initial availability |
|---|---|---|---|
| `chat` | `before_response` | Add method/context or recommend route before a reply | Phase 3 (extends the flagged `chat_skills_v1`) |
| `chat` | `after_response` | Critique/format/evaluate a draft before user delivery | Phase 3 |
| `debate_seat` | `seat_prompt` | Give one expert seat a lens/method | Existing expert path generalized in Phase 2/3 |
| `debate_observer` | `after_synthesis` | Evaluate behavior, evidence, dissent, or process | Phase 3 |
| `router` | `recommend_plan` | Recommend direct/chat/debate/tools/stop strategy | Phase 6 showcase; cannot execute |
| `evaluation` | `after_outcome` | Evaluate a verified downstream result | Phase 6 |

v1 has one observer hook, `after_synthesis`: it runs after the verdict is stored, is read-only, and cannot change positions, synthesis, dissent, quote or charge. `after_round` is **not approved** (it adds a model call per round, changes cost and quote shape, and cannot be shown to be non-influencing); the v1 schemas reject it, and a future schema version needs its own ADR (ADR-0006). Interactive facilitation is a further distinct mode.

## 4. Target architecture

```text
Host / Web UI / MCP client
 |
 v
Pilot API + Orchestrator <---- existing chat/debate/investigate/billing paths
 | | |
 | | +--> Policy Engine (identity, tenant, capability, spend, audience)
 | +-----------> Skill Resolver + Composition Planner
 +-------------------> Execution Runtime
 | | |
 | | +--> Tool Broker (allow-listed adapters)
 | +-----------> Brain Gateway (advisory, scoped)
 +-------------------> Model/Provider adapters
 |
 +--> Append-only Run / Provenance / Evaluation Ledger
 |
 +--> Read models: UI, Gallery, analytics, marketplace search

Pilot Cloud
 identity + tenant registry + immutable hosted versions + publication/fork lineage
 moderation + reactions + billing + searchable read models

E3D Brain
 user-owned/context-scoped memory and evidence references
 never grants execution authority; never replaces Pilot receipts
```

### 4.1 Ownership boundaries

**e3d-pilot** owns local schemas, validation, resolution, composition, prompt assembly, seat/observer runtime, tool-broker interface, receipts, CLI/MCP compatibility, and deterministic tests.

**e3d-pilot-cloud** owns hosted identity, tenant scopes, durable registry, APIs, publication/forking/moderation, Gallery integration, quotas/billing, hosted UI, and deployment migrations.

**e3d-brain** owns advisory memory storage/retrieval and citation-preserving context. It does not own skill registry truth, permissions, run status, evaluation authority, or publication.

**e3d-code** consumes this specification phase-by-phase. It does not become a runtime dependency of end-user skill execution.

### 4.2 Request flow

1. Host submits a chat/debate request plus zero or more skill references.
2. Resolver converts aliases/update policies to immutable `(skill_id, version, hash)` tuples.
3. Composition planner expands DAGs, validates hook/type compatibility, detects conflicts/cycles, and computes worst-case cost/tool/memory requirements.
4. Policy engine intersects requested capabilities with user, tenant, deployment, audience, and billing policy.
5. Pilot returns a preview/quote when any paid or consequential operation is present.
6. After required approval, runtime executes bounded steps and records per-step receipts.
7. Tool and Brain access occurs only through adapters receiving a short-lived run-scoped grant.
8. Output validator enforces declared schema; failures follow the declared fallback and never silently broaden access.
9. Pilot preserves original positions/drafts plus skill outputs, synthesis, dissent, cost, and errors.
10. Evaluation jobs may later attach outcome evidence. Learning jobs may propose—but not apply—changes.

## 5. Canonical contracts

Canonical wire and storage format is JSON; the schemas are `docs/skills/schemas/v1/*.schema.json`, validated by a zero-dependency harness (`tests/skills-schemas.sh`) against valid and invalid fixtures with stable lower-case `skill_*` error codes. Local authoring keeps the Agent Skills folder: `SKILL.md` (frontmatter: name, description, license, metadata; the body is `instructions.method`) plus an optional `e3d/skill.json` for everything structured. The frontmatter reader stays the engine's deliberately small subset. Hash identity is `definition_hash` (below); in every reference object, `hash` means `definition_hash`, and the existing folder hash is only ever called `legacy_folder_hash` (ADR-0001, ADR-0003).

### 5.1 `SkillDefinition` v1

The example is the committed fixture `tests/fixtures/skills/valid/skill-definition--behavioral-intelligence.json`, so it is known to validate.

```json
{
  "schema_version": "e3d.skill/v1",
  "id": "skill.user_01hxyz.behavioral-intelligence",
  "version": "1.0.0",
  "name": "Behavioral Intelligence",
  "description": "Evaluates interaction and workflow patterns using cited observations.",
  "owner_ref": "user_01hxyz",
  "visibility": "private",
  "status": "draft",
  "capability_level": "learning",
  "license": "CC-BY-4.0",
  "tags": [
    "behavior",
    "evaluation",
    "workflow"
  ],
  "tasks": [
    "chat-review",
    "debate-observer",
    "outcome-evaluation"
  ],
  "hooks": [
    {
      "scope": "debate_observer",
      "event": "after_synthesis"
    },
    {
      "scope": "evaluation",
      "event": "after_outcome"
    }
  ],
  "instructions": {
    "method": "Separate observation, hypothesis, and verified outcome. Cite event ids.",
    "constraints": [
      "Do not infer protected or sensitive traits.",
      "Do not describe a pattern as stable without minimum evidence."
    ]
  },
  "input_schema_ref": "e3d://schemas/behavior-input/v1",
  "output_schema_ref": "e3d://schemas/behavior-report/v1",
  "requested_capabilities": [
    {
      "capability": "brain.read",
      "purpose": "Retrieve permissioned prior outcome summaries.",
      "resource_classes": [
        "outcome_summary",
        "user_correction"
      ]
    },
    {
      "capability": "evaluation.emit",
      "purpose": "Record a scoped hypothesis or evaluation."
    }
  ],
  "memory_policy": {
    "read": "explicit",
    "write": "propose_only",
    "max_items": 20,
    "allowed_scopes": [
      "current_user",
      "current_project"
    ]
  },
  "limits": {
    "max_input_bytes": 64000,
    "max_output_bytes": 16000,
    "max_model_calls": 1,
    "max_tool_calls": 3,
    "timeout_ms": 60000
  },
  "fallback": {
    "on_unavailable_capability": "skip_with_notice",
    "on_invalid_output": "return_unstructured_with_warning"
  },
  "tests": {
    "suite_refs": [
      "fixture://behavioral-intelligence/v1"
    ]
  },
  "provenance": {
    "parent": null,
    "forked_from": null,
    "source_format": "e3d-native",
    "created_by": "user_01hxyz",
    "created_at": "2026-11-22T00:00:00Z"
  },
  "definition_hash": "sha256:7a1ff32c2dad1137f78307521c5aa72ffcb4598f0c862a8346cc9a62761699fb",
  "signature": null
}
```

Rules:

- `id` is stable across versions; `version + definition_hash` identifies executable meaning. Id grammar: `skill.<owner>.<name>`, owner `e3d` for built-ins; the name is the slug (ADR-0014).
- **Hashed:** `schema_version`, `id`, `version`, `name`, `description`, `capability_level`, `tasks`, `hooks`, `instructions`, schema refs, `requested_capabilities`, `memory_policy`, `limits` (including `max_words`), `fallback`, `model_hints`.
- **Not hashed (enumerated):** `definition_hash`, `signature`, `tags`, `license`, `owner_ref`, `visibility`, `status`, `tests`, `provenance`, `extensions`. Because `status` and `visibility` are not hashed, they are checked live at execution (`skill_withdrawn`). `tags` are display-only and never used for routing.
- The hash preimage is `"e3d.skill-hash/v1"`, a NUL byte, then RFC 8785 JSON of the hashed fields, restricted to strings, safe integers, booleans, null, arrays and objects (a float in a hashed field is refused). Text is NFC; bidi controls, zero-width characters and non-NFC input are refused. `tests/fixtures/skills/reference.mjs` is the reference implementation.
- Unknown executable fields fail closed (`skill_schema_unknown_field`); unknown metadata may live in `extensions` as string values only, and nothing that affects a run may go there.
- Instructions have a hard byte ceiling before storage and again before prompt assembly. Files are read once, and the bytes hashed are the bytes used.
- Public definitions cannot contain secrets, raw private transcripts, credentials, local paths, or private evidence bodies. Public licences must be on the SPDX allow-list the owner approves (ADR-0010).
- `scripts`, `install`, `network` and `mcp_servers` are refused in v1 (`skill_scripts_not_allowed`); `signature` must be null.
- An instructional skill may not request any capability (`skill_capability_denied`).

### 5.2 `SkillComposition` v1

```json
{
 "schema_version": "e3d.skill-composition/v1",
 "id": "composition.user_01hxyz.architecture-review",
 "version": "1.0.0",
 "nodes": [
 {"node_id":"systems","skill":{"id":"skill.e3d.systems-thinking","version":"1.0.0","hash":"sha256:..."}},
 {"node_id":"security","skill":{"id":"skill.e3d.security-review","version":"1.0.0","hash":"sha256:..."}},
 {"node_id":"premortem","skill":{"id":"skill.e3d.premortem","version":"1.0.0","hash":"sha256:..."}},
 {"node_id":"synthesis","skill":{"id":"skill.e3d.decision-synthesis","version":"1.0.0","hash":"sha256:..."}}
 ],
 "edges": [
 {"from":"systems.output","to":"synthesis.systems"},
 {"from":"security.output","to":"synthesis.security"},
 {"from":"premortem.output","to":"synthesis.premortem"}
 ],
 "execution": {"mode":"parallel_then_reduce","failure_policy":"continue_optional","max_parallel":3},
 "limits": {"max_nodes":8,"max_depth":4,"max_total_model_calls":8,"max_total_tool_calls":12}
}
```

Rules:

- DAG only; self-reference and transitive cycles fail validation.
- Node IDs are unique and edges must satisfy JSON Schema compatibility.
- A composition cannot grant capabilities absent from its children or policy; its effective request is the union of child requests. Phase 4 adds the flag `E3D_SKILLS_COMPOSE`; until then composition exists only as a schema and fixtures.
- Conflicting required output writers, incompatible hooks, ambiguous merges, or worst-case budget above policy fail preview.
- For v1, conditional branching is limited to deterministic predicates over structured prior outputs. No model-written code or expressions.
- Published compositions pin child versions. A new child release does not mutate a published composition; an author may create an updated composition version.

### 5.3 `SkillAttachment` v1

```json
{
 "schema_version": "e3d.skill-attachment/v1",
 "attachment_id": "att_01...",
 "target": {"type":"debate_seat","debate_id":"dbt_01...","seat":"seat_2"},
 "hook": "seat_prompt",
 "skill_ref": {"id":"skill.user_01hxyz.skeptic","version":"2.1.0","hash":"sha256:..."},
 "parameters": {"risk_focus":"authorization"},
 "priority": 100,
 "enabled": true
}
```

At most one lens-style skill may own a seat prompt in the first release. Other seat skills must be composed explicitly so ordering is inspectable.

### 5.4 `SkillRecommendation` v1

```json
{
 "schema_version": "e3d.skill-recommendation/v1",
 "recommendation_id": "rec_01...",
 "skill": {"id":"skill.e3d.metacognition","version":"1.0.0","hash":"sha256:..."},
 "strategy": {
 "mode": "debate",
 "panel_size": 3,
 "expert_skills": ["skill.e3d.architect@1.0.0","skill.e3d.security-review@1.0.0","skill.e3d.skeptic@1.0.0"],
 "observer_skills": ["skill.e3d.behavioral-intelligence@1.0.0"],
 "tool_requests": [],
 "stop_conditions": ["consensus_full","budget_exhausted"]
 },
 "reason_codes": ["HIGH_IMPACT","SECURITY_SENSITIVE","CONTESTABLE"],
 "explanation": "Independent security and architecture review is warranted.",
 "confidence": 0.84,
 "uncertainties": ["Repository scope not yet inspected"],
 "estimated_budget": {"credits_max": 40,"latency_ms_p95": 120000}
}
```

Pilot validates and may accept, modify, or reject the recommendation. The receipt stores both recommendation and final decision with reason codes.

### 5.5 `ExecutionPlan` and permission grant

```json
{
 "schema_version": "e3d.skill-plan/v1",
 "plan_id": "spl_01...",
 "principal": {"user_id":"user_01...","tenant_id":"tenant_01..."},
 "request_digest": "sha256:...",
 "steps": [{
 "step_id":"step_1",
 "skill":{"id":"skill.e3d.behavioral-intelligence","version":"1.0.0","hash":"sha256:..."},
 "hook":"after_synthesis",
 "grants":[{"capability":"brain.read","scope":"project:abc","resource_classes":["outcome_summary"],"expires_at":"..."}],
 "limits":{"model_calls":1,"tool_calls":3,"credits_max":5,"timeout_ms":60000}
 }],
 "quote":{"quote_id":"q_01...","credits_max":5,"expires_at":"..."},
 "approval":{"required":true,"approved_at":null},
 "expires_at":"..."
}
```

Plan tokens bind the request digest, skill hashes, identity, audience, grants, quote, and expiry. Any change requires a new plan/quote.

### 5.6 Run, observation, evaluation, and learning contracts

```json
{
 "schema_version":"e3d.skill-run/v1",
 "run_id":"skr_01...",
 "parent_run_id":"dbt_01...",
 "skill":{"id":"skill.e3d.behavioral-intelligence","version":"1.0.0","hash":"sha256:..."},
 "scope":"debate_observer",
 "hook":"after_synthesis",
 "status":"completed",
 "input_refs":[{"type":"debate_receipt","id":"dbt_01...","digest":"sha256:..."}],
 "output_ref":{"type":"artifact","id":"art_01...","digest":"sha256:..."},
 "grants_used":["grant_01..."],
 "provider":{"family":"anthropic","model":"pinned-model-version"},
 "metrics":{"latency_ms":1800,"credits":2,"model_calls":1,"tool_calls":1},
 "errors":[],
 "created_at":"..."
}
```

```json
{
 "schema_version":"e3d.observation/v1",
 "observation_id":"obs_01...",
 "subject":{"type":"workflow","id":"debate-review"},
 "claim":{"type":"redundancy_hypothesis","statement":"Two seats repeated the same unsupported claim."},
 "status":"hypothesis",
 "evidence_refs":["claim_17","claim_23"],
 "scope":"project:abc",
 "sensitivity":"private",
 "valid_from":"...",
 "expires_at":"...",
 "sample_size":1,
 "confidence":0.42,
 "created_by_run":"skr_01..."
}
```

`EvaluationRecord` must include: subject version/hash; task and fixture version; rubric and grader provenance; baseline run IDs; verified positives, false positives, abstentions and missing evidence; cost/latency; sample size and uncertainty; data-split designation; correction links; and visibility. `quality_status` is `unknown` unless ground truth or an approved rubric supports a conclusion.

`LearningProposal` must include: proposed diff, supporting evaluation IDs, counterevidence, affected task classes, expected benefit, rollback, author (human or job), and approval state. Applying it creates a normal immutable skill or router-policy version through existing review gates.

## 6. Resolution, composition, and routing semantics

### 6.1 Resolution order

For local execution, preserve current expert precedence unless Phase 1 proves otherwise:

1. built-in catalogue;
2. user-local catalogue;
3. repository/project catalogue.

A later layer may override a slug only for that local principal/project. Receipts record the selected source and hash. Hosted execution resolves only versions visible to the authenticated principal/tenant and must not consult server-operator home directories.

### 6.2 Explicit beats automatic

Priority order:

1. user-pinned skill version and attachment;
2. tenant/project policy-required skill;
3. user-selected recipe/composition;
4. Pilot router recommendation accepted by policy;
5. default existing behavior.

Automatic routing never replaces an explicit attachment. Policy may deny an attachment and must return a reason.

### 6.3 Lightweight metacognitive routing

Pilot retains a deterministic pre-router to avoid recursion. It uses request type, explicit user choices, risk flags, available capabilities, and configured cost limits to choose among existing paths or decide whether to call the metacognition skill. The showcase metacognition skill is invoked only for ambiguous/high-impact cases or explicit requests.

### 6.4 Prompt assembly

Prompt blocks are delimited and ordered:

1. non-overridable system/safety/policy instructions;
2. Pilot task contract and known date/context;
3. resolved skill instructions, each labeled with id/version/hash/scope;
4. untrusted retrieved/tool content, separately delimited;
5. user request and bounded conversation/debate context;
6. output schema and limits.

A skill cannot alter blocks 1–2, hide its identity, request secrets, or convert retrieved instructions into policy.

The existing expert path keeps its prompt block (`lensBlock`) byte for byte, because the no-expert and expert goldens pin it; for that path the id, version and hash labels are carried in the receipt, not in the prompt. The label rule applies to skills run through the new path. A lens that contains the end-of-role marker line closes its own block today (threat T3); Phase 2 rejects or neutralises marker lines at validation and again at prompt assembly, with a fixture.

### 6.5 Failure behavior

- Resolution/hash mismatch: fail before spend.
- Missing optional capability: use declared fallback and show notice.
- Missing required capability: fail preview/plan.
- Invalid structured output: retry at most once only if budget permits; otherwise declared fallback.
- Observer failure: debate result remains valid; receipt shows observer failure.
- Seat-skill failure before call: do not silently run an unlensed seat unless user/recipe explicitly permits fallback.
- Composition node failure: honor explicit `fail_fast`, `continue_optional`, or `fallback_node`; no implicit policy.
- Brain unavailable: continue only when memory is optional; never substitute cross-scope data.

## 7. APIs and MCP contracts

Names below are **proposals for the hosted phase**, not commitments. Settled (ADR-0005): no new MCP tool or REST route is added before Phase 7. Phase 2 adds CLI verbs only, behind `E3D_SKILLS_V1=1` (`--list-skills`, `--show-skill`, `--validate-skill`, `--project-expert`, `--export-skill`, `--diff-skill`). `e3d_list_experts` and `e3d_get_expert` keep their names and output shape; Phase 7 adds `e3d_list_skills` and `e3d_get_skill` as supersets and keeps the old pair as aliases. Hosted public routes live under `/api/...`; the `/agent/v1/...` routes are the internal engine-to-billing loopback and are not used for skills. Paths written `/v1/...` below are illustrative and are mapped to hosted names in Phase 7.

### 7.1 Read APIs

| Operation | Purpose |
|---|---|
| `GET /v1/skills` / `e3d_list_skills` | List visible metadata with filters for task, scope, capability level, owner, certification, and visibility. |
| `GET /v1/skills/{id}/versions/{version}` / `e3d_get_skill` | Fetch definition metadata, exact instructions where authorized, hash, tests, permissions, provenance, and evaluation summary. |
| `POST /v1/skills/validate` / `e3d_validate_skill` | Pure validation; no storage, network, model, or spend. |
| `POST /v1/skill-plans/preview` / `e3d_preview_skills` | Resolve attachments/composition, show grants, order, prompts summary, worst-case spend, conflicts, and required approval. |
| `GET /v1/skill-runs/{run_id}` / `e3d_skill_run` | Read authorized receipt/artifacts with redaction. |

### 7.2 Private lifecycle writes

| Operation | Safety contract |
|---|---|
| `POST /v1/skills` / `e3d_create_skill` | Creates private draft only; idempotency required. |
| `POST /v1/skills/{id}/versions` / `e3d_create_skill_version` | New immutable version; never in-place executable edit. |
| `POST /v1/skills/{id}/tests:run` / `e3d_test_skill` | Quote before paid calls; fixture inputs isolated; results private by default. |
| `POST /v1/skills/{id}:deprecate` | Marks version/alias; preserves receipts and lineage. |
| `POST /v1/compositions` | Creates private composition after DAG/type/budget validation. |

### 7.3 Execution extensions

Existing chat/debate requests gain optional additive fields:

```json
{
 "skill_attachments": [{
 "scope":"chat",
 "hook":"before_response",
 "skill":{"id":"skill.user_01.metacognition","version":"1.0.0"}
 }],
 "skill_plan_token":"optional-token-from-preview"
}
```

Debate supports separate `seat_skills` and `observer_skills`. Existing `experts` remains accepted and maps through a compatibility adapter to `debate_seat/seat_prompt`. Do not rename or remove it in v1.

### 7.4 Publish/fork operations

| Operation | Required controls |
|---|---|
| `POST /v1/skills/{id}/publish-preview` | Exact content hash, audience, license, public fields, scanner findings, lineage, and irreversible disclosures. |
| `POST /v1/skills/{id}/publish` / `e3d_publish_skill` | Auth, idempotency, exact preview token, explicit confirmation/elicitation, moderation state. |
| `POST /v1/skills/{id}/fork` / `e3d_fork_skill` | Creates private draft with exact parent version/hash and license attribution. |
| `POST /v1/skills/{id}/reactions` | Community signal only; rate limited; never changes evaluation score. |
| `POST /v1/skills/{id}/reports` | Abuse/security/license report with moderation audit trail. |

MCP hosts may draft or preview publication. They may publish only through an unspoofable human confirmation supported by the host or an out-of-band web/CLI action. A phrase visible to the model is not sufficient authorization.

### 7.5 Error envelope

```json
{
 "error": {
 "code":"skill_capability_denied",
 "message":"The skill requested brain.read outside the approved project scope.",
 "retryable":false,
 "details":{"skill_id":"...","capability":"brain.read","requested_scope":"user:*"},
 "next_action":"Remove the request or ask the user to approve an eligible scope."
 }
}
```

Stable codes are lower-case snake case with the prefix `skill_` and live in `docs/skills/schemas/v1/error-codes.json` (schema, hash, version, cycle, type, conflict, capability, audience, quote, approval, budget, timeout, provider, tool, memory, output, moderation, tenant, withdrawn). They match the codes the engine and hosted service already return (`invalid_experts`, `quote_mismatch`); a code is never renamed or reused. The error object carries `retryable` and a next step, as today. Upper-case names in earlier drafts map one to one and are accepted in prose only.

## 8. UI/UX specification

### 8.1 Skill Library

Tabs: **Mine**, **Team**, **E3D built-ins**, **Saved**, **Marketplace** (when enabled). Each card shows name, owner, current visible version, capability level, compatible scopes, requested permissions, evaluation status/sample size, community signals, license, and update status.

Filters: chat/debate seat/observer/router/evaluation; task; instructional/tool/learning; permission class; public/private; verified/experimental/unknown; free/paid; compatible with current mode.

### 8.2 Skill detail

Display exact version and hash, description, full instructions (unless a legitimate private authoring boundary applies), hooks, input/output schemas, requested capabilities, memory policy, limits, tests, evaluation evidence and uncertainty, changelog, provenance/fork graph, license, moderation state, known risks, and compatible Pilot versions.

Never label a skill “best,” “accurate,” or “verified” without the definition and sample basis of that label.

### 8.3 Create/edit flow

1. Describe desired capability conversationally or start from template.
2. Pilot creates a **private draft**.
3. Structured editor separates method, constraints, inputs, outputs, hooks, tools, memory, limits, and tests.
4. Validation shows errors and effective capability ceiling.
5. Preview shows exact prompt blocks, requested grants, data that may leave scope, and worst-case cost.
6. Test against fixtures/baseline.
7. Activate privately or create a publish preview.

Natural-language authoring is assistive. The user approves the structured definition; generated text never becomes public automatically.

### 8.4 Chat composer

Add a **Skills** control with selected chips. Selecting a skill shows scope, version policy, permissions, and estimated cost. Incompatible choices are disabled with reasons. “Recommended” suggestions remain advisory and explain why. The sent message records exact versions.

### 8.5 Debate builder

Three visually distinct zones:

- **Seats:** one expert skill per model seat; show provider assignment only after Pilot resolves it.
- **Observers:** debate-wide skills; show hook and whether they can affect later rounds (v1: no).
- **Council recipe/composition:** optional reusable assembly.

Preview shows family independence, plain seats, skill-to-seat mapping, observer schedule, cost, rounds, web/tool access, and fallback behavior. Results show original seat positions, synthesis, dissent, then observer reports—never merge observer judgments invisibly into the verdict.

### 8.6 Run inspector

Timeline: resolution → policy → approval → each skill/model/tool/memory step → synthesis → observer → evaluation. Each event exposes version/hash, input/output refs, grants used, cost/latency, redactions, errors, and fallback. Provide export as a portable redacted receipt.

### 8.7 Behavioral intelligence controls

Users can view, correct, expire, export, or delete eligible personal behavioral observations. UI distinguishes event, hypothesis, interpretation, and verified outcome. Sensitive-trait inference is prohibited, not merely hidden. Team/org views require a separate aggregation and privacy design; no employee leaderboard in v1.

## 9. E3D Brain integration

### 9.1 Separation of records

- Pilot ledger: authoritative record of requests, plans, grants, executions, costs, approvals, outputs, corrections, and outcome links.
- Brain: user-owned/contextual memory and cited summaries used as advisory inputs.
- Evaluation store: append-only evidence and rubrics; may project selected summaries into Brain.

Do not store raw credentials, hidden chain-of-thought, unnecessary transcripts, or unredacted private tool output in any layer.

### 9.2 Brain Gateway contract

**Where it lives.** E3D Brain today has one principal per process, a stdio transport, and no tenant, audience, purpose or resource-class fields; its README states there is no shared server. The gateway is therefore built in Pilot (ADR-0008): it holds the policy and the grant, calls the owner's local Brain read tools only in local owner scope, and tags what comes back. Content that came from Brain, or from a tool that saw private data, lowers the audience ceiling of everything derived from it (taint); a private-derived result cannot be published. Hosted use of Brain is out of scope until Brain gains a scoped, multi-principal interface in its own ADR. What Brain keeps as is: advisory status, proposals in an inbox, citations (note id and revision), secret scrubbing on write.

All gateway requests include principal, tenant, project, audience, purpose, resource classes, maximum items/bytes, time range, and a run-scoped grant. Responses include source IDs, source scopes, timestamps, knowledge status, citations/digests, and redaction markers.

The gateway enforces destination-aware retrieval: context visible to a private user response may not be reused in a team/public result unless separately authorized. Relevance never implies disclosure.

### 9.3 Memory writes

Learning skills emit proposals into an inbox. A deterministic policy may auto-record low-risk operational events already present in Pilot's ledger, but any interpretive memory about a person/model/workflow remains proposed until accepted or until an explicitly approved policy with clear expiry applies. Corrections append and link; they do not silently rewrite evidence.

### 9.4 Model and workflow profiles

Profiles are derived read models, segmented by task class, model/version, evidence/tool availability, workflow, and time window. They show sample size, uncertainty, last updated, counterevidence, and source evaluations. They are invalidated or decayed when models/workflows change. No global “intelligence” score.

## 10. Showcase skill specifications

### 10.1 Metacognition

**Purpose:** recommend an approach before expensive execution and evaluate the choice after an outcome.

Inputs: user goal; explicit mode/model choices; task/risk classification; available providers/tools; cost/latency policy; bounded prior outcome summaries if authorized.

Outputs: `SkillRecommendation`; reason codes; uncertainty; alternatives; stop/escalation conditions; estimated budget.

Constraints:

- recommend-only;
- deterministic Pilot pre-router decides whether invocation is warranted;
- explicit user mode wins unless policy forbids it;
- never recommend itself recursively;
- record Pilot's final route and why it differed;
- later evaluation distinguishes model failure from strategy-selection failure.

Initial fixtures: trivial lookup (direct), bounded implementation (single model + deterministic tests), high-risk architecture (independent review/debate), missing evidence (ask/research), deterministic validation task (no LLM), and budget-constrained task (cheapest eligible path).

### 10.2 Behavioral Intelligence

**Purpose:** identify evidence-backed interaction, model, council, and workflow patterns and propose improvements.

Inputs: structured events and evaluations; cited user corrections; model/version; task class; costs; verified outcomes; explicit scope.

Outputs: observations labeled event/hypothesis/interpretation/verified; evidence refs; counterevidence; confidence; sample size; expiry; recommended experiment—not a personality judgment.

Prohibited:

- protected/sensitive trait inference;
- mental-health, trustworthiness, loyalty, or employment judgments;
- team ranking or surveillance metrics;
- interpreting acceptance, likes, or consensus as correctness;
- durable claim from one interaction;
- cross-principal aggregation without a separately approved design.

Initial reports:

1. duplicate/redundant debate findings;
2. unique verified contribution by seat/skill/model version;
3. repeated user correction category with opt-in personalization proposal;
4. workflow rework/cost/latency pattern;
5. metacognitive decision postmortem.

## 11. Permissions and security model

### 11.1 Capability vocabulary v1

Start narrow:

- `context.read.current_request`
- `conversation.read.current`
- `debate.read.current`
- `brain.read`
- `brain.propose`
- `evaluation.read`
- `evaluation.emit`
- `web.search` (existing Pilot policy, if supported)
- `artifact.read.explicit`

Do not include arbitrary filesystem, shell, network, credential, repository write, email/message, publication, billing, or account-management capabilities in skill v1; they are not representable (`skill_capability_unknown`).

Matrix by level (details in `docs/skills/phase1/threat-model.md`): an **instructional** skill may request none of these (only `context.read.current_request` is implicit). `web.search` is a request that Pilot grants only if it already allows search for that run; the skill never gains search by naming it (the existing factchecker lens says "if this debate gives you web search, use it", which is the right shape). `brain.read` is local owner scope only. `brain.propose` and `evaluation.emit` are learning-level only. Phase availability: `conversation.read.current` and `debate.read.current` Phase 3; all others Phase 5.

### 11.2 Policy evaluation

Effective grant = intersection of:

`skill request ∩ deployment capabilities ∩ principal role ∩ tenant policy ∩ resource ACL ∩ audience policy ∩ run approval ∩ budget`

Denials are explicit and auditable. Grants are short-lived, least-privilege, resource-scoped, non-transferable, and unusable outside the plan/run digest.

### 11.3 Threats and required mitigations

| Threat | Mitigation |
|---|---|
| Prompt injection in skill or retrieved data | Delimited trust zones; non-overridable policy; allow-listed broker; output validation; adversarial fixtures |
| Malicious package | No scripts/hooks/symlinks; size/count limits; inert import; canonical hash/signature; scan before public transition |
| Confused deputy | Run-scoped grants; audience binding; explicit resource IDs; deny delegation from content |
| SSRF/data exfiltration | No arbitrary URL tools in v1; controlled existing web-search path; egress policy and redaction |
| Cross-tenant leak | Tenant-scoped queries/keys; negative auth tests; cache partitioning; destination-aware Brain gateway |
| Cost amplification | Static worst-case expansion; quote; node/call/byte/time ceilings; concurrency limits; cancellation |
| Version substitution | Pin version/hash in plan and receipt; verify at execution; signed hosted artifacts later |
| Marketplace manipulation | Separate reactions/evaluations; rate limits; anti-sybil signals; moderation and appeals |
| Behavioral surveillance | Private default; minimum evidence/expiry; prohibited inferences; export/correct/delete; no employee ranking |
| Memory poisoning | Knowledge status/provenance; proposal workflow; corrections; bounded retrieval; source diversity |
| Delimiter spoofing (T3, present today) | Reject or neutralise end-of-role marker lines at validation and at prompt assembly; fixture |
| Hash-line stripping (T19, present today) | Strip `e3d.expert.hash:` only inside the frontmatter; built-in hashes unchanged; fixture |
| Hidden or confusable text (T20) | NFC required; bidi and zero-width characters refused; homoglyphs accepted as a residual risk and shown in preview |
| Check/use race (T21) | Read each file once; hash and use the same bytes |
| Withdrawn or renamed skill still runs (T23) | `status` checked live; `name` and `description` hashed; `tags` never used for routing |

The full register (T1-T23) is in `docs/skills/phase1/threat-model.md`.

### 11.4 Privacy and retention

Data classes: public definition, private definition, execution input, skill output, tool/memory evidence, observation, evaluation, billing/audit. Define retention and deletion behavior for each before hosted launch. Proposed numbers (observation 30 days default and 180 maximum with a required expiry; receipts and evaluation records tied to the skill version; audit at least 365 days; financial rows never deleted) are ADR-0011 and need the owner's approval. Account closing needs a new deletion step for skill collections. Deleting an account removes or anonymizes eligible data while preserving legally/financially required minimal audit records and public fork attribution policy. Public withdrawal prevents new use but cannot promise erasure of already forked/exported copies.

### 11.5 Supply-chain and signing

Local skills trust local filesystem policy and hash. Hosted public versions receive server-side immutable storage, canonical hash, malware/secret/license scan, and a service signature. Future third-party signatures are additive. Signature validity does not confer tool permission or quality.

## 12. Provenance and telemetry

### 12.1 Required event envelope

```json
{
 "schema_version":"e3d.event/v1",
 "event_id":"evt_01...",
 "event_type":"skill.step.completed",
 "occurred_at":"...",
 "principal_ref":"pseudonymous-or-private-id",
 "tenant_ref":"tenant_01...",
 "run_id":"skr_01...",
 "parent_run_id":"dbt_01...",
 "skill_ref":{"id":"...","version":"...","hash":"sha256:..."},
 "context":{"task_class":"security_review","risk":"high","audience":"private"},
 "metrics":{"latency_ms":1800,"credits":2,"input_tokens":1000,"output_tokens":400},
 "status":"completed",
 "payload_ref":"art_01...",
 "privacy":{"class":"private","retention_policy":"user-default"},
 "trace":{"trace_id":"...","span_id":"..."}
}
```

### 12.2 Events

Emit: definition created/versioned/validated/deprecated; composition resolved/rejected; attachment resolved; plan previewed/approved/expired; capability granted/denied/used; model/tool/memory step started/completed/failed; fallback used; output invalid; observation proposed/corrected/expired; evaluation created/corrected; learning proposal created/approved/rejected; publish previewed/confirmed/withdrawn; fork/reaction/report/moderation; router recommended/accepted/overridden; outcome linked.

### 12.3 Metrics

Operational: success/error by code, latency, queue, token/credit cost, tool calls, memory reads, output validity, fallback, cancellation, provider availability.

Product: private activation, repeated use, composition reuse, test-to-activation, publish/fork reuse, permission-denial abandonment, preview-to-run conversion.

Quality: verified unique findings, false positives, abstention, calibration, outcome success, rework, comparison to strongest same-tools single-model baseline, fixed recipe, and no-skill baseline.

Safety: auth denials, cross-tenant test results, secret/PII scan findings, prompt-injection fixture pass rate, moderation incidents, behavioral correction/deletion rate.

Events carry no free-text content fields (the schema rejects them; fixture `event--raw-prompt`). Do not send raw prompts, private skill bodies, memory content, or private artifacts to analytics by default. Use server-side aggregates with documented sampling and opt-out where applicable.

## 13. Evaluation framework and release gates

### 13.1 Evaluation layers

1. **Contract:** schema/type/output conformance.
2. **Safety:** capability and audience boundaries under attack.
3. **Task quality:** fixture-grounded correctness/coverage/false positives.
4. **Comparative lift:** skill vs same model/no skill; council recipe vs strongest comparable single model; auto route vs explicit baseline.
5. **Outcome:** downstream verified result, rework, regression, user correction.
6. **Usability:** time to create/test/reuse, comprehension of permissions/provenance.

### 13.2 Dataset rules

- Pre-register rubric, primary metric, threshold, cost ceiling, and exclusions.
- Separate development, validation, and holdout fixtures; record leakage risk.
- Pin skill/model/router/tool versions and evidence availability.
- Blind graders where feasible; capture inter-rater disagreement.
- Report sample size, confidence interval, missing data, and negative results.
- Never use private customer data as public benchmark content without explicit authorization.

### 13.3 Initial gates

- Instructional runtime: zero behavior change for no-skill compatibility suite; deterministic resolution/hash receipts; all malicious-manifest fixtures fail closed.
- Attachment/observer: original seat outputs/dissent preserved; observer failure cannot invalidate debate; scope auth tests pass.
- Tool/Brain: zero cross-tenant fixture leaks; no raw credential access; denied capability never reaches adapter.
- Showcase claims: the pre-registered study in `docs/skills/phase1/evaluation-freeze.md` (90 tasks in six categories, 36 held out, 24 of those with ground-truth issues; one primary test, H1: skill lenses on council seats versus the same council without them). Cost and false-claim share are reported; inconclusive is reported as inconclusive. With 24 holdout tasks the smallest lift detectable at 80% power is about 8.6 points; smaller real effects will read as inconclusive.
- Public marketplace: private-to-public negative tests, secret/PII/license scan, fork attribution, withdrawal, moderation/appeal, and abuse throttles pass.
- Learning/default routing: prospective shadow evaluation before any recommendation affects defaults; human override and instant rollback required.

Threshold values for quality lift and acceptable cost must be approved before any holdout result exists. They are **proposed, not frozen**: +5.0 points, cost ratio at most 1.25, token ceiling 9M. The freeze takes effect only when a named human approves it and the commit is marked with the signed tag `skills-eval-freeze-v1`; the grader pool, the salt and the analysis script are produced in Phase 6.

## 14. Migration and compatibility

### 14.1 Expert-to-skill compatibility

- Treat existing experts as `instructional` skills with `debate_seat/seat_prompt`, `requested_capabilities: []`, and a compatibility projection from `e3d/expert.json` (ADR-0002): integer version `"N"` becomes `N.0.0` (missing means `1.0.0`, marked inferred); `model_hints` and `max_words` become hashed fields; `limits.max_model_calls` is 0 (a lens adds no call of its own); nothing is truncated silently, and a folder that exceeds a schema limit is reported as not projectable and keeps working on the legacy path. `tests/skills-compat.sh` pins the ten built-ins (name, version, hash, lens bytes) and four presets, and the MCP tool names and input properties.
- Preserve existing expert IDs/names, hashes, CLI flags, built-in folders, presets, receipts, and MCP fields.
- Do not rewrite existing files in place during first release. Adapter generates `SkillDefinition` in memory and records `source_schema`.
- Add a dry-run migration/export command that prints projected skill definition and any lossy fields.
- Only after parity tests may maintainers offer an explicit conversion command that writes new files with backups and never deletes originals.

### 14.2 Database migrations

Hosted storage is MongoDB with no migration framework: indexes are created idempotently at start-up and data changes are one-off scripts that are dry-run by default and need `--apply --i-have-a-backup` (ADR-0009). The additive-first discipline stays; the vocabulary changes:

1. add **new collections** (registry, versions, compositions, attachments, runs, grants, evaluations, lineage) and declare their indexes in the existing index list; nothing existing is altered;
2. deploy dual-read compatibility for built-ins and existing hosted experts;
3. run the backfill script (built-in catalogue into the registry, hashes) dry-run first, in bounded batches, idempotent, resumable after partial failure;
4. verify counts, hashes, visibility, ownership and sample reads from the dry-run report;
5. enable dual-write only where necessary;
6. switch read paths behind a per-team flag (`tenant_id` is a nullable team id; there is no other tenant concept, and team features are themselves flag-gated and default off);
7. keep the rollback read path through the observation window;
8. remove legacy paths only in a separate approved release.

Every data change ships its dry-run output, a backup and restore test, the inverse script (or an explicit statement that the change is additive and reversible by ignoring the collection), lock and runtime estimate, idempotency proof, partial-failure recovery and an isolation check. No destructive change in the same release as cutover. Phase 7 cannot start until team and audience tests exist.

### 14.3 API compatibility

- Existing `experts`/`skills` fields continue to work as documented.
- New fields are optional; old clients ignore additive response fields.
- Store `schema_version`; reject unsupported major versions with actionable error.
- Existing quote/idempotency semantics remain mandatory when new skills add cost.
- Previously completed receipts remain readable and do not resolve mutable aliases retroactively.

## 15. Test plan

### 15.1 Unit tests

Canonicalization/hash stability; semantic version validation; local/hosted resolution; override precedence; schema validation; unknown fields; size/token ceilings; symlink/path traversal; DAG cycle/depth/node limits; schema compatibility; deterministic branch predicates; capability union; policy intersection; audience checks; plan digest/expiry; prompt block ordering; redaction; error codes; compatibility projections.

### 15.2 Integration tests

- Chat before/after skill with provider stub.
- Debate with plain seats, skilled seats, and observers.
- Existing expert CLI/MCP/web paths unchanged under flags.
- Composition parallel/reduce, optional failure, timeout, cancellation.
- Quote → approval → execute → replay/idempotency.
- Tool broker allow/deny and unavailable adapter.
- Brain retrieval with correct scope, forbidden scope, redaction, outage.
- Evaluation/correction/expiry and learning proposal review.
- Hosted create/version/deprecate/publish/fork/withdraw.
- Gallery links and reaction/evaluation separation.

### 15.3 Security tests

Prompt injection in every trust zone; skill claiming system authority; encoded secret request; malicious schema; huge/nested composition; hash substitution; alias race; replayed plan token; cross-tenant IDs; cache-key collision; SSRF attempts; path traversal/symlink; output smuggling; log injection; quota race; duplicate publish; unauthorized Brain scope; public result referencing private evidence; moderation bypass.

### 15.4 End-to-end acceptance scenarios

1. Create a private instructional chat skill, preview exact behavior, test, attach, run, inspect receipt, and reuse exact version.
2. Attach different skills to three debate seats; run with provider diversity; view positions/dissent and exact seat hashes.
3. Attach behavioral observer; observer fails; debate still completes and failure is visible.
4. Compose architecture review; parallel nodes produce typed outputs; synthesis cites them; cost stays under quote.
5. Tool-enabled skill requests Brain project summaries; user denies; run follows declared fallback with no adapter call.
6. Metacognition recommends a debate; Pilot downgrades due to budget; receipt records both decisions.
7. Behavioral skill proposes a hypothesis from one event with low confidence/expiry; it is not shown as a stable profile.
8. Publish preview catches a secret and blocks publication.
9. Publish a safe version; another user forks privately with lineage/license; parent later withdraws; existing fork remains attributed.
10. No-skill regression suite produces existing outputs/contracts within documented nondeterministic tolerances.

### 15.5 Performance/chaos

Load list/search/resolution; concurrent plan execution; provider timeout; Brain outage; tool outage; registry lag; database failover; queue saturation; cancellation; duplicate events; analytics outage. Verify bounded resource use and no double charge.

## 16. Detailed e3d-code implementation phases

Each phase is independently reviewable and must end in one or more PRs. Cross-repository phases use a separate PR per repository, merged in dependency order. At the beginning of every phase, rebase on current `main`, reread repository instructions, audit active overlapping PRs, and update the phase evidence note. Do not deploy automatically.

**Runner notes (verified against e3d-code `0.4.0`).**

- A phase starts at any heading (levels 1 to 6) that contains `Phase <number>`. **No other heading in this file may contain that pattern**; v0.1 had one (`1.2 ... Phase 1 must resolve`) and e3d-code refused the file with `duplicate phase number in spec: 1`. Keep prose references to phases in body text, not headings. Before using the runner, `bin/e3d-code <this file> --list` must show exactly the eight phases.
- The runner executes at most eight phases per run; this file has eight. Run one phase at a time and stop for approval between phases.
- The runner's default permission mode is `bypassPermissions` (unattended, no per-call guard). Run it only in a dedicated worktree on a dedicated branch, never in a shared checkout, and set a stricter `CLAUDE_PERMISSION_MODE` where the phase does not need to write outside the worktree.
- Phase 1 was carried out by following this workflow by hand (the runner could not parse v0.1).

## Phase 1 - Grounding, ADRs, schemas, threat model, and evaluation freeze

<!-- runner:model=high -->
<!-- runner:read=docs/skills/README.md -->
<!-- runner:read=docs/skills/phase1/grounding-report.md -->
<!-- runner:verify=bash tests/skills-schemas.sh -->
<!-- runner:verify=bash tests/skills-compat.sh -->

**Status: delivered as draft PR `spacepacket1/e3d-pilot#92`, awaiting human sign-off. Do not re-run this phase.** Deliverables are in `docs/skills/` (`README.md` is the index and holds the sign-off table), `tests/fixtures/skills/` and `tests/skills-{schemas,compat}.sh`. The Work list below is kept as the record of what was asked.

**Dependencies:** none.
**Primary repos:** `e3d-pilot`; read-only audit of `e3d-pilot-cloud`, `e3d-brain`, `e3d-code`.
**Runtime change:** none; docs/tests/fixtures only.

### Work

1. Inventory exact files/symbols/routes/flags/tests for expert loading, hosted skills, chat, debate, investigate, quote/billing, receipts, Gallery, auth/tenant policy, telemetry, and Brain integration.
2. Reconcile this spec with `docs/experts.md`, `docs/e3d-pilot-experts-feature-spec.md`, active PRs, and live tool contracts. Create a gap table: implemented, partial, flagged, proposed, contradicted.
3. Decide ADRs: canonical skill schema; compatibility mapping; hashing; immutable storage; API names; observer semantics; tool broker boundary; Brain gateway boundary; database/registry owner; public license policy; retention; alias/update rules; failure policies.
4. Commit JSON Schemas and example fixtures for SkillDefinition, Composition, Attachment, Recommendation, Plan, Grant, Run, Observation, Evaluation, LearningProposal, Error, and Event.
5. Write threat model/data-flow diagram and permission matrix.
6. Freeze evaluation rubric, baseline arms, task categories, holdout split, minimum sample, quality/cost thresholds, and claim language before results.
7. Write compatibility tests that capture current no-skill and current expert behavior using deterministic provider stubs.

### Deliverables

- ADR set and implementation map with cited files/symbols.
- Versioned schemas/fixtures and schema-validation test harness.
- Threat model, privacy data inventory, and evaluation plan.
- Phase 2–8 issue/PR map with repo ownership and flags.

### Acceptance criteria

- All observed/proposed features are labeled accurately.
- Schema examples validate; malicious/invalid examples fail with stable codes.
- Existing behavior fixtures pass on fresh main.
- Human reviewers approve unresolved ADRs and evaluation thresholds.

### Exit gate

No runtime implementation begins until architecture, security/privacy, and evaluation reviewers approve Phase 1. Record remaining dissent and open risks.

## Phase 2 - Local private instructional skills and expert compatibility

<!-- runner:model=high -->
<!-- runner:read=docs/skills/README.md -->
<!-- runner:read=docs/skills/phase1/adr/0001-schema.md -->
<!-- runner:read=docs/skills/phase1/adr/0002-compat-mapping.md -->
<!-- runner:read=docs/skills/phase1/adr/0003-hashing.md -->
<!-- runner:read=docs/skills/phase1/adr/0004-immutable-storage.md -->
<!-- runner:read=docs/skills/phase1/adr/0012-aliases.md -->
<!-- runner:read=docs/skills/phase1/adr/0014-identifiers-flags.md -->
<!-- runner:verify=bash tests/skills-schemas.sh -->
<!-- runner:verify=bash tests/skills-compat.sh -->
<!-- runner:verify=bash tests/debate-specialists.sh -->

**Dependencies:** Phase 1.
**Primary repo:** `e3d-pilot`.
**Flag:** `E3D_SKILLS_V1=0` by default.

### Work

1. Implement canonical parser/validator/hasher and inert folder format.
2. Add compatibility projection for existing expert folders and presets without changing current paths.
3. Implement local resolver with documented precedence, immutable version/hash pinning, alias resolution, byte/token limits, symlink/path defenses, and typed errors.
4. Add pure CLI operations: list/get/validate/project/export/import-inert/diff versions. No network/model/tool calls.
5. Add private local create/version/deprecate flow if repository conventions support safe writes; otherwise generate a reviewed folder in an explicit output path.
6. Extend receipts additively with resolved skill source/version/hash only when flag/skill path is used.
7. Add docs and migration dry-run from expert to skill.
8. **Fix first, with tests, before anything else in this phase:** (a) hash-line stripping: `hashed()` must remove `e3d.expert.hash:` only inside the frontmatter (finding F-2; built-in hashes must not change); (b) end-of-role marker lines in a lens (threat T3); (c) read each file once so the hashed bytes are the used bytes (T21); (d) NFC and bidi/zero-width refusal (T20); (e) the `docs/experts.md` contradiction about experts on `e3d_debate` and the stale "eight" in the catalogue test header.
9. CLI verbs only, as listed in section 7; no new MCP tool or route.

### Acceptance criteria

- No-skill and legacy expert compatibility suites are unchanged.
- Existing expert hashes/meaning are preserved or any unavoidable change is documented and human-approved.
- Malformed, oversized, symlinked, cyclic-reference, unknown-executable-field, and script-bearing definitions fail closed.
- Local operations make no network/model calls and spend nothing.
- A user can create, validate, version, attach through the compatibility seat path, export, and inspect a private instructional skill.

### Exit gate

Security review of parser/resolver; compatibility sign-off; flag remains off in release defaults until canary tests pass.

## Phase 3 - Unified chat, debate-seat, and debate-observer runtime

<!-- runner:model=high -->
<!-- runner:read=docs/skills/README.md -->
<!-- runner:read=docs/skills/phase1/threat-model.md -->
<!-- runner:read=docs/skills/phase1/adr/0005-api-names.md -->
<!-- runner:read=docs/skills/phase1/adr/0006-observer.md -->
<!-- runner:read=docs/skills/phase1/adr/0007-tool-broker.md -->
<!-- runner:read=docs/skills/phase1/adr/0013-failure.md -->
<!-- runner:verify=bash tests/skills-schemas.sh -->
<!-- runner:verify=bash tests/skills-compat.sh -->
<!-- runner:verify=bash tests/debate-specialists.sh -->

**Dependencies:** Phase 2.
**Primary repos:** `e3d-pilot`, then `e3d-pilot-cloud` adapter only if required.
**Flags:** scope-specific, default off.

### Work

1. Introduce internal Attachment and ExecutionPlan interfaces shared by chat/debate paths without replacing existing public APIs.
2. Implement `chat/before_response`, `chat/after_response`, `debate_seat/seat_prompt`, and `debate_observer/after_synthesis`. Chat attachment extends the existing flagged `chat_skills_v1`; do not rebuild it. `after_round` is not approved (ADR-0006) and is out of scope.
3. Implement prompt trust zones, input/output schema validation, explicit ordering, per-step limits, cancellation, fallback, and receipts. The observer runs after the verdict is stored and is read-only; a test proves positions, synthesis, dissent, quote and charge are identical with and without an observer.
4. Add preview API/CLI showing exact versions, prompt summaries, conflicts, observer schedule, provider-family independence, and worst-case calls/cost.
5. Map legacy `experts` to seat attachments. Keep old request/result contracts.
6. Update web chat/debate builder and run inspector behind flags.

### Acceptance criteria

- All four end-to-end attachment scenarios pass with provider stubs and at least one allowed live canary.
- Observer output cannot overwrite seat positions, synthesis, or dissent.
- Observer failure does not fail the debate; seat-skill failure follows explicit fallback.
- Plan digest invalidates on request, version, hash, audience, policy, or price change.
- UI/API receipts agree on active skills and order.
- No-skill latency/cost path shows no material regression at agreed tolerance.

### Exit gate

Human UX review and independent security review; enable only for internal/private canary tenants.

## Phase 4 - Skill composition and deterministic planning

<!-- runner:model=high -->
<!-- runner:read=docs/skills/README.md -->
<!-- runner:read=docs/skills/phase1/adr/0001-schema.md -->
<!-- runner:read=docs/skills/phase1/adr/0013-failure.md -->
<!-- runner:verify=bash tests/skills-schemas.sh -->
<!-- runner:verify=bash tests/skills-compat.sh -->
<!-- runner:verify=bash tests/debate-specialists.sh -->

**Dependencies:** Phase 3.
**Primary repo:** `e3d-pilot`; hosted persistence may add a separate cloud PR.
**Flag:** `E3D_SKILLS_COMPOSE`, off by default.

### Work

1. Implement Composition schema, DAG validation, type compatibility, deterministic parallel/reduce ordering, bounded predicates, node/depth/call/tool/byte ceilings, and effective capability/budget calculation.
2. Implement explicit failure policies and per-node receipts/artifacts.
3. Add private composition lifecycle, preview visualization, version pinning, export/import, and compatibility with curated expert presets.
4. Add reusable built-in examples: spec review, architecture review, risk review—clearly experimental until evaluated.
5. Add composition-aware quote, idempotency, cancellation, and resume semantics.

### Acceptance criteria

- Cycles, ambiguous merges, incompatible schemas, excess expansion, and capability conflicts fail before spend.
- Parallel execution is deterministic in receipts; retries do not double charge or duplicate durable events.
- Child version updates do not mutate a pinned composition.
- Composition failure/timeout/cancellation fixtures preserve completed step evidence and allow safe retry.
- Preset compatibility remains intact.

### Exit gate

Performance/cost review and chaos test pass; keep public sharing disabled.

## Phase 5 - Tool broker, Brain gateway, and learning-safe event foundation

<!-- runner:model=high -->
<!-- runner:read=docs/skills/README.md -->
<!-- runner:read=docs/skills/phase1/threat-model.md -->
<!-- runner:read=docs/skills/phase1/adr/0007-tool-broker.md -->
<!-- runner:read=docs/skills/phase1/adr/0008-brain-gateway.md -->
<!-- runner:read=docs/skills/phase1/adr/0009-registry-owner.md -->
<!-- runner:read=docs/skills/phase1/adr/0011-retention.md -->
<!-- runner:verify=bash tests/skills-schemas.sh -->
<!-- runner:verify=bash tests/skills-compat.sh -->
<!-- runner:verify=bash tests/debate-specialists.sh -->

**Dependencies:** Phases 3–4.
**Primary repos:** `e3d-pilot`; `e3d-brain` only if an ADR requires it; cloud policy adapter if hosted.
**Flags:** each capability adapter separately off.

### Work

1. Implement v1 capability vocabulary, policy intersection, run-scoped grants, adapter interface, denial/error model, and audit events.
2. Expose only approved read/propose adapters; no arbitrary filesystem/shell/network/repo-write/scripts.
3. Implement the Brain gateway **in Pilot** (ADR-0008) with principal/tenant/project/audience/purpose/resource-class bounds, citations, knowledge status, redaction, taint tracking and destination-aware retrieval; local owner scope only. `e3d-brain` changes only if a later ADR adds a scoped interface to Brain itself.
4. Implement observation/evaluation/learning-proposal stores or append-only events according to Phase 1 ownership ADR; interpretive writes go to review inbox.
5. Add user controls for memory opt-in, view/correct/expire/export/delete where applicable.
6. Add secret/PII redaction and retention enforcement at tool/memory/log boundaries.

### Acceptance criteria

- Denied grants never invoke adapters; grants cannot be replayed outside bound plan/run.
- Cross-tenant, cross-project, and private-to-public leak suites pass with zero leakage.
- Brain outage and stale/corrupt evidence follow explicit fallback.
- Every returned memory item has source, scope, status, timestamp, and citation/digest.
- Interpretive observations cannot become accepted memory or router policy without review.
- Full audit shows requested/granted/used capabilities without exposing credentials/content.

### Exit gate

Dedicated security/privacy review, backup/restore test, and internal red-team. No external tool-enabled or learning skill launch until signed off.

## Phase 6 - Metacognition, behavioral intelligence, and evaluation harness

<!-- runner:model=high -->
<!-- runner:read=docs/skills/README.md -->
<!-- runner:read=docs/skills/phase1/evaluation-freeze.md -->
<!-- runner:verify=bash tests/skills-schemas.sh -->
<!-- runner:verify=bash tests/skills-compat.sh -->
<!-- runner:verify=bash tests/debate-specialists.sh -->

**Dependencies:** Phase 5.
**Primary repos:** `e3d-pilot`; optional Brain fixtures.
**Rollout:** shadow/recommend-only.

### Work

1. Package showcase skills as built-ins using canonical schema, tests, version/hash, explicit limits, and prohibited-use policies.
2. Implement deterministic pre-router and metacognition recommendation contract; record recommendation vs final Pilot decision and outcome.
3. Implement behavioral observer/evaluator producing scoped observations with evidence, counterevidence, sample size, confidence, expiry, and proposed experiments.
4. Build evaluation harness with pinned baselines, blind rubric support, holdout split, cost/latency/false-positive/abstention measurement, and reproducible report generation.
5. Run shadow study across approved representative tasks. Do not optimize on holdout.
6. Publish internal report including negative/inconclusive results and go/no-go recommendation.

### Acceptance criteria

- Metacognition never directly invokes execution and cannot recurse.
- Explicit user choices and policy decisions are preserved and explain overrides.
- Behavioral outputs reject prohibited sensitive/personality/employee-ranking requests.
- Single-event patterns remain hypotheses with low sample size/expiry.
- Evaluation compares same tools/evidence and strongest reasonable baselines.
- Minimum sample/thresholds from Phase 1 are met before claims; otherwise features remain experimental/shadow.

### Exit gate

Human review of study and privacy impacts. Default-routing influence requires a separate explicit approval and instant rollback flag.

## Phase 7 - Hosted user lifecycle, immutable registry, migrations, and private team use

<!-- runner:model=high -->
<!-- runner:read=docs/skills/README.md -->
<!-- runner:read=docs/skills/phase1/adr/0004-immutable-storage.md -->
<!-- runner:read=docs/skills/phase1/adr/0005-api-names.md -->
<!-- runner:read=docs/skills/phase1/adr/0009-registry-owner.md -->
<!-- runner:read=docs/skills/phase1/adr/0011-retention.md -->
<!-- runner:read=docs/skills/phase1/adr/0012-aliases.md -->
<!-- runner:verify=bash tests/skills-schemas.sh -->
<!-- runner:verify=bash tests/skills-compat.sh -->
<!-- runner:verify=bash tests/debate-specialists.sh -->

**Dependencies:** Phases 2–6 and successful internal canary.
**Primary repo:** `e3d-pilot-cloud`, then thin engine/API adapters.
**Rollout:** private drafts first; team scope after auth tests.

### Work

1. Add the registry/version/composition/attachment/run/evaluation/lineage collections and indexes with a dry-run backfill, verification, rollback and legacy dual-read, following section 14.2 (MongoDB; `tenant_id` is a nullable team id). Add `e3d_list_skills` and `e3d_get_skill` as supersets of the expert tools and settle the hosted route names with the cloud owner.
2. Implement authenticated create/version/test/deprecate, alias/update policies, quotas, idempotency, and per-tenant isolation.
3. Implement hosted preview/quote/approval and UI Library/detail/editor/chat/debate/run-inspector surfaces.
4. Reuse existing identity, tenant, billing, moderation primitives and Gallery data patterns; do not create duplicate account/reaction ledgers.
5. Add team-private sharing only after audience/Brain destination tests; include audit/export/deletion.
6. Canary by tenant; monitor migration, auth, cost, and error telemetry; document rollback.

### Acceptance criteria

- Migration/backfill is idempotent and reconciles counts/hashes/visibility/owners.
- Old hosted built-in skill/debate flows remain compatible.
- Private drafts are invisible to anonymous/other-tenant requests, search, caches, logs, and analytics.
- Quote/idempotency prevents double spend; quotas race safely.
- Account/team lifecycle, export, deletion, and retention behave as documented.
- Canary meets agreed error/latency/cost/security thresholds through observation window.

### Exit gate

Production-readiness review and explicit deployment approval. Public publishing remains off.

## Phase 8 - Publishing, forking, Gallery/marketplace discovery, and governed learning

<!-- runner:model=high -->
<!-- runner:read=docs/skills/README.md -->
<!-- runner:read=docs/skills/phase1/adr/0010-license.md -->
<!-- runner:read=docs/skills/phase1/adr/0011-retention.md -->
<!-- runner:verify=bash tests/skills-schemas.sh -->
<!-- runner:verify=bash tests/skills-compat.sh -->
<!-- runner:verify=bash tests/debate-specialists.sh -->

**Dependencies:** Phase 7; Phase 6 evaluation and Phase 5 security gates.
**Primary repo:** `e3d-pilot-cloud`; engine adapters as separate PR.
**Rollout:** curated experimental public catalogue; economics/payouts excluded.

### Work

1. Implement exact-hash publish preview/confirmation, audience/license choice, secret/PII/license scan, moderation state, withdrawal, reports, appeals, and immutable public versions.
2. Implement private fork with exact lineage/attribution/license, version comparisons, and update notifications without auto-upgrade.
3. Extend Gallery/search/categories/profile pages to skills/compositions and link consenting debate runs to exact versions.
4. Reuse reactions/saves with anti-abuse controls; display them separately from evaluation evidence.
5. Implement ranking that defaults to relevance/safety/compatibility and exposes performance only with task-matched sample/uncertainty. Popularity must not influence security permission or “verified” status.
6. Enable learning proposals for authors/router maintainers: evidence-linked diff, counterevidence, review, test, canary, rollback. No silent self-update.
7. Run curated creator/user pilot; measure reuse, fork success, moderation load, safety events, and verified task value.
8. Produce a separate go/no-go ADR for paid marketplace, payouts, cross-user aggregate learning, and broader public submission.

### Acceptance criteria

- Public transition cannot occur without exact unspoofable human consent.
- Scanner/moderation/auth negative tests pass; public artifact contains no private evidence references.
- Fork attribution and license survive export/versioning; withdrawal semantics are clear.
- Votes cannot alter evaluation records, permissions, or verified badges.
- Learning proposal application creates a reviewed immutable version and supports rollback.
- Public pages disclose experimental/unknown quality and sample sizes accurately.
- No payouts or paid creator economics ship in this phase.

### Exit gate

Security, privacy, moderation, legal/license, product, and evaluation reviews approve continued public operation. Otherwise return catalogue to curated/private mode without breaking existing pinned runs.

## 17. PR, review, and deployment protocol

For every phase:

1. Open an issue linking this spec and the fresh-state audit.
2. Create a dedicated branch/worktree; one repository per PR.
3. Include scope, exclusions, contracts changed, migration, tests, telemetry, flags, rollback, and screenshots/receipts where relevant.
4. Run repository-native tests plus the phase acceptance suite; the local run is the gate (do not wait on hosted CI). Distinguish pre-existing failures, and fix a pre-existing failure that guards the behaviour you must preserve in its own commit (Phase 1 did this for the stale prompt goldens).
5. Request independent review from implementation, architecture, security/privacy, and product/UX as appropriate.
6. Resolve blocking findings; record accepted residual risks and dissent.
7. Merge only after human approval. Deployment is a separate authorized action.
8. Canary behind flags, compare telemetry to baseline, and roll back on documented thresholds.
9. Update status matrix and this spec's implementation notes; do not rewrite historical claims.

No phase may combine schema migration, public enablement, and destructive legacy removal into one irreversible release.

Repository rules that apply to every phase: follow each repository's own instructions file; use a dedicated worktree and branch (never a shared checkout); the public engine repository must contain no hostnames, keys, internal pricing or partner terms, so hosted detail goes in the private repository or a private appendix; never print or commit credentials; no production flag is enabled, nothing is deployed or published, and billing is not changed without explicit approval; stop after each phase with the hand-off summary.

## 18. Definition of done

The feature is complete only when:

- private users can safely create/version/test/reuse skills across chat, seat, observer, and composition scopes;
- tool and Brain access is explicit, least-privilege, auditable, and tenant-safe;
- metacognition and behavioral intelligence work as bounded showcase skills with honest evaluation;
- hosted lifecycle, provenance, permissions, migrations, rollback, telemetry, and user controls are operational;
- public publishing/forking/lineage/moderation accurately distinguish popularity from evidence;
- legacy expert and no-skill flows remain supported;
- learning produces reviewed proposals rather than silent mutations;
- all release gates have evidence, approvals, and rollback procedures.

## Appendix A - Key design decisions to preserve

1. Skills generalize experts; they do not replace working expert interfaces abruptly.
2. A seat skill influences one participant; an observer evaluates the whole process and is displayed separately.
3. Metacognition recommends; Pilot decides and executes.
4. Behavioral intelligence reasons from structured, cited events and verified outcomes—not vibes or acceptance.
5. Brain remembers with provenance; Pilot's ledger remains authoritative for actions.
6. Composition is a bounded typed DAG, not an arbitrary workflow language.
7. Community content never grants tools.
8. Evaluation precedes default routing and marketing claims.
9. Public versions are immutable and forkable; mutable aliases never change historical runs.
10. Marketplace economics and cross-user learning require later, separate decisions.

## Appendix B - Initial implementation status template

Maintain this table in the repository after Phase 1:

| Capability | Status (2026-11-23) | Flag | Code owner | Evidence | Last verified |
|---|---|---|---|---|---|
| Built-in instructional experts | implemented | `E3D_SPECIALISTS` | e3d-pilot | `tests/skills-compat.sh`, `tests/specialists-loader.sh` | 2026-11-22 |
| User-local instructional skills | proposed; folder loading implemented for experts | `E3D_SKILLS_V1` (Phase 2) | e3d-pilot | schemas and 45 invalid fixtures (Phase 1) | 2026-11-22 |
| Chat attachment | partial, flagged (`chat_skills_v1`, built-in lenses only) | scope flag | e3d-pilot/cloud | audit | 2026-11-22 |
| Debate seat attachment | implemented via `experts` | `E3D_SPECIALISTS` | e3d-pilot/cloud | `tests/debate-specialists.sh` | 2026-11-22 |
| Debate observer | proposed (`after_synthesis` only) | observer flag | e3d-pilot/cloud | ADR-0006 | 2026-11-22 |
| Composition | proposed (schema and fixtures only) | `E3D_SKILLS_COMPOSE` | e3d-pilot | fixtures | 2026-11-22 |
| Tool broker | proposed | per adapter | e3d-pilot | ADR-0007 | 2026-11-22 |
| Brain gateway | proposed, built in Pilot; Brain has no scoping | per adapter | e3d-pilot | ADR-0008 | 2026-11-22 |
| Evaluation / learning proposals | proposed; design pre-registered but not frozen | eval flag | e3d-pilot/cloud | `evaluation-freeze.md` | 2026-11-22 |
| Hosted user lifecycle | proposed (MongoDB collections, team id as tenant) | tenant canary | cloud | ADR-0009 | 2026-11-22 |
| Public catalogue/forking | proposed | public flag | cloud | ADR-0010 | 2026-11-22 |

The live copy of this table is `docs/skills/README.md` in the repository; update that one.

## Appendix C - Source references used for this proposal

- Referenced ChatGPT conversation: “Adding Behavioral Intelligence in Pilot,” including the recommendation to model metacognition and behavioral intelligence as composable skills.
- `spacepacket1/e3d-pilot`: `README.md`, `docs/experts.md`, `docs/e3d-pilot-experts-feature-spec.md`, current package metadata and connected tool catalogue.
- `spacepacket1/e3d-code`: `README.md`, current package metadata and phase runner behavior.
- `spacepacket1/e3d-brain`: repository overview and Drive proposal “Extend e3d-brain for Intellectual Continuity and Federated Knowledge.”
- Google Drive: “E3D Pilot Developer Workflows — v0.1 Review Brief,” “E3D Context Intelligence — Vision,” and companion product/technical specification.

All repository/deployment references are a snapshot and must be revalidated at implementation time.

Added in v0.2: `docs/skills/phase1/grounding-report.md`, ADRs 0001-0014, `docs/skills/phase1/threat-model.md`, `docs/skills/phase1/evaluation-freeze.md`, `docs/skills/phase1/review-record.md`, and the code at the audited commits listed in section 1.1.

## Appendix D - Where each v0.1 section was corrected

| Section | Corrected by |
|---|---|
| 1 | grounding report, sections 1 to 5 |
| 3.3, 7.3 | ADR-0006, ADR-0005 |
| 5, 5.1 | ADR-0001, ADR-0002, ADR-0003, ADR-0014 |
| 6.4 | threat T3, ADR-0002 |
| 7, 7.5 | ADR-0005, ADR-0014 |
| 9 | ADR-0008 |
| 11 | ADR-0007, threat model |
| 11.4 | ADR-0011 (owner input) |
| 13 | `evaluation-freeze.md` |
| 14.1, 14.2 | ADR-0002, ADR-0009 |
| 16 | runner notes in section 16 |
