# Debate

**Prompt version:** v2

**Question:** You are the e3d-debate committee producing input to a research RFC. Treat every proposal as a hypothesis; seek consequential defects, security/privacy risks, missing requirements and simpler alternatives. Do NOT optimize for consensus. Attribute dissent explicitly. Favor reuse over reinvention, measurable improvement over theoretical benefit, simplicity over new architectural layers.

QUESTION: Should E3D use Google Research's Harness² (github.com/google-research/harness2, Apache-2.0, arXiv 2610.14224) to recursively optimize the harnesses of e3d-pilot, e3d-code and e3d-brain? Choose among: (A) use Harness² directly as an external optimizer, (B) adapt selected components, (C) independently implement its most valuable ideas inside E3D, (D) do nothing/defer. Also answer: (1) can it optimize E3D agents without replacing existing orchestration; (2) what adapters/modifications are needed; (3) could the E3D multi-model debate system, provenance ledger and e3d-brain make recursive optimization more effective; (4) what is the SMALLEST experiment showing measurable improvement, with pass/fail criteria; (5) security and licensing implications.

FACTS ESTABLISHED FROM READING THE HARNESS² REPO (verified, not speculation):
- It optimizes a "harness" (everything around fixed-weight models) expressed as an editable 8-component file tree c1..c8: system prompt, guardrails, memory, skills, tool guidance, tool scripts, subagents, plugins/middleware. Edits are file-tree diffs; "omitted is inherited"; validators per substrate (SurfaceSpec) reject invalid trees and feed errors back as retry text.
- Task-level recursion = Propose-Probe-Compose with NO ground-truth feedback: it runs the base harness, proposes edits, probes the edits on the SAME task, and composes a refined harness from behavioral contrasts between trajectories. Selection is score-free: RunView "never carries a score"; the judge runs only after selection is committed. Parallel mode (wider) and sequential mode (deeper); budget --k, each mode schedules 4k rollouts and 3k improvement stages. Harnessing-level recursion = a persistent "improvement harness"/library that retains adopted harnesses and evidence-supported lessons across tasks.
- Integration seam is a Python Protocol `BenchmarkAdapter` (~12 methods: tasks, domain_of, task_prompt, task_files, execute(task_id, harness_dir, run_id)->run_dir, delivered, trajectory, deliverable_files/text, base_harness, validate_tree, score) plus a `BenchSpec` value and a `SubstrateLike` (surface()). Shipped substrates/executors: OpenCode (default) and Codex (--substrate cx). Proposer/selector channels: claude_cli or opencode. Shipped adapters: JobBench, LAB (legal), WorkBuddy-Bench. ~13k LOC Python, Linux, Python 3.12, uv, Node 20+, gcloud CLI.
- Reported results (README/paper): a single step improves GLM-5 and Gemini 3.5 Flash over base harnesses; up to +11.5 pts WorkBuddy-Bench, +4.5 JobBench, +11.8 pp LAB partial pass; larger k gives more gains. Self-reported by Google Research on its own benchmarks, weights fixed.
- Security: README warns executor network access is unrestricted and Codex runs with its sandbox disabled; benchmark rubrics may be reachable online (leakage); API cost per run; "not an officially supported Google product". Third-party code in third_party/ and datasets keep upstream licenses.

E3D CONTEXT: e3d-pilot is a bash/Node pipeline (negotiate, execute, review, publish) that turns ideas into PRs, with a provenance ledger (ideas, events, evidence links) and e3d-debate (multi-provider committee: claude, codex, etc., rounds of rebuttal then synthesis). e3d-code is the spec-to-code tool (formerly spec2code). e3d-brain is a markdown/notes knowledge system with MCP search. E3D already has per-idea outcomes (merged / implementation_failed / rejected, reviewer verdicts, test results) which are a natural ground-truth-like signal Harness² deliberately does not use. Compute budget is a small metered API credit; the team is tiny and favors products over tooling.

