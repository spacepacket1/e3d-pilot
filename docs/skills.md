# Skills (local, instructional)

A skill is a reusable set of instructions with an identity: an id, a version and a fingerprint (`definition_hash`) computed from what it says. This
page is the user guide for the local commands. The design, contracts and decisions are in `docs/skills/` (start at `docs/skills/README.md`).

Everything here is **off by default** and **local**: no command calls a model or the network, nothing is run from a skill folder, and a skill grants no
tool, flag or permission. Skills are perspectives, not measured improvements.

## Turning it on

| Switch | Turns on |
| --- | --- |
| `E3D_SKILLS_V1=1` | the `--list-skills`, `--show-skill`, `--validate-skill`, `--project-expert`, `--export-skill`, `--diff-skill` commands, and a `skills` block in the receipt of a debate that uses experts |
| `E3D_MCP_SKILLS=1` | four read-only MCP tools on the local (stdio) server: `e3d_list_skills`, `e3d_get_skill`, `e3d_validate_skill`, `e3d_export_skill`. Never on the hosted server |

Unset, empty or `0` is off; any other value refuses to start. Existing experts, presets, MCP tools and receipts are unchanged when the switches are off.

## Where skills come from

The same three places as experts, later ones winning for an unqualified name: the built-in skills (`lib/specialists`), your own folder
(`~/.config/e3d-pilot/specialists`) and the repository's (`<repo>/.e3d-pilot/specialists`). A folder with only a `SKILL.md` is an expert folder, **projected**
in memory to a skill; a folder with `e3d/skill.json` too is a **native** skill. Nothing on disk is rewritten.

Ids are `skill.<owner>.<name>`. Built-ins are `skill.e3d.<name>`; your folders are `skill.local_user.<name>` and `skill.local_repo.<name>` (the owner `e3d`
is reserved), so a local skill with a built-in's name is a different skill. Use the full id to pick exactly one; a bare name picks the highest tier.

## Commands

```
E3D_SKILLS_V1=1 e3d-debate --list-skills
E3D_SKILLS_V1=1 e3d-debate --show-skill skeptic [--skill-version 1.0.0] [--skill-hash sha256:...]
E3D_SKILLS_V1=1 e3d-debate --validate-skill ./my-skill            # schema, hash and safety checks; nothing is stored
E3D_SKILLS_V1=1 e3d-debate --project-expert skeptic               # dry run: the skill an expert folder becomes, and what is lossy
E3D_SKILLS_V1=1 e3d-debate --export-skill skeptic ./out           # writes ./out/skeptic (a built-in becomes a private local copy); never overwrites
E3D_SKILLS_V1=1 e3d-debate --diff-skill skeptic ./out/skeptic     # field-level difference; exit 3 when the hashes differ
```

A pin that does not match fails before anything runs (`skill_version_invalid`, `skill_hash_mismatch`).

## A native skill folder

```
my-skill/
  SKILL.md          frontmatter: name (= the folder name), description, license; the body is the instruction text
  e3d/skill.json    everything structured
```

`e3d/skill.json` holds the version, capability level (`instructional` only in this release), hooks, schema references, tags, tasks, limits, model hints and
so on, for example:

```json
{
  "schema_version": "e3d.skill/v1",
  "version": "1.0.0",
  "capability_level": "instructional",
  "hooks": [{ "scope": "debate_seat", "event": "seat_prompt" }],
  "input_schema_ref": "e3d://schemas/seat-input/v1",
  "output_schema_ref": "e3d://schemas/seat-output/v1",
  "tags": ["risk"],
  "tasks": ["review-spec"]
}
```

The id, description, license and instruction text come from `SKILL.md`; `provenance`, `id` and `definition_hash` are set by the loader and may not be written
in the file. The schemas are in `docs/skills/schemas/v1`.

## Skills on seats, the preview and the plan digest

