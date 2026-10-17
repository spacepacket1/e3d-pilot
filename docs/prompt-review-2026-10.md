# Prompt review, specialist catalogue, and selection design (October 2026)

**Status:** proposal. Documents only: no code, tests, or config were changed, and **no model was called** to produce this (no debates, no provider calls, no credits). Everything below is derived from files already on this machine as of 2026-10-17.

**Why this exists.** The working thesis is that *the prompt is everything*: a small change to a prompt, or a different prompt to the same model, changes the result, and what "better" means depends on what the user is trying to do. e3d-pilot, e3d-debate, the MCP server and e3d-corp all depend on prompts we wrote quickly. This document (1) inventories them and reviews them against real transcripts, (2) proposes concrete rewrites and a cheap way to test them, (3) designs a catalogue of specialists with different lenses, and (4) answers "who chooses?", including a recruiter agent for e3d-corp.

**Evidence tags.** **[E]** = read or measured in a file (reference given). **[G]** = guess or hypothesis, not tested.

---

## 0. Evidence base and how far to trust it

| Source | What it is | Size |
| --- | --- | --- |
| **T20** | Debate transcripts in `~/e3d-pilot/docs/debates/*/`, `~/e3d-brain/docs/debates/*/`, `~/e3d-creative/docs/debates/*/` | 20 transcripts (14 + 4 + 2) |
| **R118** | Pipeline run directories under `~/e3d*/.e3d-pilot/runs/` | 118 dirs; 359 negotiate reviewer responses; 52 draft responses; ~95 review verdict files |
| **C** | e3d-corp `futco` instance event log (`.e3d-corp/instance/futco/events.jsonl`) | 3,920 events, **counted by event type and error class only; no business content was read** |
| **X** | Cold-open experiment, `~/e3d-pod2vid/experiments/coldopen/` (`script-raw.txt` vs `script-final-fixed.txt`, `producer-prompt.md`) | 24 raw lines, 17 edited |
| **H** | `--help` output of the installed `claude`, `codex exec`, `grok`, `devin` CLIs (no model call) | 4 CLIs |
| **Q** | The MacBook QA report the user pasted into the session on 2026-10-16 (not stored in any repo) | 15 findings |

**Limits that matter.** Reviewers in R118 saw *different* specs, over Aug to Oct, while model versions drifted, and later negotiate rounds approve after revisions, so cross-provider rates are suggestive, not controlled **[E]**. T20 is mostly one team's questions and one synthesizer (claude). The e3d-corp event log is dominated by one small local model (see 4.3). Sample sizes for "agent success" are small throughout. Nothing here shows that a rewrite *improves* results; that is what the experiment plan (2.10) is for.

---

## Part 1: Prompt inventory and review

### 1.1 Inventory

e3d-pilot pipeline (`bin/e3d-pilot`):

| ID | file:line | Purpose | Model(s) used | Inputs embedded | Output contract |
| --- | --- | --- | --- | --- | --- |
| PL-1 | `bin/e3d-pilot:644` `build_discover_prompt` | "External Context" + "Analogous Patterns" (+ "Monetization Signals" when `focus=revenue`) | `providers.discover` (list; every provider answers; sections concatenated by `combine_provider_sections`, `:356`) | local facts markdown (git history, branches, PRs, docs, analogy domains) | free markdown; no schema |
| PL-2 | `:804` `build_ideate_prompt` | 3 to 5 ranked candidates with dedup check and scores | `providers.ideate` (list; **merged by code**, `combine_ideate_responses` `:375`, not by a model) | facts, prior runs' candidates/specs, PR list | `### Candidate N` blocks + `---IDEATE-STATUS---` (`selected`, `reason`) |
| PL-3 | `:1101` `build_draft_prompt` | Turn the selected candidate into an `e3d-code`-shaped phased spec | `providers.draft` (single: codex or claude in real configs) | facts + `lib/draft/e3d-code-spec-conventions.md` + protected paths + ceilings | ```` ```spec ```` block + `---DRAFT-STATUS---` (`ok` / `too-large`) |
| PL-4 | `:2309` `build_negotiate_prompt` | Each reviewer approves or revises the same draft | `providers.negotiate` (list; **identical prompt to every reviewer**; converges only if all `approved`, `lib/negotiate/convergence`) | the draft only | `---STATUS---` `approved`/`revise` + full replacement ```` ```spec ```` on revise |
| PL-5 | `:1870` `build_review_prompt` | Review the executed diff | `providers.review` (list; **identical prompt**; tools disabled via `CLAUDE_TOOLS=""` at `:2000` region) | **the diff only** (not the spec or acceptance criteria) | free comments + `---VERDICT---` `approved`/`blocked` |
| PL-6 | `:1378` `build_direct_execute_prompt` | Grok-build execute backend | `providers.execute: grok-build` | the final spec | none (writes files) |
| PL-7 | `:5711` `build_fleet_discover_prompt` | Cross-repo discover | `providers.discover` | portfolio facts | markdown sections |
| PL-8 | `:5854` `build_fleet_ideate_prompt` | Cross-repo ideate (2 to 4 candidates touching 2+ repos) | `providers.ideate` | portfolio facts | as PL-2 |
| PL-9 | `lib/scoring/fanout.sh:217-226` (worker) + `:15-28` (role criteria) | Re-score ideate candidates 0 to 100 | **one** provider (`candidate_scoring.provider`) running 3 to 5 workers that cycle the roles `product, technical, risk, maintainability, testability` (`:7`) | candidates + repo `research_topics` | JSON `{"scores":[{id,score,reason}]}` |
| PL-10 | `lib/ideas/jev_dedup.sh:23` | Duplicate check via TypeSafe/Jev (typed Choice question, not chat) | Jev | candidate + existing ideas | choice + confidence |

e3d-debate and MCP:

| ID | file:line | Purpose | Model(s) | Inputs | Output contract |
| --- | --- | --- | --- | --- | --- |
| DB-1 | `bin/e3d-debate:158-160` | Round 1: independent answer | `--providers` list | question | free answer, "Be decisive, not hedgy. Under N words." |
| DB-2 | `bin/e3d-debate:162-172` | Round 2+: see others' answers, rebut or concede | same | question + every participant's previous answer **labelled by provider name, including the speaker's own** | answer + `POSITION:` + `status: approved\|revise` (where "approved" = a person acting on any participant's answer would act the same) |
| DB-3 | `bin/e3d-debate:222-226` | Synthesis | `--synthesizer` (default claude) | question + full transcript | `FINAL ANSWER` (2 to 4 sentences), `CONSENSUS: full\|majority\|split`, `DISSENT:` (**one line**) |
| DB-4 | `bin/e3d-debate:127` | Jev "is this obvious?" pre-screen (shadow mode only) | Jev | question | obviousness probability, logged |
| MC-1 | `bin/e3d-mcp:256` (tool description), `:384` (server `instructions`) | Prompt for the *calling* assistant: when to use `e3d_debate`, "ALWAYS report the dissent" | the client's model (Copilot etc.) | n/a | n/a |
| MC-2 | `lib/mcp/sampling.js:34-37` | Sampling request framing | client's model | one user message; `modelPreferences.hints`; `includeContext: none`; **no `systemPrompt`** | text |

Inputs and the hidden layer:

