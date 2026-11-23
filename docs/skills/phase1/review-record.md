# Phase 1 review record

Three independent read-only reviews were run on PR #92 (architecture, security/privacy, implementation and evaluation design), each by a separate agent given the files and not the author's conclusions.
They are model reviews, not the human approvals the exit gate requires; the sign-off table in `../README.md` is still open.

| Finding | Review | Disposition |
| --- | --- | --- |
| New `content_hash` collides with the existing MCP `content_hash` (folder hash) | architecture, blocking | Fixed: new hash is `definition_hash`; receipts record `verified_hash_kind` (ADR-0003) |
| Model hints and max_words in unhashed `extensions` | architecture, blocking | Fixed: first-class hashed fields `model_hints`, `limits.max_words` (ADR-0002) |
| Projection limits too narrow, undefined version/overflow cases, `max_model_calls` wrong | architecture | Fixed: schema widened to engine limits; overflow and version rules; `max_model_calls = 0` (ADR-0002) |
| Schemas could not express optional capabilities, node fallback, `on_seat_skill_failure`, plan-to-seat link; `after_round` accepted against ADR-0006 | architecture | Fixed in schemas and fixtures |
| Override-by-name vs id pins; prompt labels vs byte-identical prompt; `experts`/`skills`/`skill_attachments` interaction | architecture | Decided in ADR-0014, 0002, 0005; compat test also pins tool input property names |
| Hash-line stripping bypass (finding F-2): reproduced independently | security, should-fix | Recorded (grounding item 12, threat T19, ADR-0003); fix in Phase 2 |
| Delimiter spoofing (T3): confirmed | security | Recorded; fix in Phase 2 |
| Unicode/control characters, TOCTOU, referent drift, mutable name/description, status live check, `extensions` bound, `signature`, error `details` caps, lone surrogates | security | Fixed in schema/reference (text pattern, NFC, extensions strings only, signature null, caps) or recorded as controls (threat T20 to T23) |
| Brain destination rule unenforceable without taint | security | Fixed in ADR-0008 (`audience_ceiling` in receipt and schema) |
| Retention ambiguities, ledger vs deletion | security, architecture | Clarified in ADR-0011 (tombstones, which retention applies) |
| Validator accepts `constructor`/`toString` keys (prototype lookup) | implementation, blocking | Fixed (`Object.hasOwn`), fixture `prototype-key` added, would have failed before |
| Static check of every schema; `x-code` only on leaves; `$ref` with siblings | implementation | Added to the harness (the first attempt at text limits did silently lose siblings; caught by a fixture, then guarded) |
| Evaluation cross-field rules (inverted interval, status without approved rubric) | implementation | Reference semantic check and fixtures |
| compat test inherited ambient `E3D_MCP_*`; fixed sleep | implementation | Fixed: clean `env -i`; clear error on empty output. The 2-second wait remains (timing assumption noted) |
| Evaluation design: power claim, effective n, non-stratified split, multiplicity, undefined parameters, volume bias, interval method, forking paths | implementation | Rewritten (evaluation-freeze.md): one primary test, Holm for the rest, stratified salted split, 90 tasks, minimum detectable effect, defined metrics and analysis, signed tag |
| Goldens were stale at the start of this phase, weakening the H5 story | implementation, nit | Stated in the PR; refreshed in `bc68f1b` with a 12-line additive diff |

**Not resolved by this phase (open risks):** the numbers in ADR-0010 and ADR-0011 and the evaluation thresholds need the owner; the compat test depends on `jq` and `node` and a 2-second server start; homoglyph attacks are accepted and shown in preview, not prevented; the hosted claims rest on a private appendix reviewers of the public PR cannot see; the first-draft statistical design had material flaws that these reviews found, so the revised freeze deserves a human statistician's read before approval.
No UX review was run: Phase 1 has no user interface.

## Skills phase 2a (expert-loader hardening): independent review

One read-only Sonnet reviewer tried to break the change (F-2, T3, T20, T21). Findings and dispositions:

