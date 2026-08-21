# Grok Build in e3d-pilot

## Status and recommendation

Grok Build is a **normal optional provider**, selected the same way as
`claude`, `codex`, `devin`, or `local`: name `"grok-build"` in
`providers.discover`, `ideate`, `draft`, `negotiate`, or `review`. It is
available when the `grok` binary is on `PATH` (override with `GROK_BUILD_BIN`).
There is no extra feature flag. It is not the default.

The recommended Grok-shaped path is:

1. Keep your existing ideate and negotiate providers.
2. Add optional `candidate_scoring` with `"provider": "grok-build"`.
3. Leave `providers.execute` as `"csr"` (the default).
4. Keep both human gates: `ideas approve`, then `ideas approve-merge`.

Direct `providers.execute: "grok-build"` remains experimental. Benchmark
before claiming cost or quality wins. See
[Grok Build architecture](grok-build-architecture.md) for how this sits on
the existing provider and safety seams.

## Installation and authentication

```bash
curl -fsSL https://x.ai/cli/install.sh | bash
grok --version
grok login --device-auth   # useful on a headless machine
e3d-pilot providers list   # grok-build should report available
```

Alternatively set `XAI_API_KEY` before running Grok. Do not put API keys in
the repository config. e3d-pilot never logs or serializes that variable.

## Configuration

Name `grok-build` anywhere other providers are named. The recommended hybrid
keeps csr as executor and uses Grok for scoring (or as one reasoning stage):

```json
{
  "providers": {
    "discover": "devin",
    "ideate": "devin",
    "draft": "codex",
    "negotiate": ["devin", "codex"],
    "review": "devin",
    "execute": "csr"
  },
  "candidate_scoring": {
    "provider": "grok-build",
    "workers": 3
  }
}
```

The same `candidate_scoring` object is valid in a fleet discover config
(`.e3d-pilot-fleet/config.json`).

`candidate_scoring` is omitted by default. `provider` may be any adapter under
`lib/providers/`; `grok-build` is one option, not a hardcoded backend.
`workers` must be an integer from 3 to 5 (default 3). Scoring re-ranks
non-duplicate candidates, records the original model pick as `model_selected`,
and never executes.

When scoring runs, the run directory also gets:

| Artifact | Meaning |
| --- | --- |
| `ideate-response.model.md` | Ideate provider output before re-ranking |
| `ideate-scoring.json` | Averaged worker scores and ranking |
| `ideate-scoring-selection.txt` | `selected`, reason, and `model_selected` |
| `ideate-scoring.artifacts/` | Per-worker prompts, stdout, stderr, status |
| `candidates.md` | `model_selected`, `scoring_provider`, and an Ensemble Scoring section |
| idea `scores.ensemble` | Average 0–100 score; not part of the approval digest |

Fleet discover writes the same files with a `fleet-ideate-` prefix.

`providers.execute` defaults to `csr`. Direct Grok execution is a separate,
explicit choice:

```json
"providers": { "execute": "grok-build" }
```

That path still requires implementation approval, uses the e3d-pilot worktree,
and is subject to protected-path checks, diff ceilings, verify, independent
review, draft publication, and head-SHA merge approval. csr remains the
recommended executor.

| Environment variable | Default | Meaning |
| --- | --- | --- |
| `GROK_BUILD_BIN` | `grok` | Executable name or absolute path |
| `GROK_BUILD_TIMEOUT` | `900` | Positive wall-clock seconds |
| `GROK_BUILD_MODEL` | unset | Optional CLI model; unset preserves Grok's configured default |

When unavailable, `e3d-pilot providers list` and a configured-but-missing
Grok call print the installer command. No model is hardcoded because xAI's
default can change.

## Invocation and safety model

The adapter passes an argv array and `--prompt-file`; it does not use `eval`, a
shell command string, or prompt interpolation. It passes `--cwd` explicitly and
captures stdout, stderr, exit status, and timeout status. SIGINT/SIGTERM are
forwarded to the child.

- Reasoning stages (discover, ideate, draft, negotiate, review, scoring):
  `--always-approve --sandbox read-only`, with memory and subagents disabled.
  Web search stays available for discover-style research.
- Direct execution: `--sandbox strict`, web search off, and explicit denies for
  `git push`, `git merge`, `git reset --hard`, `gh pr merge`, and `gh release`.
  It runs only inside the e3d-pilot-created worktree after approval.

The same actual-diff ceilings, tests, independent review, draft PR, and human
merge gate remain authoritative. Grok output cannot waive them. Scoring
workers are read-only and cannot execute a candidate.

