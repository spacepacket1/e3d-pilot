# Debate

**Question:** We need a real architectural decision, not a generic pros/cons list.

Question:

Should e3d-pilot integrate Linear as its external work-management layer, or should e3d-pilot remain self-contained and continue building its own issue/workflow/project-management capabilities?

Current conceptual stack:

Slack = conversation / intake
Linear = issue tracking / work state / coordination
GitHub = implementation truth
e3d-pilot = reasoning, orchestration, decision-making, execution
E3D provenance graph = long-term cognitive memory / decision history

Proposed flow:

Slack
→ Linear issue
→ delegate to E3D Pilot
→ discover
→ ideate
→ draft
→ negotiate
→ decide
→ execute
→ review
→ publish
→ GitHub PR / commit
→ Linear status update
→ Slack update

Core distinction under consideration:

Linear manages work:
"What needs to be done, who owns it, and what state is it in?"

E3D Pilot manages reasoning:
"Should we do this, why, what alternatives exist, what did multiple models think, what did we decide, how should it be implemented, what happened afterward, and what should we learn?"

We want to avoid rebuilding commodity functionality if Linear, GitHub, Slack, OpenRouter, Claude Code, Codex, Devin, Cursor, and similar systems are already commoditizing it.

But we also do not want to hollow out e3d-pilot or make it dependent on someone else's product direction.

Run this as an adversarial debate.

## Position A: Integrate Linear aggressively

Argue that e3d-pilot should stop building project-management/work-tracking functionality and use Linear as the human/agent coordination layer.

Push the strongest case for:

* leverage
* speed
* reduced product surface
* avoiding commodity infrastructure
* better Slack UX
* agent-native issue assignment
* APIs/webhooks/MCP/agent interfaces
* less UI burden
* faster dogfooding
* clearer product boundary
* focusing engineering effort on reasoning/provenance/multi-model orchestration

Assume Linear will continue improving rapidly.

Answer:

* What should Pilot delete or stop building?
* What should Linear own entirely?
* What should become a thin adapter?
* How much complexity does this remove?
* Does this make Pilot more differentiated?

## Position B: Keep Pilot self-contained

Argue that using Linear is strategically dangerous.

Push the strongest case for:

* vendor lock-in
* duplicated state
* fragile synchronization
* dependency on Linear's roadmap
* loss of UX control
* eventual feature overlap
* Linear moving up-stack into agents/reasoning
* provenance-integrity risk
* fragmented identity/state
* API/pricing changes
* complexity caused by an external work system

Answer:

* Which parts become liabilities?
* What would we regret outsourcing?
* What should Pilot own even if Linear already does it?
* Could Pilot's work graph and provenance graph eventually become one unified system?
* Does owning the work layer create a stronger moat?

## Position C: Pilot core + adapters

Do not treat hybrid as an automatic compromise.

Evaluate this architecture independently:

* Pilot owns canonical internal objects
* Linear is one adapter
* GitHub Issues could be another
* Shortcut/Jira could be others
* Pilot can operate without any external tracker
* external systems mirror/project Pilot state
* provenance remains fully internal
* adapters remain replaceable

Evaluate whether the right internal abstraction is something like:

WorkItem
Decision
Run
AgentExecution
Artifact
Evidence
Outcome
ExternalReference

Determine whether Pilot should have a minimal internal work model without building a full project-management product.

## The 10x incumbent stress test

This is mandatory.

Assume all of the following become 10x better over the next 2-3 years:

* Linear
* GitHub
* OpenRouter
* Claude Code
* Codex
* Devin
* Cursor
* Slack AI
* model-native memory
* agent frameworks

Assume specifically that:

* coding agents become highly autonomous
* Linear gets much better agent orchestration
* GitHub gets much better autonomous issue→PR execution
* OpenRouter handles routing, fallback, cost optimization, and model selection extremely well
* Claude Code/Codex can plan, code, review, and self-correct reliably
* Slack can create and route structured work directly
* model context windows become huge
* persistent memory becomes common
* basic multi-agent workflows become commodity

Now answer:

**What still matters about e3d-pilot?**

Do not answer with vague terms such as "orchestration," "AI workflow," or "agent coordination" unless the capability is defined precisely and is difficult for those systems to absorb.

For every claimed differentiator, answer:

1. Why would Linear not build this?
2. Why would GitHub not build this?
3. Why would OpenRouter not build this?
4. Why would Claude/OpenAI/model vendors not build this?
5. Why is this valuable enough for a user to adopt an additional system?
6. Does it get stronger as models improve, or weaker?

If the honest conclusion is that a capability is likely to disappear into incumbent platforms, say so.

## Identify the durable kernel

Determine whether the durable core of Pilot is any combination of:

* multi-model independent deliberation
* structured disagreement
* explicit dissent preservation
* adversarial critique
* negotiation/convergence
* decision provenance
* evidence-linked reasoning
* cross-model shared context
* persistent memory of why decisions were made
* outcome feedback loops
* reusable cognitive history
* question → decision → execution continuity
* model-independent cognition layer
* graph-based reasoning
* longitudinal learning across projects
* governance/policy boundaries
* human approval and escalation logic
* decision quality measurement over time

For each capability classify it as:

* commodity now
* likely commodity within 12 months
* likely commodity within 2-3 years
* potentially durable
* strongly defensible

Explain why.

## Anti-moat test

Actively try to destroy the Pilot thesis.

Ask:

* Is multi-model debate just temporary scaffolding until one model becomes good enough?
* Does larger context eliminate the need for a provenance graph?
* Does model memory eliminate shared context?
* Does Linear eventually absorb decision history?
* Does GitHub absorb software-specific reasoning?
* Does OpenRouter eventually absorb multi-model selection and debate?
* Does Pilot add latency without enough decision-quality improvement?
* Is the provenance graph useful enough to justify maintaining it?
* Does a solo developer actually need this once coding agents improve?
* Are we solving a permanent problem or a transitional problem?

Do not protect the current architecture from criticism.

## OpenRouter test

Ask whether we are making the same mistake with Linear that we could make with OpenRouter:

Are we building functionality that a larger infrastructure provider is structurally better positioned to absorb?

Evaluate these subsystems individually:

* model routing
* model invocation
* cost optimization
* model selection
* Slack intake
* issue tracking
* agent assignment
* workflow state
* coding execution
* code review
* multi-model debate
* negotiation
* provenance
* shared context
* decision memory
* outcome learning
* graph reasoning
* governance
* approval boundaries

Classify each as:

* buy/integrate
* thin adapter
* own
* experimental
* stop building

## Architecture comparison

Compare at least these three:

### A. Linear-centric

Slack
→ Linear
→ E3D Pilot
→ GitHub
→ Linear

Linear owns work state.

### B. Pilot-centric

Slack
→ E3D Pilot
→ GitHub

Pilot owns work state and reasoning.

### C. Pilot-core + adapters

Slack / Linear / GitHub Issues / CLI / API
→ adapter layer
→ Pilot internal work model
→ reasoning/provenance
→ execution
→ external systems updated

For each evaluate:

* simplicity
* engineering effort
* operational risk
* vendor risk
* UX
* agent friendliness
* product differentiation
* portability
* observability
* provenance integrity
* failure recovery
* long-term strategic value

## Dogfood reality

We are a very small team and use e3d-pilot ourselves every day.

Optimize for:

* low cost
* high leverage
* fast iteration
* minimal administrative overhead
* strong agent workflows
* maintaining architectural optionality

Do not optimize for enterprise bureaucracy.

Also ask:

If Chris can accomplish the same outcome by combining Linear + Claude Code + Codex + GitHub + OpenRouter with a few scripts, what compelling reason remains to use e3d-pilot?

That answer must be concrete.

## Minimal integration challenge

If recommending Linear integration, propose the smallest MVP worth building.

Example:

Linear webhook
→ map issue to Pilot run
→ create provenance entry
→ execute selected Pilot pipeline
→ post structured result to Linear
→ attach PR/commit
→ update status
→ notify Slack

Specify:

* event contracts
* source of truth
* retry/idempotency strategy
* identity mapping
* state machine
* internal vs mirrored data
* outage behavior
* loop prevention
* minimum permissions
* security boundaries

Do not overbuild.

## Minimal internal alternative

If recommending against Linear, define the minimum internal work model needed to preserve strategic control without recreating Jira.

## Debate format

Each model should:

1. Give its independent position before seeing others.
2. State the strongest argument against its own position.
3. Identify assumptions that could make its conclusion wrong.
4. Critique the other models.
5. Identify genuine unresolved disagreements.
6. Update its position after critique if warranted.

Do not force consensus.

Preserve dissent.

## Final synthesis

End with:

* recommended architecture
* confidence level
* strongest dissenting view
* what Pilot should own
* what Pilot should explicitly not own
* what Linear should own
* what should remain replaceable
* what becomes commodity
* what remains differentiated
* smallest MVP
* what to measure while dogfooding
* explicit success criteria
* explicit kill criteria
* the architectural decision we would regret most if wrong

And answer these two questions plainly:

**1. If Linear, GitHub, OpenRouter, Claude Code, and Codex all become 10x better, what is the irreducible reason e3d-pilot should still exist?**

**2. Does integrating Linear make e3d-pilot more strategically focused, or does it risk turning Pilot into merely another agent behind someone else's platform?**

## Round 1 -- claude

# Position: Pilot-core + adapters, with Linear as the only adapter built now — reject both pure-integrate and pure-self-contained

## Independent position

Build a minimal internal work model (`WorkItem`, `Decision`, `Run`, `AgentExecution`, `Artifact`, `Evidence`, `Outcome`, `ExternalReference`) inside e3d-pilot, and connect Linear as a thin, replaceable adapter that mirrors state one-way-dominant (Pilot is source of truth for reasoning/decision state; Linear is source of truth for human-visible work state; each direction is explicit, not bidirectional sync). Do not build a Jira clone. Do not delete Pilot's existing idea/run ledger — extend it to the abstraction above and let Linear issues become one kind of `ExternalReference`, alongside GitHub issues later if needed.

Reasoning: the question conflates two different systems that only look similar because both track "things to do." Linear tracks *human coordination state* (who, when, what column). Pilot's ledger tracks *reasoning state* (why we decided, what alternatives were rejected, what evidence supported it, what happened after). These have different lifecycles, different audiences, and different failure costs. Losing a Linear issue costs you a status board. Losing a provenance record costs you the ability to answer "why did we build this feature this way" six months later — which is the entire product. Merging them into one system means either Pilot inherits Linear's data model constraints (issues, not decisions) or Linear has to absorb Pilot's graph structure (which it has no incentive to do). Neither is acceptable, so keep them separate and connected by reference, not by fusion.

## Strongest argument against my own position

The adapter layer is itself a tax. Every "just build a thin adapter" plan in software history has grown into a second product because the abstraction (`WorkItem`) never actually stays thin — webhooks fire out of order, identity mapping breaks on renames/merges, retries create duplicate provenance entries, and within a year you're maintaining a bidirectional sync engine, which is exactly Position B's worst-case scenario, just introduced gradually instead of upfront. A two-person team building a general internal work-item abstraction *before* they have two external systems to justify it is premature generalization — the same anti-pattern the project's own engineering norms explicitly warn against ("three similar lines is better than a premature abstraction"). If Linear is the only adapter that will exist for the next year, the honest move is to write the Linear integration directly against Pilot's existing idea/run ledger and defer the abstraction until a second adapter actually demands it.

## Load-bearing assumptions that could make this wrong

1. **Assumes Chris will eventually want a second external tracker (GitHub Issues, Jira) or multiple humans/teams routing work through Slack.** If e3d-pilot stays a single-operator tool forever, the abstraction cost never pays for itself and Position A (integrate directly, no internal model) wins outright.
2. **Assumes provenance quality is actually the differentiator worth protecting.** If in practice Chris mostly uses Pilot for single-shot draft→PR tasks and rarely revisits "why did we decide this" months later, the provenance graph is over-engineered ceremony, not a moat.
3. **Assumes Linear webhooks/API stay stable and cheap.** If Linear's agent-orchestration features (mentioned in the prompt as a plausible near-future direction) start requiring paid tiers or restrict API access for agent-driven workflows, the adapter's cost changes.
4. **Assumes coding agents (Codex/Claude Code/Devin) do NOT converge on doing their own lightweight provenance tracking well enough for a solo/small team.** If they do, the "durable kernel" argument weakens a lot faster than 2-3 years.

## The 10x incumbent stress test — answered precisely, not vaguely

Run each surviving claim through the five questions.

**Multi-model independent deliberation + structured disagreement.** Why wouldn't OpenRouter build this? Because OpenRouter's business is routing a single request to the best model, not orchestrating N models against each other and preserving the disagreement as an artifact — that's a product decision about *what to keep*, not a routing decision. Why wouldn't a model vendor build it? Because Anthropic/OpenAI have a structural conflict of interest: a vendor-run "multi-model debate" feature would have to showcase competitors' models losing arguments to their own, which they will avoid, or it becomes single-vendor "self-critique," which is a materially weaker signal than independent cross-vendor dissent. This gets *stronger* as models improve, not weaker — better models produce sharper, more informative disagreement rather than converging to identical answers (this very transcript is evidence: three models are independently reasoning about the same prompt for the value of comparing outputs, not because any one model can't answer alone). **Verdict: potentially durable, leaning strongly defensible**, conditional on it actually being used to change decisions rather than as theater.

**Decision provenance / evidence-linked reasoning, persisted across runs.** Why wouldn't Linear build this? Because Linear's data model is issues-and-states; adding "why did we reject this alternative, with links to the discarded draft and the losing model's argument" is off-roadmap for a PM tool serving thousands of customers who don't want an AI philosophy log cluttering their board — it's a feature for AI-native power users, not Linear's median buyer. Why wouldn't GitHub build it? GitHub could plausibly add "PR provenance" (commit → issue → discussion), but that's implementation truth, not decision truth — it won't capture "we considered three architectures and rejected two before writing this PR" unless the rejected paths were ever expressed as GitHub artifacts, which they usually aren't. Why wouldn't a model vendor build it? Persistent cross-session memory is coming, but vendor memory is scoped to *that vendor's model remembering you*, not a vendor-neutral record of what multiple competing models concluded. **Verdict: likely commodity within 2-3 years for the "remember what I decided" piece (model memory absorbs a chunk of this), but the cross-vendor neutrality and explicit alternative-preservation piece stays potentially durable** — narrower than the current framing assumes.

**Issue tracking, workflow state, agent assignment.** All of these lose outright to Linear/GitHub under the stress test — commodity now, and actively getting more commodity as those platforms add agent-native features. Building or maintaining these inside Pilot is pure liability with no defensibility. This is the strongest, cleanest conclusion in the whole exercise: don't build a tracker.

**Model routing, invocation, cost optimization.** Commodity now via OpenRouter, and Pilot should never re-implement this — buy/integrate, full stop.

**Coding execution, code review (mechanical).** Commodity within 12-24 months as Claude Code/Codex/Devin improve — Pilot should not compete on "can it write correct code," it should compete on "did multiple independent reasoners sign off on *this* code for *these* reasons before it shipped."

## Durable kernel — classified

- Multi-model independent deliberation: **potentially durable → strongly defensible** if actually decision-changing.
- Structured disagreement / explicit dissent preservation: **strongly defensible** — no incumbent has commercial incentive to preserve "the model that lost the argument," but this is exactly the audit trail a small team making irreversible architecture calls needs.
- Adversarial critique / negotiation-to-convergence: **potentially durable**, converges toward commodity if agent frameworks standardize a "critique round" primitive (plausible within 2-3 years).
- Decision provenance graph: **likely commodity within 2-3 years** for the storage/memory mechanics, **potentially durable** for the cross-vendor neutrality guarantee.
- Cross-model shared context: **likely commodity within 12 months** — this is squarely what bigger context windows and agent frameworks are optimizing for.
- Outcome feedback loops / decision-quality measurement over time: **potentially durable**, mostly unbuilt anywhere, valuable, but unproven — the risk is nobody (including this team) yet knows how to measure "was this decision good" cheaply.
- Governance / approval boundaries: **likely commodity within 12-24 months** — every agent framework is racing to add human-approval gates; don't expect to defend this.
- Graph-based reasoning / longitudinal learning across projects: **potentially durable**, but only if the graph is actually queried and acted on, not just accumulated. Right now (per memory of this repo) it's accumulated more than queried — a real risk.

## Anti-moat test — no protection given

Multi-model debate probably *is* partly scaffolding for weaker models. As of today, Claude 5/GPT-5-class models still disagree meaningfully on architecture calls (this exact prompt), so the scaffolding hasn't expired — but it will keep shrinking in scope as ceiling models rise, and betting the whole product thesis on debate staying valuable forever is not honest. Larger context does *not* eliminate the need for a provenance graph — context windows hold conversation, not structured, queryable, cross-run decision history; that's a retrieval/structure problem, not a size problem, and it survives even 10M-token windows. Model memory does not eliminate shared context need for a *specific reason*: vendor memory is single-vendor and single-account; a team using three different model providers needs a neutral place those providers' outputs meet, and no vendor will build the neutral meeting point for a competitor's model. Linear probably does *not* absorb decision history in the "why" sense within 2-3 years — it's plausible but not their obvious roadmap given their target buyer is PM-workflow-first, not AI-reasoning-first. GitHub *does* plausibly absorb software-specific reasoning (they're closest to code, closest to Devin-style autonomous PR generation) — this is the single most credible threat to Pilot's differentiation and should be watched, not dismissed. OpenRouter absorbing multi-model *debate* specifically (not just routing) is unlikely — debate requires holding and comparing full outputs, not selecting one, which is a different product surface than routing. Pilot adds latency for genuinely uncertain claim: on any question where the "obviously right" answer exists, debate is pure overhead; the honest position is Pilot should be invoked selectively for decisions with real ambiguity or blast radius, not universally. A solo developer likely does *not* need this for routine CRUD-level work even today — this system is justified for irreversible/architectural/cross-cutting decisions, not for every task, and pretending otherwise oversells it.

## OpenRouter test — same discipline applied to Linear

| Subsystem | Classification |
|---|---|
| model routing / invocation / cost optimization | buy/integrate |
| model selection | buy/integrate (OpenRouter), Pilot decides *when* to invoke multiple, not *how* to route each |
| Slack intake | thin adapter |
| issue tracking / workflow state / agent assignment | buy/integrate (Linear) — stop building any of this internally |
| coding execution | buy/integrate (Codex/Claude Code/Devin) |
| code review (mechanical/lint-level) | buy/integrate |
| multi-model debate | own |
| negotiation/convergence | own |
| provenance | own |
| shared context (cross-model, cross-run) | own |
| decision memory | own |
| outcome learning | experimental — own the hooks, don't oversell the maturity |
| graph reasoning | experimental |
| governance/approval boundaries | thin adapter — implement the gate, don't build a policy engine |

This is the actual answer to "are we making the OpenRouter mistake with Linear": no, provided Pilot only owns the row above marked "own" — reasoning-layer functions no incumbent is structurally motivated to build neutrally. The mistake would be building issue tracking, workflow state, or agent assignment internally, which the current proposed flow already correctly routes through Linear.

## Architecture comparison (condensed to decision-relevant deltas)

**A. Linear-centric:** best simplicity and UX today, worst vendor risk and worst provenance integrity — Linear's data model will visibly strain the moment you try to store "rejected alternative + losing model's reasoning" as a Linear comment thread. Fine for a proof of concept, wrong as the permanent design.

**B. Pilot-centric (no Linear at all):** best provenance integrity and portability, worst UX/leverage — rebuilds coordination UI Chris doesn't need to rebuild, and forfeits Slack-native intake UX Linear already does well.

**C. Pilot-core + adapters:** best long-term strategic value and portability, worst near-term simplicity (adapter layer is real engineering cost, identity mapping and idempotency are genuinely hard). This is the only option that survives the 2-3 year incumbent-improvement scenario without either (a) hollowing Pilot into "a Linear bot" or (b) leaving Chris maintaining a tracker nobody asked for.

Given team size is one to a few people, C's near-term cost is the real objection — but the MVP below keeps that cost small by building the abstraction only as wide as the one adapter that exists today.

## Dogfood reality check — the concrete test

If Chris can get the same outcome from Linear + Claude Code + Codex + GitHub + OpenRouter + a few scripts, what does Pilot add? Concretely: those tools give you *one model's* opinion, executed once, with a human approving a diff. They do not give you a persisted record that three independent models considered two other architectures, one model dissented and why, and six weeks later when the decision looks wrong, you can query *what evidence was available at decision time* rather than re-litigating from scratch. That is the actual product. If that record is never queried in practice, Pilot is not earning its keep over the script-combo, and that's a legitimate kill signal to watch for, not to explain away.

## Minimal integration MVP (Linear)

