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
const { parseVerdict } = await import(pathToFileURL(join(process.argv[2], 'lib/mcp/verdict.js')).href);
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