| Finding | Severity | Disposition |
| --- | --- | --- |
| B1: oversized files read into memory before the limit applied (regression; a 1.5 GB sparse file used 1.67 GB) | blocking | Fixed: bounded read, size checked before reading, no duplicate `too_large`; tests |
| B2: hidden-character class missed Unicode tag characters, C1 controls, variation selectors, separators, invisible fillers (the schema had the same gap) | blocking | Fixed in the loader (Cc, Cf, Zl, Zp and explicit lists) and in the schema `text` pattern; fixture `skill-definition--tag-characters` |
| S1: hash-looking line inside a YAML block scalar was stripped | should fix | Fixed: only the `metadata:` map loses its hash line |
| S2: a file swapped for a FIFO after listing could hang the read | should fix | Fixed: non-blocking open, regular-file check |
| S3: `O_NOFOLLOW` covers only the last path component | should fix | Fixed by a real-path containment check before opening; a swap between check and open stays a documented residual race |
| S4: delimiter lookalikes (spacing, NBSP, tab, full-width bracket, unclosed start marker) passed | should fix | Fixed in validation and neutralisation |
| S5: zero-width joiners and non-joiners refused (emoji sequences, Persian and Indic text) | decision | Kept the blanket refusal (matches the schemas); documented in `docs/experts.md`; **owner decision** whether to relax it |
| N1 to N5 | nit | N1 (misleading `missing_skill_md`), N2 (growing file), N4 (Windows caveat documented), N5 (brittle and missing tests) addressed |

`tests/specialists-hardening.sh` has 56 cases; 30 of the cases for the review findings fail on the code before the fixes.

## Skills phase 2b (local skills runtime): independent review

One read-only Sonnet reviewer attacked the runtime (loader, resolver, export, CLI wiring, stdio MCP tools, receipt). No blocking finding on the flags-off path. Findings and dispositions:

| Finding | Severity | Disposition |
| --- | --- | --- |
| S1: a skill's text could forge a list row or a fake notice in the MCP answer, and close its own `"""` frame | should fix | Fixed: one-line descriptions, a fence longer than any backtick run in the text, notice before and after |
| S2: a repo folder could choose `owner_ref` (lookalikes of `e3d`, `local-user` vs `local_user`, `__proto__`) and shadow another tier's id | should fix | Fixed: the owner belongs to the tier; a folder may only restate it; export omits `owner_ref` |
| S3: `tool_enabled` and `learning` skills accepted, and the tool text said "requests no capability" | should fix | Fixed: only `instructional` is accepted in this release (`skill_capability_denied`); the text is built from the data |
| S4: every MCP call rescanned all folders without a cap | should fix | Fixed: 200 folders per tier, 100 skills per list, 3 s catalogue cache |
| S5: a long name leaked a temp path in an error | should fix | Fixed: name length checked, fixed error message |
| S6: an empty `--skill-hash ""` silently dropped the pin | should fix | Fixed: pins are validated and an empty pin is refused |
| S7: a bare name resolved to a folder in the current directory | should fix | Fixed: only path-like arguments are folders |
| S8: the receipt re-read the folder | should fix | Fixed: the entry says `changed_since_load` when the bytes differ from those the panel was planned from |
| S9: withdrawn skills still resolved; pins do not cover `status` | should fix | Fixed: `skill_withdrawn` refuses them, `deprecated` is flagged; documented that pins cover meaning, not status |
| N1 N2 N3 N4 N5 N6 N7 | nit | Fixed (safe printing, name not an id, normalised empty lists, missing-value messages, `--` before values, pin/action check, lazy import of the MCP tools) |
| N8 tier directory that is a symlink is followed | nit | Accepted: users symlink their skills folder from a dotfiles repo; only skill-shaped folders are read |
| N9 `readOnlyHint` on validate/export (they use a temp folder) | nit | Accepted: they change nothing the user owns |
| N10 export leaves a folder on a round-trip failure | nit | Accepted: the error says where, for inspection |

`tests/skills-runtime.sh` now has 47 library cases; the cases for these findings fail on the code before the fixes.

**Not independently reviewed:** the advisory scanner (`lib/skills/scan.mjs` and its wiring into the commands and MCP tools) was added after this review, at the owner's request (ADR-0015 item 6). It is tested (82 library cases: every rule, benign near-misses, the ten built-ins scanning clean, worst-case inputs at the size limit, and the wiring), but no separate reviewer has attacked it. Because it is advisory and never blocks, its failure modes are false negatives and false positives, not a bypass of a control.

## Skills phase 3a (plan layer, seat skills, preview, plan digest): independent review

One read-only Sonnet reviewer attacked the planner changes, the digest, the bash wiring and the receipts.

