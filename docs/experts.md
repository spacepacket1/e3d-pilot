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
a minimum of three. A preset is no longer shrunk for lack of providers; a panel holds at most 6 seats, and an explicit `--specialist` list
longer than that refuses (a preset longer than that drops its lowest-priority experts, listed in the receipt).

## Providers

One expert sits on one seat, and a seat is one provider (an adapter). With `--panel` or `--specialist`, `--providers a,b,c` names the pool the engine may assign from; without
it the pool is every provider that answers the availability check. The engine prefers a different vendor family for each seat, uses an
expert's own model list only to break ties, and never substitutes silently. When there are more experts than providers, the extra
experts share a provider: the first seat on a provider keeps its name (`claude`), the next are `claude.2`, `claude.3`; each is its own
call with its own lens, files and fate, and is seated on the vendor family with the fewest seats so far. `--specialist skeptic:claude`
forces a provider and is meant for people who know why.

**Independence is stated, never hidden.** The receipt's `panel.independence` gives `seats`, `adapters` and `families` (counts), and each
seat records its `adapter`. A panel on fewer than 2 vendor families is refused: `--min-families N` (default 2) sets the floor, and
`--min-families 1` is the deliberate opt-in for lens-only runs. Such a run prints `N seats on 1 vendor family: lenses differ, the model
does not` on stderr and in the transcript header, and is never called multi-model. `--min-families` applies to `--panel` and `--specialist`
runs only; a plain `--providers a,b` debate is unchanged. Per-token limits (`E3D_DEBATE_MAX_TOKENS`) still refuse two seats on one provider.

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

## Over MCP (read-only)

With `E3D_MCP_EXPERTS=1` the MCP server offers two free tools, `e3d_list_experts` and `e3d_get_expert`, so an assistant can describe the built-in
experts and presets and show the exact lens text a seat receives. They read this checkout's own files at start-up: no network, no credentials,
nothing written, nothing charged, and a person's own expert folders are never listed. **Running a debate with experts through the connector is
not available yet**; the command line above runs them today. Off by default; any value other than unset, `0` or `1` refuses to start.

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

## Status and methodology

**Available today:** the command-line flags above, `--suggest-panel` and `--show-suggest-rules` (a free rule-based suggestion: it matches trigger words, runs nothing, and is not a measurement), the eight built-in experts and three presets, the receipt, and the free read-only MCP tools `e3d_list_experts` and `e3d_get_expert` (off unless `E3D_MCP_EXPERTS=1`). **Not available yet:** running experts through MCP or the hosted server, several experts on one provider, a preview of the panel and its cost before running; these are specified in [the Phase 2a spec](specs/experts-phase2a-seats-and-suggest-spec.md).

**Not measured:** whether experts improve answers, and by how much. The cost model, the coverage model, the measurement plan and the rule that decides whether a result is claimed are in the [methodology draft](methodology/expert-councils.md); its results table is marked pending until something has been measured.
