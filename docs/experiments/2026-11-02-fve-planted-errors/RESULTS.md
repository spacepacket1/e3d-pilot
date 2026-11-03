# F vs E on planted errors (2026-11-02): inconclusive

**Question.** With the vendor held fixed (one model on all seats), do three different lenses (arm F) find more planted errors than three seats with the same prompt (arm E)? This is the first comparison of the plan in [`experts-phase0-overlap-map-and-eval-plan.md`](../../specs/experts-phase0-overlap-map-and-eval-plan.md) section 4, and row "F vs E" of [the methodology draft](../../methodology/expert-councils.md).

**Result: no detectable lift.** Union catch rate (an error counts when any of the three seats names it): **E 56.5%, F 59.3%**. Paired lift **+2.8 points** (5% of baseline), 95% bootstrap interval **[-4.6, +10.2] points** over 12 tasks. The pre-registered bar needs at least 15% of baseline with an interval above zero: **not met**. Cost per debate: E 4,295 tokens, F 4,678 (**1.09x**). False alarms were **not measured**, so the full decision rule (E7) could not be met in any case. Status: **inconclusive**, no claim that lenses help or do not help.

## What was run

- 12 short documents (about 130 words) written by a model (me), each with 3 planted errors (36 in all). `experiments/fve/tasks.mjs`.
- One model, `claude-haiku-5-5` (thinking off), on 3 seats via the anthropic-api adapter and the test seam `E3D_DEBATE_SEAT_ADAPTERS`; round 1 only, web search off, synthesis not scored. E: no experts. F: `skeptic`, `customer`, `architect`, one per seat.
- **Each seat's answer was capped at 220 tokens.** Uncapped, a single seat caught 71 of 72 planted errors (a ceiling: no arm could show lift), the same problem as the October pilot. With the cap a single seat catches 38% (27/72), which leaves room. The cap is a real constraint (the engine has per-seat answer limits) but it is also what makes the test sensitive, and it means the result is about **what gets listed first under a tight budget**.
- 6 repeats x 12 tasks x 2 arms = 144 debates, shuffled, 646,016 tokens (about 0.78M with the probes, under the 1M cap). Raw rows: `results.jsonl`. Analysis: `experiments/fve/analyze.mjs` (`analysis.txt`).
- **Scoring is mechanical**: an error is caught when an answer contains a flag word and every pattern in the error's key (the specific conflicting figures). Same scorer for both arms. A spot check of the two largest movers found the matches real, but the scorer is not validated beyond that.

## What the data say

- **The lenses redistribute attention more than they add to it.** Per task, F minus E ranged from -28 to +33 points. On t01 the arithmetic slip (15 x $240) was caught in 6/6 E debates but 1/6 F debates: seats given a lens stopped checking basic arithmetic under the cap. On t10 "three days is too short" was caught 6/6 in F and 1/6 in E: a lens raised a point the generic seats skipped. The average nearly cancels.
- **The coverage model fits.** Fitted per-seat catch rate and correlation of misses: E `p`=0.47, `rho`=0.75, n_eff 1.20, predicted union 53.3% (observed 56.5%); F `p`=0.45, `rho`=0.59, n_eff 1.37, predicted 55.7% (observed 59.3%). The model predicts within about 3.5 points on this data (fitted on the same data, so this is a consistency check, not a held-out test).
- **Lenses lowered `rho`, as hypothesised, but not by much** (0.75 to 0.59). Three seats of one model behave like 1.2 to 1.4 independent seats. Four vendors (arm D) were not tested.

## Limits

One model; 12 tasks written by one author; planted errors, not real decisions; a 220-token cap; no false-alarm measure; keyword scoring; round 1 only. The interval is wide enough to include a 10-point lift. These results say nothing about vendor diversity (D vs F) or about whether a council beats one model (B vs A).

## What it suggests (hypotheses, not findings)

1. Pair lenses with a generalist seat, so the basic checks are not displaced. Worth testing: F' = two lenses plus one plain seat, against E and F.
2. If the next question is vendor diversity (D vs F), run it with the same tasks and cap: about 4,500 tokens a debate, so 144 debates is roughly 0.65M tokens.
3. Measure false alarms before any claim: the current scorer cannot.
