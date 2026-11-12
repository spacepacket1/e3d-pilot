# Debate

**Question:** Debate Brief: Adding OpenRouter to e3d-pilot's Model-Selection Layer

You are reviewing a proposed architecture change to e3d-pilot, a Bash-first autonomous agentic loop (discover -> ideate -> draft -> negotiate -> execute -> review -> publish) that decides what a codebase should build next, requires independent AI models to agree a plan is safe before anything executes, hands actual execution to a separate tool (codex-spec-runner), and stops at a draft PR -- it never merges anything itself.

Your job: debate the proposal below and converge on answers to the Open Questions at the end. Disagree with each other if warranted. Flag anything that looks unsafe, overbuilt, or premature. Do not just rubber-stamp it.

---

Current architecture (facts, not proposal)

- Providers are pluggable per pipeline stage via a config block:
"providers": {
  "discover": "claude",
  "ideate": "codex",
  "draft": "claude",
  "negotiate": ["claude", "codex"],
  "review": "claude"
}
  Built-in adapters today: claude, codex, local (any OpenAI-compatible endpoint, e.g. a self-hosted Qwen box), devin.
- negotiate already requires every configured reviewer to independently approve the same unchanged draft. Disagreement -> bounded retries -> a clean "needs human" stop. No forced merge, ever.
- execute is hard-locked to Codex and Claude, because it hands off to codex-spec-runner, which only supports those two runners today. This cannot change without a separate change to that other tool.
- Every run writes real, auditable state: run.json (status, per-stage outcome), events.ndjson (lifecycle log), calls.tsv (every provider/csr call: stage, provider, status, duration). Cost/token fields that can't be measured are stored as "unknown" -- never fabricated.
- Already speced but NOT YET BUILT (phases 14-15 of a 22-phase master spec, only 12 phases implemented so far):
  - Arena (Phase 14): run the same spec against multiple contender harnesses/models from the same commit, in isolated worktrees, with hard eligibility gates (fails verification / touches protected paths / exceeds diff ceilings -> ineligible, full stop, no score can rescue it).
  - Blind Jury (Phase 15): multiple judge models score each eligible contender's diff on weighted categories (requirements, correctness, maintainability, risk, simplicity). Judges never see which provider/model produced a candidate -- aliased "Candidate A/B" only. Median-aggregated across judges. A too-close-to-call result is reported as such, not forced into a fake winner. Judge list defaults to whatever's already configured for negotiate/review if not set explicitly.

The proposal under review

Add an openrouter provider adapter (OpenRouter: one API key, ~hundreds of models -- DeepSeek, Qwen, Kimi, and others -- behind an OpenAI-compatible interface, plus a public model catalog with live per-model pricing) so any existing provider slot (discover/ideate/draft/negotiate/review -- NOT execute, per the constraint above) can use it. Three usage modes, config-selected:

1. Literal slug: "openrouter:deepseek/deepseek-chat" -- no ambiguity, no catalog dependency.
2. OpenRouter's own auto-router: "openrouter:auto" -- let OpenRouter pick the model per-request. Simpler; less controllable.
3. e3d-pilot-resolved policy: e3d-pilot caches OpenRouter's model catalog (slug, price, context length) on a TTL and resolves a policy object like:
{
  "route": "openrouter",
  "capability": "reasoning",
  "max_cost_per_million": 1.00,
  "preferred": ["deepseek/deepseek-chat", "qwen/qwen-2.5-72b-instruct"],
  "fallback": "claude"
}
   against that cache at call time, recording the actually resolved model (not just the policy) in calls.tsv/run.json for auditability. If nothing survives the filters and there's no fallback, the run stops cleanly (same posture as --max-provider-calls running out today) rather than guessing.

Once this exists, a cheap OpenRouter model becomes usable as a Phase 15 jury judge or negotiate reviewer with no changes to Phase 14/15 themselves -- they already derive their model list from existing provider config.

