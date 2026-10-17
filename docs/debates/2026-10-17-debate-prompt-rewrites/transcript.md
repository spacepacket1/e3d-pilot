# Debate

**Question:** CONTEXT
e3d-pilot runs multi-model debates (bin/e3d-debate): round 1 each model answers independently; round 2 each model sees the others' round-1 answers and rebuts or concedes; a synthesizer then writes the verdict. A review of every prompt in e3d-pilot and e3d-corp is at docs/prompt-review-2026-10.md (read it from the working directory if you can; the facts below are taken from it).

Findings that matter here:
1. In round 2 a speaker is shown its OWN round-1 answer labelled with its provider name, as if another party had said it, so models sometimes rebut themselves.
2. Prompts never say that rounds are simultaneous, so models accuse each other of ignoring points that had not yet been published. In one debate this fooled the judge.
3. Early-convergence skipping of the synthesizer fired in 1 of 20 real debates.
4. Grounding is uneven: when asked to check specs, only one provider actually read them; 16 of 17 narration leaks ("I will read the specs...") came from one provider.
5. Reviewer revision rates differ a lot by provider (7% to 84%) but are confounded by task mix, so they prove nothing yet.
The review proposes: rewrite the debate prompts behind a flag; run a blind A/B/C experiment (3 questions x 3 prompt variants first, about 60 calls, about $2-4; the full version about 900 calls, about $27-63 and 2-3 hours of a human rating blind); strip narration and add an attribution check first; later a specialist roster with --panel/--specialist.

QUESTION
Answer each point:
1. VERDICT. Pick exactly one: (a) fix the two structural flaws now, unconditionally, and skip the experiment; (b) fix them behind a flag and run the small first-stage experiment before making the rewrite the default; (c) run the full ~900-call experiment first; (d) leave the prompts alone. Justify in a few sentences.
2. Are flaws 1 and 2 really bugs, or defensible design? Is the evidence strong enough to fix without an experiment?
3. What should the experiment measure, and who or what should judge it, given that the judge models are also the debaters?
4. Of the review's recommended order (strip narration, attribution check, prompt rewrites, roster health report, specialists), what is the right first three steps? What should be dropped or postponed?
5. Risks of changing the prompts: comparability with the existing transcripts, regressions, over-engineering relative to the goal of shipping user-facing products.
Be decisive and specific, and end with one recommended next action.

**Jev pre-screen (shadow mode, informational only):** obviousness noul=0.17 (1.0 = clearly obvious, 0.0 = clearly needs debate) -- logged for calibration, does not affect whether this debate runs.

## Round 1 -- claude

1. **VERDICT: (b)**, but with the small experiment made cheap and time-boxed. Fix behind a flag and run the 3×3 first stage. Flaws 1 and 2 are nearly certain wins, so the flag is for comparability and for catching regressions, not because the fixes are in doubt. (a) skips the one check that tells you whether the rewrite helps. (c) spends $27–63 and 2–3 human hours on a prompt-hygiene problem. (d) leaves a known bug in place.

2. **Are flaws 1 and 2 bugs?** Flaw 1 is a bug. A speaker rebutting its own answer, presented as someone else's, is a labeling error with no design rationale. The fix is mechanical: label it "your round-1 answer" and exclude it from the "others" block. Flaw 2 is a spec omission. The simultaneous-rounds design is fine, but the prompt doesn't state it, and models infer sequential turns. One sentence fixes it. The evidence is mechanistic (visible in the prompt text) plus one observed judge failure, which is enough to fix without an experiment. The experiment should cover the bigger rewrite, not these two. Even so, I'd still ship these two fixes as the flag's minimum content.

3. **What to measure.** I'd use objective, mostly non-LLM metrics:
   - Self-rebuttal rate: a regex or attribution check on the transcript.
   - False "you ignored X" accusations: check against round-1 text, which is deterministic.
   - Narration leaks: regex.
   - Spec-reading rate: tool-call logs.
   - Position change between rounds, and the share of those changes that cite a specific new argument.
   - Verdict quality: blind human rating of a small sample, with the variant hidden. Do not use debaters as judges. If an LLM judge is needed, use a model family not in the panel, and only for pairwise comparison with randomized order. Treat it as a tiebreaker, not ground truth.

   At 3 questions, expect directional signal only. The rate metrics are the real evidence.

