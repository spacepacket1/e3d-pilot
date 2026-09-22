# Debate

**Question:** Should we pilot TypeSafe AI's "Jev" model as a cheap pre-screen gate inside bin/e3d-debate, before deciding whether to use it elsewhere in the e3d ecosystem?

Context:

- Jev is a typed "System One" decision model, not a text generator: you give it a `state` and one or more typed `questions` (Choice: pick 1 of up to 255 options; Score: place on a 2-10 point ordered scale; Noul: yes/no with a probability), and it returns fast, cheap, structured answers with confidence scores. Vendor-reported numbers: ~$0.0004/decision, ~0.4s latency, roughly matching Claude Sonnet 5's "accuracy" (defined as agreement with frontier-model-generated reference labels, NOT ground truth) on their published aggregate workflow eval, at ~300x lower cost and ~195x lower latency than Sonnet 5 on that same eval. It is explicitly designed to sit in front of an expensive reasoning model as a fork/router/gate, not replace it for open-ended generation, and low-confidence answers are meant to fall back to the real model.
- It is a new third-party paid vendor dependency, separate from the model provider adapters already wired into lib/providers/ (claude, codex, devin, gemini, grok-build, local).
- bin/e3d-debate today always runs every question through N full providers (default 2, up to 4-5 for higher-stakes questions) across 2+ rounds plus a synthesis call, regardless of whether the question is actually contentious -- e.g. earlier today we ran a full 4-provider, 2-round debate on a question where 4 of 5 model responses converged quickly.
- The proposed pilot: add an optional pre-screen step to bin/e3d-debate that asks Jev a single Noul question -- "is this question's answer obvious enough that informed people would not meaningfully disagree, or does it need genuine multi-perspective debate?" -- before spending the full multi-round run. High-confidence "obvious" answers short-circuit to a fast one-line answer (clearly labeled as gate-decided, not committee-decided); low-confidence or "needs debate" answers fall through to today's unchanged full committee flow, exactly as now.
- If this pilot validates the vendor integration and gate trustworthiness, two follow-on candidates were flagged (explicitly out of scope for this specific idea, to be decided separately): (1) using the same Choice/Score/Noul pattern to pre-filter which on-chain wallet/token activity is "story-worthy" before spending an LLM call to write a Story/Thesis narrative in the spacepacket/e3d-ai stack; (2) gating e3d-oppscan's free and paid intake ("is this submission substantive enough to analyze, or spam/gibberish?") before spending a paid-tier LLM call on it.

Question for the panel: should we build this e3d-debate pre-screen pilot? Given it's a recursive case -- using a cheap gate to decide whether to run the exact kind of expensive multi-model process the gate itself would be gating -- is there a meaningful risk of the gate silently suppressing debates that actually needed multiple perspectives, and if so how would you detect that failure mode before it costs something real (e.g. a wrong approval)? If you would NOT build this, what, if anything, should be done instead to cut e3d-debate's cost? And separately: does piloting in e3d-debate (internal tooling, no customer exposure) actually de-risk the customer-facing candidates (stories/theses, oppscan intake), or are those different enough problems (irreversible customer-facing filtering vs. an internal decision aid) that a debate-gate pilot tells us little about whether to trust Jev there?

## Round 1 -- grok-build

I'll ground the recommendation in how `bin/e3d-debate` actually spends calls today, then answer the pilot question directly.No. Do not add a Jev short-circuit to `bin/e3d-debate`.

The Noul question — "would informed people disagree?" — is the decision the committee exists to make. A high-confidence "obvious" answer deletes the only evidence that it was wrong: round-2 dissent. TypeSafe's accuracy number is agreement with frontier-model labels, not ground truth, so shared blind spots count as correct. That is the silent-suppression failure, and a one-line gate answer leaves nothing to audit after a bad approval.

`e3d-debate` already stops once round 2+ reports convergence. The expensive case is the default itself: N providers × 2 rounds + synthesis, including runs that agree quickly. Those agreements are the product. Skipping them to save a rare, operator-triggered call is the wrong trade. A new paid vendor outside `lib/providers/` is not justified by that.