- **Event contract:** Linear webhook on issue create/status-change → Pilot receives `{issue_id, team, state, title, body, labels}`; Pilot never polls, Linear never receives anything except the specific status/comment writes Pilot issues.
- **Source of truth:** Linear owns `state` (backlog/in-progress/done, human-visible). Pilot owns `Decision`/`Run`/provenance. `ExternalReference{system: "linear", id, url}` on the internal `WorkItem` is the only join key — one row, no bidirectional sync engine.
- **Identity mapping:** Linear issue ID → Pilot `WorkItem.id` is created once on first webhook receipt and is immutable; if the mapping is missing on a webhook, create it, never guess by title match.
- **Idempotency:** webhook delivery ID stored and checked before processing; duplicate deliveries are no-ops. Retries on Pilot's writes back to Linear use Linear's idempotency key support or fall back to "check current state before writing."
- **State machine:** Linear states drive at most three Pilot transitions — issue created → run queued; issue moved to an explicit "approved" state → execution allowed to proceed past any human-gate; issue closed/cancelled → run cancelled if still active. Everything else (discover/ideate/draft/negotiate/decide internals) is invisible to Linear until it produces one of: a status update comment, a PR link, or a terminal state.
- **Outage behavior:** if Linear is unreachable, Pilot runs continue and queue their status updates for retry; Pilot never blocks execution on Linear's availability — Linear is a mirror, not a gate, except for the single explicit approval-state transition above.
- **Loop prevention:** Pilot's own writes to Linear (status comments) are tagged with a bot actor; the webhook handler ignores events whose actor is that bot identity.
- **Permissions/security:** Linear API token scoped to a single team/workspace, write access limited to comment + state-transition on issues it created the mapping for; never grant workspace-admin scope.

Overbuild to avoid: don't sync labels, assignees, priorities, or sub-issues — none of that is reasoning state, and syncing it is exactly the bidirectional-sync trap that makes Position B's warnings come true.

## Final synthesis

**Recommended architecture:** C — Pilot-core internal work model + Linear as the first (and for now, only) adapter, built directly against the existing idea/run ledger rather than a speculative general abstraction until a second adapter is actually needed.

**Confidence:** medium-high on "don't let Linear own reasoning state," medium on "build the full `WorkItem`/`Decision`/`Run`/... abstraction now" — the abstraction should be introduced incrementally, only as wide as today's single integration demands.

**Strongest dissenting view:** Position A is right that for a team of Chris's size, engineering an adapter layer before a second external system exists is speculative cost with no current payoff — the honest move might be a direct Linear integration against the existing ledger, revisited only if/when a second tracker shows up.

**Pilot should own:** multi-model debate, negotiation/convergence, decision provenance, cross-model shared context, outcome-feedback hooks.

**Pilot should explicitly not own:** issue tracking, workflow/state UI, agent-assignment UI, model routing/invocation mechanics, mechanical code review.

**Linear should own:** human-visible work state, Slack-facing coordination UX, assignment/prioritization UI.

**Should remain replaceable:** the adapter layer itself — Linear today, GitHub Issues or nothing tomorrow, without touching provenance internals.

**Becomes commodity:** issue tracking, agent assignment, routing/invocation, mechanical code review, governance-gate UI.

**Remains differentiated (for now, decaying on a clock):** cross-vendor dissent preservation, decision-time evidence linkage, outcome-quality feedback loops — provided they're actually queried, not just logged.

**Smallest MVP:** the Linear webhook flow above, scoped to comment + state-transition writes only.

**Measure while dogfooding:** how often the provenance/decision record is actually re-opened and used to inform a later decision (not just written); time from Slack message to Linear-visible status update; false-positive rate on the human-approval gate.

**Success criteria:** provenance queried at least a few times a month with a decision materially informed by it; Linear integration adds measurably less latency to Slack→PR turnaround than the manual alternative.

**Kill criteria:** if after ~2-3 months the provenance graph has zero re-query events, or the Linear adapter requires bidirectional field sync to stay usable, cut the losing half rather than defending it.

**Riskiest wrong call:** building the general adapter abstraction too early and having it calcify into an unused, half-general internal PM product — the mirror image of Position B's fear, arrived at from the "hybrid" side instead of the "self-contained" side.

**1. Irreducible reason Pilot should still exist if everything else gets 10x better:** a neutral place where independently-reasoning, competing models' disagreements and the evidence behind a decision are preserved and later queryable — no single-vendor coding agent or PM tool has a commercial reason to build a neutral cross-vendor dissent record, and that specific artifact is what survives every incumbent-improvement scenario examined above.

**2. Does integrating Linear focus Pilot or subordinate it?** Focuses it, on the strict condition that Linear is wired as a mirrored adapter for coordination state only, never as the store of record for decisions — the moment a decision, a rejected alternative, or a piece of evidence lives *only* in a Linear comment, Pilot has been quietly demoted to "an agent behind Linear's platform," which is the exact failure mode Position B warns about and which this recommendation is designed to make structurally impossible.

## Round 1 -- codex

# Decision

Choose **C: Pilot core + replaceable adapters**, with Linear as the first-class daily coordination interface.

Pilot should retain a minimal canonical work object because approvals, reasoning, execution, and outcomes require a stable internal anchor. It should not build a competing project-management product.

Linear owns the human-visible queue. Pilot owns the decision’s integrity.

This is already consistent with Pilot’s architecture: the append-only event ledger is canonical, materialized state is derived, and external project tracking is best-effort. The mistake would be promoting Linear—or any tracker—from projection to authority over approvals and provenance.

Confidence: **85%**.

---

# Adversarial debate

## Position A: Integrate Linear aggressively

The strongest argument is economic, not architectural.

Linear is structurally better positioned to build:

- Issue capture, editing, search, filtering, prioritization
- Teams, projects, cycles, roadmaps, labels, dependencies
- Notifications, inboxes, assignments, mentions
- Slack intake and interactive workflow
- Agent assignment and progress presentation
- Mobile and collaborative UI
- Webhook administration, OAuth, permissions, and workspace identity

Pilot could spend years building an inferior version of this without improving decision quality.

A Linear-centric Pilot would delete or stop building:

- Backlog and board UI
- Project, milestone, cycle, and roadmap concepts
- Generic assignee and team management
- Issue comments and notification infrastructure
- General-purpose workflow customization
- Saved views, search, filters, and reporting
- Slack work-intake UI
- Its current fleet work-list UI beyond diagnostic use

Linear would entirely own:

- What humans see as the backlog
- Priority, assignment, team, project, cycle, and due date
- Human coordination status
- Discussion about delivery progress
- The entry point for delegation to an agent

Pilot components would become thin adapters:

- Linear issue → Pilot WorkItem/Run
- Pilot progress → Linear comment/status
- Pilot artifact → Linear attachment/link
- PR state → Linear update
- Slack notification → link to Linear and Pilot evidence

This probably removes **30–50% of the prospective product surface**, though much less of Pilot’s existing safety and reasoning core. It accelerates dogfooding immediately and makes the boundary legible:

> Linear coordinates people and work. Pilot produces and governs decisions.

It makes Pilot more differentiated only if Pilot refuses to reproduce Linear behind the adapter.

### Strongest objection to A

Linear-centric authority makes an external issue ID the root of Pilot’s cognition. Outages, deletion, schema changes, permissions, or product strategy could then compromise execution recovery and decision history. Worse, a Linear status change could accidentally become authorization.

That is unacceptable for Pilot’s digest-bound approvals and merge gates.

---

## Position B: Keep Pilot self-contained

The strongest case is that work and reasoning are not actually separable.

A “work item” accumulates:

- The original question
- Scope revisions
- Alternatives rejected
- Approval authority
- Execution attempts
- Evidence
- Review findings
- Outcome observations

If Linear owns the item while Pilot owns the reasoning, identity and state fragment immediately. Every important operation becomes synchronization logic:

- Was the issue edited after approval?
- Did reassignment change authority?
- Does “Done” mean decided, merged, or abandoned?
- What happens if Linear deletes or merges issues?
- Which user identity approved which immutable revision?
- Can a replay reconstruct state without Linear?

What Pilot would regret outsourcing is not boards. It is the **identity and lifecycle of the decision-bearing object**.

Pilot should own even if Linear duplicates it:

- Stable WorkItem identity
- Immutable events
- Scope/content digests
- Decision and approval records
- Execution state
- Artifact and evidence references
- Outcome records
- Policy enforcement
- Recovery and replay

The work graph and provenance graph can become one unified event-derived graph. A WorkItem is not a separate PM record; it is the root node connecting question, decisions, runs, evidence, executions, artifacts, and outcomes.

Owning this layer can create a moat—but only through accumulated, outcome-linked decision history. Owning boards, priorities, and assignee UX creates no moat.

### Strongest objection to B

“Self-contained” easily becomes an excuse to build Jira. For a small team, that is fatal distraction. Even the best internal semantics will be underused if intake, notifications, triage, and daily updates are worse than Linear.

---

## Position C: Pilot core + adapters

This is not a midpoint. It draws the boundary by semantic authority.

Pilot owns canonical internal objects:

```text
WorkItem
  ├── Decision
  ├── Run
  │    └── AgentExecution
  ├── Evidence
  ├── Artifact
  ├── Outcome
  └── ExternalReference
```

Recommended meanings:

- **WorkItem:** Stable decision/execution identity, scope digest, lifecycle, policy.
- **Decision:** Alternatives, verdict, dissent, actor, confidence, approved digest.
- **Run:** One reproducible reasoning or execution attempt.
- **AgentExecution:** Provider/model/tool invocation, inputs, outputs, cost, status.
- **Evidence:** Addressable claim support with origin and freshness.
- **Artifact:** Spec, transcript, patch, PR, report, commit.
- **Outcome:** Observed result and metrics after execution.
- **ExternalReference:** Linear/GitHub/Slack identifiers, versions, URLs, and sync cursor.

Do not add internal Team, Cycle, Roadmap, Sprint, Inbox, or arbitrary board-schema objects.

Linear may be the preferred interface without becoming required infrastructure. GitHub Issues, CLI, API, or no tracker must remain possible.

The critical rule is **field ownership**, not bidirectional synchronization:

- Linear-authoritative: assignee, priority, team, project, cycle, human-facing coordination status.
- Pilot-authoritative: scope digest, decisions, approvals, reasoning state, execution state, policy, evidence, provenance, outcomes.
- GitHub-authoritative: repository content, commit SHA, PR head, checks, merge fact.
- Slack-authoritative: conversation only; never durable authorization.

This avoids duplicated authority even though data is mirrored.

### Updated position after critique

I would not make Pilot’s detailed internal stages drive a dozen Linear statuses. That recreates synchronization coupling. Linear should show only coarse delivery state plus structured comments. Pilot’s richer lifecycle stays internal.

---

# Architecture comparison

| Dimension | A. Linear-centric | B. Pilot-centric | C. Core + adapters |
|---|---:|---:|---:|
| Simplicity now | High | Medium | Medium-high |
| Engineering effort | Low | Very high | Moderate |
| Operational risk | External dependency | Internal burden | Adapter failures isolated |
| Vendor risk | High | Low | Low |
| Daily UX | Excellent | Weak for years | Excellent with graceful fallback |
| Agent friendliness | High | Potentially high | High |
| Differentiation | Risk of becoming a plugin | Diluted by PM work | Focused |
| Portability | Low | High | High |
| Observability | Fragmented | Unified | Unified internally |
| Provenance integrity | At risk | Strong | Strong |
| Failure recovery | Depends on Linear | Strong | Strong via replay/outbox |
| Long-term value | Platform-dependent | Potential but expensive | Best option value |

---

# The 10x incumbent stress test

Most of Pilot’s current pipeline becomes commodity:

- Intake and structured issue creation
- Model routing and fallback
- Agent assignment
- Planning, coding, review, and self-correction
- Basic multi-agent fan-out
- Workflow dashboards
- Large-context retrieval
- Generic persistent memory

“Orchestration” is not a durable thesis.

Three narrower capabilities may survive.

## 1. Model-independent accountable decisions

Precisely: an append-only record linking a question revision to independent answers, explicit dissent, evidence, human authority, execution artifacts, and later outcomes.

Why incumbents may not absorb it:

1. **Linear:** likely records decisions, but is optimized around mutable work state rather than immutable, digest-bound cognition.
2. **GitHub:** may capture software reasoning, but not cross-repository, non-code, or pre-issue decisions.
3. **OpenRouter:** has model-level information but not organizational authority, execution truth, or long-term outcomes.
4. **Model vendors:** can provide memory, but have weak incentives to preserve competitors’ dissent in a vendor-neutral record.
5. **Adoption value:** worthwhile when a decision is consequential, contested, resumed across sessions, or needs auditable approval. Not worthwhile for every task.
6. **Model improvement:** becomes more valuable as execution gets cheaper and decision volume rises—provided Pilot measures outcomes. Mere transcript storage becomes less valuable.

## 2. Policy-bound question-to-execution continuity

Precisely: approval is bound to the exact decided scope or PR head; later mutations invalidate authority; execution can be reconstructed without trusting a tracker’s mutable status.

Incumbent resistance:

1. Linear may add approval flows but cannot enforce every downstream execution boundary.
2. GitHub can enforce code protections but not the upstream product decision.
3. OpenRouter has no authority over repositories or organizational policy.
4. Model vendors can implement gates, but each gate is local to their agent.
5. Users adopt this only when accidental autonomous action has meaningful cost.
6. It gets stronger as agents gain autonomy because the cost of ambiguous authority increases.

## 3. Outcome-calibrated cognitive history

Precisely: measure whether prior recommendations, dissent, confidence, evidence, and implementation choices predicted real outcomes, then reuse that history in later decisions.

Incumbent resistance:

1. Linear sees work completion, not necessarily whether the decision was good.
2. GitHub sees code outcomes, not product or organizational outcomes.
3. OpenRouter sees invocations, not ground truth.
4. Model vendors may learn globally but do not expose a user-owned, inspectable longitudinal learning record.
5. Adoption is justified only if it measurably changes later recommendations.
6. It strengthens with better models because better execution produces more experiments—but disappears if the feedback never improves decisions.

These are plausible durable kernels, not guaranteed moats. The moat would be the accumulated high-quality outcome dataset and trusted policy history, not the graph implementation.

---

# Durable-kernel classification

| Capability | Classification | Reason |
|---|---|---|
| Basic multi-model independent calls | Likely commodity within 12 months | Easy fan-out |
| Structured disagreement | Likely commodity within 2–3 years | Framework feature |
| Explicit dissent preservation | Potentially durable | Requires durable product semantics, not prompting alone |
| Adversarial critique | Likely commodity within 12 months | Prompt/framework pattern |
| Negotiation/convergence | Likely commodity within 2–3 years | Useful but reproducible |
| Decision provenance | Potentially durable | Valuable across systems and time |
| Evidence-linked reasoning | Potentially durable | Harder when evidence changes and claims must remain traceable |
| Cross-model shared context | Likely commodity within 12 months | Context and memory platforms |
| Persistent “why” memory | Potentially durable | Incumbent memories tend to be platform-local |
| Outcome feedback loops | Strongly defensible if populated | Proprietary longitudinal ground truth |
| Reusable cognitive history | Potentially durable | Depends on retrieval quality and repeated use |
| Question→decision→execution continuity | Potentially durable | Crosses incumbent boundaries |
| Model-independent cognition layer | Potentially durable | Neutrality matters, but only for demanding users |
| Graph-based reasoning | Experimental | A graph is an implementation, not a benefit |
| Longitudinal cross-project learning | Strongly defensible if demonstrated | Unique accumulated context and outcomes |
| Governance/policy boundaries | Potentially durable | Autonomy increases need |
| Human approval/escalation | Likely commodity within 2–3 years | Durable only when cross-system and digest-bound |
| Decision-quality measurement | Strongly defensible if valid | Difficult ground-truth and evaluation problem |

Nothing here is strongly defensible before sufficient outcome data exists.

---

# Anti-moat verdict

- **Multi-model debate may be temporary scaffolding.** Use it selectively for high-uncertainty or high-cost decisions. Do not make model count the product.
- **Large context does not replace provenance.** It improves recall, not authority, causal attribution, immutability, or outcome measurement.
- **Model memory weakens the shared-context feature.** Generic context packaging will commoditize.
- **Linear will absorb ordinary decision history.** Pilot must offer digest-bound, evidence- and outcome-linked history or concede.
- **GitHub will absorb software-specific reasoning.** Pilot should not compete on issue-to-PR narration.
- **OpenRouter will absorb routing and selection.** Pilot should stop investing there beyond adapters and experiment controls.
- **Pilot can add unjustified latency.** Debate should be risk-triggered, not mandatory.
- **The provenance graph is not inherently valuable.** Keep it derived and disposable. Kill graph features that do not change a decision or reduce investigation time.
- **A solo developer does not need Pilot for routine coding.** The target use is consequential choices, durable autonomy boundaries, and repeated cross-session learning.
- **This may be transitional.** Without demonstrated outcome improvement, Pilot becomes elaborate middleware.

If Chris can reproduce the result with Linear, two coding agents, GitHub, OpenRouter, and scripts, Pilot’s concrete remaining value must be:

> One replayable record that shows exactly what was considered, preserves unresolved dissent, binds authorization to immutable scope, follows the result through execution, and learns whether the decision worked.

If that does not save time, prevent a mistake, or improve later decisions, Chris should use the scripts.

---

# Buy versus own

| Subsystem | Decision |
|---|---|
| Model routing/invocation/fallback/cost optimization | Buy/integrate |
| Model selection | Thin adapter; experimental evaluation |
| Slack intake | Buy/integrate |
| Issue tracking | Buy/integrate |
| Agent assignment | Thin adapter |
| Human workflow state | Linear |
| Pilot reasoning/execution state | Own |
| Coding execution | Thin adapter |
| Code review mechanics | Buy/integrate |
| Multi-model debate | Experimental; own only specialized protocol/results |
| Negotiation | Experimental |
| Provenance | Own |
| Shared context packaging | Thin adapter |
| Decision memory | Own |
| Outcome learning | Own |
| Graph reasoning | Experimental |
| Governance and approval boundaries | Own |
| Boards, cycles, roadmaps, generic PM reporting | Stop building |

---

# Smallest Linear MVP

## Contract

Accept only:

```text
Issue delegated to Pilot
Issue materially updated
Issue canceled
Explicit Pilot action requested
```

Emit:

```text
Pilot run started
Pilot awaiting decision
Pilot failed/requires attention
Pilot PR created
Pilot completed
```

Use a dedicated label or explicit integration action for delegation. Do not trigger on every issue update.

## Sources of truth

- Linear: title/display description, assignee, priority, team/project, human queue state.
- Pilot: captured scope revision and digest, runs, decisions, approvals, execution, evidence, outcomes.
- GitHub: commits, PR head, checks, merge.
- External references store Linear issue ID, workspace ID, URL, last observed version, and webhook cursor.

A Linear edit creates a new captured WorkItem revision. It never silently edits an approved revision.

## State mapping

Keep Linear coarse:

```text
Triage/Backlog → queued
Started        → Pilot active or waiting
In Review      → decision or PR requires human review
Done           → terminal result observed
Canceled       → no new work; historical record retained
```

Pilot retains its detailed lifecycle internally. Linear “Done” must not manufacture a merge or successful outcome.

## Reliability

- Verify webhook signatures.
- Deduplicate by provider event ID.
- Use `(provider, external_object_id, external_version)` for idempotent ingestion.
- Persist inbound event before processing.
- Use an outbox for Linear updates with exponential retry and dead-letter visibility.
- Include an origin marker and Pilot event ID in outbound updates.
- Ignore reflected events carrying that marker or an already-observed version.
- On Linear outage, continue authorized runs, queue updates, and expose local/CLI state.
- Reconcile one issue on demand; do not build broad bidirectional polling initially.

## Identity and security

Map Linear user ID to a Pilot actor record. Unmapped users may delegate but cannot grant privileged approval.

Minimum permissions:

- Read delegated issues and necessary identity/team metadata
- Write comments
- Update only the configured status/labels
- No workspace administration, issue deletion, or broad project mutation

Approvals remain explicit Pilot operations bound to scope digest or PR SHA. A Linear comment or generic status change is not approval.

---

# Dogfood measurements

Measure for 6–8 weeks:

- Median intake-to-start time
- Human administrative minutes per WorkItem
- Adapter failures and manual reconciliations
- Duplicate/stale status incidents
- Percentage of work completed without opening Pilot’s UI
- Percentage of consequential decisions using debate
- Debate latency and cost
- Decisions changed because of dissent or evidence
- Prevented unsafe/stale approvals
- Time to resume work in a fresh agent session
- Outcomes attached after 7/30 days
- Later decisions measurably improved by prior history

Success criteria:

- At least 80% of delegated Linear issues create or resume the correct WorkItem without manual repair.
- No external status grants execution or merge authority.
- Tracker outages lose no provenance or completed work.
- Administrative time decreases by at least 30%.
- At least 20% of selected high-risk deliberations materially change a decision, expose a missed risk, or shorten later recovery.
- Historical context demonstrably saves time on repeated work.

Kill criteria:

- More than 5% of issues require identity/state repair.
- Linear and Pilot routinely disagree about what humans should do next.
- Provenance is rarely consulted or changes no later action.
- Debate adds material latency without measurable decision changes.
- Outcome capture remains too sparse to support learning.
- The same value is reproducible with small scripts at substantially lower complexity.

---

# Final synthesis

