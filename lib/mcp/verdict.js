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

// Sections the synthesizer appends after the verdict lines. Each runs to the next heading or the end; neither is part of DISSENT.
const SECTION_RE = /\n[ \t]*#{1,6}[ \t]*(What would change this|Each model|Key claims|Hypotheses)\b[^\n]*\n/g;
const TIERS = ['documented', 'inferred', 'speculative'];
const SOURCES = ['primary', 'reputable', 'low', 'none'];
const bulletText = (l) => l.replace(/^[ \t]*(?:[-*\u2022]|\d+[.)])[ \t]*/, '').trim();

// "- <claim> | tier: documented | source: reputable | by: official statement" -> {claim, tier, source, by}. Anything the judge left out or
// mis-typed is 'untagged', never guessed. A claim cannot be "documented" with no source named: it is lowered to "inferred" and says so.
export function parseClaims(body) {
  const out = [];
  for (const l of body.split('\n')) {
    if (!/^[ \t]*(?:[-*\u2022]|\d+[.)])/.test(l)) continue;
    const [first, ...rest] = bulletText(l).split(/\s+\|\s+/);
    if (!first) continue;
    const field = (k) => rest.map((r) => new RegExp(`^${k}:\\s*(.*)$`, 'i').exec(r.trim())?.[1]?.trim()).find(Boolean) ?? '';
    const t = field('tier').toLowerCase(); const s = field('source').toLowerCase();
    let tier = TIERS.includes(t) ? t : 'untagged'; const source = SOURCES.includes(s) ? s : 'untagged';
    const c = { claim: first.slice(0, 300), tier, source, by: field('by').slice(0, 80) };
    // optional: who disputes the claim. A contested claim keeps its tier (a source does say it) but is flagged so it is never read as settled.
    const contested = field('contested');
    if (contested && !/^(no|none|n\/a)\b/i.test(contested)) c.contested = contested.slice(0, 160);
    if (tier === 'documented' && (source === 'none' || source === 'untagged')) { c.tier = 'inferred'; c.adjusted = 'tagged documented with no source named'; }
    out.push(c);
    if (out.length >= 6) break;
  }
  return out;
}

// "- <participant> | <its conclusion, at most 25 words asked>" (## Each model) -> [{ provider, text }], in the order written, at most 16, one per participant.
// Text is capped at 300 characters. The service matches `provider` to the positions; a name that matches none is ignored there, never guessed.
export function parseSummaries(body) {
  const out = [];
  const seen = new Set();
  for (const l of body.split('\n')) {
    if (!/^[ \t]*(?:[-*\u2022]|\d+[.)])/.test(l)) continue;
    const [first, ...rest] = bulletText(l).split(/\s+\|\s+/);
    const text = rest.join(' | ').trim();
    const name = (first || '').replace(/^[*`_\s]+|[*`_\s]+$/g, '');
    if (!name || !text || name.length > 64 || seen.has(name)) continue;
    seen.add(name);
    out.push({ provider: name, text: text.slice(0, 300) });
    if (out.length >= 16) break;
  }
  return out;
}

const LEVELS = ['low', 'medium', 'high'];
// "- <name> | rank: 1 | confidence: high | events: confirmed | for: ... | against: ... | discriminator: ..." (--approach hypotheses) -> hypotheses[].
// confidence is in the cause; events is how well the facts it rests on are confirmed. Anything missing or mistyped is 'untagged', never guessed.
export function parseHypotheses(body) {
  const out = [];
  for (const l of body.split('\n')) {
    if (!/^[ \t]*(?:[-*\u2022]|\d+[.)])/.test(l)) continue;
    const [first, ...rest] = bulletText(l).split(/\s+\|\s+/);
    if (!first) continue;
    const field = (k) => rest.map((r) => new RegExp(`^${k}:\\s*(.*)$`, 'i').exec(r.trim())?.[1]?.trim()).find(Boolean) ?? '';
    const rank = Number.parseInt(field('rank'), 10); const conf = field('confidence').toLowerCase();
    out.push({
      name: first.slice(0, 120), rank: Number.isSafeInteger(rank) && rank >= 1 && rank <= 4 ? rank : out.length + 1,
      confidence: LEVELS.includes(conf) ? conf : 'untagged', events: field('events').slice(0, 40),
      for: field('for').slice(0, 300), against: field('against').slice(0, 300), discriminator: field('discriminator').slice(0, 300),
    });
    if (out.length >= 4) break;
  }
  return out;
}

