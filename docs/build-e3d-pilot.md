# Feature Ticket: Build e3d-pilot

## Overview

`e3d-pilot` is a repo-agnostic orchestrator that decides what a codebase should work on next and drives that work to a reviewable branch, unattended. It sits one layer above `codex-spec-runner` (csr): csr stays the dumb, reliable phase executor ("run this spec"); e3d-pilot's job is everything before and after that — research the repo, propose an idea, check it hasn't already been done, draft a csr-shaped spec, get two (later N) models to agree the spec is ready, hand it to csr, review the result, and open a draft PR. It never merges anything itself.

e3d-pilot must work against **any** git repository, on any host or org, public or private — not just spacepacket1 projects (e3d-cast, e3d-pod2vid, e3d-agent, e3d-mobile, e3d-maps, e3d-docs, csr itself). spacepacket1 repos are where it's piloted first (starting with e3d-cast and e3d-pod2vid), not the boundary of what it supports. The whole point of the per-repo `config.json` contract is that adopting e3d-pilot on an unrelated repo is "write one config file," not "fork or patch the tool" — that's what makes it something other people, outside this org, would actually pick up and run.

This "any repo" claim is precise about *where* it holds: discover, ideate, draft, negotiate, execute, and review are all pure `git`/filesystem operations with no forge dependency — they work identically on a GitHub repo, a GitLab repo, or a repo with no remote at all. Only the final publish step needs to know about a specific forge, so it is the one pluggable seam (see Phase 8): a `github` backend ships in this spec, a `local` (no-remote) fallback ships in this spec, and GitLab is a documented future adapter, not a contradiction of the goal.

## Goals

- Run a full discover -> ideate -> draft -> negotiate -> execute -> review -> publish pipeline against a single target repo, driven entirely by a small per-repo config file.
- Provider abstraction that already treats "how many models participate" as a variable, not a constant: two reviewers today (Claude, Codex), a third local, open-weight model addable later purely through config, with zero pipeline code changes.
- Never repeat work: check the target repo's branches, open PRs, and this tool's own run history before proposing an idea.
- Never touch anything unattended in a way that isn't reversible: worktree-isolated execution, draft PRs only, a path denylist, a diff-size ceiling, and a per-repo kill switch.
- Fleet mode: point it at a list of repos and it runs the pipeline independently, once per repo.
- Reuse csr's existing conventions (provider CLIs, `runner:model=provider:model` annotations, manifest/summary format) instead of inventing parallel ones.
- Zero assumptions baked in about which org, remote host, or repo naming convention is in use — a stranger cloning e3d-pilot against their own unrelated GitHub (or GitLab, or a remote-less local repo) project should have the same experience as running it on e3d-cast, all the way through review; publish degrades to a `local` backend instead of a forge-specific one where there is no supported forge configured yet.
- A single, well-defined run-id lifecycle: every `e3d-pilot run` invocation is either starting a new run or resuming a specific existing one, and this is never ambiguous or left to an implementer's guess.
- Ideation should optimize for attracting and retaining users first, revenue second — candidates are graded and ranked accordingly (Phase 4), and sourced in part from cross-domain analogies/metaphors (games, social platforms, marketplaces, dev tools, fintech, etc.) rather than only from the target repo's own backlog (Phase 3), spanning categories such as making data more useful, adding workflow to UI, social features, gamification, testing, marketing, and selling.

## Non-Goals

- Do not reimplement or fork csr. The execute stage is a subprocess call to the user's existing `codex-spec-runner` install.
- Do not add `local` as a provider inside csr itself. csr's own `run_codex_phase` / `run_claude_phase` dispatch is out of scope for this spec — that would be a separate, future csr change. e3d-pilot's own stages (discover/ideate/draft/negotiate/review) call provider CLIs directly and can support a local provider now; only the execute stage is limited to whatever csr itself supports today.
- Do not hardcode a specific local serving stack (Ollama, LM Studio, MLX, vLLM). The local provider adapter must assume nothing beyond an OpenAI-compatible HTTP chat-completions endpoint.
- Do not build a new scheduler. Cadence (daily, etc.) is out of scope — a cron entry or the operator's own scheduler calls `e3d-pilot run` or `e3d-pilot fleet`.
- Do not auto-merge, force-push, or push to a protected branch under any condition.
- Do not require every target repo to adopt a new documentation convention. Read whatever already exists (`AGENTS.md`, `CLAUDE.md`, `README.md`) rather than mandating one.
- Do not hardcode spacepacket1- or e3d-specific assumptions anywhere in the pipeline: no fixed GitHub org, no fixed remote host, no naming convention tied to `e3d-*`. The one intentionally e3d-specific integration point is the optional `e3d-agent` live-verification hook in Phase 8, and it must stay strictly config-opt-in so it's a no-op for repos that don't have it.
- Do not add a YAML dependency. Config and state files are JSON, parseable with `jq`, which csr-adjacent tooling already assumes is available.
- Do not implement a GitLab (`glab`) publish backend in this spec. Phase 8's publish-backend interface must make one addable later without touching any other stage, but building it now is out of scope.