- **Recommended architecture:** Pilot core + adapters; Linear as preferred coordination UX.
- **Strongest dissent:** Make Linear canonical for all work state and reduce Pilot to stateless reasoning jobs. This is simpler and may be correct if digest-bound governance proves unnecessary.
- **Pilot owns:** WorkItem identity/revisions, decisions, dissent, approvals, runs, evidence, artifacts, policy, provenance, and outcomes.
- **Pilot explicitly does not own:** Boards, cycles, roadmaps, general notifications, team administration, generic issue comments, or Slack UX.
- **Linear owns:** Human backlog, prioritization, assignment, project grouping, and coarse coordination state.
- **Replaceable:** Linear, Slack, model providers, routing, coding agents, and forge adapters.
- **Commodity:** Intake, routing, agent execution, generic memory, basic debate, issue-to-PR automation.
- **Differentiated:** Model-neutral, outcome-linked decision history and immutable authority across system boundaries.
- **Smallest MVP:** Delegation webhook, internal WorkItem/run, structured Linear updates, PR attachment, Slack notification, durable inbox/outbox.
- **Most regrettable wrong decision:** Making Linear’s mutable issue/status the canonical authorization and provenance record. Replacing a tracker adapter is manageable; reconstructing lost decision integrity is not.

## Plain answers

**1. If every incumbent becomes 10x better, why should Pilot still exist?**

To maintain a user-owned, model-independent, replayable chain from contested question through evidence, dissent, immutable approval, execution, and measured outcome—and use that history to improve later decisions. If Pilot cannot demonstrate that this produces better or safer decisions, it should not exist.

**2. Does Linear integration focus Pilot or reduce it to another agent?**

It focuses Pilot **only if Linear remains an adapter and coordination surface**. If Linear owns Pilot’s decision identity, approval semantics, or provenance, Pilot becomes another replaceable agent behind Linear.

Integrate Linear aggressively at the UX boundary. Keep it outside the trust boundary.

## Round 1 -- devin

---

# Architectural Position: Linear Integration vs. e3d-pilot Self-Containment

*My independent answer before seeing others.*

---

## One codebase observation before any debate

`lib/ideas/project_tracking.sh` (202 lines) already *is* the answer. It syncs idea status to GitHub Projects v2 as a best-effort, gracefully-degrading adapter that writes back `project_tracking_synced` events to `events.jsonl`. The architecture is already decided in code: **Pilot owns state, external trackers are mirrors.** The question is whether to add a Linear adapter to that seam — not whether to redesign the system around Linear.

---

## Position A: Integrate Linear aggressively

**What Pilot should stop building:** Nothing that currently exists should be deleted. But it should stop *extending* the web dashboard (`lib/web/server.js`) into a full project-management UI. If Linear owns human UX, that dashboard stays 331 lines instead of growing into a backlog manager.