DELIVER: a recommendation among A-D with the strongest dissent preserved, the key risks (e.g. Goodharting on self-generated signals, optimizing prompts against a tiny noisy task set, Linux/gcloud/Python stack mismatch with a Mac bash/Node stack, unrestricted network executors against private repos), a concrete minimal proof-of-concept design (task set, baseline, harness surface to edit, budget k, success metric and threshold, cost cap, stop rule), and what NOT to build.

**Jev pre-screen (shadow mode, informational only):** obviousness noul=0.14 (1.0 = clearly obvious, 0.0 = clearly needs debate) -- logged for calibration, does not affect whether this debate runs.

## Round 1 -- claude

**Recommendation: (D) defer Harness² as a dependency, but do (C) in a minimal form. Run one small experiment that uses E3D's own outcome signal. Do not adopt A or B now.**

**Why not A or B.**
- The adapter seam is real, but the stack mismatch is large: Linux, Python 3.12, uv, gcloud and OpenCode/Codex executors, against a Mac bash/Node pipeline.
- Executors have unrestricted network access, and Codex runs with its sandbox disabled. Pointing that at private repos with a metered key is a bad trade.
- About 13k LOC of benchmark-shaped code would become a permanent dependency for a tiny team.
- The reported gains are self-reported on Google's own benchmarks, with different models and tasks, so they don't transfer to E3D.
- The costs are large: 4k rollouts and 3k improvement stages per task, per mode.

**What is worth taking (C).**
1. The harness as an editable file tree, with an "omitted is inherited" overlay.
2. Validators that reject bad edits and feed the error back as retry text.
3. Selecting candidates without showing the proposer a score.
4. A persistent library of adopted edits with evidence.

**The key divergence from Harness².** E3D has real outcomes: merged, implementation_failed, rejected, reviewer verdicts and test results. Harness² deliberately avoids ground truth. For E3D, outcome-based selection across tasks is simpler and more honest than per-task score-free self-refinement. I would skip Propose-Probe-Compose entirely. It multiplies cost per task, and E3D needs cross-task evidence anyway.

**Answers to the numbered questions.**
1. **Yes.** Orchestration stays as is. The harness surface is just the prompts, guardrails and tool guidance that pilot already feeds its phases. Overlay a candidate directory at run time and leave the pipeline unchanged.
2. **Adapters needed.**
   - Overlay loading, which can be an env var like `E3D_HARNESS_DIR`.
   - A validator, which can be a lint script.
   - A scorer that reads the ledger.
   - If A were ever pursued, a `BenchmarkAdapter` in Python that shells out to e3d-pilot. I would not pursue it.
3. **Yes, in three places.**
   - The debate can act as proposer or critic of edits, which gives model diversity.
   - The ledger supplies outcome labels and trajectories.
   - Brain stores adopted lessons.
   - Caveat: debate consensus is not evidence. A debate-approved edit is only a hypothesis until the outcome metric moves.
4. **Smallest experiment.**
   - **Task set:** 12 frozen historical ideas with known outcomes. Include a mix of merged and failed ones, all small, in 2–3 repos. Split into 8 tune and 4 held out. Keep the held-out set sealed until the end.
   - **Surface:** one component only, the execute-phase system prompt plus guardrails. Nothing else.
   - **Baseline:** the current harness, run 3 times on each task to measure the noise floor.
   - **Optimizer:** one proposer (Sonnet) generates 3 candidate diffs from baseline failure trajectories, using a plain loop and not Harness². Each candidate runs against the tune set.
   - **Budget:** k=3 candidates, 3 runs per task per arm, with a hard cap of $60 of the credit and a 2-hour wall clock.
   - **Metric:** the primary metric is the review-pass and tests-green rate, scored by the deterministic test suite plus the reviewer verdict. Secondary metrics are cost per task and diff size.
   - **Pass:** the held-out rate improves by at least 2 tasks of 4, or about 17 points absolute, across the 3-run average. The tune-set gain must also exceed twice the measured baseline run-to-run spread. Cost and regressions on previously passing tasks must not worsen by more than 20%.
   - **Fail or stop:** any of the following ends the experiment.
     - The cap is hit.
     - No candidate beats the baseline noise on the tune set.
     - The gain on the tune set doesn't replicate on the held-out set.
     - A candidate weakens a guardrail, which is an automatic reject.
   - Be honest about statistics: 4 held-out tasks can't establish significance. A pass means "worth a larger run", not "proven".
