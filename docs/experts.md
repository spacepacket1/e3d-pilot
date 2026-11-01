# Experts: choose the skills, not the models

An **expert** is a reusable lens for one seat in a debate: "assume it fails", "you are the customer", "check the facts". You choose which
experts sit on the council. You do not choose models: the engine assigns one provider to each expert, spreading them across vendors, and
records what it did. Off by default; set `E3D_SPECIALISTS=1`.

```
E3D_SPECIALISTS=1 e3d-debate "Should we ship this?" --panel risk-review
E3D_SPECIALISTS=1 e3d-debate "Should we ship this?" --specialist skeptic --specialist customer --specialist architect
E3D_SPECIALISTS=1 e3d-debate --list-specialists
E3D_SPECIALISTS=1 e3d-debate --show-specialist skeptic
```

## Presets

`--panel` takes a preset from `lib/specialists/panels.json`: `risk-review` (skeptic, premortem, compliance, implementer), `spec-review`
(implementer, architect, skeptic, customer) and `gap-finding` (facilitator, customer, architect, factchecker). A preset has four seats and
a minimum of three: with fewer usable providers the lowest-priority experts are dropped (and listed in the receipt); below three the run
refuses. An explicit `--specialist` list never shrinks: name more experts than there are usable providers and it refuses.

## Providers

One expert sits on one provider. With `--panel` or `--specialist`, `--providers a,b,c` names the pool the engine may assign from; without
it the pool is every provider that answers the availability check. The engine prefers a different vendor family for each seat, uses an
expert's own model list only to break ties, and never substitutes silently: if no provider is left for an expert the run refuses.
`--specialist skeptic:claude` forces a provider and is meant for people who know why.

## What an expert is

A folder in the standard [Agent Skills](https://agentskills.io/specification) format:

```
skeptic/
  SKILL.md           # name, description, license and the lens text
  e3d/expert.json    # optional: tasks, model hints, tools, limits
```

Experts are found in `lib/specialists/` (built in), `~/.config/e3d-pilot/specialists/` (yours) and `<repo>/.e3d-pilot/specialists/`
(a project's); a later location wins by name. Check a folder with `--validate-specialist <folder>` and copy one out, ready for any tool that
reads skills, with `--export-specialist <name> <folder>` (add `--no-sidecar` to leave `e3d/` behind).

## What a seat receives

The lens text is printed before that seat's usual prompt, between two marker lines, and nothing else changes. `--show-specialist` prints
the exact text. The synthesis step never receives a lens. With no expert named, every prompt and receipt is exactly what it was before.

## Safety

- An expert's lens is text written by a person: it is delimited, shown whole, and cannot grant a tool or change a flag.
- `tools` must be `none` in this release. `allowed-tools` in a `SKILL.md` is ignored with a warning, never granted. A `scripts/` folder is
  never run.
- A symbolic link inside a skill folder, an unknown frontmatter field, an oversized file or a malformed sidecar is refused with a coded error.
- Nothing is fetched from a network and no model is called to load, show, validate or export an expert.

## The receipt

When an expert is named, `decision-log.json` gains a `panel` block: the preset (or null), the experts dropped to fit, and for each seat the
provider, the expert's name, version, content hash and tier, whether its model hint was used, and the effort requested (no adapter applies an
effort setting yet, so `effort_applied` is always false). No question or answer text goes in.

Design and decisions: `docs/specs/experts-phase1-private-experts-spec.md`.
