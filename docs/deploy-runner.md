# Deploying e3d-pilot to a runner machine

e3d-pilot pushes branches, opens draft PRs, and runs model/CLI calls
unattended — it shouldn't run on a production server. This doc is a
copy-pasteable prompt for briefing a fresh Claude Code (or similar agent)
session on a separate, dedicated runner machine: clone the repo, install
dependencies, get credentials from you interactively, do one supervised dry
run, and only then set up a cron schedule.

It intentionally doesn't hardcode which target repo(s), which model
providers, or which publish backend to use — the agent following it is
expected to ask you those questions rather than guess.

---

```
Set up e3d-pilot on this machine and get it running on a schedule.

Context: e3d-pilot is a Bash CLI that autonomously researches a target git
repo, proposes an idea, gets independent AI models to agree on a spec,
executes it via codex-spec-runner in an isolated worktree, verifies the
result, and opens a draft PR (or leaves a local review branch) — it never
merges anything itself. This machine is a dedicated runner for it, separate
from any production server. Full docs: https://github.com/spacepacket1/e3d-pilot
(public repo, no auth needed to clone it) — read its README.md first, it's
authoritative for anything this prompt doesn't cover.

Do not guess at, invent, or default any of the choices below — ask me
directly and wait for my answer before proceeding. Treat installing a cron
job, and the first real (non-dry-run) e3d-pilot run, as actions to confirm
with me before doing, same as you would a push or a force-reset.

## 1. Install prerequisites

- Bash, git, jq, curl
- GitHub CLI (`gh`) — then run `gh auth login` interactively with me and
  confirm `gh auth status` succeeds before moving on. e3d-pilot itself is
  public now (no auth needed just to clone it), but `gh` auth is still
  required for any target repo that uses the `github` publish backend
  (pushing branches, opening draft PRs, listing issues/PRs for dedup).
- codex-spec-runner: clone https://github.com/spacepacket1/codex-spec-runner
  and put its `bin/` on PATH. e3d-pilot's execute stage shells out to it via
  `command -v codex-spec-runner`, so it must resolve on PATH, not a fixed
  path.
- Ask me which model CLI(s) I want available — `claude`, `codex`, or a
  self-hosted OpenAI-compatible endpoint (e3d-pilot's "local" provider) — and
  install/authenticate only those:
  - `claude`: install, then get it authenticated (ask me how I want to
    authenticate on this machine — subscription login vs. an API key).
  - `codex`: install, then get it authenticated (ask me the same question).
  - local model: ask me for the endpoint URL and model name; these become
    `LOCAL_MODEL_ENDPOINT` / `LOCAL_MODEL_NAME` env vars. Note today's local
    provider adapter sends no auth header, so this only works against an
    endpoint that doesn't require one (or ask me if that needs changing).

## 2. Clone and install e3d-pilot itself

```bash
git clone https://github.com/spacepacket1/e3d-pilot.git
```

Add its `bin/` directory to PATH permanently (shell profile, not just the
current session). Confirm `e3d-pilot --help` works and `e3d-pilot providers
list` reports the providers we just set up as available.

## 3. Ask me for the operational details, then configure

Ask me, explicitly, one at a time if that's easier:

- Which target repo(s) should e3d-pilot run against? (path or clone URL for
  each — this is probably NOT the e3d-pilot repo itself)
- Fleet mode (multiple repos via a JSON array) or a single repo?
- For each target repo: what should `verify` run, any `protected_paths` to
  never touch, `research_topics` / `analogy_domains` hints, which provider(s)
  for `discover`/`ideate`/`draft`/`negotiate`/`review`, `max_diff_files` /
  `max_diff_lines`, and `pr.backend` (`auto`, `github`, or `local`).
- Do I want email notifications on publish (`notify.email`)? If yes, get the
  `to` address and how mail should actually send — is a local `mail`/
  `sendmail`/`msmtp` already configured on this machine, or do I want a
  custom `notify.email.command` (e.g. hitting SES/SendGrid)? If the latter,
  ask me for whatever API key/credential that needs, and set it as an
  environment variable available to the cron job's environment — never
  written into `.e3d-pilot/config.json` or committed anywhere.
- What cadence do I want (hourly/daily/etc.), matching the README's "Running
  on a schedule" section.

Write each target repo's `.e3d-pilot/config.json` from
`examples/sample-config.json`, then run `e3d-pilot config validate <repo>`
and fix anything it flags before moving on.

## 4. Do one supervised dry run before scheduling anything

Run `e3d-pilot run --repo <repo> --stage all` once, watched, for each target
repo (use `E3D_PILOT_GITHUB_DRY_RUN=1` first if you want to see the exact
push/PR commands without actually pushing). Walk me through what it
produced — findings, the selected candidate and why, the negotiation
outcome, and (if it got that far) the branch/PR it opened — before trusting
it to run unattended. If it stops partway (nothing-to-do, needs-human,
verify failed), show me why rather than treating it as broken.

## 5. Only after I've confirmed the dry run looks right, set up the schedule

Follow the README's "Running on a schedule" section (cron examples for both
fleet mode and a single repo). Confirm the exact crontab line with me before
installing it. Mention `.e3d-pilot/paused` as the kill switch (drop that file
in a target repo to make its scheduled runs a no-op without touching cron).

## 6. Wrap up

Summarize: what's installed and authenticated, what config was written for
each target repo, what the dry run showed, and the exact cron schedule now
installed. Flag anything you had to skip because I didn't have an answer or
credential ready yet.
```
