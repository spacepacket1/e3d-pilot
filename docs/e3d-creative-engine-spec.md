# Feature Ticket: e3d-creative — Creative Direction Engine (New Repo)

## Overview

Build `e3d-creative`, a new standalone repo that turns a creative brief into distinct, defensible creative directions — concept, script, storyboard, shot list, and visual-style direction — without rendering any pixels. It is the "brain" in the FutCo growth loop described in `docs/futco-ad-outcome-loop-manifesto.md`: product-agnostic, reusable across every FutCo product (OppScan today; e3d-pilot, e3d-trade, e3d.ai later), and deliberately decoupled from `e3d-cast` (hosting/billing/jobs) and `e3d-pod2vid` (rendering).

This spec covers the engine itself only — offline, recommend-only, no provider spend beyond the LLM calls each phase already needs for its own tests. It does not cover: wiring this into e3d-corp's Proposal/Opportunity flow, a new pod2vid provider adapter for modern visuals, or any live ad spend. Those are separate, later tickets once this engine proves useful.

**Why a separate repo, not a module inside `e3d-cast`:** `e3d-cast` is hosted infrastructure — billing tiers, job queues, webhooks, a `cast_job` manifest that only accepts `transcript`/`upload`/`url` input today (confirmed by reading `e3d-cast/src/worker/index.js`). This engine is an LLM-driven planning/debate tool with a completely different runtime shape, used by Corp directly or via Pilot, not necessarily through `e3d-cast`'s paid-customer pipeline at all.

**Confirmed, real gap this engine does not solve by itself:** `e3d-pod2vid/make_short.py` today produces OpenAI TTS + stock Pexels B-roll + burned-in captions — this is the "looks like the 80s" pipeline the founder flagged. This engine can specify a modern shot-by-shot visual direction, but nothing consumes it until pod2vid grows a new provider-backed input kind (future ticket, not this one). Phase 6 of this spec handles that honestly: today's output degrades to what `e3d-cast`'s existing `transcript` input kind can consume, with the richer shot-by-shot direction preserved as a forward-looking artifact, never silently dropped.

## Goals

- Produce `>=3` genuinely distinct creative directions from one brief — not synonym rewrites of the same idea.
- Each direction includes: hook (first three seconds), premise, audience psychology, full word-accurate script, timed shot-by-shot storyboard, and per-shot visual-style direction (references/prompts, not pixels).
- Support real multi-model debate/critique with recorded dissent — not a single model's output rubber-stamped.
- Support both Claude and OpenAI/Codex as interchangeable LLM providers for the engine's own generation/critique calls (its runtime dependency — distinct from, and unaffected by, s2c's own phase-execution provider used to *build* this repo).
- Independent QA scoring against a fixed rubric, separate from generation, so the engine can't grade its own homework with the same call that wrote the content.
- Deterministic, regenerable, provenance-friendly output: same brief + same model/seed inputs produce comparable, content-addressable artifacts (SHA-256 digests on every generated file), matching the discipline e3d-pilot's own exports already use.

## Non-Goals

- No rendering. No calls to Higgsfield/ElevenLabs/pod2vid in this ticket — this engine produces specifications for those, not output from them.
- No e3d-corp integration (Proposal/Opportunity wiring) — later ticket.
- No hosting, billing, or web UI — this is a CLI tool and library first.
- No autonomous publishing or spend of any kind.
- No fabricated claims about the baseline ad's performance — if a brief references a baseline, treat missing baseline data as blocked, not guessed (same rule as the OppScan spec's T02).
- No new pod2vid provider adapters — flagged as a gap, not solved here.

## Running This Spec

Run with s2c's default provider. `runner:model=claude:*` is safe to use as of `spec2code` commit `e34bcd4` (2026-10-11) — `CLAUDE_PERMISSION_MODE` now defaults to `bypassPermissions`, fixing the earlier silent-no-op bug (`default` mode denied every edit with no TTY to approve it, while still exiting 0).

