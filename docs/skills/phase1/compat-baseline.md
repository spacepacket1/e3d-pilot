# Compatibility baseline

What the skills work must not change, and the tests that pin it. All deterministic: stub providers, no model, no network.

| What | Pinned by |
| --- | --- |
| No expert named: every seat prompt, the synthesis prompt and the decision log of a plain two-seat debate, prompt versions v2, v3b, v3c | `tests/debate-specialists.sh` against `tests/fixtures/specialists/golden/` (refreshed for #91 in `bc68f1b`) |
| Expert named: the lens block, seat assignment, receipt `panel` block, injection containment | `tests/debate-specialists.sh`, `tests/debate-seats.sh`, `tests/experts-assignment.sh` |
| The ten built-in experts: name, version, content hash, lens bytes, tools none, tasks, model hints; the four presets | `tests/skills-compat.sh` against `tests/fixtures/skills/expert-baseline.json` |
| Folder rules: symlinks, size, unknown fields, scripts never run | `tests/specialists-loader.sh`, `tests/specialists-catalogue.sh` |
| MCP tool names with every flag unset, and with `E3D_MCP_EXPERTS=1`; no tool mentions "skill" until the skills phases ship | `tests/skills-compat.sh` against `tests/fixtures/skills/mcp-tools-baseline.json` |
| Experts over MCP, hosted run fields, agent `experts`, chat skills | `tests/mcp-experts-read.sh`, `tests/mcp-experts-run.sh`, `tests/mcp-experts-agent.sh`, `tests/mcp-chat-tool.sh` |
| Schemas and fixtures | `tests/skills-schemas.sh` |

Changing an expert's meaning on purpose: edit it, run `node tests/fixtures/skills/snapshot.mjs --write`, and say in the PR that the hash changed and why (hosted pins will then need updating).
