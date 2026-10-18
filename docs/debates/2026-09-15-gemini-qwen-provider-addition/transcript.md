# Debate

**Question:** Should we add Gemini via Gemini CLI, Qwen3 Coder via OpenRouter, both, or neither
to e3d-pilot and e3d-debate?

This is a decision request, not authorization to implement.

## Context

Chris uses e3d-pilot daily as a solo builder, including deciding what to build,
what not to build, and how to proceed. Multi-model debate supplies independent
judgment, architectural perspectives, and constructive disagreement. He values
using existing subscriptions and free allowances efficiently -- relevant costs
include quota consumption, latency, context limits, and maintenance, not just
API charges. Debate also handles questions beyond coding; distinguish a
model's usefulness for implementation from its usefulness for product/strategic
judgment.

## Verified facts (already gathered -- reason from these, do not re-derive)

**e3d-pilot's current provider architecture** (`lib/providers/<name>`, one
script per provider, shared helpers in `lib/providers/common.sh`):

- Strict exit-code contract: 0 success, 1 failure, 2 unavailable.
  `E3D_PILOT_CHECK=1` does an availability probe; `E3D_PILOT_DRY_RUN=1` prints
  the exact command without calling the model. Every provider script already
  supports explicit model selection via its own env var: `CLAUDE_MODEL`
  (default `sonnet`), `CODEX_MODEL` (default: provider's own default),
  `DEVIN_MODEL` (default `claude-sonnet-4-6-thinking-1m` -- Devin's own
  default underlying model is a Claude model), `GROK_BUILD_MODEL` (default:
  provider's own default).
- **Real, verified gap:** cost/usage telemetry is inconsistent across today's
  four adapters. `claude` prints
  `e3d_provider_usage={"provider":"claude","model":...,"tokens":...,"cost_usd":...}`
  to stderr after every call and enforces a hard `--max-budget-usd` cap
  (default $0.50) natively via the Claude CLI, plus a post-hoc token-ceiling
  kill. `codex` prints tokens-only usage (no `cost_usd`) and has a post-hoc
  token-ceiling kill, no pre-emptive dollar cap. `devin` and `grok-build` have
  **no usage/cost telemetry and no budget cap at all** in the current code --
  grok-build has only a wall-clock timeout and a max-turns limit.
- **Real, verified fact on model diversity:** because `devin`'s default model
  is a Claude model, today's "4-provider" panel (claude, codex, devin,
  grok-build) is really only 3 distinct foundation-model families by default
  (Claude, GPT via codex, Grok via grok-build) unless `DEVIN_MODEL` is
  overridden.
- e3d-pilot already has a generic OpenAI-compatible `local` provider adapter
  (`lib/providers/local`), explicitly documented with "a self-hosted model
  (e.g. Qwen via Ollama)" as its own worked example (README.md:356), including
  a dedicated cross-run mutex already built specifically for a shared local
  Qwen inference process (lock file literally named
  `e3d-pilot-qwen.lock`, `lib/providers/common.sh:50-81`). This is a real,
  already-built alternative path to get a Qwen model into the panel --
  self-hosted, no per-token API cost, no external rate limits, but real local
  compute cost, and there is no evidence in the repo that it has ever actually
  been turned on or used in a real run (it exists only as the design's running
  example). `lib/training/export.sh`'s dataset schema names
  (`e3d-qwen-ideation-v1`, etc.) likewise reflect an intended future local
  Qwen fine-tuning target, not a live provider.
- Config plumbing for adding a new named provider to any pipeline stage
  already exists and is additive: `discover`, `ideate`, `negotiate`, and
  `review` can each already list more than one provider
  (`.e3d-pilot/config.json`'s `providers` map, e.g.
  `"negotiate": ["claude", "codex"]`). Adding a 5th/6th adapter does not
  require redesigning this.
- `bin/e3d-debate` (the tool being asked to answer this very question) is
  explicitly labeled a **prototype** in its own header comment: "Not wired
  into bin/e3d-pilot or config.schema.json yet." It defaults to
  `--providers claude,codex` unless overridden per invocation; it has no
  config file of its own.
- No reference to Gemini exists anywhere in the codebase today. "Qwen" appears
  only as: a test-fixture stub value, the `local` adapter's own documented
  example, and the training-export schema name -- never as a live, wired
  provider.

**Gemini CLI** (google-gemini/gemini-cli, open-source CLI tool, verified via
current official docs and GitHub):

- Free tier via personal Google account OAuth (browser sign-in, no billing/
  card required): **1,000 requests/day, 60 requests/minute**, access to
  current Gemini models. A separate free tier exists for a raw Gemini API key,
  but that free tier is limited to the Flash model only -- exact quota for
  that path was not independently re-verified here.
- Daily quota is **aggregated per Google account** across Gemini CLI and
  Gemini Code Assist agent-mode usage combined, across all model
  versions/families used through either surface -- if the same Google account
  is used elsewhere (e.g. an IDE plugin), quota is shared, not additive.
- Headless/non-interactive automation is a first-class, documented feature:
  `--non-interactive` (no interactive prompts), `--yolo` (auto-approve tool
  calls -- the docs themselves say "use only in trusted environments," the
  same posture e3d-pilot's own sandboxed provider modes already take),
  `--output-format json`. This maps cleanly onto e3d-pilot's existing
  provider-adapter shape (prompt-file in, text/JSON out, non-interactive).
- Paid tiers exist above the free quota (a fixed-price tier for heavier
  individual/enterprise use, and pay-as-you-go for long-running or
  professional use) if 1,000 req/day is ever insufficient.
- Terms-of-service specifics on automation/scripting were not fully
  confirmed from the search results available here -- treat "automation is
  permitted" as consistent with the docs' own headless-mode tutorials, but
  unverified against the literal ToS text.

**Qwen3 Coder via OpenRouter** (verified by fetching openrouter.ai directly,
2026-09-15):

- Exact current model slugs: `qwen/qwen3-coder` (480B-A35B MoE, 262K context),
  `qwen/qwen3-coder-next` (262K context, the cheapest variant), `qwen/qwen3-coder-plus`
  (1M context), `qwen/qwen3-coder-flash` (1M context), `qwen/qwen3-coder-30b-a3b-instruct`
  (262K context).
- **Verified directly against OpenRouter's own model listing page: none of
  the current Qwen3 Coder variants have a free (`:free`) endpoint today.**
  All are metered, paid, per-token inference. Approximate published per-token
  pricing (lower-confidence, from secondary sources, not independently
  re-verified line-by-line): roughly $0.12-1.00 per million input tokens and
  $0.80-5.00 per million output tokens depending on variant, cheapest on
  `qwen3-coder-next`.
- Some third-party blog/aggregator posts claim a free `qwen3-coder` variant
  existed briefly around February 2026. **Treat this as unverified and likely
  stale** -- it does not appear on OpenRouter's current model page. Chris's
  instruction to treat earlier claims of free allowances as unverified is
  directly confirmed here: there is no free lunch to plan around for this
  specific model today.
- OpenRouter's general `:free`-suffix model class (i.e. other models, not
  Qwen3 Coder) is rate-limited at the platform level: 20 requests/minute
  always; 50 requests/day unless the account has purchased at least $10 in
  lifetime credits, after which it rises to 1,000 requests/day. This does not
  apply to Qwen3 Coder specifically since it has no free variant, but is
  relevant if the recommendation considers other OpenRouter-hosted free
  models as an alternative.
- Data policy: OpenRouter does not log prompts/responses by default (opt-in
  only) and retains only request metadata by default, but the *underlying*
  model provider's own policy governs whether that provider trains on
  prompts -- this varies by provider and is not uniformly safe. OpenRouter
  exposes account-level toggles (including a Zero Data Retention setting) to
  restrict routing to providers who do not train on data; these are opt-in,
  not the default.

## Investigate

1. Current capabilities and gaps -- reason from the verified facts above about
   how pilot/debate invokes models, shares context, handles critique/synthesis,
   and records provenance. Confirm neither Gemini nor Qwen is currently
   integrated (verified above), and identify anything else materially relevant
   in the adapter contract (`lib/providers/common.sh`, `lib/providers/claude`,
   `lib/providers/codex`, `lib/providers/devin`, `lib/providers/grok-build`,
   `lib/providers/local`) that changes the calculus.
2. Do not re-verify Gemini CLI or Qwen3/OpenRouter facts from scratch -- use
   what's given above, but flag anything you have independent, more current,
   or conflicting knowledge of, and say so explicitly as a flagged
   disagreement with the supplied facts rather than silently overriding them.
3. Incremental decision quality: what would Gemini and/or Qwen3 Coder add
   beyond the existing panel (Claude, GPT via Codex, Grok via grok-build, and
   Devin defaulting to a Claude model) for architecture critique,
   implementation feasibility, "should we do this?" product/strategy
   decisions, and noncoding questions? Do not assume more models produce
   better decisions or that majority agreement proves correctness.
4. Integration design: compare the smallest viable Gemini CLI adapter vs. an
   OpenRouter adapter, both built to the existing `lib/providers/<name>`
   contract (exit codes, `E3D_PILOT_CHECK`, `E3D_PILOT_DRY_RUN`, explicit model
   env var, timeout, and -- given the verified gap above -- a hard budget cap
   and usage/cost telemetry at least as strong as the `claude` adapter's, not
   as weak as `devin`/`grok-build`'s). Also weigh the already-existing `local`
   adapter (self-hosted Qwen via Ollama) as a competing way to get Qwen
   judgment into the panel without OpenRouter's per-token cost or rate limits.
   Would OpenRouter's access to many other models justify building that
   adapter even if Qwen3 Coder itself adds limited incremental value?
5. Participation policy: should either candidate be a regular participant,
   optional reviewer, disagreement-triggered reviewer, coding specialist, or
   fallback, in e3d-pilot's pipeline stages and/or in e3d-debate specifically
   (remember `e3d-debate` is its own unwired prototype, not the main
   pipeline)? How does this affect speed, quota consumption, and existing
   subscription usage (Chris already pays for Claude and Codex access
   presumably via existing subscriptions; Gemini's free tier and OpenRouter's
   paid-only Qwen3 Coder have different cost shapes)?
6. Propose a small, bounded trial using representative historical pilot/debate
   questions (e.g. re-run one or two already-decided real debates from this
   repo's own `docs/debates/` history with the candidate(s) added, and compare)
   with concrete criteria for keeping or removing each candidate: valid novel
   findings, factual errors, actionable alternatives, latency, cost, and
   whether the contribution changed or improved the final decision.

## Deliver

- A clear recommendation: Gemini only, Qwen3 Coder via OpenRouter only, both,
  or neither.
- Separate verdicts for e3d-pilot's pipeline vs. e3d-debate specifically, if
  they differ.
- The strongest argument against your recommendation, and any unresolved
  dissent.
- Verified facts and sources, clearly separated from assumptions or anything
  you're inferring beyond what was given.
- If warranted, a minimal implementation scope grounded in the actual
  `lib/providers/<name>` contract, and a concrete trial plan.

Optimize for useful additional judgment per unit of cost and complexity. This
is a decision request only -- do not write or propose actual code changes,
just the decision and, if warranted, the scope of what a future change would
touch.

## Round 1 -- claude

## Recommendation: Neither, right now — trial Gemini CLI later, skip Qwen3/OpenRouter

**e3d-pilot pipeline: neither, today.** **e3d-debate: worth a small Gemini-only trial**, gated on it fixing the telemetry gap first.

## Reasoning

**Model diversity is the real gap, and Gemini addresses it better than Qwen3 Coder does.** Today's panel is Claude/GPT/Grok (Devin defaults to Claude, so it's not a 4th voice unless overridden). Gemini is a genuinely distinct foundation-model family with different training data and RLHF choices — real incremental judgment for architecture critique and "should we do this?" questions, which is where debate gets value from disagreement, not code quality. Qwen3 Coder is optimized for code completion/agentic coding, not strategic judgment — it adds the least value on exactly the non-coding questions Chris says debate needs to handle, and for implementation feasibility it's a fourth opinion among several code-capable models already in the panel.

**Cost shape favors Gemini, disfavors Qwen3 Coder via OpenRouter.** Gemini CLI's free tier (1,000 req/day) uses an existing free allowance at zero marginal cost — directly matches "use existing subscriptions/free allowances efficiently." Qwen3 Coder has **no free tier on OpenRouter** (verified fact above) — it would be the only panelist with pure metered per-token cost and no cap today, which is precisely the unmanaged-cost failure mode the recent telemetry gaps already surfaced for devin/grok-build. Adding a paid-only provider without first fixing that gap compounds a known problem rather than being independent of it.

**The `local` adapter is the better path to Qwen judgment, if wanted at all.** It's already built, self-hosted (no per-token cost, no rate limit), and explicitly designed for Qwen via Ollama — but it has never been turned on. If Qwen-family judgment is wanted, standing up `local` costs nothing in new adapter code; building a whole new OpenRouter adapter to reach a model that's strictly worse for this use case (paid, rate-limited, coding-specialized) is solving the wrong problem. OpenRouter's real value is model-catalog breadth, not Qwen3 Coder specifically — that's a separate decision from this one and shouldn't ride in on Qwen's coattails.

**Precondition, not just a nice-to-have: bring any new adapter up to the `claude` adapter's telemetry/cap bar before adding it**, per the stated gap. Adding Gemini today without a hard budget cap and cost telemetry repeats the devin/grok-build mistake on a 5th provider instead of fixing it on the existing 4.

## e3d-pilot vs e3d-debate

- **e3d-pilot pipeline (discover/ideate/negotiate/review): no change now.** This is Chris's daily-driver, and pipeline stages benefit less from one more voice than debate does — the incremental-diversity case is weaker here, and the telemetry gap is a real operational risk in a tool run daily, unattended.
- **e3d-debate: Gemini is the one worth trialing**, precisely because it's already labeled prototype/unwired — lower blast radius, and debate is where cross-family disagreement earns its cost. Run 1-2 already-decided historical debates from `docs/debates/` with `--providers claude,codex,gemini` added, judged against: novel factual findings, actionable alternatives not raised by the other three, and whether it would have flipped or usefully complicated the original decision. If it doesn't clear that bar in 1-2 trials, drop it — don't keep it on vibes.

## Strongest argument against this

Gemini's daily quota is shared across all Google-account usage (Code Assist, IDE plugins, etc.), so "free" may erode unpredictably if Chris uses Gemini elsewhere — worth checking before relying on it. Also, if Chris specifically wants stronger *coding* critique (not strategic judgment) in the panel, Qwen3 Coder's coding specialization argues for it despite the cost — that's a real, unresolved tradeoff this analysis discounts by weighting product/strategy judgment over implementation feasibility.

**Flagged disagreement with supplied facts:** none — the OpenRouter no-free-tier finding and Gemini quota-sharing caveat both match my own knowledge as of my training cutoff.

## Round 1 -- codex

## Recommendation: Gemini only

Add a Gemini CLI adapter. Do not add Qwen3 Coder through OpenRouter now.

- **e3d-pilot:** Make Gemini an optional, last-position reviewer for `negotiate` and `review`, or invoke it after unresolved disagreement. Do not add it routinely to `discover`, `ideate`, or implementation.
- **e3d-debate:** Use Gemini as a regular third participant for consequential product, architecture, and strategy debates. Keep Claude as synthesizer initially.
- **Qwen3 Coder/OpenRouter:** Defer. Reconsider only after evidence that Gemini lacks implementation-focused critique, or when access to multiple OpenRouter models becomes a concrete requirement.

## Why

Gemini adds a genuinely distinct fourth model family at effectively zero marginal API cost within its OAuth allowance. That directly addresses the panel’s real diversity gap: Devin currently duplicates Claude-family judgment. Gemini’s broad capabilities also fit product strategy and noncoding questions better than a coder-specialized Qwen variant.

Qwen3 Coder may provide useful implementation criticism, but its incremental value is narrower and every call is paid. The repo already has a lower-maintenance path to test Qwen judgment through the `local` OpenAI-compatible adapter and Qwen-specific mutex. Building OpenRouter merely because it might later expose other models is speculative platform work, not a current need.

More participants are not automatically better. In pilot negotiation, reviewers run sequentially and revisions mutate the draft before later reviewers see it; adding a permanent reviewer increases latency, quota use, and order effects. In review, one blocking verdict stops publication. Gemini therefore belongs at high-value gates, not every stage.

Debate is a better fit: round one is independent, later rounds expose labeled peer answers, and the transcript preserves provider attribution. However, it records provider names rather than reliably recording exact model/version and complete usage, so model provenance should be strengthened before drawing longitudinal comparisons.

## Minimal future scope

A `lib/providers/gemini` adapter should implement the existing probe/dry-run/exit-code contract, `GEMINI_MODEL`, non-interactive JSON output, read-only or explicitly disabled tools for review/debate, and a wall-clock timeout.

It should emit standardized provider, exact model, request count, input/output tokens, and cost telemetry. Since OAuth is free rather than dollar-metered, enforce pre-call per-run/request and token ceilings and report `cost_usd: 0`; reject paid authentication until a genuine pre-emptive dollar cap exists. This is also a good reason to standardize the currently inconsistent telemetry contract rather than copy Devin or Grok’s weakness.

An OpenRouter adapter would additionally require API-secret handling, provider/ZDR policy controls, pricing-based preflight estimation, a hard dollar ceiling, response usage reconciliation, and routing-provider provenance. That is materially more operational surface.

## Bounded trial

Replay two decided debates from `docs/debates/`: one strategic/noncoding case and one architecture case.

Run the original panel, then the same prompts with Gemini; optionally test Qwen through `local`, not OpenRouter. Blindly score each contribution for:

- valid novel findings and factual errors;
- actionable alternatives;
- whether it changed or improved the final decision;
- latency, requests, tokens, and cost.

Keep Gemini if it contributes at least one decision-relevant valid finding across two debates, has no material hallucination that survives rebuttal, and its latency/quota burden is acceptable. Otherwise retain it only as a fallback or remove it. Do not fund OpenRouter Qwen unless local-Qwen testing first demonstrates unique, repeatable implementation findings.

## Evidence boundary and dissent

Verified from the supplied facts and repository: neither candidate is integrated; provider plumbing is additive; debate is an unwired prototype; outputs are provider-labeled; pilot negotiation is sequential; local Qwen support already exists. Relevant sources include [common.sh](/Users/mini/e3d-pilot/lib/providers/common.sh), [local](/Users/mini/e3d-pilot/lib/providers/local), [e3d-debate](/Users/mini/e3d-pilot/bin/e3d-debate), and [e3d-pilot](/Users/mini/e3d-pilot/bin/e3d-pilot). I have no independent conflicting information to flag.

The strongest counterargument is that Gemini adds another correlated general-purpose opinion while increasing latency and synthesis anchoring; targeted Qwen could add more concrete coding value. That is plausible—but it argues for testing local Qwen, not paying to build OpenRouter now.

## Round 1 -- devin

**Recommendation: Gemini only. Not Qwen3 Coder via OpenRouter.**

---

**Verdicts**

| | e3d-debate | e3d-pilot pipeline |
|---|---|---|
| Gemini CLI | **Yes, add** | **Optional reviewer only** |
| Qwen3 Coder / OpenRouter | **No** | **No** |

---

**Why Gemini yes**

The panel currently has 3 distinct model families (Claude, GPT, Grok) despite 4 named providers — Devin defaults to Claude. Gemini adds a 4th genuine family at zero marginal cost under free tier (1,000 req/day). Its headless mode (`--non-interactive`, `--output-format json`) maps directly onto the existing adapter contract. For e3d-debate's primary use case — product/strategy judgment, "should we build this?" — Gemini's generalist reasoning is a direct fit, not a niche coding add-on. Free tier, clean integration shape, and independent training lineage make the cost/value ratio strong.

For e3d-pilot's pipeline: start it in e3d-debate first (prototype → validate), then consider optional/reviewer role in `negotiate` or `review` stages only. Not a default participant in every stage — quota is finite and shared with any IDE usage of the same Google account.

**Why Qwen3 Coder via OpenRouter no**

No free tier exists today. The incremental debate value of a coding-specialist model over Claude + GPT + Grok for *product and strategy* questions is low. The self-hosted `local` adapter for Qwen via Ollama already exists in the codebase as the designed example — if Qwen judgment is ever wanted, activate that path first (no per-token cost, no external rate limits, no new adapter to write). OpenRouter's multi-model access is a real argument for building the adapter, but not for *Qwen3 Coder specifically at paid rates* when coding coverage is already strong.

---

**Strongest argument against this recommendation**

Against adding Gemini: The ToS permissibility of scripted automation is unconfirmed against the literal text. If the same Google account drives Gemini Code Assist in an IDE, the free quota is shared, not additive — a busy coding day could exhaust the daily limit before a debate run. Free tiers disappear. The adapter adds a new maintenance dependency with no budget backstop (verified gap: devin/grok-build already have no cost telemetry; Gemini would be a third).

Mitigation: build the adapter with the same telemetry/kill contract as `claude`, not as the weak `devin` pattern. Use a dedicated Google account for automation, separate from any IDE usage, to isolate quota.

---

**Trial plan (concrete, bounded)**

Re-run `2026-09-07-hugging-face-strategy` and `2026-09-06-shared-cognition-vs-insight-mode` from `docs/debates/` with Gemini added. Keep if: Gemini raises ≥1 novel valid objection or factual correction not present in the Claude/GPT/Grok round, adds no factual errors, and completes within 2× the median latency of the current slowest provider. Remove if it systematically echoes the majority or produces confident errors.

## Round 1 -- grok-build

I'll inspect the provider adapters, debate prototype, and debate history so the recommendation is grounded in how e3d-pilot actually runs models.**Recommendation: Gemini only.** Do not add Qwen3 Coder via OpenRouter. Do not build a generic OpenRouter adapter for option value.

## Verdicts

**e3d-debate:** Add a `gemini` adapter and use it as an **opt-in extra voice**, not a new default. Keep the prototype default as `claude,codex`. For high-stakes product/architecture questions, run `claude,codex,gemini` (and `grok-build` when already logged in). Gemini should not synthesize by default.

**e3d-pilot pipeline:** Ship the same adapter; **do not put Gemini on any default stage.** After a trial, the only justified regular use is optional `negotiate`/`review` or `candidate_scoring` — never discover/ideate/draft/execute. Negotiate **fails the run** if a listed reviewer is unavailable, so a quota-exhausted Gemini reviewer would brick consensus. That is incompatible with “always on.”

**Qwen3 Coder / OpenRouter:** Neither tool. The unused `local` adapter is already the designed Qwen path (Ollama example, `e3d-pilot-qwen.lock`, training-export names). Paying OpenRouter for a **coder** model does not buy better “should we do this?” judgment.

## Why Gemini, not Qwen, not both

The live panel is three foundation families (Claude, GPT via Codex, Grok). Devin’s default is Claude, so a fourth named provider is not a fourth mind. Gemini is the missing **generalist** family: useful for architecture critique, product strategy, and noncoding questions, not only implementation. Headless CLI shape (`--non-interactive`, JSON out) matches `lib/providers/<name>` (prompt file in, text out, `E3D_PILOT_CHECK` / `DRY_RUN`). Cost is quota, not a new invoice, if the Google account is not already burning the shared 1,000 req/day with Code Assist.

Qwen3 Coder is the wrong increment: metered, no `:free` endpoint, coder-specialized, messier training-data policy via the underlying provider, and it duplicates a path that already exists and has never been turned on. An OpenRouter gateway “for other models later” is a marketplace product, not a judgment upgrade. Chris already has four adapters, an unused local path, and inconsistent telemetry; more surface without a proven delta is the failure mode.

## Participation and cost

Chris already pays for Claude and Codex. Gemini’s free tier is the efficient diversity buy **if** requests are opt-in and counted. Pipeline fan-out would waste that quota; two-round debates with three providers plus synthesis are the right spend. Do not use `--yolo` in analysis/debate (same posture as negotiate setting `CLAUDE_TOOLS=""`). Any Gemini adapter must match **claude-grade** usage telemetry and a hard cap (request and/or dollar), not grok-build’s timeout-only envelope.

## Strongest argument against, and dissent

A fourth generalist may echo Claude/GPT/Grok, add latency, and share quota with IDE use, while Gemini CLI automation vs literal ToS is not fully confirmed. The unused `local` adapter is evidence this repo already over-builds providers. Unresolved: whether free-tier CLI actually serves a Pro-class model worth the slot (API-key free path is Flash-only per the given facts). If the trial’s Gemini is a thin model, the recommendation collapses to **neither**.

## Facts vs inference

**Given/verified:** no Gemini in-repo; Qwen only as local example / fixture / export schema; adapter contract 0/1/2; debate is an unwired prototype defaulting to claude,codex; Gemini CLI headless + 1,000 req/day shared per Google account; Qwen3 Coder on OpenRouter is paid-only as of 2026-09-15; negotiate fails fast on unavailable reviewers; `local` is the documented Qwen path.

**I did not re-scrape OpenRouter or Gemini docs.** No flagged contradiction with those facts. **Assumption:** free-tier Gemini CLI quality is close enough to matter; **assumption:** Chris is not already exhausting that Google account elsewhere.

## If implemented later (do not do it in this decision)

One script, `lib/providers/gemini`: `GEMINI_MODEL`, CHECK/DRY_RUN, timeout, JSON parse, `e3d_provider_usage` with tokens/`cost_usd` or explicit `unmeasured`, hard cap. Tests + README opt-in only. No default `config.json` / debate default change.

**Trial (keep/kill):** Re-run `docs/debates/2026-09-07-hugging-face-strategy` and `2026-09-07-e3d-graph-generalization` with `--providers claude,codex,gemini` (same synthesizer as original). Keep Gemini only if it produces ≥1 valid novel finding that would have changed or sharpened the recorded decision, error rate no worse than the existing panel, and the trial stays well under daily quota. Kill it if it only restates others, hallucinates repo facts, or the free-tier model is too weak. Do not trial OpenRouter Qwen unless Gemini is kept **and** a later coding-only gap remains; then prefer turning on `local`, not OpenRouter.

## Round 2 -- claude

All five of us land in the same place: build a minimal Gemini CLI adapter to Claude-grade telemetry/cap standard, trial it in e3d-debate against 1-2 historical `docs/debates/` replays with keep/kill criteria, don't make it a pipeline default, and skip Qwen3 Coder/OpenRouter entirely (use the dormant `local` adapter if Qwen judgment is ever wanted). My round-1 framing ("neither, right now") and the others' framing ("Gemini only") describe the identical action once you unpack it — none of us recommend flipping Gemini into any config default today; all of us gate that on a bounded trial. I'll drop the "neither" framing since it reads as more conservative than it is and is causing surface-level disagreement where none exists in substance.

Where the group is fully aligned and I have nothing to add: Qwen3 Coder is the wrong increment (paid-only, coder-specialized, duplicates the unused `local`/Ollama path that's already zero-cost); Gemini is the real diversity gap-filler (Devin's Claude default means today's panel is 3 families, not 4); e3d-debate is the right first venue precisely because it's an unwired prototype with low blast radius; the pipeline's `negotiate` fail-fast-on-unavailable-reviewer behavior (grok-build's point) is a concrete, specific reason Gemini must never be a default pipeline reviewer while its quota is shared and unpredictable — a quota-exhausted mandatory reviewer would brick consensus. That's a sharper, more concrete version of my own "telemetry/cap precondition" argument and I fold it in.

One place I'll push back slightly: devin and grok-build's trial plans pick different debate pairs (`hugging-face-strategy` + `shared-cognition-vs-insight-mode` vs. `hugging-face-strategy` + `e3d-graph-generalization`). This is a minor implementation detail, not a decision-relevant disagreement — either pair works as long as one is strategic/noncoding and one is architectural, which all four proposed pairs satisfy. Not worth resolving here; whoever implements the trial picks two that fit that split.

Strongest counter, which I already raised and no one has actually rebutted: Gemini's daily quota is shared account-wide with any Code Assist/IDE usage, so "free" is not free if Chris's Google account is active elsewhere — this could silently starve a debate run mid-session with no budget-style warning, unlike a dollar cap. Codex and devin both surface this too but no one has a mitigation beyond "use a dedicated account," which is a real operational cost (account management) that slightly undercuts the "zero marginal cost" framing everyone (including me) leans on. That's the one place I'd flag as genuinely unresolved rather than settled — not enough to change the recommendation, but enough that the trial should explicitly log whether quota pressure appears before anyone treats Gemini as reliably free going forward.

No remaining substantive dissent on the core question: build Gemini adapter + trial in e3d-debate, no default pipeline rollout pending trial results, skip Qwen/OpenRouter now.

POSITION: Build a minimal Gemini CLI adapter (claude-grade telemetry and cap) and trial it as an opt-in extra voice in e3d-debate against 1-2 historical debates before any default rollout; skip Qwen3 Coder via OpenRouter, using the existing dormant `local` adapter instead if Qwen judgment is ever wanted.
status: approved

## Round 2 -- codex

My position holds: **Gemini only**, implemented initially as an opt-in trial adapter—not enabled by default anywhere. Do not build OpenRouter/Qwen3 Coder now.

For **e3d-debate**, Gemini should be the trial third participant on selected consequential strategy, architecture, and noncoding questions. Promote it to a regular—but still explicitly selected—participant only if the trial shows decision-relevant novelty. Keep Claude as synthesizer initially.

For **e3d-pilot**, ship no configuration change. If Gemini proves useful, use it selectively in `negotiate`; avoid making it a default `review` gate because an available provider that fails blocks publication, while quota exhaustion makes availability operationally uncertain. It offers little justification for routine discover, ideate, draft, or execute participation.

The actual implementation confirms that debate participants run concurrently in each round, receive competitors’ text only in subsequent rounds, and are identified only by provider name—not exact model/version. Negotiation is sequential, so adding reviewers increases latency and order effects; unavailable configured negotiators fail the run. These details support opt-in deployment more strongly than routine participation. See [e3d-debate](/Users/mini/e3d-pilot/bin/e3d-debate), [e3d-pilot](/Users/mini/e3d-pilot/bin/e3d-pilot), and [common.sh](/Users/mini/e3d-pilot/lib/providers/common.sh).

Claude’s “neither today, trial later” is overly restrictive: conducting a faithful automated trial necessarily requires the minimal Gemini adapter. The telemetry requirement should constrain that adapter, not postpone the experiment indefinitely. Codex and Devin are directionally right, but “regular third participant” is premature before measured evidence. Grok-build’s opt-in position is closest to mine. Devin’s dedicated-account suggestion may isolate quota, but should not be assumed acceptable without confirming Google’s account and automation terms.

A minimal future Gemini scope is one adapter plus tests and documentation: OAuth-only initially; `GEMINI_MODEL`; check/dry-run/exit codes; noninteractive JSON; timeout; tools disabled or safely confined; exact-model and token/request telemetry; a pre-call per-run request ceiling; and `cost_usd: 0` only when OAuth-free operation is verified. Paid authentication must fail closed until a genuine dollar cap exists. Transcript provenance should record the exact model. No default config or debate-provider change.

Do not add OpenRouter for speculative catalog breadth. Qwen3 Coder is paid-only, narrower for strategic judgment, introduces API-secret/routing/data-policy/pricing complexity, and competes with an already-built local Qwen route. If implementation critique later proves deficient, test local Qwen first.

Trial two historical debates—one strategic and one architectural—with identical prompts, rounds, and synthesizer. Blind-score valid novel findings, material errors, actionable alternatives, decision impact, latency, requests, tokens, and cost. Keep Gemini if it supplies at least one valid decision-relevant contribution across two trials without a material unrebutted error and with acceptable latency/quota use; otherwise retain only as fallback or remove it.

The strongest counterargument is that another generalist may merely echo the panel while consuming shared quota and maintenance effort; unresolved literal-ToS coverage for automation is a real pre-deployment gate. I have no independent factual conflict with the supplied Gemini/OpenRouter facts.

POSITION: Add Gemini CLI only as an opt-in trial adapter, with no default pipeline participation, and defer OpenRouter/Qwen3 Coder in favor of local Qwen testing if a coding gap emerges.
status: revise

## Round 2 -- devin

**Position confirmed: Gemini only. Qwen3 Coder via OpenRouter: no.**

The Qwen3/OpenRouter question is fully resolved — all four round-1 answers agree, and the case against is strong enough that no rebuttal landed. The remaining live disagreement is the one between claude and the other three: **whether telemetry gaps in existing adapters should block adding Gemini.**

## Rebuttal to claude on sequencing

Claude frames the telemetry gap as a precondition: fix devin/grok-build first, then add Gemini. I read the actual adapter code. The gap is worse than the problem statement describes:

- `grok-build`: no `e3d_provider_usage`, no dollar cap — confirmed
- `devin`: same — confirmed in supplied facts
- `local`: also no `e3d_provider_usage`, no dollar cap — **confirmed from code**, not mentioned in the supplied facts

Four of five existing adapters are below the `claude` telemetry bar. Treating "fix all four first" as the gate for Gemini means Gemini waits indefinitely for remediation work no one has scheduled. That's the wrong sequencing.

The correct sequencing is **build the Gemini adapter once, at claude-grade telemetry, and let it be the model for backfilling the others** — not the other way around. Claude's framing implicitly treats Gemini as an obligation rather than an opportunity to demonstrate the right pattern.

## Where I agree with the other three

- **codex** is right that the Gemini adapter should emit standardized `e3d_provider_usage` (including `cost_usd: 0` for free-tier OAuth calls) and enforce a pre-call request ceiling, not a post-hoc dollar cap that doesn't apply to quota-based billing. That's cleaner than copying the `claude` adapter's `--max-budget-usd` flag directly.
- **grok-build** is right that Gemini should not be a default participant in `negotiate` — the stage fails fast on unavailability, so a quota-exhausted provider would brick the run. This is the hardest constraint against pipeline integration.
- **devin** (my round 1) is right on the trial spec: re-run `2026-09-07-hugging-face-strategy` and `2026-09-06-shared-cognition-vs-insight-mode` with `--providers claude,codex,gemini`. Keep Gemini if it produces ≥1 novel valid finding that would have changed or sharpened the recorded decision, no factual errors that survive rebuttal, and latency within 2× the slowest existing provider.

## What I'm adding in round 2

One observation the other answers underweight: the `local` adapter's telemetry gap means the repo has effectively institutionalized "build now, measure never" for non-claude providers. Gemini should not be the 5th provider in that pattern. If Chris is going to have an opinion on whether Gemini earns its slot, he needs actual request counts and token counts after the trial — not just vibes. This is an argument for instrumenting Gemini *before* the trial, not after it passes.

## Verdicts (unchanged from round 1, refined)

**e3d-debate:** Add a `gemini` adapter immediately, instrumented with `e3d_provider_usage` (requests, tokens, `cost_usd: 0`), hard per-run request ceiling, wall-clock timeout. Run the bounded two-debate trial. Keep if it clears the bar; remove otherwise. This is where Gemini earns its keep — generalist judgment on product/strategy questions, 4th distinct model family, free-tier quota.

**e3d-pilot pipeline:** Do not add to any default stage. After a successful trial, consider opt-in for `negotiate`/`review` — but only with exit-2 (unavailable) behavior, not exit-1 (failure), when quota is exhausted. The fail-fast contract for negotiate makes this non-trivial.

**Qwen3 Coder via OpenRouter:** No. If Qwen judgment is ever wanted, activate the existing `local` adapter. Build OpenRouter only if a specific multi-model-catalog need emerges, not to reach Qwen.

## Strongest remaining objection

If the free-tier Gemini CLI routes to Flash (not a Pro-class model) — which the supplied facts suggest is the risk for API-key auth but is unconfirmed for the OAuth/CLI path — the "4th distinct family" value claim collapses. The trial must record exact model version, not just provider name. Current `e3d-debate` records only provider name in the transcript; this needs fixing before longitudinal comparisons mean anything.

POSITION: Add Gemini CLI to e3d-debate now with claude-grade telemetry built in from the start; do not add Qwen3 Coder via OpenRouter; defer Gemini pipeline integration until after a bounded two-debate trial.
status: revise

## Round 2 -- grok-build

I'll read the full debate prompt and the previous-round answers, then check the adapter contract so the recommendation is grounded in how pilot and debate actually work.I'll check a few adapter and debate details that could change whether Gemini belongs in the pipeline versus remaining opt-in.**Recommendation holds: Gemini only.** Do not add Qwen3 Coder via OpenRouter. Do not build a generic OpenRouter adapter for catalog option-value.

## Verdicts

**e3d-debate:** Ship a `gemini` adapter and use it as an **opt-in extra voice**. Keep the prototype default `claude,codex`. For high-stakes product/architecture questions, pass `--providers claude,codex,gemini` (plus `grok-build` when already logged in). Gemini should not synthesize.

**e3d-pilot:** Same adapter; **do not list Gemini on any default stage.** After a keep/kill trial, the only justified regular use is optional `negotiate`/`review` or `candidate_scoring` — never discover/ideate/draft/execute. Negotiate **fails the run** if a listed reviewer is unavailable (`tests/phase6.sh`). A shared 1,000 req/day quota is incompatible with “always on.”

**Qwen3 / OpenRouter:** Neither tool. The unused `local` adapter is already the designed Qwen path.

## Why this still beats the other three

Claude’s **“neither now, trial later”** is the right caution with the wrong label. A trial needs `lib/providers/gemini`. Refusing to add Gemini while proposing a Gemini trial is a freeze, not a decision. The keep/kill bar *is* the gate. Calling it “neither” would tell an operator to do nothing, which wastes the cheap diversity buy.

Codex is right that Gemini is the missing generalist family and that OpenRouter is speculative platform work. It is **wrong to wire Gemini as an optional last-position negotiate/reviewer now**, and **wrong to make it a regular third debate participant before the trial**. In this repo, “optional” in config is not optional at runtime: listing it makes it required. That is a daily-driver footgun on a shared free quota. Sequential negotiate also mutates the draft before later reviewers see it; adding a quota-fragile last reviewer buys order effects, not independent judgment.

Devin’s table (“debate: yes, add”) is too coarse. Add the adapter, not a new default. A dedicated Google account is a reasonable ops mitigation, not a reason to default-on.

Qwen3 Coder remains the wrong increment: metered, no `:free` endpoint, coder-specialized, and it duplicates a path that already exists and has never been turned on. I am not moving toward “both.”

## Cost and participation

Chris already pays for Claude and Codex. Gemini’s free tier is the efficient diversity buy **if** requests are opt-in and counted. Do not use `--yolo` in analysis/debate (same posture as negotiate setting `CLAUDE_TOOLS=""`). Any Gemini adapter must match **claude-grade** usage telemetry and a hard request/token cap, not grok-build’s timeout-only envelope. Report `cost_usd: 0` on OAuth free; reject paid auth until a real dollar cap exists.

## Strongest argument against, and dissent

A fourth generalist may echo Claude/GPT/Grok, add latency, and share quota with IDE use. Gemini CLI automation vs literal ToS is unconfirmed. The unused `local` adapter is evidence this repo already over-builds providers. Unresolved: whether free-tier CLI actually serves a Pro-class model (API-key free path is Flash-only per the given facts). If the trial’s Gemini is thin, this collapses to **neither**. Codex’s counter — use it immediately on consequential debates rather than replaying history — is the best objection; the unused `local` path is why I still want two keep/kill debates first.

## Facts vs inference

**Given:** no Gemini in-repo; Qwen only as local example / fixture / export schema; adapter contract 0/1/2; debate is an unwired prototype defaulting to `claude,codex`; Gemini CLI headless + 1,000 req/day shared per Google account; Qwen3 Coder on OpenRouter is paid-only as of 2026-09-15; negotiate fails fast on unavailable reviewers.

**No flagged contradiction** with those facts. **Assumption:** free-tier Gemini quality is close enough to matter; Chris is not already exhausting that Google account.

## If implemented later (do not do it in this decision)

One script, `lib/providers/gemini`: `GEMINI_MODEL`, CHECK/DRY_RUN, timeout, JSON parse, `e3d_provider_usage`, hard cap. Tests + README opt-in only. No default `config.json` / debate-default change.

**Trial:** Re-run `docs/debates/2026-09-07-hugging-face-strategy` and `2026-09-07-e3d-graph-generalization` with `--providers claude,codex,gemini`. Keep only if ≥1 valid novel finding would have changed or sharpened the recorded decision, error rate no worse than the existing panel, and quota stays comfortable. Kill if it only restates others, hallucinates repo facts, or the free-tier model is too weak. Do not trial OpenRouter Qwen; if a coding-only gap remains after Gemini is kept, turn on `local` first.

POSITION: Add an opt-in Gemini CLI adapter and trial it in e3d-debate only; do not change pipeline or debate defaults; skip Qwen3 Coder via OpenRouter.
status: revise

## Round 3 -- claude

All five of us now describe the same action: build a minimal `gemini` adapter with claude-grade telemetry (`e3d_provider_usage`, `cost_usd: 0` on free-tier OAuth, hard request ceiling) from the start, trial it against 1-2 historical `docs/debates/` replays, keep it opt-in in e3d-debate pending results, never make it a pipeline default, and skip Qwen3 Coder/OpenRouter entirely in favor of the dormant `local` adapter if Qwen judgment is ever wanted. The apparent sequencing disagreement (mine: "trial gates rollout" vs. devin's: "build with instrumentation first, then trial") isn't a disagreement about what to build or when to touch the pipeline — it's about whether "the adapter" or "the trial" is the named first step, and devin's version is actually the more precise one: you can't run a faithful trial without the instrumented adapter existing first, so "build minimal telemetry-first adapter, then trial" is the correct single sequence, not two competing ones. I adopt that framing over my own "trial later" phrasing, which read as more hesitant than it was.

Two points from this round sharpen but don't change the recommendation:

**Devin's model-version point is the one gap worth fixing before the trial means anything.** `e3d-debate` transcripts currently record only provider name, not exact model/version. If free-tier Gemini CLI OAuth silently serves a weaker model than expected (the supplied facts confirm this risk for API-key auth, leave it unconfirmed for OAuth), a trial that only logs "gemini" as the participant can't distinguish "Gemini added nothing" from "we tested the wrong tier." This should be added to the minimal adapter scope, not treated as a separate follow-up.

**Grok-build's "optional in config is not optional at runtime" point is the sharpest articulation of why negotiate/review must stay closed to Gemini even after a successful trial**, more precise than my own telemetry-precondition framing or codex's "avoid default review gate" — it's not just that Gemini's quota is unpredictable, it's that the pipeline's fail-fast contract turns any listed reviewer into a hard dependency regardless of intent. That's a structural argument, not a caution, and it holds even once telemetry is fixed.

No one has rebutted the standing flag I raised last round: Gemini's daily quota is aggregated per Google account across CLI and Code Assist/IDE usage combined, so "free" isn't free if that account is active elsewhere, and unlike a dollar cap there's no graceful budget-style warning — just a hard stop. Nobody has a mitigation beyond "use a dedicated account," which is itself an ongoing operational cost. This doesn't change the recommendation, but the trial should explicitly log whether quota pressure shows up, and that finding — not vibes — should govern whether Gemini graduates beyond opt-in.

On Qwen3 Coder / OpenRouter: fully resolved across all five answers, no dissent remains. Paid-only, coder-specialized, and duplicates the already-built, never-activated `local`/Ollama path. Building a generic OpenRouter adapter for catalog breadth is speculative platform work not justified by this question.

Given devin's sequencing correction and grok-build's structural point are both refinements I'm folding in rather than rebuttals I'm resisting, and every other participant lands on the identical action (build instrumented Gemini adapter → trial in e3d-debate → keep opt-in, no pipeline default → skip Qwen/OpenRouter), there's no remaining substantive disagreement. Anyone acting on any of the five answers now does the same thing.

POSITION: Build a minimal, claude-grade-telemetry Gemini CLI adapter (with exact model/version recorded in transcripts) and trial it as an opt-in extra voice in e3d-debate against 1-2 historical debates before any default rollout; never make it a pipeline default given negotiate's fail-fast-on-unavailable-reviewer contract; skip Qwen3 Coder via OpenRouter, using the existing dormant `local` adapter instead if Qwen judgment is ever wanted.
status: approved

## Round 3 -- codex

My position holds: **Gemini only**, meaning build the minimal adapter solely to conduct an opt-in trial; do not enable it by default. Skip Qwen3 Coder/OpenRouter.

The answers now agree operationally. Claude correctly abandoned “neither now,” because a realistic automated trial requires the Gemini adapter. Grok-build most precisely distinguishes “add the adapter” from “add a default participant.” Devin is right that existing telemetry debt should not block Gemini; Gemini should establish the stronger standard.

Two corrections matter:

- Only `negotiate` treats an unavailable configured provider as fatal. `review` explicitly skips unavailable providers and proceeds if at least one succeeds. Thus Gemini could eventually be a safer optional reviewer than negotiator, although ordinary failures can still disrupt runs.
- A “hard dollar cap” is not meaningful for verified OAuth-free calls. The equivalent safeguard is a pre-call request ceiling, token ceiling where enforceable, timeout, and fail-closed rejection of paid authentication. `cost_usd: 0` should be emitted only when the adapter can establish the free OAuth path—not merely infer it.

For `e3d-debate`, keep the default `claude,codex`, but trial `claude,codex,gemini` on one strategic/noncoding and one architectural historical debate. Gemini adds a genuinely distinct family and is more likely than coder-specialized Qwen to improve “should we?” judgment. Preserve Claude as synthesizer during comparison so the independent variable is participation, not adjudication.

For `e3d-pilot`, make no default configuration change. After a successful trial, Gemini belongs first as an explicitly selected debate participant or occasional `review` voice. Using it in `negotiate` requires accepting fail-fast quota risk; routine discover/ideate use would consume shared quota without demonstrated value.

Minimal future scope: `lib/providers/gemini`, adapter tests, and opt-in documentation; `GEMINI_MODEL`, check/dry-run, strict exit codes, noninteractive JSON, timeout, disabled tools, request/token limits, standardized usage telemetry, and exact-model provenance. Exact model identity must enter transcripts because provider-only labels cannot support meaningful longitudinal evaluation. No OpenRouter adapter should be built for speculative catalog value.

Keep Gemini only if two blinded replays produce at least one valid, decision-relevant novel finding, no material unrebutted factual error, acceptable latency, and tolerable quota consumption. Otherwise retain it only as a fallback or remove it. If a coding-perspective gap later appears, test the existing local Qwen route before paying OpenRouter and accepting its routing/data-policy complexity.

Strongest counterargument: Gemini may duplicate existing generalists while consuming shared account quota and adding maintenance. Literal automation-ToS coverage and the exact free-tier model remain unresolved deployment gates. I have no independent conflict with the supplied external facts.

POSITION: Add only a minimal opt-in Gemini CLI adapter for a bounded e3d-debate trial, make no pipeline or debate default changes, and defer Qwen3 Coder/OpenRouter in favor of local Qwen if a coding gap is later demonstrated.
status: approved

## Round 3 -- devin

**Round 3 assessment: convergence confirmed, two open points worth naming.**

All four participants now describe the same action sequence: build a minimal Gemini CLI adapter at claude-grade telemetry from day one, trial it in e3d-debate against two historical debates using explicit `--providers` opt-in, keep/kill on clear criteria, skip Qwen3 Coder/OpenRouter, leave every default config unchanged. No one following any of the four answers would take a materially different first action.

What I said in round 2 that still stands:

- **Telemetry is part of the adapter spec, not a follow-up.** The right sequencing is: ship the adapter already instrumented (request count, token count, `cost_usd: 0` for OAuth-free), *then* run the trial. Not instrument after. This is now the consensus — codex and grok-build both specify claude-grade telemetry as a ship requirement, not a nice-to-have.
- **Exact model version must be recorded in the transcript.** The supplied facts flag that the free CLI OAuth path might serve a different model than API-key auth. `e3d-debate` currently records only provider name. The adapter must emit and the transcript must preserve the exact model string, or longitudinal comparisons between runs are meaningless. No one has disagreed with this; it just hasn't made it into anyone's explicit adapter spec beyond mine.
- **`local` Qwen before OpenRouter Qwen, always.** The existing dormant adapter is the correct path if coding critique ever seems thin. OpenRouter is speculative catalog work with per-token cost and no free path.

Where I'm updating based on the other three:

- **Grok-build's `negotiate` fail-fast constraint is the sharpest pipeline argument.** I mentioned "exit-2 not exit-1 on quota exhaustion" in round 2, but grok-build's framing is cleaner: in this repo, "optional" in config is not optional at runtime — listing a provider in `negotiate` makes it required. This is a concrete reason the trial should live entirely in `e3d-debate` (the unwired prototype) and not touch any `config.json` defaults, even optionally, until the trial is done.
- **Claude's quota-sharing concern is unresolved and should be a trial observable.** If the trial shows quota pressure mid-run (e.g., partial results or exit-2 from a depleted account), the "free tier" framing becomes inaccurate and the cost calculus changes. This should be an explicit trial metric, not background awareness.

The one disagreement I'll log for the record rather than fight:

**Trial debate pair selection** (grok-build: `hugging-face-strategy` + `e3d-graph-generalization`; my round 2: `hugging-face-strategy` + `shared-cognition-vs-insight-mode`; claude: either works). The criterion is one strategic/noncoding debate and one architectural — both pairs satisfy this. I have no strong preference; the implementer should pick whichever two have the clearest recorded rationale to compare against.

**Strongest argument against the consensus (unchanged):** A fourth generalist voice may echo the existing panel on every question that matters. The `local` adapter being dormant is evidence the repo has a track record of building providers that never run. If Gemini just restates Claude and GPT with different phrasing, the trial result will be "keep as fallback" indefinitely rather than "remove" — which is a worse outcome than skipping it entirely, because it creates ongoing maintenance surface. The keep/kill bar must be strict: at least one finding that would have *changed* a decision, not merely *supported* it with additional confidence.

No factual conflicts with the supplied Gemini/OpenRouter facts. No remaining substantive disagreement with the other three.

POSITION: Build a minimal Gemini CLI adapter with claude-grade telemetry and exact model recording built in from day one, trial it as opt-in in e3d-debate against two historical debates with a strict keep/kill bar, leave all defaults unchanged, and skip Qwen3 Coder via OpenRouter entirely.
status: approved

## Round 3 -- grok-build

I'll read the full debate prompt and prior participant answers so I can take a round-3 position without re-deriving the given facts.The group now agrees on the operator action. I'll restate that recommendation, keep the remaining caveats as caveats, and mark the round approved.Position holds. Claude dropping “neither” removes the only action-level split. Someone following any of us would: add `lib/providers/gemini`, leave pipeline and debate defaults alone, trial it in `e3d-debate` on two historical questions, and not build OpenRouter/Qwen3 Coder.

**Recommendation: Gemini only.** Not both. Not neither. Not Qwen3 Coder via OpenRouter.

**e3d-debate:** Ship the adapter. Keep default `--providers claude,codex`. Invoke Gemini only via `--providers` for the trial. Do not make it the synthesizer.

**e3d-pilot:** Same adapter, no `config.json` change. Do not list Gemini on discover/ideate/draft/execute/negotiate/review. Listing a provider is not optional at runtime: negotiate fails the run if a listed reviewer is unavailable. A shared 1,000 req/day quota cannot be a daily-driver gate.

**Qwen / OpenRouter:** No. Paid-only, coder-narrow, and it duplicates the unused `local` (Ollama) path. Do not build a generic OpenRouter adapter for catalog option-value.

**Rebuttals that are now nuance, not dissent.** Devin’s “add to e3d-debate now” means the adapter, not a new default — same action. Codex’s “trial third participant on consequential questions” is the historical replays, not a live default. Claude is right that the exact debate pair is an implementer detail; one strategic/noncoding and one architectural is the requirement. Devin’s dedicated Google account and post-trial exit-2-on-quota idea are ops follow-ups, not this decision. Recording exact model in usage/transcripts is part of claude-grade telemetry, not a second project.

**Trial (do later, not this decision).** Re-run two `docs/debates/` cases with `--providers claude,codex,gemini` (e.g. `2026-09-07-hugging-face-strategy` plus either `e3d-graph-generalization` or `shared-cognition-vs-insight-mode`). Same rounds and synthesizer. Score novel valid findings, unrebutted errors, decision impact, latency, requests/tokens, and whether quota pressure appears. **Keep** only if ≥1 valid finding would have changed or sharpened the recorded decision, error rate no worse than the existing panel, and quota stays comfortable. **Kill** if it only restates others, hallucinates repo facts, or the free-tier model is too thin. Do not trial OpenRouter Qwen; if a coding-only gap remains, turn on `local` first.

**Minimal future scope.** One script `lib/providers/gemini`: `GEMINI_MODEL`, CHECK/DRY_RUN, 0/1/2, timeout, non-interactive JSON, tools off (same as negotiate’s `CLAUDE_TOOLS=""` — no `--yolo` for analysis). `e3d_provider_usage` with tokens/requests and `cost_usd: 0` on verified OAuth-free; hard per-run request/token cap; paid auth fail-closed until a real dollar cap exists. Tests + README opt-in. No default config.

**Strongest argument against.** A fourth generalist may echo Claude/GPT/Grok, add latency, and share quota with IDE/Code Assist so “free” silently starves a run with no dollar-cap warning. Unresolved: literal ToS for automation; whether CLI OAuth actually serves a Pro-class model (API-key free path is Flash-only per given facts). If the trial’s Gemini is thin, this collapses to neither. The unused `local` adapter is evidence this repo already over-builds providers.

**Given vs assumed.** Given: no Gemini in-repo; Qwen only as local example/fixture/export schema; adapter contract 0/1/2; debate is an unwired prototype; Gemini CLI headless + 1,000 req/day shared per Google account; Qwen3 Coder paid-only as of 2026-09-15; negotiate fails fast on unavailable reviewers. No flagged contradiction with those facts. Assumed: free-tier quality is close enough to matter; Chris is not already exhausting that Google account.

POSITION: Add an opt-in Gemini CLI adapter and trial it in e3d-debate only; do not change pipeline or debate defaults; skip Qwen3 Coder via OpenRouter.
status: approved


## Synthesis (claude)

FINAL ANSWER: Add Gemini via a minimal Gemini CLI adapter, built with claude-grade telemetry (usage/request/token counts, `cost_usd: 0` on verified free-tier OAuth, exact model/version recorded in transcripts) from the start; trial it as an opt-in extra voice in e3d-debate against two historical debate replays (one strategic/noncoding, one architectural) with a strict keep/kill bar requiring ≥1 decision-relevant novel finding. Do not add it to any e3d-pilot default stage or config — negotiate's fail-fast-on-unavailable-reviewer contract makes any listed provider a hard dependency, which is incompatible with Gemini's shared, capped daily quota. Skip Qwen3 Coder via OpenRouter entirely: it's paid-only with no free tier, coder-specialized rather than useful for product/strategy judgment, and duplicates the already-built, never-activated `local`/Ollama adapter, which is the correct path if Qwen judgment is ever wanted.

CONSENSUS: full

DISSENT: none substantive — only minor, non-decision-relevant differences remain (which two historical debates to replay, and an unresolved observation that Gemini's account-wide shared quota could silently starve a run, which the trial should log but doesn't change the recommendation).
