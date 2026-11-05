# Built-in experts

Eight starter experts (plus `agent-diagnosis`, below), each a standard skill folder (`SKILL.md`) with an optional `e3d/expert.json`. They come from the October design
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

**Suggest a panel (free, rule-based).** `E3D_SPECIALISTS=1 e3d-debate "question" --suggest-panel [--task decide|review-spec|find-gaps]` prints the experts whose trigger words appear in the question, the words that matched, a confidence (`low` or `medium`, never higher) and the command to run them. It runs nothing, calls no model and writes nothing. The table is `suggest.json` (list it with `--show-suggest-rules`); fewer than two matching experts proposes the `risk-review` preset instead. Rule-based advice, not a measurement: it matches words; it does not understand your question.

**`agent-diagnosis`** (not in a preset; suggested by `--suggest-panel` for questions about agents, skills, prompts, harnesses, MCP tools or LLM behaviour): intake for AI-agent incidents. It asks what the agent was told, what it saw, what it believed "done" meant, what changed recently and whether it happened before. In case mode (`--follow-up`) the synthesizer also checks the questions cover the biggest unanswered intake gap. Run it with `E3D_SPECIALISTS=1 e3d-debate "question" --follow-up --specialist agent-diagnosis --specialist skeptic`.
