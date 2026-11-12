# Debate

**Question:** Question: should e3d-pilot (multi-model idea->PR pipeline + e3d-debate) and codex-spec-runner (phased spec execution with per-phase model routing, Codex/Claude CLIs, a Qwen coding provider being designed) adopt any of these five open-source tools surfaced in a tweet (facts below were read from each repo's own README/GitHub metadata on 2026-10-07; they are the projects' own claims, unverified by us; the repos are 3-7 weeks old):

1. Rizzo-AI-Academy/rizzo-flow (Apache-2.0, 842 stars, created 2026-09-21): open local re-implementation of the *interface* of TypeSafe's Jev "System One" typed-decision API (yes/no, choice, score, number with probabilities, no token generation). Runs on llama.cpp (Metal/CUDA/Vulkan/ROCm/CPU), default model Spark-X2.5 4B/1.7B + own LoRA fine-tune; claims ~50 ms/decision on RTX 5060 Ti at Q8_0, ~5.6 GiB GPU memory, same HTTP interface so code can point at localhost by changing one URL. States probabilities are UNCALIBRATED unless calibrated on own data and makes no claim of matching Jev quality.
2. Yinsongxu/LLM2Jev (Apache-2.0, 402 stars, created 2026-09-19): turns local LLMs (e.g. Qwen3.5-4B) into Jev-style decision models via prefill-only logit scoring; SGLang, Transformers, and MLX (Apple Silicon) backends; text+image; exposes a /v1/systemone-compatible HTTP endpoint. Claims 76.2% on 231 public JevBench items with Qwen3.5-4B, P50 48 ms / P95 346 ms vs Jev 1.13.0 P50 652 ms / P95 722 ms. Not affiliated with TypeSafe.
3. APUS-AI-Lab/fast-browser-use (MIT, 211 stars): a browser-automation "System 1" agent skill for Claude Code/Codex/Cursor using local Qwen3.5-9B / 35B-A3B via MLX or PyTorch, single-token action selection over visible interactive elements, claims zero cloud inference.
4. See-Sol-Lab/DeepSeekGUI (263 stars): desktop GUI workbench over the DeepSeek Harness (Git, built-in browser, memory); Windows/Linux builds; product layer under PolyForm Perimeter 1.0.1 (source-visible, NOT open source; no use to build competing products), upstream harness MIT.
5. oriveo/oriveo (AGPL-3.0, 476 stars): open-source BYOK multi-model chat client for iOS/Android/web (OpenAI, Anthropic, Gemini, OpenRouter, DeepSeek + more, plus Ollama/LM Studio/llama.cpp/vLLM endpoints); local-first, self-hostable, Swift.

Context on how e3d-pilot already uses Jev: it calls hosted Jev (TypeSafe System One) via TYPESAFE_API_KEY in two advisory-only places -- a shadow-mode "is this question obvious enough that debate is unnecessary" Noul pre-screen in e3d-debate (informational only, collecting calibration data for a possible future gate, idea-82a5c2225266) and an advisory dedup check on idea ingest (lib/ideas/jev_dedup.sh) that appends notes and never blocks. Both fail open/skip when no key is set. Pilot's execution stages (draft, negotiate, execute, review) are driven by frontier CLIs (claude, codex, devin, grok-build). Hardware today: one 24 GB Mac mini running Qwen locally, shared by several agent systems. Strategic direction from prior debates (docs/debates/2026-10-06-e3d-ai-appliance and 2026-10-07-smb-ops-product-architecture): local-first measured Qwen routing, governed autonomy with deterministic policy kept OUTSIDE the model, prefer open source and existing systems, don't build commodity plumbing.

For each of the five, give a verdict (ADOPT now / PILOT behind a flag / WATCH / SKIP), and for each say exactly where it would plug in (e3d-pilot stage, e3d-debate, spec-runner phase routing/escalation, or the SMB-ops product) and what it would replace or add. Specifically consider: (a) could a local typed-decision endpoint replace or shadow hosted Jev for the debate pre-screen, idea dedup, candidate-scoring, and -- for spec-runner -- "Qwen attempt passed / needs escalation to Codex" confidence routing, and what calibration evidence (e.g. shadow-compare against hosted Jev and against actual outcomes on our own ledger) must exist before trusting its probabilities for any gating role; (b) is fast-browser-use useful for pilot/spec-runner/Corp web tasks or just a security surface (browser agents + credentials + prompt injection) given the RED-action policy; (c) license/legal and supply-chain risk (AGPL, PolyForm Perimeter, very young repos, pickled/untrusted model weights, an unaffiliated clone of a commercial API) and a vetting checklist; (d) what is the smallest, cheapest experiment that would justify or kill each adoption. Give a concrete recommendation, not a survey; say which single thing to do first.

**Jev pre-screen (shadow mode, informational only):** obviousness noul=0.11 (1.0 = clearly obvious, 0.0 = clearly needs debate) -- logged for calibration, does not affect whether this debate runs.

## Round 1 -- claude

**Do first: LLM2Jev, as a PILOT shadow experiment in e3d-debate's pre-screen. It's a one-afternoon spike that logs and gates nothing.**

These verdicts rest on the repo claims you supplied, which I haven't verified.

**Verdicts**

1. **rizzo-flow: WATCH.** Its README says it makes no quality-parity claim and its probabilities are uncalibrated. Its target is CUDA/RTX-class hardware, and your Mac mini is Metal-only and shared. Its one real advantage is a faithful clone of the hosted interface. LLM2Jev already offers a compatible endpoint with an MLX backend, so rizzo-flow adds nothing for you now. Revisit it if you move to a GPU box.