4. **First three steps.**
   1. Strip narration. It is cheap and regex-checkable, and a single provider causes 16 of 17 leaks.
   2. Attribution fix plus the simultaneity sentence, plus an automated attribution check in the transcript linter.
   3. The small 3×3 experiment on the full rewrite, behind the flag, scored by the metrics above.

   **Postpone:** the full 900-call run, the specialist roster and `--panel/--specialist`, and the roster health report. Reviewer revision rates are confounded, so building on them is premature. Early-convergence skipping fired once in 20 debates, so leave it alone.

5. **Risks.**
   - **Comparability.** Existing transcripts used the old prompts. Record a `prompt_version` in each transcript's metadata and don't mix versions in any stats.
   - **Regressions.** The "don't narrate" instruction could suppress legitimate tool use. Verify that the spec-reading rate doesn't drop.
   - **Over-engineering.** Under your products-over-plumbing rule, this is internal tooling. Cap it at about one day and under $5. If the small experiment shows no clear gain beyond the two fixes, ship those two and stop. Don't build specialists.

**Next action:** add `prompt_version` to the debate metadata, implement the own-answer relabel and the simultaneity sentence behind `--prompts v2`, and strip narration. Then run the 3×3 using the metered wrapper.

## Round 1 -- codex

1. **VERDICT: (b)** Fix the structural flaws behind a flag and run the small A/B/C experiment before making the rewrite default. The bugs are proven, but the proposed rewrite also adds steelmanning, grounding labels, new convergence semantics, and structured synthesis—changes whose net quality impact is unknown. The ~60-call stage is proportionate; ~900 calls are not yet justified.

2. **They are bugs, not defensible design.** A speaker cannot productively treat its own answer as another participant’s, and simultaneous rounds require explicit timeline semantics. Observed self-rebuttal and a judge being fooled establish real failures. No experiment is needed to justify correcting those mechanics; the experiment tests whether the broader rewrite improves decisions without introducing regressions.

3. Measure:

- Blind human preference: “Which result would you rather act on, and why?”
- Accuracy against supplied fact sheets and planted traps.
- False attribution and complete preservation of each participant’s final position.
- False convergence, not merely early-stop frequency.
- Grounding quality, narration leakage, cost, and latency.
- Run-to-run variance.

Use deterministic checks for quotes, attribution, formatting, and known facts. Use one or preferably two blinded humans for actionability and substantive disagreement. Do not make a participating model—or the synthesizer—the primary evaluator. Model judging may be recorded only as a secondary, separately identified measure. Include a single-model control later if the pilot warrants expansion.

4. The first three steps should be:

   1. Add the synthesis attribution checker.
   2. Strip genuine process narration while preserving useful grounding disclosures.
   3. Implement versioned R1–R3 prompts behind a flag and run the small A/B/C trial.

Postpone specialists and `--panel` until ordinary debate is reliable. Build the roster health report afterward as operational telemetry, not as evidence of provider quality. Drop the full experiment unless the pilot shows a meaningful signal; drop automated recruiter decisions until substantial blinded outcome data exists.

5. Preserve old transcripts as historical artifacts and record prompt version, provider, model, and flag state in every new transcript. Keeping baseline variant A provides comparability. Main regression risks are lost nuance from rigid output schemas, narration stripping deleting evidence, longer answers, parser breakage, and false early convergence. Test those explicitly. Avoid turning debate infrastructure into the product: ship only changes that improve trustworthy user-facing answers, then return effort to user-facing features.

**Recommended next action:** implement the attribution checker plus flagged prompt variants, then run the three-question randomized A/B/C pilot.

## Round 1 -- grok-build

I'll read the prompt review and the debate prompt code so the verdict is grounded in the actual findings.I'll confirm the round-2 prompt construction in `bin/e3d-debate` so the verdict matches the actual code.**1. VERDICT: (a).** Ship the two protocol fixes as the default. Do not gate them on an experiment. The full R1–R3 rewrite, specialists, and ~900-call harness are a different decision.