| Finding | Severity | Disposition |
| --- | --- | --- |
| B1: a broken user or repo skill was silently replaced by the built-in of the same name, with the run reporting success (the fail-by-default policy did not apply) | blocking | Fixed: `skill_invalid` (a new stable code) names the broken folder and the run stops, or that seat runs plain under `plain_seat`; a merely invalid skill is no longer reported as "not found" |
| S1: the digest ignored `--prompts`, `--approach`, `--web-search`, `--recap`, `--jev` and the synthesis settings, so `--expect-plan` could be bypassed | should fix | Fixed: those settings are in the digest; the docs list what is and is not covered |
| S2: `E3D_SKILLS_V1=1` made previously valid runs fail (`--max-words 5`, `--rounds 11`, a synthesizer name with an underscore, huge numbers) | should fix | Fixed: the preview never fails on request values the debate checks itself; schema ranges widened; bad values are replaced by defaults with a warning |
| S3: the call estimate looked like a bound but ignored retries | should fix | Fixed: nominal calls, the real retries per call and what adds more are shown |
| S4: folder names with escape sequences and newlines reached the readable preview | should fix | Fixed: warnings and conflict text are reduced to printable ASCII |
| S5: when every seat skill failed under plain_seat the error was misleading | should fix | Fixed: an explicit refusal naming the codes |
| N1 (`--lens-bytes-max` with seat skills), N2 (version-only pin caveat), N6 (constraints not sent) | nit | Fixed or documented, with a preview warning for N6 |
| N3 (lens size clamp), N4 (failed skills digest alike), N5 (plain seats count toward families), N7 (named-twice message) | nit | Accepted: the digest stays safe, the run is identical, and plain seats are real seats on real providers |
| N8 (weak plain-seat and preview tests) | nit | Fixed: the plain seat's own prompt is checked, the preview creates no output directory, and the bypass cases are covered |

`tests/skills-plan.sh` now has 21 library cases plus the end-to-end cases; the eight review-finding cases fail on the code before the fixes.

## Skills phase 3b (debate observer): independent review

One read-only Sonnet reviewer attacked the observer: prompt and fence design, reply checks, the bash wiring, process handling, the receipt and the tests.

| Finding | Severity | Disposition |
| --- | --- | --- |
| B1: "the observer has no tools" was only a sentence in the prompt; the `claude` adapter runs with tools on unless told otherwise, so injected debate text could reach a model with real tools | blocking | Fixed: a per-adapter tool policy (`claude` with `CLAUDE_TOOLS=""`, plain API adapters allowed, every adapter with tools refused before any call, an operator allow-list); the docs say what is enforced |
| S1: an orphaned `sleep` after every normal run, and orphaned grandchildren after a kill | should fix | Fixed: the adapter runs under a supervisor in its own process group, killed on the deadline and after exit; tested with real grandchild processes |
| S2: Ctrl-C did not stop the observer's tree | should fix | Fixed and tested for SIGINT and SIGTERM |
| S3: model text starting with `## Round N -- x` could replace a participant's position or the verdict the observer sees, inflate the prompt, or fill the participant cap | should fix | Fixed: the data comes from the engine's own answer files and the synthesis, validated and bounded; participant names are checked; tested with a hostile debate |
| S4: C1 controls, zero-width and bidirectional characters, U+2028 and a blank-looking reply passed | should fix | Fixed: all control, format, separator and zero-width characters are replaced; emptiness is checked after |
| S5: the report on stdout changed what consumers that parse the verdict to the end of the stream see (`DISSENT:` lines in a report) | should fix | Fixed: the report goes to stderr and files; stdout is byte-identical, tested |
| S6: `limits.max_input_bytes` was never enforced | should fix | Fixed: the prompt is cut to fit, and nothing is sent if the skill's own text is over |
| S7: the cut report exceeded the limit by the marker | should fix | Fixed: the cut includes the marker |
| S8: the receipt did not bind the data and the prompt the observer read | should fix | Fixed: `input_refs` carry both digests and a reproducible debate id |
| S9: a stale report survived a failed run in a reused folder | should fix | Fixed and tested |
| N1 (killed-by-signal ambiguity), N3 (a directory passes `-x`), N5 (shared temp name for the receipt merge) | nit | Fixed (the supervisor knows a timeout; `-f` and `-x`; a unique temporary name) |
| N2 (the digest differs with `--seat-skill` plus `--observer`), N4 (the fence echo check is a literal substring) | nit | Accepted and documented |

