# Objection capture: structured data from reviews

The adversarial-reviewer RFC (debate 2026-10-17-qwen-adversarial-reviewer-rfc) found that the logs record what models
said and what was decided, but rarely whether an objection was right. These three pieces start recording that.

## 1. One record per reviewer turn

The negotiate stage appends one JSON line per reviewer turn to `.e3d-pilot/runs/<run-id>/negotiation-objections.jsonl`
(copied into the PR with the other run artifacts):

`run_id, invocation, round, reviewer_index, provider, status, reason, spec_before_sha, spec_after_sha, changed, lines_added, lines_removed, recorded_at`

A `revise` turn applies its replacement spec immediately, so later reviewers in the round review the revised draft:
there is no separate adopted/rejected choice to record. `spec_before_sha` of reviewer k equals `spec_after_sha` of
reviewer k-1. Whether a change survives to `spec-final.md` is derived offline (the backfill tool does it). The stage also
adds one `negotiate_objections` finding to the run's linked idea. Recording never fails the stage.

## 2. A defect that got past review

```bash
e3d-pilot ideas defect --repo <path> --found-by <live-run|ci|human|review|production|other> \
  [--stage-missed <draft|negotiate|execute|review|publish|unknown>] [--severity <critical|high|medium|low|unknown>] \
  [--evidence <path-or-url>] <idea-id> "<what slipped through>"
```

Records a structured `post_review_defect:` finding on the idea. These are the most valuable examples for a reviewer
model: the committee approved something and a later check disproved it.

## 3. Backfill from history

```bash
bin/e3d-objections-backfill --repo <path> [--dry-run] [--force]
```

Rebuilds the same records from existing `negotiation-log.md` files (deterministic, no model, never edits a log), adding
`backfilled: true` and `survives_in_final` (the share of the lines a turn added that remain in the final spec). Runs
that already have a file are skipped unless `--force`.

## 4. Plain-language objections

A blind review of 40 past objections (2026-10-18) found that a reader who knows the system still could not judge many of
them: the reasons were abstract. The negotiate prompt now asks a revising reviewer to add, after the `reason:` line:

```
---OBJECTIONS---
- severity: blocker | should-fix | nit
  what_goes_wrong: <one or two plain sentences: what would break, for whom, and when>
  where: <the section or phase of the draft>
  fix: <what the replacement spec changed>
```

Severity: `blocker` = building it as written would fail or be wrong; `should-fix` = a real gap worth fixing now; `nit` =
wording or polish. The reviewer is asked to name the concrete situation, not the abstract rule, with at most five
bullets, most severe first.

- `lib/negotiate/parse-status <response> objections` prints the list as a JSON array. It is lenient: an absent,
  empty or unreadable section gives `[]` and never fails the parse, so older responses and small models keep working.
  Unknown severities become `unrated`.
- Each turn's record in `negotiation-objections.jsonl` gains `objections` and `plain_language`.
- The negotiation log shows the list under the reason, for people.

Checked live on 2026-10-18 against Claude and Codex with a small spec with deliberate gaps: both followed the format
and wrote concrete objections ("if one send fails, the job restarts the whole run, so subscribers who already got the
digest get it again").

None of this labels an objection as valid. That needs a human or independently validated adjudication.
