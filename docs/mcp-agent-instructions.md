# Instructions for AI agents that use the e3d-pilot MCP server

Copy the block below into `.github/copilot-instructions.md` (Copilot), `AGENTS.md`, or `CLAUDE.md` in a repository that
has e3d-pilot configured. Editors load these files every time, while MCP tools are often loaded only when a request
matches their description, so this is the reliable place to say *when* to use them.

```md
## e3d-pilot (MCP server `e3d-pilot`)

- For a design or tradeoff question ("should we...", "X or Y?", a library or architecture choice), call `e3d_debate`
  for a multi-model second opinion before deciding. It costs credits, so do not use it for simple lookups.
  When you summarize its result, always keep the consensus level, the dissent, and any warnings exactly as given.
- To turn a decision into tracked work ("add this to the backlog", "create an idea"), call `e3d_pilot_propose`. It is
  free and only records the idea as proposed. Never approve an idea yourself: a person approves it.
- Before expensive requests, call `e3d_usage` to see today's model-call budget. If a call is refused for budget,
  report the refusal text to the user and stop; do not retry with different arguments to get around it.
- To drive the pipeline: `e3d_pilot_implement` drafts and negotiates a spec and pauses before any code is written.
  Show the user the result of `e3d_pilot_code_plan` and wait for them to confirm before `e3d_pilot_execute`.
  Merging is never available through these tools.
```
