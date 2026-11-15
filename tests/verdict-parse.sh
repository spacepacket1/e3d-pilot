#!/usr/bin/env bash
set -euo pipefail

# parseVerdict (lib/mcp/verdict.js): a synthesizer reply cut short keeps every part that arrived. No model calls, no network.
# Found on 2026-10-26: 3 of 8 live debates came back "consensus: unknown" -- one reply ended after CONSENSUS (no DISSENT line, so the
# whole verdict was thrown away and the CONSENSUS line stayed inside the answer), two were cut off inside the answer.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node --input-type=module - "$ROOT" <<'EOF2'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
const { parseVerdict, parseClaims, sanitizeVerdict, applySeatLabel } = await import(pathToFileURL(join(process.argv[2], 'lib/mcp/verdict.js')).href);
const ok = (m) => console.log(`ok - ${m}`);

// complete replies are parsed exactly as before
let v = parseVerdict('FINAL ANSWER: Use SQLite. It is simple.\nCONSENSUS: full\nDISSENT: none\n');
assert.deepEqual(v, { final_answer: 'Use SQLite. It is simple.', consensus: 'full', dissent: { present: false, summary: 'none' } }); ok('complete, full, no dissent');
v = parseVerdict('FINAL ANSWER: Use SQLite.\nCONSENSUS: majority\nDISSENT: Gemini would keep JSON because the data is tiny.');
assert.equal(v.consensus, 'majority'); assert.equal(v.dissent.present, true); assert.match(v.dissent.summary, /^Gemini would keep JSON/); ok('complete, majority, dissent text');
v = parseVerdict('FINAL ANSWER: Do X.\nCONSENSUS: split\nDISSENT: "None."');
assert.equal(v.dissent.present, false); ok('quoted none counts as none');
v = parseVerdict('noise\nFINAL ANSWER: Do X.\nCONSENSUS: full\nDISSENT: none\nPOSITIONS: a: X | "q"');
assert.equal(v.consensus, 'full'); ok('text before FINAL ANSWER is ignored');
assert.equal(parseVerdict('no verdict here'), null); assert.equal(parseVerdict(''), null); assert.equal(parseVerdict(undefined), null); ok('no FINAL ANSWER gives null');

// "## What would change this": returned as would_change, never part of the dissent; absent when the section is absent
v = parseVerdict('FINAL ANSWER: Use SQLite.\nCONSENSUS: majority\nDISSENT: Gemini would keep JSON.\n\n## What would change this\n- A benchmark showing writes above 500 per second\n2) A second writer process\n* Dropping the offline requirement\n- a fourth line that is cut');
assert.deepEqual(v.would_change, ['A benchmark showing writes above 500 per second', 'A second writer process', 'Dropping the offline requirement']);
assert.equal(v.dissent.summary, 'Gemini would keep JSON.'); assert.equal(v.consensus, 'majority'); ok('would_change parsed (3 max), dissent untouched');
v = parseVerdict('FINAL ANSWER: Do X.\nCONSENSUS: full\nDISSENT: none\n\n## What would change this\n- New data on Friday\n\n## Questions for you\n\n1. q');
assert.deepEqual(v.would_change, ['New data on Friday']); assert.equal(v.dissent.summary, 'none'); ok('would_change before case-mode questions');
v = parseVerdict('FINAL ANSWER: Do X.\nCONSENSUS: full\nDISSENT: none\n');
assert.equal('would_change' in v, false); ok('no section, no would_change field');

// claim ledger: "## Key claims" is parsed into claims[], in either order with "What would change this", and kept out of the dissent
v = parseVerdict('FINAL ANSWER: Do X.\nCONSENSUS: majority\nDISSENT: B disagrees.\n\n## What would change this\n- New data\n\n## Key claims\n- The outage began on Nov 13 | tier: documented | source: reputable | by: openai-api\n- Officials say no cyberattack | tier: inferred | source: primary | by: official statement\n- A second actor is involved | tier: speculative | source: none | by: xai-api');
assert.equal(v.claims.length, 3); assert.deepEqual(v.claims[0], { claim: 'The outage began on Nov 13', tier: 'documented', source: 'reputable', by: 'openai-api' });
assert.equal(v.claims[1].by, 'official statement'); assert.equal(v.claims[2].tier, 'speculative'); assert.deepEqual(v.would_change, ['New data']); assert.equal(v.dissent.summary, 'B disagrees.'); ok('claims parsed after would_change; dissent untouched');
v = parseVerdict('FINAL ANSWER: Do X.\nCONSENSUS: full\nDISSENT: none\n\n## Key claims\n- Claim one | tier: inferred | source: none | by: a\n\n## What would change this\n- Evidence E');
assert.equal(v.claims.length, 1); assert.deepEqual(v.would_change, ['Evidence E']); assert.equal(v.dissent.summary, 'none'); ok('claims before would_change');
// a claim cannot be "documented" without a named source; malformed tags are untagged, never guessed; 6 max
let c = parseClaims('- Sky is blue | tier: documented | source: none | by: a\n- Odd | tier: certain | source: gold | by: b\n- Bare claim\n- 4 | tier: inferred | source: low | by: x\n- 5\n- 6\n- 7\n- 8');
assert.equal(c[0].tier, 'inferred'); assert.match(c[0].adjusted, /no source/); assert.equal(c[1].tier, 'untagged'); assert.equal(c[1].source, 'untagged'); assert.equal(c[2].claim, 'Bare claim'); assert.equal(c[2].tier, 'untagged'); assert.equal(c.length, 6); ok('documented needs a source; bad tags are untagged; capped at 6');
assert.deepEqual(parseClaims('no bullets here'), []); ok('no bullet lines, no claims');
v = parseVerdict('FINAL ANSWER: Do X.\nCONSENSUS: full\nDISSENT: none\n\n## Key claims\nnothing parseable');
assert.equal('claims' in v, false); assert.equal(v.dissent.summary, 'none'); ok('an empty ledger section adds no field');