No phase below carries an explicit `runner:model=` annotation — routing is left to `--auto-route` (`spec2code` commit `52bf165`), which classifies each phase's real complexity with one cheap model call instead of a keyword guess. Always pass `--auto-route`; without it, routing falls back to the static keyword heuristic, which does not know this is a multi-model debate/critique engine and may under-tier it. Live test runs against this spec with `--provider claude --auto-route` have landed anywhere from mostly `sonnet` with a couple `opus`/`haiku` outliers to as many as 5 of 7 phases rated `opus` — the classification is a real model judgment call each time, not a fixed table, so expect some run-to-run variance and check `.spec2code/route-cache.tsv` after a `--list` to see what this run actually decided before assuming cost. `--provider codex --auto-route` has so far rated every phase `default` (`gpt-5.4`) with no variance observed. Before running, also check `.spec2code/manifest.tsv` in the most recently-run repo for the last model (codex or claude) that actually completed a phase, since specific model strings go stale without warning on either provider.

```bash
s2c docs/e3d-creative-engine-spec.md all --auto-route
s2c docs/e3d-creative-engine-spec.md all --provider claude --auto-route
```

## Existing Files (read first)

- `/Users/mini/e3d-corp/lib/proposals/schema.js`, `lib/opportunities/schema.js` — shape conventions (`validateProposalInput`, `normalizeOpportunityCandidate`) this engine's brief/output should stay compatible with, so a later e3d-corp integration ticket is a thin adapter, not a rewrite.
- `/Users/mini/e3d-cast/src/worker/index.js` (`buildWorkerManifest`) — the `cast_job` manifest shape (`kind`, `version`, `jobId`, `input: {kind: transcript|upload|url}`) this engine's output must be reducible to, until pod2vid gains a richer input kind.
- `/Users/mini/e3d-pod2vid/make_short.py` — what the current rendering pipeline actually does (OpenAI TTS + Pexels B-roll + captions); the concrete baseline this engine's visual-style direction is trying to improve on.
- `/Users/mini/e3d-pilot/lib/ideas/ledger.sh` (`ideas_default_candidate_json`, `ideas_ingest_candidate`) — the candidate JSON shape a human-authored idea needs, if/when this engine's output is ingested into e3d-pilot's provenance-tracked ledger.
- `/Users/mini/e3d-pilot/docs/e3d-corp-pilot-cast-ad-outcome-loop-spec.md` §4 — the original creative-quality bar (distinct strategies, QA guardrails, rubric) this engine must satisfy for the OppScan proving case.

## Shared Constraints

- All timestamps RFC 3339 UTC.
- All persisted JSON written atomically (temp file + `mv`), matching e3d-pilot/e3d-corp conventions already established across this fleet.
- Every generated artifact (script, storyboard, visual-direction file) gets a SHA-256 content digest recorded alongside it — no artifact without a verifiable digest.
- No secrets in prompts, logs, or commits. Provider API keys come from environment/file, never hardcoded.
- The narrative/claims guardrails from the OppScan spec §4 apply globally, not just to that one campaign: no implying knowledge the brief doesn't support, no invented testimonials, no unsupported earnings/performance claims.
- A storyboard or critic score is a heuristic, never evidence that an ad will convert — this must be stated in the tool's own output, not just this doc.

## Phase 1 - Repo Scaffold and Brief/Direction-Set Schema

<!-- runner:verify=node --test test/schema.test.js -->

### Requirements

- Scaffold the repo: `package.json`, `bin/e3d-creative` CLI entrypoint, `lib/` for schema/validation, `test/` using Node's built-in test runner (matching e3d-corp's `node --test` convention).
- Define and validate a **Brief** input schema (JSON): `product`, `audience`, `objective`, `baselineRef` (nullable — path/URL to existing creative, or `null` if none exists), `constraints` (array of strings), `spendCeiling` (nullable number), `metric`, `threshold`. Keep field names compatible with `e3d-corp/lib/proposals/schema.js` conventions (non-empty strings, explicit nulls, no implicit undefined).
- Define and validate a **Direction** output schema: `directionId`, `hook`, `premise`, `audiencePsychology`, `script` (word-accurate, array of lines each tagged `fact`/`claim`/`hypothesis`), `storyboard` (array of shots: `timecodeStart`, `timecodeEnd`, `visualDirection`, `audioNotes`, `onScreenText`), `ctaText`, `confidence` (0-1), `rationale`.
- `bin/e3d-creative validate-brief <file>` and `bin/e3d-creative validate-direction <file>` CLI commands for standalone schema checking, no LLM calls.
- If `baselineRef` is set but the referenced file/path doesn't exist or is unreadable, validation must fail closed with a clear "blocked: baseline unreachable" error — never silently treat it as absent.

### Acceptance Criteria

