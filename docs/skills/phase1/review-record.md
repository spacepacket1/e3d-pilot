# Phase 1 review record

Three independent read-only reviews were run on PR #92 (architecture, security/privacy, implementation and evaluation design), each by a separate agent given the files and not the author's conclusions.
They are model reviews, not the human approvals the exit gate requires; the sign-off table in `../README.md` is still open.

| Finding | Review | Disposition |
| --- | --- | --- |
| New `content_hash` collides with the existing MCP `content_hash` (folder hash) | architecture, blocking | Fixed: new hash is `definition_hash`; receipts record `verified_hash_kind` (ADR-0003) |
| Model hints and max_words in unhashed `extensions` | architecture, blocking | Fixed: first-class hashed fields `model_hints`, `limits.max_words` (ADR-0002) |
| Projection limits too narrow, undefined version/overflow cases, `max_model_calls` wrong | architecture | Fixed: schema widened to engine limits; overflow and version rules; `max_model_calls = 0` (ADR-0002) |
| Schemas could not express optional capabilities, node fallback, `on_seat_skill_failure`, plan-to-seat link; `after_round` accepted against ADR-0006 | architecture | Fixed in schemas and fixtures |
| Override-by-name vs id pins; prompt labels vs byte-identical prompt; `experts`/`skills`/`skill_attachments` interaction | architecture | Decided in ADR-0014, 0002, 0005; compat test also pins tool input property names |
| Hash-line stripping bypass (finding F-2): reproduced independently | security, should-fix | Recorded (grounding item 12, threat T19, ADR-0003); fix in Phase 2 |
| Delimiter spoofing (T3): confirmed | security | Recorded; fix in Phase 2 |
| Unicode/control characters, TOCTOU, referent drift, mutable name/description, status live check, `extensions` bound, `signature`, error `details` caps, lone surrogates | security | Fixed in schema/reference (text pattern, NFC, extensions strings only, signature null, caps) or recorded as controls (threat T20 to T23) |
| Brain destination rule unenforceable without taint | security | Fixed in ADR-0008 (`audience_ceiling` in receipt and schema) |
| Retention ambiguities, ledger vs deletion | security, architecture | Clarified in ADR-0011 (tombstones, which retention applies) |
| Validator accepts `constructor`/`toString` keys (prototype lookup) | implementation, blocking | Fixed (`Object.hasOwn`), fixture `prototype-key` added, would have failed before |
| Static check of every schema; `x-code` only on leaves; `$ref` with siblings | implementation | Added to the harness (the first attempt at text limits did silently lose siblings; caught by a fixture, then guarded) |
| Evaluation cross-field rules (inverted interval, status without approved rubric) | implementation | Reference semantic check and fixtures |
| compat test inherited ambient `E3D_MCP_*`; fixed sleep | implementation | Fixed: clean `env -i`; clear error on empty output. The 2-second wait remains (timing assumption noted) |
| Evaluation design: power claim, effective n, non-stratified split, multiplicity, undefined parameters, volume bias, interval method, forking paths | implementation | Rewritten (evaluation-freeze.md): one primary test, Holm for the rest, stratified salted split, 90 tasks, minimum detectable effect, defined metrics and analysis, signed tag |
| Goldens were stale at the start of this phase, weakening the H5 story | implementation, nit | Stated in the PR; refreshed in `bc68f1b` with a 12-line additive diff |

**Not resolved by this phase (open risks):** the numbers in ADR-0010 and ADR-0011 and the evaluation thresholds need the owner; the compat test depends on `jq` and `node` and a 2-second server start; homoglyph attacks are accepted and shown in preview, not prevented; the hosted claims rest on a private appendix reviewers of the public PR cannot see; the first-draft statistical design had material flaws that these reviews found, so the revised freeze deserves a human statistician's read before approval.
No UX review was run: Phase 1 has no user interface.