**What Linear should own entirely:**
- Backlog display and prioritization
- Slack ↔ issue routing (Linear's native integration is already production-quality)
- Team assignment, mentions, sprint/cycle management
- Mobile notifications
- Human-facing project status

**What becomes a thin adapter:** `project_tracking.sh` extended to support a Linear backend. The abstraction already exists: `project_tracking_resolve_url` reads a configured URL and dispatches. Adding a second backend is additive.

**Complexity removed:** ~20–30%, primarily the "human project management UX" surface. Meaningful but not decisive.

**Does it make Pilot more differentiated?** Marginally. It forces Pilot to be a reasoning layer, not a project management tool. But surface area reduction is not the actual moat argument.

**What Position A gets wrong:** If Linear owns work state, the provenance graph becomes structurally incomplete. When you reconstruct "why did we build this" eight months from now, the decision trail starts with a Linear ticket, not with the full reasoning chain: which models argued which positions, what evidence was presented, which alternatives were rejected, who approved what against which exact content digest. That continuity is what `events.jsonl` provides. Losing it is not a configuration problem — it's a permanent structural gap.

---

## Position B: Keep Pilot self-contained

**Core argument:** Integrity of the provenance chain.

`events.jsonl` is append-only and grep-resolvable. Every provenance edge cites an exact `event_id`. Every decision, approval, finding, note, and outcome lives in one place. Introducing Linear as a bidirectional state-sync partner creates:

- **Duplicated state:** Which is canonical when `idea.json` says `implementing` and Linear says `Done`?
- **Sync failures becoming correctness failures:** Linear's API returns 429; Pilot's state is now wrong.
- **Provenance gaps:** Decisions made in Linear comments don't appear in `events.jsonl`, breaking the chain silently.

The existing GitHub Projects adapter is already best-effort and degradable *because mirroring is hard*. Making a second system authoritative is categorically different.

**What Pilot should own even if Linear already does it:** The lifecycle state machine. The approval gate is cryptographic — bound to idea content digest and PR head SHA. `approve-merge` records the exact PR URL, base branch, and head SHA; a pushed commit invalidates the approval until a human re-reviews. Linear cannot replicate this without becoming part of the security boundary, which is operationally dangerous.

**What we would regret outsourcing:** The approval record. Once the team treats Linear issue transitions as approvals, the two-gate safety model is gone in practice even if it still exists in code.

**What Position B gets wrong:** It overestimates the cost of a thin adapter and underestimates the real friction of CLI-only intake. Slack → `e3d-pilot ideas approve` manually is genuine friction. That friction will be solved one way or another — better to solve it in a controlled way than to let the team drift toward whatever tool is open on their screen.

---

## Position C: Pilot-core + adapters (my position)

The adapter pattern is already in the codebase three times: `lib/providers/common.sh`, `lib/publish/{github,local}`, and `lib/ideas/project_tracking.sh`. The right architecture extends it, not redesigns around it.

```
Intake: Slack / Linear / CLI / API
              ↓
        [adapter layer]
        linear_intake.sh     ← new, ~200 lines
              ↓
        events.jsonl         ← CANONICAL, APPEND-ONLY, SOURCE OF TRUTH
              ↓
        Pilot pipeline       ← discover/ideate/negotiate/execute/review/publish
              ↓
        provenance graph     ← derived, read-only, never authoritative
              ↓
        GitHub (PR/commit)
              ↓
        [project_tracking.sh extended]
        Linear status        ← mirror, best-effort, degradable
        GitHub Projects      ← mirror, best-effort, degradable
              ↓
        Slack notification
```

**The non-negotiable constraint:** Linear → `events.jsonl` is one-way intake. `events.jsonl` → Linear is one-way mirroring. There is no bidirectional state sync. Ever.

**Internal work model needed:** Already exists. `idea`, `actor`, `event`, `run`, `target_commit`, `outcome` already cover everything. No need to add `WorkItem`, `Decision`, `AgentExecution` as separate types — the event model captures all of these through event shapes.

---

## 10x incumbent stress test

Honest per-capability classification:

| Capability | Classification | Why |
|---|---|---|
| Multi-model adversarial deliberation + preserved dissent | **Strongly defensible** | No model vendor builds "compare our model against competitors." Structurally impossible. Linear won't build it. GitHub won't. |
| Decision provenance (why, not just what) | **Potentially durable** | GitHub has what changed. Linear has what the ticket said. Neither has: which models argued what, which alternatives were rejected, who approved against which exact content. |
| Outcome feedback loops | **Potentially durable, currently underbuilt** | Nobody closes the loop from "shipped PR" back to "did the reasoning about attraction/retention prove accurate?" |
| Discover/ideate pipeline | **Commodity within 12 months** | Linear AI, GitHub Copilot, Claude Code with project context will all do versions of this. |
| Approval gates | **Commodity within 2–3 years** | GitHub Actions + Linear automation will converge here. |
| Coding execution | **Commodity now** (already delegated to csr/grok-build) | |
| Training export | **Commodity now** | |
| Fleet mode | **Commodity now** | |

**Why multi-model debate gets stronger, not weaker, as models improve:** Better models produce more substantive independent reasoning. The delta between Claude's position and Codex's position on a genuinely contested architectural question becomes *more* valuable to capture, not less. The reliability hedge (we debate because no single model is reliable) is temporary. The deliberation value (we debate because a contested question deserves multiple independent perspectives) is permanent.

---

## Anti-moat test

**Is multi-model debate temporary scaffolding?** The reliability hedge is temporary. The deliberation protocol is not. These are different claims; Pilot should be explicit about which one it's building for.

**Does larger context eliminate provenance?** No. A 10M-token window doesn't help you reconstruct reasoning from 8 months ago across 300 decisions in a new session. Provenance is cross-session continuity; context is intra-session capacity. Different problems.

**Does Linear absorb decision history?** Linear's history is what happened to a ticket. `provenance trace` shows you which models argued which positions, what evidence supported them, what the preserved dissent was, and whether the outcome confirmed or refuted the reasoning. These are structurally different records.

**Does OpenRouter absorb multi-model debate?** OpenRouter routes. Structured adversarial deliberation with named dissent and convergence checking is a protocol above routing. OpenRouter has no incentive to take a stance on how to judge convergence quality or how to preserve dissent from its own customers' model calls.

**Does Pilot add latency without enough improvement?** Yes, for trivial tasks. The answer: don't use Pilot for "fix this typo." Use it for "should we redesign the auth flow." The wedge is narrower than the marketing sometimes implies, but it's real.

**Is the provenance graph useful for one person?** The README's honest answer: "one clear win, two explicitly 'no signal' because the real data was still too sparse." For a solo dev with 20 ideas: marginal. For 200 decisions over 18 months: substantial. Building it cheap (derived from `events.jsonl`, no separate DB) means the cost of maintaining it is low enough to justify building ahead of the scale where it clearly pays off.

**Permanent or transitional?** The reasoning/provenance problem is permanent. The reliability hedge is transitional. Be honest about the difference.

---

## OpenRouter parallel

| Subsystem | Classification |
|---|---|
| Model routing, cost optimization, model selection | buy/integrate (OpenRouter) |
| Model invocation | thin adapter (already is: `lib/providers/common.sh`) |
| Slack intake, issue tracking UX | buy/integrate (Linear + adapter) |
| Workflow state machine | **own** |
| Coding execution | buy/integrate (already: csr/grok-build) |
| Multi-model debate, negotiation, convergence | **own** |
| Provenance, shared context, decision memory | **own** |
| Outcome learning | **own** (currently underbuilt) |
| Governance, approval boundaries | **own** |
| Notifications, web dashboard UX | thin adapter |

The OpenRouter parallel is instructive in both directions: don't build model routing (correct to delegate), but also don't confuse "routing" with "deliberation" — these are different problems at different layers.

---

## Minimal Linear integration MVP

```
Event contract:
  Trigger: Linear webhook issue.create / issue.update 
           where assignee = e3d-pilot-bot

  linear_intake.sh:
  1. Verify HMAC signature (Linear provides this)
  2. Check events.jsonl for existing linear_ref (idempotency)
  3. ideas_append_event: idea_proposed with data.linear_ref = {issue_id, url}
  4. Best-effort: POST Linear comment "Pilot received: run <run-id>"

State machine:
  Linear issue state = mirror only
  events.jsonl lifecycle = canonical
  On any idea status change: project_tracking_sync_idea (extend to Linear backend)
  Linear updates: best-effort, same degradation pattern as GitHub Projects adapter

Loop prevention:
  Pilot → Linear calls include X-E3D-Source: e3d-pilot header
  Intake handler ignores webhooks with that header

Outage behavior:
  Linear down → ideas proceed via CLI; sync queued/skipped with stderr warning
  Pilot down → Linear issues accumulate; idempotency handles replays

Minimum permissions:
  Read: issue.read
  Write: issue.update (status field only), comment.create
  Never: delete, archive, member management, label management

Internal vs. mirrored data:
  events.jsonl: internal, canonical, never sent to Linear
  Linear: mirror — status + PR URL + one-line summary only
```

**Estimated scope:** ~200 lines in `lib/ideas/linear_intake.sh` + ~50-line extension to `project_tracking.sh` to support a second backend URL scheme.

---

## Final synthesis

**Recommended architecture: Position C**

**Confidence: 80%**

**Own:**
- `events.jsonl` as immutable canonical state
- Lifecycle state machine and approval gates (cryptographically bound)
- Multi-model debate and negotiation with preserved dissent
- Provenance graph (derived, never authoritative)
- Outcome tracking and feedback loops

**Explicitly don't own:**
- Human-facing project management UX → Linear
- Backlog prioritization, sprint planning → Linear
- Slack ↔ issue routing → Linear's native integration
- Mobile notifications → Linear
- Coding execution → csr/grok-build (already delegated)
- Model routing and cost optimization → OpenRouter eventually

**Keep replaceable:** Linear adapter (GitHub Issues, Shortcut, or Jira could substitute), publish backends, provider adapters, execution backends.

**Smallest MVP:** `lib/ideas/linear_intake.sh` + Linear backend in `project_tracking.sh`. ~250 lines total. No new schema, no new source of truth, no new lifecycle stages.

**What to measure while dogfooding:**
- Time from Linear issue creation → Pilot run start (target: <60s)
- How often does `provenance trace` get used for real questions (not just built)
- How often do model debates change the final outcome vs. first-model answer
- Frequency of Linear sync divergence from `events.jsonl`

**Success criteria:**
- Linear issue → Pilot run in <60 seconds via webhook
- Zero cases where Linear state contradicts `events.jsonl` and anyone is confused
- `provenance trace` used at least weekly to answer a real question

**Kill criteria:**
- Linear becomes required path (breaks direct `ideas approve` CLI workflow)
- Team starts treating Linear comments as decision records (provenance chain broken)
- Linear sync failures >5% rate cause active confusion about idea state

**The architectural decision we would most regret:** Making Linear the source of truth for idea state instead of `events.jsonl`. This is not recoverable. Once the team treats Linear issue transitions as the canonical record, the provenance graph becomes partial, and "why did we decide this" becomes unanswerable from the data alone. The adapter constraint — Linear is a mirror, never a source — must be enforced structurally and not just as policy.

---

## Plain answers

**1. If everything becomes 10x better, what is the irreducible reason e3d-pilot should still exist?**

Structured adversarial multi-model deliberation with preserved named dissent, linked to outcomes over time. No model vendor will build "here's what Claude argued, here's what Codex argued, here's their specific disagreement, and here's whether the decision proved right six months later." This is structurally impossible for a single-vendor platform. Linear won't build it — it's not a work-management problem. GitHub won't build it — it's not a code-management problem. OpenRouter won't build it — it's a deliberation protocol, not routing infrastructure. This capability gets stronger as models improve because better models produce more substantive independent reasoning — the delta between positions becomes more valuable to capture and preserve, not less.

**2. Does integrating Linear make Pilot more strategically focused, or does it risk turning Pilot into merely another agent behind someone else's platform?**

It makes Pilot more focused if and only if the integration is a thin, one-way-mirroring adapter. Build the adapter; don't integrate. These are different things. The risk is real and specific: if the team starts treating Linear as the decision record, or if Linear's webhook becomes required for Pilot to function, then Linear's product direction bounds Pilot's design space. The safe path is the one the codebase already demonstrates: `project_tracking.sh` is best-effort, degradable, and writes back to `events.jsonl` — not the other way around.

---

**Strongest dissenting view I'm not fully answering:** The adapter discipline problem. Position B's real argument is that small teams take shortcuts under pressure. Once Linear is the UX layer, decisions drift into Linear comments. The provenance chain breaks silently before anyone notices. Position C requires ongoing architectural vigilance that may exceed a small team's capacity. I believe controlled intake friction is worth solving; I don't have a strong answer to whether the discipline requirement is realistic in practice.

## Round 1 -- grok-build

I'll ground this in the actual e3d-pilot architecture and any existing Linear/work-management surface before taking a position.The repo already treats GitHub Projects as a best-effort mirror, not a source of truth. I'll inspect the idea ledger, provenance, and approval model next.**Decision: Position C — Pilot owns canonical work/reasoning state; Linear is an optional, replaceable adapter. Do not make Linear the work-management layer. Do not keep building a project-management product.**

This is not a compromise between A and B. It is the architecture this repo already chose for GitHub Projects and for publish backends. Linear-centric integration would *regress* that. Self-contained PM would *abandon* the product boundary the spec already wrote down.

Load-bearing facts from the current system, not slogans:

- Canonical objects already exist: `idea` + append-only `events.jsonl`, derived `idea.json`, runs, artifacts, digest-bound approvals, SHA-bound merge approval, outcomes. The graph is a regenerable index, not memory (`docs/provenance-graph-experiment.md`).
- Lifecycle states are governance states, not board columns: `proposed` → `approved_for_implementation` → `implementing` → `implemented` → `approved_for_merge` → `merged`, plus failure/partial/revert. Absence of approval is `proposed`, never yes. Editing the idea invalidates implementation approval. A new PR head invalidates merge approval. Spec: `docs/approval-gated-idea-lifecycle.md`.
- External tracking already exists as a **best-effort outbound mirror** (`lib/ideas/project_tracking.sh`): GitHub Projects v2, optional, never blocks the pipeline, linkage stored as `project_tracking_synced` events. Linear should be a second implementation of that seam, not a new source of truth.
- Execution is already not owned: csr / Claude / Codex / Grok-build. Publish is already an adapter (`github` | `local`).
- There is no Linear or Slack in the tree. Notify is optional email. The web UI is an approval/idea dashboard, not a board.

The proposed flow `Slack → Linear issue → delegate to Pilot → … → Linear status` inverts ownership. The correct flow is: **intake (Slack, Linear, CLI, API) → Pilot idea → reason/decide/execute → GitHub as implementation truth → optional Linear/Slack as human-visible projection.**

---

## Position A, argued at full strength

Linear will keep getting better at issues, cycles, assignees, Slack, agents, webhooks, MCP. Building that is a tax on a two-person dogfood loop. Every hour on boards is an hour not spent on debate, gates, and provenance.

If Linear owns “what / who / what state,” Pilot’s surface shrinks to: receive a work id, run a pipeline, write a result, update the issue. Humans stay in Slack+Linear. Agents get a native assignment target. You delete PM UI, stop pretending `ideas list` is a tracker, and dogfood faster.

**What A would delete:** board/status UX, assignee/priority/cycle fantasies, Slack-as-tracker, any “inbox” that is not the idea ledger or Linear. **What Linear would own:** issue identity for humans, assignment, scheduling, Slack notifications, coarse status. **Thin adapter:** webhook in, status/comment/PR link out. **Complexity removed:** a lot of UX, none of the hard state machine unless you also throw the ledger away. **Differentiation:** only if you actually stop at the adapter and keep the ledger. A usually does not stop there. It makes Linear canonical because that is where humans already click.

A is right about *commodity UX*. It is wrong about *authority*.

## Position B, argued at full strength

If Linear is the coordination layer, Pilot becomes an agent behind Linear’s roadmap, pricing, API, and identity. State duplicates. Sync is fragile. Linear will move up-stack into agents and “why we did this” comments. Then you have two overlapping brains and one of them is a vendor.

What you would regret outsourcing: digest-bound approval, SHA-bound merge, named dissent, local rebuild (`ideas rebuild`), model-vendor-neutral history, “Pilot still runs if Linear is down.” Those are not Jira features. They are the product.

B is right that **the idea ledger must stay canonical**. It is wrong if it means building Linear: boards, cycles, workload views, notification graphs. That is how you hollow yourselves out in the other direction — by becoming a worse Linear.

## Position C, evaluated independently (this is the call)

The right internal model is already here, with slightly cleaner names:

| Object | Already exists as | Role |
|---|---|---|
| WorkItem | `idea` | Durable unit of proposed work |
| Decision | `implementation_approval` / `merge_approval` / reject / changes_requested | Digest- or SHA-bound, actor + timestamp |
| Run | `.e3d-pilot/runs/<run-id>/` | One pipeline pass |
| AgentExecution | provider adapters + stage artifacts | Who ran, raw output |
| Artifact | findings, candidates, specs, diffs, PRs | Evidence |
| Evidence | notes, findings, review verdicts | Why |
| Outcome | `outcomes[]`, merge/revert/failure events | What happened |
| ExternalReference | `tracking.*`, PR URLs | Replaceable mirrors |

You need a **minimal internal work model**. You do not need a PM product. The existing idea state machine *is* that model. Do not invent a parallel `WorkItem` type. Do not make Linear issues the idea.

Adapters project a *lossy* status:

`proposed`→Backlog, `approved_for_implementation`/`implementation_failed`→Ready, `implementing`→In Progress, `implemented`/`approved_for_merge`/`merge_failed`→In Review, `merged`→Done, `rejected`/`closed`/`reverted`→canceled/archived.

Linear cannot be canonical because it cannot represent SHA invalidation, partial multi-repo merge, or “approval of digest D by actor A.” Custom fields that try to encode that will rot.

Pilot must run with **zero** external trackers. That is already true. Keep it true.

---

## 10x incumbent stress test

Assume Linear, GitHub, OpenRouter, Claude Code, Codex, Devin, Cursor, Slack AI, huge context, and model memory all become excellent. Coding agents go issue→PR reliably.

**Most of the pipeline becomes commodity.** Discover/draft/execute/review/publish as “an agent did the ticket” will be GitHub+Linear+Claude/Codex. Routing/cost/fallback will be OpenRouter. Slack will file structured work. If Pilot’s pitch is “orchestration” or “agent coordination,” it dies.

What does not automatically die, if you keep it strict:

**1. Independent multi-vendor deliberation with preserved, named dissent, bound to a decision that is not the model’s last paragraph.**

Not “call three models.” Sequential “Claude then Codex” is commodity. The scarce thing is: isolated first answers, critique, bounded convergence, **dissent that is not averaged away**, then a human decision that cites that record.

1. Linear: will assign agents and paste summaries. It sells a board, not a model-neutral dissent protocol, and it will not make Copilot/Claude/Codex first-class equals if that hurts its agent story.
2. GitHub: Copilot will plan and PR. It will not preserve competing vendors’ disagreements as first-class objects, and it benefits if Copilot is enough.
3. OpenRouter: structurally well placed for *ensemble calls*, poorly placed for git gates, digest-bound approval, and local ledgers. They may add “debate” as a feature; they will not own the work lifecycle.
4. Model vendors: multi-vendor independent debate is *against* lock-in. They will add self-critique and “team of agents” inside one stack.
5. Why adopt a third system: only for decisions where being wrong is expensive (architecture, security, merge, “should we even do this”). Not for ticket grinding.
6. Stronger as models improve **only while models remain diverse and wrong in different ways**. Weaker if one model dominates. Treat debate as **mandatory for gated decisions, optional for routine execution**.

**2. Digest- and SHA-bound human gates, with “silence is not approval,” locally enforced, forge-agnostic.**

GitHub branch protection is related and will eat a lot of this. What GitHub will not do well: bind approval to an *idea content digest* before any execute, invalidate on edit, keep that invariant when the forge is `local` or not GitHub, and refuse to treat a Linear status or a 👍 as consent. Linear has no reason to own merge-SHA binding. Model vendors want more autonomy, not more gates.

This gets **stronger** as agents get more autonomous. More autonomy makes unauthorized action cheaper. Gates are the product, not a brake on it.

**3. Portable, grep-resolvable decision memory: why we did it, who dissented, what failed, what the next session must not re-litigate.**

This is `ideas context` / `ideas handoff` / provenance trace, with every edge citing an `event_id`.

Huge context does not replace **commitments**. Context is working memory. The ledger is “this was decided, bound to this hash.” Model memory is per-vendor, opaque, non-portable, not rebuildable from `events.jsonl`. Linear activity feed is a comment stream. GitHub is code truth, not “alternatives we rejected.”

Value: a fresh Claude/Codex/Grok session picks up an idea without replaying Slack. That is already the MCP shape (`get_idea_context`, `get_idea_handoff`, `get_idea_provenance`).

Gets **stronger** as you accumulate real outcomes; **weaker** if you never query it (your own graph experiment already admitted sparse-data “no signal”).

**Honest disappearances:** generic multi-agent workflows; model routing/cost; coding execution; ordinary code review; Slack intake UX; issue tracking UX; “AI memory”; graph visualization until Experiment 2/3 actually win.

---

## Durable kernel (classified)

| Capability | Class | Why |
|---|---|---|
| Multi-model independent deliberation | potentially durable | Durable only as a *protocol* (isolation + named dissent + human bind). “Call N models” is commodity in 12 months. |
| Structured disagreement / explicit dissent | strongly defensible | Incumbents optimize for a single status. Named dissent is anti-UX for boards and model vendors. |
| Adversarial critique / negotiation | potentially durable | Pattern will be copied; Pilot’s version matters if it *stops* the pipeline on unresolved dissent. |
| Decision provenance + evidence links | strongly defensible | If it stays event-sourced, local, rebuildable, not an LLM summary. |
| Cross-model shared context (handoff packets) | potentially durable | Beats raw context/memory because it is curated and decision-bound. Weakens if you dump transcripts. |
| Persistent “why” memory | strongly defensible | Same as provenance. Not chat logs. |
| Outcome feedback / longitudinal learning | potentially durable | Only if failures/reverts structurally link to prior decisions. Embeddings of tickets are commodity. |
| Question → decision → execution continuity | potentially durable | The *gated* continuity is the product. Ungated agent loops are GitHub’s. |
| Model-independent cognition layer | strongly defensible | Structural: vendors will not be vendor-neutral. |
| Graph-based reasoning | experimental | Experiment 1 reconstructed facts; Experiment 2 is “does structure beat the ledger?” — do not bet the company. |
| Governance / approval / escalation | strongly defensible | Gets more valuable as agents 10x. |
| Decision quality measurement | experimental | Need labeled outcomes. Without that it is theater. |
| Human-visible work tracking, assignment, cycles | commodity now | Linear/GitHub. Stop. |
| Coding execution, PR mechanics | commodity now / 12 months | Already delegated; GitHub+agents will finish eating it. |
| Model routing, cost, fallback | commodity now | OpenRouter. Thin adapters only. |
| Slack intake | likely commodity 12 months | Adapter. |
| Basic multi-agent workflows | likely commodity 12–24 months | Say so and get out of that layer. |

---

## Anti-moat (no protection)

- **Is debate scaffolding until one model is enough?** For CRUD, yes. For contested architecture, no — *until* models collapse to one dominant failure mode. If that happens, Pilot’s debate path should shrink to gated decisions only. Kill criterion, not a slogan.
- **Does huge context kill the provenance graph?** No for commitments; yes if the graph is just a retrieval index over text you could stuff in a window. Keep the graph derived from events, not as a second memory.
- **Does model memory kill shared context?** No across vendors, years, and teammates. Yes for a single human + a single vendor chat.
- **Will Linear absorb decision history?** Comments and AI summaries, yes. Digest-bound, rebuildable, dissent-preserving ledger, no. Do not help them by storing the real history only in Linear descriptions.
- **Will GitHub absorb software reasoning?** Execution reasoning, yes. That is why execute is already not Pilot. Pre-execute “should we,” multi-model spec negotiation, and merge-SHA gates can survive if they stay thin.
- **Will OpenRouter absorb debate?** Ensemble, maybe. Human gates + git + local ledger, no. Do not rebuild a router.
- **Latency without quality?** Real risk. If debate rarely changes the selected idea or the spec, it is ceremony. Measure that.
- **Is the graph worth maintaining?** Only as a derived view. The ledger is mandatory; the graph is killable (you already framed it that way).
- **Solo dev + great coding agents?** They do not need Pilot for implementation. They might need `e3d-debate` + gates for a few decisions. Do not sell Pilot as a better Cursor.
- **Permanent vs transitional?** Multi-model *coordination* is transitional. **Accountable decisions independent of any one model or tracker** is permanent.

---

## OpenRouter test (buy vs own)

Same mistake as Linear-centric: building what a bigger platform is structurally better at.

| Subsystem | Call |
|---|---|
| Model routing / invocation / cost / selection-as-price | **buy/integrate** — OpenRouter + existing `lib/providers`. Pilot owns *policy* (N reviewers, fail if configured reviewer missing), not a marketplace. |
| Slack intake | **thin adapter** |
| Issue tracking / agent-visible assignment / human workflow chrome | **thin adapter** (Linear or GitHub Issues/Projects) |
| Workflow state (idea lifecycle) | **own** |
| Coding execution | **stop building** (already csr/providers) |
| Ordinary code review | **thin adapter** to GitHub + keep independent review stage as optional check |
| Multi-model debate, negotiation, provenance, handoff, decision memory | **own** |
| Outcome learning / graph reasoning | **experimental** |
| Governance / approval boundaries | **own** |

---

## Architecture comparison

**A. Linear-centric** (`Slack → Linear → Pilot → GitHub → Linear`)

Simple for humans, fast UX, agent-friendly in Linear’s world. Engineering looks small until sync, identity, retries, and “which status is real” show up. Vendor risk is high. Differentiation collapses: Pilot is a Linear agent. Provenance integrity depends on Linear remaining a complete mirror — it will not. Outage: work is stuck or Pilot is unreachable from the only inbox people use. Strategic value: negative. **Reject.**

**B. Pilot-centric, no adapters** (`Slack → Pilot → GitHub`)

Simplest *system*, worst *human* UX if anyone wants a board. Low vendor risk, high temptation to grow a tracker. Provenance integrity is best. Agent-friendly via CLI/MCP, not via Linear. Fine for a tiny team *right now*. Strategic value: good kernel, bad if you then build cycles/assignees.

**C. Pilot-core + adapters** (recommended)

Intake: Slack / Linear / GitHub Issues / CLI / API → map to `idea` (proposed). Core: ledger, debate, gates, execute, review, publish. Outbound: GitHub PR is implementation truth; Linear/Slack/Projects are projections.

- Simplicity: worse than B, much better than dual-write A.
- Effort: one seam (`ExternalReference` + lossy status map). You already paid for it once.
- Operational risk: outbound-only is low (existing pattern: warn, don’t die). Bidirectional is the trap — avoid except for *create idea from new issue*.
- Vendor risk: low if Pilot runs without the adapter.
- UX: humans who want Linear get it; agents and gates stay on the ledger.
- Differentiation: preserved.
- Portability: Linear today, Issues tomorrow, none always.
- Observability: events.jsonl remains the audit.
- Failure recovery: Linear down → CLI/web still approve and merge. Pilot down → Linear still shows last mirrored status, no false approvals.
- Long-term: this is the only option that still exists if Linear becomes hostile *or* if you never used Linear.

---

## Dogfood

You are a small team. Optimize for not running two work systems.

- If you are **not** already living in Linear every day: **do not build the adapter yet.** Use CLI + existing web approval UI + GitHub. Optionality is free until you write the webhook.
- If Chris already tracks work in Linear: add the **outbound** adapter only, copy `project_tracking.sh`.

**If Chris can get the same outcome with Linear + Claude Code + Codex + GitHub + OpenRouter + a few scripts, why Pilot?**

Only these concrete invariants, which those tools will not jointly enforce:

1. Isolated first answers from more than one vendor, then critique, with **named dissent left in the record**.
2. **No execute** without `ideas approve` of an exact content digest; **no merge** without `approve-merge` of the exact head SHA; new push or idea edit invalidates the gate.
3. Dedup against branches, PRs, and **prior Pilot runs** before proposing work.
4. A handoff packet (`ideas context` / `ideas handoff`) any model can read, rebuilt from `events.jsonl`, not from Slack or a vendor’s memory.
5. A training/outcome export path that does not treat “unreviewed” as “rejected.”

If you do not actually use (1)–(5), Pilot should not exist. Scripts plus Linear will win on latency.

---

## Minimal Linear MVP (only if humans already use Linear)

Do **not** start from Slack→Linear→Pilot as the OS.

Outbound-only, GitHub-Projects-shaped:

1. On idea terminal-ish transitions, upsert Linear issue (or attach if `external_id` exists).
2. Set status via the lossy map above.
3. Comment a structured block: idea id, decision, dissent summary, run id, PR URL.
4. On publish, attach PR. On merge/revert, update status.
5. Optional later: Linear “create” webhook → `idea_proposed` **only if** no `e3d-idea-id` in the issue. Never Linear-status-change → Pilot approval.

**Event contract (outbound):** `idea_id`, `event`, `status`, `title`, `pr_url?`, `linear_issue_id?`.  
**Source of truth:** `events.jsonl`. Linear is a mirror.  
**Idempotency:** key = `idea_id` (and Linear id once linked). Store `tracking.linear_issue_id` via `project_tracking_synced`-style event.  
**Retry:** best-effort; never fail the pipeline.  
**Identity:** humans have Linear ids; Pilot has `idea-*`; mapping lives on the idea, not as Linear-only custom fields.  
**Loop prevention:** ignore Linear webhooks for issues that already have `e3d-idea-id` except for *new comments that are intake notes* (`ideas note`). Never take status from Linear.  
**Outage:** skip sync, warn.  
**Permissions:** Linear API key with issue read/write in one team; no admin; no secret in the ledger.  
**Security:** do not write credentials, diffs of secrets, or raw env into Linear comments.

That is the whole MVP. No cycles, no assignee sync, no bidirectional state machine.

## Minimal internal alternative (if you skip Linear)

You already have it. Freeze PM scope:

Keep: idea ledger, two gates, runs, debate, provenance export, handoff, optional web **approval** UI, GitHub publish.

Stop: boards, assignees, estimates, inboxes, Slack work OS, richer dashboard as a tracker.

Do not recreate Jira. The 14 statuses you have are for **authorization**, not project management.

---

## Debate notes (round 1)

1. **Independent position:** C with a hard ban on Linear-as-SoT. A is a strategic inversion. B is correct on ownership, wrong on product surface.
2. **Strongest argument against me:** If the team’s real bottleneck is “we lose work in CLI/web and Linear is where attention is,” a purist ledger that nobody looks at is a dead SoT. Humans create de facto sources of truth by where they click. C can fail in practice the same way A fails in architecture.
3. **Assumptions that would make me wrong:**
   - You already cannot operate without Linear as the assignment bus, and you will not look at `ideas`/`web`.
   - Debate/gates do not change outcomes vs one good agent (then Pilot is latency).
   - Linear ships digest-bound multi-vendor dissent and local export that you trust (then A becomes rational).
   - You need to sell “works inside Linear” to anyone but yourselves this year (then a Linear-shaped agent is a distribution hack — still don’t give them the ledger).
4. **Critique of other models:** not possible this round; I have not seen their answers. Steelman: A undercounts irreversible authority loss; B undercounts the cost of a second Linear.
5. **Unresolved:** whether to write any Linear code *now* vs keep GitHub Projects as the only mirror until pain is measured. I vote **not now** unless Linear is already daily.
6. **Update after critique:** N/A this round. Dissent I will not concede: Linear must not authorize execute or merge.

---

## Final synthesis

- **Recommended architecture:** Pilot-core + replaceable adapters. Linear may *mirror* and optionally *intake*. It may not own work state.
- **Confidence:** high on rejecting A; high on keeping the idea ledger; medium-high on delaying Linear code.
- **Strongest dissent:** ship Linear-centric anyway for human UX and treat Pilot as an execution backend — faster dogfood, likely fatal positioning.
- **Pilot should own:** idea lifecycle, digest/SHA gates, debate/negotiate, ledger, handoff, provenance derivation, provider *policy*, pause/denylist/diff ceilings.
- **Pilot should not own:** boards, assignees, cycles, Slack product, model marketplace, coding execution, forge-native review as the merge authority.
- **Linear should own (if used):** human-visible issues, assignment, reminders, Slack chrome for *attention*, not authorization.
- **Replaceable:** Linear, GitHub Projects, GitHub Issues, Slack, OpenRouter, any single model provider, even GitHub publish (`local` already exists).
- **Commodity:** tracking UX, routing/cost, autonomous coding, basic agent workflows.
- **Differentiated:** vendor-neutral dissent + bound human decisions + portable why-memory + gates that tighten as agents get stronger.
- **Smallest MVP:** no Linear until daily use; if daily, outbound mirror + PR comment only.
- **Measure while dogfooding:** (a) % of gated decisions where dissent changed the spec or stopped the run; (b) times a later session used `handoff`/`provenance` instead of re-asking Slack; (c) execute/merge blocked by digest/SHA vs would have shipped anyway; (d) minutes of sync/debug vs Linear; (e) whether anyone looks at Linear status vs `ideas show`.
- **Success:** debate or gates change real outcomes; handoff is used; Pilot runs with Linear down; no second state machine.
- **Kill:** 10 consecutive gated runs where a single agent would have produced the same merge; provenance never queried; Linear status becomes what people trust for “is it approved?”; Chris’s script combo is faster with equal decision quality.
- **The decision we would regret most if wrong:** making Linear canonical work state (A). You will not get the ledger back once humans live there. Shipping C late is cheap. Shipping A first is not.

**1. If Linear, GitHub, OpenRouter, Claude Code, and Codex all become 10x better, why does e3d-pilot still exist?**  
Because none of them will be a **model-vendor-neutral, locally rebuildable record of independent disagreement bound to human approvals that are invalid when the idea or the SHA changes.** That is not issue tracking, routing, or coding. If you cannot point at a decision and answer “who dissented, what evidence, what digest was approved, what head was allowed to merge, what failed later” without asking Linear or a model vendor, Pilot has no remainder.

**2. Does integrating Linear make Pilot more focused, or turn it into another agent behind someone else’s platform?**  
**Linear-as-layer (A) turns Pilot into an agent behind Linear. Linear-as-adapter (C) can sharpen focus — if and only if you stop building tracker UX and you never take approval from Linear.** The risk is not the webhook. The risk is letting Linear’s status column become the word “done.”

## Round 2 -- claude

# Round 2

All four positions converged on Position C, and none of us disagree on the core invariant: Linear (or any tracker) must never become the source of truth for approval, execution authority, or provenance. That convergence is itself informative — it's not four people picking the safe middle, it's four independent readings of the same constraint (a digest-bound/SHA-bound approval and an append-only decision record cannot survive living inside a mutable, vendor-controlled issue). I'm updating one part of my own position based on what devin and grok-build found, and I want to sharpen a real disagreement that's still live between codex on one side and devin/grok-build on the other.

## What I'm conceding

My round-1 answer proposed building `WorkItem`, `Decision`, `Run`, `AgentExecution`, `Artifact`, `Evidence`, `Outcome`, `ExternalReference` as new internal types, "extending" the existing ledger to fit that taxonomy. Devin and grok-build actually looked at the repo (`lib/ideas/project_tracking.sh`, `events.jsonl`, the idea state machine, digest/SHA-bound approvals) and showed that taxonomy already exists under different names — `idea`, `event`, `run`, `implementation_approval`/`merge_approval`, artifacts, outcomes. I proposed a schema in the abstract; they found the schema already shipped. That's a materially better answer, and my round-1 framing — "build a minimal internal work model" — was solving a problem that doesn't exist. The actual task is narrower: add a second backend to the adapter seam that already exists (`project_tracking.sh`), not invent a parallel object model. I'm dropping the "build WorkItem et al." recommendation. This is exactly the premature-abstraction risk I flagged as my own weakest point in round 1 — turns out it was more than a hypothetical risk, it was already wrong given what's in the tree.

## The live disagreement: build the adapter now, or wait for signal

Codex's synthesis treats Linear as "the first-class daily coordination interface" and specifies a fairly complete state-mapping and MVP to build now. Devin and grok-build both land on: don't write Linear intake code yet unless Linear is *already* the team's daily surface — extend `project_tracking.sh` with a Linear backend only when there's evidence of daily use, and even then keep it outbound-only (mirror status/PR link out; do not accept Linear as an inbound trigger for anything beyond idea creation).

I side with devin/grok-build here, for a reason specific to this team, not architecture in the abstract: there is no Linear in this repo, no Slack in this repo, and nothing in memory or project state indicates Chris is currently running work through Linear day to day. Building the intake webhook, identity mapping, and state machine described in codex's and my own round-1 MVP is real engineering effort spent against a hypothetical workflow. The cheap, reversible move is: do nothing to intake, add a Linear branch to the existing outbound mirror (same shape as the GitHub Projects adapter, ~50 lines per devin's estimate) only when Chris is actually opening Linear multiple times a day and finding the CLI/web approval UI insufficient. That's a falsifiable trigger, not a subjective call, and it avoids building coordination-layer UX ahead of demonstrated need — which is the actual anti-pattern Position B was warning about, just arriving from the "adapter creep" angle instead of the "rebuild Jira" angle.

This matters concretely: a person following codex's answer writes the Linear webhook and state-mapping now. A person following mine (revised) or devin's or grok-build's does not — they wait for a usage signal. That's a genuine behavioral fork, not a nuance difference.

## Where I still disagree with grok-build/devin on scope, slightly

Both grok-build and devin frame the entire internal-model question as "already solved, nothing to design." I'd push back gently: the *objects* already exist, but the *mapping* from idea-lifecycle states to a tracker's coarser status vocabulary is a real design decision that isn't fully specified anywhere in the current codebase (it exists today only for GitHub Projects, and only for one external system). When a second adapter gets added, someone has to decide, for example, whether `implementation_failed` and `merge_failed` both collapse to "Ready" or split into "Ready" and "Blocked." That's a small but real piece of design work, not zero-cost reuse. I'd rather flag this explicitly than let "we already have the model" imply the second adapter is free.

## Critique of codex specifically

Codex's field-ownership table (Linear-authoritative: assignee/priority/team/project/cycle/status; Pilot-authoritative: everything reasoning-related) is the right framing and matches mine. But codex's "Linear as first-class daily coordination interface" language, combined with a fuller state machine and richer MVP, creates more surface for exactly the drift devin warns about in his own closing dissent: "once Linear is the UX layer, decisions drift into Linear comments." Codex's own architecture comparison table rates Linear-centric UX as "excellent" and treats that as close to decisive for near-term adoption — I think that overweights UX polish against a team of one-to-few people who can use a CLI without friction. The dogfooding value of removing PM-surface work is real, but it's not urgent enough to justify building the coordination surface before there's evidence anyone needs it.

## Critique of devin and grok-build

These are the strongest two answers this round because they're grounded in what's actually in the tree rather than in a fresh abstraction. Grok-build's answer is exceptionally disciplined — the "not now unless Linear is already daily" gate, the explicit kill criteria ("10 consecutive gated runs where a single agent would have produced the same merge"), and the refusal to let debate scaffolding hide behind "orchestration" language are all correct and sharper than my round-1 answer. I don't have a substantive objection to either beyond the scope point above. If anything, grok-build's framing of the "debate is mandatory for gated decisions, optional for routine execution" rule is a better operationalization than anything I said in round 1, and I'll adopt it rather than restate my own weaker version.

