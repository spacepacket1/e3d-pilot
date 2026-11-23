# ADR-0023: Debate observer runtime

Status: **Owner-decided 2026-11-23** (skills phase 3 plan, decisions D5 to D8 approved as written). Phase: 3b. Builds on ADR-0006 (observer semantics).

## Context

ADR-0006 settled what an observer is: `after_synthesis` only, read-only, never part of the verdict, failure never fails the debate, cost approved separately. Phase 3b makes it run. The new risk is real: the observer reads **model output** (the participants' answers and the verdict), which may carry injection, and it is one more paid call.

## Decision

1. **`--observer <id|name>[@version][#sha256:hash][:provider]`**, behind `E3D_SKILLS_V1=1` and `E3D_SKILLS_OBSERVER=1`, one per debate. The skill must declare the hook `debate_observer/after_synthesis`, be instructional, and allow one model call (`limits.max_model_calls >= 1`). Any problem (unknown, withdrawn, invalid, pin mismatch, wrong hook, no adapter) stops the run **before any call**.
2. **Provider (D7).** An explicit `:provider` wins. Otherwise the first provider in the pool from a vendor family other than the synthesizer's, else another adapter, else the synthesizer itself with a warning that it grades its own verdict. The family is shown in the preview.
3. **Runs after the verdict is printed and stored** (the same place as `--recap`): the stdout up to that point and `transcript.md`, the seat and synthesis prompts, and the decision log apart from the new `observers` key are byte-identical with and without an observer (tested). The report is printed after the verdict under a heading that says it is read-only and not part of it, and written to `observer-<skill>.md` and `observers.json` (atomic: temporary file then rename).
4. **Prompt trust zones (D5).** In order: fixed policy; the task (date, byte limit); the skill, labelled with id, version, hash, tier and scope, closed by a marker carrying a per-run random token; the debate (the user's question, each participant's final answer, the verdict) as **untrusted data inside a fence made of that token**, so nothing in the debate can close or forge it; the output rules. The policy says the data may contain instructions and is not to be followed, and that the observer has no tools. The skill is re-resolved at prompt time and must still match the planned pin.
5. **Reply check (D6).** Valid means non-empty printable text within the skill's `max_output_bytes` that does not contain the fence token (an echo of it is refused). An invalid reply follows the skill's declared `fallback.on_invalid_output`: `return_unstructured_with_warning` returns the text cut to the limit with the error recorded; `retry_once` makes exactly one more call; `fail` records a failure. An empty reply, an adapter error or a timeout is always a failure.
6. **Deadline.** The adapter call runs with the skill's `timeout_ms` as a hard deadline (`skill_timeout`); a killed or failed call leaves no report file.
7. **Receipt.** `observers[]` in `decision-log.json`: a validated `skill-run` record (scope `debate_observer`, hook `after_synthesis`, status, one model call, zero credits, errors with stable codes, the digest of the debate receipt it read, the digest of its report) plus where the report went, a `use_id` and an `attachment_id`. A failed observer is visible on stdout and stderr.
8. **Not available in a per-token (hosted) debate** until the hosted contract exists (3c): the call has no quoted limit, and billing must price it. No observer usage is ever added to `usage.json`.
9. **Preview and digest (D9).** `--preview-skills` lists the observer (skill, adapter, family, limits); the plan digest covers it, so adding an observer or changing its provider invalidates an earlier `--expect-plan`.

## Consequences

`tests/skills-observer.sh` covers the checks, a debate with an observer, the byte-for-byte comparison, every failure mode (adapter failure, empty, over-long, fence echo, deadline, retry), a hostile debate that tries to close the fence, and the preview and digest. Ctrl-C during the observer stops the process like any other call; nothing partial is written. The observer shares the process environment of the debate; it has no tool of its own, but an adapter is trusted code, as for every other call.

## Alternatives considered

Interleaving the observer into the synthesis (changes the verdict and its cost); a fixed delimiter instead of a per-run token (forgeable by debate text); letting the observer write structured observations straight into the receipt (a model-chosen record in a trusted file; the report stays text until a reviewed schema path exists).
