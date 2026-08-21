# Grok Build architecture

How Grok Build fits e3d-pilot today. The README is the operator source of
truth; this note is the seam-level picture.

## Current shape

- Reasoning providers are executable adapters under `lib/providers/`. Each
  accepts a prompt-file path, prints its response, and returns 0 (success), 1
  (failure), or 2 (unavailable). Discover, ideate, draft, negotiate, and review
  resolve those adapters from configuration without provider-specific logic.
  `grok-build` is one of those adapters, next to `claude`, `codex`, `devin`,
  and `local`. Naming it in `providers.*` is the opt-in; there is no extra
  feature flag.
- Optional `candidate_scoring` runs after ideate (and after fleet ideate).
  It fans out 3–5 read-only workers through any `lib/providers` adapter,
  averages scores, re-ranks non-duplicate candidates, and records the original
  model pick as `model_selected`. Shared implementation is
  `lib/scoring/fanout.sh`. Scoring never executes, publishes, or approves.
- Source-changing execution is a separate config field, `providers.execute`,
  defaulting to `csr`. csr walks the negotiated spec phase by phase and
  dispatches Codex or Claude. `"execute": "grok-build"` is an experimental
  one-shot implement-the-spec path inside the same e3d-pilot worktree. csr
  remains the recommended executor.
- Execution begins only after the implementation-approval gate. It creates a
  dedicated `e3d-pilot/<run-id>` branch in a temporary git worktree, rechecks
  protected paths on the spec, measures the real resulting diff against
  file/line ceilings, verifies it, obtains independent model review, and only
  then commits and publishes a draft PR or local review branch.
- Publishing and merging are separate. The GitHub publisher pushes only the run
  branch and creates a draft PR. Merge requires a later human approval bound to
  the exact PR head SHA and base branch; force-push is not part of the flow.
- Negotiation uses every configured reviewer sequentially against the same
  draft. Malformed reviewer output gets one parse retry; convergence is bounded
  (four rounds by default). Provider failures are not retried silently.
- Grok workflows, nested subagents, ACP, and MCP are not part of the pipeline.
  e3d-pilot owns worktrees, the idea ledger, and SHA-bound merge.

## Why scoring rather than Grok-as-executor

e3d-pilot's product is the missing half *above* a coding executor: what to
build, whether it is new, whether more than one model agrees, and whether a
human approved. csr stays the dumb phase executor. The high-leverage Grok
use is therefore cheap, parallel, read-only ranking of candidates, then the
existing approval → negotiate → csr path.

Direct Grok execute exists as an explicit `providers.execute` choice so the
adapter can be measured, not so it replaces csr by default.

## Historical note (2026-08-20)

The first architecture pass, before the adapter landed, recorded that execute
always called csr, that there was no generic timeout/cost wrapper, and that
the smallest compatible design was a normal `grok-build` reasoning adapter
plus an optional execute choice. That design is what shipped, with scoring
added on the same provider seam rather than as a second pipeline.
