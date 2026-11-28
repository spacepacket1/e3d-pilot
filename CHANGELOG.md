# Changelog

## 0.3.1

Hardening and one hosted-only capability. Nothing changes for the local package: with no new switch set, behaviour is the same as 0.3.0.

- Hosted chat can run one hosted user skill per message. The server advertises the capability `chat_user_skills_v1`. It is off unless `E3D_MCP_CHAT_USER_SKILLS=1`, `E3D_MCP_CHAT=1` and the skills-run seats switch are all set; without the switch a request gets a 409 `skills_unavailable`. This is for hosts only; the local package does not use it.
- Provider adapters no longer write API keys to a temporary file, and keys are no longer in process arguments: the key header is piped to curl. Work directories are cleaned up when the adapter gets TERM, and the hosted listener removes stale leftover work directories at startup.
- Chat and recap adapters are now ended with SIGTERM first, so the adapter's own cleanup runs, and with SIGKILL only after 5 seconds.
- CI-only test fixes (jq binding, shared tmp scan, Node 20 load log, calibration-local on Linux). No behaviour change.

Not in this release: skills in the `e3d_debate` MCP tool, a public skills gallery, pooled calibration, automatic skill selection, more than one user skill per chat message, any change to the 0.3.0 local skills or calibration features.

## 0.3.0

Local skills, opt-in and off by default. With no switch set, behaviour is the same as 0.2.0 for skills; this release also contains the other engine changes merged since 0.2.0 (see the git history since the `v0.2.0` tag).

- Skills: versioned instructions with an id, version and fingerprint (`definition_hash`). Commands to list, show, validate, project, export and diff them (`--list-skills` and friends). `E3D_SKILLS=1` is the one switch for local use.
- Skills on seats (`--seat-skill`) and a read-only debate observer (`--observer`) that never changes the verdict; `--preview-skills` shows the plan and digest with no model call.
- Calibration (local, `E3D_CALIBRATION_V1=1`): record uses and outcomes in a local store and see a track record with Wilson intervals and a minimum count. It is a record of what was written down, not a claim that a skill helps. The local commands pool nothing and send nothing.
- Calibration over MCP, local stdio only and **off by default**: with `E3D_MCP_SKILLS=1`, `E3D_CALIBRATION_V1=1` and `E3D_CALIBRATION_MCP=1` all set, an agent can fetch a skill with a use ticket, read the local track record (`e3d_skill_record`, `e3d_my_calibration`: a rate only from at least 10 outcomes you marked or that are verified), and report a use or outcome, or delete outcomes, but only after you accept a confirmation dialog (MCP elicitation) that states what will be written. A decline, Esc, timeout or a host without elicitation writes nothing. This has been checked in interactive Claude Code only; Codex is untested, and VS Code and the desktop app cancel the dialog unless a hook accepts it.
- Calibration CLI: `--report-outcome` stores a user-marked outcome only when stdin and stdout are a terminal; from a pipe, a file or an agent's shell it stores a host-reported one, which never replaces a user-marked outcome. `--delete-outcome` needs a terminal. This labels who marked it; it is not a security boundary.
- Hosted-side support for private user skills (intake checks, per-token observer, run listener fields). These stay off unless a host enables them; the local package does not use them.
- Read-only MCP skill tools behind `E3D_MCP_SKILLS=1` (local stdio server only).

Not in this release: skills in the `e3d_debate` MCP tool, a public skills gallery, pooled calibration, automatic skill selection.