Detect it only in shadow mode: score Jev on past transcripts and live runs, log whether it would have skipped, and compare to whether the debate changed the recommendation or left named dissent. Never let it skip. If the false-obvious rate is not near zero on questions you already know were contested, stop.

Cut cost inside the current loop instead. Default to 2 providers. Skip synthesis when every round-2 status is `approved` and emit the agreed position directly. Add a round-1 overlap check only as a human-reviewed hint, not a stop.

A debate pilot does not de-risk story/thesis filtering or oppscan intake. It would only prove auth, schema, latency, and billing. Those gates are irreversible and customer-facing, with different labels (spam, story-worthiness) and different loss. Trust for them needs their own labeled sets.

## Round 1 -- claude

Yes, build it — but as a shadow-mode pilot before it ever short-circuits anything.

**Recursion risk is real but detectable cheaply.** The failure mode is Jev confidently gating away a question that actually had genuine disagreement. Don't trust vendor eval numbers (self-reported agreement-with-frontier-labels, not ground truth). Instead: run the gate in shadow mode for the first N debates — call Jev, log its verdict and confidence, but *always* run the full committee anyway. Then compare: on questions Jev called "obvious," did the full committee's rounds actually converge fast, or did providers diverge? That gives you a real false-negative rate (gate says skip, committee actually disagreed) before the gate ever suppresses a real run. Only flip it live once that rate is low on a decent sample (~30-50 debates) and skewed toward your actual question mix, not toward low-stakes ones.

**Cheaper alternative if you don't want the vendor dependency yet:** you already have the signal you need without Jev — after round 1, if all providers' answers cluster (simple string/embedding similarity or even exact-match on Choice-style questions), skip round 2 and synthesis, same short-circuit logic, zero new vendor. That's worth trying first since it's free and tests the same "detect convergence early" hypothesis.

**On de-risking the customer-facing candidates: no, not much.** e3d-debate gating is reversible and low-stakes — worst case a stale one-liner gets caught by a human reading the debate output. Oppscan intake filtering and story-worthiness filtering are irreversible drops: a false "not worth it" verdict means the content never gets seen by anything smarter, no human is in the loop to catch it. A clean internal pilot tells you Jev's Noul calibration is *plausible*, not that it's safe to use as a silent filter on customer-facing paths. Those need their own shadow-mode validation with their own failure-rate thresholds — treat this pilot as a Jev integration/calibration test, not a transferable trust result.

## Round 1 -- codex

Yes—pilot Jev in `e3d-debate`, but initially in shadow mode, not as an autonomous short-circuit.

The proposed design has a flaw: Jev can decide “obvious,” but cannot produce the actual one-line answer. Once another model must answer, the sensible route is:

- “Needs debate” or low confidence → unchanged committee flow.
- High-confidence “obvious” → one full provider, not zero providers.
- High-stakes categories → always debate.

For the first few hundred decisions, run the committee regardless and log Jev’s prediction. Measure the dangerous error specifically: cases Jev called obvious where the committee materially disagreed, changed the answer, or surfaced an important caveat. Afterward, retain randomized committee audits of perhaps 5–10% of short-circuited cases. Set the threshold from the observed false-short-circuit rate, not vendor aggregate accuracy or raw confidence. Every gate decision must be visible and overridable.

This makes failures detectable before approvals depend on it. Without shadow labels and ongoing audits, silent suppression is a meaningful and unacceptable risk: “controversial” is context-dependent, and agreement with generated reference labels is weak evidence for safe routing.

If Jev cannot achieve a very low false-short-circuit rate, drop it and use a simpler single-provider-first escalation policy based on uncertainty, risk level, and answer characteristics.

The pilot meaningfully de-risks vendor integration, latency, cost, reliability, confidence calibration, and audit plumbing. It does not validate customer-facing story-worthiness or spam filtering. Those require separate domain-specific shadow pilots because their errors suppress customer content and have different class balance, consequences, and reversibility.

Load-bearing assumption: debate cost is material enough to justify the added dependency and evaluation machinery.

## Round 1 -- devin

**Yes, build the pilot. Here's the decisive case:**