2. **LLM2Jev: PILOT behind a flag.**
   - **Where it plugs in:**
     - **e3d-debate:** shadow the Noul pre-screen.
     - **`lib/ideas/jev_dedup.sh`:** shadow the dedup check.
     - **Candidate scoring:** a later add-on.
     - **Spec-runner:** an eventual "Qwen passed / escalate" signal.
   - **Implementation:** add `E3D_JEV_BASE_URL` and `E3D_JEV_BACKEND=local|hosted|both`. Both callers already fail open and are advisory, so a local endpoint can be added beside hosted Jev with no change in behavior.
   - **MLX on the Mac mini:** run Qwen3.5-4B (about 3 GB) via MLX. That fits next to your other Qwen workloads, but check memory pressure first.
   - **Replaces nothing yet.** It adds a second advisory column.

3. **fast-browser-use: SKIP for now.**
   - **Security surface:** it combines a browser, credentials and prompt injection. Your RED-action policy keeps deterministic policy outside the model, and this tool would put an unvetted model inside the loop for exactly those actions.
   - **Value:** pilot and spec-runner have no web-task demand today. Revisit it only when the SMB-ops product has a concrete web-automation need. At that point, run it in a sandboxed profile with no credentials and allow-listed domains.

4. **DeepSeekGUI: SKIP.** PolyForm Perimeter bars building competing products, and e3d-pilot and the SMB-ops product plausibly compete with it. It is a GUI over a harness you don't use, and it has no integration point.

5. **oriveo: SKIP for the pipeline. WATCH for the SMB-ops product.** AGPL-3.0 makes embedding or forking it a copyleft problem for any hosted product. It's a chat client, not plumbing you need. Only consider it as a separate, unmodified, self-hosted client for operators.

**(a) Calibration evidence before any gating role**

- **Ledger:** log local and hosted outputs side by side, plus the eventual ground truth. Ground truth means whether a debate changed the verdict, whether a dedup candidate was later merged or closed as duplicate, whether a candidate got shipped, and whether a Qwen attempt passed review without Codex rework.
- **Agreement with hosted Jev:** at least 200 paired items, with rank correlation and decision-flip rate reported.
- **Outcome calibration:** AUROC and a reliability curve against your own outcomes. A local model that agrees with hosted Jev is not proof that either is right.
- **Gating thresholds:** it cannot gate until Brier score and the false-"obvious" rate are acceptable. A false "obvious" skips a debate, so cap that rate at about 2% on the labeled set.
- **Spec-runner escalation:** gate it separately and one-directionally. The local signal may only trigger more escalation, never suppress it. Deterministic tests stay the real pass/fail gate.
- **Latency claims:** measure them on your own hardware.

**(c) Vetting checklist**

- Pin a commit SHA and read the diff on every update.
- Check licenses: Apache-2.0 and MIT are fine.
- Weights must be safetensors or GGUF only. Refuse pickle files, and set `trust_remote_code=False`.
- Download weights from the official upstream Qwen repo, not the clone's own mirrors.
- Bind the server to 127.0.0.1 only.
- Run it in its own venv or container with no credentials or network egress.
- Audit dependencies with `pip-audit`.
- Read the code for telemetry or phone-home calls.
- Treat the "76.2% on JevBench" figure as marketing until you reproduce it.
- Name the clone's lack of affiliation with TypeSafe in the docs. Avoid trademark-ish naming in your own product.

**(d) Cheapest kill experiment**

1. Run LLM2Jev with Qwen3.5-4B on MLX.
2. Replay about 100 past debate questions and ledger ideas through it.
3. Compare its answers to the hosted Jev answers you already have, and to the known debate outcomes.
4. **Kill it** if agreement is under about 70%, or if P95 latency is over 1 s on the Mac mini, or if it destabilizes the other Qwen workloads.
5. **Keep it** as a shadow column only if it passes. Promote nothing to a gate until the calibration bar above is met on real outcomes.

**Assumptions**

- Your Mac mini has about 3 GB of headroom.
- Hosted Jev outputs for past items are retrievable from the ledger. If they aren't, the replay costs a little hosted-API money.
- The product strategy stays local-first with policy outside the model.

## Round 1 -- codex

Do one thing first: **pilot LLM2Jev in shadow mode on the Mac mini**, using real ledger cases. It best matches existing Qwen/MLX infrastructure and tests the strategic question—whether local typed judgments are useful—without changing authority.

1. **LLM2Jev — PILOT behind a flag.** Add as a selectable backend for e3d-debate’s obviousness pre-screen and idea-ingest dedup; then shadow candidate scoring and spec-runner’s post-Qwen escalation decision. It replaces no deterministic tests and initially replaces no hosted Jev calls. Cheapest test: replay ≥500 labeled historical decisions, then shadow live for two weeks, recording LLM2Jev, hosted Jev, latency/resource use, and eventual outcomes.

2. **rizzo-flow — WATCH.** Treat it as LLM2Jev’s alternate backend, not a second integration: same debate/dedup/candidate-routing seams. Its explicit uncalibrated-probability warning, custom LoRA, and less Mac-specific story make it second choice. Cheapest test: run the identical frozen replay set after LLM2Jev; adopt only if materially better on calibration, throughput, or operational simplicity. Never download pickled weights.

3. **fast-browser-use — WATCH.** Potentially useful only in the SMB-ops product for bounded, read-only portal reconnaissance or form drafting—not pilot’s coding stages or spec-runner. Browser agents combine credentials, hostile page content, and actions; they must never decide or execute RED operations. Cheapest test: disposable VM/profile, public test site, fake data, no credentials, allowlisted domains/actions, network recording, and prompt-injection fixtures. Continue only if it reliably stops at approval boundaries and beats existing browser automation.

