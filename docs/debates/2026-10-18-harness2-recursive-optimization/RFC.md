# RFC: Harness² for E3D recursive optimization

Status: draft, research only (nothing implemented). Idea: idea-2a3a473006c2. Evidence: [transcript.md](transcript.md) (claude + codex, 2 rounds, claude synthesis).

## Recommendation: (C) — implement the idea in E3D, do not adopt Harness² code
Harness² is best treated as a *design reference*, not a dependency. Its loop (propose edits → probe on the same task → compose from trajectory contrasts, score-free selection, judge only after commit) is simple enough to reproduce as a small bash/Node overlay. Adopting it directly would need a Python 3.12/uv/gcloud/Linux stack, a ~12-method `BenchmarkAdapter` in Python, and executors with unrestricted network access (Codex sandbox disabled per its README) — all against a Mac bash/Node pipeline holding private repos. The reported gains (+4.5 to +11.8 pts) are self-reported on Google's own benchmarks and say little about E3D.

Answers to the key questions
1. Optimize without replacing orchestration? Yes, if the editable surface is limited to the execute-phase prompt and tool guidance, loaded from a file, with guardrails and the evaluator read-only.
2. Adapters: none for Harness² itself under (C). Only a replay runner: frozen task → run with harness variant → collect tests/ledger outcome.
3. Do debate/ledger/brain help? Ledger outcomes (merged / failed / rejected, tests) are real ground truth that Harness² deliberately lacks — the main E3D advantage, and also the main Goodhart risk. Debate is useful as a critic of proposed edits. e3d-brain: skip (retrieval, not an agent harness).
4. Smallest experiment: below.
5. Security/licensing: Apache-2.0 permits reuse with notices; audit `third_party/` and dataset licenses separately. Run in a disposable, network-denied sandbox; treat repo text, debate output and brain notes as prompt-injection input.

## Minimal proof of concept
- Precondition: confirm the execute-phase prompt loads from a file; if not, or if fewer than ~10 replayable tasks exist, defer (D).
- Tasks: ~10–12 frozen, secret-free historical tasks; 4 sealed as held-out.
- Arms: baseline vs. one candidate harness edit, 3 runs per arm to measure noise.
- Score: tests + ledger outcome (not model self-judgment).
- Cap: $50–60 and two hours.
- Pass: candidate wins ≥2 more of the 4 sealed tasks, regresses none, beats 2× baseline noise, cost per task ≤ +20%. A pass authorizes a larger replication, not adoption.
- Stop immediately on: secret access, network escape, publish attempt, evaluator leakage, weakened guardrail.

## Preserved dissent
- Claude's final position is "D plus a minimal C experiment" and would build a plain proposer loop; Codex moved from B (adapt components, Python adapter) to C. Claude opposed a Python adapter around Harness²; Codex initially favored it.
- Shared residual (pure D): 4 sealed tasks cannot establish significance, and historical outcomes came from the old harness, so replays aren't independent.
- Caveat: the synthesis attribution check flagged one quoted string not found verbatim in the transcript.

## Do NOT build
A generic 8-component framework, an improvement-harness service, a dashboard, or auto-adoption of edits/lessons.
