---
selected: candidate-storage-mirror-2
reason: approved idea implementation
focus: default
---

# Candidates

## Proposed Candidates

### Candidate storage-mirror-2: Optional read-only remote mirror of a repo's idea ledger/provenance graph (v2, draft-scoped)
Duplicate: no
Dedup rationale: Corrected redo of idea-c1b4658310c4, which failed at draft: that candidate's own wording required the spec to enable the mirror in e3d-pilot's own .e3d-pilot/config.json, but .e3d-pilot/** is a protected path no automated phase may touch -- a real, correct refusal, not a bug. Same feature, scoped to code/schema only; enabling it for any repo (including this one) is left as a separate manual config edit, same as every other e3d-pilot config value.
Category: workflow
Analogy: none
Attraction (1-5): 4
Retention (1-5): 4
Effort: medium
Revenue (1-5|n/a): 1
Description: Right now every idea ledger and provenance graph lives only on the single machine that ran e3d-pilot against that repo -- .e3d-pilot/ is a local, gitignored directory, and ideas_workspace_dir() in lib/ideas/ledger.sh hardcodes '<repo>/.e3d-pilot' as the only backend. An AI session on a different machine (or a chat surface with no shell/repo access at all, e.g. a phone conversation) has no way to reach get_context/build_handoff/provenance query for a repo it isn't physically checked out on. Add an OPT-IN, config-driven, READ-ONLY mirror: recognize an optional `storage.mirror` block in `.e3d-pilot/config.json` (url, an env-var-named API key, on/off -- absent or off by default, so every existing repo's behavior is unchanged) and, when present and enabled, POST the repo's current events.jsonl plus materialized idea.json snapshots to that URL on a successful `publish`, and/or via a new on-demand CLI subcommand. This must be genuinely repo-agnostic like every other e3d-pilot feature (no fixed org/host, no assumption the mirror target is any particular company's service, since e3d-pilot is a public repo) -- the mirror endpoint is just a URL in config, nothing more. The local ledger remains the only write path and the only source of truth: no remote locking, no remote writes, no change to ideas_acquire_lock or any transition logic -- this adds a read-only copy elsewhere, nothing more. Do NOT modify .e3d-pilot/config.json or any file under .e3d-pilot/** as part of this change (protected path) -- turning the feature on for any specific repo, including this one, is an out-of-scope, separate manual config edit a human makes afterward, not something this spec does. Explicitly deferred, out of scope: any write-capable remote ledger, remote locking/leases, or a specific reference server implementation -- those depend on this read path actually proving useful first.
