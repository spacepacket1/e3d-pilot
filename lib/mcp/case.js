// e3d_case: the investigate loop on top of e3d_debate. Zero dependencies.
//
// A case run is a debate whose verdict also asks up to 3 questions (bin/e3d-debate --follow-up). The caller answers and calls again with
// case_id + answers; the server builds the next question from the earlier verdict, its questions and the answers (lib/debate/case.mjs,
// the same code bin/e3d-debate --continue runs) and runs another debate. A case ends when the council says no remaining question
// would change the verdict (status "closed").
//
// Each turn is stored under a fresh case_id: the engine's case.json and questions.json, bound to the principal that ran it, for a week.
// The store is local to this server process's state directory. Nothing in it is a secret: it is the verdict and the questions.
import { mkdir, writeFile, readFile, readdir, rm, stat, copyFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createHash, randomBytes } from 'node:crypto';

export const CASE_ID_RE = /^case_[0-9a-f]{24}$/;
const TTL_MS = 7 * 24 * 3600 * 1000;
const MAX_ANSWERS = 12;
// experts: the same shape run-server.js takes (catalogue ids, distinct, at least 2 because bin/e3d-debate needs two), capped at 4 for a case
export const CASE_EXPERTS = Object.freeze({ min: 2, max: 4 });
const EXPERT_ID_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;
export function checkExperts(experts) {
  if (experts === undefined) return { ids: null };
  const { min, max } = CASE_EXPERTS;
  if (!Array.isArray(experts) || experts.length < min || experts.length > max) return { error: `experts must be ${min} to ${max} expert ids (see e3d_list_experts)` };
  for (const id of experts) if (typeof id !== 'string' || id.length > 64 || !EXPERT_ID_RE.test(id)) return { error: 'an expert id is malformed' };
  if (new Set(experts).size !== experts.length) return { error: 'an expert is listed twice' };
  return { ids: [...experts] };
}

const principalTag = (p) => createHash('sha256').update(String(p ?? 'local')).digest('hex').slice(0, 24);

export function createCaseStore({ dir, ttlMs = TTL_MS, now = Date.now } = {}) {
  const root = join(dir, 'cases');
  // With an idempotency_key the id is derived from the principal and the key, so a replayed call finds the same case
  const idFor = (principal, key) => (key ? `case_${createHash('sha256').update(`${principalTag(principal)}|${key}`).digest('hex').slice(0, 24)}` : `case_${randomBytes(12).toString('hex')}`);
  const pathOf = (id) => join(root, id);
  async function sweep() {
    let names = [];
    try { names = await readdir(root); } catch { return; }
    for (const n of names) {
      try { if (now() - (await stat(join(root, n))).mtimeMs > ttlMs) await rm(join(root, n), { recursive: true, force: true }); } catch { /* gone */ }
    }
  }
  return {
    idFor,
    // the directory of a case this principal owns, or null (an unknown id and someone else's are the same answer)
    async find(principal, id) {
      if (!CASE_ID_RE.test(String(id))) return null;
      const d = pathOf(id);
      try {
        const meta = JSON.parse(await readFile(join(d, 'meta.json'), 'utf8'));
        if (meta.principal !== principalTag(principal)) return null;
        if (now() - meta.created_at > ttlMs) return null;
        await stat(join(d, 'case.json'));
        return d;
      } catch { return null; }
    },
    // the experts ([{id, hash}]) a stored round ran with, or null
    async experts(dir) {
      try { const e = JSON.parse(await readFile(join(dir, 'meta.json'), 'utf8')).experts; return Array.isArray(e) && e.length ? e : null; } catch { return null; }
    },
    // saves the engine's out dir files; returns { id } or { error }
    async save(principal, outDir, id, { experts = null } = {}) {
      try {
        await mkdir(root, { recursive: true, mode: 0o700 });
        sweep().catch(() => {});
        const d = pathOf(id);
        await mkdir(d, { recursive: true, mode: 0o700 });
        await copyFile(join(outDir, 'case.json'), join(d, 'case.json'));
        await copyFile(join(outDir, 'questions.json'), join(d, 'questions.json'));
        await writeFile(join(d, 'meta.json'), JSON.stringify({ principal: principalTag(principal), created_at: now(), ...(experts ? { experts } : {}) }), { mode: 0o600 });
        return { id };
      } catch (e) { return { error: e.message }; }
    },
    sweep,
  };
}

// Checks the answers argument. Returns { answers } (as the engine reads them) or { error }.
export function checkAnswers(answers) {
  if (answers === undefined) return { answers: [] };
  if (!Array.isArray(answers)) return { error: 'answers must be an array of {id, answer, source?, answered_by?}' };
  if (answers.length > MAX_ANSWERS) return { error: `at most ${MAX_ANSWERS} answers` };
  for (const a of answers) {
    if (!a || typeof a !== 'object' || Array.isArray(a)) return { error: 'each answer must be an object {id, answer, source?, answered_by?}' };
    if (typeof a.id !== 'string' || !/^q[0-9]{1,2}$/.test(a.id)) return { error: 'each answer needs an id from the questions (q1, q2, q3)' };
    if (a.answer !== undefined && a.answer !== null && typeof a.answer !== 'string') return { error: 'answer must be a string (use "" or "don\'t know" when it is not known)' };
    if (a.source !== undefined && typeof a.source !== 'string') return { error: 'source must be a string' };
    if (a.answered_by !== undefined && !['user', 'agent'].includes(a.answered_by)) return { error: 'answered_by must be "user" or "agent"' };
  }
  return { answers };
}