5. **Security and licensing.**
   - Apache-2.0 allows use, modification and redistribution. It requires retaining the notice and marking changes. If copying code, check `third_party/` and dataset licenses separately.
   - Anything run through unrestricted executors needs a sandbox: a container with no network, or an allowlist limited to the API.
   - Never expose private repos or secrets to those executors.
   - Evolving a guardrail layer with an LLM is itself a risk. An optimizer can learn to remove the checks that fail it. Guardrails must be read-only to the optimizer.

**Key risks.**
- **Goodharting on self-generated signals.** If the reviewer is a model, the optimizer learns to please it. Anchor on tests and merge outcomes.
- **Tiny noisy sets.** This is overfitting by construction, so the held-out split and noise floor are mandatory.
- **Selection leakage.** The proposer must not see held-out tasks.
- **Outcome contamination.** Historical merges depended on the old harness, so replays are not independent of it.

**Strongest dissent.**
- Someone will argue for A: Google already solved validators and recursion, so reimplementing is NIH. My answer is that the cost of the stack and sandbox adapter exceeds the benefit at this scale.
- Someone will argue for pure D: with 12 tasks the experiment is noise. That is partly right, and it is why a pass only authorizes a larger run.

**What NOT to build.**
- A Python port of Harness².
- A generic 8-component framework.
- An "improvement harness" service.
- A dashboard.
- Auto-adoption of edits without human review.
- Any optimization of e3d-brain until pilot shows a gain. Brain is retrieval, not an agent harness.

**Load-bearing assumptions.**
- Pilot phases read their prompts from files that can be overlaid.
- At least 12 replayable ideas with known outcomes exist.
- $60 buys 3 arms of 12 tasks. If not, shrink the task set rather than raise the cap.

## Round 1 -- codex

## Recommendation: **B — adapt selected components**

Use Harness² as a **time-boxed experimental optimizer around E3D**, not as production infrastructure. Reuse its editable-tree/validation model, Propose–Probe–Compose loop, and evidence records. Do not adopt its executor, persistent library, or full Python/gcloud stack yet.