Test gaps closed: impersonation, huge names, C1 and zero-width characters, a whitespace-only reply, the per-token refusal (exercised through the real engine), the prompt-time pin check, a failed synthesis, no output directory, a tool-capable adapter, and leaked processes.

## Phase 3c H1 (hosted skill intake) independent review, 2026-11-23

Reviewer: an independent read-only Sonnet agent, with reproducing scripts and a mutation run. Scope: `lib/skills/intake.mjs`, its tests, and the export of `hasHiddenCharacters`. No blocker. Should-fix findings and outcome:

| Finding | Class | Outcome |
| --- | --- | --- |
| S1: the accepted entry kept the caller's own object, which every check read again (a getter or a later mutation could change what was accepted) | should fix | Fixed: one pass bounds and copies the value; every check and the entry use the frozen copy; accessors, holes and Proxies are refused |
| S2: `JSON.stringify` ran before any cap (a shared-reference DAG or a huge sparse array cost seconds and memory) | should fix | Fixed: the bounded copy runs first, counts nodes and bytes, and refuses shared references; tested for a DAG and a sparse array |
| S3: the `scopes` argument was not validated (a string or an object with `includes` admitted anything) | should fix | Fixed: a non-empty list drawn from the two known scopes, else `skill_scope_denied`; `null` options no longer throw |
| S4: hidden characters, non-NFC text and lone surrogates passed in unhashed fields (extensions, license, tasks, provenance); a sender could choose provenance and a legacy folder hash that reached the observer plan | should fix | Fixed: every string and key in the copy is checked; provenance is rewritten by the engine |
| S5: a hosted entry did not work with the plan preview (the tier was not in the preview schema) and `findSkill` keyed on provenance | should fix | Fixed: `hosted` added to the preview schema (both copies kept identical); `findSkill` matches a hosted skill on its own recomputed hash |
| S6: a hosted skill could be reached by a bare name, and two owners with one slug resolved by array order | should fix | Fixed: a hosted skill resolves only by its full id; a multi-owner catalogue still must not be built |
| Nits: `String()` on a null-prototype status threw; the shared `warnings` array | nit | Fixed |

Test gaps closed by mutation: hidden characters, NFC, owner pattern, scopes, provenance rewrite, freezing and the hosted preview and resolution are each pinned by a case that fails when the check is removed. Overlapping layers (key count, array length, accessor refusal, a small shared reference) are caught by another layer as well and stay as defence in depth.

## Phase 3c H2a (hosted skills in the debate) independent review, 2026-11-23

Reviewer: an independent read-only Sonnet agent, with reproducing scripts and 24 mutations. Scope: `lib/skills/hosted.mjs`, `--hosted-skills` in `bin/e3d-debate`, `specialists-cli.mjs`, `observer.mjs`, and the tests. No blocker. Findings and outcome:

| Finding | Class | Outcome |
| --- | --- | --- |
| S1: unquoted command substitutions passed the file path to the observer: a space broke it, and a glob such as `g[a]*.json` made the observer read a DIFFERENT file than the one validated | should fix | Fixed: the path is one quoted array argument everywhere; tested with a space and a glob |
| S2: a hosted observer could not record its result (the run record required a legacy folder hash that a hosted skill does not have) | should fix | Fixed: the field is optional; end-to-end hosted observer test asserts `observers.json` |
| S3: `--on-seat-skill-failure plain_seat` let a failed hosted skill run as a plain seat | should fix | Fixed: refused in `bin/e3d-debate` and in the planner (two layers, both tested together) |
| S4: a hosted file nothing used was never validated, and an empty path counted as absent | should fix | Fixed: the file is read and checked once at start, before anything runs; an empty path is refused |
| S5: the file was opened by path after the size check | should fix | Fixed: one descriptor opened without following symlinks, checked with `fstat`, read at most the cap plus one byte |
| Nits: identifiers (not text) appear in the receipt, transcript and panel line; a skill declaring both hooks can be a seat and the observer in one run | nit | Accepted and noted for the cloud: publishing a debate that used private skills is the owner's explicit choice, with a preview of the names that appear; skill text is never part of it (plan section 7); whether seat plus observer on one skill is priced twice is a cloud question |

