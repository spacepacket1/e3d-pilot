# Jev over 10 past debates (2026-11-03)

A one-off replay behind [docs/jev-council.md](../../jev-council.md), the evidence for its provisional bands. It measures **agreement with what the council decided, not correctness**: there are no real outcomes here.

## Method

- 10 recorded debates (`docs/debates/`) that reduce to a yes/no position. For each I wrote one neutral statement P and its plain-language negation, and gave Jev the original debate question as context with the statement (`state: {question, statement}`), one `Noul` call per statement (`jev-latest`, instructions: judge whether the statement is the right position to take).
- "Council" is the headline stance on P read from each debate's `FINAL ANSWER`. Verdicts are usually conditional, and a one-line statement flattens them.
- 3 sanity pairs with obvious answers, and 3 repeat calls to check stability. 29 calls, about 18.7k input and 0.6k output tokens.

## Results

| debate | council on P | Jev P | Jev not-P | polarity consistent | band (provisional thresholds) |
|---|---|---|---|---|---|
| 2026-09-06-discovery-mode-reframing | N (majority) | 0.18 | 0.76 | yes | decisive_no |
| 2026-09-06-shared-cognition-vs-insight-mode | N (majority) | 0.25 | 0.48 | no | undecided |
| 2026-09-07-e3d-graph-generalization | N (majority) | 0.35 | 0.39 | no | undecided |
| 2026-09-07-hugging-face-strategy | N (majority) | 0.81 | 0.15 | yes | decisive_yes |
| 2026-09-15-gemini-qwen-provider-addition | Y (full) | 0.42 | 0.42 | no | undecided |
| 2026-09-16-linear-work-management-layer | N (majority) | 0.67 | 0.44 | yes | undecided |
| 2026-09-22-jev-debate-gate | Y (majority) | 0.76 | 0.27 | yes | decisive_yes |
| 2026-09-27-openrouter-provider-adapter | Y (majority) | 0.46 | 0.49 | no | undecided |
| 2026-10-06-e3d-ai-appliance | N (majority) | 0.17 | 0.77 | yes | decisive_no |
| 2026-10-08-decision-memory-as-product | N (majority) | 0.18 | 0.62 | yes | decisive_no |

- Agreement with the council headline using P alone: **6/10** (the negation gives 6/10 too).
- Bands that are decisive: 5/10; of those Jev agrees with the council on 4. The other 5 are `undecided` (inconsistent pair, or between 0.3 and 0.7): where the council needed a conditional answer, Jev was not decisive.
- Sanity pairs: decisive and consistent (0.97-0.99 for the obvious yes, 0.02 for "store passwords in plaintext", negations mirrored). Repeat calls moved by about 0.02.

## Caveats

- n = 10, one author wrote all statements, no outcomes, the council stance is one reader's summary. The two clear disagreements (Hugging Face, Linear) may be wording: the councils' verdicts were conditional.
- The 0.7 / 0.3 thresholds were chosen after seeing these results, so they fit them. They are provisional and need recalibrating on outcomes, ideally on debates not used here.
- Noul is used as returned by Jev. It is not a calibrated probability.

`results.json` holds the raw values.