- Valid and invalid brief/direction fixtures both covered by table-driven tests.
- A brief with a `baselineRef` pointing at a nonexistent file fails validation with a message containing "blocked", not a generic parse error.
- `node --test test/schema.test.js` passes with no network access.

## Phase 2 - Provider Abstraction (Claude + OpenAI)

<!-- runner:read=lib/schema -->
<!-- runner:verify=node --test test/provider.test.js -->

### Requirements

- `lib/providers/` with a provider-agnostic interface (`generate({systemPrompt, userPrompt, model}) -> {text, usage}`) and two implementations: `claude.js` (Anthropic Messages API) and `openai.js` (OpenAI/Codex-compatible API). This is the engine's own runtime dependency for generation/critique calls — unrelated to and unaffected by which provider s2c itself used to write this code.
- API keys resolved from environment first, falling back to a configurable key-file path (same pattern as `S2C_CLAUDE_API_KEY_FILE` in `bin/spec2code` and `~/.config/e3d-pilot/anthropic-api-key` on this machine) — never hardcoded, never logged.
- A provider selection mechanism per call site (not global): the brief or CLI flag can request `claude` or `openai` for concept generation vs. critique independently, mirroring the "different phases, different providers" capability already proven in `spec2code`'s `tests/phase-13-mixed-provider-spec.sh`.
- Tests use fake/stub provider binaries or injected fetch mocks — no real network calls, no real API spend, matching e3d-pilot's own test discipline.

### Acceptance Criteria

- Both providers implement the identical interface; a test proves the calling code never branches on provider identity outside `lib/providers/`.
- A test proves concept generation and critique can independently select different providers within one run.
- No test makes a real network call or requires a real API key to pass.

## Phase 3 - Concept Generation (≥3 Distinct Directions)

<!-- runner:read=lib/providers -->
<!-- runner:verify=node --test test/concepts.test.js -->

### Requirements

- `bin/e3d-creative concepts <brief.json> --out <dir>` generates `>=3` Directions from one Brief, each validated against Phase 1's schema before being written.
- The generation prompt must explicitly require audience-psychology diversity across the returned directions (not just different wording of one idea) and must require the script's `fact`/`claim`/`hypothesis` tagging to be internally consistent (no line tagged `fact` that isn't traceable to the Brief's own fields).
- A deterministic "concept diversity" check: reject (and regenerate once, then fail loudly) a batch where two directions' `premise` fields are near-duplicates (e.g., high string-similarity), rather than silently accepting synonym rewrites.
- Every generated Direction file gets a SHA-256 digest written alongside it in a manifest (`concepts-manifest.json`), including brief digest, model/provider used, and timestamp — provenance-ready from the start.

### Acceptance Criteria

- Against a stub provider returning canned near-duplicate premises, the diversity check fires and the run fails with a clear message rather than writing three near-identical directions.
- Against a stub provider returning three genuinely distinct canned responses, all three validate against Phase 1's schema and are written with correct digests.
- `node --test test/concepts.test.js` passes with no real provider calls.

## Phase 4 - Independent Multi-Model Critique and Debate

<!-- runner:read=lib/providers -->
<!-- runner:verify=node --test test/critique.test.js -->

### Requirements