**2. Bugs, and the evidence is enough.** Round 2’s contract is “see the others.” `bin/e3d-debate:165-167` loops every provider, including the speaker, and labels each block with the provider name. That is a construction error, not a design. Simultaneous writes are how the loop works (`&` then `wait`); the prompt never says so, so models treat same-round text as already published. T20 shows the predicted failures: Claude rebutting “Claude (c)”; the pirate synthesizer treating a crossed accusation as fact. Those are mechanism demonstrations, not a quality A/B. You do not A/B “stop mislabelling the speaker’s own text.” Early-convergence 1/20 is a separate, weaker claim and does not justify waiting.

**3. If you measure anything, measure after the two fixes, with scripts first.** Primary: (i) self-rebuttal rate — round-2 text attacking the speaker’s own prior as if it were another party; (ii) same-round “they ignored X” accusations; (iii) synthesizer attributions whose quoted strings are absent from that analyst’s section. Those are deterministic. A human (the operator, ~30 min, not 2–3 hours) rates a handful of pairs on “which verdict would I act on.” Do not let a debating model, or the default claude synthesizer, be the sole judge of the debate it sat in. Hold out one unused provider as synthesizer, or keep synthesis on today’s prompt and score it with the checker. Skip forecast accuracy, tic rate, and specialist panels until this ships.

**4. First three:** (1) label the speaker’s prior as `YOU` (or omit it) and state simultaneity in round 2+ and in the synthesizer prompt; (2) strip tool-use narration from provider output; (3) stamp `prompt_version` on every transcript and add the verbatim attribution checker. Postpone the steelman/`AGREES_WITH`/computed-convergence rewrite, R3’s new MCP dissent shape, reviewer checklists, and `--panel/--specialist`. Drop the 900-call experiment as a gate. Roster health is a real e3d-corp defect (claude 50/50 not-ready) and belongs on that product’s board, not in this debate change.

**5. Risks.** Longitudinal transcripts become incomparable unless versioned. Changing `POSITION`/`status`/`DISSENT` breaks the published MCP contract; the two-line construction fix does not. A flag-plus-harness-plus-roster is plumbing. The 2026-09-17 decision is products over plumbing; users of `e3d_debate` already get self-rebuttal and a confused judge.

Assumption: rounds stay parallel; we do not serialize them.

**Next action:** land one PR in `bin/e3d-debate` that relabels or omits the speaker’s own prior and adds one simultaneity sentence to round 2+ and synthesis. Default on. No flag.

## Round 1 -- devin

**1. VERDICT: (b).** Fix behind a flag, then run the small experiment. Flaws 1 and 2 are verified bugs with specific transcript evidence—not hypotheses—so doing nothing (d) is indefensible. But the proposed R1 rewrite adds STEELMAN/CHECK/AGREES_WITH structure that is untested and could introduce false-convergence gaming or answer bloat. The 60-call pilot costs ~$3 and settles whether the full rewrite helps before it becomes the default. Option (a) would commit to an untested structural change; (c) wastes two weeks when a cheap pilot exists.

**2. Bugs, not defensible design.** Flaw 1 (self-rebuttal): showing a speaker its own round-1 answer labelled as a peer's is a prompt implementation error, not a philosophical choice. The transcript evidence (`transcript.md:821,827`) is direct and unambiguous. Flaw 2 (crossed accusations): rounds are simultaneous by construction but the prompt never says so; the synthesis then cited a claim as already addressed when it wasn't (`transcript.md:206`). Both are structural errors with documented downstream harm. Evidence is strong enough to fix the labelling immediately; it is *not* yet strong enough to choose among full rewrite variants, which is why the experiment exists.

**3. Experiment metrics and judging.** Measure: (a) self-rebuttal rate—count instances where a speaker's round-N text quotes or disputes its own round-(N-1) text verbatim; (b) false-accusation rate—claims in round N that were addressed by the accused only in round N (auto-detectable by text diff); (c) synthesis attribution accuracy—whether the verdict correctly attributes which round introduced a claim. Do *not* use the debater models as judges of (c); use a held-out model that is not in the debate pool, plus a human spot-check on the 3-question pilot. Structural/mechanical checks (a) and (b) need no judge at all.

