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
  const raw = String(out ?? '').match(/FINAL ANSWER:[\s\S]*$/)?.[0]?.trim();
  if (!raw) return null;
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
  return { final_answer: answer, consensus, dissent: { present: !none, summary: none ? 'none' : dissentText } };
}
