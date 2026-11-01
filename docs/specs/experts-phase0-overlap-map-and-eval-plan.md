# Experts and Auto Councils, Phase 0: overlap map and evaluation plan

**Status:** draft 1, 2026-11-01. Docs only: no runtime change, no flag, no deploy, and **no model was called** to write this (no debates, no credits).
**Parent:** [`experts-auto-councils-marketplace-developer-talent.md`](experts-auto-councils-marketplace-developer-talent.md) (merged in #50), section 4 "Phase 0".
**Evidence tags:** **[E]** read in a file today (path given). **[G]** guess, not tested. **[N]** not verified.

Phase 0 asks three things before any code: what already exists, what each proposed feature should reuse or change, and how we will know the council helps. This page answers them and lists the decisions the owner has to make.

## 1. What already exists, and what it means for Phase 1 and 2

| Proposed in #50 | What exists today | Consequence |
| --- | --- | --- |
| A seat in a council | A seat is only a **provider adapter**. `bin/e3d-debate --providers a,b` and `lib/mcp/voices.js` (`chooseVoices`, `CLI_ORDER`) pick adapters; every participant gets the **same prompt** [E] | An "expert" adds what a seat lacks: a lens, instructions, tools and a version. It is a wrapper around a seat, not a new kind of participant |
| Expert definitions (12 lenses, YAML, presets, precedence) | Already designed in detail in `docs/prompt-review-2026-10.md` Part 3: starter roster of 12, file format, load order (built-in < user < repo), presets `risk-review` and others, `--panel` / `--specialist` flags [E]. Nothing is built | Phase 1 is mostly **implementing that design**, not inventing one. Do not write a second schema without reconciling it (section 2, D2) |
| Which vendors may take part | **Per-account panel** (cloud `docs/panel-config-spec.md`; engine `lib/mcp/panel.js`): an allowlist, the account's chosen vendors, degrade-or-refuse, "never add a vendor the account did not choose" [E] | Experts and Auto Council must work **inside** the account's panel. An expert may narrow a vendor choice, never widen it (D4) |
| Dissent attributed to an expert | Today `dissent` is `{present, summary}` and `positions` is per provider [E: prompt-review 3.5] | Receipts need `specialist_id`, `specialist_version`, provider, model and final action per seat. Additive fields only |
| Decision log and computed agreement | `lib/debate/agreement/` (#20) [E] | The base for `SeatContribution` and for the measurement in Phase 3 |
| Gallery, reactions, handles, forks, challenges, publisher-paid score | Cloud (private repo) [E: earlier sessions]; the public read tool `e3d_gallery` is in the engine since #49 | Public experts and recipes reuse these in Phase 4. The new MCP tool names should follow `e3d_*` and must not collide with `e3d_gallery` |
| `expert_ids`, `council_id`, `panel:"auto"` on `e3d_debate` | Hosted calls go through **billing's agent quote and begin routes**. Those routes do not accept `challenge_of` today, and the same gap would block any new `e3d_debate` parameter [E: gallery work, 2026-10-31] | **Phase 2 over hosted MCP needs a billing-side change** (the open "A or B" decision). Phase 1 (CLI and local engine) does not |
| Price of a panel | The panel spec has its own pricing section (docs/panel-config-spec.md section 5) [E, headings only] | More or different seats change the quote. Phase 2 must define how an expert panel is priced before it can spend |

## 2. Decisions to approve (my recommendation first)

- **D1. Expert, seat and panel.** A *seat* is a provider adapter (as today). An *expert* is a versioned lens plus instructions, tools and model preferences. A *panel* is a list of seats; a *council recipe* is a panel whose seats name experts. Recommendation: adopt these four words exactly and use them in code and docs.
- **D2. One schema.** `expert/v1` in #50 is a superset of the October file format. Keep the October fields (`models`, `tools`, `limits`, `tasks`) and add `owner_id`, `visibility`, `required_evidence`, `tests`, `license`, `provenance`, `content_hash`. **Drop `performance` from the definition**: measured results live only in the append-only `EvaluationRecord`, never hand-edited. *(Amended 2026-11-01: the definition is a standard skill folder plus a JSON sidecar; see D6 and the Phase 1 spec.)*
- **D3. Where experts live.** Phase 1: files, in the engine (`lib/specialists/<name>/SKILL.md`, user and repo overrides as the October design says). No cloud registry before Phase 4.
- **D4. The vendor invariant.** An expert's `models` list is resolved against the account's panel: unavailable or not-allowed vendors are dropped in order, and if none is left the run **refuses** (never substitutes), as `lib/mcp/panel.js` already does for panels. Recorded in the receipt.
- **D5. MCP pass-through.** Settle A or B before Phase 2. A: experts are CLI and local-engine only, and hosted assistants hand the user a link. B: extend billing's agent routes once, for `challenge_of` and the expert parameters together. Recommendation: B, but only when Phase 2 starts, so the change is made once.
- **D6. Agent Skills interop.** **Amended 2026-11-01 (owner): the standard `SKILL.md` format is the native format.** An expert is a standard skill folder plus an optional `e3d/expert.json` sidecar for what the standard has no place for; there is no separate export conversion ("export" is a validated copy). **Inspect-only import** (parse, validate, preview, never run) in Phase 1, **import-and-run no earlier than Phase 2** and only after the injection fixtures pass. Imports pass a **license gate**. Detail below.
- **D7. Where skills are published.** Not into Anthropic's repository. **First-party skills** (our lenses, already standard skill folders) go to a **separate public repository**, not a folder in the engine repo. **User-published experts stay in the Pilot registry** (Cloud, Phase 4), which is the authoritative copy. A **read-only, opt-in, curated GitHub mirror** may be generated from it later for standard-tool installs. Detail below.

### D6 detail: Agent Skills and `expert/v1`

*Amended 2026-11-01: the standard format is now native. Read the right-hand column below as "where this field lives in the skill folder" (the folder's `SKILL.md`, or the `e3d/expert.json` sidecar), and "export" as a validated copy. The Phase 1 spec (`experts-phase1-private-experts-spec.md`) is the working definition; this table is the original reasoning.*

Why now: Anthropic donated the Agent Skills standard to the Agentic AI Foundation on 2026-10-22 (reported by several outlets; I did not read the primary announcement). The format spec is at `https://agentskills.io/specification` **[E: read 2026-11-01, no version or date shown on the page]**. A skill is a directory with a required `SKILL.md` (YAML frontmatter plus Markdown) and optional `scripts/`, `references/`, `assets/`.

| `SKILL.md` | Rule in the spec | `expert/v1` mapping |
| --- | --- | --- |
| `name` (required) | 1-64 characters, lowercase letters, digits and hyphens, no leading, trailing or double hyphen, **must equal the directory name** | Our `id` is `expert.<namespace>.<slug>` (has dots), so export the **slug** only and put the namespace in `metadata`. Reject an import whose name breaks the rule |
| `description` (required) | 1-1024 characters; what it does and when to use it | Our `description` plus the task contracts. Truncate on export and say so |
| `license` | name or bundled file | `license` |
| `compatibility` | 1-500 characters, environment needs | Optional: required evidence and tools in words |
| `metadata` | string keys to **string** values | `e3d.expert.version`, `e3d.expert.hash`, `e3d.expert.lens`, `e3d.expert.schema`, tags joined as a string. Lists must be flattened |
| `allowed-tools` (experimental) | space-separated tools **pre-approved** to run | **Never exported by default; ignored on import** (kept only as a *claim* in `requested_capabilities`). Our rule stays: a manifest is not an authorization token |
| Body | no format limit; under 500 lines and about 5,000 tokens recommended | Our method, avoid and lens text, within those sizes |
| `scripts/` | executable code | None on export. On import: stored as inert text, flagged "contains scripts", **never executed**, excluded from the run by default |
| `references/`, `assets/` | on-demand docs and files | Text only, size-capped, as untrusted data. Binary assets rejected at first |

What is **not** in the folder: moderation status and, above all, the **measured record** (`EvaluationRecord`), which lives in the registry. That is the point of the product: the standard carries the instructions, we carry whether they work. On import into Pilot the `e3d.*` keys and the sidecar are treated as **claims** and checked against the content hash, never trusted; a folder from elsewhere has neither and still imports as plain instructions.

The spec has **no** versioning, trust or security section **[E]**, so those stay ours: pinned content hash, an explicit user action to fetch (no fetch on install), a preview before any run, imported text placed in a delimited untrusted block and **never in the judge or synthesizer role**, and the prompt-injection fixtures #50 already requires.

A wrapper expert (an existing skill plus our lens, tools, tests and record) records `provenance.skill_source` as repository, path and content hash, so the wrapped skill is pinned the same way as any other input.

**License gate (import and wrap).** On import, read the skill's `license` field and any `LICENSE.txt`, show both in the preview, and record them with the content hash. Allow publishing a wrapper only for a recognised open license (for example Apache 2.0 or MIT) with its notice and attribution kept and our changes marked. Treat a missing license, "Proprietary", "source-available", or any terms we cannot classify as **not publishable** and not redistributable; the user may still run it privately if the terms allow. Example from `github.com/anthropics/skills` **[E: read 2026-11-01]**: the repo has no repository-wide license; skills such as `mcp-builder`, `skill-creator` and `claude-api` carry Apache 2.0, while `docx`, `pdf`, `pptx` and `xlsx` are marked "Proprietary" with additional restrictions. A human reads the actual license text before anything copied from a third-party skill ships; this page is not legal advice.

Tests: a conformance check that every exported skill passes `skills-ref validate` (the reference validator named in the spec) or, if it cannot be used, our own check of the rules in the table, plus a test that an imported `allowed-tools` grants nothing. The spec can change (it now sits under a foundation), so we record the date we read it (2026-11-01) and fail loudly on a frontmatter field we do not know rather than guess.

### D7 detail: where skills are published

- **Not Anthropic's repository.** `github.com/anthropics/skills` is Anthropic's implementation and examples, not a hub for other publishers **[E]**, and the standard does not require one: any public repository can hold skills. I did not read its contribution rules.
- **First-party pack (recommended next step after D6 export works).** A separate public repository (name to decide, for example `e3d-skills`; the owning GitHub account or organisation is an owner decision) holding our 12 lenses as `SKILL.md` folders, Apache 2.0, generated by the D6 export so it cannot drift from the engine files. It costs little and gives a real demand signal (installs and stars) before any marketplace work, which answers the "demand is unproven" risk. Whether `npx skills add owner/repo` or skills.sh picks it up without registration is **not verified**.
- **User-published experts are not committed to any git repository as the primary copy.** Reasons: the spec promises removal on request and account deletion, and git history keeps content; published versions are immutable and consent is tied to one content hash, which a database with consent records handles and a repository does not; license checks, secret and personal-data scans and moderation must run before anything is public; thousands of user commits would need a bot with write access and invite conflicts and rate limits; and the engine repository should not hold user content.
- **Optional mirror, later (Phase 4 or after).** A generated, read-only public repository of experts that are approved, license-clean and **opted in by the creator**, so standard tools and directories can install them. Creators are told before opting in that removal deletes the file but git history may keep copies. The Pilot registry stays authoritative; the mirror never accepts writes.
- **Not decided here:** the repository name and owner, whether a mirror is worth its moderation cost, and any listing on a third-party directory.

## 3. What the October experiment tells us about measuring

`docs/experiments/2026-10-17-debate-prompt-pilot/RESULTS.md` [E]:

- 9 debates (3 questions, 3 prompt variants, one run each), 3 voices, 2 rounds: **45 metered calls, 331,766 input and 65,506 output tokens**, about 44 thousand tokens a debate. grok-build's CLI spend was not measured. I did not look up prices, so there is **no dollar figure here**.
- **Run-to-run noise is large and was not measured.** The same question under three prompt variants gave three different verdicts, and one run per cell cannot separate a prompt effect from chance.
- **Planted errors were too easy**: all three were caught in every variant. A test that every arm passes cannot show lift.

So a Phase 3 that runs each task once per arm cannot support "the council helps". The plan below repeats runs and adds a control.

## 4. Evaluation plan (to pre-register before any result is seen)

**Arms, per task**
- A: the strongest single model, with the same tools and evidence.
- B: today's default panel (same prompt for every seat).
- C: a random eligible expert preset.
- D: the advisory Auto Council.
- E (control): the **same** single model sampled three times and merged. This separates "more voices" from "different vendors".
- F (control): the **same** single model with **three different lenses**. This isolates what *skill selection* adds with the vendor held fixed. F against E isolates the lenses; D against F isolates the vendor spread. Without F we cannot say a gain came from skills rather than from mixing models.

**Tasks.** 40 to 50, in bands: spec review, diff review, architecture decision, risk review, claim checking with subtle planted errors, forecasts that will resolve. Prefer our own real artifacts with later-known outcomes (specs that were revised, changes that were reverted) so ground truth exists. Keep private repos out of any public fixture.

**Grading.** Rubric written first. Blind to arm. Two graders: the owner plus a model from a family not used in the arms. Primary measure: **verified unique findings** per task (a person checks each against the source) and **false positives**. Freeze the router before the 20% holdout is opened.

**Repeats.** At least 3 per task per arm, to measure noise.

**Cost, in tokens only.** Using the pilot's ~44 thousand tokens a debate for the multi-seat arms (B, C, D, F): 45 tasks x 4 arms x 3 repeats is about 540 debates, roughly **24 million tokens**, plus the cheaper A and E arms and grading. The owner approves a cap before any run.

**Stage 0 (cheap, first):** 12 tasks x 3 repeats on arms A and B only. Output: the noise (standard deviation of the per-task difference), which tasks separate the arms, and a real token cost. Decide the full run from this, not from a guess.

**Proposed thresholds (owner to approve; #50's "15% lift, under 3x cost" is a hypothesis, not yet a bar)**
- **Ship:** mean paired lift in verified unique findings over arm A is at least +15%, the 95% bootstrap interval excludes 0, cost per task is at most 3x arm A, and false positives are not worse by more than 10% relative.
- **Inconclusive:** anything else with the interval including 0. Say so; stay in shadow mode; no accuracy claim.
- **Stop or narrow:** point estimate below +5% at 2x cost or more, or arm E matches arm D (the lift is just more samples).
- If 45 tasks cannot exclude 0 at the Stage 0 noise level, we add tasks or declare it inconclusive. We do **not** loosen the bar afterwards.

## 5. Phase 1, narrowed

Engine only, flag off by default: 8 starter lenses (of the October 12) as standard skill folders, the validator, load order and receipt fields (D2, D3, D4), `--panel` and `--specialist` on the CLI, an additive receipt, and a validated-copy command (D6). Full definition: `experts-phase1-private-experts-spec.md`. **Out:** cloud, billing, hosted MCP parameters, publishing, reactions, any marketplace surface. Existing `e3d_debate` and `e3d-debate` behavior unchanged when no expert is named.

## 6. For the owner

*Answered 2026-11-01: D1 to D7 approved with D6 amended (standard format native); D5 is option B, starting at Phase 2; Phase 1 starts now; Phase 4 waits for the Challenge test; Stage 0 token cap and grading plan are in section 9 of the Phase 1 spec. The list below is the original question.*

1. Approve D1 to D7 (or change them). D6 in one line: our format stays native; export to the standard `SKILL.md` in Phase 1; import is inspect-only at first, never runs scripts or pre-approves tools, and passes a license gate. D7 in one line: publish our own pack from a separate repository, keep user-published experts in the Pilot registry, and consider an opt-in read-only mirror later.
2. A or B for MCP pass-through (D5), and whether to settle it now or at Phase 2.
3. Whether Phase 1 starts now (engine-only, cheap) or waits for the 5-debate Challenge test to show whether strangers participate. My view: Phase 1 can start now because it needs no cloud change and no public surface; **Phase 4 should wait** for the test.
4. A token cap for Stage 0, and your time to grade.

## 7. Not verified

I have not opened the cloud PRs #272, #279, #280, #283, #284, #286, #290 and #291 that #50 cites, so I do not vouch for their descriptions. For D6 I read the format spec page once (through a read-only fetch) and did not read the foundation announcement, the `skills-ref` validator or any real skill; the install and size figures quoted in the news are second-hand. For D7 I did not read Anthropic's contribution rules, skills.sh's listing requirements, or the third-party notices file in `anthropics/skills`, and I read only the first lines of a proprietary `LICENSE.txt`. I read only the headings of the panel spec's pricing and audit-field sections. Nothing here was measured; the token figures are from the October results file.
