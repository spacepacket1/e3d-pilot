# ADR-0021: Calibration wording rule

Status: **Owner-decided 2026-11-23; recorded here and awaiting reviewer sign-off like the other ADRs.** Phase: calibration 1. Spec: `spec/e3d-pilot-calibration-spec-v0.1.md`.

## Context

The hosted decision-record spec bans "memory, learning, truth, audit or audit trail, governance, knowledge base, or better outcomes" in UI copy, share pages, docs and marketing, enforced by a copy test.

## Decision

1. The same ban applies to all calibration copy and shares its copy test. 2. Allowed words: "track record", "calibration", "recorded outcomes", "resolved uses", "how it went". 3. The skills claim language still applies: no "improves", "best", "accurate" or "verified" without the definition and sample basis. 4. Example of an allowed sentence: "In your 17 resolved uses of this skill on architecture reviews, 12 were marked worked (95% interval 47% to 87%); 41% of uses had a recorded outcome."

## Consequences

"Calibration" always appears with the record it describes, so it is not read as "this skill is correct".

## Alternatives considered

Ban "calibration" too (loses the clearest term); a separate rule (two wording regimes).

## Amendment proposed (needs owner sign-off; not part of the owner-decided text above)

The example sentence in decision 4 says "41% of uses had a recorded outcome". The share it reports is resolved uses divided by all uses, and a use marked `unknown` has an outcome on file but is not resolved, so the sentence can read lower than the share of uses that have an outcome. Proposed corrected example: "In your 17 resolved uses of this skill on architecture reviews, 12 were marked worked (approximate 95% interval 46% to 87%); 41% of uses were marked worked or failed." The interval bounds are rounded outward from the unrounded Wilson bounds (12 of 17 is 46.87% to 86.72%), so a printed interval is never tighter than the computed one. The local record line also prints the number of uses marked unknown or inferred, the outcome sources, the share of uses made with the reminder on and the number of corrections, as calibration spec section 5.4 asks. The engine implements the corrected wording; the sentence above is unchanged until the owner approves this amendment.

