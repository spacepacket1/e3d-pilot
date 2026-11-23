# Skills Gallery readiness: what to build now so a public Gallery is additive later

Status: **design note. The owner accepted the recommended defaults in section 7 on 2026-11-23** (decision 5 as amended there); no code yet. Where a sentence reports a fact, the file it comes from is in parentheses. Where it says "propose" or "recommend", it is our suggestion, not something already decided. Context: the hosted release is private-only (ADR-0024, `phase1/adr/0024-hosted-private-skills-subset.md`); a Gallery of public skills is the owner's later direction. Wording follows ADR-0021: a "track record" or "calibration" describes what was recorded, never that a skill is good or effective.

## 1. What a Gallery needs, and what we already have

| Need | Already in the definition or plan | Missing |
| --- | --- | --- |
| Stable name | `id` = `skill.<owner>.<name>`, `version` (semver), `name`, `description` (`schemas/v1/skill-definition.schema.json`, ADR-0014) | A public, human-chosen owner name (section 2) |
| Integrity | `definition_hash` over the executable fields; the engine recomputes it and refuses a mismatch (`lib/skills/canonical.mjs`, ADR-0024) | Server signature (spec 11.5 plans one; `signature` must be null in v1) |
| Who made it, where from | `owner_ref`, `provenance.{parent, forked_from, created_by, created_at}` (schema); fork lineage carries id, version and hash | A public profile page; a display name |
| Visibility and state | `visibility` private/team/unlisted/public; `status` draft/active/deprecated/withdrawn (schema) | A moderation state (not in the schema; belongs on the hosted record, section 3) |
| Safety signal | Advisory pattern scan with stable `scan_*` codes (`lib/skills/scan.mjs`); it states it is not a verdict | Secret/PII/local-path scan at publish (threat T18); human review |
| License | `license` string; proposed SPDX allow-list for public (ADR-0010, still Proposed) | Owner approval of the list |
| Categories | `tags` (max 20, display only) and `tasks` (schema; spec says tags are never used for routing) | A fixed category list |
| Evidence | Calibration: records keyed to (id, version, hash) plus stratum, evidence tiers, minimum 10 resolved uses, private to the principal (ADR-0017, 0018, 0020) | Any public or pooled record. Not representable in v1 on purpose (ADR-0020) |
| Withdrawal, reports | `status: withdrawn` checked live at run time (spec 5.1, T23); hosted spec 2.2 lists publish-preview, publish, fork, reactions, reports | Not built; hosted phase 8 |

## 2. The public handle problem

**The facts.** Hosted ids today look like `skill.u_<account id>.<name>`. The intake code requires exactly that for a hosted owner and rejects an id that does not match (`lib/skills/intake.mjs` lines 19 and 114; the pattern `^u_[a-z0-9]{6,36}$`). Two consequences follow from the hash code (`lib/skills/canonical.mjs`):

- `NON_EXECUTABLE` lists `definition_hash, signature, tags, license, owner_ref, visibility, status, tests, provenance, extensions`. So `owner_ref`, `visibility`, `status`, `license`, `tags` and `provenance` can change **without** changing `definition_hash`.
- `id`, `version`, `name` and `description` are **not** on that list, so they **are hashed** (spec 5.1 says the same). Renaming the owner segment of the id therefore changes the hash, which makes it a new skill identity, and every pin, receipt and calibration record keyed to the old (id, version, hash) points at the old one. Also, the id contains the internal account identifier, which would become visible on a public page.

**Proposal: separate the permanent identity from the public label.**