| ID | file:line | What it is |
| --- | --- | --- |
| SP-1 | `lib/draft/e3d-code-spec-conventions.md` (embedded into PL-3) | Spec-format rules **plus time-sensitive claims**: an example model string and "gpt-5.5 and gpt-5.4-mini are both confirmed non-working under a ChatGPT-authenticated Codex CLI as of 2026-09" (`:38-42`) **[E]** |
| AD-1 | `lib/providers/claude:42-49` | `--print --permission-mode default --max-budget-usd 0.50`; `--tools` unset = **full tool access** unless the caller sets `CLAUDE_TOOLS` **[E]**. No `--append-system-prompt`, no `--effort`. |
| AD-2 | `lib/providers/codex:39-57` | `--sandbox`, context window, auto-compact; no effort setting **[E]** |
| AD-3 | `lib/providers/grok-build:11,49-57` | optional `--reasoning-effort` from `GROK_BUILD_REASONING_EFFORT`; `--always-approve --sandbox read-only` for headless reads **[E]** |
| AD-4 | `lib/providers/devin:24-27`, `local:41`, `azure-openai`, `anthropic-api`, `openai-api`, `bedrock`, `mcp-sampling` | Prompt delivered as **one user message**; **no system prompt anywhere in e3d-pilot** **[E]** |
| CLI | **H** | Installed CLIs support what the adapters do not use: `claude --append-system-prompt`, `--system-prompt(-file)`, `--effort`; `grok --rules` (append to system prompt), `--system-prompt-override`, `--reasoning-effort`; `codex exec -c key=value` and `--profile` (a reasoning-effort config key is plausible **[G]**, not verified); `devin` exposes only the prompt and a model **[E]** |

e3d-corp roles (`~/e3d-corp/lib/roles/*.js`; each is a *system prompt + JSON user prompt* returning validated JSON):

| ID | file:line | Purpose | Notable contract |
| --- | --- | --- | --- |
| C-1 | `opportunityProspect.js:49` | Turn one event + evidence into one Opportunity | 13 numbered rules; JSON with `counterparty` (`kind`/`name`/`contactHint`); `evidenceEventIds` must come from the supplied list; "honest 'nothing here' is better than a manufactured opportunity"; optional `wantsSecondOpinion` |
| C-2 | `investingOpportunity.js:11` | Evidence-backed investment view | `view`, `confidence`, mandatory `invalidationCondition`; neutral preferred when weak; `wantsSecondOpinion` |
| C-3 | `communicator.js:8` | Draft one outreach email | no invented capability; no greeting/signature placeholders |
| C-4 | `riskAssess.js:47` | HOLD / APPROVE / CHECK recommendation | cannot approve or mutate; CHECK on thin evidence; evidence ids allow-listed |
| C-5 | `creativeBrief.js:44` | Brief for e3d-creative | every claim grounded; ids allow-listed; narrower brief when evidence is thin |
| C-6 | `invoiceReminder.js:17` | Payment reminder draft | facts only; never invent fees or threats |
| C-7 | `prospectResearchBrief.js:20` | Prospect research brief | signal extraction only if supported; list estimated fields |
| C-8 | `prospectOutreachDraft.js:30` | One step of an outreach sequence | may answer exactly `null` if the hypothesis is too vague |
| C-9 | `leadReplyTriage.js:23` | Classify an inbound reply: auto / draft / escalate | conservative tie-break (escalate over draft over auto) |
| C-10 | `xEngagementReply.js:39` | Draft an X reply | char limit; may answer `null`; one finding is the only fact |
| C-11 | `lib/research/jevRelevance.js:66`, `jevDedup.js:68` | Typed Jev questions | choice + confidence |
| C-LLM | `lib/llm/{local,openaiCompatible,anthropic}Client.js`, `grokCliClient.js:87-88` | Transport | **system prompt is a real system role** for local/OpenAI-compatible/Anthropic; the Grok CLI client concatenates system + user into one prompt file **[E]** |

### 1.2 What the prompts assume and force, with evidence

**A. Debate (DB-1 to DB-3, MC)**

*Assumes:* that "approved" in round 2 means "would take the same action"; that "status: revise" is rare when participants agree; that one synthesizer pass can judge a multi-round transcript fairly; that every participant can see the same facts.

*Forces:* a word cap ("Under N words"), a two-line footer in round 2+, and a three-field synthesis with a **one-line** DISSENT.

*Observed failure modes:*

1. **The convergence rule almost never fires [E].** In T20, only **1 of 20** transcripts used the early-convergence fast path (`e3d-creative/.../2026-10-15-brain-claims-spec-review`, `## Synthesis (fast path, no LLM call)`, line 348). The other 19 ran every round. In the 4-model e3d-brain debate all four converged on the same verdict (b), yet all four ended `status: revise` (`e3d-brain/.../federated-intelligence-living-idea/transcript.md:840,862,890,919`) because "approved" requires agreement on caveats and framing too, even though the prompt says caveats "do NOT count as disagreement" **[E]**.
2. **The consensus label is nearly constant [E].** T20: **16 majority, 3 full, 1 split.** *Interpretation [G]:* the label is compressed toward "majority", either by the synthesizer's prior or by the rubric being undefined ("full | majority | split" has no definition in DB-3).
3. **Identity leakage causes self-rebuttal [E].** DB-2 shows each participant its *own* previous answer labelled with its provider name as if it were another participant. In the e3d-brain debate, claude's round 2 rebuts "**Claude (c)**" and "**Claude's 'reserve optional `origin` and `authority` keys'**" (its own round-1 positions) as if a different party said them (`transcript.md:821,827`), and then adopts "Claude's trigger".
4. **Accusations cross in flight [E].** Rounds are written simultaneously, so a rebuttal answers the *previous* round. In the pirate debate, codex's round 2 correctly said Grok "buried" the $60M ETH ETF outflow (Grok's round 1 has **0** mentions; `transcript.md:109`), Grok's round 2 added it (**1** mention), and Grok's round 3 then called the accusation false (`:186`). Neither side had a timeline to appeal to.
5. **The judge inherited the confusion [E].** The synthesis (`:206`) states ChatGPT "claimed Grok buried the roughly $60M ETH ETF outflow, which Grok had already logged": true only after the accusation was written. (Tracked as idea `idea-79378bb3da4c`.)
6. **DISSENT is one line and names no one reliably [E].** The e3d-brain synthesis packs three participants' dissent into one line (`DISSENT: Claude labeled the verdict (c)... Devin still wants... Grok and Codex reject...`).
7. **Agentic providers narrate their process into the answer [E].** 17 line-start narration leaks across T20 ("I'll check the actual graph architecture so this round is grounded...", "The first draft ran long. I'm cutting it...", "I can't find the e3d-brain specs..."): **16 from grok-build, 1 from devin; 2 in round 1, 12 in round 2, 3 in round 3** (12 of 20 transcripts affected). Round 2 dominates because the prompt asks the model to *critically evaluate* claims, and a tool-using model goes to verify them first. The narration is also a *positive* signal (see item 8). (Tracked as `idea-135c127951d5`.)
8. **Grounding is asymmetric [E].** The debate runs with whatever tools each provider has. In the e3d-brain federated debate, grok-build read the real specs and caught that `origin` already means `mcp|hook|import|cli` and that C4 forbids stored relevance scores (`transcript.md:867`+); devin said "I can't find the e3d-brain specs in this repo... answering from the project description" (`:751`); claude and codex answered generically. Two of the four recommendations (add `origin`/`authority` fields) would have collided with the spec **[E]**.
9. **Word caps are soft and model-dependent [E].** Measured against the requested cap: pirate debate (cap 420): grok-build **113 to 120%** in all 3 rounds, codex **74 to 85%**; federated (cap 450): claude **134% / 112%**, devin **124% / 82%**, codex **100% / 75%**, grok-build **94% / 93%**. The synthesizer therefore sees unequal "mass" per voice (*length bias is a plausible consequence* **[G]**).
10. **"Be decisive, not hedgy" plus "approved/revise" may push confident-sounding convergence on the action while hiding disagreement on reasons [G]**; no test isolates it.