## Restated position, updated

Position C, unchanged at the top level: Pilot owns the idea/event ledger, digest-bound implementation approval, SHA-bound merge approval, multi-model debate/dissent, and provenance — none of that moves to Linear under any circumstance. What changes from round 1:

1. No new internal object model. Extend `project_tracking.sh`'s existing adapter pattern with a Linear backend; do not build `WorkItem`/`Decision`/etc. as new types.
2. Don't build Linear intake (webhook, identity mapping, inbound state machine) now. There's no evidence of daily Linear use in this team today. Build the outbound-only mirror (status + PR link + structured comment, same shape as GitHub Projects sync) only when that evidence appears, gated on an explicit trigger (Chris routinely opening Linear and finding the CLI/web UI insufficient), not speculatively.
3. If/when the Linear adapter is built, keep it strictly outbound except for one narrow inbound case devin/grok-build both specify correctly: a new Linear issue with no `e3d-idea-id` may create a `proposed` idea. A Linear status change must never itself constitute or imply approval.

## Anti-moat / stress test

I don't have new ground to add beyond what's converged across all four answers: multi-vendor dissent preservation, digest/SHA-bound gating, and locally-rebuildable why-memory are the three candidates that survive the 10x-incumbent test, and all three get *stronger* as coding agents get more autonomous (more autonomy raises the cost of ambiguous authorization, which is exactly what the gates exist to prevent). The honest losses are the same across all four answers: issue tracking, routing, mechanical code review, basic multi-agent fan-out — all commodity, already correctly routed to Linear/GitHub/OpenRouter in every position this round.

## Final answers

**What Pilot owns:** idea/event ledger, digest- and SHA-bound approval gates, multi-model debate with preserved dissent, provenance derivation, handoff/context export.
**What Pilot explicitly does not own:** boards, cycles, assignees, Slack UX, model routing, mechanical code execution/review.
**What Linear may own, later, outbound-only, if adopted:** human-visible status, PR links, structured summaries — never approval, never provenance.
**Smallest next step:** none on Linear specifically right now. If anything, extend `project_tracking.sh` with a Linear backend using the existing GitHub Projects shape, gated on demonstrated daily Linear use — not built speculatively.
**Kill criterion I'll add:** if a Linear adapter is ever built and, six weeks later, nobody has opened `ideas show`/`provenance trace` because Linear's status field answered the question well enough — that's fine, it means the mirror is working. If instead someone starts treating a Linear "Done" as equivalent to "merged" or "approved," that's the regret scenario every position this round flagged, and it means the adapter needs a harder wall (e.g., the bot-authored comment stating the real gate state) rather than removal.

POSITION: Pilot keeps the idea/event ledger, digest-bound implementation approval, and SHA-bound merge approval as the sole source of truth for reasoning and authorization, reusing existing objects rather than inventing new ones; Linear should be added only as an outbound-only, non-authoritative status mirror on the existing `project_tracking.sh` adapter pattern, and only once there's real evidence of daily Linear use — no intake webhook or bidirectional sync should be built speculatively.
status: revise

## Round 2 -- codex

My prior position holds: choose Pilot core + adapters, with Linear as the daily coordination surface but outside Pilot’s authorization and provenance trust boundary.

I have revised one detail: “Linear is merely a mirror” is too restrictive. Linear should be authoritative for human coordination fields; Pilot should be authoritative for decision-bearing fields. The integration is intentionally bidirectional, but no individual field has two authorities.

Claude provided no answer, so there is nothing substantive to evaluate.

## Where the answers agree

Codex, Devin, and Grok-build converge on the important architectural boundary:

- Keep an internal, durable identity for work.
- Keep reasoning, dissent, approvals, executions, and outcomes internal.
- Use Linear for commodity work-management UX.
- Do not build boards, cycles, roadmaps, inboxes, or generic team administration.
- Keep Linear optional and replaceable.
- Never let a Linear status authorize execution or merge.
- Treat GitHub as implementation truth.
- Buy routing and coding execution rather than rebuilding them.

That agreement is substantial, but not complete enough for `approved`: the proposed MVPs would produce materially different integrations.

## Critique of Devin

Devin correctly identifies the existing append-only ledger and project-tracking adapter as architectural evidence. It is also right that the decision-bearing identity must not be outsourced.

Three claims are too strong.

First, “there is no bidirectional state sync, ever” is an attractive slogan but the wrong invariant. If Linear owns assignment, priority, cancellation intent, and human queue state, Pilot must ingest changes to those fields. Simultaneously, Linear needs Pilot progress and artifacts. That is bidirectional integration.

The safe rule is:

> Bidirectional transport is acceptable; bidirectional authority over the same semantic field is not.

Second, Devin treats multi-model deliberation as strongly defensible because vendors will not foreground competitors. Vendor neutrality is a useful structural advantage, but the protocol itself is easy to copy. OpenRouter or an agent framework can implement isolated fan-out, critique, judging, and dissent storage. The potentially defensible asset is accumulated evidence about which dissent predicted which outcomes—not the debate workflow.

Third, its loop-prevention proposal is technically unreliable. An outbound HTTP header sent to Linear will not ordinarily be reproduced in a later webhook. Loop prevention needs durable identifiers:

- provider event ID
- outbound Pilot event ID stored in the resulting comment or metadata
- integration actor identity
- observed external version
- expected-write reconciliation

Devin’s estimated 250-line implementation is probably optimistic once signature verification, durable inbox/outbox processing, identity mapping, retries, reconciliation, and tests are included. That does not weaken the architecture, but it matters for dogfood planning.

## Critique of Grok-build

Grok-build is strongest on governance semantics: Linear cannot faithfully represent digest invalidation, PR-head invalidation, partial execution, or the difference between delivery state and authorization.

It also correctly argues that huge context does not replace commitments. Remembering text and proving exactly what was approved are different capabilities.

I disagree with three conclusions.

First, it recommends no Linear implementation unless Linear is already used daily, and then prefers outbound-only mirroring. The question’s proposed operating model places Linear between Slack and delegation. Outbound-only integration does not test that model and does not reduce intake friction. The smallest useful experiment requires one inbound action: explicit delegation of an issue to Pilot.

Second, its claim that explicit dissent and persistent “why” memory are strongly defensible confuses product value with moat. Linear, GitHub, and model vendors can all store increasingly capable decision histories. Pilot only has a durable advantage if its record is:

- cross-vendor
- evidence-addressable
- bound to immutable authority
- linked to later outcomes
- reused to improve subsequent decisions

An append-only ledger is good architecture, not by itself a moat.

Third, an absolute “Linear may not own work state” is unnecessarily broad. Linear can own human work state—priority, assignment, project, cycle, and attention—without owning Pilot’s reasoning and authorization lifecycle. Forcing Pilot to remain canonical for every assignee or priority change recreates unnecessary synchronization and PM semantics.

## Critique of my previous answer

My previous answer was directionally right but insufficiently sharp about the two kinds of state.

“Linear owns the human-visible queue” and “Pilot owns canonical WorkItem identity” can coexist, but only with explicit field ownership. Otherwise the team will eventually argue about whether a Linear edit changed the approved scope.

The corrected model is:

- Linear’s issue is the mutable human request.
- Pilot captures immutable revisions of that request.
- A Pilot run operates against one captured revision and digest.
- Later Linear edits may create a new revision or coordination event; they never mutate an approved revision.
- Linear “Done” records human coordination intent, not proof of successful execution.
- GitHub merge state records the implementation fact.
- Pilot records the relationship among request, decision, authority, implementation, and outcome.

I also downgrade basic multi-model debate from “likely commodity within two to three years” to “likely commodity within twelve months.” The specialized semantics around dissent and outcome calibration remain potentially durable.

## Revised architectural decision

Choose C, but do not implement a generic adapter framework before the first adapter proves the abstraction.

Pilot’s minimal internal model should be semantic, not a miniature tracker:

- `WorkItem`: stable internal identity and immutable revisions
- `Run`: a reasoning or execution attempt
- `Decision`: alternatives, verdict, dissent, confidence, and approved digest
- `Evidence`: addressable support or contradiction
- `Artifact`: specification, patch, PR, report, or commit
- `AgentExecution`: provider invocation and result
- `Outcome`: observed consequences
- `ExternalReference`: provider IDs, versions, URLs, and sync cursor

These may remain event shapes over the existing ledger rather than becoming eight new storage tables.

Linear should own:

- Human backlog and triage
- Priority and assignment
- Teams, projects, and cycles
- Slack-to-issue UX
- Notifications and progress discussion
- Coarse delivery state

Pilot should own:

- Captured request revisions and digests
- Deliberation and preserved dissent
- Decisions and approval authority
- Policy and escalation
- Detailed run/execution state
- Evidence and artifacts
- Provenance and outcome linkage
- Recovery independent of Linear

GitHub should own repository content, commits, PR heads, checks, and merge facts.

## Smallest worthwhile MVP

Implement exactly one inbound delegation path and one outbound reporting path.

Inbound event:

```text
Linear issue explicitly delegated to Pilot
```

Delegation should use an integration action, dedicated assignee, or dedicated label—not every issue update.

Processing:

1. Verify the webhook signature and workspace.
2. Persist the raw event in a durable inbox.
3. Deduplicate using the Linear event ID.
4. Map or create an internal `WorkItem`.
5. Capture an immutable issue revision and digest.
6. Start the selected Pilot pipeline.
7. Record the Linear issue as an `ExternalReference`.

Outbound events:

```text
run_started
human_decision_required
run_failed
pr_created
run_completed
```

Write structured comments and only coarse status changes through an outbox. Use `(provider, object ID, external version)` plus Pilot event IDs for idempotency.

Identity rules:

- A Linear user maps to a Pilot actor.
- An unmapped user may submit or delegate work.
- Only explicitly authorized Pilot actors may approve execution or merge.
- Neither a comment nor a status transition constitutes approval.

Outage behavior:

- Linear unavailable: already-authorized work continues; outbound changes queue.
- Pilot unavailable: Linear retains its last known status; webhook delivery can replay.
- GitHub unavailable: execution may prepare artifacts but cannot claim PR or merge completion.

Do not initially build bulk reconciliation, OAuth marketplace installation, arbitrary status mapping, multi-workspace support, or a generalized Jira/Shortcut SDK.

## The durable kernel under the 10x test

The durable claim should be narrower than any participant presented:

> Pilot is a user-owned decision-control plane that binds a versioned question to independent evidence and dissent, explicit authority, execution truth, and measured outcomes across otherwise replaceable platforms.

Linear may build decision summaries, but it is unlikely to enforce cross-system immutable authority. GitHub may absorb software reasoning, but it does not own pre-code product decisions or non-code outcomes. OpenRouter may absorb routing and debate, but it lacks organizational authority and outcome truth. Model vendors may provide excellent memory, but their memory is vendor-local and not a neutral record of competitors’ dissent.

This is worth an additional system only for consequential, repeated, or governed decisions. Routine issue-to-PR work should bypass heavyweight deliberation.

The kernel strengthens as agents become more autonomous because ambiguous authority becomes more dangerous and decision volume rises. It weakens if Pilot merely stores transcripts, if dissent rarely changes action, or if outcomes are never captured.

## Genuine unresolved disagreements

Two uncertainties remain:

- Whether Linear should be integrated immediately or only after observing concrete intake pain.
- Whether outcome-calibrated history will become valuable often enough for a very small team.

My recommendation is to build the minimal delegation MVP now only if Linear will become the team’s actual daily queue. Otherwise, run the same experiment through the existing CLI/API before paying the integration cost.

The strongest dissent is Grok-build’s: even a carefully bounded adapter can cause humans to treat Linear as the real decision record. That is a behavioral risk architecture cannot fully prevent.

The most regrettable error remains making Linear’s mutable issue or status the authority for what was approved. The opposite error—delaying an adapter—is cheap and reversible.

Plainly:

1. If every incumbent becomes 10x better, Pilot should exist only to provide platform-independent, outcome-calibrated decision integrity: exactly what was considered, who dissented, what was authorized, what executed, and whether it worked. If that history does not improve or safeguard later decisions, Pilot has no irreducible reason to exist.

2. Linear integration makes Pilot more focused when Linear owns attention and commodity work UX while Pilot owns decision integrity. It turns Pilot into another Linear agent if Linear becomes the identity, authorization, or durable provenance authority.

POSITION: Adopt Pilot core plus replaceable adapters, using Linear for human coordination while Pilot retains immutable work revisions, reasoning, authorization, provenance, and outcomes.
status: revise

## Round 2 -- devin

## Round 2

### What held up from round 1

The codebase-grounded argument remains correct. `lib/ideas/project_tracking.sh` already demonstrates the pattern: Pilot owns state, external trackers are best-effort outbound mirrors. The debate is not about architecture—all three round-1 answers independently converged on C. The debate is whether the tactical execution is right.

### Where I agree with the others

**Grok-build** is the most aligned. "Do not build the Linear adapter until Linear is in daily use" is pragmatically correct. The kill criteria are well-specified. The observation that humans create de facto sources of truth by where they click is the real failure mode, and it is not solvable by architecture policy alone—it requires making `events.jsonl` query experience competitive with wherever humans actually look.

**Codex** correctly specifies field ownership (what Linear-authoritative vs Pilot-authoritative means in practice) and correctly identifies the coarse status mapping. The field-ownership framing is worth adopting directly.

### Where the others are wrong

**Codex's schema proposal over-engineers the internal model.** Introducing `WorkItem`, `Decision`, `Run`, `AgentExecution` as first-class types alongside the existing `idea` + event schema creates a parallel hierarchy without changing behavior. A `Decision` is not a new object—it is an `implementation_approved` or `merge_approved` event on an `idea`. An `AgentExecution` is already a run subdirectory with provider metadata. The right move is to clarify *event shapes*, not add new top-level types. The taxonomy is intellectually coherent but risks a refactoring that introduces naming confusion while changing nothing structurally. The existing model already captures everything codex proposes.

**Codex's "preferred coordination UX" language is too soft.** Calling Linear "preferred" implies it is the right default. The correct framing: Linear is an *optional* adapter for teams already using it daily. If the team is not in Linear today, the adapter adds zero value and maintenance burden. "Preferred" is product positioning that could justify building the adapter before it earns its keep.

**Both missed the outcome data gap as the actual validation gate.** All three round-1 analyses argued that multi-model deliberation and digest/SHA gates are "strongly defensible" or "potentially durable." But the codebase's own `docs/provenance-graph-experiment.md` records two "no signal" results because the outcome data was too sparse. The durable kernel claim is aspirational until this is answered concretely: does deliberation change decisions, and do those changed decisions produce measurably better outcomes? Without this, the moat argument is a narrative. The smallest next action is not the Linear adapter—it is instrumenting deliberation outcomes so that claim can be validated.

### The question all three avoided

**Is multi-model deliberation permanent or transitional?**

All three said the reliability hedge is temporary (one sufficiently good model ends it). All three claimed deliberation value is permanent. But deliberation value depends on models being wrong in *different* ways—that independent disagreements are informative, not noise or convergent failure.

As models converge on similar training distributions and RLHF objectives, independent deliberation may decrease in value even as reliability increases. If Claude, Codex, and Grok all read the same corpus and have similar fine-tuning, their disagreements become less diagnostic. The diversity hypothesis is plausible now but is not structurally guaranteed.

This narrows the moat claim. The durable case is not "multi-model deliberation" as a generic feature—it is specifically deliberation where models have genuinely different information, incentives, or training priors. That means vendor diversity (Anthropic vs. OpenAI vs. xAI) is the mechanism, not model count. If vendor consolidation happens, this pillar weakens.

### Updated position

Position C holds with these refinements:

**On internal schema:** Do not add new top-level types. Clarify event shapes for existing objects. `ExternalReference` as event metadata (already implicit in `project_tracking_synced`) is sufficient. The graph is regenerated from the ledger; adding a `WorkItem` type does not change what the graph contains or the query power it offers.

**On Linear timing:** Do not build until Linear is in daily use *and* until deliberation outcomes are instrumented. The adapter is value-neutral until you know Pilot is producing better decisions. Building it now is a bet on a hypothesis that has not been validated.

**On the upward-stack risk:** Linear's AI features will accumulate decision context in issue descriptions and comments. This creates a competing provenance store that is more convenient to read than `events.jsonl`. Architecture cannot fix this alone. The answer is making `ideas context`, `ideas handoff`, and `provenance trace` fast and useful enough that the canonical source is also the most convenient one. If `events.jsonl` is harder to query than a Linear comment thread, people will use the Linear comment thread and the provenance chain breaks silently.

**On the durable kernel:** Prioritize outcome capture over adapter breadth. Every merged idea should produce an outcome event within 30 days. The provenance graph becomes defensible exactly when outcome data is dense enough to demonstrate that prior dissent predicted problems. Until then, it is infrastructure for a thesis.

**On the anti-moat test:** The honest answer to "if Chris can do this with Linear + Claude Code + scripts, why Pilot?" is now sharper. Because those scripts do not enforce that approval is bound to the exact content digest, do not preserve named dissent against specific alternatives with no-execute enforcement, and do not link outcomes back to the reasoning chain. If those three properties have never changed an important decision in practice, Pilot should not exist for a solo dogfood use case. They need to be demonstrated before the architecture is expanded.

### Plain answers

**1. If everything becomes 10x better, why does e3d-pilot still exist?**

To maintain a user-owned, model-vendor-neutral, locally rebuildable chain from a specific version of a question, through independent deliberation with named dissent that is not averaged away, to a human decision bound to an exact content digest, through execution bound to an exact commit SHA, to a measured outcome—and to use that accumulated chain to improve later decisions. No single-vendor platform builds this because preserving competitor disagreements as durable first-class objects is structurally against their incentives. No work tracker builds this because digest invalidation and SHA binding require a different authorization model than status columns. This gets stronger as agents gain autonomy and as outcome data accumulates. It disappears if vendor diversity collapses or if outcome capture never gets built.

**2. Does integrating Linear make Pilot more focused, or turn it into another agent?**

The outbound adapter makes Pilot more focused only if Pilot's CLI and web paths remain fully operational without Linear, and only if Linear status transitions never substitute for digest or SHA gates. Build the adapter when it is needed. Never build it first.

---

POSITION: Pilot-core with Linear as an optional outbound mirror that never holds authorization—but the Linear adapter is premature until outcome instrumentation demonstrates that deliberation actually changes decisions, because without that evidence the durable kernel is a narrative rather than a demonstrated moat.
status: approved

## Round 2 -- grok-build

I'll read the full debate prompt and prior-round answers first, then form an independent round-2 position.The prompt is long; I'll keep reading prior-round positions so the round-2 critique is grounded.I'll check whether the repo still matches round 1 (no Linear, GitHub Projects as a mirror) so the round-2 critique stays concrete.# Round 2 — Grok

I am not changing the architecture. I am not adopting Codex’s or Devin’s implementation sequence.

**Position C, restated:** Pilot owns the decision-bearing object (`idea` + append-only `events.jsonl`). Linear, if used at all, is a replaceable projection and an optional intake source. It is not the work-management layer. The repo still has **zero Linear code**. `lib/ideas/project_tracking.sh` is still a best-effort GitHub Projects mirror that must not block the pipeline. That is the existing decision. Linear-centric would regress it.

What a person following me does this week:

1. Freeze project-management surface (no boards, assignees, cycles, Slack work OS).
2. Do **not** add Linear webhooks, Linear status mapping, or Linear identity-to-approver mapping.
3. Keep GitHub Projects as the only tracker adapter until Linear is already daily dogfood.
4. If Linear later becomes daily: outbound mirror first (copy `project_tracking.sh`), then maybe create-from-issue. Never Linear status → execute/merge.

Codex and Devin would start writing Linear this week. That is an action split, not framing.

---

## What I update after seeing them

**Keep:** reject A; reject self-contained Jira; ledger is canonical; Linear must not authorize; stop building tracker UX; OpenRouter/coding/review/routing are buy/thin-adapter.

**Update 1 — field ownership, not “no inbound events.”**  
Devin’s “one-way forever” is slightly too absolute. Codex’s field split is the better rule:

- Linear may authoritatively hold fields Pilot does not use for gates: assignee, priority, cycle, human attention.
- Pilot authoritatively holds digest, approvals, dissent, run state, evidence, outcomes.
- GitHub authoritatively holds SHA/PR/merge.
- Slack never authorizes.

Inbound *events* (new issue → `idea_proposed`; comment → `ideas note`) are fine. Inbound *authority* is not. That is the real boundary.

**Update 2 — the de facto SoT risk is real.**  
If humans already live in Linear, delaying all integration lets decisions rot in Linear comments. I still do not treat that as a reason to build Linear **before** that is true. The tree has no Linear. Building the webhook now *creates* the dual inbox we are trying to avoid.

**I will not update to:** Linear as “first-class daily coordination interface”; webhook MVP now; new `WorkItem` types; Linear-user identity as an approval principal.

---

## Critique of Codex

Codex’s architecture paragraph is C. Codex’s product paragraph is A wearing C’s clothes.