## Existing Files (read first)

- `/home/ubuntu/codex-spec-runner/bin/codex-spec-runner` — exact CLI surface e3d-pilot's execute stage shells out to (`--list`, `--preflight`, `--prepare-context`, `all`, `--from/--to`, `--provider`, manifest format, `runner:model=provider:model` annotation syntax).
- `/home/ubuntu/codex-spec-runner/README.md`
- `/home/ubuntu/codex-spec-runner/examples/runner-improvements-feature-ticket.md` — template this spec follows.
- `/home/ubuntu/e3d-agent/README.md` — optional live-verification adapter for repos exposing paid E3D APIs (used by Phase 8 only, not a core dependency).

## Shared Constraints

- Bash-first CLI, same install story as csr (`bin/` on `PATH`), Node/`jq`/`curl` allowed, no new language runtime required to run it.
- All runtime/generated state lives under `.e3d-pilot/` inside the *target* repo (not inside the e3d-pilot repo itself), mirroring csr's `.codex-spec-runner/` convention: safe to delete, regenerated on demand, git-ignored by default in the target repo.
- Every external action (branch creation, PR open, provider call) must be traceable to a file under `.e3d-pilot/runs/<run-id>/` in the target repo.
- Keep each phase's scope to what its Requirements say; do not implement later phases early.
- Prefer small, composable functions/scripts per concern (config, dedup, provider adapter, worktree, negotiate) over one large control-flow file.

## Phase 1 - Repo Scaffold and Config Schema

<!-- runner:model=codex:gpt-5.4-mini -->

Create the e3d-pilot repo skeleton and the per-target-repo config contract everything else depends on.

### Requirements

- Initialize the repo at `/home/ubuntu/e3d-pilot` if not already a git repo: `git init`, `LICENSE`, `.gitignore` (must ignore `.e3d-pilot/` — that directory belongs to *target* repos when e3d-pilot is run against them, but also ignore any local `.e3d-pilot/` created when e3d-pilot is run against itself for dogfooding), `README.md` stub, `bin/e3d-pilot` entrypoint (Bash), `package.json` if needed for distribution metadata only (no required runtime dependency).
- This spec file (`docs/build-e3d-pilot.md`) already exists in the working tree before Phase 1 runs; do not move or rename it.
- Define the per-target-repo config file: `.e3d-pilot/config.json` inside the target repo. Fields:
  - `verify`: array of shell commands to run in the review stage (falls back to auto-detection from `package.json`/`requirements.txt`/`Makefile` if absent).
  - `protected_paths`: array of glob patterns e3d-pilot must never modify or propose modifying (e.g. CI config, deploy scripts, secrets).
  - `research_topics`: free-text hints for the discover stage's web research pass (e.g. "AI video generation", "wallet-paid APIs").
  - `analogy_domains`: optional array of cross-domain seed strings used by the discover stage's analogy pass (e.g. "game progression/reward loops", "social feed and notification mechanics", "marketplace liquidity", "fintech trust/verification UX"); if absent, e3d-pilot falls back to a built-in default list spanning games, social platforms, marketplaces, dev tools, and fintech.
  - `pr`: `{ "base_branch": "main", "draft": true, "labels": [], "backend": "auto" }`. `backend` is `"auto"` (detect from remote), `"github"`, or `"local"`; `"gitlab"` is a reserved future value, not implemented by this spec.
  - `providers`: per-stage provider assignment, e.g. `{ "discover": "claude", "ideate": "claude", "draft": "codex", "negotiate": ["claude", "codex"], "review": "claude" }`. `negotiate` is explicitly an array to keep the reviewer count variable.
  - `max_diff_files` / `max_diff_lines`: ceilings enforced before execute.
  - `docs`: optional explicit path to repo guidance docs (`AGENTS.md`, `CLAUDE.md`); if absent, auto-detect by filename.
  - `notify`: optional `{ "email": { "to": "...", "command": "..." } }`. When present, a successful publish sends a best-effort email; `command` overrides the default `mail` invocation (see Phase 8).
