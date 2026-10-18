# Debate prompt pilot: results (stage 1)

Idea `idea-3cbb718c4377`. Debate that set this up: [`../../debates/2026-10-17-debate-prompt-rewrites`](../../debates/2026-10-17-debate-prompt-rewrites/README.md).

**Setup.** 3 questions x 3 prompt variants = 9 debates, 2 rounds, 3 voices, claude (`anthropic-api`, claude-sonnet-5-5) as synthesizer in every run. Panel: claude (`anthropic-api`), gpt-5.5 (`openai-api`), grok-build (CLI).
- **A = `v2`**: today's prompts plus the own-answer relabel and the simultaneity sentence (already shipped).
- **B = `v3b`**: rewritten round 1 and round 2+ prompts (review R1, R2).
- **C = `v3c`**: B plus the rewritten judge prompt (review R3).
- Questions: `q1-federated` (the federated-intelligence note, replayed), `q2-spec-review` (the FutCo ad-mandate spec, inlined), `q3-fact-sheet` (a fact sheet with 3 planted errors).
- One run per cell. There are no repeats, so run-to-run noise is not measured. Everything below is a smoke test, not a ranking.

**Cost.** 45 metered calls (claude + gpt-5.5; grok-build's CLI spend is not measured): 331,766 input and 65,506 output tokens in total. I did not look up prices for these two models, so I am not stating a dollar figure; the budget I proposed was $2-4.

## Deterministic measures

| Run | Answers' words (6 answers) | Synthesis words | Early convergence |
|---|---|---|---|
| Q1 A / B / C | 3,142 / 2,534 / 2,356 | 200 / 200 / 353 | none / none / none |
| Q2 A / B / C | 2,843 / 2,419 / 2,551 | 255 / 290 / 521 | none / none / none |
| Q3 A / B / C | 2,385 / 2,201 / 2,213 | 169 / 227 / 544 | none / none / none |

- **B and C debaters write 7-25% fewer words** than A. C's synthesis is 1.8-3.2x longer than A's, because it adds per-analyst positions, dissent and checked claims.
- **Early convergence: 0 of 9.** No run converged in round 2 under any variant, so the derived `status` lines in B and C were never what ended a debate. This pilot says nothing about false convergence.
- **Narration is not fixed by the prompts.** Both B and C tell the model "output only the answer: do not describe your process". Only grok-build narrated ("I'll read the e3d-brain specs first…"): 7 of its 18 answers began with narration, 2 in A, 2 in B, 3 in C, none from the other two providers. The instruction made no measurable difference, so stripping it in code (idea-135c127951d5) is still needed.
- **Attribution.** I checked the verbatim quotes in C's per-analyst POSITIONS and DISSENT lines against each analyst's own text: 13 of 15 came from their final round, 2 came from their round 1 (the prompt asks for the final round), and none were invented. Quotes in the other variants' prose were scare quotes, not per-analyst attributions, so there is no like-for-like comparison.
- **Planted traps (Q3): no signal.** All three errors ($30 should be $90; 4 calls per debate should be 7; the 150,000 token cap should be 100,000) were caught in every variant's round 1 by at least two of the three models, and in every synthesis. The test was too easy to separate the variants. If we run it again, the traps need to be subtler.

## Verdicts differ by variant on Q1

| | A | B | C |
|---|---|---|---|
| Q1 | (b) a trimmed note, CONSENSUS: full | (c) defer, majority | (d) do not include, majority |
| Q2 | (c) hold | (b) approve with changes | (c) hold |
| Q3 | (c) lower | (c) lower | (c) lower |

Q1's three runs reach three different verdicts. With one run per cell I cannot tell prompt effect from ordinary run-to-run variance, which is the main reason to repeat before drawing any conclusion. The original 4-model debate on this question (with codex and devin) chose (b) by majority.

## What this supports and what it does not

- **Supported:** B and C work mechanically (all 9 runs completed, MCP-compatible output, derived lines parse). B does not cost more tokens than A. C costs a little more in the synthesis.
- **Not supported:** that B or C gives better decisions. No quality measure has been applied yet. That needs your blind rating, with two cautions: C's output has a different shape, so it is partly recognisable even with labels hidden, and one run per cell cannot separate the variants from noise.

## Next, if you want it

1. Rate [`blind-sheet.md`](blind-sheet.md): three verdicts per question, random order, about 30 minutes. The key is in `blind-key.json` (not committed; open it after rating).
2. Repeat each cell 2 more times (about 54 more calls) to measure run-to-run variance, and replace Q3 with subtler traps.
3. Strip grok-build's narration in code, which the prompts did not do.

Files: `run.sh` (how it was run), `analyze.py` and `metrics.json` (token and word counts), `runs/<question>-<variant>/transcript.md` (full transcripts and stderr).