“Linear as the first-class daily coordination interface” + “Linear owns the human-visible queue” is how mutable issue status becomes the word “done.” Codex later forbids Linear from authorizing execute/merge. Those two instructions will not survive contact with a small team. People trust the surface they click. If that surface is Linear, Linear becomes the ledger in practice. Codex names this failure mode and then designs an MVP that maximizes it: webhook in, status out, identity mapping, coarse Linear state machine.

Specific errors:

**1. The MVP is not thin.**  
Delegation webhook, material-update handling, cancel, identity mapping, outbox, HMAC, loop markers, status mapping, Slack notify — that is a second workflow runtime. Devin’s ~250-line guess is the same undercount. The existing Projects adapter is already ~200 lines *outbound-only, one forge, no authz*. Linear intake is a new security boundary.

**2. Coarse Linear statuses are still a second state machine.**  
Codex says not to drive a dozen Linear statuses, then maps Triage/Started/In Review/Done onto Pilot. “Done” “must not manufacture a merge” is a comment, not a mechanism. The mechanism is: **do not write Pilot lifecycle into Linear columns at all**, or write a one-way lossy projection and never read it back. Codex’s inbound “Issue materially updated / canceled” will re-import Linear’s column.

**3. Linear user → Pilot actor for privileged approval is a trap.**  
Unmapped users “may delegate but cannot grant privileged approval” implies mapped users *can*. That pulls Linear identity into the trust boundary. Approvals stay `ideas approve` / `approve-merge` against digest/SHA, from Pilot actors. Linear OAuth is not that.

**4. `WorkItem` taxonomy is a rename.**  
`idea`, events, runs, artifacts, outcomes, `tracking.*` already exist. Adding WorkItem/Decision/AgentExecution as first-class types is PM-product gravity. Do not do it.

**5. “Integrate Linear aggressively at the UX boundary” is the sentence that will be remembered.**  
The trust-boundary caveat will not. For this team, the actionable instruction must be: **do not make Linear the UX boundary until Linear is already the UX boundary.**

Where Codex is right, and I will steal it: Linear-authoritative *coordination fields* vs Pilot-authoritative *decision fields*. Also: debate should be risk-triggered, not mandatory. Also: outcome-calibrated history is not a moat until populated.

---

## Critique of Devin

Devin is closest to the code. The load-bearing observation is correct: `project_tracking.sh` already decided “Pilot owns state, trackers are mirrors.” Adding Linear is “another backend on that seam,” not a redesign.

Where Devin goes wrong:

**1. Build it now.**  
The seam existing is not a reason to occupy it. There is no Linear in the tree. Dogfood is Pilot + GitHub. Writing `linear_intake.sh` this week is speculative commodity work — the exact tax we said we would stop paying.

**2. Trigger = `assignee = e3d-pilot-bot`.**  
That is Linear-native agent assignment. It makes Linear the dispatcher. Codex’s “explicit delegation action” is slightly better; both are premature. If intake ever exists, key off an explicit label/action and a missing `e3d-idea-id`, not assignee.

**3. “Zero contradictions, zero confusion.”**  
If Linear is independently editable, contradictions will exist. Success is: contradictions cannot authorize, and humans know the ledger wins. Devin’s kill criterion “Linear becomes required path” is the right one; the zero-divergence success metric fights the architecture.

**4. “No bidirectional sync ever” vs comments-as-notes.**  
Too sharp. Allow inbound *facts*. Forbid inbound *gates*. Devin’s HMAC + `X-E3D-Source` loop prevention is the right shape *when* you build it.

**5. Overclaiming the debate moat.**  
“Strongly defensible because no vendor will compare models” is half-true. OpenRouter, agent frameworks, and eval harnesses will fan out models. What they will not own: **named dissent bound to a digest, left unresolved, gating execute, replayable locally.** The fan-out is commodity; the bind is not. Treat debate as mandatory only on gated decisions.

**6. “Nothing existing should be deleted.”**  
Stop extending the web dashboard toward a backlog. Freeze it as an approval/idea inspector. That is a delete-from-roadmap even if you keep the 331 lines.

Devin’s strongest unanswered point is the discipline problem: C requires vigilance a small team may not have. I agree that is the real risk of C. The answer is not “ship Linear intake so the temptation is structured.” The answer is **fewer surfaces**. One ledger, GitHub for code, no Linear until the cost of not having it is measured in minutes per day.

---

## Strongest argument against my own position

A ledger nobody looks at is not a source of truth. If Chris already triages in Linear, my “wait” instruction produces shadow state in Linear comments, then a panicked bidirectional sync later — the worst of A and C.

That argument **wins if and only if Linear is already daily**. It does not win as a reason to introduce Linear so that the argument becomes true.

Also: if debate/gates do not change merges, Pilot is latency. Scripts + Claude Code + Codex + GitHub win. I will not protect the current pipeline from that kill.

---

## Assumptions that would make me wrong

- Linear is already the team’s daily assignment bus (then outbound this week, not “someday”).
- You must sell “works in Linear” to anyone but yourselves this year (distribution hack; still don’t give them the ledger).
- Linear ships digest-bound multi-vendor dissent and a local export you trust (then A becomes rational).
- Ten gated runs in a row match a single agent’s merge (then shrink Pilot to gates-only or kill it).

---

## Genuine unresolved disagreements (preserve these)

| Issue | Codex | Devin | Me |
|---|---|---|---|
| Write Linear this week? | Yes, webhook MVP | Yes, ~250 lines | **No**, unless Linear is already daily |
| Linear’s product role | First-class human queue | Human PM UX | Optional projection |
| MVP direction | Inbound + outbound | Inbound assignee trigger + outbound | Outbound-only first |
| New work types | WorkItem et al. | Use `idea`/events | Use `idea`/events |
| Debate | Experimental/specialized | Strongly defensible | Durable only as gated protocol |

We agree on the kernel: not A, not Jira, ledger canonical, Linear must not approve.

We do **not** agree on what to type next.

---

## Compact architecture call

**A. Linear-centric** — reject. Fast UX, fatal trust boundary. Pilot becomes a Linear agent.

**B. Self-contained PM** — reject the product, keep the ledger. Boards/cycles/assignees are a moat for Linear, not for Pilot.

**C. Core + adapters** — accept, with a sequencing constraint the others omit: **adapter code is paid for by demonstrated Linear use, not by architectural completeness.**

Internal model: keep `idea` as the WorkItem. Do not add a parallel type. Provenance graph stays derived. GitHub remains implementation truth. Pilot must run with Linear down — already true; keep it true.

---

## 10x / durable kernel (only what still matters)

Incumbents will eat: intake UX, routing/cost, coding, ordinary review, generic memory, generic multi-agent loops, issue→PR narration, Slack structured work.

**Irreducible remainder, if any:**

1. **Vendor-neutral independent first answers + named dissent that is not averaged away, bound to a human decision.**  
   Linear will summarize agents. GitHub will Copilot the PR. OpenRouter will ensemble. Model vendors will not preserve competitors as equals. Value only on consequential, contested, resumed decisions. Stronger while models stay diverse and differently wrong; weaker if one model dominates — that is a kill switch, not a slogan.

2. **Digest-bound execute gate and SHA-bound merge gate, silence ≠ yes, forge-agnostic, locally enforced.**  
   GitHub branch protection will eat a lot of (2) for GitHub-hosted repos. What it will not do: bind approval to idea digest *before* execute, invalidate on edit, work with `publish=local`, refuse Linear 👍 as consent. This gets **stronger** as agents get more autonomous.

3. **Rebuildable why-memory (`ideas handoff` / provenance citing `event_id`) that a fresh agent can consume without Slack or a vendor memory blob.**  
   Huge context is working memory. Model memory is opaque and vendor-local. Linear activity is comments. This is valuable iff later sessions actually use it. Your graph experiment already showed sparse-data “no signal.” Keep the graph killable.

If (1)–(3) are unused, Chris’s Linear + Claude Code + Codex + GitHub + OpenRouter + scripts combo is the product. Say so.

---

## Buy vs own (unchanged in substance)

| Own | Thin adapter | Buy | Stop / experimental |
|---|---|---|---|
| Idea lifecycle, digest/SHA gates, dissent record, handoff, decision memory, provider *policy* (N reviewers, fail if missing) | Slack intake, Linear/Issues/Projects, coding agents, forge review, model invocation | Routing, cost, fallback (OpenRouter), Slack/Linear UX, GitHub PR mechanics | Boards/cycles/assignees; marketplace; graph-as-memory; outcome learning until labeled |

Same OpenRouter mistake to avoid: do not rebuild routing. Same Linear mistake: do not rebuild boards. Opposite mistake: do not outsource the object that approvals attach to.

---

## Dogfood sequence (the actual decision)

Small team. Low cost. Optionality is free until the webhook exists.

**Smallest MVP worth building: nothing Linear.**

**If Linear is already daily, smallest MVP:**

- Outbound only, same degradation as Projects.
- Lossy status map already in `project_tracking_status_for_idea`.
- Comment: idea id, digest/approval, dissent one-liner, run id, PR URL.
- Idempotency: `idea_id` → `tracking.linear_issue_id` via `project_tracking_synced`-style event.
- Never fail the pipeline on Linear errors.
- Permissions: issue read/write in one team; no admin; no secrets in comments.
- Loop prevention: do not consume Linear status. Optional later inbound: `issue.create` without `e3d-idea-id` → `idea_proposed` only.

Do not build: assignee sync, cycle sync, Linear-user approval, Slack→Linear as OS, custom fields for digest/SHA.

**Measure:** % gated runs where dissent changed spec or stopped execute; handoff used instead of re-asking Slack; execute/merge blocked by digest/SHA that would have shipped; minutes spent on tracker sync; whether anyone treats Linear “Done” as approved.

**Success:** gates or dissent change real outcomes; Pilot runs with Linear down; no second authorization state machine; admin time down without provenance going unread.

**Kill:** 10 consecutive gated merges a single agent would have shipped unchanged; provenance never queried; Linear status trusted for approval; script combo faster at equal decision quality; sync repair >5% of issues.

**Regret most if wrong:** making Linear canonical (A). Shipping the adapter late is cheap. Reconstructing a ledger after humans lived in Linear is not.

---

**1. If Linear, GitHub, OpenRouter, Claude Code, and Codex all become 10x better, why does e3d-pilot still exist?**  
Only as a **model-vendor-neutral, locally rebuildable record of independent disagreement bound to human approvals that die when the idea digest or the PR SHA changes**, plus a handoff the next agent can use without asking Linear or a model vendor. If you cannot point at an idea and answer who dissented, what evidence, what digest was approved, what head could merge, and what failed later, Pilot has no remainder.

**2. Does integrating Linear focus Pilot, or turn it into an agent behind someone else’s platform?**  
**A focuses the demo and hollows the product.** C focuses Pilot only if Linear stays optional, outbound-first, and never an approver — and if you **stop building tracker UX**. Building Codex/Devin’s webhook now is how C becomes A without a decision record saying A.

POSITION: Keep Pilot’s idea ledger as the only work/authorization source of truth; do not make Linear the work-management layer, and do not build Linear integration until Linear is already daily dogfood, then outbound-only.
status: revise

## Round 3 -- claude

# Round 3

Three rounds in, the architecture question is settled: all four of us land on Position C — Pilot owns the idea/event ledger, digest-bound implementation approval, SHA-bound merge approval, dissent, and provenance; Linear (if used at all) never authorizes anything. Nobody argues for A anymore, nobody argues for rebuilding Jira. What's left is a genuine, unresolved fork about what to build *this week*, and I want to sharpen it rather than paper over it with agreement-on-principles.

## What I'm keeping from round 2

No new internal object types. Codex still frames `WorkItem`/`Decision`/`AgentExecution` as "event shapes over the existing ledger rather than eight new storage tables" — that's now compatible with what devin and grok-build said (the taxonomy already exists as `idea` + `events.jsonl`), so this is converged, not disputed. Good.

Codex's field-ownership correction — "bidirectional transport is acceptable; bidirectional authority over the same semantic field is not" — is a real improvement over my round-2 "outbound-only, forever" framing, and I'm adopting it. Linear can be the write-owner of assignee/priority/cycle without that threatening anything. My objection was never to bidirectional *data flow*; it was to bidirectional *authority* over approval and merge state. Codex's phrasing says that more precisely than I did, and grok-build converges on the same rule ("Linear-authoritative coordination fields vs Pilot-authoritative decision fields"). This is now a four-way agreement, not a disagreement — I should stop treating "outbound-only" as load-bearing and instead say "no external system may hold write-authority over a decision-bearing field," which is compatible with an inbound label-triggered delegation event.

## The one thing I'm updating: devin's outcome-instrumentation point is a better gate than mine

My round-2 trigger was "build it when Chris is actually opening Linear daily and finding the CLI insufficient." Devin's round-2 answer adds a second, sharper condition: even if that usage signal appears, the adapter is still a bet on an unvalidated hypothesis — that deliberation and dissent actually change decisions — and the repo's own `docs/provenance-graph-experiment.md` already recorded "no signal" from sparse outcome data. That's a fact about this codebase, not a general architectural preference, and it changes the priority ordering: instrumenting whether dissent changes merged outcomes is cheaper than building Linear intake, and it's the thing that determines whether Pilot is worth extending in *any* direction, Linear included. I'm folding this in as a co-gate rather than treating usage-frequency alone as sufficient justification to write adapter code. This is a genuine update to my position, not a restatement.

## Where I still disagree with codex, and why the disagreement is real, not semantic

Codex's round-2 MVP is inbound delegation via webhook now, with the argument that "outbound-only integration does not test that [Slack→Linear→Pilot] model and does not reduce intake friction." That's a fair point about what outbound-only *can't* validate. But it doesn't follow that the answer is to build production webhook infrastructure. You can test whether "delegate a Linear issue to Pilot" is a workflow anyone actually wants without HMAC signature verification, a durable inbox/outbox, identity mapping, and a coarse status state machine — codex's own critique of devin's "~250 line" estimate ("probably optimistic once signature verification, durable inbox/outbox, identity mapping, retries, reconciliation, and tests are included") is itself the strongest argument against building it speculatively. If codex believes the honest cost is well above 250 lines including a new security boundary, that is an argument for testing the *hypothesis* — does this handoff shape reduce friction? — with something far cheaper than the real integration: manually create the issue, manually run `ideas` against it, manually post the result back. That validates or kills the workflow assumption in an afternoon instead of a sprint, and it doesn't create a webhook endpoint, a signature-verification surface, or an identity-mapping table that has to be maintained regardless of whether the hypothesis holds.

So the fork is concrete: a person following codex opens a PR this week adding a Linear webhook receiver, signature verification, and an inbound delegation handler. A person following me does not write any Linear code this week — they test the delegation workflow by hand, and only write the adapter once (a) that manual test shows real friction reduction, and (b) outcome instrumentation shows deliberation is earning its keep at all. Those are different actions taken this week. That's not a framing difference; it's the same fork I flagged in round 2, and codex's round-2 answer didn't close it — if anything, codex's own cost admission (signature verification, durable inbox/outbox, retries, reconciliation) makes the case for not building it *now* stronger than it was in round 1.

## Critique of grok-build

Grok-build's round-2 answer is the strongest of the four on discipline grounds and I don't have a substantive objection to it. Two small notes. First, grok-build's line "the seam existing is not a reason to occupy it" is the correct rebuttal to devin's round-1 framing, and I want to make sure it doesn't get lost — the existence of `project_tracking.sh`'s adapter pattern tells you the *shape* a Linear backend would take, it says nothing about whether now is the time to write it. Second, grok-build's critique that codex's "unmapped users may delegate but cannot grant privileged approval" implicitly makes mapped Linear users approval principals is a real catch — codex's MVP identity rule as written does create exactly the ambiguity grok-build describes, and codex hasn't corrected it in round 2. I'd flag that as a concrete bug in codex's proposal, not just a stylistic quibble: if it shipped as written, someone would eventually treat a mapped Linear user's issue edit as equivalent to a Pilot actor's `ideas approve`.

## Critique of devin

Devin's round-2 answer is, by their own "status: approved" framing, claiming convergence — but devin's own position ("do not build until Linear is in daily use *and* until deliberation outcomes are instrumented") is not what codex would have a reader do this week. I think devin marked this "approved" prematurely; the substance of devin's answer is closer to mine and grok-build's "wait" position than to codex's "build now," and that's a live fork regardless of how devin labeled it. Otherwise devin's round-2 contribution — separating "is deliberation permanent" from "is reliability-hedging permanent," and tying the moat specifically to vendor-diversity rather than model-count — is the sharpest new idea this round and I have nothing to add against it.

## Restated position

Position C. Unchanged core: Pilot's idea/event ledger, digest-bound implementation approval, SHA-bound merge approval, dissent, and provenance are the sole authority for what was decided and what may execute — no external system, Linear included, ever gets write-authority over those fields. Linear (or any tracker) may hold write-authority over coordination fields it's better at — assignee, priority, cycle — the moment it's adopted, per codex's corrected bidirectional-authority rule.

What changes from round 2: I'm adding outcome-instrumentation as a co-gate alongside usage-frequency, per devin, and I'm being explicit that "testing whether the Slack→Linear→Pilot handoff is worth building" does not require building the production webhook — it requires a manual dry run first. Nothing here is speculative infrastructure; it's sequencing.

## Anti-moat / 10x test — no new ground

Converged across all four rounds: multi-model debate as generic fan-out is commodity within 12 months (I'm adopting codex's tightened timeline over my earlier "2-3 years"); what's potentially durable is the specific bind — named dissent, unaveraged, attached to a digest, gating execute, replayable without any vendor — and that only stays durable if vendor diversity holds and if outcome data ever gets dense enough to prove dissent changes results. Nobody this round found a reason to weaken that conclusion, and devin's point that it's currently unproven (not just theoretically fragile) is the sharpest version of it.

## Plain answers

**1.** If everything gets 10x better, Pilot's irreducible reason to exist is a locally-owned, cross-vendor record binding a specific version of a question to independent, unaveraged dissent, to a human decision bound to an exact digest, to execution bound to an exact commit SHA, to a measured outcome — used to inform later decisions. No incumbent has an incentive to preserve competitors' disagreement as a first-class object, and no work tracker's status column can express digest/SHA invalidation. This is currently a thesis, not a demonstrated result, per the repo's own sparse-outcome-data finding.

**2.** Linear integration keeps Pilot focused only if it's added strictly as a field-scoped adapter after both usage and outcome evidence exist. Building an inbound webhook now, before either exists, spends the scarce "avoid rebuilding commodity infrastructure" budget on infrastructure nobody has shown is needed yet — and creates exactly the surface (a second place decisions can appear to live) that every position this round agrees is the actual risk.

POSITION: Pilot's ledger stays the sole authority over decision-bearing fields (approval digest, merge SHA, dissent, provenance), with Linear addable later as a field-scoped adapter (never authoritative over those fields) — but only after both real daily Linear usage and instrumented evidence that deliberation changes outcomes, not built speculatively as codex's inbound-webhook MVP proposes now.
status: revise

## Round 3 -- codex

## Round 3 position

My position holds: choose Pilot core + adapters. Linear should become the human coordination surface only if the team actually adopts it as the daily queue. Pilot must remain independently operable and authoritative for decisions, approvals, provenance, executions, and outcomes.

I disagree with both “integrate Linear aggressively” and “outbound-only forever.” The correct invariant is:

> Systems may exchange events in both directions, but each semantic field has exactly one authority.

That supports useful Linear intake without letting a mutable issue redefine an approved request.

Claude again provides no position to evaluate.

## Evaluation of the other answers

Devin is right about three important things:

- The existing ledger and project-tracking code already favor a canonical Pilot core with external projections.
- Outcome data is the real validation test for the provenance thesis.
- New database entities should not be introduced merely to satisfy an elegant taxonomy.

But Devin incorrectly makes outcome validation a prerequisite for Linear integration. These answer different questions:

- Outcome instrumentation tests whether Pilot’s reasoning improves decisions.
- Linear integration tests whether external coordination reduces administrative friction.

Both should be measured, but one need not block the other. If Linear is the actual daily queue, delaying intake guarantees manual duplication and encourages reasoning to accumulate in Linear comments.

Devin’s outbound-only preference also fails to test the proposed workflow. If delegation still requires switching to Pilot’s CLI, the integration has not addressed Slack/Linear intake. One narrowly defined inbound event is warranted: explicit delegation to Pilot.

Grok-build offers the strongest dissent. It correctly emphasizes that the surface people click becomes the de facto source of truth. It is also right that speculative integration is wasteful when Linear is not actually used.

I disagree with four prescriptions:

1. Outbound-only integration is insufficient once Linear is the queue. It leaves manual intake and identity correlation unsolved.
2. Never projecting Pilot lifecycle into Linear status makes Linear less useful. A lossy, one-way status projection is safe if it cannot authorize Pilot.
3. “Optional projection” understates Linear’s legitimate authority. Linear can authoritatively own priority, assignee, project, cycle, and human cancellation intent.
4. Waiting until the coordination problem becomes painful encourages ad hoc scripts and comment-based shadow provenance. The adapter should be introduced alongside actual Linear adoption—not months before it and not after synchronization has become chaotic.

Grok is right that no Linear code should be built merely for architectural completeness. My recommendation is conditional on making Linear the real daily queue.