The CLI's strict child-network restriction is documented as a no-op on macOS,
so network isolation is not claimed here. Command denies and the outer pipeline
are defense in depth; operators needing kernel-enforced network isolation should
run the worker in an appropriate Linux sandbox/container.

e3d-pilot does not invoke Grok workflows, nested subagents, ACP sessions, or
MCP servers. Those features are out of the safety model: workflows are not
exactly-once, and process restart is not a resume boundary for them.

## Benchmark harness

Use one unchanged task prompt across backends:

```bash
bin/e3d-backend-benchmark \
  --repo /path/to/repo \
  --task-id benchmark-001 \
  --prompt /path/to/task.md \
  --backends codex,claude,grok-build \
  --verify 'npm test' \
  --output /path/to/results.json
```

Each backend gets a detached temporary worktree at the same HEAD. The harness
records success, duration, exit status, changed files, additions/removals,
verification result, retry count, backend errors, model/usage/cost when exposed,
and null human-review fields. It never commits, pushes, publishes, or merges.
Raw stdout/stderr remain beside the JSON in a `.artifacts` directory; temporary
worktrees are removed after measurement. `E3D_BENCHMARK_TIMEOUT` bounds each
backend call (1800 seconds by default).

Subjective review should be entered later using fixed criteria: functional
correctness, test adequacy, scope discipline, maintainability, and review burden.
Do not compare only “task completed.” Keep raw provider artifacts when running a
decision-grade experiment and blind the reviewer to backend identity.

## Standalone worker scoring

In-pipeline scoring is the `candidate_scoring` config block above. The same
read-only fan-out is also available as a standalone tool:

```bash
bin/e3d-grok-workers \
  --repo /path/to/repo \
  --candidates candidates.json \
  --provider grok-build \
  --workers 3 \
  --top 5 \
  --output worker-results.json
```

`--provider` defaults to `grok-build` and accepts any `lib/providers` adapter.
It accepts 3–5 workers, retains each prompt/stdout/stderr/status, averages valid
scores, marks partial runs, and emits the top candidates as JSON. The declared
downstream remains frontier-model review followed by the existing negotiation;
the tool cannot execute a candidate. Rate limits and spend remain operator
concerns; use the timeout and start with three workers.

## ACP, MCP, and workflows

ACP is practical but premature as the default. A future client needs only:

```text
spawn `grok agent stdio`
  -> initialize
  -> authenticate
  -> session/new(cwd, mcpServers)
  -> session/prompt
  <- session/update chunks
  <- completion metadata
  -> cancel/terminate
```

ACP provides structured sessions, events, permissions, and cancellation. The
CLI backend is much smaller, easier to audit, and already has structured JSON;
switch only if experiments show that long-lived sessions or structured tool
mediation materially improve reliability.

MCP is sufficiently defined for later read-only tools: repository intelligence,
issue/search systems, E3D internal read APIs, e3d-tube/Spark Queue inputs, and
other agent services. Do not expose deployment, secret, release, merge, or write
tools to Grok. Start with one read-only server and an explicit allowlist after
the baseline CLI benchmark.

Grok workflows can fan out far beyond e3d-pilot's desired scoring experiment.
Their external effects are not exactly-once and process restarts are not a safe
resume boundary, so e3d-pilot does not invoke them.

## Cost model and known unknowns

Do not apply API list prices to subscription/OAuth Grok Build runs. Exact CLI
economics require observed usage and the actual authentication/model route.
Use this parameterized comparison:

```text
current_cost = N * frontier_execution_cost
hybrid_cost  = N * grok_pass_cost
             + K * frontier_review_cost
             + M * negotiated_execution_cost
```

For a 100 → 20 → 5 funnel:

```text
hybrid_cost = 100*G + 20*R + 5*E
savings     = 100*E - hybrid_cost
```

where `G`, `R`, and `E` must come from observed, complete run records. If Grok
reports partial or absent cost, keep it null and obtain billing-console totals
for the experiment window. Review time should be measured separately because a
cheap pass that increases review burden may have negative leverage.

## Next experiments

1. Install/authenticate explicitly, then run 10–20 blinded, paired tasks across
   all three backends. Record complete usage/billing and reviewer rubric scores.
2. Enable `candidate_scoring.provider: "grok-build"` on a real fleet cadence and
   compare selected-idea quality and reviewer burden against the same ideate
   provider with scoring omitted. Direct execute should stay `csr` for that
   comparison.
3. Prototype a read-only ACP spike for one repo-analysis task and compare event
   fidelity, cancellation, implementation complexity, and recovery with CLI
   JSON. Add one read-only MCP server only if ACP shows measurable leverage.