- Write a `config.schema.json` (or equivalent inline validation function) and a `e3d-pilot config validate <repo>` subcommand that checks a target repo's config against it.
- `bin/e3d-pilot --help` documents all subcommands this spec will add across phases, even as stubs that print "not yet implemented" for later-phase commands.

#### Run Lifecycle (foundation for every later stage)

Every later phase reads or writes "the current run" — this must be unambiguous before any of them are built.

- `e3d-pilot run --repo <path> --stage <name>` accepts an optional `--run-id <id>`.
- `--stage discover` (or `--stage all`) **without** `--run-id` always starts a **new** run: generate `<run-id>` as `<date>-<repo-slug>` under `.e3d-pilot/runs/` in the target repo, collision-safe (`-2`, `-3`, ... if one already exists today), and record it as that repo's latest run.
- Every other stage (`ideate`, `draft`, `negotiate`, `execute`, `review`, `publish`) **without** `--run-id` resolves to "the latest run for this repo" by reading `.e3d-pilot/latest-run` (a plain text file in the target repo holding the current run-id, updated whenever a new run starts). This is how a stage run standalone (e.g. resuming `negotiate` after a "needs human" exit) finds its run without the caller having to know the id.
- `--stage <name> --run-id <id>` always operates on that specific run directory regardless of what `latest-run` says — this is the explicit resume path.
- `--stage all` is a sequential dispatcher owned by this phase's CLI skeleton: it calls discover, ideate, draft, negotiate, execute, review, publish in order within one run-id, stopping immediately (with a clear, distinct exit status per stage) if any stage exits non-zero or reports a non-error "stop" outcome (e.g. ideate's "nothing to do", negotiate's "needs human"). Later phases fill in each stage's real behavior; this phase only needs the dispatch skeleton and the run-id plumbing to exist and be callable.

### Acceptance Criteria

- `bash -n bin/e3d-pilot` passes.
- `e3d-pilot config validate <repo-without-config>` fails clearly, naming the missing file.
- `e3d-pilot config validate <repo-with-a-hand-written-sample-config>` (add one sample under `examples/sample-config.json`) passes.
- `.gitignore` correctly ignores `.e3d-pilot/`.
- Two consecutive `--stage discover` runs (stub implementation is fine at this phase) against the same repo on the same day produce two distinct run-ids, and `.e3d-pilot/latest-run` points at the second.
- `--stage <anything> --run-id <a-specific-earlier-id>` resolves to that run directory even after a newer run exists.

## Phase 2 - Provider Adapters and the N-Reviewer Contract

<!-- runner:model=claude:sonnet -->

Build the abstraction that lets discover/ideate/draft/negotiate/review call any configured model through one interface, so adding a third (local) provider later is additive, not a rewrite.

### Requirements

- Every provider is a script at `lib/providers/<name>` (`claude`, `codex`, `local`) implementing the same contract: read a prompt from a file path given as `$1`, write plain-text output to stdout, exit non-zero on failure. No provider-specific branching outside `lib/providers/`.
- `lib/providers/claude` shells out to the `claude` CLI the same way csr does (non-interactive, prints response, respects `CLAUDE_BIN` override).
- `lib/providers/codex` shells out to the `codex` CLI the same way csr does (respects `CODEX_BIN`, sandbox/approval flags default to safe/read-mostly for e3d-pilot's own stages, since these stages reason and write files under `.e3d-pilot/`, not the target repo's tracked source — only the execute stage, via csr, touches tracked source).
- `lib/providers/local` calls a configurable OpenAI-compatible endpoint: `LOCAL_MODEL_ENDPOINT` (e.g. `http://localhost:11434/v1`), `LOCAL_MODEL_NAME`. If `LOCAL_MODEL_ENDPOINT` is unset, the provider reports itself unavailable via a distinct, documented exit code (not a crash) — this is what lets `e3d-pilot providers list` report status cleanly rather than erroring. This distinct exit code is only the adapter-level contract; whether a *pipeline run* is allowed to proceed with an unavailable reviewer is defined in Phase 6, not here (short answer, spelled out there: it is not — a configured-but-unavailable negotiate reviewer fails the run fast, it is never silently skipped).
- Add `e3d-pilot providers list` that reports each provider's availability (binary/endpoint reachable or not) without invoking a real prompt.
- Define the negotiate convergence protocol here (implemented fully in Phase 6, but the data contract belongs here): each reviewer's raw stdout must contain, verbatim and on their own lines somewhere in the output, the following (Markdown fences shown below are for *this document's* readability only — they are not part of the parse target; `lib/negotiate/parse-status` must locate these three lines by matching `^---STATUS---$`, `^status: (approved|revise)$`, `^reason: .+$` directly in the raw text, whether or not the provider happens to wrap them in a code fence):
  ```
  ---STATUS---
  status: approved | revise
  reason: <one line>
  ```
  When `status: revise`, the same response must also contain the reviewer's full proposed replacement for the spec draft, in a fenced block starting with ` ```spec ` — Phase 6 applies this immediately, in place, as soon as it's parsed (not deferred to a later round; a subsequent reviewer in the same pass may then replace it again — see Phase 6 for the exact sequential mechanics). This phase only defines that the parser extracts both the status block and, when present, the fenced `spec` block from one response.
  A shared `lib/negotiate/parse-status` parses both from any provider's raw output identically.
