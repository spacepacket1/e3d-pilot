# ADR-0002: Expert to skill compatibility mapping

Status: **Accepted by the owner, 2026-11-23** (approved as written when skills phase 2 was authorized; the independent reviews of the phase 2 work are in `review-record.md`). Date: 2026-11-22. Phase: 1.

## Context

Existing experts must keep names, hashes, flags, folders, presets, receipts and MCP fields (spec 14.1). Nothing may be rewritten in place.

## Decision

An expert folder is projected **in memory** to a `SkillDefinition` with: `id = skill.e3d.<name>` for built-ins (`skill.<owner>.<name>` otherwise, ADR-0014); `version = "<N>.0.0"` from `metadata."e3d.expert.version"` (missing means `1.0.0`); `name`, `description`, `license` unchanged; `capability_level = instructional`; `hooks = [debate_seat/seat_prompt]` (a chat-skill use also maps to `chat/before_response`); `instructions.method` = the SKILL.md body unchanged; `constraints = []`; `requested_capabilities = []`; `memory_policy` none; `limits.max_model_calls = 0` (a lens adds no call of its own; the seat's calls, one per round, belong to the debate), `max_tool_calls = 0`, `max_input_bytes 64000`, `max_output_bytes 16000`, `timeout_ms 60000`; `input_schema_ref`/`output_schema_ref` = `seat-input/v1`/`seat-output/v1`; `fallback = {fail, return_unstructured_with_warning}`; `tasks` from the sidecar (up to 50 items of up to 64 characters, as the engine allows); `provenance.source_format = expert-v1-projection` and `legacy_folder_hash` = the existing folder hash. Sidecar `models` (provider and effort hints, which change seat assignment) become the **hashed** field `model_hints`, and `limits.max_words` becomes the hashed `limits.max_words`; nothing that affects a run goes into the unhashed `extensions`. **Not behaviour-bearing and carried in `extensions` (string values) or dropped, as the dry-run lists:** `required_evidence` and `tests` (the engine reads neither into a prompt today; if that changes they are promoted to hashed fields), `allowed-tools` (ignored today) stays ignored; the `e3d.expert.lens` summary and `tags` map to `tags`. **Overflow and odd input:** the projection never truncates silently. A user folder whose fields exceed a schema limit (for example a tag that is not a slug, a version that is not an integer string) is reported by the dry-run as *not projectable* with the field and the limit, and keeps working on the legacy expert path unchanged. A non-integer version is refused; a missing version projects to `1.0.0` marked *inferred* (the MCP listing keeps showing `null`). Tags that are not slugs are dropped from `tags` and listed. **Prompt labels:** spec 6.4 asks every skill block to carry id, version, hash and scope. The expert path keeps `lensBlock` byte for byte (that is what the goldens pin), so for expert-path skills the labels live in the receipt, not the prompt; the label rule applies to skills run through the new path. The projection never changes what a seat receives.

## Consequences

Compatibility test `tests/skills-compat.sh` pins the ten built-ins (name, version, hash, lens bytes) and four presets. Phase 2 must show the projection of every built-in is stable and that the seat prompt is byte-identical.

## Alternatives considered

Convert experts in place (violates 14.1); map the hash to the new one (breaks hosted pins).
