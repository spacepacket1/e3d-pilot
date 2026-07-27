# e3d-pilot

`e3d-pilot` is a repo-agnostic, Bash-first agentic loop that researches what a repository should do next, negotiates a runnable specification, executes it in an isolated worktree through [codex-spec-runner](https://github.com/spacepacket1/codex-spec-runner), verifies the result, and stops at a draft PR or local review branch. It never merges.

## Requirements and installation

Install Bash, Git, `jq`, `curl`, and `codex-spec-runner`; install and authenticate whichever model CLIs and forge CLI your configuration uses. Add this repository's `bin` directory to `PATH`:

```bash
git clone https://github.com/spacepacket1/e3d-pilot.git
export PATH="$PWD/e3d-pilot/bin:$PATH"
e3d-pilot --help
```

## Configure a repository

Create `.e3d-pilot/config.json` in the target repository. Start from [`examples/sample-config.json`](examples/sample-config.json). The fields are:

- `verify`: commands run in the execution worktree before publish. An empty list is auto-detected from `package.json`, `requirements.txt`, or `Makefile`.
- `protected_paths`: globs that generated specs and execute-time guards reject.
- `research_topics`: hints for discovery research.
- `providers`: provider names for `discover`, `ideate`, `draft`, ordered `negotiate` reviewers, and independent `review`.
- `max_diff_files` and `max_diff_lines`: actual post-execution ceilings.
- `docs`: optional guidance-document path; otherwise common filenames are detected.
- `live_verify`: optional `{ "command": "..." }` hook. It runs only when repository docs identify a supported E3D paid-API surface and `e3d-agent` is available; otherwise it is skipped.
- `pr`: `base_branch`, draft flag, labels, and backend (`auto`, `github`, or `local`).

Validate and run:

```bash
e3d-pilot config validate /path/to/repository
e3d-pilot run --repo /path/to/repository --stage all
```

## Runs and stages

Generated state lives in the target repository at `.e3d-pilot/runs/<run-id>/`. `discover` and `all` without `--run-id` create a collision-safe new run and update `.e3d-pilot/latest-run`. Other standalone stages resume that latest run. Pass `--run-id ID` to resume a specific run.

The pipeline is:

1. `discover` writes `findings.md` from Git/repository facts and external context.
2. `ideate` writes ranked, deduplicated `candidates.md`; `selected: none` stops cleanly.
3. `draft` writes a CSR-compatible `spec-draft.md` with explicit touched-path annotations.
4. `negotiate` sequentially asks every configured reviewer to approve or replace the current draft. All must approve in one unchanged pass; otherwise bounded rounds end in “needs human.” Success writes `spec-final.md`.
5. `execute` creates `e3d-pilot/<run-id>` in a separate worktree, invokes CSR, captures its state, and enforces protected paths and diff ceilings.
6. `review` runs verification commands and asks the configured review provider to inspect the diff independently.
7. `publish` commits narrowly scoped audit artifacts and uses a publish backend.

Create `.e3d-pilot/paused` to stop stages before external work.

## Providers and negotiation

Built-in adapters are `claude`, `codex`, and `local`; check them with `e3d-pilot providers list`. The local adapter needs an OpenAI-compatible endpoint:

```bash
export LOCAL_MODEL_ENDPOINT=http://localhost:11434/v1
export LOCAL_MODEL_NAME=my-model
```

Then add `"local"` anywhere in `providers.negotiate`; reviewer count is not hardcoded. A configured unavailable reviewer fails fast and is never silently skipped.

The execute stage is intentionally limited to providers supported by `codex-spec-runner`—currently Codex and Claude. Adding local execution requires a separate CSR enhancement; e3d-pilot never emits `runner:model=local` today.

## Publishing

`auto` selects `github` for a `github.com` origin and `local` otherwise. GitHub pushes only the run branch and calls `gh pr create --draft`; it never merges or pushes the base branch. Local commits the worktree branch without network access and writes `publish-summary.md`. The scripts in `lib/publish/` share the extension seam for a future GitLab backend.

Only after verification passes, publish force-adds findings, candidates, negotiation log, final spec, and CSR manifest under the run's audit path so summary links resolve on the branch.

## Fleet mode

Provide a JSON array of repository paths:

```bash
e3d-pilot fleet examples/sample-fleet.json
```

Each repository runs independently. Fleet continues after failures, prints a per-repository result and final totals, and exits nonzero if any repository failed.

## Safety model

Execution uses a separate worktree and per-run branch. Protected paths are checked both when drafting and immediately before CSR. Actual file/line ceilings stop before review. Failed verification blocks publish. Publication is draft/local only, with no merge, force-push, or direct base-branch push.

Run the repository test suite with:

```bash
for test_file in tests/*.sh; do bash "$test_file"; done
```