4. **DeepSeekGUI — SKIP.** It adds a competing desktop workbench, not a missing pipeline primitive; lacks macOS support, while PolyForm Perimeter conflicts with product reuse. Do not test the product layer. A one-hour review of the MIT harness alone is sufficient if a concrete harness gap later appears.

5. **oriveo — SKIP.** A multi-model chat client does not advance idea→PR execution, phased routing, or governed SMB operations; AGPL creates needless distribution/network-service obligations. Cheapest experiment is a requirements comparison—already a mismatch. Revisit only if a mobile approval inbox becomes a committed requirement, and then prefer a narrow existing approval UI.

No local probability should gate debate skipping, dedup rejection, candidate selection, or Qwen escalation until each task has preregistered thresholds and enough in-domain outcomes to measure Brier score, reliability/ECE, false-negative costs, and drift. Agreement with hosted Jev is diagnostic, not ground truth. For spec-runner, tests, static checks, and artifact verification remain primary; typed confidence may only add an escalation feature. This follows TypeSafe’s own guidance that code retains control and thresholds require target-domain validation. [TypeSafe documentation](https://docs.typesafe.ai/llms.txt)

Before any pilot: pin commits and hashes; inspect install scripts/dependencies; generate an SBOM; scan licenses/CVEs; verify weight format/provenance; forbid pickle/remote code; sandbox networking/filesystem; benchmark shared-Mac contention; and obtain legal review for API-trademark compatibility, AGPL, and PolyForm terms.

## Round 1 -- devin

Now I have enough context. Here's my verdict:

---

## Verdict

### 1. rizzo-flow — **WATCH**

Runs Spark-X2.5 (a model you don't have). On Metal the latency claims are unverified, and the 24 GB Mac mini is already loaded with Qwen shared across several systems. The `JEV_API_URL` env override in `lib/providers/jev.sh` means the wiring is already there — one env var swap — but loading a second model family competes for the same memory budget. LLM2Jev is strictly better for this hardware. Revisit if Spark-X2.5 proves meaningfully more accurate than Qwen on your own ledger.

### 2. LLM2Jev — **PILOT (do this first)**

Best fit by far. MLX backend = Apple Silicon native, Qwen3.5-4B = model family already running on the Mac mini (no new weights to vet), Apache-2.0, and `JEV_API_URL=http://localhost:<port>/v1/systemone` is the entire integration into both `jev_dedup.sh` and the debate pre-screen. Use in shadow mode only: log both the hosted Jev response and the LLM2Jev response, compare against actual outcomes on the idea ledger over ~50 events. **Calibration bar before any gating role:** ≥80% agreement with hosted Jev AND ≥70% accuracy predicting actual dedup/debate outcomes on the ledger. For spec-runner, same logic: LLM2Jev confidence on "did this Qwen phase attempt pass?" gives you escalation routing to Codex/Claude, but only after validating on ≥30 phase outcomes first. Until then, probabilities are decorative.

Supply-chain checklist: pin to a specific commit hash; review the HTTP server code before running on your network; audit the MLX backend for pickle deserialization of model weights; run in an isolated venv with no access to credentials.

### 3. fast-browser-use — **SKIP**

Browser automation + credentials + prompt injection = RED action by your own policy. Youngest and smallest repo (211 stars, 3 weeks old). No identified use case in the automated pipeline — pilot/spec-runner tasks don't need browser control. If Corp web tasks ever require it, that's a human-in-the-loop step, not an agent step.

### 4. DeepSeekGUI — **SKIP**

PolyForm Perimeter 1.0.1 prohibits use to build competing products. e3d-pilot is exactly that. Mac builds don't exist. Desktop GUI has no place in an automated pipeline. Hard no, license alone.

### 5. oriveo — **WATCH**

AGPL-3.0 is a barrier: any server-side integration triggers copyleft on the combined work. It's a consumer chat client, not a pipeline tool, and you've explicitly rejected commodity plumbing. No immediate use case. If the SMB-ops product ever needs a white-labeled multi-model chat front-end and you're willing to AGPL the layer, revisit. Not now.

---

**Single thing to do first:** Add `E3D_PILOT_JEV_SHADOW_LOCAL=1` flag support to `lib/providers/jev.sh` that fires a parallel async `curl` to `JEV_API_URL_LOCAL` (LLM2Jev) and appends a `jev_local_response` field to the existing shadow log. No behavior change, no new gate, just data collection. Run for 2 weeks. If agreement with hosted Jev exceeds 80% on your own ledger, promote to the optional offline fallback.

## Round 1 -- grok-build

I'll ground the verdicts in how Jev, routing, and the RED-action policy actually sit in this repo, then give one first experiment.Adopt none of them. Pilot one shadow endpoint. Skip the other four.

**LLM2Jev — PILOT behind a flag.** It is the only one that matches this machine: MLX on the 24 GB Mac mini, Qwen weights you already run, and a `/v1/systemone`-shaped POST. The seam is `JEV_API_URL` in `lib/providers/jev.sh`, used only by the debate Noul pre-screen and `lib/ideas/jev_dedup.sh`. Add a second URL, `JEV_SHADOW_URL`, and log both answers. Do not point `JEV_API_URL` at it. It replaces nothing and gates nothing. It does not enter spec-runner routing. A local probability is not a reason to skip Codex.

**rizzo-flow — WATCH.** Same interface idea, but a second runtime (llama.cpp) plus an unaudited Spark LoRA (~5.6 GiB) on a mini that is already shared. Their own README says the probabilities are uncalibrated and not a Jev-quality claim. Revisit only if the MLX shadow dies for a reason MLX cannot fix.

**fast-browser-use — SKIP.** A browser agent that picks actions over the live DOM, inside Claude/Codex/Cursor sessions that already hold credentials, is a RED surface (credentials, money, public side effects, prompt injection). It does not help draft, negotiate, execute, or review. Corp web research stays on tools that do not click. A 9B/35B browser model also fights the shared mini.

**DeepSeekGUI — SKIP.** The product layer is PolyForm Perimeter 1.0.1: source-visible, not open source, and not usable to build a competing product. An SMB ops appliance is that product. Windows/Linux only; the MIT harness license does not cover the workbench.

**oriveo — SKIP.** AGPL-3.0 BYOK chat UI. Pilot and spec-runner already speak through CLIs. Shipping this to customers drags network copyleft onto a product you were told not to fill with commodity chat.

**Calibration before any gate.** Agreement with hosted Jev is necessary and not sufficient. Keep the shadow advisory and fail-open. Separately, after the fact, score finished spec-runner phases with the question "did this Qwen attempt need Codex?" and label it from tests and review, not from the model. A gate is allowed only when, on your ledger, the score beats the base rate (Brier), the threshold lives in policy code outside the model, and a missing or low score still escalates to Codex. Until then, candidate-scoring and phase routing stay where they are.

**Vetting, before the process even starts.** Pin the commit. Accept safetensors only; refuse pickle. Confirm Apache-2.0 with no extra rider. Run it as its own user with no `TYPESAFE_API_KEY`, no customer credentials, and no repo write. Call it a local typed-decision endpoint, never Jev. Reproduce a slice of their bench yourself. No auto-update. These repos are weeks old; the README numbers are their claims.

**Do this first.** Pin LLM2Jev, serve Qwen3.5-4B on localhost, and dual-log the next 20 real Noul and dedup calls next to hosted Jev. Kill it if the bench slice does not reproduce, if the mini swaps under the existing Qwen load, or if mean absolute disagreement on those yes/no probabilities exceeds 0.25. That one log justifies or kills the pilot. Nothing else gets installed.

## Round 2 -- claude

Round 2: my prior position holds. The verdicts converge, and the real differences are in sequencing and kill criteria.

**Where everyone agrees (and I stand by it)**
- LLM2Jev: PILOT in shadow mode, advisory only, fail-open. All five of us say this.
- DeepSeekGUI: SKIP. PolyForm Perimeter bars building competing products.
- rizzo-flow: WATCH. LLM2Jev already has the MLX path and the compatible endpoint, so rizzo-flow adds nothing on this hardware.
- No local probability gates anything until it is calibrated on our own outcomes.

**Where I disagree with the others**

1. **fast-browser-use: SKIP, not Codex's WATCH.** Codex's disposable-VM test is sound if a web-automation need appears. Nothing in pilot or spec-runner has that need today, and the SMB-ops product has none committed. A WATCH verdict implies a tracked follow-up, and that costs attention for no payoff. Reopen it when a concrete requirement exists. The Codex fixture list (no credentials, allow-listed domains, injection tests) is the right test then.

2. **oriveo: SKIP, not WATCH.** Devin and I both said WATCH for SMB-ops. On reflection, Codex and grok-build are right that nothing here is a committed requirement, and AGPL is a real cost. I'm moving to SKIP. If a mobile approval inbox ever becomes a requirement, evaluate purpose-built options then.

3. **Sample sizes and kill thresholds.**
   - Codex wants 500 replays plus two weeks of live shadow. That is too heavy for a first spike.
   - Devin's "≥80% agreement" and "≥70% accuracy over ~50 events" are too loose for a gate. 50 events cannot support a calibration claim.
   - Grok-build's "20 live calls" is too small to kill or keep anything. The 0.25 mean-absolute-disagreement rule is reasonable as a kill rule, though.
   - My plan: a ~100-item replay as the cheap kill test (agreement under ~70%, P95 over 1 s, or contention with the other Qwen workloads kills it). Then live shadow to accumulate ≥200 paired items before any calibration claim.

4. **Integration seam: Devin and grok-build both found a better one than mine.** `JEV_API_URL` in `lib/providers/jev.sh` already exists. A second shadow URL, as grok-build proposes, with dual logging is simpler than my `E3D_JEV_BACKEND` switch. I'm adopting that. Never repoint the primary URL, because that would silently replace the hosted answer.

5. **Spec-runner.** Grok-build keeps it out of routing entirely. I'd allow one narrow use later: the local signal may only add escalation, never suppress it, and deterministic tests stay the gate. Nothing is built for this until the debate and dedup shadow passes.

6. **Supply chain.** Everyone's checklists overlap: pin the SHA, accept safetensors/GGUF only, no `trust_remote_code`, bind to localhost, isolate without credentials, and check for telemetry. I add that Qwen weights come from upstream, not the clone's mirrors. Legal review (Codex) is overkill for a localhost shadow that is never shipped. It matters only if SMB-ops ships it.

**Single first action**
Pin LLM2Jev, serve Qwen3.5-4B on MLX on localhost, add `JEV_SHADOW_URL` dual-logging to the debate pre-screen and dedup, and replay ~100 past items.

POSITION: Pilot LLM2Jev as a localhost shadow endpoint (second URL, dual-logged, never gating) with a ~100-item replay kill test first; WATCH rizzo-flow; SKIP fast-browser-use, DeepSeekGUI and oriveo.
status: approved

## Round 2 -- codex

My position mostly holds: adopt none now; first run a flag-gated LLM2Jev shadow pilot. I would tighten my earlier “≥500 replay cases” requirement: start with 100–200 plus live collection, but require substantially more task-specific outcomes before gating.

1. **LLM2Jev — PILOT behind a flag.** Add it beside hosted Jev in e3d-debate’s obviousness pre-screen and idea-ingest dedup; later record advisory candidate scores and spec-runner “Qwen passed / escalate” scores. It replaces nothing initially. The smallest experiment is a frozen historical replay plus two weeks of dual logging on the Mac, killed by unacceptable contention, latency, instability, or no predictive lift over simple base rates.

2. **rizzo-flow — WATCH.** It would use the same typed-decision seams, but its uncalibrated custom model and weaker Apple-Silicon fit offer no reason to run two pilots. Test it on the identical replay only if LLM2Jev fails operationally or rizzo-flow later shows compelling in-domain quality.

3. **fast-browser-use — WATCH, not general adoption.** It belongs only in an eventual SMB-ops sandbox for bounded, read-only reconnaissance or form drafting—not pilot/spec-runner stages. Test with fake data, no credentials, disposable profiles, allowlisted sites/actions, prompt-injection fixtures, and mandatory approval. It must never execute RED actions. “SKIP” is reasonable operationally today, but WATCH better preserves this narrow product experiment.

4. **DeepSeekGUI — SKIP.** It adds no pipeline primitive, lacks the relevant Mac target, and PolyForm Perimeter makes product reuse hazardous. Review only the separately MIT-licensed harness if a concrete gap arises.

5. **oriveo — SKIP for integration; WATCH only as a separate operator client.** It adds commodity chat rather than execution/routing. AGPL makes embedding or modification unattractive. A requirements comparison should kill it unless a mobile approval inbox becomes committed.

The others broadly converge on the right first action. Devin’s 50-event/30-phase samples and fixed 80%/70% accuracy thresholds are too weak and arbitrary for probability-based authority. Hosted-Jev agreement is diagnostic, not truth. Grok-build is too categorical in excluding spec-runner: local confidence can become an escalation feature, but deterministic tests and artifact review remain authoritative, and initially the signal may only cause *more* escalation.

Before any gate, measure task-specific Brier score, reliability/ECE, discrimination, threshold error costs, drift, and outcomes: debate usefulness, confirmed duplicates, shipped candidates, and Qwen attempts accepted without rework. Debate skipping needs an especially low false-“obvious” rate. Thresholds remain deterministic policy outside the model.

Vetting: pin commits and hashes; audit install/server code, dependencies, licenses, telemetry, and egress; generate an SBOM; accept verified safetensors/GGUF only; disable remote code and pickle; use official weight provenance; bind localhost; isolate credentials/filesystem; benchmark shared-Mac contention; document the unaffiliated API clone; obtain legal review for trademarks, AGPL, and PolyForm.

POSITION: Pilot LLM2Jev first as a non-gating shadow endpoint, watch rizzo-flow and narrowly sandboxed browser automation, and skip DeepSeekGUI and oriveo integration.
status: revise

## Round 2 -- devin

**My round-1 position holds. One real disagreement to rebut; everything else converges.**

**What all four agree on (don't relitigate)**
- LLM2Jev: PILOT behind flag, shadow only, gates nothing
- rizzo-flow: WATCH
- DeepSeekGUI: SKIP (PolyForm Perimeter, no Mac builds)
- Calibration framework: shadow → ledger → outcomes → Brier before any gate

**Real disagreement: fast-browser-use (codex says WATCH; I say SKIP)**

Codex's framing — "bounded, read-only portal reconnaissance" — sounds safe but isn't. Single-token action selection over a live DOM *is* the model making decisions about what to click, follow, or submit. That's policy inside the model, which the strategic direction explicitly prohibits. "Read-only" doesn't eliminate the surface: URL parameters, autofill, cookie side-channels, and prompt-injected content in page text are all attack vectors before you ever click anything. The repo is ~3 weeks old (211 stars), there is no concrete SMB-ops browser task in scope today, and vetting a browser agent correctly requires a full sandbox, allowlist, and prompt-injection test suite — which costs more than any benefit it would deliver. The SMB-ops product is not yet real enough to justify opening that surface. SKIP stands.

**Minor correction to grok-build's kill metric**

"Mean absolute disagreement > 0.25" is the wrong kill trigger. For a binary decision endpoint (yes/no, duplicate/not), what matters is *decision flip rate* — how often the local model outputs a different discrete verdict than hosted Jev — and *false-"obvious" rate* on cases where debate was subsequently meaningful. A probability difference of 0.24 that always stays on the same side of the decision boundary is harmless; a difference of 0.10 that flips the verdict is not. The threshold should be on flips, not on probability distance.

**Minor disagreement with codex's experiment size**

≥500 labeled historical decisions before declaring a pilot is too expensive as a *kill* experiment. Kill criteria should be cheap: if LLM2Jev disagrees on decision verdict in >30% of the first 30 real shadow calls, or if the Mac mini swap pressure is measurable, kill it immediately. Expansion to 200+ paired items is the *keep* criterion before any calibration claim, not the entry requirement.

**oriveo: I maintain WATCH, aligned with claude**

AGPL blocks embedding; it does not block deploying it as a separate, unmodified, self-hosted operator client if SMB-ops ever needs one. SKIP is too strong. Practical action today is the same as WATCH — do nothing — but the license analysis should be correct in the record.

**Do first (unchanged):** Add `E3D_PILOT_JEV_SHADOW_LOCAL=1` to `lib/providers/jev.sh`, dual-log the next 30 real Noul + dedup calls against hosted Jev, measure flip rate. Kill if flip rate >30% or memory contention. Everything else waits.

POSITION: PILOT LLM2Jev in shadow mode only; SKIP fast-browser-use unconditionally; WATCH rizzo-flow and oriveo; SKIP DeepSeekGUI; no local probability gates anything until ledger-calibrated Brier score clears a preregistered threshold.
status: revise

## Round 2 -- grok-build

I'll check the Jev call sites and the RED-action rules so the round-2 verdict matches the repo, not just the prior writeups.The prior call holds, with one correction: twenty live pairs can kill this pilot. They cannot crown it.

**LLM2Jev — PILOT, and the only install.** Shadow it from the debate Noul pre-screen and `lib/ideas/jev_dedup.sh` via a second localhost URL logged beside hosted Jev. Leave `JEV_API_URL` on `https://api.typesafe.ai/v1/systemone`. Devin's "one env var swap" would aim `Authorization: Bearer $TYPESAFE_API_KEY` at the clone and replace the hosted call. His "≥80% agreement, then optional offline fallback" turns an uncalibrated score into behavior. Today a missing key fails open. That stays the outage path. Claude's kill at under 70% agreement and Codex's ≥500-replay prerequisite answer a later question. Replay the hosted answers you already have, then dual-log live calls, and drop the process if a bench slice fails, the shared mini swaps, or the mean absolute gap on yes/no probabilities exceeds 0.25. Keep the column until ledger outcomes exist: debate changed the verdict, dedup was later merged or closed. Spec-runner routing stays on tests and review. A typed "needs Codex" score is a later, escalate-only feature once those phase labels exist.

**rizzo-flow — WATCH.** Same interface, plus llama.cpp and a Spark LoRA their own README calls uncalibrated. Revisit only if the MLX path fails for a reason MLX cannot fix.

**fast-browser-use — SKIP.** Codex's WATCH still schedules a browser-agent experiment. Pilot and spec-runner have no web-action job, and a local model picking DOM actions inside credentialed CLI sessions is a RED surface. No VM test until an SMB-ops task names a read-only, allowlisted site.

**DeepSeekGUI — SKIP.** PolyForm Perimeter 1.0.1 on the product layer, no macOS build, no pipeline seam.

**oriveo — SKIP.** AGPL chat client. A possible future operator UI is not a reason to clone or embed it.

Pin the commit, safetensors only, Apache-2.0, own user, no API key, `127.0.0.1` only. Call it a local typed-decision endpoint.

Do this first: pin LLM2Jev, serve Qwen3.5-4B on MLX, dual-log the next real Noul and dedup calls. Install nothing else.

POSITION: Pilot only LLM2Jev as a fail-open shadow beside hosted Jev on the debate pre-screen and idea dedup; watch rizzo-flow; skip the other three; gate nothing until our own ledger outcomes calibrate it.
status: revise

## Round 3 -- claude

Remaining disagreement is small: oriveo (SKIP vs WATCH), fast-browser-use (SKIP vs WATCH), and kill thresholds. My position holds, and I'm adopting a few tightenings from the others.

**Kill criteria**
- Devin's point is correct: for a binary endpoint, the discrete verdict flip rate matters more than mean probability distance. Grok-build's 0.25 mean-absolute-gap rule can miss flips near the decision boundary, and it can fire on harmless same-side differences. I'm replacing my "agreement under ~70%" with a verdict-flip-rate kill, plus P95 latency over 1 s or measurable swap/contention on the shared mini.
- The replay set should be about 100 items, using hosted-Jev answers we already hold. That is cheap, costs no API calls, and gives a verdict in an afternoon. Devin's "30 live calls" is thinner than that and slower, because we'd wait for real traffic. Codex's 500 is too heavy for a kill test.
- Keep criterion: at least 200 paired items before any calibration claim. Gating needs far more, and the thresholds stay deterministic policy outside the model.
- Agreement with hosted Jev is diagnostic only. The real labels are our own ledger outcomes: did debate change the verdict, was the duplicate later merged or closed, did the Qwen attempt pass tests without rework.

**Integration seam**
Devin's original proposal, an env swap on `JEV_API_URL`, would send `TYPESAFE_API_KEY` to the clone and replace the hosted answer. Grok-build is right to reject it. We use a second `JEV_SHADOW_URL`, dual-logged, with no key sent and bound to 127.0.0.1. The hosted call and its fail-open behavior stay untouched.

**fast-browser-use: SKIP**
Codex's WATCH is defensible, but it implies a tracked follow-up with no committed web task behind it. A WATCH with no owner and no trigger is a SKIP. I'll reopen it when an SMB-ops task names a specific site, and then I'll use Codex's fixtures. Devin is right about the central risk. Single-token action selection over a live DOM is a model making policy decisions, which our architecture forbids, and it would run next to credentialed CLI sessions.

**oriveo: SKIP**
Devin's license analysis is correct: AGPL restricts embedding and modification, not running an unmodified self-hosted instance. That is worth recording. But no requirement exists, so the action today is nothing. I'll document the analysis in the debate record and not label it WATCH.

**Spec-runner**
Grok-build and Codex converge: nothing is built yet. Later, a local "escalate" signal may only add escalation. Tests and review stay the gate.

**Supply chain (unchanged)**
- Pin the SHA.
- Accept safetensors/GGUF only, with no pickle and no `trust_remote_code`.
- Take Qwen weights from upstream, not the clone's mirrors.
- Bind to localhost, with no credentials in the process.
- Check for telemetry and egress.
- Run it under its own user.
- Record that it is an unaffiliated clone of a commercial API.

Legal review is needed only if SMB-ops ships it.

**Do first**
Pin LLM2Jev, serve Qwen3.5-4B on MLX on localhost, add `JEV_SHADOW_URL` dual-logging to the debate pre-screen and dedup, and replay ~100 held hosted answers. Install nothing else.

POSITION: Pilot only LLM2Jev as a localhost shadow endpoint on a second URL (dual-logged, never gating), killed by verdict-flip rate, latency or Mac contention on a ~100-item replay, and skip fast-browser-use, DeepSeekGUI and oriveo with rizzo-flow on WATCH.
status: revise

## Round 3 -- codex

I changed one verdict: **fast-browser-use moves from WATCH to SKIP**. Claude, Devin, and grok-build are right that no concrete browser task currently justifies maintaining a high-risk experiment.

- **LLM2Jev — PILOT behind a flag.** Add `JEV_SHADOW_URL` beside—not instead of—hosted Jev in the e3d-debate Noul pre-screen and idea dedup. Dual-log candidate scoring later. After labels exist, spec-runner may record “Qwen needs escalation” as an escalation-only feature; deterministic tests and review remain authoritative. First replay roughly 100 historical cases, then collect at least 200 task-specific outcome-linked shadows. Hosted-Jev agreement is diagnostic, not truth. Before any gate, require acceptable Brier score, reliability/ECE, discrimination, threshold-specific false-positive costs, and drift against actual ledger outcomes: useful debates, confirmed duplicates, candidate success, and Qwen rework. Debate skipping particularly requires a near-zero false-“obvious” rate.

- **rizzo-flow — WATCH.** It fits the same seams but replaces nothing: its explicitly uncalibrated custom model and weaker Mac fit do not justify a second pilot. Run the identical frozen replay only if LLM2Jev fails operationally or rizzo-flow later demonstrates compelling in-domain evidence.

- **fast-browser-use — SKIP.** It has no present pilot/spec-runner seam. Reconsider only for a named SMB-ops task with deterministic action policy outside the model. The eventual kill/justify experiment is a disposable, credential-free browser profile, fake data, domain/action allowlists, prompt-injection fixtures, and zero RED actions. “Read-only” browsing still exposes cookies, redirects, autofill, and injected page content.

- **DeepSeekGUI — SKIP.** It adds no needed primitive, lacks the relevant Mac product, and PolyForm Perimeter creates unacceptable competitive-product risk. If a harness gap emerges, evaluate only the separately MIT-licensed upstream harness.

- **oriveo — SKIP.** It is commodity chat, not routing or governed execution; AGPL complicates embedding and modification. Reopen only if a mobile approval inbox becomes a committed SMB-ops requirement, starting with a requirements-only comparison rather than deployment. Devin is legally correct that separate unmodified deployment may be possible, but WATCH still creates needless attention today.

Vetting must pin commits and dependency hashes, generate an SBOM, audit licenses/telemetry/egress, bind localhost, isolate credentials and filesystem, reject pickle and `trust_remote_code`, accept verified safetensors/GGUF from upstream provenance, benchmark shared-Mac contention, and document the unaffiliated API compatibility claim. Shipping changes would require legal review.

Do first: pin LLM2Jev on MLX and run the frozen replay before changing live call paths.

POSITION: Pilot only LLM2Jev as a non-gating localhost shadow, watch rizzo-flow, and skip fast-browser-use, DeepSeekGUI, and oriveo.
status: revise

## Round 3 -- devin

**Positions now stable enough to close on the two remaining disagreements.**

**Where all four agree — done:**
LLM2Jev PILOT (shadow, dual-log, gates nothing). rizzo-flow WATCH. DeepSeekGUI SKIP.

**fast-browser-use: SKIP (rebut codex's WATCH)**

Codex's "bounded, read-only SMB-ops sandbox" framing is the correct test condition. But there is no committed SMB-ops browser task. A WATCH verdict means creating a tracking entry and a follow-up owner — that is real cost paid now for a requirement that does not exist. The correct action is SKIP and reopen when a named task arrives; at that point codex's own fixture checklist (no credentials, allowlisted domains, injection tests, disposable VM) is exactly right. Keeping it on the WATCH list does not accelerate that by one day.

**oriveo: maintain WATCH, not SKIP**

Claude and grok-build moved to SKIP. The practical action today is identical (install nothing), but the license analysis should be right in the record: AGPL bars embedding; it does not bar deploying oriveo as a separate, unmodified, self-hosted operator client. SMB-ops has a confirmed strategic direction toward governed human approvals, and a mobile multi-model approval inbox is a plausible near-term surface. WATCH preserves the option without spending anything. SKIP buries a correct analysis behind a verdict that overstates the bar.

**Accept grok-build's technical correction on shadow plumbing**

My round-1 phrasing ("one env var swap") implied swapping `JEV_API_URL`. That would replace hosted Jev and silence the outage path. The right implementation: add a second `JEV_SHADOW_URL` env var, log both responses, keep `JEV_API_URL` pointed at `https://api.typesafe.ai/v1/systemone`. The primary answer stays hosted. Grok-build is correct here.

**Kill criterion: flip rate, not MAD**

Grok-build's "MAD > 0.25 kills it" is wrong as stated (a 0.24 gap that always stays on the same side of the decision boundary is harmless; a 0.10 gap that flips the discrete verdict is dangerous). Kill trigger is flip rate on discrete verdicts — yes/no decision disagreement in more than 30% of the first 30 live shadow pairs. Claude's 100-item replay-first approach is cleaner statistically but depends on having well-labeled historical items; live shadow starts producing signal immediately. Do the replay only if we have labeled items in hand; otherwise start live dual-logging immediately and apply the 30-pair kill check first.

**Single first action (unchanged):** Add `JEV_SHADOW_URL` (localhost LLM2Jev on MLX) to `lib/providers/jev.sh`, dual-log the next real Noul pre-screen and dedup calls without touching the primary path, measure flip rate on the first 30 pairs. Kill if flip rate > 30% or Mac mini shows memory contention. Everything else waits.

POSITION: Pilot LLM2Jev as a non-gating localhost shadow (second URL, dual-logged) with a 30-pair flip-rate kill check; watch rizzo-flow and oriveo; skip fast-browser-use, DeepSeekGUI, and oriveo integration until concrete requirements exist.
status: revise

## Round 3 -- grok-build

I'll check the Jev call seam so the kill rule and the shadow URL match the repo, not just the prior writeups.I changed one rule. Devin is right that a probability gap which stays on the same side of the decision is harmless and a small gap that flips the verdict is not, so mean absolute disagreement above 0.25 is the wrong statistic. Codex is right that agreement with hosted Jev is not the truth. Flip rate gets logged. It does not stop the pilot.

A high flip rate is when the shadow is worth keeping. Hosted Jev is already advisory and uncalibrated against our ledger. If the local endpoint disagrees on 30% of the first 30 calls, those pairs are exactly what later outcome labels — debate changed the verdict, dedup was merged or closed — have to judge. Devin's rule deletes the sample when it becomes informative. Claude's kill below about 70% agreement on a 100-item replay makes the same mistake with a larger n. Twenty or thirty live calls can kill the process if the shared 24 GB mini swaps, the server crashes, or latency is unusable next to the other Qwen workloads. They cannot support a quality verdict either way.

LLM2Jev is still the only install: PILOT, shadow only, fail-open, gates nothing. `JEV_API_URL` stays `https://api.typesafe.ai/v1/systemone`. `lib/providers/jev.sh` sends the TypeSafe bearer token there, so a second `JEV_SHADOW_URL` on `127.0.0.1` gets no key and is never read by control flow. Replay about 100 existing hosted decisions as an operations smoke test, then dual-log the live Noul pre-screen and `lib/ideas/jev_dedup.sh` until at least 200 paired items and real ledger outcomes exist. Brier score, reliability, and the cost of a false "obvious" are the calibration claim. Spec-runner gets no code in this spike. A later "needs Codex" score may only add escalation. Tests and review stay the gate.

rizzo-flow stays WATCH. Same interface, an uncalibrated Spark LoRA, and a worse fit than MLX on this Mac. A second pilot only if MLX fails for a reason MLX cannot fix.

fast-browser-use stays SKIP. Single-token selection over a live DOM is policy inside the model, which these debates already keep outside it. Codex's WATCH still reserves a sandbox experiment. Pilot and spec-runner have no web-action job, and RED actions plus prompt injection make that experiment cost more than any unnamed SMB-ops task. Reopen it only when a task names a read-only, allowlisted site.

DeepSeekGUI stays SKIP: PolyForm Perimeter on the product layer, and no macOS build. oriveo stays SKIP. Devin's watch-but-do-nothing is the same action today. AGPL still bars embedding, and there is no committed approval inbox. No legal review for a localhost process that is not shipped. Pin the commit, use upstream Qwen safetensors, Apache-2.0, localhost only.

Do this first: pin LLM2Jev, serve Qwen3.5-4B on MLX, replay about 100 hosted answers for operations, then dual-log. Install nothing else. Do not turn the process off because it disagrees with Jev.

POSITION: Pilot only LLM2Jev as a fail-open localhost shadow beside hosted Jev on the debate pre-screen and idea dedup, logging flips but killing only on operational failure; watch rizzo-flow; skip the other three; gate nothing until our own ledger outcomes calibrate it.
status: revise


## Synthesis (claude)

FINAL ANSWER: Pilot LLM2Jev only, as a fail-open, advisory shadow on a second localhost URL (`JEV_SHADOW_URL`) beside hosted Jev. It covers the e3d-debate Noul pre-screen and idea dedup, and it is dual-logged and gates nothing. Do this first: pin the commit, serve Qwen3.5-4B on MLX with upstream safetensors only, bind to 127.0.0.1, send no `TYPESAFE_API_KEY`, and replay about 100 held hosted-Jev answers. Kill it on operational failure: contention on the shared Mac mini, latency, or crashes. Keep it until at least 200 paired items have ledger outcomes (debate changed the verdict, duplicate merged or closed, Qwen attempt passed without rework). Any later gate needs Brier score, reliability and a near-zero false-"obvious" rate, with thresholds in deterministic policy code outside the model. In spec-runner, a local score may only add escalation to Codex and never suppress it. Put rizzo-flow on WATCH, because LLM2Jev already has the MLX path and rizzo-flow's probabilities are uncalibrated. SKIP fast-browser-use (a model picking DOM actions beside credentials is a RED surface, and no named task needs it), DeepSeekGUI (PolyForm Perimeter bars competing products, and there is no macOS build) and oriveo (AGPL, no committed requirement).
CONSENSUS: majority
DISSENT: Devin wanted oriveo on WATCH; the other three had it at SKIP. Grok-build wants to kill the pilot only on operational failure, while Claude and Devin also kill it on a high verdict-flip rate against hosted Jev. All four agreed on the LLM2Jev pilot itself.