**4. Right first three steps.** (1) **Strip narration now**: add "Output only the answer; do not describe your process" to DB-1 and DB-2. One line, zero structural risk, immediately reduces pollution. (2) **Fix the identity label**: in DB-2, show the speaker's own prior answer under a "--- YOU (your own previous answer) ---" header and add one sentence: "Every analyst writes each round simultaneously; do not accuse anyone of ignoring a point they may not yet have published." This is a 3-line code change that directly kills flaws 1 and 2. (3) **Run the 3×3 pilot** with these two fixes as the baseline variant vs. the full R1/R2/R3 rewrite. Roster health report and specialists: postpone until debate quality is validated.

**5. Risks.** Comparability: existing 20 transcripts become a different distribution; document the prompt version in every transcript header now. Regressions: AGREES_WITH-based convergence could stop a debate early when participants list different reasons but accept the same action. Over-engineering: STEELMAN/CHECK steps add ~30% length; if the word cap isn't raised, quality degrades elsewhere.

**Recommended next action:** Edit `bin/e3d-debate` DB-2 to relabel the speaker's own prior answer as "--- YOU ---" and add the simultaneity sentence. Ship behind `--prompts=v2` flag. Estimated: 15 minutes, zero model calls, directly fixes both verified bugs.

## Round 2 -- claude

**Round 2 rebuttal**

Most of us agree. Everyone says flaws 1 and 2 are real bugs. Everyone puts narration stripping and attribution checking near the front. Everyone postpones specialists and the 900-call run. The only real split is (a) versus (b).

**Grok's (a) is right about the two fixes and wrong about what the verdict should cover.** Relabeling the speaker's own answer and adding a simultaneity sentence need no experiment. I said so in round 1, and Grok's argument for it is the strongest in the thread. Two points from Grok change my plan:

- **Ship the two fixes as the default, with no flag.** I had put them behind `--prompts v2`. That keeps a known mislabel as the default for every `e3d_debate` caller, and the only gain is comparability. A `prompt_version` stamp gives that comparability without a flag. I concede this to Grok.
- **Don't change the MCP contract.** Changing `POSITION`, `status` or `DISSENT` would break published consumers. This is a real constraint on the broader rewrite. The pilot should check for it explicitly.

**Why I still pick (b).** The question asks about the rewrite as well as the two fixes. The rewrite adds steelmanning, `AGREES_WITH`, computed convergence and structured synthesis, and nobody has evidence that any of that helps. Codex and Devin are right that those changes could cause false convergence or longer answers. Grok's (a) is silent on whether to ship them. If (a) means "ship only the two fixes," then Grok and I agree on action and differ only in the label. I'll treat my answer as (a) for the fixes and (b) for the rewrite.

**Devin's judge proposal is weaker than the rest.** A "held-out model not in the debate pool" is fine for a spot check. But Devin's metric (b), false accusations found by "text diff", can't be done mechanically. Whether round-N text accuses someone of ignoring something is a semantic judgment. I'd back this with a keyword regex (`ignored`, `failed to address`) and then a human check of the hits. Codex's planted-trap and fact-sheet metric is the best addition to my list, because it gives ground truth that doesn't depend on any judge.

**Codex's attribution checker as step 1 is slightly out of order.** Flaw 1 gets fixed by a 3-line prompt change. Fix the labels first, then build the checker to confirm the fix worked.

**Revised first three steps:**
1. Relabel the speaker's own answer, add the simultaneity sentence to rounds 2+ and to the synthesizer prompt, and stamp `prompt_version`. All of this is default, with no flag.
2. Strip narration, then run a check that spec-reading doesn't drop.
3. Run the 3×3 pilot on the rewrite only, behind a flag, using the objective metrics plus a planted-trap fact sheet. Judge it by blind human rating, which should take about 30 minutes.

Cap the whole effort at about one day and under $5.

POSITION: Ship the relabel, simultaneity sentence and narration strip as the default with a prompt_version stamp, and run the small 3×3 pilot behind a flag only for the broader rewrite.
status: revise

## Round 2 -- codex

