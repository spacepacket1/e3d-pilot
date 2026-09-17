# Strategic priority: products over plumbing

**Type:** Direct user decision, not an e3d-debate. Recorded because the user asked
for this conversation specifically to be added to the provenance graph, calling
it "critically important because it is the purpose of what we do."

**Date:** 2026-09-17
**Decided by:** Chris (spacepacket@gmail.com)

## The directive

> Always remember that the goal of everything we do and every question we ask is
> to target the right users, make them aware of what we are doing, get their
> attention, have them try our products and services, become users and
> customers, and ultimately to generate revenue, especially recurring revenue.
> This is important because I feel like we are stuck in the plumbing of
> e3d-pilot, when the goal is to [ship] products and services. The plumbing is
> a means to an end. We can always continue to work on the plumbing when
> necessary, but the focus has to be on the real goal, and the real goal is to
> develop products and services that provide obvious value to other people, not
> just me.

This followed a long session that went deep into e3d-pilot internals (debate
mechanics, an outcome-capture instrumentation system, negotiate/gate tracking,
a web UI addition) without connecting any of it back to a user-facing product
or a revenue path -- the trigger, in the user's words, was feeling "stuck in
the plumbing of e3d-pilot."

## Clarifications given immediately after, correcting an over-broad first pass

1. **UI and CLI/API are both real product surfaces, not plumbing.** The web
   dashboard's forms, and visualizing the provenance graph specifically, count
   as genuine product-facing value -- that's how most humans actually work, not
   the command line. CLI/API surfaces matter too, explicitly because agents (as
   users) prefer those over a UI. Judge a surface by who it actually serves,
   not by its form (UI vs. CLI is not the same axis as product vs. plumbing).

2. **e3d-pilot's current goal is not to become the product itself.** It's the
   tool used to build and improve the ecosystem's actual products --
   `e3d-pod2vid`, `e3d-netdoctor`, `spacepacket`/`e3d`, `e3d-applied`, and
   products/services not yet conceived. If e3d-pilot becomes useful to outside
   users over time, that's a welcome side effect, not the current target.

3. **Standing discipline:** continually ask what other products or services
   anything being built could extend or extrapolate into, rather than solving
   only the immediate task narrowly.

## Why this belongs in the provenance graph

This isn't a technical decision about e3d-pilot's implementation -- it's the
strategic frame that should govern which future ideas get proposed, approved,
and prioritized across the whole ecosystem, not just this repo. Recording it
here, evidence-linked, means any future idea (in e3d-pilot's own ledger, or
conceptually in any ecosystem repo) can be checked against it: does this serve
user acquisition, awareness, trial, conversion, or revenue for a real product
-- or is it plumbing that should be named as a tradeoff, not silently pursued
by default.

## Known gap

The user also asked for this to be added directly to two other systems:
"the e3d mcp" and "futco mcp" (the ecosystem knowledge base this document's
own idea is evidence-linked into via `search_knowledge_base`/`get_repo`).
As of this writing, no write access exists to either from this session:
futco-mcp only exposes read tools, and e3d-mcp's only write tool
(`update_token_claim`) edits crypto token owner fields, unrelated. Both
systems' underlying repos live under `/Users/cbloom/...`, not reachable from
this `/Users/mini/e3d-pilot` session's filesystem. This still needs a session
with real access to those repos, or their maintainer, to close out.
