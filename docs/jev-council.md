# Jev council signal (Phase 1, shadow only)

Phase 1 of [issue #66](https://github.com/spacepacket1/e3d-pilot/issues/66). Jev (TypeSafe System One) is a typed, non-generative judge: it returns a `Noul` probability for a yes/no criterion and no reasoning. This feature records what Jev says about statements **you** supply, next to a debate, and shows it to nobody inside the debate. It exists to collect evidence for the question the issue asks: does Jev add decision value, and where.

It changes no answer, no consensus, no exit code and no prompt.

## Use

```
bin/e3d-debate "Should we adopt X?" --providers claude,codex --out-dir docs/debates/adopt-x \
  --jev-propositions props.json
```

`props.json` is an array of 1 to 5 statements, each with an optional plain-language negation:

```json
[{"id": "p1", "text": "E3D should adopt X now.", "negation": "E3D should not adopt X now."}]
```

`id` matches `[a-z0-9_-]{1,32}`, text is at most 500 characters. A bad file fails the run before any provider is called.

Needs `TYPESAFE_API_KEY`. Without it the artifact says `no_signal`. In per-token mode (`E3D_DEBATE_MAX_TOKENS`) no Jev call is made and the artifact says `skipped`.

## What it records

- `jev-council.json` in `--out-dir`: per statement the raw `Noul` values exactly as Jev returned them, whether a statement and its negation landed on opposite sides (`consistent`), a `combined` value, and a `band`. It is the only place the statement text is kept.
- One labelled line in `transcript.md` (ids and bands, no text).
- A `jev_council` summary in `decision-log.json` (status and band counts, no text), so the log stays free of question and answer text.

## Bands (provisional)

For a paired statement, `combined = (noul(statement) + (1 - noul(negation))) / 2`. A pair whose two values lean the same way is `consistent: false` and always `undecided`: Jev did not give a usable answer. Otherwise `combined >= 0.7` is `decisive_yes`, `<= 0.3` is `decisive_no`, and anything between is `undecided`. A statement without a negation uses its own value and has no polarity check, which is weaker.

The 0.7 and 0.3 thresholds come from a 10-debate replay ([results](experiments/2026-11-03-jev-past-debates/README.md)) and were chosen after seeing it. They are provisional and must be recalibrated on outcomes. Noul is not a calibrated probability, and the artifact says so.

## Hidden from the models

The call is made before round 1 and written after the copy that becomes the synthesis prompt, so no round prompt and no synthesis prompt carries it. `tests/jev-council.sh` checks that the statement text appears only in `jev-council.json`.

## Failure behaviour

A missing key, a vendor error, a malformed or out-of-range answer gives `no_signal` (or `partial` when some statements worked). Nothing is guessed, and the debate runs as if the flag were absent.

## What this is not

- Not a council seat and not a vote. Jev cannot rebut or concede, and a vote needs a calibrated, outcome-checked signal first.
- Not shown to the other models. Whether showing it helps or anchors them is the next experiment: run the same debates with the signal visible and hidden and judge both against outcomes.
- No framing call. A model that rewrote the question into statements would bring its own perspective and would be one more priced vendor call.

## Hosted opt-in: `--jev` and the run request's `jev: true`

Per-token mode (the hosted service) makes no Jev call by default. `bin/e3d-debate --jev` runs the obviousness pre-screen anyway: one Jev call, **not priced** (an owner decision, 2026-11-04, overriding the per-token "planned vendor calls only" rule for opted-in debates). The internal run request accepts `jev: true` (only true or absent; it is part of the idempotency key) and the hosted run passes `--jev`. It is record only (`transcript.md`), added no vendor call, and a missing key or failed call is skipped. The cloud sends it only for accounts that turned on Settings > Debate defaults > Advanced > Jev. Deploy the engine before the cloud: an engine without this change refuses the unknown field.

## The existing obviousness pre-screen is hidden too

The obviousness pre-screen (`Jev pre-screen (shadow mode, informational only)`) used to be written to the transcript before the synthesis-prompt copy, so the synthesizer saw it whenever `TYPESAFE_API_KEY` was set. That contradicted "informational only". It is now written after the copy, as the experts line already was: it is in `transcript.md` (the record) and in neither the synthesis prompt nor its transcript copy. The priced prompt bytes (`E3D_DEBATE_PROMPT_OVERHEAD=1`) are unchanged, since that mode and per-token mode never made the call. `tests/jev-council.sh` covers it with and without `--jev-propositions`.

## Tests

`bash tests/jev-council.sh` covers validation, bands, the polarity check, failure and malformed answers, the per-call stub (`E3D_PILOT_JEV_STUB_DIR`), the artifact and the decision-log summary, hidden-from-prompts, unchanged output, a bad file failing before any provider runs, and per-token mode making no call.