My position holds: **(b)**. Claude and Devin correctly separate two questions: the defects are already proven, while the broader prompt rewrite is not. A versioned flag plus a ~$2–4 pilot is proportionate regression protection, not an attempt to determine whether mislabeling is bad.

Grok is right that flaws 1 and 2 are genuine protocol bugs and need no efficacy experiment. But its choice of (a) conflates “evidence is sufficient to fix” with “deploy unconditionally without comparison.” Prompt changes can alter behavior beyond their literal wording, and the cheap pilot preserves a clean baseline. Conversely, the other (b) answers should be clearer that the experiment tests deployment and the broader rewrite—not the validity of either bug.

The pilot should measure deterministic failure rates first: self-rebuttal, temporally impossible “you ignored this” claims, synthesis attribution errors, narration leakage, and verified grounding/tool use. Also record cost, latency, answer length, false convergence, and blind pairwise human preference on actionability and factual correctness. A participating debater or synthesizer must not be the primary evaluator; a held-out model can provide secondary ratings, but a blinded human should adjudicate substantive quality. Three questions provide a smoke test, not statistically persuasive provider rankings.

The right first three steps are:

1. Add transcript `prompt_version` metadata and automated attribution/temporal checks, establishing measurement before changing output.
2. Implement the own-answer label/exclusion, explicit simultaneity sentence, and narrowly targeted narration stripping behind `--prompts=v2`.
3. Run the randomized 3×3 A/B/C pilot, then default to v2 unless it shows a concrete regression.

This ordering is stronger than stripping narration first because filtering can erase useful grounding disclosures; measurement should distinguish process chatter from evidence. Postpone roster-health conclusions, specialists, `--panel`, and the 900-call study. Early convergence also lacks enough incidence to prioritize.

Existing transcripts remain valid only as v1 artifacts. Main regression risks are lost grounding evidence, rigid-format bloat, parser breakage, and changed convergence behavior. Cap this work tightly: if the pilot finds no material benefit beyond the two structural fixes, ship those fixes and return to user-facing product work.

Recommended next action: add prompt-version metadata and the attribution/temporal regression checks, then implement `--prompts=v2`.

POSITION: Choose (b): version the two proven structural fixes behind a flag, run the small blind pilot, and make them default unless a specific regression appears.
status: revise

## Round 2 -- grok-build

I'll check the debate prompt construction so the rebuttal tracks the code, not just the other answers.I have not changed my mind. The verdict stays **(a)**.

`bin/e3d-debate` lines 165–167 still print every provider, including the speaker, under `--- $other (previous round) ---`. Rounds are one parallel batch, and the prompt never says so. T20 shows the predicted failures: self-rebuttal, and a synthesizer treating a same-round accusation as fact. Claude, Codex, and Devin all call these bugs that need no experiment. They then vote **(b)**, which leaves that loop on the default path until a flagged rewrite is promoted.

That bundling is the mistake. The review's ticket 3 mixes the two-line fix with STEELMAN, CHECK, `AGREES_WITH`, and computed convergence. Its own success rule — if variant A ties, keep today's prompts and adopt only the zero-risk fixes — already separates them. A 3×3 whose treatment arm is the full R1–R3 rewrite cannot tell you whether the label fix worked. The three **(b)** votes also disagree on the pilot: Claude puts both fixes inside v2; Devin uses them as the baseline against the full rewrite; Codex leads with a checker. "Run the small experiment" is not one action. Devin's "fix it immediately, behind a flag, zero model calls" withholds the fix from anyone who does not pass the flag.

A replay switch is fine. A gate is not. Ship the relabel (or omission) and one simultaneity sentence in round 2+ and in synthesis as the default. Keep v1 selectable and stamp `prompt_version`. Do not ship `AGREES_WITH` or a new MCP dissent shape in that PR. Do not wait on ~60 calls.

Two concessions. Narration stripping is not step one and must not be a blunt delete: 16 of 17 leaks are also the grounding signal, and "do not narrate" can suppress the spec reads we want. Strip process chatter only after the label fix, and check that tool use remains. The attribution checker is a linter in the same PR, not a substitute for the fix. Postpone the 900-call run, specialists, and the roster health report.