1. Keep `skill.u_<account>.<name>` as the **permanent id**. Never rewrite it. It is what hashes, pins, receipts and calibration records use, so they never break.
2. Add a **public handle** (for example `@ada`) that lives only on the hosted account/profile record, not in the definition. The Gallery shows `@ada/code-review` and resolves it to the permanent id. The handle is a lookup alias, in the same spirit as the alias table the spec already plans (ADR-0012, hosted `skillAliases`).
3. Claim and rename rules (proposed): handle is chosen at the first publish, not at signup; 3 to 30 characters, lowercase letters, digits and hyphens; one handle per account; unclaimed until used; rename allowed rarely (say once per 90 days); the old handle redirects for 90 days and is then held (reserved to the same account) so nobody can take over old links.
4. Reserved handles (proposed): `e3d`, `pilot`, `admin`, `official`, `support`, `system`, `anthropic`, `openai`, plus anything starting `u_` (the internal form) and names that look like another company or person on request. `e3d` is already reserved in the id grammar for built-ins (ADR-0014, intake).
5. Receipts, pins and calibration keep the permanent id, version and hash, and gain a display-only `handle_at_time` if wanted. A handle change then changes nothing that was recorded, and an old debate page still names the skill it used.

**What changes the hash, exactly.** Changing the handle: nothing (it is not in the definition). Changing `owner_ref`, `visibility`, `status`, `license`, `tags`, `provenance`: nothing. Changing `id`, `version`, `name` or `description`, or any instruction, hook, limit or schema ref: a new hash. Forking changes `id` (new owner segment), so a fork is always a new hash, which is correct: it is a new identity with `forked_from` pointing at the parent's (id, version, hash).

**Do now (private release) so the later move is additive:**
- Treat the owner segment of the id as an opaque internal string everywhere. Never display it, never parse it for meaning, never put it in a URL that people share.
- Resolve skills by id from the account's own records, not by string matching on the owner segment.
- Do not let a user-chosen name collide with the future handle space: `name` (the last segment) stays a slug (ADR-0014); the handle is a separate field.
- Do not copy `owner_ref` into receipts as an identity. Receipts keep (id, version, hash) (ADR-0011).
- Leave a nullable `public_handle` on the hosted account record unused. A new nullable field on a new collection is additive (ADR-0009).

## 3. Labels: verification and ranking, kept apart from the definition

All labels live on the hosted record about a published version, **never inside the definition**, so adding or changing a label can never change `definition_hash`. Every label states what it is and what it is not. This is a proposal.

| Family | Labels (examples) | Source | What it never means |
| --- | --- | --- | --- |
| Integrity | "Hash verified" (engine recomputed it), "signed by Pilot" (later), "license declared", "lineage: forked from X" | Machine | Quality or safety |
| Safety review | "Automated scan: no patterns found / N warnings", "Reviewed by a person on <date>, version X", moderation state: `pending`, `approved`, `restricted`, `removed` | Scan (`scan.mjs`), reviewer | "Safe". The scan says so itself; a clean scan is not a safety claim |
| Category | A small fixed list (proposed 10 to 15) chosen at publish; free `tags` stay for search only | Author, checked | Anything about results |
| Evidence | "Track record: 14 resolved uses, tier mix, 95% interval, X% had a recorded outcome" and only at 10 or more resolved uses in a stratum (ADR-0018) | Calibration | A score, a rank or "effective". Never pooled unless ADR-0020's separate go/no-go is passed |
| Community | Saves, reactions, fork count | Users | Evaluation. Reactions never change evaluation, permissions or verified status (hosted spec 2.2 and phase 8) |

**Must never be ranking inputs:** popularity alone (views, saves, reactions, forks); consensus among models; self-reports without their evidence tier (ADR-0017 stores `inferred` outcomes as `unknown` only); author-supplied text claims; the account's age or follower count; a clean scan. Hosted phase 8 already says ranking defaults to relevance, safety and compatibility, and performance appears only task-matched with sample size and uncertainty.

**How ranking gets gamed, and the defense:**

