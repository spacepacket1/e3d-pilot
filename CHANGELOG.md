# Changelog

## 0.3.0 (preview)

Local skills, opt-in and off by default. With no switch set, behaviour is the same as 0.2.0 for skills; this release also contains the other engine changes merged since 0.2.0 (see `git log v0.2.0..v0.3.0`).

- Skills: versioned instructions with an id, version and fingerprint (`definition_hash`). Commands to list, show, validate, project, export and diff them (`--list-skills` and friends). `E3D_SKILLS=1` is the one switch for local use.
- Skills on seats (`--seat-skill`) and a read-only debate observer (`--observer`) that never changes the verdict; `--preview-skills` shows the plan and digest with no model call.
- Calibration (local, `E3D_CALIBRATION_V1=1`): record uses and outcomes in a local store and see a track record with Wilson intervals and a minimum count. It is a record of what was written down, not a claim that a skill helps. Nothing is pooled or sent anywhere.
- Hosted-side support for private user skills (intake checks, per-token observer, run listener fields). These stay off unless a host enables them; the local package does not use them.
- Read-only MCP skill tools behind `E3D_MCP_SKILLS=1` (local stdio server only).

Not in this release: skills in the `e3d_debate` MCP tool, a public skills gallery, pooled calibration, automatic skill selection.