Next action: one default-on PR for the relabel, the simultaneity sentence, and `prompt_version`.

POSITION: Ship the own-answer relabel and the simultaneity sentence as the default now, and do not gate them on a flagged rewrite or a 60-call experiment.
status: revise

## Round 2 -- devin

**Round 2 evaluation:**

Grok makes the strongest argument I hadn't weighted correctly: the two mechanical fixes (relabel own answer, add simultaneity sentence) are *construction errors*, not design variants. You don't A/B "stop mislabeling the speaker's own text." My round-1 answer put these fixes behind `--prompts=v2`, which is wrong—it delays a deterministic correction and gives the flag a false responsibility. Grok is right: ship those two fixes as default, version-stamp the transcript, done.

Where Grok's (a) overstates: it implies the full rewrite (STEELMAN/CHECK/AGREES_WITH, revised convergence semantics, new synthesis structure) should also ship unconditionally. That's not what Grok explicitly says—they call it "a different decision"—but choosing (a) as the verdict label collapses that distinction. The broader rewrite *does* need the 3×3 pilot because it introduces untested structural changes with unknown effects on false-convergence gaming and answer length.

Claude and Codex both chose (b) cleanly, which I now think is right for the broader rewrite but wrong for the two specific fixes. Codex's suggestion to run the attribution checker before narration stripping is debatable but defensible; narration strip is one line and regex-checkable while the attribution checker is code, so I'd still strip narration first.

**Revised position on the four sub-questions:**

1. **(a) for the two mechanical fixes; (b) for the broader rewrite.** The experiment is for STEELMAN/CHECK/AGREES_WITH, not for correct labeling.
2. Both are bugs. Evidence is mechanistic, not statistical. Fix unconditionally.
3. Same as round 1: deterministic rate metrics first; held-out model or human for verdict quality; no debater-as-judge.
4. (1) Strip narration, (2) relabel own answer + simultaneity sentence, (3) 3×3 pilot for the full rewrite. Postpone specialists and roster health.
5. Version-stamp every transcript now; that's the entire comparability solution.

**Next action:** Land a single commit that strips narration from DB-1/DB-2, relabels the speaker's own prior as `--- YOU (your round-1 answer) ---`, and adds the simultaneity sentence. No flag needed for these two lines. Then open the 3×3 pilot branch with the full rewrite behind `--prompts=v2`.

POSITION: Ship the two mechanical fixes (own-answer relabel + simultaneity sentence) immediately as the default; gate the broader R1/R2/R3 structural rewrite behind a flag and run the 3×3 pilot before promoting it.
status: revise


## Synthesis (claude)

FINAL ANSWER: Pick (b), but split the scope. Ship the two mechanical fixes as the default now, with no flag and no experiment. These are the own-answer relabel (shown as "YOU") and one sentence saying rounds are simultaneous, added to round 2+ and to the synthesizer prompt. Stamp `prompt_version` on every transcript so old and new transcripts stay comparable. Put only the broader R1–R3 rewrite (steelman, `AGREES_WITH`, computed convergence, structured synthesis) behind a flag, and run the ~60-call 3×3 pilot on it before promoting it. Judge the pilot mainly with deterministic checks: self-rebuttal, temporally impossible "you ignored X" claims, synthesis quotes absent from the attributed section, narration leaks, and whether spec-reading is preserved. Add planted-trap fact sheets and a blinded human rating, and never use a debater or the synthesizer as the primary judge. First three steps: (1) relabel, simultaneity sentence and `prompt_version` as default; (2) strip process narration narrowly, checking that spec-reading doesn't drop, plus an attribution linter; (3) the flagged 3×3 pilot. Postpone the 900-call run, specialists/`--panel` and the roster health report, and cap the whole effort at about one day and under $5. Next action: land one PR in `bin/e3d-debate` with the relabel, the simultaneity sentence and `prompt_version`.
CONSENSUS: majority
DISSENT: Grok-build holds (a) and wants no flag at all. Codex still wants the two fixes behind `--prompts=v2` until the pilot shows no regression, and wants the measurement and attribution checks built before the prompt changes.