- Config's `negotiate` field (Phase 1) is an ordered array of provider names; convergence rule is "all listed reviewers report `approved` in the same round" — implement this as a pure function of the array length so a 2-reviewer and a future 3-reviewer config exercise the same code path.

### Acceptance Criteria

- `e3d-pilot providers list` correctly reports `local` unavailable when `LOCAL_MODEL_ENDPOINT` is unset, and reachable when pointed at a throwaway local HTTP stub in a test.
- A unit-style shell test feeds a 2-entry and a 3-entry `negotiate` array into the convergence function with synthetic status blocks and confirms both "all approved" and "one dissenting" cases resolve correctly.
- `lib/providers/claude` and `lib/providers/codex` invocations are confirmed via `--dry-run`-style output (print the command that would run) without requiring live credentials in this phase's own verification.

## Phase 3 - Discover Stage

<!-- runner:model=codex:gpt-5.4-mini -->

Produce `findings.md` for a target repo: what's going on in it right now, plus outside context.

### Requirements

- `e3d-pilot run --repo <path> --stage discover` writes `.e3d-pilot/runs/<run-id>/findings.md` in the target repo, using the run-id lifecycle from Phase 1 (this is one of the two stages, along with `all`, that may start a new run).
- Every `findings.md` records the repo's current `git rev-parse HEAD` as a `head_sha` front-matter field.
- Local facts gathered directly (no model call needed for this part): `git log <previous-run's-head_sha>..HEAD` when a prior run's `findings.md` exists for this repo, else the last `HISTORY_LOOKBACK_COMMITS` commits (default `20`, configurable via env); open branches; `gh issue list` / `gh pr list` if `gh` is authenticated and the repo has a remote; existing `AGENTS.md`/`CLAUDE.md`/`README.md` content; and any files matching `TODO`/`FIXME` greps.
- Model call (using the configured `discover` provider): given the local facts bundle plus `research_topics` from config, produce a short "what's the current state of the art relevant to this repo" section. This model call always runs, with or without a `gh` remote — it is independent of `gh`/GitHub entirely, since it's a web-research pass over `research_topics`, not a repo-hosting query. Only the `gh issue list`/`gh pr list` local-facts sub-step is skipped when there is no authenticated `gh` remote; everything else (git facts, docs, TODO/FIXME grep, and this model call) still runs.
- Analogy pass (same model call, not a second provider invocation): the prompt must also instruct the provider to pick the 2-3 most transferable entries from `analogy_domains` (or the built-in default list) for this specific repo, and produce a distinct "Analogous Patterns" subsection under "External Context" naming, per entry, the source domain, the mechanic being borrowed, and one concrete sentence on how it could apply here. The intent (see project goals) is to seed ideation with cross-domain metaphors — e.g. a game's progression loop suggesting a retention mechanic, a marketplace's liquidity trick suggesting a two-sided workflow — rather than leaving novel, non-obvious ideas to chance.

### Acceptance Criteria