| Attack | Defense |
| --- | --- |
| Fake reactions, sybil accounts | Community signals shown separately and never ranked on; rate limits; one per account |
| Tuning a skill to look good (Goodhart, C-T3) | Records keyed to immutable versions; a new version starts empty; no pooled public score |
| Cherry-picked outcomes | Always show resolution rate and tier mix beside any success figure; minimum 10 resolved |
| Fork spam to copy a good record | A fork starts with an empty record and shows lineage, never inherits the parent's |
| Name squatting, look-alike names | Reserved handles; display the permanent hash prefix; report path |
| Hidden malicious text that passes the scan | Scan is advisory; human review for a "reviewed" label; reports and appeals; withdraw and takedown |
| Popularity feeding permission or "verified" | Forbidden by design (hosted phase 8) |

## 4. The publish flow (proposed, from hosted spec 2.2 and phase 8)

1. **Preview, before anything is public:** exact version and hash, the full text that will be public, license, scanner findings, lineage, and the list of irreversible disclosures. Publish needs the exact preview token and a human confirmation that a model cannot supply (hosted spec 2.2: a phrase visible to the model is not authorization).
2. **Irreversible disclosures to state in the preview:** the full instruction text becomes readable by anyone; copies may be forked or exported and cannot be recalled (ADR-0010); the handle and display name appear; the license applies to everyone who copies it; the version is immutable.
3. **License:** public or unlisted needs an SPDX identifier from the allow-list (proposed in ADR-0010: MIT, Apache-2.0, CC0-1.0, CC-BY-4.0, CC-BY-SA-4.0). Forks inherit it and may not relicense.
4. **Blocking checks:** secrets, personal data, local paths, private evidence references (threat T18, T16). A finding blocks until fixed.
5. **Forks and lineage:** a fork is a private draft with `provenance.forked_from = {id, version, hash}` and attribution kept (hosted spec 2.2, ADR-0010). Updates to the parent are offered, never auto-applied.
6. **Withdrawal:** sets `status: withdrawn`, checked live, so **new** runs stop. It does not delete past receipts or erase copies already forked (ADR-0010, ADR-0011 keeps minimal lineage so forks stay attributed). Past runs keep their (id, version, hash) pin. The UI must say this plainly.
7. **Takedown:** the operator can move a version to `removed` for abuse, security or license reasons, with an audit entry and an appeal path (hosted spec 2.2 reports; phase 8 appeals). Removal hides the text on public pages but keeps hash and id, so receipts still resolve to "removed".
8. **Moderation states (proposed):** `pending` (visible to the author only), `approved`, `restricted` (unlisted, no ranking), `removed`. Stored on the hosted record, not the definition.

## 5. Private skills, published debates, receipts and the Gallery

The owner's rule: publishing a debate that used private skills is the owner's explicit choice; show which skill names appear, never the skill text unless that skill is itself published. What this implies:

| Situation | What the public page shows |
| --- | --- |
| Debate used a private skill | Display name and version label only, plus "private skill" and the hash prefix if the owner allows. Never the text, scan findings text, or calibration detail |
| Debate used a published skill | Handle/name, version, hash, a link to the published page |
| Skill published later | Old debates may then link to it; the pin (id, version, hash) must match a published version, otherwise it stays "private at the time" |
| Skill withdrawn after use | Debate page keeps the name and hash; the link says withdrawn |

Receipts keep (id, version, hash) and metrics, never the body (ADR-0011), so this rule needs no new data. What is needed: the publish-debate preview lists every skill name that will appear and lets the owner remove the skill block entirely; and a "names appearing" disclosure is part of the irreversible list. Proposal: a private skill's name can itself be sensitive, so the preview names them one by one and the default is that they are hidden.

## 6. Phased path