The [repository](https://github.com/google-research/harness2) is new, unsupported, expensive by design, and explicitly runs Codex without sandboxing and executors with unrestricted networking. Its reported improvements are promising but self-reported on its own benchmarks; the [paper](https://arxiv.org/abs/2610.14224) does not establish transfer to small, private software pipelines.

**Strong dissent — D:** A tiny team with limited API credit should defer entirely until there is independent replication. Four-plus executions per task may cost more than simply improving E3D’s existing prompts from failure evidence. If the experiment cannot be isolated cheaply, D wins.

### 1. Preserve existing orchestration

Yes. Harness² can sit outside E3D:

`optimizer → temporary harness files → existing e3d command → trajectory/deliverables → existing tests/review`

It need not replace negotiate/execute/review/publish, e3d-debate, or provider routing. Initially allow edits only to:

- system instructions;
- guardrails;
- tool guidance;
- existing skills.

Exclude scripts, plugins, subagents, pipeline control flow, credentials, and publish behavior.

### 2. Required adapter

Build one thin `BenchmarkAdapter`, preferably as experimental Python glue rather than porting Harness²:

- Enumerate frozen historical E3D tasks and domains.
- Materialize task files into disposable worktrees.
- Translate c1/c2/c4/c5 into E3D’s existing configuration.
- Invoke the Node/bash CLI unchanged.
- Convert ledger events, tests, reviews, diffs, and deliverables into RunView-compatible artifacts.
- Score only after selection using deterministic tests plus blinded review.
- Validate an allowlisted file tree, size limits, forbidden instructions, and unchanged orchestration.
- Run under Linux container/VM if Harness²’s POSIX assumptions fail on macOS.

### 3. E3D-specific advantage—and danger

E3D can improve the method:

- **Debate:** different providers propose changes; a dissenting model attacks regressions and prompt injection.
- **Provenance ledger:** supplies real outcomes, tests, and reviewer verdicts rather than behavioral appearance alone.
- **e3d-brain:** retrieves prior failure lessons by domain.

But these signals invite Goodharting. “Merged” is not correctness; reviewers and tests share blind spots. Do not let generated lessons automatically enter e3d-brain. Require evidence links, human approval, project/model/version scope, and expiry. Keep held-out scores invisible to proposers and selectors.

### 4. Smallest credible experiment

Use **eight frozen historical tasks**: two each from pilot/code/brain plus two cross-project tasks. Four build the improvement library; four remain sealed evaluation tasks.

- Baseline: existing harness, fixed model/provider/settings.
- Treatment: parallel `k=1`.
- Same disposable environment and task inputs.
- Hidden evaluator: tests, requested-artifact checks, and blinded reviewer rubric.
- Primary metric: independently verified task success.
- Pass: treatment succeeds on **at least two more of four held-out tasks**, causes no baseline-success regression, introduces no security violation, and stays within **$50 total API cost**.
- Secondary: cost per successful task and human review minutes.
- Stop immediately on secret access, network escape, publish attempt, evaluator leakage, or cost cap.
- A tie, one-task gain, or improvement confined to development tasks is failure—not “promising.”

### 5. Security and licensing

Never run the shipped unrestricted executor against private repositories. Use secret-free snapshots, network denial, disposable containers/worktrees, read-only evaluator files, command allowlists, output-size limits, and retained audit logs. Treat task text, repository files, brain notes, and retrieved “lessons” as untrusted prompt-injection inputs.

Apache-2.0 permits adaptation with required license/notice preservation and modification notices, including its patent terms. Audit `third_party/`, benchmark, and dataset licenses separately; do not copy benchmark data into E3D by assumption.

**Do not build:** a new recursive-optimization service, generalized eight-component abstraction, autonomous memory writer, custom executor, dashboard, or Node rewrite. First prove that four editable text surfaces beat the current harness on sealed E3D outcomes.

## Round 2 -- claude

**Position held: (D) defer Harness² as a dependency, plus a minimal (C) experiment on E3D's own outcome signal. Codex's (B) is mostly the same action under a different label, but its adapter layer is what I disagree with.**

**Where Codex and I actually agree (and why the letter is a distraction).**
- Orchestration stays unchanged.
- The edit surface is a few text files: system prompt, guardrails, tool guidance.
- The held-out set is sealed and the proposer never sees it.
- The pass bar is roughly 2 of 4 held-out tasks.
- The cost cap is $50–60.
- Guardrails and the evaluator are untouchable by the optimizer.
- Nothing is auto-written to brain.
- Nobody builds a service, dashboard, or generic 8-component framework.

**Where Codex is wrong, in my view.**
1. **Adapter-in-Python is the expensive part and it is the part B insists on.** Codex's `BenchmarkAdapter` has to enumerate tasks, materialize worktrees, translate c1/c2/c4/c5, convert ledger events into RunView artifacts, validate trees and run in a Linux container. That is the stack mismatch I flagged, now written as a requirement. For a 4-file edit surface, the same loop is about 100 lines of bash/Node: an overlay dir, a lint script, a ledger scorer. The only thing Harness² would contribute is its optimizer loop, and I argued we should skip it (Propose-Probe-Compose).
2. **Propose-Probe-Compose is the wrong thing to borrow.** It is designed for the case where no ground truth exists. E3D has outcomes, so selecting on tests plus reviewer verdicts across tasks is cheaper and less self-referential. Codex's treatment arm (parallel k=1) buys 4 rollouts and 3 improvement stages per task, which on a metered key is a large fraction of the cap for one data point. Codex does not say how $50 covers that across 8 tasks, and I doubt it does.
3. **Eight tasks, four sealed, with a 1-task gain called failure.** That is a stricter bar than mine on a smaller sample, with no baseline noise measurement. A single run per arm on 4 tasks cannot separate signal from run-to-run variance. I require 3 runs per task and a tune gain above 2× the measured spread. Codex's design could pass or fail purely on luck.
4. **"Two each from pilot/code/brain."** I'd still defer brain. It is a retrieval system, not an agent harness, so it has no execute-phase prompt to optimize. Adding it dilutes an already tiny sample.

**What I take from Codex.**
- The stop conditions are better than mine: secret access, network escape, publish attempt, evaluator leakage. I'm adding them.
- Treating task text, repo files and brain notes as untrusted prompt-injection input is correct, and I had it only implicitly.
- Lessons that enter brain need an evidence link, a human approval, a scope (project/model/version) and an expiry. I'll adopt that.
- A blinded reviewer rubric on top of tests is a reasonable secondary metric. It should stay secondary, since model reviewers are the Goodhart risk.

**The strongest dissent, attributed.**
- **Codex's own dissent (pure D)** is the one I take most seriously. If the overlay cannot be made cheaply, because pilot phases hardcode their prompts, my experiment is not small and defer wins. The first step is therefore a one-hour check of whether the execute-phase prompt loads from a file. I haven't verified that.
- **Against me:** someone will say an in-house loop is exactly the NIH reinvention the question warns about. My answer is that the part worth reusing is the design (overlay, validators, score-free proposer), not the code, and the code only runs on a stack we don't have.
- **Honest limit on both of us:** outcome contamination. Historical merges were produced under the old harness, so replays are not independent samples. Neither plan fully fixes this.

**Disagreement that remains.** Codex would write a Python adapter and invoke Harness²'s loop. I would not, and would write a bash/Node overlay and a plain proposer loop. Those lead to different first-week work.

POSITION: Defer adopting Harness² itself (D), but run one small in-house (C) experiment with a bash/Node overlay, outcome-based scoring, 3 runs per arm, a sealed held-out split and a $60 cap, rather than building a Python BenchmarkAdapter around Harness² as Codex proposes.
status: revise

## Round 2 -- codex

I change my position from **B to C**: independently implement only the smallest valuable ideas inside E3D. Claude’s central objection holds: adapting Harness² still requires an adapter, Python/Linux environment, artifact translation, and security wrapper around a 13k-LOC experimental system. That integration is larger than the experiment needed to test its premise.

Claude labels its recommendation “D, but do C,” which is operationally ambiguous. Running its proposed optimization experiment is C, not D. I agree with its substance but choose C explicitly.

Harness² can optimize agents without replacing E3D orchestration: candidate prompt overlays can feed the existing negotiate/execute/review pipeline. But direct integration is unjustified until an E3D-native experiment demonstrates transfer.

Implement only:

- An allowlisted overlay for one prompt surface.
- Static validation, with errors returned for one repair attempt.
- Candidate comparison using sealed tasks.
- Evidence records in the existing ledger.

Do not initially reproduce Propose–Probe–Compose, its eight-component abstraction, RunView, persistent improvement harness, executor, or Python adapter.

E3D potentially has better signals than Harness²: deterministic tests and actual outcomes can constrain multi-model proposals; debate can supply adversarial criticism; the ledger can preserve candidate lineage. However, reviewer verdicts and merges are correlated, gameable proxies. Debate agreement is not evidence. e3d-brain should retrieve approved lessons only after replicated gains, with model/project/version scope and expiry; it should neither select candidates nor autonomously ingest optimization conclusions.

The smallest defensible experiment:

- Ten replayable, secret-free historical tasks from e3d-pilot/e3d-code; six development and four sealed.
- Fixed model, settings, tools, repository snapshot, and cost limits.
- Editable surface: only the execute-phase prompt/tool guidance. Guardrails remain immutable.
- Measure baseline variance by rerunning two representative tasks three times.
- Two candidate diffs proposed from development failures; one selected using tests and blinded review. This is an E3D-native bounded search, not Harness² `k=1`, whose nominal scheduling is already expensive.
- Run baseline and selected candidate on every sealed task in randomized order.
- Pass only if the candidate wins at least two additional sealed tasks, regresses none, exceeds twice the measured baseline noise, causes no policy/security violation, and increases cost per task by no more than 20%.
- Hard cap: $50 and two hours. Stop on evaluator leakage, secret access, unexpected network use, publish attempts, weakened guardrails, or exhaustion of the cap.
- A pass authorizes a larger replication—not adoption. A tie, one-task gain, or development-only gain fails.

Strong dissent remains **D**: four sealed tasks cannot establish statistical confidence, and manual prompt repair may dominate this elaborate search. If ten safe replayable tasks or the $50 budget are unavailable, defer entirely. The case for A/B—reuse tested validators and recursion instead of NIH—becomes persuasive only after measurable E3D benefit justifies integration cost.

Security requires disposable worktrees or containers, denied-by-default networking, no private credentials, read-only evaluators, command allowlists, and audit logs. Treat repositories, task text, debate output, and brain retrieval as prompt-injection inputs. Apache-2.0 permits copying or modification with notices and modification marking, but every reused third-party component and dataset needs a separate license audit.

Do not build a generic optimizer service, Python port, eight-component schema, custom executor, dashboard, autonomous memory writer, or optimization support for e3d-brain.

POSITION: Choose C: run one bounded E3D-native prompt-overlay experiment, and defer Harness² code integration unless sealed E3D outcomes improve.
status: revise


## Synthesis (claude)

FINAL ANSWER: Choose (C). Don't adopt Harness² code, and don't build a Python adapter around it. Run one E3D-native experiment instead. It would use a bash/Node overlay of the execute-phase prompt and tool guidance, with guardrails and the evaluator read-only. Use about 10–12 frozen, secret-free historical tasks, with 4 sealed as a held-out set. Score on tests and ledger outcomes, with 3 runs per arm to measure the noise floor, and set a hard cap of $50–60 and two hours. Pass if the candidate wins at least 2 more of the 4 sealed tasks, regresses none, beats twice the baseline noise, and raises cost per task by no more than 20%. A pass authorizes a larger replication, not adoption. Stop on secret access, network escape, a publish attempt, evaluator leakage, or a weakened guardrail. Run everything in a disposable, network-denied sandbox and treat repo text, debate output and brain notes as prompt-injection inputs. Skip e3d-brain, because it is retrieval and not an agent harness. Don't build a generic 8-component framework, an improvement-harness service, a dashboard, or auto-adoption of edits or lessons. Apache-2.0 allows reuse with notices, but audit `third_party/` and dataset licenses separately. First check that the execute-phase prompt loads from a file. If it doesn't, or if there aren't enough replayable tasks, defer (D).
CONSENSUS: majority
DISSENT: Claude labels its plan "D plus a minimal C experiment" and would build a plain proposer loop, while Codex moved from B to C. The shared residual dissent is pure D: 4 sealed tasks can't establish significance, and historical outcomes were produced under the old harness, so replays aren't independent.

**Attribution check:** 1 quoted string(s) in the synthesis, 1 NOT found verbatim in the analysts' text (possible paraphrase or misattribution):
- "D plus a minimal C experiment"
