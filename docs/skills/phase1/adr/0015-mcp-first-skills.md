# ADR-0015: Skills delivered to the user's own agent over MCP

Status: **Accepted by the owner, 2026-11-23** (approved as written when skills phase 2 was authorized; the independent reviews of the phase 2 work are in `review-record.md`). Date: 2026-11-23. Phase: 1 (added after the calibration specification). Amends ADR-0005.

## Context

Skills are widely shared as prompts that people copy into a chat: unversioned, untested and untraceable. Most skill use happens in the user's own agent (Claude Code, Codex and similar), where Pilot does not run the model. ADR-0005 froze the MCP surface until the hosted registry exists (phase 7). That rule delays the product direction that matters most: managing skills, and recording how they went, where people already work. Calibration (`e3d-pilot-calibration-spec-v0.1.md`) needs skill use and outcome records from those hosts.

## Decision

1. **Local, read-only skill tools may ship in skills phase 2**, on the stdio server, behind `E3D_MCP_SKILLS=1` (off by default, strict unset/0/1): list, get (content, hash, version, source), validate, export. They read the user's local skill folders and the built-ins. No spend, no network, no model call. ADR-0005's "no new MCP tool before phase 7" now applies only to **hosted (remote) tools and to any tool that writes hosted data or spends**.
2. **The hosted remote tools** (registry list/get, hosted outcome reports) wait for the hosted registry, with OAuth scopes beyond today's single `debates:run` (proposed: `skills:read`, `skills:write`, `outcomes:write`), decided in the hosted adapter.
3. **A skill is served as data, never as an instruction from Pilot.** Every response carries id, version, `definition_hash`, source tier and a fixed label saying the text is a skill definition for the host to evaluate. The server never installs, writes into the host's skill directories, or runs anything. A separate, explicit user action (a CLI export) writes a folder.
4. **Instructional only.** A skill served over MCP cannot request or grant any host capability. The host keeps its own tool permissions; Pilot cannot enforce them, so the label and the scanner (below) are the controls.
5. **Use and outcome reports are bound to a server-issued `use_id`** created when the skill is fetched; reports for unknown, expired or foreign ids are refused.
6. **Advisory scan (implemented in skills phase 2b, `lib/skills/scan.mjs`).** **Import and publish scanning** (secrets, local paths, scripts, hidden or confusable text, instruction patterns aimed at the host such as "ignore previous", "run this command", "disable safety") raise findings the user sees before saving; findings are advisory except the ones the schema already rejects.
7. Existing tools (`e3d_list_experts`, `e3d_get_expert`) keep names and output forever.
8. **Hosts (owner, 2026-11-23):** Claude Code first, then Codex. Delivery order: MCP tool results first (works in any MCP host); explicit user-run export into a host's skills directory second; MCP prompts or resources later. Codex behaviour is verified in calibration phase 3, not assumed.

## Consequences

`tests/skills-compat.sh` currently asserts that no MCP tool name contains "skill"; it is changed deliberately in skills phase 2 to assert the same with the flag unset and the new names with it set. The threat model gains T24 (a served skill injects the host agent) and T25 (outcome poisoning). Delivery formats beyond tools (MCP prompts or resources) are allowed later if hosts support them, under the same labelling rule.

## Alternatives considered

Keep ADR-0005 as written (delays the main use case); push skill files into the host's skills directory automatically (silent installation of untrusted instructions into a tool-capable agent); serve only through the hosted service (excludes the local, private case, which is the first one users have).

**Update (2026-11-23):** the scanner exists as an advisory pattern scan (`scan_*` codes, `warn` and `notice` severities) shown by `--validate-skill`, `--show-skill`, `--list-skills` and the MCP tools. It never refuses a skill, matches words and not intent, and a clean result is not a safety claim. Publish-time scanning (secrets, PII, local paths) is still hosted phase 8 work.
