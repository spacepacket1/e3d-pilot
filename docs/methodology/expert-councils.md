# Expert Councils: seats, skills and the cost of disagreement

**Methodology draft 1, 2026-11-01.** Status: a seed for a paper in the style of the E3D methodology page (numbered papers, notation, equation cards, results marked *pending* until measured). **Nothing in section 5 has been measured.** The equations are models, the numbers in section 3 are illustrations, and both are labelled as such throughout.

**Where it sits.** Paper 1 (OTA v1) and Paper 2 (the Decision Layer) concern on-chain signal. This draft concerns the debate engine: how a council of AI seats is formed from skills, what it costs, and how we would know it helps. Proposed as Paper 3; the name and where it is published are the owner's to decide.

## 1. Definitions

| Term | Meaning |
| --- | --- |
| **Adapter** `a` | A provider script that answers a prompt (for example `claude`, `codex`, `gemini-api`). |
| **Vendor family** `f(a)` | The company behind an adapter (Anthropic, OpenAI, Google, xAI). Two adapters can share a family. |
| **Skill** `s` | An *expert*: a reusable lens, written as a standard Agent Skill folder (`SKILL.md`), that tells a seat what to look for. |
| **Seat** | One participant for the whole debate: a pair `(a, s)`. One adapter can hold several seats; one skill is named once. |
| **Round** | One pass in which every seat answers once. Round 1 is independent; later rounds read the other seats' previous answers. |
| **Council** | The set of seats, plus a synthesis call that writes the verdict with consensus and dissent. |
| **Multi-model** | A council on two or more vendor families. A council on one family is labelled as such and is never called multi-model. |

## 2. Equation cards

**E1. Panel.** A council is a set of distinct skills, each on one adapter.

$$P = \{(a_i, s_i)\}_{i=1}^{n}, \qquad s_i \ne s_j\ (i \ne j), \qquad n \le n_{\max} = 6$$

*Choose skills, not models: you name the skills and the engine assigns the adapters. The cap `n_max` bounds cost.*

**E2. Assignment.** Each skill goes to the adapter that is least used, vendor first.

$$a_i = \underset{a \in \text{pool}}{\arg\min}\ \bigl(\,\text{seats}(f(a)),\ \text{seats}(a),\ h_i(a),\ \pi(a)\,\bigr) \quad\text{(lexicographic)}$$

*Fewest seats in the vendor family, then fewest on the adapter, then the skill's model hint `h_i` (a tie-break only), then pool order `π`. `skill:adapter` overrides it.*

**E3. Token cost.** `Q` question, `B` fixed prompt text, `L` lens block, `A` an answer, `S` the synthesis output, `n` seats, `r` rounds.

$$\text{In} = n(Q{+}B_1{+}L) + (r{-}1)\,n\,\bigl(Q{+}B_2{+}L{+}(n{-}1)A\bigr) + (Q{+}B_s{+}nrA), \qquad \text{Out} = nrA + S$$

$$T(n, r) = \text{In} + \text{Out}, \qquad \text{calls} = nr + 1$$

*The `(n-1)A` term is why cost grows faster than the seat count: from round 2 every seat reads every other answer. A skill on an existing seat adds only `nrL` tokens; an extra seat adds a whole call every round.*

**E4. Effective seats.** Seats that miss the same things count for less.

$$n_{\text{eff}} = \frac{n}{1 + (n-1)\rho}$$

*`rho` is the average correlation between seats' misses: 0 for independent seats, 1 for identical ones. Four seats on one model are close to one seat.*

**E5. Coverage.** The chance the council catches a given problem, if one seat does with probability `p`.

$$P(\text{caught}) \approx 1 - (1-p)^{\,n_{\text{eff}}}$$

*A rough model, not an exact one. The hypothesis behind skills is that a lens lowers `rho` between seats on one model.*

**E6. Lift and its uncertainty.** `S_X(t)` is a score on task `t` (for example the share of planted errors caught); `m` tasks, `k` repeats each.

$$\Delta = \mathbb{E}_t\bigl[S_X(t) - S_Y(t)\bigr], \qquad \text{SE} \approx \frac{\sigma_d}{\sqrt{m}}, \qquad \sigma_d^2 \approx \sigma^2_{\text{task}} + \frac{\sigma^2_{\text{run}}}{k}$$

*Run-to-run noise is large (one question gave three verdicts in the October pilot), so every comparison needs repeats.*

**E7. Decision rule.** Pre-registered before any result is seen.

$$\text{ship}\ X \iff \Delta \ge 0.15\,\bar S_Y \ \ \wedge\ \ \Delta - 1.96\,\frac{\sigma_d}{\sqrt{m}} > 0 \ \ \wedge\ \ \frac{T_X}{T_Y} \le 3 \ \ \wedge\ \ \text{FP}_X \le 1.10\,\text{FP}_Y$$

*A lift of at least 15% of the baseline, an interval that excludes zero, at most three times the cost, and false alarms no more than 10% worse. Otherwise the result is "inconclusive" and no accuracy claim is made. The bar is not loosened afterwards.*

**E8. Cost per extra finding.**

$$\kappa = \frac{T_X - T_Y}{F_X - F_Y}$$

