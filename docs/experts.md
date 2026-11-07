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
(implementer, architect, skeptic, customer) `gap-finding` (facilitator, customer, architect, factchecker) and `market-commentary` (macro-market-analyst, factchecker, skeptic, customer). A preset has four seats and
a minimum of three. A preset is no longer shrunk for lack of providers; a panel holds at most 6 seats, and an explicit `--specialist` list
longer than that refuses (a preset longer than that drops its lowest-priority experts, listed in the receipt).

## Providers

One expert sits on one seat, and a seat is one provider (an adapter) or, with more experts than providers, a numbered extra seat on one. With `--panel` or `--specialist`, `--providers a,b,c` names the pool the engine may assign from; without
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
nothing written, nothing charged, and a person's own expert folders are never listed. **Passing experts through the `e3d_debate` connector tool is
not built**; the command line above and hosted web debates (next section) run them. Off by default; any value other than unset, `0` or `1` refuses to start.

## Hosted runs (live on pilot.e3d.ai web debates since 2026-11-03, behind a flag)

On pilot.e3d.ai the Ask page has a `Skills` menu (pick 2 up to the panel size, 4 vendors) and a free in-browser `Suggest skills` button. The hosted engine gives each skill to a different vendor of the quoted panel; vendors without a skill answer as plain seats; users never choose models. The lens text adds a little to the quote (about +1 credit on a standard 4-vendor debate). Results and Gallery entries list skill names only. The cloud side lives in `e3d-pilot-cloud`; this repo holds the engine side described below.

For the hosted web service (spec: [Phase 2b.1](specs/experts-phase2b1-hosted-lenses-spec.md)) the engine has four extra switches, all of which need
`E3D_SPECIALISTS=1` and `--specialist`: `--builtin-only` (or `E3D_SPECIALISTS_BUILTIN_ONLY=1`) reads only the built-in experts, so a folder on the
host can never override one by name; `--expert-pin name=sha256:...` (repeatable) refuses an expert whose content hash differs from the one named;
`--lens-bytes-max N` refuses an expert whose lens block (markers included) is larger than N bytes; `--fill-pool` makes every provider of `--providers`
that holds no expert a plain seat (no lens, `expert: null` under `panel.plain_seats` in the receipt), allows at most one expert per provider (more
experts than providers is refused, seats are never added), and writes one line after the question in `transcript.md`:
`**Experts (perspectives, not measured):** skeptic on claude, customer on gemini; plain seat: codex.` (the synthesis prompt never carries it).
`e3d-mcp`'s internal run listener accepts the run fields `experts` (`[{id, hash}]`, 2 to 16 distinct ids) and `lens_bytes` (1 to 4096) only with
`E3D_MCP_EXPERTS_RUN=1` (which needs `E3D_MCP_PRICING=per_token`; any other value refuses to start) and then advertises the capability `experts_v1`;
without it both fields are refused `400 invalid`. The `e3d_debate` MCP tool takes `experts` only with `E3D_MCP_EXPERTS_AGENT=1` (hosted agent mode; it needs `E3D_MCP_EXPERTS=1`, an `idempotency_key`, and a billing service that prices and echoes them: [the Phase 2b.2 spec](specs/experts-phase2b2-mcp-listing-and-use-spec.md)); otherwise it does not. Stored result positions hold the answer only (no web-search source list or notices), and each position's `model` comes from the seat's usage line ([web-search-interface.md](web-search-interface.md) section 6).

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

**Available today:** the command-line flags above, `--suggest-panel` and `--show-suggest-rules` (a free rule-based suggestion: it matches trigger words, runs nothing, and is not a measurement), the nine built-in experts (plus agent-diagnosis) and four presets (adding market-commentary), the receipt, and the free read-only MCP tools `e3d_list_experts` and `e3d_get_expert` (off unless `E3D_MCP_EXPERTS=1`). Hosted web debates on pilot.e3d.ai can use skills (see Hosted runs). Several experts on one provider are supported (seats `claude`, `claude.2`). **Not built:** passing skills through the `e3d_debate` MCP tool, more skills than vendors on a hosted panel, automatic (model-chosen) skill selection, users' own skills on the hosted server, any marketplace, a preview of the panel and its cost before running (`--show-panel`, see [the Phase 2a spec](specs/experts-phase2a-seats-and-suggest-spec.md)).

**Not measured:** whether experts change answer quality, and by how much. The one test so far (planted errors, 2026-11-02, #63) was inconclusive: +2.8 points, 95% interval -4.6 to +10.2, cost 1.09x, false alarms not measured; four other comparisons are not run. The cost model, the coverage model, the measurement plan and the rule that decides whether a result is claimed are in the [methodology draft](methodology/expert-councils.md); its results table is marked pending until something has been measured.