**Build it because:**
- The recursive framing is a feature, not a bug. A gate that wrongly marks a debate question as "obvious" is caught immediately — the person who asked it sees a one-line gate-decided answer and can trivially override to full committee. The feedback loop is tight, the stakes are low (internal tooling), and the cost of a miss is one re-run, not a published story or a missed risk flag.
- The 4-of-5-converged example you cited is exactly the target: wasted compute with zero information gain. A Noul gate captures that case with ~$0.0004 and 0.4s. Even at 50% gate accuracy the expected cost reduction is meaningful.
- Labeling gate-decided answers distinctly (not committee-decided) is load-bearing — don't skip it. It makes the failure mode visible in the output.

**On silent suppression risk:**
Log every gate decision with its confidence score. After ~50 runs, audit: what fraction of "obvious" calls would have produced divergent debate responses? If Jev's confidence >0.85 correlates with actual convergence, trust it at that threshold. If it suppresses 10%+ questions that would have diverged, tighten the threshold or widen the fallback band.

**On whether debate-gate de-risks the customer-facing candidates:**
Partially. It validates the Jev integration and confidence calibration. It does NOT validate filtering irreversible customer-facing output — oppscan and story/thesis filtering have asymmetric downside (a suppressed submission you can't recover). Treat those as separate trust decisions requiring their own pilots with explicit false-negative audits.

**If you'd rather not build it:** just add a convergence check after round 1 — if all providers agree within a small edit distance, skip round 2. No new vendor dependency.

## Round 2 -- grok-build

I'll check how `bin/e3d-debate` actually spends calls so the rebuttal tracks the code, not the vendor pitch.I still would not add Jev to `bin/e3d-debate`, including as a shadow pilot whose point is a later short-circuit.

Codex is right that Jev cannot write the one-line answer, so the proposed skip still needs a generator. That does not justify a new paid vendor outside `lib/providers/`. Claude's in-loop cut is the right cost lever, with one correction: do not auto-stop after round 1. Round 1 is independent answers; agreement before rebuttal is how a shared blind spot looks. Convergence is only checked from round 2, and synthesis still always runs afterward. Skip that synthesis when every round-2 status is `approved` and emit the agreed position. A round-1 overlap note stays a human hint, not a stop.

Devin's "the asker will re-run" misses `--repo --idea`: a gate one-liner is recorded as a decision. The label does not surface dissent nobody ran.

The shadow test the other three share cannot catch the failure that matters. Scoring Jev against later committee convergence repeats TypeSafe's metric — agreement with frontier models, not ground truth. Unanimous error looks like a true "obvious." Check only questions already known to be contested, or a human reversing the call. I would not stand up the vendor to learn that.

A debate pilot does not de-risk story/thesis or oppscan gates. Different labels, irreversible drops, no transcript left behind.

POSITION: Do not add a Jev pre-screen to e3d-debate; skip synthesis after unanimous round-2 approval, and do not treat a debate-gate trial as evidence for customer-facing filters.
status: revise

## Round 2 -- claude

My position hasn't changed. Reading the field: shadow-mode-first is now the consensus (claude, codex, devin, and I all land there), with grok-build the lone holdout for "don't build at all." That holdout doesn't survive contact — grok-build's own "detect it only in shadow mode" proposal *is* the pilot everyone else is describing, just refusing to call it that. If shadow mode runs, logs Jev's verdicts against actual committee divergence, and only flips live once false-short-circuit is near-zero on a contested-question-heavy sample, the recursion risk is bounded by construction: the gate never suppresses anything until it's been checked against ground truth (the committee itself), many times over.

Codex's refinement is the one addition worth adopting: "high-confidence obvious → one provider, not zero" softens the failure mode during rollout — a lone-provider answer is a fine fallback if the committee-agreement assumption turns out wrong, cheaper than full committee, safer than a bare gate string. I'd fold that into the live-mode design rather than treat it as a separate camp.

On transferability: unanimous now, correctly — reversible/internal (debate) vs. irreversible/customer-facing (oppscan, story-worthiness) are different risk classes. This pilot buys vendor integration, latency/cost validation, and a template for the shadow-audit methodology — not a trust transfer. Each downstream candidate needs its own labeled shadow run.

POSITION: Build the Jev pre-screen as a shadow-mode pilot in e3d-debate — log verdicts against actual committee divergence for ~30-50 runs, use codex's one-provider fallback (not zero) during any live rollout, and treat it as a vendor/methodology validation only, not a trust transfer to oppscan or story-worthiness filtering.
status: approved

## Round 2 -- codex

My position holds: pilot Jev, but shadow-only first; never let the initial version suppress a debate.

Grok correctly identifies the core risk, but “never let it skip” makes shadow validation pointless as a decision experiment. A measured pilot with strict promotion criteria can determine whether autonomous gating is safe. Claude’s 30–50 debates and Devin’s ~50 runs are too small to establish a low false-obvious rate, especially with rare but costly misses. Devin also understates the danger: labeling enables override, but users may accept confident answers—including approvals—without noticing omitted perspectives.

The proposed design still has an unresolved flaw: Jev classifies; it does not generate the promised one-line answer. A live path therefore needs one normal provider to answer:

- High-confidence obvious, low-risk → one provider.
- Low-confidence, needs-debate, or high-stakes/approval-bearing → full committee.
- Randomly audit 5–10% of short-circuits indefinitely.

Promotion should follow hundreds of representative shadow cases, measuring material dissent, changed recommendations, and missed caveats—not textual convergence alone or vendor confidence.

Grok and Claude are right that early convergence can independently reduce cost; implement round-one stopping regardless of Jev.

This pilot validates integration, reliability, economics, and domain-specific calibration only. It provides almost no safety evidence for irreversible story or intake filtering, which needs separate shadow datasets and thresholds.

POSITION: Build a shadow-mode Jev pilot, promoting only a low-risk, one-provider fast path after substantial validation and retaining audits and mandatory full debate for consequential decisions.
status: revise

## Round 2 -- devin

**Maintaining YES, with two updates from this round.**

**Codex is right on architecture:** Jev alone can't answer the "obvious" question — a model call still happens. So the gate doesn't eliminate LLM cost; it reduces N×rounds+synthesis to 1-provider+Jev. That's still a meaningful reduction but narrower than I framed. Revise the design: "obvious" path = Jev + single provider, not Jev alone. This also makes the gate-decided label honest — it's still a model answer, just ungated.

**Claude is right on sequencing:** Try the round-1 convergence check first (no new vendor, free, same hypothesis). If it cuts cost adequately, the Jev dependency isn't justified. If it doesn't (e.g., round-1 divergence even on trivially obvious questions, or you want pre-round classification), then Jev earns its place.

**Rebutting grok-build:** "Those agreements are the product" is true when the question was genuinely uncertain. It's not true when four providers agree in round 1 on something that was never contested. The gate's job is precisely to distinguish these before spending the full loop. Grok-build's own shadow-mode proposal validates the gate's signal — the only disagreement is whether to ever activate it. That's a threshold calibration question, not a reason to reject the architecture.

**Silent suppression mitigation still stands:** shadow mode first, log every gate call and confidence score, measure false-short-circuit rate before activating, retain 5–10% random audits after.

De-risking customer-facing candidates: validation of integration only, not trust transfer. Unchanged from round 1.

POSITION: Build the Jev pilot in shadow mode, try round-1 convergence first, activate the gate only after false-short-circuit rate is measured and acceptable, and treat customer-facing candidates as separate pilots.
status: revise


## Synthesis (claude)

FINAL ANSWER: Build the Jev pre-screen, but only as a shadow-mode pilot in bin/e3d-debate: log Jev's verdict on every run while still executing the full committee, promote to live gating (with a one-provider fallback, not a bare gate string) only after a large, contested-question-heavy sample shows a near-zero false-obvious rate, and keep permanent randomized audits of any short-circuited runs. Also implement the free round-1/round-2 convergence check regardless, since it captures the same waste with no new vendor dependency. This pilot validates Jev's integration, latency, cost, and calibration methodology only — it does not transfer trust to the irreversible customer-facing filters (oppscan intake, story/thesis worthiness), which need their own independent shadow-mode validation before going live.

CONSENSUS: majority
DISSENT: grok-build holds that no version of this should be built, arguing that convergent debates are the valuable output rather than waste, and that even shadow-mode validation reuses Jev's flawed agreement-with-frontier-labels metric rather than ground truth.