| Phase | What ships | Needs first | Defer |
| --- | --- | --- | --- |
| A. Private (now, ADR-0024) | Private skills, receipts with (id, version, hash), scan on save | Nothing new; the "build now" list below | Everything public |
| B. Unlisted | Share by link; fork privately; license required; preview and confirm; reports | Handle claim, ADR-0010 list approved, publish preview with secret scan, withdrawal semantics, moderation state field | Search, ranking, reactions |
| C. Public, curated | Gallery listing by category and handle; profile pages; human review label; reactions shown separately | Moderation staffing and appeals, takedown process, reserved names enforced, T-H10 threat work (poisoned shared skill) | Evidence labels, ranking by performance |
| D. Evidence shown | Per-skill "track record" for the viewer's own use only (already private, ADR-0020) | Calibration data gates (ADR-0018) | Pooled public records |
| E. Ranked | Ranking by relevance, safety, compatibility; evidence only task-matched with interval | Separate go/no-go ADR for pooling (ADR-0020), 200 resolved outcomes across 20 principals before recommendations (ADR-0018) | Payouts, paid marketplace (own go/no-go, phase 8 step 8) |

## 7. Decisions for the owner (recommended default)

| # | Decision | Recommended default and why |
| --- | --- | --- |
| 1 | Public identity model | A separate public handle chosen at first publish, permanent internal id unchanged. Renaming the id would change hashes and orphan pins and receipts |
| 2 | Handle rename policy | Rename at most once per 90 days, old handle redirects then is held for that account. Stops link rot and squatting |
| 3 | Reserved names | `e3d`, `pilot`, `admin`, `official`, `support`, `system`, plus major AI companies. Prevents impersonation |
| 4 | License allow-list (ADR-0010) | Approve the five SPDX ids as written. Lets us scan and enforce attribution |
| 5 | Are private skill names shown on a published debate | **Amended by the owner's direction:** publishing a debate is the owner's explicit choice and is never blocked. The publish preview lists the skill names, versions and hashes that will appear, and the owner can hide a name. The skill text is never part of it |
| 6 | First public step | Unlisted before public, curated before open. Smaller blast radius while moderation is untested |
| 7 | Who reviews and what a "reviewed" label means | Label states reviewer, date and version only; staff only at first. Avoids implying "safe" |
| 8 | Moderation staffing and appeals | Named owner and a response time before phase C. Public text without a takedown process is a liability |
| 9 | Pooled public track records | Stay off (ADR-0020). Goodhart and poisoning risk |

## 8. Build or avoid now in the private release

Build or keep:
- The id stays `skill.u_<account>.<name>` and is treated as opaque; no UI or URL shows the owner segment.
- Keep `visibility` values `private, team, unlisted, public` and `status` values `draft, active, deprecated, withdrawn` in the schema (already present; hosted release accepts private and active only, ADR-0024).
- Keep `owner_ref`, `license`, `tags`, `provenance` outside the hash (already true); keep `license` a required string and encourage an SPDX id in the editor so most skills are already publishable.
- Store scan output next to the version record, not in the definition; keep the stable `scan_*` codes.
- Store versions immutably with (id, version, hash) as the key; never edit a version in place.
- Calibration records keyed to (id, version, hash) and private (ADR-0017, 0020).
- Plan the new hosted fields as separate nullable additions: `public_handle` (account), `moderation_state` and `published_at` (version), label rows in their own collection.

Avoid:
- Putting handle, labels, moderation state, ratings or counts inside the definition (would change the hash or break strict schema).
- Using `tags` for routing, ranking or permission (spec says display only).
- Showing or logging the internal account identifier publicly.
- Any aggregate or popularity number across users.
- Copy that says "verified", "best", "effective", "improves" (ADR-0021, spec 3.2).
- A signature or `visibility` other than private on the hosted path before the moderation work exists.

## 9. What we could not verify

- The hosted account model (whether an account id can be exposed or changed) was not inspected; only the engine's rules were.
- Whether Gallery profile or handle infrastructure already exists for debates in the cloud repo (hosted spec 3 mentions "profile pages" for phase 8 only).
- Legal review of license, takedown and attribution duties (this note is not legal advice; the allow-list in ADR-0010 is itself unapproved).