- Running discover against a repo with no `gh` remote configured still succeeds: the "Local State" section omits the `gh issue`/`gh pr` subsection (noted as skipped, with why) while git-derived facts are still present, and the "External Context" section (from the model call) is still produced normally.
- `findings.md` is well-formed Markdown with clearly separated "Local State" and "External Context" sections, and a `head_sha` front-matter field.
- Re-running discover the same day for the same repo does not overwrite the prior run's directory, and the second run's `git log` range starts from the first run's recorded `head_sha`.
- The "External Context" section contains a distinct "Analogous Patterns" subsection naming at least one source domain (from `analogy_domains` or the default list) plus a one-line transfer rationale per entry.
- Overriding `analogy_domains` in a target repo's config changes which domains appear in the prompt sent to the discover provider (verifiable with a stub provider that echoes the prompt it received back into its output).

## Phase 4 - Ideate and Dedup Stage

<!-- runner:model=claude:sonnet -->

Turn findings into a ranked list of candidate ideas, each checked against everything that already exists.

### Requirements

- `--stage ideate` reads the current run's `findings.md`, plus **every prior run's `candidates.md` and `spec-final.md`** for this repo under `.e3d-pilot/runs/*/`, plus current `git branch -a`. `gh pr list --state all` output is included the same way Phase 3 handles it: only when `gh` is authenticated and the repo has a remote it recognizes; otherwise this sub-step is skipped and noted as skipped in `candidates.md`, exactly like `findings.md` already notes it for discover. Dedup against branches and past runs still runs in full either way — a missing `gh` view narrows what dedup can check, it never blocks the stage.
- Model call (configured `ideate` provider) proposes 3-5 candidate ideas. For each candidate, it must explicitly state why it is not already covered by an existing branch, open/closed PR (when that data was available), or a past run — not just propose ideas in isolation.
- Each candidate block carries, beyond the existing `Duplicate`/`Dedup rationale` fields: `Category` (one of `data`, `workflow`, `social`, `gamification`, `testing`, `marketing`, `selling`, `other`), `Analogy` (source domain plus one sentence on how it transfers — drawing on Phase 3's "Analogous Patterns" findings where relevant, or a fresh analogy if the candidate doesn't map to one already surfaced), `Attraction (1-5)` and `Retention (1-5)` (new-user pull and repeat-engagement value, per this project's stated goal that attracting and retaining users is primary), `Effort (low|medium|high)`, and an optional `Revenue (1-5|n/a)` scored explicitly as secondary to Attraction/Retention, never a substitute for them.
- The prompt should encourage candidates spanning multiple `Category` values across the full set when plausible ideas exist for each, but must not force a low-quality or duplicate candidate into an underrepresented category just for coverage — non-duplication and genuine merit still come first.
- Ranking rule: non-duplicate candidates are ordered primarily by `Attraction + Retention` (highest first); `Revenue` may only break ties between otherwise-equal candidates, and must never let a lower `Attraction + Retention` candidate outrank a higher one.
- Output: `.e3d-pilot/runs/<run-id>/candidates.md`, ranked, with the top candidate marked as selected and the rest kept for audit/traceability.
- If every candidate is judged a duplicate of existing work, the stage exits cleanly with no selected candidate and a note explaining why — this is a valid, non-error outcome (nothing to do today).
- The existing soft-validation mechanism (which already warns, non-fatally, when the model ignores the 3-5-candidate or dedup-rationale prompt requirements) must extend the same treatment to the new required fields: a candidate missing `Category`, `Analogy`, `Attraction`, `Retention`, or `Effort` (Revenue may legitimately be `n/a`) surfaces as a warning in `candidates.md` and stdout, exactly like today's count/rationale warnings — not a hard rejection.

### Acceptance Criteria

- A synthetic test repo with an open PR titled "Add X" and a findings.md that would otherwise suggest "Add X" results in that candidate being marked duplicate, not selected.
- Running ideate against a repo with no `gh` remote configured still succeeds: `candidates.md` notes the PR-list sub-step as skipped, and dedup against branches and past runs still runs normally.
- The "nothing to do" outcome is distinguishable programmatically (e.g. a `selected: none` field) so `e3d-pilot run --stage all` can stop cleanly without proceeding to draft.
- Given two non-duplicate candidates from a stub provider — one with higher `Revenue` but lower `Attraction + Retention`, one with lower `Revenue` but higher `Attraction + Retention` — the higher `Attraction + Retention` candidate is selected/ranked first.
- Every candidate in a produced `candidates.md` has `Category`, `Analogy`, `Attraction`, `Retention`, and `Effort` fields present; a stub response that omits one of these triggers the corresponding soft warning without failing the stage.

## Phase 5 - Draft Stage

<!-- runner:model=claude:sonnet -->

Turn the selected candidate into an actual csr-shaped phased Markdown spec.

### Requirements

- `--stage draft` reads `candidates.md`'s selected entry and the target repo's structure, and produces `.e3d-pilot/runs/<run-id>/spec-draft.md` following csr's spec conventions exactly: numbered `## Phase N - Title` headings, `<!-- runner:model=... -->` / `<!-- runner:read=... -->` / `<!-- runner:verify=... -->` annotations where useful, Overview/Goals/Non-Goals/Existing Files/Shared Constraints sections, Requirements/Acceptance Criteria per phase.
- The draft stage must read `/home/ubuntu/codex-spec-runner/README.md`'s "Spec Format" and "Spec Annotations" sections (or an equivalent bundled copy) as part of its prompt, so the generated spec is directly runnable by csr without hand-editing.
- Every `<!-- runner:model=... -->` annotation the draft stage emits must reference only providers csr's own execute step actually dispatches — today `codex` and `claude`. This is true even if the target repo's own `negotiate` config includes `local`: `local` is an e3d-pilot-side reviewer, never a csr execute-time provider, and the draft stage must never emit `runner:model=local:*` or leave a phase's provider unset in a way that could resolve to it. If csr adds `local` support in the future, this constraint list is the one place to update.
- Every phase the draft stage writes must also carry a machine-readable `<!-- pilot:touches=<glob> -->` annotation (one or more per phase) naming the paths that phase's Requirements will touch, populated by the draft stage itself since it is the one writing those Requirements. This is what makes the `protected_paths` check in Phase 7 a real match instead of guessing from prose.
- Respect the target repo's `protected_paths` and `max_diff_files`/`max_diff_lines` from config: no phase's `pilot:touches` globs may match a `protected_paths` entry, and the drafted spec should be scoped to fit the configured ceiling; if a candidate can't be scoped that small, the draft stage should say so rather than silently exceeding it.

### Acceptance Criteria

- `spec-draft.md` produced against a sample candidate parses successfully with `codex-spec-runner spec-draft.md --list` (phase numbers, providers, titles all print).
- Every phase in a produced `spec-draft.md` has at least one `pilot:touches` annotation, and none of them are `runner:model=local:...`.
- A drafted spec that would touch a `protected_paths` entry is rejected before being written, with a clear reason recorded in the run directory.

## Phase 6 - Negotiate Loop

<!-- runner:model=codex:gpt-5.4-mini -->

Implement the bounded, multi-reviewer convergence loop over the draft spec, using the contract from Phase 2.

### Requirements

- Before round 1, check every provider named in `config.providers.negotiate` via the same availability check `providers list` uses (Phase 2). If any configured reviewer is unavailable, the stage fails immediately with a clear error naming which reviewer and why — it never silently drops a configured reviewer or proceeds with fewer than configured, since that would quietly weaken the agreed reviewer set.
- Each round is a single, strictly sequential pass through `config.providers.negotiate`, in order — never parallel, never "collect everyone's verdict against one shared snapshot." Concretely, for each reviewer in the array: invoke it against `spec-draft.md` **as it currently stands at that exact moment** (reflecting any replacement already applied earlier in this same pass); if it reports `approved`, move to the next reviewer with the draft unchanged; if it reports `revise`, immediately overwrite `spec-draft.md` with that reviewer's fenced `spec` replacement block (per the Phase 2 parse contract) before invoking the next reviewer. This is what "the reviewer that flagged a problem is the one that fixes it" means mechanically — no reviewer ever reviews or revises on behalf of another, and no reviewer's replacement is discarded or fought over, because each one only ever sees and edits the single current draft in strict order.
- A round **converges** only if every reviewer in the pass reports `approved` at the moment it was invoked — i.e. the entire pass completes with zero `revise` verdicts triggered. If even one reviewer revises partway through a pass, that pass is not converged regardless of what reviewers after it say (they were reviewing a draft that had already changed mid-pass); log the whole pass and start the next round from the first reviewer in the array again, since the draft has moved since they last saw it. Log every reviewer's status, reason, and (if given) replacement spec for the round to `.e3d-pilot/runs/<run-id>/negotiation-log.md`, in full, before starting the next round.
- `NEGOTIATE_MAX_ROUNDS`, default `4`. If convergence (all reviewers `approved` in the same round) isn't reached within the limit, the stage stops, leaves `spec-draft.md` and the full log in place, and exits with a distinct "needs human" status — it must never fall through to execute with an unresolved spec.
- On convergence, write the approved spec as `.e3d-pilot/runs/<run-id>/spec-final.md`.
- This loop must work unmodified whether `negotiate` in config has 2 entries or 3 — no hardcoded two-party assumption anywhere in this phase's code (reuses Phase 2's convergence function), including when 2 or more reviewers request `revise` in the same round.