// The synthesizer ends a finished reply with a line "END" (bin/e3d-debate). Its output budget is small, so a reply that ran out mid-line has no END, and
// the line that was cut is the LAST one: the final item of the last section. Without END (and when case mode's "Questions for you" did not follow), that
// final item is dropped rather than shown half-written: losing one complete item is better than showing a cut one.
const END_LINE = /\n[ \t]*END[ \t]*\s*$/;

export function parseVerdict(out) {
  const text = String(out ?? '');
  const ended = END_LINE.test(text);
  const hadQuestions = /\n[ \t]*#{1,6}[ \t]*Questions for you\b/.test(text);
  // Case mode (e3d-debate --follow-up) appends a "## Questions for you" section after the dissent; it is not part of the verdict fields
  // (the questions are read from questions.json). Absent in an ordinary debate, so nothing changes for one.
  let raw = text.match(/FINAL ANSWER:[\s\S]*$/)?.[0]?.replace(/\n[ \t]*#{1,6}[ \t]*Questions for you\b[\s\S]*$/, '').replace(END_LINE, '').trim();
  if (!raw) return null;
  // "## What would change this" (up to 3 observable things) and "## Key claims" (the claim ledger): parsed out, kept out of the dissent text.
  const heads = [...raw.matchAll(SECTION_RE)];
  let wouldChange = null; let claims = null; let hypotheses = null; let summaries = null;
  if (heads.length) {
    const sections = heads.map((h, i) => ({ name: h[1].toLowerCase(), body: raw.slice(h.index + h[0].length, heads[i + 1]?.index ?? raw.length) }));
    raw = raw.slice(0, heads[0].index).trim();
    const lastName = sections[sections.length - 1].name;
    const dropLast = !ended && !hadQuestions;
    for (const s of sections) {
      const last = dropLast && s.name === lastName;   // this section ends the reply and the reply was not marked finished
      if (s.name.startsWith('what would')) {
        let w = s.body.split('\n').map(bulletText).filter(Boolean);
        if (last) w = w.slice(0, -1);
        w = w.slice(0, 3).map((l) => l.slice(0, 400));
        if (w.length && !wouldChange) wouldChange = w;
      } else if (s.name === 'each model') {
        const m = parseSummaries(s.body);
        if (last) m.pop();
        if (m.length && !summaries) summaries = m;
      } else if (s.name === 'hypotheses') {
        const h = parseHypotheses(s.body);
        if (last) h.pop();
        if (h.length && !hypotheses) hypotheses = h;
      } else {
        const c = parseClaims(s.body);
        if (last) c.pop();
        if (c.length && !claims) claims = c;
      }
    }
  }
  const verdict = parseVerdictBody(raw);
  return verdict && (wouldChange || claims || hypotheses || summaries) ? { ...verdict, ...(summaries ? { position_summaries: summaries } : {}), ...(hypotheses ? { hypotheses } : {}), ...(wouldChange ? { would_change: wouldChange } : {}), ...(claims ? { claims } : {}) } : verdict;
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
    ...(v.position_summaries ? { position_summaries: v.position_summaries.map((p) => ({ ...p, text: clean(p.text) })) } : {}),
    ...(v.hypotheses ? { hypotheses: v.hypotheses.map((h) => ({ ...h, name: clean(h.name), events: clean(h.events), for: clean(h.for), against: clean(h.against), discriminator: clean(h.discriminator) })) } : {}),
    ...(v.claims ? { claims: v.claims.map((c) => ({ ...c, claim: clean(c.claim), by: clean(c.by), ...(c.contested ? { contested: clean(c.contested) } : {}) })) } : {}),
  };
}

// One answering seat (after others were lost) has nothing to agree or disagree with, so the label is "unknown", whatever the judge wrote.
// The consensus_note already says how many seats the verdict rests on. A debate that asked for one seat is left alone.
export function applySeatLabel(v, seats) {
  if (!v || !seats || !seats.flags?.seats_lost || seats.seats_answered !== 1 || v.consensus === 'unknown') return v;
  return { ...v, consensus: 'unknown' };
}