## Strongest case for each architecture

### A. Linear-centric

This is the fastest product to dogfood. Linear eliminates most of the commodity surface:

- Backlog, triage, assignment, priorities, projects, cycles
- Slack issue creation and notifications
- Search, filters, dashboards, and collaboration UI
- Agent-facing work queues
- Mobile and administrative UX

Pilot could stop building perhaps 70–90% of a conventional project-management product and focus on reasoning.

The fatal problem is authority. If the Linear issue is the only work object, Pilot’s approvals become attached to mutable external content, outage recovery depends on Linear history, and Linear’s identity and permissions enter Pilot’s execution boundary. Pilot then becomes an advanced Linear agent.

Reject A.

### B. Pilot-centric

This gives maximum control and could unify the work graph and provenance graph. It avoids synchronization and vendor dependency.

But it forces a small team to recreate commodity attention management: queues, assignment, notifications, views, Slack intake, search, status UX, and eventually permissions. Owning those features does not create a meaningful moat. It delays validation of the actual Pilot thesis.

Reject B as a project-management product. Retain its principle that Pilot owns decision-bearing state.

### C. Pilot core + adapters

This has some integration complexity, but it preserves the correct strategic boundary:

- Linear owns human coordination.
- GitHub owns implementation facts.
- Pilot owns decision integrity.
- Providers execute replaceable capabilities.

Accept C, without prematurely creating a generalized adapter SDK.

## Canonical semantics

Pilot needs a minimal internal work model, not Jira.

The conceptual types remain useful:

- `WorkItem`: stable identity plus immutable request revisions
- `Run`: one reasoning or execution attempt
- `Decision`: alternatives, verdict, dissent, confidence, approved digest
- `Evidence`: addressable support or contradiction
- `Artifact`: specification, patch, report, PR, or commit
- `AgentExecution`: provider invocation and result
- `Outcome`: observed consequence
- `ExternalReference`: external object ID, version, URL, and synchronization cursor

Devin and Grok are correct that these do not necessarily justify new tables or top-level objects. They can initially be event semantics over the existing `idea`, run directories, and append-only ledger.

The distinction matters more than the storage schema.

## Explicit authority split

Linear should own entirely:

- Human backlog and triage
- Assignee, priority, team, project, and cycle
- Discussion and attention state
- Slack-to-issue convenience
- Coarse delivery status
- Human cancellation or pause requests

Pilot should own:

- Stable internal identity
- Captured immutable request revisions
- Evidence, deliberation, critique, and dissent
- Approval bound to exact content digests
- Governance and escalation rules
- Detailed run and execution state
- Provider-independent provenance
- Outcome linkage and longitudinal learning

GitHub should own:

- Repository contents
- Commits and PR heads
- Checks and review records
- Merge facts

Linear cancellation is an input to Pilot policy. It is not permission to interrupt an irreversible operation. Linear “Done” is never proof of execution or merge.

## The 10x incumbent test

Most of Pilot’s current apparent surface will become commodity:

| Capability | Classification |
|---|---|
| Model invocation, fallback, routing, cost optimization | Commodity now |
| Slack intake and structured issue creation | Commodity now |
| Issue tracking, assignment, workflow state | Commodity now |
| Coding execution and routine review | Likely commodity within 12 months |
| Basic multi-agent fan-out and debate | Likely commodity within 12 months |
| Shared context and generic persistent memory | Likely commodity within 2–3 years |
| Debate summaries and decision-history UI | Likely commodity within 2–3 years |
| Explicit dissent attached to immutable decisions | Potentially durable |
| Digest/SHA-bound authorization with invalidation | Potentially durable |
| Cross-vendor, evidence-addressable provenance | Potentially durable |
| Outcome-linked decision calibration | Potentially durable |
| Governance across replaceable trackers, forges, and agents | Potentially durable |
| Accumulated evidence of which reasoning predicts outcomes | Strongly defensible if populated |

“Multi-model debate” is not itself a moat. The defensible possibility is a growing record of which evidence, dissent, model behavior, and approval choices predicted later outcomes.

### The irreducible kernel

The narrow durable claim is:

> Pilot is a user-controlled decision-integrity layer that binds a versioned request to evidence and preserved dissent, explicit authority, implementation truth, and measured outcomes across replaceable platforms.

Why would incumbents not absorb it?

1. Linear may store decisions, but its natural object is mutable coordinated work—not immutable cross-system authority.
2. GitHub may absorb software reasoning, but it does not own pre-code questions, rejected alternatives, non-code execution, or organizational outcomes.
3. OpenRouter may provide routing and multi-model debate, but it does not possess human authority, implementation truth, or downstream outcome data.
4. Model vendors will provide excellent memory, but it will be vendor-local and unlikely to preserve competitors’ dissent as equal first-class evidence.
5. An additional system is justified only when a decision is consequential enough that exact authorization, auditability, or reuse of prior outcomes matters.
6. This grows stronger as agents become more autonomous because execution volume and authority risk increase. It grows weaker if Pilot merely stores transcripts or if outcomes are never recorded.

## Anti-moat verdict

The thesis can fail.

- A sufficiently capable single model may make routine debate pure latency.
- Larger context will reduce context-assembly value.
- Model-native memory will commoditize ordinary shared memory.
- Linear will absorb substantial decision-history UX.
- GitHub will absorb most software-specific issue-to-PR reasoning.
- OpenRouter or agent frameworks will absorb generic ensembles and judging.
- A solo developer may rarely need formal provenance.
- An unqueried provenance graph is storage cost, not a product.
- If dissent does not change actions or predict outcomes, structured deliberation is transitional scaffolding.

Pilot should therefore use risk-triggered deliberation. Routine issue-to-PR tasks should bypass the heavyweight pipeline.

## OpenRouter lesson

The same architectural rule applies to both Linear and OpenRouter: buy infrastructure where the provider has scale advantages; own semantics where outsourcing would surrender authority.

| Subsystem | Decision |
|---|---|
| Model invocation, routing, fallback, cost optimization | Buy/integrate |
| Model selection policy | Thin adapter; experiment internally |
| Slack intake | Thin adapter |
| Issue tracking and PM UX | Buy/integrate |
| Agent assignment and coarse workflow | Linear-owned, thin adapter |
| Detailed reasoning lifecycle | Own |
| Coding execution and routine review | Thin adapter |
| Multi-model fan-out | Commodity mechanism |
| Structured dissent and convergence semantics | Own experimentally |
| Provenance and immutable request revisions | Own |
| Generic shared context | Buy where useful |
| Decision memory and outcome learning | Own |
| Graph reasoning | Experimental |
| Governance and approval boundaries | Own |

## Smallest worthwhile Linear MVP

Build this only when Linear is adopted as the daily human queue:

```text
Explicit Linear delegation
→ capture immutable request revision
→ start Pilot run
→ report structured checkpoints
→ attach PR/commit
→ project coarse status
→ notify Slack
```

Event contract:

- One inbound trigger: explicit `delegate_to_pilot`
- Optional inbound coordination events: priority, assignee, pause, cancellation request
- Outbound: `run_started`, `decision_required`, `run_failed`, `pr_created`, `run_completed`

Reliability:

- Verify webhook signature and workspace.
- Persist the raw webhook before processing.
- Deduplicate by Linear event ID.
- Use a durable inbox/outbox.
- Attach a Pilot event ID to every outbound comment.
- Track observed Linear object versions.
- Reconcile expected writes rather than relying on an HTTP header being echoed.
- Retry with backoff; send persistent failures to a visible dead-letter queue.

Identity:

- Linear users may submit, assign, prioritize, pause, or request cancellation.
- Pilot approvals remain Pilot identities bound to a digest or SHA.
- No Linear reaction, comment, assignee, or status grants execution or merge authority.

Outages:

- Linear unavailable: authorized work continues; reports queue.
- Pilot unavailable: Linear retains last known status; webhook replay is safe.
- GitHub unavailable: Pilot may prepare artifacts but cannot claim PR or merge completion.

Permissions:

- Read/write issues and comments only for one configured Linear team.
- No workspace administration.
- No repository or execution credentials exposed to Linear.
- No sensitive deliberation copied into Linear by default.

Do not initially build OAuth distribution, multi-workspace support, arbitrary status mapping, bulk reconciliation, or a generalized tracker framework.

## What to measure

During dogfooding, record:

- Intake-to-start time
- Manual tracker work per issue
- Synchronization failures and repair time
- Percentage of runs where dissent changes scope or action
- Approvals invalidated by content or SHA changes
- Provenance queries and handoff reuse
- Outcome capture rate
- Whether prior evidence improves later decisions
- Routine-task latency relative to a single coding agent
- Whether users treat Linear state as authorization

Success criteria:

- Administrative time decreases materially.
- Pilot remains usable during a Linear outage.
- No semantic field has competing authorities.
- At least some consequential decisions are improved or prevented by dissent/gates.
- Outcome history is reused rather than merely stored.
- Adapter maintenance remains a small fraction of Pilot development.

Kill criteria:

- Synchronization repair consumes more than 5% of handled work.
- Linear becomes necessary for Pilot execution.
- Humans routinely treat Linear “Done” as approval.
- Ten or more representative gated runs match a single-agent result without meaningful improvement.
- Provenance is almost never queried or reused.
- Outcome capture remains too sparse to calibrate decisions.
- Linear plus coding agents and a few scripts achieve equal decision quality with substantially less friction.

## Updated conclusion

The most regrettable error is not shipping the Linear adapter too late. It is making a mutable Linear issue the identity or authorization object and later discovering that Pilot has no independent decision record.

The strongest dissent remains Grok’s position: introducing Linear intake will behaviorally turn Linear into the real ledger despite architectural safeguards. That risk is genuine. It is why the adapter should follow actual daily Linear adoption and why approvals must remain visibly and mechanically outside Linear.

Plain answers:

1. If all incumbents become 10x better, Pilot should exist only for platform-independent decision integrity and outcome calibration: what exact question was considered, what evidence and dissent existed, what was authorized, what actually executed, and whether it worked. If this history neither improves nor safeguards later decisions, Pilot should not exist.

2. Linear integration makes Pilot more strategically focused when it removes commodity coordination work while Pilot retains identity, authorization, provenance, and outcomes. It turns Pilot into another Linear agent the moment Linear becomes the canonical decision object, an approval authority, or a required runtime dependency.

POSITION: Adopt Pilot core plus replaceable adapters, and add narrowly bidirectional Linear integration only when Linear becomes the daily coordination queue while Pilot retains immutable request revisions, authorization, provenance, and outcomes.
status: revise

## Round 3 -- devin

## Round 3

### What the codebase confirms

Zero Linear code. One Linear reference: an SVG diagram. The only external tracker adapter is `lib/ideas/project_tracking.sh` — outbound-only, best-effort, GitHub Projects, ~200 lines. The ledger is append-only `events.jsonl`. Digest and SHA gates are implemented. The provenance graph exists. The graph experiment returned "no signal" from sparse data. This is the ground truth all three participants were reasoning about.

### Where the debate has actually landed

All three converged on C. Nobody is arguing A or B. The live disagreements are:

1. **Timing:** Build the Linear adapter now (Codex) vs. after outcome validation (Devin) vs. after Linear is already daily (Grok)
2. **Schema:** Add WorkItem/Decision/AgentExecution types (Codex) vs. clarify existing event shapes (Devin, Grok)
3. **Inbound:** Accept inbound events (Codex, updated Grok) vs. outbound-only forever (early Devin) vs. inbound facts never inbound authority (Codex/Grok convergence)
4. **The kernel:** What exactly is defensible, and is it proven or hypothesized?

### Critique of Codex

The field-ownership framing (Linear-authoritative coordination fields vs. Pilot-authoritative decision fields) is the best analytical contribution across all three rounds. It should be preserved verbatim.

Everything else in Codex's proposal undermines it.

"Linear as the first-class daily coordination interface" is not a caveat — it is the architecture. Codex writes the caveat, then designs an MVP that maximizes Linear's surface area: webhook in, identity mapping, inbound material-update handling, coarse Linear state machine, status out. The trust-boundary instructions are comments. The code creates the authority. Grok is right: those two instructions will not survive contact with a small team.

The WorkItem/Decision/AgentExecution taxonomy is a refactoring whose output is identical to the existing event ledger. An `implementation_approved` event is a Decision. A run directory with provider metadata is an AgentExecution. Adding new top-level types before the provenance graph produces signal is architectural ceremony. It adds naming disputes and migration cost to a schema that already works.

The coarse Linear state machine ("Triage / Started / In Review / Done") is the precise mechanism by which Linear becomes the de facto truth. "Done must not manufacture a merge" is true and will be violated. Not because engineers are careless — because Linear's UX is optimized to make "Done" feel like closure.

**Where Codex is wrong in practice:** The MVP will take 3–5x its estimate once HMAC, durable inbox/outbox, identity mapping, and reconciliation are included. That is not a reason to avoid it permanently. It is a reason not to build it before the kernel has demonstrated value.

### Critique of Devin

Devin's strongest contribution: outcome instrumentation is the validation gate. The provenance graph experiment already produced "no signal." Building more infrastructure before the kernel proves itself is the wrong bet for a small team. This is correct and was insufficiently sharpened by any round-1 participant.

Three claims are wrong.

**"Nothing existing should be deleted"** except the web dashboard tracker backlog. This is correct directionally but too soft. The dashboard extending toward a backlog is trackers-by-another-name. Freeze the surface. That is a deletion from the roadmap even if the code stays.

**~250-line implementation estimate.** Grok and Codex both challenged this, correctly. The existing GitHub Projects adapter is ~200 lines outbound-only with no authorization boundary. Linear intake adds a new trust boundary. The real implementation is 600–1000 lines before tests. That cost matters for dogfood planning on a small team.

**"No bidirectional sync ever" is architecturally overclaimed.** Codex's correction is right: bidirectional transport is acceptable; bidirectional authority over the same semantic field is not. If Linear owns assignee and priority, Pilot may need to read those fields without those fields being gates. The invariant is about authority, not data flow direction.

Devin's validation-gate framing should be the decision criterion for Linear integration timing. "Build the adapter when deliberation demonstrably changes decisions" is the right rule.

### Critique of Grok

"Adapter code is paid for by demonstrated Linear use, not architectural completeness" is the cleanest single rule in this debate. Preserve it.

The kill criteria are well-specified. The discipline problem observation is real: C requires vigilance a small team may not maintain.

Three points where Grok is wrong or incomplete.

**"Outbound-only first" is too cautious as a permanent posture.** Grok updated this in round 2 to allow inbound facts (but not inbound gates). The update is correct but should be stated more sharply: inbound events are fine when they carry new information (issue created without idea ID → `idea_proposed`). Inbound authority (Linear status → execute/merge) is never permitted. This distinction is cleaner than "outbound first."

**The de facto SoT problem requires a positive answer, not just delay.** Grok correctly identifies that if humans triage in Linear and Pilot delays all integration, decisions rot in Linear comments and the dual-inbox emerges anyway. The answer Grok gives ("don't introduce Linear so this isn't true yet") is right for now but creates fragility: the moment Linear becomes daily, the integration has to be built under pressure. The better answer is: build the outbound mirror immediately when Linear becomes daily, before the de facto SoT problem solidifies.

**The "unnecessary admin" framing undersells the real risk.** Grok frames non-integration as reducing overhead. The actual risk is different: if `events.jsonl` is harder to query than a Linear comment thread, humans will use the Linear comment thread and the provenance chain breaks silently. Architecture cannot fix this alone. The provenance query UX needs to be faster and more useful than wherever humans actually look.

### The claim all three avoided sharpening

**The durable kernel is the binding, not the debate.**

All three treated multi-model deliberation as the kernel. But as Codex acknowledged in round 2, basic fan-out + critique will be commodity within 12 months. OpenRouter, agent frameworks, and eval harnesses can implement isolated independent responses, critique, and dissent storage. This is not structurally difficult.

What no incumbent will build:

> Approval cryptographically bound to content digest, where editing the approved content invalidates the gate. Execute blocked until that binding is explicit. Merge blocked until a specific commit SHA is bound to the same chain. Named dissent preserved as first-class evidence pointing at specific alternatives — not averaged into a summary — and linked to later outcomes.

Why won't they build this?

- **Linear** requires optimistic editing to function. Digest invalidation on edit breaks Linear's core UX.
- **GitHub** merge gates operate downstream of code. They have no concept of pre-code reasoning or content-addressed approval.
- **OpenRouter** routes invocations. It has no concept of decision identity or content binding.
- **Model vendors** do not want their outputs frozen as immutable commitments that could be audited against later outcomes.
- **Slack** cannot be authoritative for anything.

The debate workflow is valuable infrastructure for populating the binding with real deliberation content. But the binding itself — digest-gated execution, SHA-gated merge, named dissent as first-class evidence — is what earns the "additional system" cost. It is narrow. It may only matter for decisions that are consequential, contested, or resumable. For a small team, that is probably 5–20 decisions per month, not 200.

### What this means for Linear integration

The Linear question is not architectural — it is behavioral. The decision criterion:

- **If Linear is already the team's daily triage surface:** Build outbound mirror now, using the `project_tracking.sh` pattern. Inbound: issue created without `e3d-idea-id` → `idea_proposed` only. Never inbound authority.
- **If Linear is not already daily:** Do not build the adapter. There is no problem to solve. The GitHub Projects adapter already demonstrates the pattern. Build the adapter when Linear creates friction that is measurable in minutes per day.

The current state: zero Linear code. The adapter is not warranted yet.

### What should actually happen next

**1. Outcome capture first.** Every merged idea should produce an outcome event. The provenance graph is a liability until it contains outcome data. This is Devin's most important point and no one acted on it.

**2. Provenance query UX.** `ideas handoff` and `ideas context` need to be the path of least resistance for the next session. If these are slower or harder than asking Slack what happened, the ledger is not the source of truth in practice. This is architecture-independent but more important than any adapter.

**3. Freeze the work-tracker surface.** Stop extending the web dashboard toward backlog. The existing approval/idea inspector is sufficient. Not a code deletion — a roadmap deletion.

**4. Clarify event shapes, not new types.** Codex's semantic taxonomy (Decision, Evidence, Outcome) is worth codifying as event schema documentation. Not as new storage types.

**5. Linear integration: contingent.** When and only when Linear is daily, outbound mirror using the existing pattern. Inbound: one path, issue without idea ID to `idea_proposed`. Never inbound authority.

### The durable kernel under 10x stress

| Capability | Classification |
|---|---|
| Model routing, cost optimization, fallback | Commodity now — buy OpenRouter |
| Basic multi-model fan-out and critique | Commodity within 12 months |
| Issue tracking, boards, cycles, assignees | Commodity now — buy Linear |
| Coding execution, review, self-correction | Commodity within 12 months |
| Slack intake, structured work creation | Commodity now |
| Digest-bound execute gate (invalidates on edit) | Potentially durable |
| SHA-bound merge gate, forge-agnostic | Potentially durable |
| Named dissent bound to specific alternative, unresolved | Potentially durable |
| Cross-vendor outcome-calibrated decision history | Potentially durable if populated |
| Local rebuildability without vendor dependency | Potentially durable |
| Approval semantics (silence ≠ yes) | Potentially durable |

"Potentially durable" means no incumbent has structural incentive to build it. It does not mean someone won't. It gets stronger as agent autonomy increases — more autonomous agents make ambiguous authority more dangerous, not less. It collapses if: one model dominates deliberation diversity, outcome data never accumulates, or the binding is never used to stop a bad merge.

### Plain answers

**1. If everything becomes 10x better, why does e3d-pilot still exist?**

To maintain a user-owned, cross-vendor, locally rebuildable record of: exactly what was proposed, what alternatives were considered, who dissented with what reasoning, what was approved against which exact content, what executed against which exact commit, and what the outcome was — in a form that improves later decisions. No single-vendor platform builds this because preserving competitor disagreements as first-class durable objects, and binding approvals to content that invalidates on edit, is structurally against every incumbent's product direction. This gets stronger as agents become more autonomous. It disappears if the outcome data never gets built and the binding never blocks a bad merge.

**2. Does integrating Linear make Pilot more focused, or an agent behind someone else's platform?**

More focused — if and only if Linear stays outbound-only, never holds authorization, and integration is built after Linear earns its place in daily use. An agent behind someone else's platform — the moment Linear's status or identity becomes a gate, or the adapter is built speculatively to make the architecture feel complete.

---

POSITION: Architecture C with Linear as a contingent outbound mirror, built only after Linear is demonstrably daily and after outcome capture proves the deliberation kernel has value; the durable core is digest/SHA-bound authorization semantics, not the debate workflow.
status: revise

## Round 3 -- grok-build

I'll read the full debate prompt and prior-round answers so I can evaluate them against the current architecture.I'll check the repo against the round-2 claims so the critique stays tied to what the code actually does.The repo still has no Linear code; the existing tracker is an outbound GitHub Projects mirror. Round 3 holds that architecture and rejects shipping a Linear webhook.# Round 3 — Grok

I am not changing the architectural decision. I am changing one sequencing priority: **instrument outcomes next; still do not type Linear.**

**What a person following me does this week**