// sanitizeVerdict: every model-written field goes through clean(), including would_change and claims
const mark = (t) => `[${t}]`;
v = sanitizeVerdict({ final_answer: 'a', consensus: 'full', dissent: { present: true, summary: 'd' }, would_change: ['w1', 'w2'], claims: [{ claim: 'c', tier: 'documented', source: 'primary', by: 'x' }] }, mark);
assert.equal(v.final_answer, '[a]'); assert.equal(v.dissent.summary, '[d]'); assert.deepEqual(v.would_change, ['[w1]', '[w2]']);
assert.deepEqual(v.claims, [{ claim: '[c]', tier: 'documented', source: 'primary', by: '[x]' }]); ok('sanitizeVerdict covers would_change and claims');
assert.equal(sanitizeVerdict(null, mark), null); assert.equal('would_change' in sanitizeVerdict({ final_answer: 'a', consensus: 'full', dissent: { present: false, summary: 'none' } }, mark), false); ok('sanitizeVerdict: null and no optional fields');

// applySeatLabel: one answering seat after a loss has nothing to compare
const lost1 = { seats_requested: 4, seats_answered: 1, flags: { seats_lost: true } };
assert.equal(applySeatLabel({ final_answer: 'a', consensus: 'majority', dissent: { present: true, summary: 'd' } }, lost1).consensus, 'unknown');
assert.equal(applySeatLabel({ final_answer: 'a', consensus: 'majority', dissent: { present: true, summary: 'd' } }, { seats_requested: 4, seats_answered: 2, flags: { seats_lost: true } }).consensus, 'majority');
assert.equal(applySeatLabel({ final_answer: 'a', consensus: 'full', dissent: { present: false, summary: 'none' } }, { seats_requested: 1, seats_answered: 1, flags: { seats_lost: false } }).consensus, 'full');
assert.equal(applySeatLabel(null, lost1), null); assert.equal(applySeatLabel({ consensus: 'full' }, null).consensus, 'full'); ok('applySeatLabel: unknown only for one answering seat after a loss');

// cut after CONSENSUS: the consensus survives and the CONSENSUS line is not part of the answer
v = parseVerdict('FINAL ANSWER: Use a shared schema with row-level security. Revisit if several customers need physical isolation.\n\nCONSENSUS: majority');
assert.equal(v.consensus, 'majority');
assert.equal(v.final_answer, 'Use a shared schema with row-level security. Revisit if several customers need physical isolation.');
assert.ok(!/CONSENSUS/.test(v.final_answer));
assert.equal(v.dissent.present, null); assert.match(v.dissent.summary, /ended before its dissent line/); ok('cut after CONSENSUS keeps the consensus');
v = parseVerdict('FINAL ANSWER: Pick the queue.\nCONSENSUS: unknown-ish');
assert.equal(v.consensus, 'unknown'); assert.equal(v.final_answer, 'Pick the queue.'); ok('unrecognised consensus word stays unknown, answer still clean');

// cut before CONSENSUS: answer kept to its last complete sentence, and the reply says it was cut off
v = parseVerdict('FINAL ANSWER: Pick a Postgres queue. Move to SQS if load grows tenfold. This answer rests on st');
assert.equal(v.final_answer, 'Pick a Postgres queue. Move to SQS if load grows tenfold.');
assert.equal(v.consensus, 'unknown'); assert.equal(v.dissent.present, null); assert.match(v.dissent.summary, /cut off before its consensus and dissent lines/); ok('cut inside the answer drops only the unfinished sentence');
v = parseVerdict('FINAL ANSWER: Stay inside Postgres. Mitigate with iterative scans and no need for heavy faceting or advanced relev');
assert.equal(v.final_answer, 'Stay inside Postgres.'); assert.match(v.dissent.summary, /cut off/); ok('cut mid-word');
v = parseVerdict('FINAL ANSWER: One long fragment with no sentence end');
assert.equal(v.final_answer, 'One long fragment with no sentence end'); assert.match(v.dissent.summary, /cut off/); ok('a fragment with no full sentence is kept whole');

// a dissent that stops mid-sentence is marked, a finished one and one followed by another section are not
v = parseVerdict('FINAL ANSWER: Use X.\nCONSENSUS: majority\nDISSENT: Gemini would keep JSON because the data is');
assert.equal(v.dissent.present, true); assert.match(v.dissent.summary, /because the data is \[cut off\]$/); ok('cut-off dissent is marked');
v = parseVerdict('FINAL ANSWER: Use X.\nCONSENSUS: majority\nDISSENT: Gemini would keep JSON.\nPOSITIONS: a: X | "q"');
assert.ok(!/cut off/.test(v.dissent.summary)); ok('dissent followed by another section is not marked');

// a reply that is complete but has no CONSENSUS line keeps the old message
v = parseVerdict('FINAL ANSWER: Do X, because it is simpler.');
assert.equal(v.final_answer, 'Do X, because it is simpler.'); assert.equal(v.consensus, 'unknown'); assert.match(v.dissent.summary, /could not be parsed/); ok('complete answer without CONSENSUS: legacy message');
EOF2