A skill can sit on a debate seat. This needs `E3D_SKILLS_V1=1`, `E3D_SKILLS_SEATS=1` and `E3D_SPECIALISTS=1` (it runs a debate):

```
E3D_SPECIALISTS=1 E3D_SKILLS_V1=1 E3D_SKILLS_SEATS=1 e3d-debate "Should we ship it?" \
  --specialist skeptic --seat-skill 'premortem@2.0.0' --seat-skill 'my-review#sha256:...:codex'
```

`--seat-skill <id|name>[@version][#sha256:hash][:provider]` sits beside `--specialist` and takes any skill: a built-in, or a native one from your folders. A pin
(`@version`, `#hash`) that no longer matches stops the run **before any model call**; so does an unknown or withdrawn skill, or one that does not declare the
`debate_seat/seat_prompt` hook. A seat only runs without its skill if you say `--on-seat-skill-failure plain_seat`: that seat then sends no lens and is recorded
as a plain seat with the failure code, in the receipt, the preview and on stderr. A skill's `model_hints` steer which provider it gets; `:provider` forces one. The
seat's prompt is the same role block experts have always had; the id, version and hash are in the receipt (`skills`, with a `use_id` and an `attachment_id` per seat).

**Preview before you spend.** `--preview-skills` (add `--preview-json` for JSON) prints what the run would do and exits without calling any model: each seat with its
skill, version, hash and size, plain seats and why, vendor families, the number of model calls and a token estimate for a typical short question (an estimate, not
a bound: credits are quoted by the hosted service), and a **plan digest**. The preview carries no instruction text. The call count is the nominal one; each call
may be retried (`E3D_DEBATE_PROVIDER_RETRIES`, default 2), and a fallback synthesis, a recap, web search and retries after an empty answer add more.

**Bind a run to its preview.** Run the same command with `--expect-plan sha256:...` and the run refuses to start (`skill_quote_expired`, nothing called) if anything
the digest covers changed. It covers: the question, rounds, word limit, synthesizer, the provider pool as assigned, forced providers, every seat's skill (id, version,
hash, lens size) and plain seats, and the settings `--prompts`, `--approach`, `--web-search`, `--recap`, `--jev`, `E3D_DEBATE_SYNTH_FALLBACK`,
`E3D_DEBATE_FAST_SYNTHESIS` and `E3D_DEBATE_PROVIDER_RETRIES`. It does **not** cover other environment knobs (timeouts, per-provider settings, test seams) or what a
provider does on its side. The receipt records the digest as `skills_plan_digest`.

**Pins.** A hash pin (`#sha256:...`) is what guarantees the exact skill that runs. A bare name with only a version pin (`skeptic@1.0.0`) is satisfied by any skill of
that name and version in the highest tier, including one of your own that shadows a built-in; name the full id (`skill.e3d.skeptic`) to select exactly one. A skill
folder that exists but does not validate is never skipped over for another skill of the same name: the run stops with `skill_invalid` (or that seat runs plain with
`plain_seat`).

**Constraints.** A native skill's `instructions.constraints` are part of its hash but are **not sent to the model** in this release (a seat receives the instruction
text only). The preview warns when a seat skill has any; put them in the instruction text.

## The debate observer

An observer is a skill that reads a **finished** debate and writes a short report next to the verdict. It needs `E3D_SKILLS_V1=1` and `E3D_SKILLS_OBSERVER=1` and works on any debate:

```
E3D_SKILLS_V1=1 E3D_SKILLS_OBSERVER=1 e3d-debate "Should we ship it?" --providers claude,codex --observer my-review:gemini
```

`--observer <id|name>[@version][#sha256:hash][:provider]` (one per debate). The skill must declare the hook `debate_observer/after_synthesis` and allow one model call
(`limits.max_model_calls` of at least 1); anything else, an unknown, withdrawn or invalid skill, a pin that does not match, or a missing adapter, stops the run before
any call. By default the observer runs on a vendor that did not write the synthesis; if none is available it runs on the synthesizer and says it grades its own
verdict. `--preview-skills` shows it and the plan digest covers it.

