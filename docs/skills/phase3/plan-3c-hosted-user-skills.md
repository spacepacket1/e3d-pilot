# Phase 3c plan: hosted user skills (private only first)

Status: **approved by the owner on 2026-11-23 with the recommended defaults for D1 to D7.** Scope: users create, version and run their **own private** skills on the hosted Pilot service, as debate seat skills and debate observers. This is the hosted form of the vision (create, manage, run, keep the record). Companion to `plan.md` (3a, 3b merged) and to `docs/skills-hosted-spec.md` in the cloud repo (observer pricing contract, section 2.4).

## 1. What is in and out

| In (first release) | Out (later, each its own review) |
|---|---|
| Private skills, visible only to their owner (and revealed to nobody else, in no listing, cache, log or analytics) | Sharing, teams, forking, Gallery, publishing, reactions, marketplace |
| Instructional skills only (no tools, no memory, no learning) | Tool, memory, learning or composed skills |
| Hooks: debate **seat** skill and debate **observer** | Chat `after_response` (decided: not in v1) |
| Create, new immutable version, deprecate, list, view, delete (account deletion included) | Aliases, compositions, evaluation runs |
| Plan preview and quote with the observer line (hosted spec 2.4) | Per-skill billing or author revenue |
| Library list/editor, attach to a debate, run inspector (minimal) | Rich editor, test runner, diff views |

## 2. Where the pieces live today

