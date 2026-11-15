// e3d-debate prints "FINAL ANSWER: ...\nCONSENSUS: ...\nDISSENT: ..." -- turn that into fields.
//
// The synthesizer's output budget is small, so the tail of its reply can be missing. That used to throw the whole verdict away
// ("consensus: unknown", the CONSENSUS line left inside the answer text). Now every part that arrived is kept:
//   - complete reply: as before;
//   - cut after CONSENSUS (no DISSENT line): the consensus is kept, the dissent is unknown;
//   - cut before CONSENSUS: the answer is kept up to its last complete sentence, consensus and dissent are unknown, and the
//     dissent summary says the reply was cut off. Nothing is invented: the positions still carry each model's own answer.

const CONSENSUS_LEVELS = ['full', 'majority', 'split'];
const TERMINAL = /[.!?][)"'’”*`]*$/;

function trimIncomplete(text) {
  const t = text.trim();
  if (TERMINAL.test(t)) return { text: t, cut: false };
  let end = -1;
  for (const m of t.matchAll(/[.!?][)"'’”*`]*(?=\s|$)/g)) end = m.index + m[0].length;
  return { text: end > 0 ? t.slice(0, end).trim() : t, cut: true };
}

export function parseVerdict(out) {
  // Case mode (e3d-debate --follow-up) appends a "## Questions for you" section after the dissent; it is not part of the verdict fields
  // (the questions are read from questions.json). Absent in an ordinary debate, so nothing changes for one.
  let raw = String(out ?? '').match(/FINAL ANSWER:[\s\S]*$/)?.[0]?.replace(/\n[ \t]*#{1,6}[ \t]*Questions for you\b[\s\S]*$/, '').trim();
  if (!raw) return null;
  // "## What would change this": up to 3 concrete observable things that would change the answer. Not part of the dissent text.
  let wouldChange = null;
  const wc = /\n[ \t]*#{1,6}[ \t]*What would change this\b[^\n]*\n([\s\S]*)$/.exec(raw);
  if (wc) {
    raw = raw.slice(0, wc.index).trim();
    wouldChange = wc[1].split('\n').map((l) => l.replace(/^[ \t]*(?:[-*\u2022]|\d+[.)])[ \t]*/, '').trim()).filter(Boolean).slice(0, 3).map((l) => l.slice(0, 400));
    if (!wouldChange.length) wouldChange = null;
  }
  const verdict = parseVerdictBody(raw);
  return verdict && wouldChange ? { ...verdict, would_change: wouldChange } : verdict;
}

function parseVerdictBody(raw) {
  const body = raw.replace(/^FINAL ANSWER:\s*/, '');
  const cons = /\n[ \t]*CONSENSUS:[ \t]*([^\n]*)/.exec(body);
  if (!cons) {
    const { text, cut } = trimIncomplete(body);
    return {
      final_answer: text, consensus: 'unknown',
      dissent: { present: null, summary: cut
        ? 'The summary was cut off before its consensus and dissent lines; read the answer text and each model\'s position.'
        : 'Verdict could not be parsed; read the answer text in full.' },
    };
  }
  const answer = body.slice(0, cons.index).trim();
  const consensus = CONSENSUS_LEVELS.find((c) => cons[1].toLowerCase().includes(c)) ?? 'unknown';
  const dis = /\n[ \t]*DISSENT:\s*([\s\S]*)$/.exec(body.slice(cons.index + cons[0].length));
  if (!dis) return { final_answer: answer, consensus, dissent: { present: null, summary: 'The summary ended before its dissent line; read each model\'s position.' } };
  const dissentText = dis[1].trim();
  const none = /^["'`]*none[."'`]*$/i.test(dissentText);
  // A dissent that stops mid-sentence was probably cut by the output limit: keep what arrived and say so.
  const cutDissent = !none && !/\n[A-Z][A-Z ]+:/.test(dissentText) && !TERMINAL.test(dissentText);
  return { final_answer: answer, consensus, dissent: { present: !none, summary: none ? 'none' : cutDissent ? `${dissentText} [cut off]` : dissentText } };
}

// Everything the models wrote is run through the same clean() before it leaves the server when web search was on (control and bidi
// characters, markdown images, HTML and links neutralised). Covers every model-written field, including would_change and claims.
export function sanitizeVerdict(v, clean) {
  if (!v) return v;
  return {
    ...v,
    final_answer: clean(v.final_answer),
    dissent: { ...v.dissent, summary: clean(v.dissent.summary) },
    ...(v.would_change ? { would_change: v.would_change.map((t) => clean(t)) } : {}),
    ...(v.claims ? { claims: v.claims.map((c) => ({ ...c, claim: clean(c.claim), by: clean(c.by) })) } : {}),
  };
}

// One answering seat (after others were lost) has nothing to agree or disagree with, so the label is "unknown", whatever the judge wrote.
// The consensus_note already says how many seats the verdict rests on. A debate that asked for one seat is left alone.
export function applySeatLabel(v, seats) {
  if (!v || !seats || !seats.flags?.seats_lost || seats.seats_answered !== 1 || v.consensus === 'unknown') return v;
  return { ...v, consensus: 'unknown' };
}