**B. Pipeline stage prompts (PL-1 to PL-8)**

*Assumes:* the model will respect long hard-requirement lists (PL-3 has ~15); the draft guard's estimator matches the model's idea of size; reviewers are interchangeable.

*Observed failure modes:*

1. **Same prompt, wildly different reviewers [E].** Across 359 negotiate reviewer responses (identical PL-4 prompt), the share asking for revisions: **grok-build 40 of 61 (66%)**, **codex 26 of 80 (33%)**, **devin 5 of 70 (7%)**, **claude 3 of 77 (4%)**, **local 0 of 71 (0%)**. Round 1 only: grok-build **27/32 (84%)**, codex **18/44 (41%)**, devin **5/39 (13%)**, claude **3/42 (7%)**, local **0/42**. The "every reviewer must approve" rule is therefore effectively decided by whichever providers are strict, and a local model that approves 42 of 42 is not contributing a review **[E; cause is partly confounded, see section 0]**. Real configs list 3 to 5 negotiate providers (e3d-corp: grok-build, claude, codex, devin, local) **[E]**.
2. **The review prompt gives the reviewer less than the draft stage had [E].** PL-5 embeds only the diff, with no spec, acceptance criteria, protected paths or ceilings, so a reviewer cannot check "does this do what was approved". Of review verdict files: **codex blocked 5 of 22 parsed verdicts (23%), grok-build 2 of 20 (10%), claude 0 of 24, devin 0 of 20**; each provider also has **3 files with no parseable verdict**, the same count, which is consistent with the documented failure where a 1.13 MB diff made claude hit its $0.50 budget and codex return nothing and the run still published on the two survivors (comment at `bin/e3d-pilot` ~`:2010-2030`) **[E; "same 3 runs" is a guess]**.
3. **The draft prompt asks for a size the guard disagrees with [E].** PL-3 says "scoped to plausibly fit within N files and M lines", but the guard estimates `bullets x 20 lines/bullet` (`bin/e3d-pilot:1318`). **25 of 52 draft responses (48%)** have a non-empty `draft-scope-warnings.txt`, and 5 of 52 (9.6%) returned `too-large`. The model is never shown the estimator. In the MacBook QA run the draft's own "under about 30 lines" contradicted the guard's "~180 lines vs max 100" (Q item 5).
4. **The draft can satisfy the format but miss the point [E: Q item 3].** The idea was "add a --version flag"; the spec only edited README text because the scratch repo had no CLI. The prompt has an escape for "too large" but none for "the repo lacks the surface this candidate assumes".
5. **A single hard-wired role per stage.** PL-1/2/3/6 have no lens at all; PL-4/5 give every reviewer the same job. Differentiation exists only in PL-9 (see C).
6. **Conditional-clause sprawl.** PL-7's prompt accumulates special cases ("omit that entire section when all configured live instances are healthy" immediately followed by "Do not omit it, though, if any Discord account still has zero engagement", `bin/e3d-pilot:5711-5750`) **[E]**. Prompts that grow by patching contain internal tension **[G]** about which instruction wins.
7. **A time-sensitive fact lives inside a prompt input [E].** SP-1 hard-codes which model strings did or did not work "as of 2026-09". Stale prompt text silently steers drafts.

**C. Candidate scoring (PL-9)**

The best-documented prompt fix in the repo: the "product" role scored internal cost-savings work **18 to 27 versus 91 for a generic dashboard feature** purely because "product evaluator" defaulted to consumer-UX instincts; the fix was one sentence telling it that "product value" means advancing *this repo's* stated research priorities (comment at `lib/scoring/fanout.sh:10-19`) **[E]**. That is direct evidence for the thesis. But all workers run on **one provider**, so the roles are the only diversity **[E]** (config schema: `candidate_scoring.provider` + `workers`).

**D. Adapters as a hidden prompt layer**

No adapter sets a system prompt or a reasoning effort except grok-build's optional effort **[E]**. The "low/medium/high" idea does not exist in the debate path today: `e3d-code` tiers (`mini/default/high`) apply to code-writing phases only **[E: e3d-code README]**, and the claude adapter's `CLAUDE_TOOLS` unset means debate participants run with tools **[E]**, which is the mechanism behind observations A7 and A8.

**E. e3d-corp role prompts**

These are the strongest prompts in the repo **[E]**: a real system role; a JSON contract; allow-listed evidence ids; explicit escape hatches (`null`, "low-confidence 'nothing here'", `escalate`, `CHECK`); conservative tie-breaks; "never invent" rules stated per field. Weaknesses visible in data **[E, C]**:

- C-1 has 13 rules, including a conditional `counterparty` contract. Of ~330 local-model attempts, **8 failed validation with the same error**: "counterparty.name: must be null when counterparty.kind is none" (2.4%). A contract-complexity failure, not a capability failure **[G on cause]**.
- No role has worked examples; none carries a prompt version id into its telemetry (see Part 4).
- The `wantsSecondOpinion` field is **consumed** (`investingOpportunity.js:530`: the first provider that succeeds is the "boss"; if it asks, the second configured provider is consulted under a budget reservation). That is a primitive for agent-initiated panel expansion **[E]**.

### 1.3 The thirteen observations from the brief

