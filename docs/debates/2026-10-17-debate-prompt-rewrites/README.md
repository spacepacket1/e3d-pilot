# Should we fix the debate prompts, and how much should we test first?

Four models (claude, codex, grok-build, devin) debated for two rounds, and claude synthesized the verdict. The question came from [`docs/prompt-review-2026-10.md`](../../prompt-review-2026-10.md), a review of every prompt in e3d-pilot and e3d-corp. Full text: [`transcript.md`](transcript.md). Ledger idea: `idea-3cbb718c4377`.

## The question

The review found two structural flaws in the debate prompts:

1. In round 2 a speaker is shown its **own** round-1 answer, labelled with its provider name as if someone else had written it. Models sometimes rebut themselves.
2. The prompts never say that rounds are **simultaneous**. Models accuse each other of ignoring points that had not been published yet, and in one debate this fooled the judge.

Options: (a) fix both now and skip any experiment, (b) fix behind a flag and run a small ~60-call pilot (about $2-4) first, (c) run the full ~900-call experiment first (about $27-63 and 2-3 hours of blind human rating), (d) leave the prompts alone.

## Verdict (consensus: majority)

**(b), with the scope split.**

- **Ship now, as the default, with no flag and no experiment:** relabel the speaker's own answer as "YOU" and add one sentence saying rounds are simultaneous, in round 2+ and in the synthesizer prompt. Stamp a `prompt_version` on every transcript so old and new transcripts are never mixed in statistics.
- **Behind a flag, pilot first:** only the broader R1-R3 rewrite (steelmanning, `AGREES_WITH`, computed convergence, structured synthesis). Run the 3-question x 3-variant pilot before promoting it.
- **Measure mostly with deterministic checks:** self-rebuttal, impossible "you ignored X" claims, synthesis quotes that are absent from the attributed section, narration leaks, and whether spec-reading is preserved. Add planted-trap fact sheets and a blinded human rating. A debater or the synthesizer is never the primary judge.
- **First three steps:** (1) relabel + simultaneity sentence + `prompt_version`; (2) strip process narration narrowly, checking that spec-reading doesn't drop, plus an attribution linter; (3) the flagged pilot.
- **Postponed:** the 900-call run, specialists and `--panel`, the roster health report. Cap the whole effort at about one day and under $5.
- **Next action:** one PR in `bin/e3d-debate` with the relabel, the simultaneity sentence and `prompt_version`.

## Who said what

| | Round 1 | Round 2 |
|---|---|---|
| claude | (b), both fixes behind `--prompts v2` | Conceded to Grok: ship the two fixes with no flag. Treats its answer as (a) for the fixes and (b) for the rewrite. |
| codex | (b), attribution checker first | Holds (b). Wants the fixes behind the flag until the pilot shows no regression, and measurement built before changes. |
| grok-build | (a), no flag at all | Holds (a). Says bundling the two-line fix with the rewrite is the mistake, because a 3x3 on the full rewrite cannot show whether the label fix worked. |
| devin | (b), both fixes behind a flag | Conceded to Grok: fixes unconditional, experiment only for the broader rewrite. |

## Dissent

- **Grok-build** holds (a) and wants no flag at all, only a replay switch for the old prompts.
- **Codex** wants the two fixes behind `--prompts=v2` until the pilot shows no regression. It also wants the measurement and attribution checks built before the prompts change, because narration filtering can erase useful grounding evidence.

## Highlights

- **Three of four models changed position in round 2, all toward Grok.** The argument that moved them: you cannot A/B "stop mislabelling the speaker's own text." The evidence is in the prompt code, not in a statistical comparison.
- **Grok checked the code and it holds.** `bin/e3d-debate:165-167` loops over every provider, including the speaker, and prints each under `--- $other (previous round) ---`. I confirmed these lines when writing this page.
- **A new constraint came out of round 2:** don't change `POSITION`, `status` or `DISSENT`, because the MCP tools publish them as a contract. The two-line fix doesn't touch them, but the broader rewrite would.
- **Narration stripping is not a blunt delete.** Grok points out that 16 of the 17 leaks come from the same provider that actually reads the specs, so a "do not narrate" rule could suppress the grounding we want.

## Caveats

- This debate ran with the flaw it discusses: in round 2 each model was shown its own round-1 answer labelled as a peer's. Both of the round-2 concessions to Grok were made in that setting.
- Only Grok and Devin visibly cited the repo code or the earlier transcripts. I did not check Devin's line references into earlier transcripts.
- Claude wrote the synthesis and is also a debater. Its "(b), but split the scope" label blends (a) and (b), which the dissent notes record.

## Links

- Transcript: [`transcript.md`](transcript.md)
- Source review (candidate tickets and experiment plan): [`docs/prompt-review-2026-10.md`](../../prompt-review-2026-10.md)
- Related ledger ideas: `idea-79378bb3da4c` (attribution check for debate verdicts), `idea-135c127951d5` (strip agent narration)