- **Engine** (merged): definition format, hash, validator, scanner, seat skills with pins and plan digest, observer. All read skills from **folders on the engine's disk**.
- **Cloud** (merged): quote-then-execute billing, the loopback listener contract (`experts_v1`: ids and hashes checked against the engine's own catalogue), the pricing contract for the observer. **No skill registry, no user skill storage, no routes.** Hosted spec phases 2 to 7 are not built.
- **Gap:** the engine never receives skill text over the loopback. A user skill lives in the cloud database, so the cloud must send the definition and the engine must accept it safely.

## 3. The contract between cloud and engine (the heart of 3c)

New listener capability `skills_v1`, advertised only with `E3D_MCP_SKILLS_RUN=1`, `E3D_SKILLS_V1=1`, `E3D_SKILLS_SEATS=1` (and `E3D_SKILLS_OBSERVER=1` for observers) and per-token pricing. Off: the new fields are refused like any unknown field (today's behaviour).

Request fields (all strict; unknown keys refused):

- `skill_attachments`: 1 to 4 objects `{ attachment_id, hook: "seat"|"observer", target (provider name, seats only), definition }`.
- `definition`: exactly the executable fields of a skill (id, version, instruction text, hooks, limits, fallback, capability_level `instructional`, no requested capabilities) and `definition_hash`.
- `skill_bytes`: the total instruction bytes the cloud priced (like `lens_bytes`); the engine refuses a run whose actual bytes exceed it.
- Observer: `observer_reserve` fields exactly as quoted (model, output cap, input bound) so the engine can refuse a run that would exceed them.

Engine rules (the engine is the authority, the cloud's hash is a claim):

1. Recompute `definition_hash` from the received fields (canonical form); mismatch means refuse **before any model call**.
2. Validate with the existing schema validator and the 2a hardening checks (hidden characters, normalisation, lens-marker spoofing). Refuse on any finding; the scanner is advisory and its findings go into the receipt.
3. Accept `capability_level: instructional` only. Anything requesting tools, memory or learning is refused (`skill_capability_denied`).
4. Hard caps: attachments, bytes per skill, total bytes, nested depth, number of fields, string length. Reject, never truncate.
5. Never put request text in a file path or shell argument. The definition is held **in memory**; a new `lib/skills/intake.mjs` builds the same in-memory skill object the folder loader builds (`skillFromDefinition`), so seats and the observer use the code that is already reviewed. If a staging file is unavoidable, it is a private 0700 per-run directory, removed in all exits.
6. The attachment is bound to the run: `attachment_id` and the plan digest are in the receipt; a changed byte changes the digest.
7. Observer: the existing path (one read-only call, no tools, fenced prompt, byte cap, stdout untouched). The adapter must pass the tool policy; an adapter that cannot be made tool-less is refused.
8. Per-run usage row for the observer so billing can reconcile `reserved`, `charged`, `refunded`.

## 4. Cloud work (summary; detail in the cloud repo's phase text)

- **Collections** `skills` and `skillVersions` (immutable), indexes added in `src/db.js`; no change to existing collections; a dry-run-only migration framework is not needed because nothing is backfilled in this slice.
- **Routes** under `/api/skills...` (create draft, new version, deprecate, list, get, delete). Session-authenticated; idempotency keys on every write; quotas; **owner-only reads** enforced in one function used by every read path.
- **Validation on save:** the same canonical hash and the same schema (the cloud ships the engine's schemas), scanner on every save with findings shown to the author.
- **Run wiring:** debate builder attaches skills by `(skill id, version)`; the cloud sends the definition on the loopback; the quote prices skill bytes and the observer line per section 2.4; the receipt and run inspector show skill@version and hash.
- **Deletion and retention:** account deletion removes skills and versions and keeps financial and minimal audit rows (hosted spec 4.3).
- **Flag:** `PILOT_SKILLS_ADAPTER` plus an allowlist for the first users (see D3).

## 5. PR sequence

| PR | Repo | Content | Pins |
|---|---|---|---|
| H1 | engine | `lib/skills/intake.mjs`: in-memory definition intake (hash recompute, validate, hardening, capability ceiling, caps), no listener yet | unit cases incl. oversized, duplicate and unknown keys, wrong types, hash mismatch, hidden characters, tools requested; same result as the folder loader for the same skill |
| H2 | engine | listener capability `skills_v1` and fields; mapping to seat skills and the observer; refusal rules; receipt fields | flag off equals today byte for byte; every refusal happens before a model call; a stub run with two skills and an observer |
| C1 | cloud | collections, indexes, owner-only read function, create/version/deprecate/list/get/delete routes, quotas, idempotency, account deletion | cross-user and anonymous access denied on every route, cache and log; quota race test |
| C2 | cloud | run wiring: attach, loopback send, quote with observer line, receipt, idempotency covering the observer line, comped-grant rule | quote mismatch, replay refused, reserve never exceeded, observer failure refund rule |
| C3 | cloud | minimal UI: library, editor, attach in the debate builder, run inspector; **escaped rendering of observer output** | XSS test with hostile observer text; UI and API receipts agree |
| H3/C4 | both | adversarial suite through the real hosted path, adapter audit, independent security review, tenant canary | see section 7 |

Merge order: H1, H2, then C1 to C3 against the merged engine. Each PR has its independent Sonnet review recorded in `review-record.md`; the H3/C4 review is a dedicated security review.

## 6. New threat model rows (to add with H1)

| Id | Threat | Control |
|---|---|---|
| T-H1 | Stored prompt injection: a saved skill text steers its model | private-only (the author is the only reader and the only victim); fenced prompts; observer no tools; never given extra permissions |
| T-H2 | Tenant isolation failure: one user reads or runs another's skill | one owner-check function, tests on every route, cache and log; ids unguessable; attach by owner check at quote **and** at run |
| T-H3 | Definition smuggling: extra fields, huge or deep JSON, unicode tricks | strict schema, caps, 2a hardening, engine recomputes the hash |
| T-H4 | Hash confusion or time-of-check change between quote and run | engine recomputes; plan digest in the receipt; quote pins version and hash |
| T-H5 | Observer output rendered as HTML (stored XSS) | escape on every render; tests with script and markup payloads |
| T-H6 | Cost abuse: huge skills, many observers, retry storms | caps, reserve inside `max_credits`, idempotency covering the observer line, per-user quotas, rate limits |
| T-H7 | Skill text leaking into logs, analytics, error messages, support tools | never log definitions; aggregates only; redaction test |
| T-H8 | An adapter with tools enabled reachable by a seat or observer | audit the production adapter list; refuse unsafe adapters for observers; seat tools fixed in engine #98 |
| T-H9 | Resource exhaustion in the engine process | caps before parsing, per-run memory budget, deadlines, supervised calls |
| T-H10 | Poisoned shared skill reaches other users | **out of scope** until sharing; the first release has no path for it |

## 7. Acceptance

- With every flag off, every existing route, response, quote and test is unchanged.
- A private skill is invisible to anonymous and other-user requests, search, caches, logs and analytics.
- A run with a seat skill and an observer: the verdict, positions and dissent are byte-identical with and without the observer; the observer line settles at or below its reserve; failure follows the refund rule.
- Every refusal (bad hash, tools requested, oversized, unknown field, other user's skill) happens before a model call and before charge.
- Hostile suite through the hosted path: a skill and a question that try fence forgery, forged policy, trigger phrases, secret leakage and markup; the report is clean and rendering is escaped.
- A private run's receipt, transcript and panel line (they carry skill ids and names) are never published to the Gallery or any public page; a skill used as both a seat and the observer in one run is priced as the contract says (to be settled in C2).
- A live canary on the metered key, then a tenant canary, before any wider use.

## 8. Decisions for the owner

- **D1. Order.** The hosted spec says phase 7 needs phases 2 to 6. This slice is a deliberate subset (private, instructional, seat and observer only). Recommended: accept the subset and record it as an ADR, with the full phases still to come.
- **D2. Caps.** Recommended starting numbers: 4 attachments per run, 8 KiB instruction text per skill, 20 skills and 50 versions per user, observer output at most 1,000 bytes. Adjustable in config.
- **D3. Who can create.** Recommended: an allowlist for the first release (existing admin allowlist mechanism), then open sign-ups after the tenant canary.
- **D4. Default observer model and platform output cap** (open from the pricing contract). Recommended: choose when C2 is built, from a measured cost on three candidate cheap models.
- **D5. Hooks in v1.** Seat and observer only; chat `after_response` stays out.
- **D6. Deletion.** Recommended: deleting a skill deletes its versions and runs' skill text, and keeps receipts (id, version, hash, tokens) for billing and audit.
- **D7. Naming.** Hosted routes and any MCP tools follow ADR-0005; no new MCP tool before the hosted registry exists (the cloud routes come first, MCP later).

## 9. Not in scope and why

Sharing and Gallery publishing are the stored-injection and tenant-isolation risk class; they come after this release has run on real users, with moderation and abuse handling. Tools and memory skills need the policy adapter (hosted phase 5). These stay on the roadmap in `docs/skills-hosted-spec.md`.