| Observation | Verdict | Evidence |
| --- | --- | --- |
| Sequential generation collapses into per-model tics | **Verified, quantified** | X: raw script ORACLE used "Great question" in **8/8** lines, GROK started "Love the" in **7/8**, "Receipts" appeared in **8** lines, "with nuance" in **8**, "just asking" in **6**; after the producer pass: **2/5, 2/5, 2, 1, 1**. 688 words / 24 lines became 344 / 17. *Confound:* the role cards *asked* for those tics, so some repetition is by design **[G]**. |
| Parallel rounds make accusations cross in flight | **Verified** | pirate `transcript.md:109, 186` (above) |
| The synthesizer misattributed a claim | **Verified** | pirate `:206` vs R1/R2 text |
| Agentic providers leak process narration | **Verified, mostly grok-build** | 17 leaks; 16 grok-build, 1 devin; 12 in round 2 |
| Models that could read the repo grounded their answers | **Verified (one clear case)** | e3d-brain federated debate: grok-build vs devin vs claude/codex |
| `status: approved\|revise` can be gamed or fail to trigger | **Verified (fail to trigger)**; "gamed" **not seen** | 1/20 fast path; all four `revise` while agreeing on the verdict |
| Word limits changed quality | **Partly**: caps are soft and model-dependent; effect on *quality* not measured | section A9; cold-open 35-word cap gave punchy lines but did not prevent tic collapse |
| Round-1 independence versus anchoring | **Not verified** | round-1 prompts are independent by construction; anchoring in round 2 is by design. A similarity measure between round-1 and round-2 answers is in the experiment plan |
| Identity/role leakage | **Verified** | claude rebutting "Claude (c)" in e3d-brain `:821, 827`; pirate captains saw provider-labelled text |
| Tone instructions versus factual instructions competing | **Plausible, one sample** | the pirate brief required both "every fact from the log" and peak drama/narcissism; speeches became figure recitals (author's own judgment of the result, **[G]**; no controlled comparison) |
| Models imitating the question's style | **Not verified** | the pirate speeches echoed the brief's vocabulary, but the brief also instructed the dialect; cannot separate |
| (new) Reviewer strictness varies by model on an identical prompt | **Verified** | 84% / 41% / 13% / 7% / 0% round-1 revise rates |
| (new) The draft prompt and the guard disagree about size | **Verified** | 48% of drafts warned |

---

## Part 2: Proposed improvements

Each rewrite names the failure mode it targets. All rewrites are **proposals**; none has been run.

### R1. DB-2, round 2+ (highest value)

**Targets:** self-rebuttal (A3), crossed accusations (A4), narration (A7), non-triggering convergence (A1).

```text
You are {NAME}, one of {N} analysts debating one question. The others are: {OTHER_NAMES}.

THE QUESTION
{QUESTION}

WHAT WAS WRITTEN LAST ROUND
--- {OTHER_1} ---
{text}
--- {OTHER_2} ---
{text}
--- YOU (your own previous answer; you may revise it, you are not debating it) ---
{text}

Every analyst writes each round at the same time. Nobody has seen anyone's text for the current
round, so respond only to the text above and never accuse someone of something they may have
fixed since.

DO THIS, IN ORDER:
1. STEELMAN: in two sentences, state the strongest version of the position you disagree with most,
   in words its holder would accept.
2. CHECK: pick the one claim from the others that would hurt your position most if true. Say whether
   it is TRUE, FALSE, or UNVERIFIABLE from what you can see, and quote at most 15 words of it exactly.
3. HOLD OR REVISE: say what you now believe and which sentence (if any) changed your mind.
4. WHAT WOULD CHANGE MY MIND: one concrete, checkable fact or result.
Under {WORDS} words. Output only the answer: do not describe your process or what you are about to read.

End with exactly these three lines:
ACTION: <one imperative sentence a person could carry out>
AGREES_WITH: <names whose ACTION you would also accept, or "none">
CONFIDENCE: <low|medium|high>
```

*Convergence becomes computed, not self-declared:* stop early when, for every participant, `AGREES_WITH` lists all the others. Participants may still list differences in reasons without blocking convergence. *Why it should help:* removes the vague "approved" semantics (A1), makes the speaker's own text unmistakable (A3), states the simultaneity rule (A4). *Risk:* steelman/check steps lengthen answers (compensate with the cap) and `AGREES_WITH` could be gamed to stop early **[G]**; the experiment measures false convergence.

### R2. DB-1, round 1

**Targets:** grounding asymmetry (A8), narration (A7), unstated assumptions.

```text
You are {NAME}, one of {N} analysts who will each answer independently before seeing the others.

THE QUESTION
{QUESTION}

GROUNDING
- Facts stated in the question are authoritative. Do not contradict them.
- If you can read files or run commands, use that only to check a claim you intend to rely on.
  Mark every claim that depends on the repository as [read: path] or [from memory]. If you cannot read
  the repository, say so in one line and mark repo-specific claims [unverified].
- Do not describe your process. Your reply is only the answer.

ANSWER IN THIS SHAPE (under {WORDS} words):
VERDICT: <one or two sentences>
KEY REASONS: <2 to 4 bullets>
ASSUMPTIONS THAT CARRY THE ANSWER: <1 to 3 bullets>
WHAT WOULD CHANGE MY ANSWER: <one checkable thing>
```

*Why:* makes grounding visible to the other analysts and the judge, so a generic answer is labelled generic. Keeps "decisive" implicit in `VERDICT` rather than the "not hedgy" instruction, which may suppress honest uncertainty **[G]**.

### R3. DB-3, synthesis and attribution

**Targets:** judge errors (A5), one-line DISSENT (A6), constant label (A2).

```text
You are the judge of a debate. Below are the question and the full transcript. Every analyst wrote each
round at the same time, so a rebuttal in round N answers the text of round N-1. Judge accusations by
that timeline.

Produce exactly this:
FINAL ANSWER: <2 to 4 sentences: the action to take and the single biggest reason>
CONSENSUS: <full = every analyst's last ACTION is the same action; majority = most share one action and
  at least one differs; split = two or more distinct actions each with a real backer>
POSITIONS: one line per analyst: <name>: <their final ACTION in your words> | "<verbatim quote, at most 20 words, from their final round>"
DISSENT: one entry per analyst whose action differs from FINAL ANSWER: <name>: <what they would do instead and why> | "<verbatim quote>". Write "none" only if every analyst agrees.
CLAIMS CHECKED: any factual claim where analysts contradicted each other, and what the transcript shows (round and analyst). Say "not resolvable" when it is.
OPEN QUESTIONS: up to 3.
Rules: every quote must be copied verbatim from that analyst's text. If you cannot find a quote, omit the claim. Never attribute a statement to someone who did not write it.
```

*Why:* defines the labels (A2), forces per-analyst dissent (A6), and makes attributions checkable by a deterministic script (every quoted string must appear in that analyst's section; `idea-79378bb3da4c`). The structured-dissent output (MCP) needs the same per-analyst shape (Part 3.5).

### R4. PL-4, negotiate reviewer

**Targets:** reviewer spread (B1), rubber-stamp reviewers, missing constraints.

```text
You are reviewer {i} of {N} in round {r} of the negotiate loop. Review as: {LENS_NAME}: {LENS_ONE_PARAGRAPH}.

The draft below must satisfy:
- It must not touch these protected paths: {PROTECTED_PATHS}
- It must fit within {MAX_DIFF_FILES} files and {MAX_DIFF_LINES} changed lines in total (count each
  Requirement/Acceptance bullet as about 20 changed lines)
- Every phase has a runner:model annotation, at least one pilot:touches glob, and acceptance criteria a
  script or a diff could check

Answer each item PASS or FAIL with one clause:
1. Does the spec deliver the candidate's stated purpose, not merely edit documentation?
2. Can each phase be verified on its own, in order?
3. Are the acceptance criteria checkable by a command or file diff?
4. Is the scope realistic against the ceilings above?
5. Does it touch anything protected or out of scope?
Approve only if all five pass. If you revise, change only what failed and name the item numbers in `reason`.

[unchanged: the ---STATUS--- block and the full-replacement ```spec rule]
```

*Why:* the same prompt produced 84%/41%/13%/7%/0% revise rates; a checklist anchors "revise" to named failures, makes strictness comparable across models, and a rubber-stamp reviewer must at least answer five concrete questions. Combine with lenses (Part 3) so reviewers differ on purpose.

### R5. PL-5, review

**Targets:** reviewing without the spec (B2).

```text
You are the {LENS_NAME} reviewer in the review stage. You are given (1) the approved spec, including each
phase's acceptance criteria, and (2) the executed diff.

Report:
SPEC COMPLIANCE: for each phase, MET / PARTLY / NOT MET against its acceptance criteria, citing file:line from the diff.
DEFECTS: real defects only (regression, correctness bug, security issue), each with file:line and how it fails.
NOT REVIEWED: anything you could not assess (truncated diff, binary or generated files).

Then end with the verdict block, verbatim:
---VERDICT---
status: approved | blocked
reason: <one line>
Use "blocked" only for a DEFECT, or for a NOT MET item that breaks the spec's stated purpose.
```

*Why:* a reviewer that never sees the acceptance criteria cannot catch "right format, wrong thing" (B4). `NOT REVIEWED` makes the silent-truncation failure visible.

### R6. PL-3, draft (sizing worksheet and mismatch exit)

**Targets:** size contradiction (B3), format-correct-but-missing-the-point (B4).

Insert before the spec:

```text
SIZING (you will be checked against this): list every Requirement and Acceptance bullet you plan to write
and estimate changed lines at about 20 lines per bullet (the guard uses bullets x 20). Print
TOTAL_BULLETS, ESTIMATED_LINES. If ESTIMATED_LINES exceeds {MAX_DIFF_LINES}, cut scope or answer
status: too-large.

FIT CHECK: the spec must change something a user of the candidate would notice. If the repository lacks
the surface the candidate assumes (for example there is no CLI to add a flag to), do NOT write a spec for
a different surface. Answer status: mismatch and name the missing surface in `reason`.
```

*Why:* shows the model the estimator it will be judged by (B3) and adds the missing exit (B4). Needs a parser change to accept `mismatch` (ticket).

### R7. Specialist wrapper (new; used by Part 3)

```text
ROLE
You are {NAME}: {LENS}.
HOW YOU WORK: {METHOD}
YOU DO NOT: {AVOID}
A FAILURE MODE TO WATCH FOR IN YOURSELF: {FAILURE_MODE}
THE OTHER VOICES ON THIS PANEL: {OTHER_NAMES_AND_ONE_LINE_LENSES}
Stay in your lens even when your view is a minority. The task and output format follow.
```

*Delivery channel [E, H]:* `claude --append-system-prompt`, `grok --rules` or `--system-prompt-override`, the `system` field of the Anthropic/OpenAI-compatible API adapters, MCP sampling's `systemPrompt` field (**[G]** whether each client honours it); `codex` and `devin` get it as a prefix in the user message. Today none of these channels is used (D).

### R8. Script / banter mode (new; from the cold-open experiment)

Three changes, each tied to evidence **X**:

1. **Beat sheet first** (one call, editor model): `Write a nine-beat outline for a two-minute sketch: for each beat, who speaks, what changes, and which running gag appears (each gag at most twice, and its second use must twist it).` *(Not yet tested **[G]**; the producer pass below is tested.)*
2. **Line turns carry the beat and a "used phrases" list**: `This is beat {k}: {beat}. You may NOT reuse any opener or phrase in this list: {top repeated 3-grams so far}. If your character's tic is due, mutate it.` Guard: reject and retry a line whose first three words match a previous line by the same speaker.
3. **Producer pass** (proven: raw tics 8/8, 7/8, 8, 8 became 2/5, 2/5, 2, 1; 688 words became 344): `producer-prompt.md` in the experiment folder is the working text; keep the rules "each tic at most twice and the second time a twist", "countdown numbers must decrease", "at most 17 lines, 300 words".

*Also:* keep the two-sided facts rule out of comedic prompts, or confine it to a separate "facts" beat, because the pirate debate's "every number must come from the log" produced recitation **[G]**.

### 2.9 General techniques: supported versus not yet supported

| Technique | Supported by evidence here? |
| --- | --- |
| Anti-repetition constraint (+ producer pass) | **Yes** (X) |
| Grounding instruction that distinguishes given facts from model knowledge | **Yes, indirectly** (A8: grounded answers caught real collisions) |
| Say which round's text each rebuttal answers (simultaneity) | **Yes** (A4, A5) |
| Label the speaker's own text as "YOU" | **Yes** (A3) |
| Per-analyst dissent with verbatim quotes | **Yes** (A5, A6) |
| Checklists for reviewers | **Plausible** (B1: spread is large; no test that a checklist narrows it) |
| "What would change my mind" / disconfirmation request | **Not tested**; included because the 16-of-20 "majority" base rate suggests dissent is rarely sharpened **[G]** |
| Steelman pass before rebuttal | **Not tested** (motivated by A3/A4) |
| Pre-mortem or devil's-advocate framing | **No evidence in our logs**; offered as *specialists* (Part 3), to be tested not assumed |
| Beat sheet before lines | **Not tested** |

### 2.10 Experiment plan (not run; estimates only)

**Question set (12, fixed):** 4 design decisions replayed from past debates (graph generalization, Jev debate gate, decision-memory, federated-intelligence note), 3 spec-review tasks on real draft specs, 2 *checkable forecasts* (for example a dated numeric range whose truth resolves later), 2 grounded-fact tasks (answer depends on a supplied fact sheet with 3 planted traps), 1 banter sketch.

**Variants:** A baseline (today's prompts); B R1+R2; C B + R3; D C + specialist panel for the same question; E C + reviewer checklists (spec-review tasks only). Run each cell twice to see run-to-run variance.

**Measures:**

- **Checkable-claim accuracy**: count verbatim-quote attributions in the synthesis that are false (deterministic script) and factual claims contradicting the supplied fact sheet (planted traps caught).
- **Dissent preservation**: does each analyst's final ACTION appear in the synthesis attributed to them?
- **Convergence quality**: early-stop rate, and *false convergence* (stopped early but a human rater sees a substantive disagreement).
- **Independence**: pairwise lexical/semantic similarity of round-1 answers; and round-1 to round-2 shift.
- **Tic rate** for the banter task (repeated openers per speaker).
- **Blind human rating** (the user, or two raters): 36 transcript pairs, A vs variant, order randomized, rating "which would you rather act on" plus a one-line why. About 2 to 3 hours of human time (**[G]**).
- **Cost and latency**.

**Number of calls:** 12 questions x 5 variants x 2 repeats = 120 debates. A thorough 3-voice, 2-round debate = 3 x 2 + 1 = 7 calls (spec-review tasks and the panel variant use 4 voices = 9 calls). Roughly **900 model calls** (**[G]** exact count depends on early stops).

**Estimated cost (a guess, not a quote):** at ~3,000 input and ~700 output tokens per call on frontier models, roughly **$0.03 to $0.07 per call**, so **about $27 to $63**, plus ~120 judge/checker calls (~$6). Using subscription CLIs instead of metered API keys changes the bill but not the call count. Recommended order: run 3 questions x A/B/C first (about 60 calls) and stop if nothing moves.

**What would count as success:** a variant wins on blind rating on at least two thirds of pairs *and* does not increase false attributions or false convergence. If A wins or ties, keep the prompts and only adopt the zero-risk fixes (narration stripping, attribution check).

**Honest baseline caveat:** nothing in our data shows that multi-model debate beats a single model on accuracy. This experiment, with a single-model arm added (variant F: one model, same question), would produce the first evidence either way.

---

## Part 3: Specialists

### 3.1 Dimensions

| Dimension | Values | Today |
| --- | --- | --- |
| **Goal / task** | decide, review-spec, review-diff, find-gaps, forecast, ideate, write (script/copy), judge | implicit in which script is run |
| **Lens / personality** | the specialist's job and bias (below) | none (PL-9 has 5 scoring lenses on one model) **[E]** |
| **Model family** | provider adapter name (claude, codex, grok-build, devin, gemini, local, API adapters, mcp-sampling) | chosen per stage in config **[E]** |
| **Reasoning effort** | low / medium / high where the CLI supports it | only grok-build, optional **[E]**; `claude --effort` exists **[H]** but is unused; codex possibly via `-c` **[G]** |
| **Tool access** | none / read-only / read+run | claude: unset = full; reviewers: none; grok-build: read-only sandbox **[E]** |

### 3.2 Starter roster (12)

Families are recommended **only where an observed behavior supports it** (E) and marked **[G]** otherwise. The drafts are R7-style lens preambles; `{TASK}` is supplied by the task contract.

| # | id | Lens (one line) | Draft prompt snippet | Best for | Characteristic failure mode | Model family |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `skeptic` | Assume it fails; find the cheapest way to prove it | "Your job is to find the strongest reason this should NOT be done. Name the specific failure, who is hurt, and the evidence that would show you are wrong. You may not praise." | risk review, spec review | contrarian for its own sake; cries wolf | **grok-build** (E: strictest reviewer, 84% round-1 revise rate; **[G]** it is a style, not necessarily accuracy) |
| 2 | `premortem` | It is a year later and this failed; write the obituary | "Assume this shipped and failed. List the three most likely causes in order, each with an early warning sign you could watch for." | pre-commit decisions | invents implausible disasters; anchors on vivid failures | any **[G]** |
| 3 | `customer` | The end user's view; ignores implementation | "You are the person who would use or pay for this. What do you actually do today, what would make you switch, and what would make you stop?" | product, GTM, messaging | projects own preferences; flatters | claude or sampling **[G]** |
| 4 | `compliance` | Regulator / security / privacy reviewer | "Review as a compliance and security officer. Identify any data that leaves a boundary, any claim that is unsupported, any rule that applies. Cite the rule." | specs touching data, money, public claims | over-restricts; cites rules that do not apply | claude **[G]** (careful, conservative tone observed in C-9/C-4 style, not measured) |
| 5 | `implementer` | The engineer who must build it | "You will implement this tomorrow. Which phase is underspecified, what will you have to guess, and what would you cut?" | draft, spec review | optimistic estimates | **codex** (E: the draft provider in 3 of 4 real configs; **[G]** quality unknown) |
| 6 | `architect` | Systems and long-term maintenance | "Review the design for coupling, failure modes, migration and maintenance cost. Prefer the boring option unless you can say why not." | architecture, negotiate | gold-plating; resists any change | claude **[G]** |
| 7 | `futurist` | Forecasts with dates and probabilities | "State each forecast as: what, by when, a probability, and what you would see first if you were right. No forecast without a way to check it." | forecast panels, scored predictions | confident round numbers; narrative over base rates | any **[G]**; best used with a **resolution log** |
| 8 | `editor` | Cuts, structure, repetition | "Cut by half. Remove anything repeated. Keep the strongest line of each idea. Do not add material." | script producer pass, summaries | flattens voice | **claude** (E: ran the cold-open producer pass; tics 8/8 became 2/5) |
| 9 | `writer` | Voice-driven drafting, comedy and copy | "Write in the voice of {CHARACTER}. Lead with the surprising specific. Never explain a joke." | banter, scripts | repeats own tics (E: 8/8) | codex, grok-build, claude all used in X; **no model separation supported** |
| 10 | `factchecker` | Verifies claims against sources or the repo | "For each factual claim in the others' text, say TRUE / FALSE / UNVERIFIABLE with the source you used. Quote exactly." | any debate with facts; pre-publication | stalls on unverifiable claims | **grok-build with read access** (E: grounded itself against the real specs; caveat: it also leaks narration, 16/17) |
| 11 | `judge` | Synthesizer: assigns dissent, checks attribution | R3 above | every debate | misattributes under timeline confusion (E, one case) | claude (E: current default; one verified error in the pirate run) |
| 12 | `facilitator` | Keeps the panel on the question, surfaces missing perspectives | "Before anyone answers: list the 3 questions a careful person would ask first. After round 1: name the perspective nobody covered." | open-ended decisions, gap-finding | adds process without content | claude **[G]** |

*Not claimed:* that any family is "best" at a role beyond what the **E** rows state. The strongest behavior evidence we have is reviewer strictness (B1), the narration/grounding pattern (A7, A8), and tic collapse (X). Role-to-model assignments marked **[G]** should be revisited with experiment data, not trusted.

### 3.3 File format

Specialists as data, one file each (YAML shown; JSON also fine):

```yaml
id: skeptic
version: 3                      # bump on any prompt change; copied into every run record (see Part 4: prompt version)
name: The Skeptic
lens: Assume it fails; find the cheapest way to prove it.
tags: [risk, review, decision]
tasks: [decide, review-spec, find-gaps]     # which task contracts it supports
prompt:                          # delivered as the system prompt where the provider supports one
  role: |
    You are {name}: {lens}
  method: |
    Find the strongest reason this should not be done. Name the failure, who is hurt, and the
    evidence that would show you are wrong.
  avoid: |
    Do not praise. Do not hedge. Do not argue against a position nobody took.
  failure_mode: Contrarian for its own sake; drop a point if you cannot name the evidence for it.
models:                          # ordered preference; first available wins
  - provider: grok-build
    effort: high                 # passed as the adapter's effort flag where supported, else ignored with a note
  - provider: claude
tools: none                      # none | read | read+run   (maps to CLAUDE_TOOLS / sandbox flags)
limits: { max_words: 300 }
performance:                     # filled by measurement, never hand-edited
  samples: 0
  revise_rate: null
  accepted_findings_rate: null
  last_evaluated: null
```

### 3.4 How e3d-debate loads and uses it

- **Location and precedence:** `lib/specialists/*.yaml` (built in) < `~/.config/e3d-pilot/specialists/*.yaml` (user) < `<repo>/.e3d-pilot/specialists/*.yaml` (repo). Later wins by `id`.
- **CLI:** `e3d-debate "question" --panel risk-review` (preset) or `--specialist skeptic --specialist customer:claude` (explicit, with an optional provider override). Existing `--providers a,b` keeps working and means "unlabelled specialists".
- **Presets** (`panels.yaml`): `risk-review` = skeptic + premortem + compliance + judge; `spec-review` = implementer + architect + skeptic + judge; `creative-writers-room` = writer x2 + editor (producer pass) in script mode (R8); `forecast` = futurist x3 on different model families + factchecker + judge; `gap-finding` = facilitator + customer + architect.
- **Composition with providers:** a specialist resolves to (provider adapter, effort, tools, system prompt). Existing adapters stay the transport; we only add the missing flags (D). A specialist whose first provider is unavailable falls back down its `models` list, and the transcript records which provider actually ran.
- **MCP:** `e3d_debate` gains `panel` (preset id) and `specialists` (list); a new free tool `e3d_list_specialists` shows ids, lenses, and `performance`. The assistant can pick a panel; the *user* can still override.

### 3.5 What structured dissent needs

Today `dissent` is `{present, summary}` and `positions` is per *provider* **[E]**. To attribute dissent to a *specialist*, each participant record needs: `specialist_id`, `specialist_version`, `provider`, `model` (as reported), and its final `ACTION`. The `dissent` object becomes a list of `{ specialist_id, provider, action, reason, quote }`, so "the compliance reviewer would not ship this" survives summarisation. The R3 synthesis prompt already emits that shape; the MCP result and the e3d-pilot ledger note both need the same fields, and the family/independence check should treat *specialists* on the same model as one family (existing `independence()` already groups by vendor family).

---

## Part 4: Who chooses, and the recruiter

### 4.1 Options for choosing a panel

| Option | Good | Bad | Needs |
| --- | --- | --- | --- |
| User picks explicitly | transparent, zero new risk | users do not know the roster; most will never pick | roster listing and docs |
| **Preset by task type** | simple, explainable, cheap | one size per task; presets rot | a small set of tested presets |
| Router agent (a model recommends the panel) | adapts to the question | one more model call and one more thing that can be wrong; opaque unless it explains | logging so it can be evaluated |
| Performance-based selection | self-improving in principle | needs ground truth we mostly do not have (see 4.3); easy to chase noise | outcomes per specialist |
| Bandit / exploration | learns without a lab | unsafe for high-stakes tasks; needs volume | volume and a reward signal |

### 4.2 Recommendation (phased)

1. **Now:** explicit `--panel` / `--specialist` plus 4 to 5 presets, shown in `--help` and in the MCP tool description. The user (or the calling assistant) chooses.
2. **Next:** an *advisory* router: given the question and goal, it proposes a panel and a one-line reason; the user confirms in one step; every suggestion and the user's final choice are logged (this builds the data to judge routing later).
3. **Later:** performance-informed defaults, only where a checkable outcome exists (forecasts that resolve, specs that were merged/reverted, reviews later contradicted).
4. **Last, and only for low-stakes work** (ideation, banter): bandit-style exploration among pre-vetted specialists.

*Why this order:* it replaces nothing that works, keeps a human decision at each step, and does not depend on outcome data we do not yet have.

### 4.3 e3d-corp today (what a recruiter would stand on)

**Where roles live [E]:** `lib/roles/*.js` (10 roles, Part 1). Role-to-provider binding is config: `roles.<name>.provider` is a string or a list (`.e3d-corp/config`, example at `examples/*.json:58`); provider kinds are `local`, `openai-compatible`, `grok-cli`, `anthropic` (`lib/llm/registry.js`). Per-provider spend is reserved and settled through events (`lib/llm/budget.js`). The first provider that succeeds is the "boss"; it may request a second opinion from the second provider (`investingOpportunity.js:530`).

**How success is recorded [E]:** telemetry events `role.provider.completed|failed` carry `role, provider, model, latencyMs, costUsd, usage, reason`; the **Experience** record joins an event chain to its **Outcome** (`lib/experience/assemble.js`); `computeMetrics` (`lib/evaluation/metrics.js:174`) reports acceptance, rejection, outreach funnel, revenue attributable, cost per useful opportunity, and **latency and cost by `role:provider:model`** (`:148`). Outcome types: 12 (`prospect.replied`, `meeting.booked`, `proposal.accepted`, `deal.won`, `invoice.paid`, `opportunity.no-value`, and more; `lib/outcomes/schema.js`).

**What the real data says [E, C], `futco` instance, 2026-08-23 to 2026-10-12:**

- 3,920 events; **287** opportunities created and scored, almost all by `opportunity.prospect` on one local model (`mlx-community/Qwen2.5-7B-Instruct-4bit`).
- **99** `role.provider.failed`: **50** `claude` ("Provider claude is not ready: LLM API key env var ANTHROPIC_API_KEY is not set"), **17** local HTTP 503, **22** local timeouts (60 s and 300 s), **8** schema-invalid, **2** local base URL unset. `claude` has **0 completions** as a prospect provider.
- Human judgment is sparse: **8** `opportunity.reviewed` (**6 no-value, 2 pursuing**); **9** proposals created, **5** approved.
- `Experience.model` is `null` when no model was recorded (`assemble.js:28-46`: "no event records a model at that stage, so model stays null rather than guessed"); an Opportunity has no `proposedBy` (`docs/build-multi-provider-roles.md`).

**So:** per-agent *quality* cannot be judged from 8 human reviews; per-agent *reliability* can be judged today, and it already exposes a real defect (a configured provider that has never once worked).

### 4.4 The recruiter agent

**Concept.** A recruiter is an e3d-corp **role** (a reasoning component that returns validated JSON) that watches roster telemetry and *proposes* roster changes. It never executes them. It fits e3d-corp's own rule: "roles return structured JSON; deterministic code applies policy and owns every state transition".

**What "hire" and "fire" concretely mean (four proposal types):**

| Proposal type | Meaning | Reversible? |
| --- | --- | --- |
| `specialist.add` | add a specialist (or provider) to a role's list, initially in *shadow/second-opinion* position only | yes |
| `specialist.retire` | remove it from a role's list or demote it to shadow ("fire" is a demotion with a record, never a deletion) | yes |
| `specialist.revise` | change its prompt (new `version`) or model binding | yes, versions are kept |
| `specialist.rebudget` | change its provider budget | yes, but financial-adjacent |

**Authority and Decision flow (using the existing machinery).**

- Add four action types to `ACTION_POLICY` (`lib/authority/policy.js`, which is code, versioned, and the single source of truth): `specialist.add/retire/revise` at **level 2** (external/reversible: approval and execution are one call), `specialist.rebudget` at **level 3** (it commits spend; approve, then `confirmAndExecute`). None are level 0/1: changing who produces the company's decisions is not an internal note.
- **An agent cannot change its own authority.** The recruiter's own role binding, the policy table, and the budget policy that constrains it are *outside* the set of things a roster proposal may touch; `assertProposalAuthorized` already fails closed on an unknown type, so a proposal naming those targets is refused in code, not by prompt.
- **A recruiter never decides.** A human Decision is required (same as `pilot-handoff`), except inside an active **roster mandate**, modelled on `ad_mandate` and `autoDecideUnderMandate` (`lib/decisions/autoDecideUnderMandate.js:21`): a human activates a mandate listing the roles and specialists it may touch, a maximum number of changes per week, probation lengths and budget caps; a proposal that fits is auto-decided; anything outside the mandate waits for a person, and "covered" is checked fail-closed exactly as `evaluateMandateCoverage` does.

**Guardrails.**

- **Minimum samples before any quality action:** at least 30 attempts and at least 10 human-judged or outcome-bearing results for the role; *reliability* actions (a provider unready or failing) may act on 10 attempts because they do not judge quality.
- **Probation:** a new or revised specialist runs as a second opinion (shadow) for N tasks and is promoted only if a *blind* comparison against the incumbent holds up; the incumbent's prompt and model stay on file.
- **Rollback:** every change is a new `version`; automatic revert if, during probation, failure rate or rejection rate exceeds a stated threshold.
- **Budgets:** the recruiter's own model calls draw from the same `budget.js` reservations and have a hard cap.
- **Never edits** the authority table, the budget policy, its own role, or Outcomes (it may read Experience; it cannot write Outcomes).

**Cold start.** Seed the roster from the Part 3 catalogue with a single default specialist per role; run the recruiter in **report-only mode** for the first several weeks; use the existing negotiate/review spread (B1) as the first priors.

**Goodhart risks.** If success = approval rate, agents learn to be safe and boring: mitigate with a *basket* (acceptance, downstream outcomes such as `meeting.booked` or `proposal.accepted`, novelty/diversity of opportunities, cost), a human-reviewed random audit sample taken *before* the recruiter sees the data, and a penalty for "approved but later no-value". Agents that can read their own score can game it, so the score lives in the recruiter's input only, not in any role's prompt.

**Over-firing.** With tiny samples, noise dominates: use shrinkage or confidence intervals, require two consecutive evaluation windows, a cooldown between changes, and never retire the last working specialist for a role.

**Data missing today [E]:** (1) a **prompt/version id** in `role.provider.completed` so outcomes can be attributed to a prompt version, not only a model; (2) the **model** and **`proposedBy`** on Opportunities and in Experience; (3) structured *reasons* for `no-value` (today a single label); (4) outcome **volume** (8 reviews in 7 weeks); (5) multi-provider attribution when a second opinion is used; (6) a small **golden set** per role (inputs with known-good answers) so quality can be measured without waiting for the market.

### 4.5 Smallest valuable first step

**A read-only "roster health report" (authority level 0), built from events that already exist.** For every `role:provider:model`: attempts, completions, failures **by class** (not ready/config, 5xx, timeout, schema-invalid), average latency and cost, and human review counts. It flags *broken* (for example `claude` on `opportunity.prospect`: 50 failures, 0 completions, cause "ANTHROPIC_API_KEY not set") and *flaky* (local: 22 timeouts, 17 HTTP 503). It makes **no** quality judgment and proposes **no** hire or fire. In the same change, add the two missing fields (`promptVersion` hash, `model`) to the telemetry so the *next* step has data. This finds a real defect today, uses no new authority, and starts the data the recruiter will need.

---

## Product angle (honest)

- **Improves a product people use:** R1 to R3 (debate quality), narration stripping, attribution checking, the panel/specialist feature in `e3d_debate`, and `e3d_list_specialists`. These change what a Copilot user gets from the published MCP server.
- **Potential content product:** script/banter mode (R8). It feeds the video work; whether it has an audience is untested.
- **Internal plumbing:** the recruiter, roster health report, telemetry fields, and the evaluation harness. They matter for how well e3d-corp runs, not for what a user installs. The harness is also the only way to generate *evidence* that debate improves results, which matters for how we describe the product to others.
- **Unproven claim to avoid repeating:** that multi-model debate is more accurate than a single model. We have no measurement either way (see the single-model arm in 2.10).

---

## Top findings

1. **Reviewer personalities already differ enormously on an identical prompt: round-1 revise rates of 84% (grok-build), 41% (codex), 13% (devin), 7% (claude), 0% (local, 0 of 42).** The specialists idea is describing something that already exists, but accidentally and uncontrolled. **[E]**
2. **The debate prompts leak structure: they show a speaker its own answer as someone else's (self-rebuttal), run rounds simultaneously without saying so (crossed accusations, which then fooled the judge), and define convergence in a way that fired in 1 of 20 debates.** The fixes are prompt text, not code, plus a computed convergence rule. **[E]**
3. **Grounding is the biggest quality lever we have seen, and it is unevenly applied.** The one model that read the real specs caught two field collisions that two others would have shipped; 16 of 17 narration leaks come from the same tool-using model doing that checking. Make grounding explicit and strip the narration. **[E]**
4. **The draft prompt and the draft guard disagree: 48% of drafts exceed the guard's own size estimate, and the draft stage has no exit for "this repo lacks the surface the candidate assumes".** Showing the model the estimator and adding a `mismatch` exit are cheap. **[E]**
5. **A recruiter cannot judge agent quality yet (8 human reviews across 287 opportunities), but it can find a real defect today: `claude` has failed 50 of 50 attempts as a prospect provider because an API key is unset.** Start with a read-only roster health report and add prompt-version and model fields to telemetry. **[E]**

## Recommended first step

Two cheap, low-risk, evidence-backed changes first, before any new feature: **(a)** narration stripping and the attribution check (both already in the ledger), and **(b)** the R1 + R2 + R3 debate prompt rewrites *behind a flag*, evaluated with the small experiment (about 60 calls, roughly $15 to $30 by the estimate above) before they become the default. In parallel, build the e3d-corp roster health report.

## Candidate tickets (for the e3d-pilot ledger later)

1. **Attribution check for synthesis** *(exists: `idea-79378bb3da4c`)*: verify every quoted string and who-said-what claim against the transcript.
2. **Strip agent narration** *(exists: `idea-135c127951d5`)*: remove tool-use narration from provider output.
3. **Debate prompt rewrite R1+R2 behind a flag**: self-labelling, steelman/check, grounding, `ACTION`/`AGREES_WITH` with computed early stop.
4. **Synthesis rewrite R3 with per-analyst dissent and verbatim quotes**, and the matching MCP `dissent` list shape.
5. **Reviewer lenses and checklists (R4, R5)**: embed the spec and acceptance criteria in the review prompt; add `NOT REVIEWED`.
6. **Draft sizing worksheet and `mismatch` exit (R6)**, with the parser change.
7. **Specialist file format, loader, `--panel/--specialist`, presets, MCP `panel` parameter and `e3d_list_specialists`.**
8. **Use the system-prompt and effort channels in adapters**: `claude --append-system-prompt/--effort`, `grok --rules/--reasoning-effort`, API `system` fields, MCP sampling `systemPrompt`.
9. **Script/banter mode (R8)**: beat sheet, sequential turns with a used-phrases list, producer pass.
10. **Prompt evaluation harness**: fixed question set, blind rating sheet, claim-accuracy script, single-model arm.
11. **e3d-corp roster health report (recruiter step 0)** plus `promptVersion` and `model` fields in telemetry and Opportunities.
12. *(deferred)* **Roster mandate and `specialist.*` action types** in `ACTION_POLICY`, only after 11 has produced a few weeks of data.

## What I could not verify

- **That any rewrite improves results.** None was run; no model was called. The experiment plan exists for this.
- **Whether `codex exec -c` accepts a reasoning-effort key**, and whether each MCP client honours `systemPrompt` in sampling requests. Both marked **[G]**.
- **Cause of the reviewer spread** (model character, versus differing specs, rounds, or versions); the counts are real, the attribution is partly confounded.
- **Whether the three "no verdict" review files per provider are the same three runs** (consistent with the documented large-diff failure, not confirmed).
- **Quality of any model for any specialist role** beyond the behaviors cited as **E**; every other role-to-model suggestion is a guess.
- **Anything inside the e3d-corp instance beyond event-type counts and error classes**: I deliberately did not read prospect, customer or financial content. The `futco` outcome volume (8 reviews, 9 proposals, 5 approvals) comes from counting event types.
- **The MacBook QA findings (source Q)** were taken from the pasted report; I did not re-run them.
- **The pirate-debate "tone versus facts" and "style imitation" observations**, which rest on one transcript and a prompt that explicitly asked for the style.