Rollout is staged: (1) adapter with literal-slug/auto support only, (2) catalog cache + inspection command, (3) policy-object resolution, (4) real per-call cost accounting (OpenRouter's response includes token usage; the catalog has real prices, so actual cost -- not "unknown" -- can be computed and fed into the Flight Recorder report).

Cost reality (verified against OpenRouter's own pricing page, Sept 2026)

- Pay-as-you-go, not subscription. No markup on top of provider list price.
- Revenue comes from a platform fee on credit top-ups: 5.5% (min $0.80) for card payments, 5.0% flat for crypto.
- BYOK (routing through OpenRouter but billing your own provider key) is free up to $25,000/month of list-price inference, then 5%.
- Dozens of genuinely free, rate-limited models exist (~20 req/min, 200/day) -- plausible for cheap discover/ideate/judge calls at low volume.
- Credits expire 365 days after purchase; refunds only within 24h of purchase; the platform fee itself is never refundable.

Explicitly out of scope for this debate

- Migrating any infrastructure off a home LAN machine (parked separately, unrelated to this proposal).
- A lead-generation/outreach automation system for an unrelated business service. Not relevant here -- don't let it leak into this debate.
- Extending codex-spec-runner to support OpenRouter as an execute-stage runner. Acknowledged as future/separate work, not decided here.

---

Open Questions -- converge on an answer for each

1. Default mode: should a bare "openrouter" value (no explicit mode) mean auto, or should it be a schema error demanding an explicit choice? Argue the safety/predictability tradeoff.
2. Capability tagging: OpenRouter's own capability/category metadata is coarse. Is a small built-in mapping (mirroring how analogy_domains has a sensible built-in default today) good enough, or does this need repo-level config from day one?
3. Cost ceiling default: should max_cost_per_million be required in every policy object, or is an unset ceiling (meaning "no cap, pick the best preferred match") acceptable given fallback and hard-gates exist elsewhere in the pipeline?
4. Failure posture: is "clean stop, no fallback" the right default when a policy resolves to nothing, or should there always be an implicit fallback to a directly-configured frontier provider, even if the config didn't specify one -- trading predictability for fewer needs-human stops?
5. Judge diversity vs. cost: once Phase 15 exists, is it better practice to put 2-3 cheap OpenRouter models as judges with one frontier tie-breaker, or 1 cheap + 1 frontier judge with tie going to human review? Which produces a more trustworthy too-close-to-call signal?
6. Catalog staleness risk: a 24h default TTL means prices can lag OpenRouter's actual live prices by up to a day. Is that acceptable given costs are typically small per call, or should pricing be fetched live (uncached) at policy-resolution time regardless of the slower call path it implies?
7. Anything unsafe or overbuilt: does this proposal violate e3d-pilot's core invariant -- "unattended does not mean unsupervised, a human still owns the irreversible decision" -- anywhere? Is any part of this bigger than the problem it solves?

Produce a final recommendation: adopt as designed, adopt with named changes, or reject with reasons. Be concrete about which Open Question answers drove the recommendation.

## Round 1 -- claude

**Recommendation: adopt with named changes.**

1. **Default mode**: Schema error. "openrouter" bare is ambiguous between three semantically different behaviors (literal, auto, policy) with different audit/cost implications. Silent defaulting to auto trades predictability for convenience the config author didn't ask for. Cost is one extra required field; forcing the choice costs nothing and matches the pipeline's existing "no guessing" posture (max-provider-calls, empty policy match).

2. **Capability tagging**: Small built-in mapping is enough for v1, same precedent as analogy_domains. OpenRouter's categories are coarse but stable enough for coarse routing (reasoning/cheap-fast/long-context). Repo-level override should be supported from day one as an escape hatch, but the built-in default shouldn't block adoption — this is Phase-ordering, not a blocker.

3. **Cost ceiling**: Unset should be allowed, not required. Hard gates already exist downstream (Arena eligibility, diff ceilings, negotiate unanimity) and `fallback` plus the clean-stop-on-empty-match behavior bound the blast radius. Forcing every policy to declare a ceiling adds friction without adding safety — the real backstop is architectural, not a per-call number.

4. **Failure posture**: Clean stop is correct, no implicit fallback. An unconfigured, invisible frontier fallback is exactly the kind of implicit magic this system has avoided everywhere else (see: no forced merge, no fabricated cost fields). "Needs human" is cheap; a silent fallback that quietly starts spending on Claude because a policy filter was too strict is a worse failure mode than a stop.

5. **Judge diversity**: 2-3 cheap OpenRouter judges + 1 frontier tiebreaker. A single frontier vs single cheap judge with tie-to-human is functionally just negotiate again with extra steps — it doesn't exploit what Blind Jury is for (median aggregation smoothing individual model quirks). More cheap judges genuinely diversify failure modes; the frontier model earns its cost only as a tiebreaker, not a co-equal voter.

6. **Catalog staleness**: 24h TTL is fine. Per-call costs here are small (judge/discover/ideate calls, not execute), and live-fetching on every policy resolution adds a network round-trip to the hot path for a risk that's bounded by the ceiling check itself (worst case: you compare against a slightly stale price, still under any sane ceiling).

7. **Unsafe/overbuilt check**: Nothing here touches execute or negotiate's unanimity requirement — the irreversible-decision boundary is untouched. The only overbuilt risk is jumping straight to policy-object resolution before the adapter or catalog cache exist; the staged rollout already avoids this. Ship stages 1-2 now, gate 3-4 on real usage data.

## Round 1 -- codex

Recommendation: adopt with named changes. Ship literal-slug support first; treat dynamic policy routing as optional follow-on, not a prerequisite for Arena/Jury.

1. Bare `openrouter` should be a schema error. `auto` changes model identity between calls, weakening reproducibility and reviewer independence. Require `openrouter:auto` explicitly and record the resolved model whenever OpenRouter exposes it.

2. Provide a small versioned built-in capability map plus repo-level overrides from day one. Record the mapping version in run state. OpenRouter metadata alone is too coarse for safety-sensitive selection.

3. Require a cost ceiling for every policy object. Otherwise “policy routing” can silently become unbounded spending. The schema must distinguish input, output, cached-input, and reasoning-token pricing; one ambiguous blended “per million” ceiling is insufficient.

4. Fail closed when nothing matches. Never invent an implicit frontier fallback: it surprises operators, changes trust boundaries, and may incur materially different costs. Explicit fallback remains appropriate.

5. Prefer one cheap judge plus one frontier judge, with disagreement or a narrow margin going to human review. Two correlated cheap models can manufacture a majority without adding genuine independence. A frontier “tie-breaker” also risks disguising disagreement as certainty.

6. A 24-hour catalog TTL is acceptable. Live fetching on every resolution adds availability dependence without guaranteeing the price remains unchanged during inference. Require a fresh-enough cache, configurable TTL, conservative price comparison, and actual post-call cost recording. A stale or unavailable cache should stop policy resolution, while literal slugs remain usable.

7. The adapter does not violate the human-ownership invariant because execution remains constrained and publishing stops at a draft PR. The real risks are subtler:

- `auto` reviewers may unknowingly resolve to the same underlying model, defeating independent consensus.
- Provider diversity is not model-family diversity; resolved identities must be checked and logged.
- Dynamic capability routing can make identical commits/configs behave differently over time.
- Building the full policy engine before Phases 14–15 is premature unless current users need it.

Ship stages 1–2 now, with explicit modes and audit fields. Defer stage 3 until Arena/Jury creates demonstrated demand, then require explicit ceilings, explicit fallbacks, diversity checks, and versioned resolution metadata.

## Round 2 -- claude

My prior position holds up on most points; I'll restate briefly and engage where codex diverges from me.

**Agree with codex on**: bare `openrouter` as schema error (both of us converged here, correcting nothing — this was already my position). Fail-closed on empty policy match: same conclusion, though codex's framing (surprises operators, changes trust boundaries) is sharper than mine.

**Diverge on #3, cost ceiling**: codex requires a ceiling in every policy object; I still don't. codex's argument — "policy routing can silently become unbounded spending" — proves too much: the `preferred` list is already a closed, explicit set of models the author chose. There's no unbounded search space to guard against; the worst case is "the most expensive model in a list you wrote yourself" gets picked, which is bounded by construction. A ceiling adds a second, redundant guard against a risk the explicit list already caps. Where I'd shift: codex is right that a single blended "per million" number is a bad shape once a ceiling *is* set — input/output/reasoning pricing differ enough that one number invites false confidence. If we require a ceiling for the "no explicit preferred list, just a capability filter" case (which is the actually-unbounded case), it should be structured, not scalar.

**Diverge on #5, judge composition**: codex's "1 cheap + 1 frontier, disagreement to human" is more conservative than my "2-3 cheap + 1 frontier tiebreaker," and codex's specific objection — correlated cheap models manufacturing a false majority — is a real risk I underweighted. But codex's fix (only 2 judges total) throws away median aggregation entirely, which is the actual point of Phase 15 existing instead of just negotiate again. The better fix is diversify judge *families*, not shrink judge *count*: 2 cheap judges from different model families (not two DeepSeek variants) plus 1 frontier tiebreaker preserves median-smoothing while addressing correlation. I'm updating toward requiring family diversity as a named constraint, not toward codex's 2-judge design.

Both of us land in the same place operationally: ship stages 1-2, defer 3-4, no execute/negotiate boundary violated. The remaining daylight (ceiling-required-always vs. ceiling-required-only-when-unbounded; 2-judge vs. diversified-3-judge) would change what an implementer actually builds.

POSITION: Adopt with named changes — schema-error default, fail-closed with no implicit fallback, ceiling required only for capability-filter (non-list) policies with structured (not blended) pricing fields, and judge panels must enforce model-family diversity rather than just judge count.
status: revise

## Round 2 -- codex

My prior position holds: adopt with named changes, but separate the useful adapter from the premature policy engine.

1. Bare `openrouter` must be a schema error. `openrouter:auto` materially changes reproducibility, cost, and model independence; convenience does not justify implicit routing.

2. Use a small, versioned built-in capability map with repo-level overrides from day one. I agree with Claude that built-ins are sufficient defaults, but disagree that overrides can wait: misclassification must be locally correctable without a release.

3. Require an explicit cost ceiling for policy routing. Claude’s reliance on downstream safety gates is misplaced: those gates constrain code risk, not API spending. Moreover, replace ambiguous `max_cost_per_million` with separate input/output—and where applicable cached-input and reasoning-token—limits or a clearly defined worst-case calculation.

4. Fail closed when no model qualifies. Never invent a frontier fallback; fallback identity and expenditure must be explicit.

5. Prefer one cheap and one frontier judge, with disagreement or a narrow result sent to a human. I reject Claude’s cheap-model majority plus frontier tie-breaker: cheap models may share training, architecture, or systematic blind spots, while a tie-breaker converts genuine disagreement into artificial certainty. Blind Jury should expose uncertainty, not adjudicate it away.

6. A configurable 24-hour TTL is acceptable. Require a sufficiently fresh cache and conservative ceiling comparison; cache failure or excessive age stops policy resolution. Literal slugs should remain available. Actual response usage should produce post-call cost records.

7. The adapter preserves human ownership because it neither expands execute nor merges. The hazards are reviewer aliasing, correlated “diversity,” changing resolutions over time, and opaque `auto` choices. Log resolved model identity, catalog timestamp, mapping version, policy inputs, and resolution reason; reject negotiate/jury configurations whose supposedly independent reviewers resolve to the same model.

Ship stages 1–2 now. Defer stage 3 until demonstrated demand from Arena/Jury, then require explicit ceilings, fallbacks, overrides, and diversity checks. Stage 4 should accompany—not trail far behind—production policy routing.

POSITION: Adopt literal and auto OpenRouter support now, but defer policy routing until it has explicit cost limits, fail-closed resolution, versioned overrides, and resolved-model diversity checks.
status: revise


## Synthesis (claude)

FINAL ANSWER: Adopt with named changes: ship stages 1–2 now (literal-slug and explicit `openrouter:auto` only — bare `openrouter` is a schema error), and defer stage 3 (policy-object routing) until Arena/Jury creates real demand. When policy routing lands, require fail-closed resolution with no implicit fallback, structured (not blended) cost limits at least for capability-filter (non-list) policies, a versioned/overridable capability map, and resolved-model + model-family diversity logged and enforced for negotiate/jury panels. A 24h catalog TTL is acceptable.

CONSENSUS: majority

DISSENT: Both rounds agree on schema-error default, fail-closed, staged rollout, and diversity-logging, but never converge on whether cost ceilings are always required (codex: yes, always, structured; claude: only when the policy has no explicit `preferred` list) or on judge composition (codex: 1 cheap + 1 frontier, tie to human; claude: 2-3 family-diverse cheap judges + frontier tiebreaker) — these are implementation-level details to resolve when stage 3/Phase 15 is actually built, not blockers to adoption now.
