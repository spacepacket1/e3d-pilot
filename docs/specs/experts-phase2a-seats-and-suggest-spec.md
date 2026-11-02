# Experts, Phase 2a: seats that do not depend on providers, and a free "suggest a panel" (engine only)

**Status:** draft 1, 2026-11-01, for owner review **before any code**. Docs only.
**Parents:** [Phase 1 spec](experts-phase1-private-experts-spec.md) (section 4 names the one-seat-per-provider limit as "lifted at the start of Phase 2"), [Phase 0](experts-phase0-overlap-map-and-eval-plan.md) and [#50](experts-auto-councils-marketplace-developer-talent.md).
**Evidence tags:** **[E]** read in a file today. **[G]** guess. **[N]** not verified.

## 1. Why, and what is not in this phase

Today a council can hold only as many experts as there are usable providers (usually 2 to 4), and nothing helps a person choose which experts to name. Phase 2a removes the first limit and adds a free, rule-based suggestion for the second. **Both are engine only, behind `E3D_SPECIALISTS=1`.** It also unlocks the evaluation plan's arm F ("same model, three lenses", Phase 0 section 4), which needs several seats on one provider.

**Not in 2a:** anything hosted (passing expert parameters through `e3d_debate`, billing's agent routes, quotes and pricing: that is **Phase 2b**, option B); a language-model router (a later, quoted step); running a suggestion automatically (`--auto`); per-expert word limits; effort plumbing into adapters. With none of the new flags, every prompt, flag and receipt stays exactly as it is (golden tests).

## 2. Part A: a seat is not a provider

### 2.1 What is keyed by provider today [E: bin/e3d-debate]

The round loop starts one subshell per entry of `DEBATE_PROVIDERS` and uses the provider name for **everything**: the adapter to run (`$PROVIDERS_DIR/$provider`), the files of a call (`round${round}-${provider}.prompt.md|.out|.status|.stderr`), the answer arrays (`LAST_ANSWER[$provider]`, `PROMPT_ANSWER[$provider]`), the per-token usage rows (`r${round}:${provider}`), the per-provider limit lookups (`PT_MAX_JSON`, `PT_ANS_JSON`, `WS_CAP`), web-search switches (`search_on_for`), seat loss (`SEAT_UNAVAILABLE`, `R1_ANSWERED`, `DROP_NOW`) and the round-2 labels ("`--- claude (previous round) ---`"). `DEBATE_PROVIDERS` is read in 29 places.

### 2.2 The change: two names, one for the seat and one for the adapter

- A **seat id** is the name used for files, arrays, labels, usage rows and seat loss. An **adapter** is the provider script that answers.
- A new array `SEAT_ADAPTER[seat]` maps one to the other. **A seat id equals its adapter name whenever one seat uses that adapter**, so every existing debate is byte-identical. A second seat on the same adapter is `adapter.2`, a third `adapter.3`. The suffix uses `.` because `bin/e3d-mcp`'s `readSeats` strips every character outside `a-z 0-9 _ . : -` from a seat name **[E]**, so a `~` would be shown wrongly in MCP warnings; `.` is allowed there, is safe in a file name, and no adapter name contains one **[G: adapters are plain script names]**.
- Everywhere the script runs the adapter or looks up a per-provider limit it uses `SEAT_ADAPTER[seat]`; everywhere else it uses the seat id.
- **Two seats on one adapter are independent calls**: each has its own files, its own retries, its own usage row and its own fate. If `claude.2` fails in round 1, `claude` is not dropped, and the other way round.
- Per-token limits and web-search caps are per adapter, so each seat of that adapter gets the same limit; a quote written for one seat of an adapter is not valid for two (hosted pricing is Phase 2b; locally there is no price).

### 2.3 Assignment (replaces "at most one seat per provider")

Phase 1's rules stand, with one change. The engine assigns each expert a provider from the pool: **prefer the vendor family with the fewest seats so far, then the adapter with the fewest seats, then the expert's `models` order as a tie-break (`hint_used` as today), then pool order**; `name:provider` still overrides. With enough providers this gives exactly today's spread, so existing panels do not move; with fewer providers than experts it seats the extras on the least-used family instead of refusing.

- **Bounds:** at most **8 seats** in one panel (an explicit list longer than that, or a preset, refuses).
- **Presets:** `min_seats` stays; a preset no longer shrinks for lack of providers, only for the 8-seat bound (none today).
- **Independence is stated, never hidden.** The receipt's `panel` block gains `independence: { seats, adapters, families }` and each seat gains `adapter`. When fewer than 2 vendor families are in use the engine prints one stderr line ("N seats on 1 vendor family: lenses differ, the model does not") and the transcript header repeats it. **`--min-families N`** (default **2**) refuses a panel with fewer families and says how to lower it; `--min-families 1` is the deliberate opt-in for lens-only runs (the evaluation's arm F). A debate that is not multi-model is allowed only on purpose, and is always labelled.

### 2.4 What readers of the receipts see

`decision-log.json` keeps `schema: 1`; `providers` lists **seat ids** (identical to adapters when each is used once). `seats.json` `seats_unavailable[].provider` is the seat id. `bin/e3d-mcp` reads only `seats.json` and passes the string through **[E: Phase 1.2 grep]**, so a hosted debate (which names providers, never experts, until 2b) is unaffected; the transcript headings become `Round 1 -- claude.2` only when a second seat exists, and the MCP warning keeps the `.2`.

### 2.5 Pull requests (each flag-free and mergeable alone)

1. **2a.1, the seam, no behavior change:** introduce `SEAT_ADAPTER` and make the loop, the helpers and the receipts use seat id versus adapter correctly, with every seat id equal to its adapter. **Proof:** the Phase 1.2 golden files (`v2`, `v3b`, `v3c`) and the existing debate, retry, seat-reliability, per-token, web-search and MCP tests all pass unchanged. This is the risky PR (surgery on a 1,100-line bash script) and carries the most tests.
2. **2a.2, the limit lifted:** the assignment above, the 8-seat bound, `--min-families`, the `independence` block and its stderr line. **Proof:** two and three seats on one adapter each get their own lens, files and usage row; one of two same-adapter seats can fail without dropping the other; `--min-families` refuses and allows as stated; existing panels of distinct providers are assigned exactly as before.

## 3. Part B: `--suggest-panel` (free, rule-based, explainable)

`E3D_SPECIALISTS=1 e3d-debate "question" --suggest-panel [--task decide|review-spec|find-gaps]` prints a proposed panel and **runs no debate and calls no model**. It never spends anything.

- **Method:** a fixed table of weighted trigger words and phrases, kept in `lib/specialists/suggest.json` and listed by `--show-suggest-rules`. Each rule adds weight to one or more experts and names the words that matched. Examples: money, legal, privacy, security, claim, regulation add `compliance`; ship, launch, release, migrate, deadline add `skeptic` and `premortem`; customer, pricing, users, market, onboarding add `customer`; design, architecture, schema, migration, monorepo, scale add `architect`; spec, requirements, plan, estimate add `implementer`; numbers, dates, "according to", statistics add `factchecker`; open question, options, unclear, brainstorm add `facilitator`. `--task` adds a base weight from each expert's `tasks`.
- **Selection:** the highest-weighted experts, up to 4 (the council size), ties broken by catalogue order. Fewer than 2 experts matching means **low confidence**: it says so and proposes the `risk-review` preset instead of guessing.
- **Output:** each expert with the words that triggered it, the confidence (`low` below a total weight threshold, else `medium`; never `high`), the exact command line that would run it (`--specialist a --specialist b ...`), and a fixed sentence: *"Rule-based advice, not a measurement. It matches words; it does not understand your question."*
- **Honesty rules:** the question is only read locally; nothing is sent anywhere; a suggestion is never executed by itself and `--auto` does not exist yet; the output makes no claim about quality or accuracy.
- **Why rules first:** it is free, deterministic, reproducible from the receipt and testable. A language-model router costs credits, must be quoted, and is only worth building once Stage 0 or later shows rules are not enough (Phase 0). The suggestion and the panel a person finally runs are both visible to the evaluation if it is ever run.

**Pull request 2a.3:** the rules file, the command, and tests: each rule fires on its words and not on near-misses; matches are case-insensitive and whole-word; ties are stable; low confidence falls back to `risk-review`; the output names the matched words; the same question always gives the same answer; no network and no process is used; with the switch off the flags refuse.

## 4. Decisions for the owner (my recommendation first)

- **D8. `--min-families` default 2.** A panel on one vendor is allowed only with `--min-families 1`, and is always labelled. (Keeps "multi-model" true by default.)
- **D9. At most 8 seats** per panel.
- **D10. Seat ids `adapter.2`**, `adapter.3`, with the first seat keeping the plain adapter name.
- **D11. Rule-based `--suggest-panel` first**, named "suggest" (never "auto"), no model call; a language-model router is a later, quoted decision.

## 5. Not verified

How many places in the script use the provider name where the **seat id** is the right key (I counted uses, not read each: the 2a.1 diff and its tests settle it); whether any adapter script reads the name it was called by (none was checked); how the evaluation harness will pass several seats on one adapter (arm F is defined in Phase 0 but not built); the suggestion thresholds and weights (they are a starting table to tune on real questions, not measured).
