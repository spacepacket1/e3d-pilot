# Skills (local, instructional)

A skill is a reusable set of instructions with an identity: an id, a version and a fingerprint (`definition_hash`) computed from what it says. This
page is the user guide for the local commands. The design, contracts and decisions are in `docs/skills/` (start at `docs/skills/README.md`).

Everything here is **off by default** and **local**: no command calls a model or the network, nothing is run from a skill folder, and a skill grants no
tool, flag or permission. Skills are perspectives, not measured improvements.

## Turning it on

| Switch | Turns on |
| --- | --- |
| `E3D_SKILLS_V1=1` | the `--list-skills`, `--show-skill`, `--validate-skill`, `--project-expert`, `--export-skill`, `--diff-skill` commands, and a `skills` block in the receipt of a debate that uses experts |
| `E3D_CALIBRATION_V1=1` | the local calibration commands (`--skill-record`, `--report-outcome`, `--my-calibration`, `--delete-outcome`, `--compact-calibration`) and a note of each skill use of a receipt in the local store; see [Calibration (local)](#calibration-local) |
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

**It cannot change the verdict.** It runs after the verdict is printed and stored. **stdout is byte-identical** with and without it (consumers parse stdout as the verdict), and so
are `transcript.md`, every seat and synthesis prompt, and the decision log apart from a new `observers` key. The report is shown on **stderr** under a heading that says it is
not part of the verdict, and written to `observer-<skill>.md` and `observers.json` in `--out-dir`; `decision-log.json` gains `observers` (a validated run record: status, errors
with stable codes, digests that bind the exact data and prompt, a `use_id`).

**It runs without tools.** The observer reads text written by models, so it runs only on an adapter that cannot use tools: `claude` (started with its tools off) or a plain
chat API adapter (`anthropic-api`, `openai-api`, `gemini-api`, `xai-api`, `openrouter`, `azure-openai`, `bedrock`). `codex`, the `gemini` CLI, `grok-build`, `devin`, `local` and the
MCP sampling adapters have real tools or no switch to turn them off, and are refused before any call. If you have verified another adapter, name it in
`E3D_SKILLS_OBSERVER_ADAPTERS` (comma list).

**It reads untrusted text.** Participants' answers and the verdict may contain instructions. They come from the engine's own answer files, not from a re-read of the transcript, are
cleaned of every control, zero-width and bidirectional character, and sit inside a fence made of a random token chosen for that run. The prompt says they are data and gives the
observer no tool. The whole prompt is cut to fit the skill's `max_input_bytes`. A reply that is empty, over the skill's byte limit or that echoes the fence token is invalid and follows
the skill's `fallback.on_invalid_output` (`return_unstructured_with_warning`, `retry_once` or `fail`); an adapter error or a timeout is a failure. The skill's `timeout_ms` is a hard
deadline for the adapter **and everything it started** (also on Ctrl-C). A failure never fails the debate; it is shown on stderr as `OBSERVER FAILED` with its code. Not available in a
per-token (hosted) debate.

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

## Calibration (local)

Off unless `E3D_CALIBRATION_V1=1` (unset, empty or `0` is off; any other value refuses to start with exit 2). Everything here is local: no model, no network, no account. Spec: `docs/skills/spec/e3d-pilot-calibration-spec-v0.1.md`; decisions: ADR-0016 to ADR-0021.

**What a track record is.** A description of what was recorded when one exact skill (id, version, `definition_hash`) was used on one kind of task: how many uses, how many were marked worked or failed (the resolved uses), how many were marked unknown, where the outcomes came from, and an interval around the share marked worked. It is derived from your own records every time you ask and is never stored.

**What it is not.** It is not a claim about the skill, a comparison between skills, a verdict, or a prediction. Outcomes are marked by you (or your agent), are not checked by Pilot, and may be missing for most uses, which is why the share of uses marked worked or failed, the share of uses made with the reminder on, the source mix of the outcomes and the number of corrections are always printed beside the rate. There is no ordering of skills and no single number for a skill. Nothing in it changes a default, a panel or a skill.

```
E3D_CALIBRATION_V1=1 e3d-debate --skill-record skeptic [--skill-version V] [--skill-hash H] [--task-class C] [--skill-mode M] [--model-family F] [--json]
E3D_CALIBRATION_V1=1 e3d-debate --report-outcome use_... --result worked|failed|unknown [--json]
E3D_CALIBRATION_V1=1 e3d-debate --my-calibration [--json]
E3D_CALIBRATION_V1=1 e3d-debate --delete-outcome use_... [--json]
E3D_CALIBRATION_V1=1 e3d-debate --compact-calibration [--json]
```

| Command | What it does |
| --- | --- |
| `--skill-record` | Prints the record for each (version, hash, kind of task, mode, model family) of a skill you have used. A bare name that matches two skills is refused; use the full id. Under 10 resolved uses it prints no rate and exits 1 with `skill_record_insufficient` and the counts. |
| `--report-outcome` | Records how a use went (`worked`, `failed` or `unknown`) against its `use_id`, as a user-marked outcome. A later report for the same use supersedes the earlier one and keeps it in the file; the same report twice changes nothing. |
| `--my-calibration` | Every record you have, grouped by skill. Groups under the minimum are listed with their counts and no rate. |
| `--delete-outcome` | Removes the outcomes of one use from the records (a recorded deletion; the record recomputes without them). |
| `--compact-calibration` | Applies retention and removes deleted, unreadable and expired lines from the files by an atomic rewrite. |

**Where a `use_id` comes from.** With `E3D_SKILLS_V1=1`, `E3D_CALIBRATION_V1=1` and a panel, each skill entry of the receipt (`decision-log.json`) already carries a `use_id`; the debate also notes that use in your local store, issued at the receipt's own time (`ts`) and valid for 90 days from it. A receipt older than 90 days or dated in the future is refused, so replaying an old receipt cannot create a fresh use. Each use carries `run_ref` = `skr_` plus 24 hex digits of the receipt's SHA-256, so the uses that were active together in one receipt can be found again. Calibration cannot be combined with hosted skills (`--hosted-skills`, `E3D_SKILLS_HOSTED=1`): a hosted run serves many people and this store belongs to one, so it refuses to start. The module `lib/calibration/cli.mjs` checks the switch itself and cannot be run around it. After that `--report-outcome` refuses with `skill_use_expired`; an id that was never issued here is `skill_use_not_found`. The kind of task is `unclassified` unless you set `E3D_CALIBRATION_TASK_CLASS` (3 to 40 characters: lower-case letters, digits, single hyphens) for the run; the mode is `debate_seat` and the model family `unknown` in this release. With the switch off the receipt and every output are byte-identical to before.

**Where it lives.** `~/.config/e3d-pilot/calibration/` (override with an absolute `E3D_CALIBRATION_DIR`): `uses.jsonl` and `outcomes.jsonl`, append-only, one record per line, directory mode 0700 and files 0600. A symbolic link, a file owned by someone else or one open to group or others is refused (`skill_scope_denied`). Files are capped at 4 MiB (`skill_too_large`) and a line at 4096 bytes. Writers take a lock file (`pid:host:nonce`). A lock held by a live process on this machine is kept for up to 10 minutes; a lock from another host (a container, a shared home directory) is treated as alive for the same time; a lock whose process is gone, or that has had no readable owner for 2 seconds, is taken over at once. Past 10 minutes a lock is taken over even from a process that is only suspended, and a command that resumes after that finds out before it replaces any file (`--compact-calibration` stops without writing). Takeovers are serialised by a second lock file, and a holder removes only a lock that still holds its own text and inode. A lock path that is not a regular file is reported by name. A line that does not parse, fails its schema or its wrapper, repeats an id, or forks a chain of corrections (an outcome that does not follow the current one) is ignored and counted. A hard-linked data file is refused. Only the final path component and the file itself are checked for links, not the parent directories. Uses and outcomes are kept 365 days; `use_id` accepts a report for 90. Nothing is shared or pooled: the records belong to this machine and this user.

**What is stored.** Identifiers, enums, counts and timestamps. There is no field for text of any kind: unknown fields and any value outside its enum, id or timestamp pattern are refused (`skill_outcome_invalid`), so a note, a question, an answer or skill text cannot be written. Likes, saves, forks and silence never create an outcome. A time must be a real instant and an outcome may be dated at most one day ahead of the clock.

**How the numbers are made.** A use is resolved when it has a current outcome marked worked or failed by a tier other than `inferred`. `unknown` and `inferred` outcomes are stored and not counted as resolved; an unmarked use is unresolved, not a failure. The share marked worked comes with a 95% Wilson interval (z = 1.959964). A record needs at least 10 resolved uses; below that the answer is "not enough resolved outcomes". Uses younger than the horizon of a stated prediction are unresolved until they pass it. Reliability bins would need 30 resolved predictions in each bin, and this release has no prediction capture, so `calibration` is always null and the record is `descriptive`. The comparison with uses without the skill (`baseline`) is null for the same reason: the store holds only skill uses.

Example of what it prints (one line): `skill.e3d.skeptic 2.0.0 on architecture-review (debate_seat, unknown): in your 17 resolved uses, 12 were marked worked (approximate 95% interval 46% to 87%); 41% of 41 uses were marked worked or failed; 0 marked unknown and 0 inferred (not counted as resolved); outcome sources: 2 with an artifact digest attached as evidence, 11 user-marked, 4 host-reported; 22% of uses were made with the reminder on; 0 corrections on file`. Shares round to the nearest percent, except that a share that is not exactly 0 or 1 prints as "under 1%" or "over 99%" rather than 0% or 100%; the interval rounds outward (lower bound down, upper bound up) from the unrounded bounds, so it is never printed tighter than it was computed. The JSON carries the exact 4-decimal numbers, and `details` beside each record (`n_unknown`, `n_inferred`, `corrections`). If lines of the files could not be read they are ignored and the output says how many (`unreadable_lines` in JSON); `--compact-calibration` removes them.

**Known limits.**
- Two terminals reporting on the same use: whichever takes the lock second supersedes the first without being told (both outcomes stay in the file until compact). The record counts the later one.
- Timestamps may be at most 5 minutes ahead of the clock.
- The task class is a free slug (3 to 40 characters from `E3D_CALIBRATION_TASK_CLASS`), so a very specific value can identify a piece of work; it is a re-identification risk in the sense of threat C-T4 and matters when records are ever shared. Keep it coarse.
- There is no export command yet (ADR-0019 item 5); the files are plain JSONL and can be read as they are.
- Horizons are measured from `issued_at`, and prediction capture does not exist yet. The reliability-bin code (`calibrationBlock`) coerces its input and is not reachable from the commands; a later phase that feeds it predictions must validate them against `prediction.schema.json` first.
- A `use_id` whose use aged out (365 days) and was removed by `--compact-calibration` could in principle be registered again, but only from a receipt dated within 90 days, which cannot be the same receipt. A `use_id` that still has outcomes or a deletion on file is never registered again.
- **Phase 3 (MCP) must not reuse this path as it is.** `register-uses` trusts a receipt written on this machine by this engine; an MCP or hosted adapter must issue use_ids itself, bind them to the authenticated principal, and apply its own rate limits and replay checks.

Errors are the stable codes of `docs/skills/schemas/v1/error-codes.json`: `skill_use_not_found`, `skill_use_expired`, `skill_outcome_invalid`, `skill_outcome_conflict`, `skill_record_insufficient`, `skill_scope_denied`, `skill_too_large`, `skill_not_found`. With `--json` an error is printed on stdout as `{"ok":false,"error":{"code","message"}}`; the line `error: <code>: <message>` always goes to stderr.

## Hosted skills (E3D_SKILLS_HOSTED, skills phase 3c)

For a hosted service only; a person never uses this. `bin/e3d-debate --hosted-skills FILE` runs a debate with the skills of one user of a hosted service. The service writes the file, `{ "principal": "u_...", "skills": [definition, ...] }` (1 to 4 definitions, at most 256 KiB), and starts the debate with `E3D_SKILLS_V1=1`, `E3D_SKILLS_HOSTED=1` (plus `E3D_SKILLS_SEATS=1` and `E3D_SPECIALISTS=1` for seats) and `--builtin-only`, so no folder on the host is read.

- Every definition goes through the engine's own checks (`lib/skills/intake.mjs`): the hash is recomputed and a mismatch is refused, the owner must be the authenticated principal, the skill must be private, active and instructional, every string is checked for hidden characters, and the sizes are bounded. One refused definition refuses the whole run before any model call. The error names codes, never the skill text.
- A hosted skill is tier `hosted` and is reached **only by its full id** (`skill.u_<id>.<name>`), never by a bare name, and never shadows a built-in.
- Seats and the observer use the same code as local skills: `--seat-skill skill.u_<id>.<name>[@version][#sha256:...]`, `--preview-skills`, `--expect-plan`, the receipt `skills` block and the plan digest all work unchanged.
- **An observer in a per-token (hosted) debate** runs only with the limits the quote priced, passed together as `E3D_DEBATE_OBSERVER_MAX_TOKENS` (1 to 4096: the vendor output limit of its one call) and `E3D_DEBATE_OBSERVER_INPUT_BYTES_MAX` (1 to 256000: the most prompt bytes it may be sent; the smaller of this and the skill's own `max_input_bytes` wins). The provider is named (`--observer <skill>:<provider>`), never chosen by the engine, and must be an API adapter with an output-limit setting (not `claude`). The call is never retried, even for a skill that asks for `retry_once`, and writes its own usage row `observer:<skill>` (the vendor's counts, or an estimate at the quoted limit when the debate is stopped while it runs). Limits without `--observer`, one limit without the other, or `--observer` without limits are refused before any call. If even the smallest prompt does not fit the input bound, the observer is skipped and the debate is unaffected.

## The hosted listener (skills_v1, skills phase 3c, PR H2c)

For the hosted service's run listener (`POST /internal/runs`, loopback, `docs/external-auth.md`); a person never uses this. The listener accepts hosted user skills as debate **seats** and as the debate **observer**, behind the capability `skills_v1`, and runs them through `bin/e3d-debate --hosted-skills` (above). Field names, ranges and the idempotency rule are in `docs/skills/phase3/plan-3c-hosted-user-skills.md`, section 3, "Listener fields".

- **Switches.** `skills_v1` is advertised (next to `per_token_v1`, in the 400 an empty run request gets) only with `E3D_MCP_SKILLS_RUN=1`, `E3D_SKILLS_V1=1`, `E3D_SKILLS_HOSTED=1` and `E3D_MCP_PRICING=per_token`. `E3D_SKILLS_SEATS=1` lets seat attachments in and `E3D_SKILLS_OBSERVER=1` lets the observer attachment in; an attachment whose switch is off is refused 400 `invalid`. Each of the five is unset, empty, `0` or `1`; anything else refuses to start (the last four are read only when `E3D_MCP_SKILLS_RUN=1`, and `E3D_MCP_SKILLS_RUN=1` needs per-token pricing). With any switch off the new fields are refused like any unknown field and nothing else changes: every other request, answer and test is byte for byte what it was.
- **What a run does.** The listener checks every definition with the engine's own intake (`lib/skills/intake.mjs`: hash recomputed, owner equals `skills_principal`, private, active, instructional, hidden characters, sizes) BEFORE anything is held, so a refused definition is a 400 `invalid` with stable `skill_*` codes and no skill text, and nothing is charged. It then writes ONE file `{ principal, skills }` into the run's private directory (file mode 0600, directory 0700, created for that run) and starts the debate with `--builtin-only --hosted-skills FILE`, one `--seat-skill <id>@<version>#<hash>:<target>` per seat attachment, `--observer <id>@<version>#<hash>:<provider>` for the observer, `--fill-pool --lens-bytes-max <skill_bytes>` when there are seats (providers without a skill stay plain seats), and the environment `E3D_SPECIALISTS=1`, `E3D_SKILLS_V1=1`, `E3D_SKILLS_HOSTED=1`, `E3D_SKILLS_SEATS=1` and/or `E3D_SKILLS_OBSERVER=1` as used, plus the quoted observer limits (`E3D_DEBATE_OBSERVER_MAX_TOKENS`, `E3D_DEBATE_OBSERVER_INPUT_BYTES_MAX`). The engine runs the same intake again when it starts, so a definition changed after planning is refused before any model call. The file is removed as soon as the engine exits and its directory in every exit path, including errors and a cancelled run.
- **Strict choices where the plan was silent** (each is the strictest option; say so if the cloud needs another): a run has any number of seat attachments from 0 to 4 (one skill is enough: that seat carries it and the other seats of the panel run plain, with `--fill-pool`), at most one observer, seat targets distinct and in the request's `providers` (which a seat attachment therefore needs), the same skill on at most one seat (it may also be the observer), one id with one definition only, `experts` and skills in the same request are refused (`400 invalid`), `skill_bytes` is the TOTAL instruction bytes of the distinct skills of the run (the sum of each `instructions.method`, a skill that is a seat and the observer counts once), and the observer adapter must be one this server can price per token (`anthropic-api`, `openai-api`, `gemini-api`, `xai-api` when allowed, or an enabled `or-` voice; never `claude`). The request body limit is 256 KiB on a listener with `skills_v1` (64 KiB otherwise) so that four 48 KiB definitions fit; each definition's raw size is checked against 48 KiB before anything reads it deeper.
- **Nothing is kept or logged.** The log carries counts and an intake digest (`skills: hosted run seats=2 observer=1 skills=2 digest=...`), never a definition, a word of its text or the principal. The run state keeps the definitions only while the run is queued or running (a restart must still be able to run it) and drops them when the run ends. Errors carry codes only.
- **The observer's usage row.** The observer is a quoted line of the bill. Its row (key `observer:<skill name>`, provider the adapter) goes to the billing service in the same usage report as the seats' rows when the run has an observer; the billing service must accept that key before `E3D_SKILLS_OBSERVER=1` is set on this listener. Without an observer attachment a row with that key is dropped as malformed, as before.
