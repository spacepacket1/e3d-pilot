# Built-in experts

Eight starter experts, each a standard skill folder (`SKILL.md`) with an optional `e3d/expert.json`. They come from the October design
(`docs/prompt-review-2026-10.md`, Part 3). Use them with `E3D_SPECIALISTS=1`; see [`docs/experts.md`](../../docs/experts.md).

| Expert | Lens | Presets |
| --- | --- | --- |
| `skeptic` | assume it fails; find the cheapest way to prove it | risk-review, spec-review |
| `premortem` | it is a year later and this failed; write the obituary | risk-review |
| `compliance` | regulator, security and privacy reviewer | risk-review |
| `implementer` | the engineer who has to build it | risk-review, spec-review |
| `architect` | systems and long-term maintenance | spec-review, gap-finding |
| `customer` | the end user's view, ignoring implementation | spec-review, gap-finding |
| `facilitator` | keep the panel on the question; find the missing perspective | gap-finding |
| `factchecker` | verify claims, and say when they cannot be verified | gap-finding |

Not shipped yet: `judge` (needs the synthesis rewrite), `editor` and `writer` (need a script mode), `futurist` (needs a resolution log).

**Model hints are guesses unless noted.** Only `skeptic` (grok-build was the strictest reviewer in the October runs) and `implementer`
(codex is the usual draft provider) carry a hint, and a hint only breaks a tie: the engine assigns the provider. None of these experts has
a measured track record, and nothing here claims one.

**Tools are `none`.** `factchecker` therefore cannot look anything up and is told to answer UNVERIFIABLE rather than guess.

To add your own, copy a folder into `~/.config/e3d-pilot/specialists/` (yours) or `<repo>/.e3d-pilot/specialists/` (a project's); a later
location wins by name. Check it with `E3D_SPECIALISTS=1 e3d-debate --validate-specialist <folder>`. Licensed MIT, like the engine.