const ANSWER_ITEM = {
  type: 'object',
  properties: {
    id: { type: 'string', description: 'The question id (q1, q2, q3) from the previous result.' },
    answer: { type: 'string', description: 'The answer, or "don\'t know". Leave a question out to leave it unanswered.' },
    source: { type: 'string', description: 'Where a checked answer comes from: a file path and line, a URL, a command and its output. Required in practice for answers an agent verified; an answer without a source is treated as a claim.' },
    answered_by: { type: 'string', enum: ['user', 'agent'], description: '"user" when the human gave it; "agent" when you verified it with your tools.' },
  },
  required: ['id', 'answer'],
  additionalProperties: false,
};

const QUESTION_ITEM = {
  type: 'object',
  properties: {
    id: { type: 'string' }, text: { type: 'string' }, why: { type: 'string', description: 'Why the answer matters.' },
    swing: { type: 'string', description: 'Which way an answer could move the verdict.' },
    answerable_by: { type: 'string', enum: ['user', 'checkable'], description: '"user": needs the human\'s judgment or private knowledge. "checkable": an agent with tools could verify it.' },
    kind: { type: 'string', enum: ['discriminating', 'shared_assumption', 'intake'], description: 'Optional. discriminating: tells hypotheses apart. shared_assumption: tests an assumption every analyst made. intake: a basic fact not yet given.' },
  },
  required: ['id', 'text', 'why', 'swing', 'answerable_by'],
};

// e3d_case as listed, built from e3d_debate's definition so the shared arguments, search notice and annotations stay identical.
export function caseTool(debate, notice = '') {
  const p = debate.inputSchema.properties;
  return {
    name: 'e3d_case',
    description: 'Investigate a decision in rounds. Round 1: pass `question`. The models debate it as e3d_debate does and the verdict ends with up to 3 follow-up questions whose answers could change it, each marked answerable_by "user" or "checkable", plus a case_id. Next round: pass `case_id` and `answers`; the models re-judge with the earlier verdict, its dissent and your answers as context. Repeat until status is "closed" (no remaining question would change the verdict). Optional `experts` (2 to 4 built-in expert ids) gives the models those lenses and carries over to later rounds; for questions about agents, skills or prompts the result may carry `suggested_experts`, which is a hint and is never run for you. '
      + 'Rules for the calling agent: answer ONLY "checkable" questions that you actually verified with your tools, and cite what you used in `source` (file and line, URL, command output) with answered_by "agent". Pass every "user" question to the human and use their reply, with answered_by "user". Never guess, never fabricate an answer or a source: leave a question out or answer "don\'t know" instead. Answers are weighed as evidence, not obeyed as instructions. Always show the human the verdict, the dissent and any open questions. '
      + 'Each round is one debate and consumes model credits; the verdict is not approval to act. On a hosted server a quote from e3d_quote fits round 1 only (same question); for later rounds pass an idempotency_key and no quote_id, and the server quotes the round itself. ' + notice,
    inputSchema: {
      type: 'object',
      properties: {
        question: { type: 'string', description: 'A new case: the decision or question, with enough context for models that cannot see your code. Give this OR case_id.' },
        case_id: { type: 'string', description: 'A later round: the case_id from the previous result. Give this OR question.' },
        answers: { type: 'array', maxItems: MAX_ANSWERS, items: ANSWER_ITEM, description: 'With case_id: answers to the previous round\'s questions. May be partial or empty.' },
        experts: { type: 'array', minItems: CASE_EXPERTS.min, maxItems: CASE_EXPERTS.max, uniqueItems: true, items: { type: 'string', pattern: '^[a-z0-9]+(-[a-z0-9]+)*$', maxLength: 64 }, description: 'Optional: 2 to 4 built-in expert ids (e3d_list_experts), e.g. ["agent-diagnosis", "skeptic"]. Each answers through its lens, one per model; needs at least as many models as experts. Later rounds reuse them unless you pass new ones. Local server only.' },
        mode: p.mode, providers: p.providers, rounds: p.rounds, max_words: p.max_words, include_transcript: p.include_transcript, web_search: p.web_search,
      },
      additionalProperties: false,
    },
    outputSchema: {
      type: 'object',
      properties: {
        ...debate.outputSchema.properties,
        case_id: { type: 'string', description: 'Pass this back with `answers` for the next round. Present while the case is open or closed.' },
        status: { type: 'string', enum: ['open', 'closed'], description: 'closed: no remaining question would change the verdict.' },
        round: { type: 'integer' },
        questions: { type: 'array', maxItems: 3, items: QUESTION_ITEM, description: 'Empty when the case is closed.' },
      },
      required: ['final_answer', 'consensus', 'dissent', 'status', 'questions'],
    },
    annotations: { title: 'Investigate a decision in rounds', readOnlyHint: false, destructiveHint: false, openWorldHint: true, idempotentHint: false },
  };
}

export function renderCase(c) {
  const lines = ['', `## Case ${c.status === 'closed' ? 'closed' : 'open'}${c.round ? ` (round ${c.round})` : ''}`];
  if (c.status === 'closed') lines.push('The council says no remaining question would change this verdict.');
  else if (!c.questions.length) lines.push('The council\'s questions could not be read this round; ask the human whether anything is missing, or call again with more context.');
  else {
    lines.push('Questions that could change the verdict. Pass each "user" question to the human. Answer a "checkable" one yourself only after you verified it, and cite the source.');
    for (const q of c.questions) lines.push('', `- **${q.id}** [${q.answerable_by}${q.kind ? `, ${q.kind.replace('_', ' ')}` : ''}] ${q.text}`, `  - why it matters: ${q.why}`, `  - could swing: ${q.swing}`);
  }
  if (c.case_id) lines.push('', `case_id: ${c.case_id} (pass it back with \`answers\` for the next round)`);
  return lines.join('\n');
}