- `bin/e3d-creative critique <concepts-dir> --out <dir>` runs each Direction through critique from a *different* provider than generated it (if Direction was generated with `claude`, critique defaults to `openai`, and vice versa — configurable override), producing a structured verdict: `keep`/`revise`/`reject`, `reasoning`, `dissent` (explicit disagreement text if critique disagrees with generation's own confidence).
- Bounded rounds: at most 2 critique rounds per Direction, with deterministic termination (if round 2 still disagrees, record both verdicts and surface both — never silently average toward a blander middle ground, matching the manifesto's and original spec's explicit "preserve bold ideas" requirement).
- A "retain existing creative" / "do nothing" option must always be one of the critique's available verdicts when a `baselineRef` exists in the Brief, not just revise/reject of the new directions.
- Every critique round appends to the same manifest discipline as Phase 3 (digests, provider, timestamp) so a full debate history is reconstructable from files alone.

### Acceptance Criteria

- A test proves critique never uses the same provider that generated the Direction, unless explicitly overridden.
- A test proves two disagreeing critique rounds both get recorded (not collapsed into one averaged verdict).
- A test proves the "retain existing creative" verdict is offered when `baselineRef` is set and omitted when it is `null`.
- `node --test test/critique.test.js` passes with stub providers only.

## Phase 5 - Storyboard-to-Visual-Direction and Independent QA Rubric

<!-- runner:read=lib/providers -->
<!-- runner:verify=node --test test/qa.test.js -->

### Requirements

- For each `keep`-verdict Direction, expand its storyboard shots with concrete visual-style direction per shot: style references, pacing notes, on-screen text, sound-design cues — explicit enough that a human (or a future pod2vid provider adapter) could brief a visual generator from it without further interpretation.
- Implement the independent QA rubric from `docs/e3d-corp-pilot-cast-ad-outcome-loop-spec.md` §4: stop-scroll hook, narrative arc, clarity of value prop, authenticity, production-quality expectation, factual defensibility, brand fit, CTA strength, audience fit. QA scoring must use a *third* call, separate from both generation and critique, so no single call grades its own output.
- QA output must include the explicit disclaimer text (not just doc-level prose) that a rubric score is a heuristic, not evidence of conversion — surfaced in the CLI's human-readable output, not buried only in JSON.

### Acceptance Criteria

- A test proves QA scoring is invoked with neither the generation nor critique provider/call context reused verbatim (fresh call).
- A test proves every QA output includes the heuristic disclaimer string.
- `node --test test/qa.test.js` passes with stub providers only.

## Phase 6 - Output Packaging and Downstream Compatibility

<!-- runner:read=lib/schema -->
<!-- runner:verify=node --test test/package.test.js -->

### Requirements

- `bin/e3d-creative package <direction.json> --out <dir>` produces two things per Direction: (1) the full rich artifact (script, shot-by-shot visual direction, QA scores) as the durable record, and (2) a `cast-compatible.json` reduction shaped to match `e3d-cast`'s existing `cast_job` manifest `input: {kind: "transcript", text: ...}` field — today's only consumable path into the existing pipeline, per `e3d-cast/src/worker/index.js`.
- The reduction must explicitly mark what it drops: a top-level `unconsumedByCurrentPipeline: ["shot.visualDirection", "shot.audioNotes", ...]` field listing exactly which rich fields have no consumer yet. Never silently collapse the shot-by-shot visual direction into nothing with no record that it existed.
- `--list` output (matching s2c's and e3d-pilot's own CLI convention) showing each Direction's id, verdict, QA score summary, and digest, scannable without opening files.

### Acceptance Criteria

- A test proves the `cast-compatible.json` reduction validates against e3d-cast's manifest shape (static shape check, no live e3d-cast call).
- A test proves `unconsumedByCurrentPipeline` lists every rich field that didn't make it into the reduction, for a fixture with a non-trivial storyboard.
- `node --test test/package.test.js` passes with no network access.

## Phase 7 - End-to-End Offline Run and Documentation

<!-- runner:read=README.md -->
<!-- runner:verify=node --test test/e2e.test.js -->

### Requirements

- `bin/e3d-creative run <brief.json> --out <dir>` chains Phases 3-6 end to end against stub providers in tests, real providers in actual use.
- `README.md`: brief schema, direction schema, CLI commands, provider configuration (env vars / key-file path), and an explicit statement of this repo's scope boundary (no rendering, no e3d-corp integration, no spend authority) matching this spec's Non-Goals.
- A worked example brief (e.g., a fictional/sanitized version of the OppScan HVAC case) committed under `examples/`, runnable against stub providers as a smoke test.

### Acceptance Criteria

- `bin/e3d-creative run examples/sample-brief.json --out /tmp/e2e-test` with stub providers produces `>=3` directions, at least one `keep` verdict, QA scores, and a `cast-compatible.json` with populated `unconsumedByCurrentPipeline`.
- `node --test test/e2e.test.js` passes with no network access, matching every prior phase's test discipline.
- README accurately describes current scope with no forward-looking claims about capabilities this ticket doesn't build.

## After This Ticket (not in scope here)

- Wiring e3d-corp's "commission creative directly" Proposal type (see manifesto §3) to call this engine.
- A new `e3d-pod2vid` provider adapter capable of consuming `shot.visualDirection` instead of discarding it — the actual fix for "looks like the 80s."
- Ingesting this spec and its outcome into e3d-pilot's provenance-tracked idea ledger via `ideas ingest` + real `negotiate`/`review` rounds, once this document is reviewed.
