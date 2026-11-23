# Skills Phase 1: grounding report

Status: **draft for review**, 2026-11-22. Scope of Phase 1: documents, schemas, fixtures and tests only. No runtime behaviour changes.

This report reconciles the "E3D Pilot User-Defined Skills" implementation specification (v0.1, 2026-11-22) with what the four repositories
actually contain on fresh `main`. The spec says its own repository claims must be revalidated; this is that revalidation.
Detailed hosted-service file and route references are kept in a private appendix, because this repository is public and the hosted
repository is private.

## 1. What was inspected

| Repository | Visibility | Commit audited | Instructions found | Open PRs touching this area |
| --- | --- | --- | --- | --- |
| `e3d-pilot` (engine, this repo) | public | `511cce9` (main, 2026-11-21) | `CLAUDE.md` | none touch experts, skills, MCP or specialists (#3, #13, #14, #15 are ledger mirror and docs) |
| `e3d-pilot-cloud` (hosted) | private | `54b4740` (main, 2026-11-22) | `CLAUDE.md` (spec first, flag off, version bump per release, per-area tests) | none touch skills, experts, billing or Gallery code. #332 (Ask-page threads marker) edits `site/app/views/ask.js`, next to the Skills composer: watch for conflicts in Phase 3 |
| `e3d-brain` | public | `fc9effa` (main, 2026-11-19) | README only (no CLAUDE.md or AGENTS.md) | none |
| `e3d-code` | public | `40222a5` (main, 2026-10-18) | README, usage text | #5 (leading-zero phase arguments): not relevant to this spec |

Method: a read-only checkout of each `main` (no changes to anyone's working tree), `rg`/`jq` over the code, the existing expert tests run on
a fresh worktree, and the spec compared line by line with `docs/experts.md`, `docs/specs/experts-*`, the code and the tests.
Two Sonnet read-only subagents produced the hosted-service and the Brain/e3d-code inventories; every claim used below was either
checked in the engine directly or is labelled "from the audit".

## 2. Baseline of the engine on fresh main

| Suite | Result |
| --- | --- |
| `specialists-loader`, `specialists-catalogue`, `debate-seats`, `experts-assignment`, `experts-suggest`, `mcp-experts-read`, `mcp-experts-run`, `mcp-experts-agent`, `case-mode` | pass |
| `debate-specialists` | **failed on main before this branch**: `FAIL: v2: seen-synth differs from the golden prompt` |

Cause: PR #91 (`## Each model` per-model summaries) added a block to the synthesis prompt but did not regenerate
`tests/fixtures/specialists/golden/*/seen-synth.md`. This is the no-expert byte-for-byte baseline the skills work must preserve, so it had
to be right first. Commit `bc68f1b` regenerates the three goldens with `make-golden.sh` from current main; the diff is 12 added lines
(the #91 block, three prompt versions) and nothing else. After it, `debate-specialists` passes. This is the only change to an existing file.

## 3. Gap table

Labels: **implemented** (exists and tested), **partial**, **flagged** (exists, off by default), **proposed** (only in the spec), **contradicted** (the spec states something the code does not do).

| Spec capability | Status | Evidence |
| --- | --- | --- |
| Experts are standard skill folders: `SKILL.md` + optional `e3d/expert.json` | implemented | `lib/debate/specialists.mjs` `validateFolder` (:220), `readSidecar` (:184); `lib/specialists/*/` |
| Built-in, user, repo tiers, later wins by name | implemented | `loadExperts` (:313); `bin/e3d-debate` :239-241 (`lib/specialists`, `~/.config/e3d-pilot/specialists`, `<repo>/.e3d-pilot/specialists`) |
| Ten built-in experts, four presets | implemented in the engine | `tests/fixtures/skills/expert-baseline.json`; `lib/specialists/panels.json`. The hosted browser suggest list has one preset (`risk-review`) (audit) |
| Folder-safety rules: symlinks, oversize, malformed sidecar, no `scripts/` run, `allowed-tools` ignored, unknown frontmatter field fails | implemented | `walk` (:133), `validateFolder`, `LIMITS` (:17); `tests/specialists-loader.sh` |
| Tools are `none` | implemented | `readSidecar` (:197); `docs/experts.md` "Safety" |
| Content hash, immutable identity | partial | `hashFolder` (:169) hashes the file tree (`path\0size\0sha256`), not a canonical JSON. Hosted pins `{id, hash}` and refuses a mismatch (`--expert-pin`; `run-server.js` `EXPERT_FIELDS` :46) |
| Semantic versions | **contradicted** | Existing version is an integer string in `metadata."e3d.expert.version"` (`"1"`, `"2"` for factchecker). The spec's `1.0.0` form has no source today |
| Aliases (`latest`, channels) | proposed | none in engine or hosted |
| Debate seat attachment | implemented (as `experts`) | `assign` (`lib/debate/specialists-plan.mjs`:31), one lens per seat, `MAX_SEATS = 6` (:21), seat ids `claude`, `claude.2`, `lensBlock` (:16), receipt `panel` block (`bin/e3d-debate` :1474) |
| Chat attachment | **partial, flagged** (spec says proposed/Phase 3) | `chat_skills_v1`: 1 to 3 built-in lenses on one model's answers (`lib/mcp/chat-runner.js` :26-29, :118-145; `lib/mcp/agent-chat.js` :40). Needs the hosted run listener |
| `experts` through the `e3d_debate` MCP tool | flagged (docs contradict themselves) | `E3D_MCP_EXPERTS_AGENT=1` (`lib/mcp/agent.js` :183-206, `bin/e3d-mcp` :86, :340-346). `docs/experts.md` says both "not built" (Over MCP) and that the flag exists (Hosted runs) |
| MCP listing of experts | flagged | `e3d_list_experts`, `e3d_get_expert`, `E3D_MCP_EXPERTS=1` (`lib/mcp/experts-read.js`), off by default; verified by `tests/skills-compat.sh` |
| Quote, idempotency, price includes lens bytes | implemented for experts | `e3d_quote` and `e3d_debate` take the same `experts`; `lens_bytes`; `quote_mismatch` (hosted, from audit) |
| Debate observer (`after_round`, `after_synthesis`) | proposed | none. The synthesis prompt never receives a lens by design (`docs/experts.md` "What a seat receives") |
| Composition (typed DAG) | proposed | none. Closest: `panels.json` presets, a flat list of names |
| Tool broker, grants, plans, `ExecutionPlan` | proposed | none. Plan preview is explicitly "not built" (`--show-panel`) |
| Skill run receipts pinning version and hash | partial | local `decision-log.json` `panel` block carries name, version, hash, tier (no schema file, no run id of its own). Hosted stores `experts: [{id, hash}]` on the debate row |
| Observations, evaluation records, learning proposals | proposed | none. `experiments/fve` and `docs/methodology/expert-councils.md` are an experiment and a draft, not a store |
| Router/recommendation (metacognition) | proposed; two deterministic precedents | `--suggest-panel` (`lib/specialists/suggest.mjs`, rule-based, confidence never above medium) and hosted Investigate auto-adding `agent-diagnosis` and `skeptic` (audit) |
| Brain gateway with principal, tenant, project, audience, purpose, resource class | **contradicted** | Brain has one principal per process, stdio MCP, no tenant/audience/purpose/resource-class fields, read-side redaction absent; README: "no shared server and no cross-brain data flow". Engine side is one optional shell recall (`lib/ideas/brain_recall.sh`) |
| Hosted user-defined skills, registry, lifecycle | proposed (hosted docs say "not built") | audit |
| Publish, fork, reactions, reports, moderation | exists for debates, proposed for skills | Gallery tables, reports, appeals, fork counts are per debate (audit) |
| Skill telemetry events | proposed | hosted usage events are per ledger transition; none per skill |
| Stable error envelope | partial | engine and hosted already return lowercase codes with `retryable` and a next step (`lib/mcp/agent.js` :73-130). The spec's codes are upper case |

## 4. Contradictions and corrections to the spec

1. **Authoring format.** Spec 5.1 shows nested YAML with inline lists. The engine's frontmatter reader is a deliberate small YAML subset that
   refuses `[`, `{` and nesting (`specialists.mjs` `scalar`, :63; `parseFrontmatter`). Decision: JSON for everything structured (ADR-0001).
2. **Identifiers.** Spec ids look like `skill.user_01hxyz.slug`; existing names must match `^[a-z0-9]+(-[a-z0-9]+)*$` and equal the folder name (`NAME_RE`, :23; `name_folder_mismatch`). Decision: keep the slug as the name, derive the id (ADR-0014).
3. **Hash.** Spec: RFC 8785 JSON hash. Engine and hosted: file-tree hash that hosted pins and receipts already name, and the MCP expert listing already calls it `content_hash`. Decision: keep both, never replace, and name the new one `definition_hash` (ADR-0003).
4. **Version.** Integer strings today, semver in the spec. Decision: projection maps `"N"` to `N.0.0` (ADR-0002).
5. **Migrations.** Spec 14.2 assumes tables with forward and backward commands. The hosted service uses MongoDB with idempotent index creation at startup (`ensureIndexes`) and no migrations directory; one-off data changes are dry-run-first scripts needing `--apply --i-have-a-backup` (audit). Decision: ADR-0009 restates the migration rules for that reality.
6. **Tenants.** The spec's `tenant_id` has no hosted equivalent. There are user accounts and flag-gated teams (default off); OAuth has a single scope, `debates:run` (audit). Decision: `tenant_id` is nullable and means a team id (ADR-0009).
7. **API names.** Spec uses `/v1/skills/...`. The hosted public API is under `/api/...`; the `/agent/v1/...` routes are the engine-to-billing loopback, not public. There is no OpenAPI file; the MCP tool registry is in this repo, and the hosted recorded tool list fixture is stale (three tools) (audit). Decision: ADR-0005.
8. **Flag names.** Spec: `E3D_SKILLS_V1`. Existing: `E3D_SPECIALISTS`, `E3D_SPECIALISTS_BUILTIN_ONLY`, `E3D_MCP_EXPERTS`, `E3D_MCP_EXPERTS_RUN`, `E3D_MCP_EXPERTS_AGENT`, `E3D_MCP_CHAT_TOOL`; hosted per-feature flags (audit). Every flag validates strictly: unset, `0` or `1`, anything else refuses to start. Decision: `E3D_SKILLS_V1` is added, never replaces them (ADR-0014).
9. **Chat attachment** is partly built (see gap table); Phase 3 extends it, it does not start it.
10. **`docs/experts.md` contradicts itself** on `e3d_debate` experts, and the catalogue test header says "eight". Fix in the Phase 2 docs commit; recorded in the status matrix.
11. **`allowed-tools` and web search.** `factchecker` v2 says "if this debate gives you web search, use it". The expert has `tools: none`; web search is a debate-level Pilot setting, not something the skill is granted. This is the right shape for `web.search`: a capability the policy grants, never the lens. The spec's `web.search` capability must stay a request, and v1 instructional skills may not carry it (ADR-0007).
12. **Hash line stripping (finding F-2).** `hashed()` (`specialists.mjs`:162-167) deletes any `e3d.expert.hash:` line from the whole SKILL.md, lens body included, so two lenses that differ by such a line share a folder hash (reproduced with a scratch folder). A hash pin can therefore be bypassed by a lens edit. Not changed in Phase 1; Phase 2 restricts the stripping to the frontmatter (ADR-0003). Built-ins contain no such line, so no existing hash changes.
13. **Delimiter handling (finding).** `lensBlock` wraps the lens between `[Your role in this debate]` and `[End of role. ...]` but does not escape or reject a lens that contains the end-marker line itself (`specialists-plan.mjs` :16-19; `validateFolder` has no such rule). A user-authored lens can therefore close its own block early. Today the impact is limited to that one seat's prompt (the lens never reaches other seats or the synthesis, test "specialists 7"), but spec 6.4 trust zones depend on the delimiter. Phase 2 must reject or neutralise marker lines; fixture and test to be added then (threat T3).
14. **e3d-code cannot run this spec as pasted.** `bin/e3d-code spec.md --list` stops with `duplicate phase number in spec: 1`: the heading "1.2 Unknowns that Phase 1 must resolve" matches the runner's `Phase <digits>` heading rule (levels 1 to 6) and so counts as a second Phase 1. Also any later heading containing "phase N" would split a phase body, the runner defaults to `CLAUDE_PERMISSION_MODE=bypassPermissions` (unattended, no per-call guard), and `MAX_PHASES_PER_RUN` defaults to 8 (the spec has exactly 8). Phase 1 was therefore run by following the same phase workflow by hand (read-first files, scoped work, handoff summary, independent checks), not by invoking the runner. If the runner is to be used for later phases, rename that heading in a working copy first.
15. **Brain is not a gateway.** Spec 9 needs per-request scoping Brain does not have. It does have what the spec says it must keep: advisory status, proposals in an inbox, citations (note id and revision), secret scrubbing on writes. Decision: ADR-0008.

Things the spec said that **checked out**: resolution order built-in < user < repo (`loadExperts` tiers); hosted never reads operator home directories (`--builtin-only`); symlink, oversize and malformed-sidecar refusal; `scripts/` never run; no network or model call to load, show, validate or export an expert; expert tools `none`; ten experts and four presets in the engine; "user-hosted skills, marketplace, effectiveness claims not built or not proven"; the seat lens never reaches the synthesis.

## 5. Questions the spec left to Phase 1 (section 1.2), answered

| Question | Answer |
| --- | --- |
| Database, migrations, service boundaries | Hosted: MongoDB replica set, no migration framework (index creation at start-up, dry-run data scripts). Engine: files only (`decision-log.json`, state dir). Boundary: engine runs debates behind a loopback listener; billing/quote/idempotency is hosted |
| Shared code path for web debate, MCP debate, investigate, chat, CLI | One engine: `bin/e3d-debate` runs every debate; `lib/mcp/run-server.js` (hosted web), `bin/e3d-mcp` + `lib/mcp/agent.js` (MCP debate/quote), `lib/mcp/case.js` (Investigate), `lib/mcp/chat-runner.js` + `agent-chat.js` (chat). Experts reach it as `--specialist`/`--expert-pin` flags built by the listener |
| Canonical expert fields; schema drift | Canonical: engine `SKILL.md` frontmatter + `e3d/expert.json` (`SIDECAR_KEYS`). Hosted copies the built-in catalogue (id, label, tags, hash, lens bytes) generated from the engine folders; its suggest table is a byte copy pinned by sha256 in its tests. No drift found; one doc drift (item 10) |
| Brain MCP contracts; safe per-principal adapter | Six read tools plus `capture` (inbox mode) and journal tools; stdio only; no safe per-principal advisory adapter today (finding 14) |
| Telemetry retention, deletion, consent, billing, moderation, Gallery lineage | Hosted: transcript retention 90 days, decision records 365 days (configurable), account deletion cascades through debates, publications, chats, teams, keys and sessions; financial rows are never deleted; Gallery reports, appeals, forks exist for debates. A future skills collection needs its own deletion step (ADR-0011) |
| Active PRs changing expert/skill behaviour | none in any of the four repos |

## 6. Required decisions

All fourteen are written as ADRs in `adr/` with status **Proposed**. They need a human decision before Phase 2 starts; see `../README.md` for the sign-off table.
Items needing the owner's judgement rather than engineering ones: ADR-0010 (public license policy), ADR-0011 (retention numbers), and the evaluation thresholds in `evaluation-freeze.md`.

## 7. Phase 2 to 8 issue and PR map

| Phase | Repo (one PR per repo) | Flag | Contracts it may change | Depends on ADRs |
| --- | --- | --- | --- | --- |
| 2 Local instructional skills + expert compatibility | e3d-pilot | `E3D_SKILLS_V1=0` | receipt gains `skills` block only when used; new CLI verbs; fixes lens-marker finding | 0001 to 0004, 0012, 0014 |
| 3 Chat, seat, observer runtime | e3d-pilot, then e3d-pilot-cloud adapter | per scope, off | request gains optional `skill_attachments`; result gains observer block | 0005 to 0007, 0013 |
| 4 Composition | e3d-pilot; optional cloud persistence PR | `E3D_SKILLS_COMPOSE` (new) | composition schema live | 0001, 0013 |
| 5 Tool broker, Brain gateway, event store | e3d-pilot, e3d-brain, cloud policy adapter | one per adapter | grants, events | 0007, 0008, 0009, 0011 |
| 6 Showcase skills + evaluation harness | e3d-pilot | shadow only | none public | evaluation freeze |
| 7 Hosted lifecycle + registry | e3d-pilot-cloud, then thin engine adapter | tenant canary | new collections, routes | 0004, 0005, 0009, 0011, 0012 |
| 8 Publish, fork, discovery, governed learning | e3d-pilot-cloud, engine adapter | public flag | Gallery extended | 0010, 0011 |

Each phase also needs its own issue and PR template per spec section 17; those are created when that phase is approved, not now.

## 8. What Phase 1 changes in the repository

New: `docs/skills/**`, `tests/fixtures/skills/**`, `tests/skills-schemas.{sh,mjs}`, `tests/skills-compat.sh`. Changed: the three no-expert golden prompts (commit `bc68f1b`).
No file under `bin/` or `lib/` is touched; nothing imports the new test support. Rollback is deleting the PR's files and reverting `bc68f1b`.
