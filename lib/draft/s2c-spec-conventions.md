# spec2code Spec Conventions (bundled copy)

Bundled from `spec2code`'s README (`Spec Format` and `Spec Annotations`
sections, runner version `0.3.0`) so the draft stage always has this contract
available even when s2c isn't checked out at a known path. If s2c's own README
changes, update this file to match.

## Spec Format

The spec should be Markdown with phase headings that include a phase number:

```md
## Phase 1 - Historical Replay
## Phase 2 - Walk-Forward Validation
## 6. Phase 3 - Execution Simulation
```

The runner extracts each phase section from its heading until the next phase heading.
Phase metadata is parsed once per runner process, sorted numerically, and duplicate phase numbers fail before the provider is launched.

## Spec Annotations

Specs can override a phase model, add extra read files, and include verification hints with HTML comments inside the phase body:

```md
## Phase 2 - Report Writer

<!-- runner:model=mini -->
<!-- runner:read=docs/reporting-notes.md -->
<!-- runner:verify=bash tests/reporting.sh -->
```

- `runner:model` overrides heuristic routing for that phase across providers
- `runner:read` adds files to the "Read first" block
- `runner:verify` tells the provider what to run and is rerun independently by the runner after a successful phase
- legacy `codex:*` annotations are still accepted; `codex:model` only applies when `PROVIDER=codex`

`runner:model` must name a provider s2c's execute step actually dispatches: today that is only `codex` or `claude` (for example `runner:model=codex:gpt-5.6-sol`). Never use a bare tier name alone without confirming it resolves under the target provider, and never invent a third provider name.

**`runner:model=claude:*` is safe to use again as of 2026-10-11.** s2c's `claude` provider path (`run_claude_phase` in `spec2code`) used to invoke `claude --print --permission-mode default` with no TTY to approve tool calls, so every `Edit`/`Write` the model attempted was silently denied while the process still exited 0 -- the phase reported success with zero files changed and no provider-authored handoff. This happened for real on idea-17100e68160f's Phase 1 (`e3d-oppscan`, run `impl-17100e68160f-repo-20260922164753`, 2026-09-22) and blocked the whole implementation. Fixed in `spec2code` commit `e34bcd4`: `CLAUDE_PERMISSION_MODE` now defaults to `bypassPermissions`, confirmed end-to-end against the real `claude` binary (2.1.296) both standalone and through `spec2code`'s own phase runner. Mixing `codex:*` and `claude:*` phases in one spec is supported (`tests/phase-13-mixed-provider-spec.sh`).

Codex model availability depends on how this machine's Codex CLI is authenticated (ChatGPT account vs. API key) and changes over time as OpenAI deprecates or renames models — a model that worked previously can start failing with "model not supported" or a 404 with no warning. Do not copy a `codex:<model>` string from this file, from an old spec, or from memory without checking it is still current: read the most recent successful rows in `.spec2code/manifest.tsv` (same directory as this file's parent's `.spec2code/`) for the last model that actually completed a phase, or run `codex exec --model <model> -` with a trivial prompt and confirm it returns normally before drafting a phase annotation that depends on it. `gpt-5.5` and `gpt-5.4-mini` are both confirmed non-working under a ChatGPT-authenticated Codex CLI as of 2026-09; treat any specific model string in this file, including the example above, as illustrative only, never as a verified-current default.
