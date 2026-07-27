# codex-spec-runner Spec Conventions (bundled copy)

Bundled from `codex-spec-runner`'s README (`Spec Format` and `Spec Annotations`
sections, runner version `0.3.0`) so the draft stage always has this contract
available even when csr isn't checked out at a known path. If csr's own README
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

`runner:model` must name a provider csr's execute step actually dispatches: today that is only `codex` or `claude` (for example `runner:model=codex:gpt-5.4-mini` or `runner:model=claude:sonnet`). Never use a bare tier name alone without confirming it resolves under the target provider, and never invent a third provider name.