### Acceptance Criteria

- A synthetic scenario with two reviewer stubs that both immediately approve converges in round 1.
- A synthetic scenario where one stub always requests revision hits `NEGOTIATE_MAX_ROUNDS` and exits with the "needs human" status, not a crash or a silently-forced pass.
- A synthetic scenario where a configured reviewer stub is made "unavailable" fails the stage immediately, before round 1's status blocks are even requested from the other reviewer.
- A synthetic scenario with three stubs where the first two report `revise` (each with a distinct replacement block) and the third would approve: the pass applies both replacements in order, the third stub is invoked against the second stub's replacement (not the original draft), and the round is still logged as not-converged (since revisions were triggered) — the next round starts again from the first stub, not the third.
- Adding a third stub reviewer to the same test config exercises the identical code path (confirmed by running the same test with 2 and 3 stub entries).

## Phase 7 - Execute Integration and Worktree Isolation

<!-- runner:model=claude:sonnet -->

Wire `spec-final.md` into a real, isolated csr run against the target repo, with the safety rails that make unattended execution acceptable.

### Requirements

- `--stage execute` creates a fresh `git worktree` for the target repo (never operates in the user's primary checkout), on a new branch named from the run-id (e.g. `e3d-pilot/<run-id>`).
- Runs `codex-spec-runner <path-to-spec-final.md> all` (using csr's existing CLI exactly as documented — `--preflight` runs automatically per csr's own default) inside that worktree, capturing csr's manifest/summary output alongside e3d-pilot's own run directory.
- Before invoking csr, re-check every phase's `pilot:touches` annotation (from Phase 5) against `protected_paths` one more time as a final guard — this is a straightforward glob match against explicit, machine-readable annotations, not text inference, so it is exact rather than best-effort.
- After csr completes, enforce `max_diff_files`/`max_diff_lines` against the actual `git diff` in the worktree. Exceeding the ceiling stops the pipeline before review/publish and flags it for a human, rather than trimming the diff automatically.
- Respect `.e3d-pilot/paused` in the target repo: if present, `execute` (and ideally every stage) refuses to run and says why.

### Acceptance Criteria

- Running execute against a throwaway test repo produces a new branch in a separate worktree, leaves the primary checkout's working tree untouched.
- A spec deliberately crafted to touch a `protected_paths` entry is caught and stops before csr is invoked.
- A test that makes a huge synthetic diff exceed `max_diff_lines` correctly halts before publish.
- Creating `.e3d-pilot/paused` in the test repo causes `execute` to no-op with a clear message.

## Phase 8 - Review and Publish Stage

<!-- runner:model=claude:sonnet -->

Independently verify the executed change, then open a draft PR — and stop.

### Requirements

- `--stage review` runs the target repo's configured `verify` commands (or auto-detected ones) inside the worktree, and separately asks the configured `review` provider to read the diff and comment on correctness/scope-creep, independent of whichever provider(s) implemented it in execute.
- If `config.docs` or auto-detected repo docs mention E3D paid-API surfaces (e3d-pod2vid render/revise, E3D Maps), and `e3d-agent` is available on the machine, allow an optional config-declared live-verification command (e.g. `npx e3d-agent pod2vid render --transcript ... --wait`) to run as one more `verify` entry — strictly config-opt-in, never assumed.
- Before publish runs, it force-adds the current run's audit artifacts (`findings.md`, `candidates.md`, `negotiation-log.md`, `spec-final.md`, and a copy of csr's manifest rows for this run) into the worktree branch's commit, as an explicit, narrowly-scoped exception to the target repo's `.gitignore` — only these specific files, only on this branch. This is what makes them part of the pushed diff instead of orphaned local state, so audit links in the PR body actually resolve for anyone reviewing it.
- `--stage publish` hands off to a publish backend under `lib/publish/<name>`, selected by `config.pr.backend` (default: auto-detect from the repo's remote — a `github.com` remote selects `github`; no remote selects `local`). Each backend implements one contract: given the branch name and a prepared summary (see below), produce a human-actionable result and a machine-readable outcome (published/needs-attention/error).
  - `lib/publish/github`: pushes the branch to the configured remote and opens a **draft** PR via `gh pr create --draft` against `config.pr.base_branch`, with a body that embeds condensed excerpts of findings/candidates (noting why this idea wasn't a dupe)/negotiation outcome inline, plus relative links to the now-committed audit files.
  - `lib/publish/local`: used when there is no supported forge remote (or none configured). Leaves the branch committed in the worktree, does not push anywhere, and writes a plain-text summary (same content that would have gone in a PR body) to `.e3d-pilot/runs/<run-id>/publish-summary.md`, printing its path and the branch name so a human can open it however they publish changes in their own workflow.
  - Adding a GitLab (`glab`) backend later is only implementing `lib/publish/gitlab` against this same contract — out of scope for this spec (see Non-Goals), but this phase's job is to make that true.
- Publish never merges, never pushes to `base_branch` directly, and refuses to run if `verify` failed.
- After a successful publish (outcome `published` or `needs-attention`), if `config.notify.email.to` is set, send a best-effort email notification: subject naming the branch (and flagging when the outcome needs human action), body containing a link (the PR URL for `github`, or the local branch name/path when there is no remote) followed by the same summary content used for the PR body. Notification is strictly opt-in (absent by default), and its failure or the absence of a mail transport never fails the publish stage — it degrades to a skip, same as `live_verify`'s config-opt-in pattern. The actual send is a configurable shell command (default: `mail`), never a hardcoded SMTP/API integration, matching this project's stance against baking in a specific external stack.
- `lib/publish/github` captures and reports the created PR's URL (`pr_url:` in its machine-readable output) so the notification step and any other caller can link to it directly, instead of only printing human-readable push/PR commands.

### Acceptance Criteria

- A verify failure (synthetic failing test) blocks publish with a clear reason; no branch is pushed.
- A successful run against a repo with a `github.com` remote produces a draft PR (verified against a throwaway/test GitHub repo, or a dry-run mode that prints the exact `gh` command without executing it, for environments without a disposable repo), and the audit files it links to are present in that PR's file list.
- A successful run against a repo with no remote configured produces a committed local branch and a `publish-summary.md`, and does not attempt any network call.
- The PR body (or `publish-summary.md`, for the `local` backend) contains working links/paths to all audit artifacts, and those paths exist in the branch's tree.
- With `notify.email.to` configured and a stub mail command on `PATH`, a successful publish invokes that command with the configured recipient, a subject naming the branch, and a body containing the PR URL (github backend) or local branch name (local backend) plus the summary content.
- With `notify` absent from config, publish completes exactly as before and never invokes a mail command.

## Phase 9 - Fleet Mode and Documentation

<!-- runner:model=codex:gpt-5.4-mini -->

Let one invocation run the whole pipeline across many repos, and document the tool so anyone — inside or outside spacepacket1 — can adopt it on their own repo.

### Requirements

- `e3d-pilot fleet <repos.json>` (a simple JSON array of repo paths) runs `run --repo <path> --stage all` for each, independently, continuing past a single repo's failure (per-repo status summarized at the end, not silently swallowed).
- `README.md` is written as a standalone open-source tool's README, not an internal e3d doc: it must not assume the reader has any other spacepacket1 repo, and none of its walkthrough steps may depend on spacepacket1-specific paths, orgs, or tooling. It covers: install, per-repo `config.json` schema (with the sample from Phase 1), the run-id/resume model from Phase 1, the full stage list and what each produces, the negotiate protocol and how to add a third provider (concretely: set `LOCAL_MODEL_ENDPOINT`/`LOCAL_MODEL_NAME` and add `"local"` to a repo's `negotiate` array — no code change), the publish backend model (`github`/`local` today, `gitlab` as a documented future extension point), safety rails, and fleet mode.
- Document explicitly that `execute` is bounded by whatever providers csr itself supports (today: `codex`, `claude`) even after a `local` provider is configured for e3d-pilot's own stages — call out that wiring `local` into csr's execute step is a separate future change to csr, not this repo.
- Add `examples/sample-config.json` (already referenced in Phase 1) as the canonical documented example.

### Acceptance Criteria

- `e3d-pilot fleet examples/sample-fleet.json` (add this file, pointing at 2+ throwaway test repos) runs both and reports a clear per-repo pass/fail summary even when one repo is deliberately broken.
- A new reader of `README.md` alone (no other context) can onboard a new repo by writing one `config.json` and running `e3d-pilot run --repo <path> --stage all`.
- `bash -n bin/e3d-pilot` and all phase-level shell syntax checks pass.