*Tokens spent per additional valid finding, `F` being verified unique findings.*

## 3. Worked numbers

Constants (assumptions for a short question, not measurements): `Q`=100, `B1`=300, `B2`=500, `Bs`=400, `L`=130, `A`=300, `S`=400 tokens. Computed by `lib/debate/cost-model.mjs`; `tests/methodology-cost-model.sh` fails if this table drifts from the model.

**Cost, in tokens:**

| Council | Seats | Rounds | Calls | Total tokens | vs plain 4 seats, 2 rounds |
| --- | --- | --- | --- | --- | --- |
| 2 seats, no skills | 2 | 2 | 5 | 5,900 | 0.4x |
| 4 seats, no skills (today's council) | 4 | 2 | 9 | 13,300 | 1.0x |
| 4 seats, a skill each | 4 | 2 | 9 | 14,340 | 1.1x |
| 3 skills, all on one adapter | 3 | 2 | 7 | 10,080 | 0.8x |
| 6 seats (the cap) | 6 | 2 | 13 | 24,660 | 1.9x |
| 8 seats (above the cap) | 8 | 2 | 17 | 37,380 | 2.8x |
| 8 seats, one round (breadth only) | 8 | 1 | 9 | 9,940 | 0.7x |
| 4 seats, one round | 4 | 1 | 5 | 5,420 | 0.4x |
| 4 seats, three rounds | 4 | 3 | 13 | 23,260 | 1.7x |
| 4 seats, four rounds | 4 | 4 | 17 | 32,180 | 2.4x |

Dollars are the same sums with each vendor's price per input and output token, which this draft does not state.

**Coverage, illustrative** (`p` = 0.4, `n` = 4; one seat alone gives 0.40):

| Seats are | rho | n_eff | P(caught) |
| --- | --- | --- | --- |
| fully independent | 0 | 4.0 | 0.87 |
| somewhat alike | 0.5 | 1.6 | 0.56 |
| very alike (one model) | 0.8 | 1.2 | 0.45 |

## 4. Measurement matrix

Rows are the arms, each a council setup; every comparison changes one thing.

| Arm | Setup | Comparison | What it isolates |
| --- | --- | --- | --- |
| A | one strong model | baseline | |
| B | today's 4 vendors, no skills | B vs A | does a council beat one model? |
| E | one model sampled three times and merged | E vs B | vendor diversity, or just more samples? |
| F | one model, three skills | **F vs E** | **do skills add anything, vendor held fixed?** |
| D | skills spread over 4 vendors | D vs F | what vendor spread adds on top of skills |
| C | random skills | C vs D | whether choosing skills well is worth anything |

Columns: planted errors caught (scriptable, no grading); unique valid points and false alarms (a person and a second model verify); verdict differs from the baseline (scriptable); run-to-run stability (three repeats); tokens and wall time. Tasks: 40 to 50 for the full run, with ground truth where it exists (planted errors, known outcomes) and a blind grader where it does not. The protocol, the staging (a cheap Stage 0 first to measure noise) and the pre-registered thresholds are in `docs/specs/experts-phase0-overlap-map-and-eval-plan.md`; the first test proposed is F vs E on planted errors, about 0.5 million tokens by the model above.

## 5. Results

| Comparison | Delta | 95% interval | Cost ratio | Status |
| --- | --- | --- | --- | --- |
| B vs A | pending | pending | pending | not run |
| E vs B | pending | pending | pending | not run |
| F vs E | +2.8 points (5% of baseline) | -4.6 to +10.2 points | 1.09x | run 2026-11-02: inconclusive |
| D vs F | pending | pending | pending | not run |
| C vs D | pending | pending | pending | not run |

*F vs E was run once on 12 planted-error tasks (one model on three seats, 220-token answers, 144 debates, about 0.65 million tokens): no detectable lift, and false alarms were not measured, so E7 could not be met. The lenses mostly changed which errors were named, not how many. Details and limits: [`docs/experiments/2026-11-02-fve-planted-errors/RESULTS.md`](../experiments/2026-11-02-fve-planted-errors/RESULTS.md). The other four rows are pending, protocol section 4.* Observations so far are anecdotes, not results: in two real runs on one question the seats' emphasis followed their skills (a skeptic naming failure modes, a customer speaking as a user) and both runs ended "yes, conditionally" with the skeptic as the dissenter. One question, two runs.

## 6. What is and is not claimed

- **Claimed:** the definitions, the cost model (checked by test), and a plan for measuring.
- **Not claimed:** that skills improve answers, that a council beats one model, that any ranking of skills or vendors exists. No quality or accuracy claim is made until section 5 has numbers and E7 is met.
- **Limits:** `rho` is unknown and may differ by task; the coverage model assumes equal `p` and equal pairwise correlation; the cost constants are for short questions; planted-error tasks may not represent open decisions; graders are subjective; a rule-based suggestion matches words and does not understand a question; a one-vendor council is not independent and is never described as multi-model.

## 7. Reproducing and versioning

`node -e "import('./lib/debate/cost-model.mjs').then(m => console.log(m.tokens({ n: 6, r: 2 })))"` reproduces any row of section 3. Draft 1 (2026-11-01): definitions, E1 to E8, cost and coverage tables, the measurement matrix, results pending.