Test gaps closed: a hosted observer end to end, a space and a glob path, `plain_seat`, an unused bad file, an empty path, the lens-size limit with a hosted skill, and the observer plan and prompt receiving the file. Overlapping layers (the two `--builtin-only` checks, the two `plain_seat` checks, the two size checks, the symlink guard) are pinned together by mutation.

## Phase 3c H2b (observer in a per-token debate) independent review, 2026-11-23

Reviewer: an independent read-only Sonnet agent, with reproducing scripts and about 24 mutations. Scope: the quoted observer limits, the usage row and the stop handling in `bin/e3d-debate`, and `lib/skills/observer.mjs`. One billing blocker, three should-fix:

| Finding | Class | Outcome |
| --- | --- | --- |
| B1: an observer call killed by the skill's own deadline (exit 124) wrote no usage row, so a call the vendor may have billed was undercounted and the platform would refund the whole reserve | blocker | Fixed: a deadline or signal exit is reported as an `inflight` row at the quoted output limit; test with a skill `timeout_ms` below the vendor's delay |
| S1: a SIGTERM between the call finishing and the row being written left the call unreported | should fix | Fixed: the stop phase stays set until the row is written (a late stop gives an inflight row or the vendor's counts). Not tested deterministically: the window is milliseconds and a test would need a seam in production code |
| S2: the observer's row carried the search-mode `searches` field (null) although it never searches | should fix | Fixed: an observer call is never a search call (`searches` 0); test with search quoted and a caller exporting search settings |
| S3: with `retry_once` and an unusable reply in a per-token debate, the failure was not recorded in `observers.json` or the receipt | should fix | Fixed: the one allowed attempt is final and is recorded as a failure; the test asserts both files |
| Nits and test gaps: the input bound was only checked in characters; the leftover-process case; the exported search settings | nit | Tests added: the bound is measured in bytes (also with multibyte text), no observer process outlives a stopped debate, the observer request carries no search tool |

Process note: a mutation run was started in the background and overlapped with other commands that read the same files; the run was stopped and the files were verified against the intended diff before continuing. Mutation runs are run in the foreground, alone, from now on.

## Phase 3c H2c (hosted skills on the run listener) independent review, 2026-11-23

Reviewer: an independent read-only Sonnet agent, with reproducing scripts and 9 mutations. Scope: `lib/mcp/{pricing,run-server,runs,usage}.js`, `bin/e3d-mcp` and the tests. No blocker; no way found to inject an argument, change a provider, break the pin grammar or cross tenants. Six should-fix, all addressed:

| Finding | Class | Outcome |
| --- | --- | --- |
| S1: a `skill_bytes` equal to the instruction bytes was accepted, then the engine refused after the hold (the lens block carries a wrapper of about 170 bytes) | should fix | Fixed: each seat skill's lens block, wrapper included, must fit `skill_bytes` at plan time; test |
| S2: an observer skill name over 64 characters made its usage row unreadable for billing | should fix | Fixed: refused at plan time; test (a 70-character name) |
| S3: a definition nested thousands of levels deep gave a retryable 503 | should fix | Fixed: iterative depth bound (16) before any recursion, and the key computation can no longer throw; test at 3000 levels |
| S4: the daily-budget estimate ignored the observer call and the lens bytes | should fix | Fixed: `skillsExtra` adds the observer call, its quoted input and output, and the lens bytes per seat per round; unit-tested. The wiring into the estimate is covered by the end-to-end runs, not by its own assertion |
| S5: the conflict test passed for the wrong reason; the crash-recovery scrub was untested | should fix | Fixed: the second definition now has a real hash; a killed process is restarted and its stored state is checked for skill text |
| S6: no principal binding; a stale private file after SIGKILL; a restart is not a kill switch | should fix | Stale file: swept at start (old, private, ours, the file only; a young directory is kept; tested). Kill switch: a run accepted with skills that is resumed while the skills switch is off is not run (code; **not covered by a test**, the scenario needs a queued run across a restart). Principal binding stays documented: isolation depends on the trusted caller passing the right principal, to be bound to the authorize-run principal in the cloud (C2) |
| Nits | nit | Accepted: the redundant target check, the broader 256 KiB limit when skills are on (only on the authenticated run route), the observer row not matching its provider (only the engine writes it) |

Known gaps: the kill-switch path above; a request with exactly one seat attachment is still refused by the listener (the engine half of the single-seat change is separate and the listener half follows it).