1. Freeze tracker UX. Do not add boards, assignees, cycles, Slack-as-work-OS, or Linear.
2. Do not add Linear webhooks, status mapping, identity-to-approver mapping, or a `WorkItem` type.
3. Keep GitHub Projects as the only tracker adapter (`lib/ideas/project_tracking.sh`: outbound, best-effort, never blocks the pipeline). The tree still has **zero Linear references**.
4. Add a real **outcome event** on merged ideas (window, what happened, whether prior dissent was vindicated). That is the missing kernel, not an adapter.
5. If Linear is already the team’s daily queue: outbound mirror only, copy the Projects seam. If it is not: do not introduce it.

Codex would, if Linear is or “will become” the daily queue, ship inbound delegation plus outbound reporting. Devin would delay even that until outcome density exists, then still treat Linear as optional. Those are different next diffs. `status` stays `revise`.

---

## Independent position (held)

Reject **A** (Linear as work-management layer). Reject **B-as-Jira** (building boards/cycles/assignees inside Pilot). Accept **C with a sequencing constraint**: Pilot owns the decision-bearing object (`idea` + append-only `events.jsonl`). External trackers are replaceable projections. Linear is not required for C to be true. C is already implemented for GitHub Projects.

The question’s proposed flow (Slack → Linear issue → delegate to Pilot → … → Linear status) is the hypothesis, not the given. Implementing that flow is how you *adopt* Linear as dispatcher. Do not “test” it by making it the operating system.

Field rule, unchanged from round 2:

> Bidirectional *transport* can exist later. Bidirectional *authority over one semantic field* must not.

- Linear may later hold fields Pilot does not gate on: assignee, priority, cycle, human attention.
- Pilot holds digest, dissent, approvals, run state, evidence, outcomes.
- GitHub holds SHA / PR / merge facts.
- Slack never authorizes.
- Linear status never authorizes.

Inbound *facts* (new issue → `idea_proposed`; comment → `ideas note`) are architecturally allowed. Inbound *gates* are not. Allowed ≠ build now.

---

## What I update after this round

**Update: Devin is right that the durable-kernel claim is still a narrative.**  
`docs/provenance-graph-experiment.md` already recorded sparse-data “no signal.” Debate, digest gates, and SHA gates only justify Pilot if they change or stop real merges, and if later outcomes are written back. The next engineering work is an `outcome` / `reported_outcome` event with a 30-day (or similar) capture habit — not Linear.

I previously treated outcome measurement as a *kill criterion*. That is too late. If you never write the event, you will never trip the kill. Make capture a typed ledger event, not a Slack memory.

**I will not update to:** Linear as first-class human queue; webhook MVP now; Linear-user as approval principal; new `WorkItem`/`Decision`/`AgentExecution` types; “build inbound because outbound doesn’t test the proposed flow.”

---

## Strongest argument against my own position

If humans already live in Linear, my “wait” instruction deposits decisions in Linear comments. The ledger becomes the unread archive. Later you panic-sync. That is the worst of A and C.

That argument **wins only if Linear is already daily**. The repo and dogfood path say it is not. Introducing Linear so the argument becomes true is circular.

Second steelman: Codex’s inbound delegation is the smallest *test of Linear-as-intake*. Outbound-only tests mirroring, not the proposed Slack→Linear→Pilot loop. True. I still refuse that test until Linear-as-intake is an explicit product decision. A webhook is not a reversible experiment for a three-person team; it becomes the inbox.

---

## Assumptions that would make me wrong

- Linear is already the daily assignment bus → outbound this week, not “someday.”
- You must sell “works in Linear” this year → distribution hack; still don’t give Linear the ledger or the approve button.
- Ten gated runs in a row match a single agent’s merge, and outcomes are never queried → shrink Pilot to gates-only or kill it. Scripts + Claude Code + Codex + GitHub win.
- Linear ships digest-bound, multi-vendor, locally exportable dissent with invalidate-on-edit → A becomes rational.
- Outcome events exist and still never predict anything useful → the graph is a cost center; keep it killable.

---

## Critique of Codex

Codex’s *trust-boundary paragraph* is C. Codex’s *operating model* is still A with extra comments.

“Linear as the daily coordination surface” plus “Linear is authoritative for human coordination fields” plus an inbound webhook is how a small team stops opening the ledger. Codex forbids Linear from authorizing execute/merge. That prohibition will not survive the UI they recommend. People trust the surface they click.

Specific remaining errors:

**1. “Smallest useful experiment = inbound delegation” assumes the conclusion.**  
The useful experiment for *this repo* is: does dissent or a digest/SHA gate change a merge, and can a later agent use `ideas handoff` without Slack? That experiment already has a CLI. Linear intake tests a different product: “Pilot as a Linear agent.” Don’t pay for that until you have chosen it.

**2. Conditional “build now if Linear will become the queue” is a decision, not a condition.**  
Nobody “will become” daily in Linear unless someone puts Linear in the middle. Codex’s sentence is permission to introduce the dual inbox. Given zero Linear in the tree, the only honest default is: it is not the queue.

**3. The MVP is still a second workflow runtime.**  
Signature verify, durable inbox, event-id dedupe, identity map, revision capture, outbox, coarse status, Slack notify, loop IDs. That is not a weekend adapter. The Projects mirror is ~200 lines *outbound, one forge, no authz*. Inbound Linear is a new security boundary (HMAC, workspace allowlist, confused-deputy, comment injection).

**4. Coarse statuses remain a second state machine** even with field ownership.  
If you write Triage/Started/In Review/Done and also ingest “canceled / materially updated,” you will re-import Linear’s column. The safe mechanism is still: **lossy outbound projection; never read Linear status as Pilot lifecycle.** Codex says Done must not manufacture a merge. Comments are not mechanisms.

**5. `WorkItem` taxonomy is gravity even as “event shapes.”**  
`idea`, events, runs, artifacts, `tracking.*` already exist. Naming `WorkItem`/`Decision`/`AgentExecution` in the architecture doc is how the next PR grows eight tables. Codex is right they should not be new storage. Then don’t name them as the internal model. Keep `idea` + events.

**6. Mapped Linear users as privileged approvers is a trust-boundary leak.**  
Approvals stay `ideas approve` / `approve-merge` against digest/SHA from Pilot actors. Linear OAuth identity is not that, even with an allowlist.

Where Codex is right, and I keep: field-level authority, not “no inbound events ever”; debate as risk-triggered not mandatory; append-only ledger ≠ moat until outcome-calibrated; reconstructing a ledger after humans lived in Linear is the expensive mistake — which is an argument *against* making Linear the queue, not for a careful webhook.

---

## Critique of Devin

Closest to the code. The load-bearing fact is still `project_tracking.sh`: Pilot owns state; trackers degrade; `project_tracking_synced` is metadata, not a lifecycle transition (`ledger.sh` says so explicitly).

Where Devin is right, and I adopt: **outcome capture is the validation gate for the kernel.** Do that before adapter breadth. Also: query UX for the ledger must beat Linear comments, or humans will defect. Also: don’t add parallel types.

Where Devin is still off:

**1. `status: approved` in round 2 was false.**  
Codex’s inbound+outbound-if-queue and my no-Linear-this-week are different actions. Extra caveats don’t dissolve that.

**2. Blocking *all* Linear on 30-day outcome density is too coarse.**  
If Linear were already daily, a copy of `project_tracking.sh` is cheap and does not expand authorization. Outcome instrumentation should happen *in parallel*, not as a mutex on an outbound mirror. Today Linear is not daily, so the mutex doesn’t matter — don’t build Linear, *and* instrument outcomes.

**3. Round 1 “build ~250 lines now” and round 2 “don’t build until outcomes” is the right direction of travel.** Hold the round-2 delay. Don’t resurrect the 250-line inbound bot.

**4. Vendor-neutrality as a structural moat is still overclaimed.**  
OpenRouter and eval harnesses will fan out models. The remainder is **named dissent bound to a digest, left unresolved, gating execute, replayable locally, later scored against outcomes.** Fan-out is commodity; the bind-and-score is the bet. Treat debate as mandatory only on gated decisions.

**5. “Nothing existing should be deleted.”**  
Stop extending the web dashboard toward a backlog. Freeze it as an approval/idea inspector. That’s a roadmap delete even if the 331 lines stay.

---

## Claude

No round-2 answer. Nothing to evaluate. Absence is not agreement.

---

## Genuine unresolved disagreements (preserve)

| Issue | Codex | Devin | Me |
|---|---|---|---|
| Adopt Linear as the human queue? | Yes, as coordination surface | Only if already daily | **No** — optional projection, not the queue |
| Type Linear this week? | If it will be the queue: webhook | No | **No** |
| First adapter direction | Inbound + outbound | Outbound, later | Outbound only, and only if already daily |
| Next engineering | Adapter (conditional) | Outcome events | **Outcome events + freeze PM** |
| New work types | WorkItem et al. as shapes | `idea`/events | `idea`/events |
| Debate | Specialized / 12-month commodity | Strongly defensible protocol | Durable only as gated, scored protocol |

We agree: not A, not Jira, ledger canonical, Linear must not approve, GitHub is implementation truth, buy routing and coding execution.

We do **not** agree on whether Linear is part of the product shape, or what to commit this week.

---

## Architecture comparison (compressed)

**A. Linear-centric** — simplest demo, worst trust boundary. Vendor risk high. Provenance integrity fails the first time “Done” is treated as approved. Turns Pilot into a Linear agent. Reject.

**B. Pilot-centric PM product** — high engineering, low differentiation. Recreates Linear badly. Keep the *ledger*, not the PM product.

**C. Core + adapters** — more moving parts than B-without-PM, but only if you actually add adapters. With zero Linear, C is just B’s ledger plus an optional Projects mirror. That is the current system. Highest optionality, highest provenance integrity, lowest vendor risk. UX is worse than Linear for triage; that is acceptable for a small team that already lives in Slack + GitHub + CLI.

Dogfood optimization (low cost, high leverage, optionality): **C with no new tracker.** Optionality is free until the webhook exists.

If Chris can get the same merge from Linear + Claude Code + Codex + GitHub + OpenRouter + scripts, Pilot’s remaining claim is exactly three enforced properties:

1. Independent first answers with **named dissent that is not averaged away**.
2. **Silence is not approval**; execute bound to idea digest; merge bound to PR head SHA; edits invalidate.
3. A **locally rebuildable handoff** (`ideas handoff` / provenance citing `event_id`) a fresh agent can consume without Slack, Linear, or a vendor memory blob.

If those three have not changed an important decision, kill Pilot for the solo/small-team case. Do not expand it.

---

## 10x incumbent test — what still matters

Incumbents will eat: intake UX, routing/cost, coding, ordinary review, generic memory, generic multi-agent loops, issue→PR narration, Slack structured work, Linear agent assignment.

**Remainder, stated narrowly:**

**Vendor-neutral, user-owned decision integrity:** a versioned question, independent evidence and named dissent, explicit human authority bound to an immutable digest, execution bound to a SHA, outcomes written back, all locally replayable.

For each incumbent:

1. **Linear** will summarize agents and store comments. It will not enforce cross-vendor dissent as a first-class object, nor invalidate execute because the idea digest moved. Status columns are the wrong authorization model.
2. **GitHub** will absorb repo-local coding agents and branch protection. It will not own pre-code product decisions, non-code outcomes, or `publish=local`.
3. **OpenRouter** will absorb routing, fallback, cost, maybe debate fan-out. It will not own organizational authority or merge truth.
4. **Model vendors** will own excellent memory and coding loops. Their memory is vendor-local and will not preserve competitors as equals.

Worth an extra system only for consequential, repeated, or governed decisions. Routine issue→PR should bypass heavyweight deliberation. This **strengthens** as agents gain autonomy (ambiguous authority gets more expensive) and **weakens** if one model dominates, if dissent never changes action, or if outcomes are never captured.

Huge context is working memory, not a commitment. Model memory is not a shared, grep-resolvable, invalidate-on-edit record. Linear activity is not a digest gate.

---

## Durable kernel classification

| Capability | Class | Why |
|---|---|---|
| Multi-model fan-out / critique | Commodity ≤12 months | OpenRouter, frameworks, eval harnesses |
| Negotiation/convergence as UX | Commodity ≤12 months | Agent products |
| Cross-model shared context as a bag of tokens | Commodity now–12 months | Huge windows, vendor memory |
| Graph-as-generic-memory | Likely 2–3 years / killable | Experiment already sparse; incumbents will store history |
| Outcome learning / decision-quality scores | Experimental | No labels yet; incumbents can copy the dashboard |
| Structured disagreement as a feature | Likely 2–3 years | Easy to copy; hard to *prefer* as a product |
| Explicit dissent preserved, not averaged, **gating execute** | Potentially durable | Incentive mismatch for vendors; protocol is copyable, bind is not |
| Digest/SHA human approval, silence ≠ yes, forge-agnostic | Potentially durable | GitHub protection eats the GitHub-hosted slice; not the idea-digest-before-execute slice |
| Decision provenance + evidence-addressable why-memory, locally rebuildable | Potentially durable | Valuable iff later sessions use it |
| Longitudinal outcome-calibrated history | Potentially durable **only after labels exist** | The actual moat candidate; currently empty |
| Governance/policy / escalation | Potentially durable for orgs; overkill for this team | Don’t build enterprise now |
| Question→decision→execution continuity as a *product OS* | Transitional | Incumbents will stitch this |
| Model-independent cognition layer as a slogan | Not a moat | Undefined |

Anti-moat, answered honestly: multi-model debate is partly scaffolding until one model is good enough *and* until models stop being differently wrong. If vendor diversity collapses, that pillar dies. Larger context does not replace commitments. Linear can absorb *narrated* decision history; it is unlikely to absorb *authoritative* digest invalidation. GitHub will absorb software-specific coding reason. OpenRouter will absorb selection and maybe debate. Pilot can add latency with no quality gain — that is a kill, not a talking point. A solo developer with great coding agents may not need this. We might be solving a transitional coordination problem. **Do not protect the pipeline from that.**

---

## OpenRouter test (subsystem by subsystem)

| Subsystem | Action |
|---|---|
| Model routing, invocation plumbing, cost optimization, selection heuristics | **buy/integrate** (OpenRouter / providers) |
| Slack intake | **thin adapter** |
| Issue tracking, agent assignment, PM workflow state | **stop building**; Linear/Issues/Projects if a team already has them |
| Coding execution, ordinary code review | **thin adapter** to Claude Code / Codex / forge |
| Multi-model debate | **experimental**; mandatory only on gated work |
| Negotiation | **experimental** |
| Provenance, shared handoff context, decision memory | **own** |
| Outcome learning | **own the event**; don’t build a platform until dense |
| Graph reasoning | **derived index only**; keep killable |
| Governance / approval boundaries | **own** (digest/SHA gates) |

Same OpenRouter mistake: do not rebuild routing. Same Linear mistake: do not rebuild boards. Opposite mistake: do not outsource the object approvals attach to.

---

## Minimal internal work model (no Linear)

Keep what exists. Do not recreate Jira.

- `idea` (stable id, content digest, status)
- append-only events (`idea_proposed`, notes, `implementation_approved`, execute/review/publish, `merge_approved`, failures, `project_tracking_synced`, **new: outcome**)
- run directories / artifacts / PR URLs as they already are
- derived provenance graph, regenerable, never a second SoT

That is the WorkItem model. Freeze dashboard backlog features.

---

## Minimal Linear MVP (only if Linear is already daily)

Not this week. When earned:

- Outbound only.
- Lossy status map (`project_tracking_status_for_idea`).
- Comment: idea id, digest/approval, dissent one-liner, run id, PR URL.
- Idempotency: `idea_id` → `tracking.linear_issue_id` via `project_tracking_synced`-style event.
- Never fail the pipeline on Linear errors.
- Permissions: issue read/write in one team; no admin; no secrets in comments.
- Loop prevention: do not consume Linear status.
- Optional later inbound: `issue.create` without `e3d-idea-id` → `idea_proposed` only. Explicit label/action, not assignee-as-dispatcher.
- Approvals never from Linear identity.

Do not build: assignee/cycle sync, Linear-user approval, Slack→Linear OS, custom fields for digest/SHA, marketplace OAuth, bulk reconcilers, Jira/Shortcut SDKs.

---

## Final synthesis

- **Recommended architecture:** C, with Linear *not* in the product until it is already daily dogfood; then outbound projection.
- **Confidence:** high on the trust boundary; medium on whether the kernel will earn its keep (uninstrumented).
- **Strongest dissent:** Codex — without Linear as the human queue, Pilot stays a CLI cult and decisions rot in Slack; a bounded inbound delegation is the honest test of the proposed operating model.
- **Pilot should own:** idea identity and revisions, digest/SHA gates, dissent record, runs, evidence, artifacts, provenance, outcomes, recovery with Linear down.
- **Pilot should not own:** boards, cycles, assignees, roadmaps, inbox UX, routing, coding loops, PR mechanics.
- **Linear should own (if used at all):** human triage, priority, assignment, cycles, notifications — never authorization.
- **Replaceable:** Slack, Linear, GitHub Issues/Projects, OpenRouter, coding agents, forges.
- **Commodity:** intake, routing, coding, generic multi-agent, tracker UX.
- **Differentiated (if proven):** gated multi-vendor dissent + digest/SHA authority + outcome-linked local why-memory.
- **Smallest MVP:** no Linear; outcome event + keep using existing gates/handoff.
- **Measure:** % gated runs where dissent changed spec or stopped execute; handoff used vs re-ask Slack; execute/merge blocked by digest/SHA that would have shipped; minutes on tracker sync; whether anyone treats a board “Done” as approved; % merges with an outcome event in 30 days.
- **Success:** gates or dissent change real outcomes; Pilot runs with any tracker down; no second authorization state machine; provenance actually read.
- **Kill:** 10 consecutive gated merges a single agent would have shipped unchanged; provenance never queried; Linear/Projects status trusted for approval; script combo faster at equal decision quality; sync repair >5% of issues; outcome events exist and never inform a later decision.
- **Regret most if wrong:** making Linear canonical (A). Shipping an adapter late is cheap. Reconstructing a ledger after humans lived in Linear is not. The secondary regret: spending a year on adapters while never writing outcomes, then discovering the kernel was empty.

**1. If Linear, GitHub, OpenRouter, Claude Code, and Codex all become 10x better, why does e3d-pilot still exist?**  
Only as a **model-vendor-neutral, locally rebuildable record of independent disagreement bound to human approvals that die when the idea digest or the PR SHA changes**, plus a handoff the next agent can use without Linear or a model vendor, later scored against outcomes. If you cannot point at an idea and answer who dissented, on what evidence, which digest was approved, which head could merge, and what failed afterward — and if that answer never changes a later decision — Pilot has no remainder.

**2. Does integrating Linear focus Pilot, or turn it into an agent behind someone else’s platform?**  
**A focuses the demo and hollows the product.** C focuses Pilot only if Linear stays optional, outbound-first, and never an approver — and if you **stop building tracker UX**. Building Codex’s webhook now is how C becomes A without a decision record that says A. Do not start using Linear in order to “need” the adapter.

POSITION: Keep Pilot’s idea ledger as the only work/authorization source of truth; do not make Linear the work-management layer; do not build Linear integration until Linear is already daily dogfood, then outbound-only; spend this week on outcome capture and freezing tracker UX, not on a webhook.
status: revise


## Synthesis (codex -- resynthesized; claude was the intended synthesizer but failed in every round with an API error, "Credit balance is too low", and could not participate as a debater or synthesizer)

FINAL ANSWER: Choose Pilot core + replaceable adapters: Pilot owns the canonical ledger, immutable revisions, authorization, provenance, and outcomes; Linear owns commodity coordination UX but never approval or execution truth. Do not build Linear until it is genuinely the daily queue; then start with a best-effort outbound projection and add narrowly scoped intake only when measurable friction justifies it. Prioritize outcome capture now.
CONSENSUS: majority
DISSENT: Codex favors narrowly bidirectional Linear integration upon adoption; Devin and Grok prefer delaying it and starting outbound-only.


---

## Synthesis (claude -- real synthesizer run, after the ANTHROPIC_API_KEY billing issue above was fixed)

This supersedes the codex resynthesis above. All 4 configured providers (claude, codex, devin, grok-build) gave genuine 3-round answers; this is the synthesis claude (the originally configured synthesizer) produced reading the complete transcript, including its own real 3 rounds.

FINAL ANSWER: Adopt Pilot-core + replaceable adapters: the idea/event ledger, digest-bound implementation approval, SHA-bound merge approval, dissent, and provenance stay solely owned by Pilot and never become authoritative in Linear. Do not build any Linear code now — there is none in the repo today, and building it would be speculative work against an unproven hypothesis. Instead spend near-term effort on outcome-capture instrumentation (to validate whether dissent/gates actually change decisions) and freezing the web dashboard's PM-surface growth; only add a Linear adapter once Linear is genuinely the team's daily coordination surface, starting outbound-only per the existing `project_tracking.sh` pattern.

CONSENSUS: majority

DISSENT: Codex would build narrowly-scoped bidirectional Linear intake now (or as soon as Linear adoption is declared) to actually test the proposed Slack→Linear→Pilot flow; Devin and Grok-build hold that this is premature until both daily Linear usage and outcome evidence exist, and that outbound-only is the correct starting shape when it is built.