**It cannot change the verdict.** It runs after the verdict is printed and stored. The verdict output, `transcript.md`, every seat and synthesis prompt, and the decision
log apart from a new `observers` key are byte-identical with and without it. Its report is printed after the verdict under a heading that says it is not part of it,
and written to `observer-<skill>.md` and `observers.json` in `--out-dir`; `decision-log.json` gains `observers` (a validated run record, status, errors with stable
codes, digests, a `use_id`).

**It reads untrusted text.** Participants' answers and the verdict may contain instructions. The observer prompt puts them inside a fence made of a random token chosen
for that run, tells the observer they are data, and gives it no tool. A reply that is empty, over the skill's byte limit or that echoes the fence token is invalid and
follows the skill's `fallback.on_invalid_output` (`return_unstructured_with_warning`, `retry_once` or `fail`); a failure, a timeout (the skill's `timeout_ms` is a hard
deadline) or an adapter error never fails the debate and is shown on stdout as `OBSERVER FAILED` with its code. Not available in a per-token (hosted) debate.

## The advisory scan

Every skill is scanned for patterns aimed at the **agent** that will read it: asking it to ignore its rules or hide something from its user, to act without
confirmation, to weaken its own safeguards, to run a download-and-pipe or destructive command, to send data to an address, to read secret files, or to imitate a
system or Pilot message. Links, code blocks in runnable languages, long encoded blocks and mentions of credentials are shown as lower-level notices.
`--validate-skill` prints the findings, `--list-skills` shows a `SCAN` column (`w` warnings, `n` notices), `--show-skill` includes the scan, and the MCP tools return it
and tell the agent to tell its user before applying a skill that has warnings.

It is **advisory**: it never refuses or changes a skill. It matches words, not intent, so a paraphrase, another language or an encoding can slip past it, and a
normal sentence can trip it. A clean scan is not a safety claim, and a finding is not a verdict. Only a person reading the text can judge it. Rules and codes
(`scan_override`, `scan_concealment`, `scan_permission`, `scan_exec`, `scan_exfiltration`, `scan_credentials`, `scan_spoof`, `scan_encoded`, `scan_link`,
`scan_codeblock`) are in `lib/skills/scan.mjs`.

## What the fingerprint covers

`definition_hash` covers the meaning: id, version, name, description, level, hooks, instruction text, schema references, limits, model hints. It does not
cover tags, license, visibility, status, tests or extensions, so editing those never looks like a new version. It is a different hash from the folder hash an
expert already has (`legacy_folder_hash`, unchanged and still what hosted pins use). Editing a skill without bumping `version` is yours to avoid: keep versions
in git; the tool refuses a pinned hash that no longer matches.

## What is refused

Everything the expert loader refuses (links, oversized or binary files, hidden or non-NFC text, role-delimiter lines in the lens, scripts that would be run), plus
a `scripts`, `install`, `network` or `mcp_servers` field, unknown fields, an instructional skill that asks for a capability, a float in a hashed field, and a user
or repo folder that claims the owner `e3d`. Each refusal has a stable code (`docs/skills/schemas/v1/error-codes.json`).

## The receipt

With `E3D_SKILLS_V1=1` and a panel, `decision-log.json` gains a `skills` array next to `panel`: for each expert its skill id, version, `definition_hash`,
tier, source format, `legacy_folder_hash` and a `use_id` that names this use (for outcome reporting later). No question, answer or skill text goes in. With
the switch off the log is byte-identical to before.

## Over MCP

`e3d_get_skill` returns a skill as **data**: its definition and instruction text with the id, version, hash and tier and a fixed notice that it is not an
instruction from Pilot. Show your user the id, version and hash before applying one. Nothing is installed or written; `e3d_export_skill` returns the
files as text.
