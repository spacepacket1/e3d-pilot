Today's date (UTC): DATE.
You have no web access and your knowledge may be out of date. If the question depends on recent events or current data, say so and give your answer conditionally.

Below is the full transcript of a debate between multiple AI models answering one question for a human who needs a single, decisive answer (ran the full 2 rounds without every participant converging).

Question: q?

# Debate

**Prompt version:** v3c

**Question:** q?

## Round 1 -- alpha

VERDICT: x
ACTION: do the alpha thing
AGREES_WITH: beta
CONFIDENCE: high

## Round 1 -- beta

VERDICT: x
ACTION: do the beta thing
AGREES_WITH: alpha
CONFIDENCE: high

## Round 2 -- alpha

VERDICT: x
ACTION: do the alpha thing
AGREES_WITH: beta
CONFIDENCE: high

[derived by e3d-debate from ACTION / AGREES_WITH]
POSITION: do the alpha thing
status: approved

## Round 2 -- beta

VERDICT: x
ACTION: do the beta thing
AGREES_WITH: alpha
CONFIDENCE: high

[derived by e3d-debate from ACTION / AGREES_WITH]
POSITION: do the beta thing
status: approved


You are the judge of a debate. Above are the question and the full transcript. Every analyst wrote each
round at the same time, so a rebuttal in round N answers the text of round N-1. Judge accusations by
that timeline.

Produce exactly this (keep this order; DISSENT must come before POSITIONS):
FINAL ANSWER: <2 to 4 sentences: the action to take and the single biggest reason>
CONSENSUS: <full = every analyst's last ACTION is the same action; majority = most share one action and at least one differs; split = two or more distinct actions each with a real backer>
DISSENT: one entry per analyst whose action differs from FINAL ANSWER: <name>: <what they would do instead and why> | "<verbatim quote>". Write "none" only if every analyst agrees.
POSITIONS: one line per analyst: <name>: <their final ACTION in your words> | "<verbatim quote, at most 20 words, from their final round>"
CLAIMS CHECKED: any factual claim where analysts contradicted each other, and what the transcript shows (round and analyst). Say "not resolvable" when it is.
OPEN QUESTIONS: up to 3.
Rules: every quote must be copied verbatim from that analyst's text. If you cannot find a quote, omit the claim. Never attribute a statement to someone who did not write it.

The 150-word limit above covers the lines above only. After them, add a section headed exactly "## What would change this" with at most 3 lines. Each line names one concrete, observable thing (a document, a measurement, a date or an event) that would change your FINAL ANSWER or its CONSENSUS, and says which way. Do not invent evidence. If you state any probability anywhere, name the event, the time window and what the number rests on; if you cannot, state no number.

Then add a section headed exactly "## Each model" with one line per participant, in transcript order, in exactly this form:
- <participant name exactly as in the transcript headings> | <that participant's own conclusion in its last turn, in at most 25 words>
Restate only what that participant concluded, in its own terms, as the shortest answer it gave to the question. Do not compare participants, say who is right or whether they agree. If it gave no conclusion, write: No position stated.

Then add a section headed exactly "## Key claims" with at most 6 lines, one per factual claim that your FINAL ANSWER or your reasoning relies on, each in exactly this form:
- <the claim, one sentence> | tier: <documented|inferred|speculative> | source: <primary|reputable|low|none> | by: <who asserted it: an analyst's name, or "official statement">
tier: documented = a source that the transcript names states it; inferred = it follows from documented facts by reasoning; speculative = neither. source: primary = a government, court, regulator, company filing or the party concerned; reputable = an established news organisation or research body; low = a social post, blog, forum, aggregator or anonymous source; none = a participant's own knowledge with no source named. A statement by an interested party (an agency about its own incident, a company about its own outage) is a claim, not a verdict: write by: official statement. Never write "documented" unless a source is named in the transcript.
If an analyst or a named official body disputes a claim anywhere in the transcript, add a fifth field to that line: | contested: <who disputes it, in a few words>. Leave the field out when nothing disputes it. A contested claim keeps its tier (a source does say it) but must never be presented as settled.
Last line of your reply: END
If the question depends on recent events or current data that the participants did not have, say so plainly in FINAL ANSWER instead of presenting the answer as current.
