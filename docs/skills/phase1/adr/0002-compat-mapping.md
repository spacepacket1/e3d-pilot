# ADR-0002: Expert to skill compatibility mapping

Status: **Proposed** (needs a human decision before Phase 2). Date: 2026-11-22. Phase: 1.

## Context

Existing experts must keep names, hashes, flags, folders, presets, receipts and MCP fields (spec 14.1). Nothing may be rewritten in place.

## Decision

An expert folder is projected **in memory** to a `SkillDefinition` with: `id = skill.e3d.<name>` for built-ins (`skill.<owner>.<name>` otherwise, ADR-0014); `version = "<N>.0.0"` from `metadata."e3d.expert.version"` (missing means `1.0.0`); `name`, `description`, `license` unchanged; `capability_level = instructional`; `hooks = [debate_seat/seat_prompt]` (a chat-skill use also maps to `chat/before_response`); `instructions.method` = the SKILL.md body unchanged; `constraints = []`; `requested_capabilities = []`; `memory_policy` none; `limits.max_model_calls = 1`, `max_tool_calls = 0`; `tasks` from the sidecar; `provenance.source_format = expert-v1-projection` and `legacy_folder_hash` = the existing folder hash. **Lossy or non-mapped fields**, listed by the dry-run command: sidecar `models` (provider and effort hints) go to `extensions.e3d.model_hints`; `limits.max_words` to `extensions.e3d.max_words`; `required_evidence` and `tests` to `extensions.e3d.*`; `allowed-tools` (ignored today) stays ignored; the `e3d.expert.lens` summary and `tags` map to `tags`. The projection never changes what a seat receives.

## Consequences

Compatibility test `tests/skills-compat.sh` pins the ten built-ins (name, version, hash, lens bytes) and four presets. Phase 2 must show the projection of every built-in is stable and that the seat prompt is byte-identical.

## Alternatives considered

Convert experts in place (violates 14.1); map the hash to the new one (breaks hosted pins).
