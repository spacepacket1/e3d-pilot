#!/usr/bin/env node
// Command front end for the local calibration store, called by bin/e3d-debate behind E3D_CALIBRATION_V1=1 (calibration spec 5.2, phase 2). Zero dependencies.
//
//   record  <skill> [--version V] [--hash H] [--task-class C] [--mode M] [--model-family F] [--json]   the track record(s) derived from the recorded uses and outcomes
//   report  <use_id> --result worked|failed|unknown [--json]                                           records how it went; a later report for the same use supersedes
//   mine    [--json]                                                                                    every record of yours, grouped by skill
//   delete  <use_id> [--json]                                                                           removes the outcomes of one use; records recompute
//   compact [--json]                                                                                    applies retention and drops deleted and superseded-aged outcomes
//   register-uses <decision-log.json>                                                                   (called by the debate) notes each skill use of a receipt
//
// No command calls a model or the network. Errors carry a stable code from lib/skills/schemas/v1/error-codes.json; --json prints them on stdout as
// {"ok":false,"error":{"code","message"}}, and `error: <code>: <message>` always goes to stderr. Exit 0 ok, 1 refused.
import { closeSync, constants, fstatSync, openSync, readSync } from 'node:fs';
import { CalError, compact, deleteOutcome, newUse, registerUse, reportOutcome, skillIds, stateDir, trackRecords } from './store.mjs';
import { describeRecord } from './record.mjs';

const RESULTS = ['worked', 'failed', 'unknown'];
const TASK = /^[a-z0-9]+(-[a-z0-9]+)*$/;

function parse(argv) {
  const o = { positional: [], json: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => { if (i + 1 >= argv.length) throw new Error(`${a} needs a value`); return argv[++i]; };
    if (a === '--version') o.version = val();
    else if (a === '--hash') o.hash = val();
    else if (a === '--task-class') o.task_class = val();
    else if (a === '--mode') o.mode = val();
    else if (a === '--model-family') o.model_family = val();
    else if (a === '--result') o.result = val();
    else if (a === '--json') o.json = true;
    else if (a === '--') { o.positional.push(...argv.slice(i + 1)); break; }
    else if (a.startsWith('--')) throw new Error(`unknown option ${a}`);
    else o.positional.push(a);
  }
  return o;
}

const out = (o, human, data) => { if (o.json) console.log(JSON.stringify(data, null, 2)); else for (const l of human) console.log(l); return 0; };
function refuse(o, e) {
  const code = e instanceof CalError ? e.code : 'skill_scope_denied';
  const message = e instanceof CalError ? e.message : 'unexpected failure';
  console.error(`error: ${code}: ${message}`);
  if (o.json) console.log(JSON.stringify({ ok: false, error: { code, message, ...(e.details ? { details: e.details } : {}) } }, null, 2));
  return 1;
}

function resolveSkill(dir, ref) {
  const ids = skillIds(dir);
  if (ids.includes(ref)) return ref;
  const hits = ids.filter((id) => id.split('.').slice(2).join('.') === ref);
  if (hits.length === 1) return hits[0];
  throw new CalError('skill_not_found', hits.length ? `"${ref}" names more than one skill here; use the full id (${hits.join(', ')})` : `no recorded use of a skill called "${ref}"`);
}

function cmdRecord(o, dir) {
  const ref = o.positional[0];
  if (!ref) throw new CalError('skill_not_found', '--skill-record needs a skill id or name');
  const skill = resolveSkill(dir, ref);
  const sel = { skill, version: o.version, hash: o.hash, task_class: o.task_class, mode: o.mode, model_family: o.model_family };
  const r = trackRecords(dir, sel);
  if (!r.records.length && !r.insufficient.length) throw new CalError('skill_not_found', 'no recorded use matches that version, hash and kind of task');
  if (!r.records.length) {
    const e = new CalError('skill_record_insufficient', `not enough resolved outcomes (at least ${r.insufficient[0].min_resolved} needed per record)`);
    console.error(`error: ${e.code}: ${e.message}`);
    for (const i of r.insufficient) console.error(`  ${i.subject.id} ${i.subject.version} on ${i.stratum.task_class} (${i.stratum.mode}, ${i.stratum.model_family}): ${i.n_resolved} resolved of ${i.n_uses} uses`);
    if (o.json) console.log(JSON.stringify({ ok: false, error: { code: e.code, message: e.message }, records: [], insufficient: r.insufficient }, null, 2));
    return 1;
  }
  return out(o, [...r.records.map(describeRecord), ...r.insufficient.map((i) => `${i.subject.id} ${i.subject.version} on ${i.stratum.task_class} (${i.stratum.mode}, ${i.stratum.model_family}): not enough resolved outcomes (${i.n_resolved} of ${i.min_resolved} needed; ${i.n_uses} uses recorded)`),
    'A track record describes what was recorded. It is not a claim about the skill.'], { ok: true, records: r.records, insufficient: r.insufficient });
}

function cmdReport(o, dir) {
  const useId = o.positional[0];
  if (!useId) throw new CalError('skill_use_not_found', '--report-outcome needs a use id');
  if (!RESULTS.includes(o.result)) throw new CalError('skill_outcome_invalid', `--result must be one of ${RESULTS.join(', ')}`);
  const r = reportOutcome(dir, { use_id: useId, result: o.result });
  const d = r.outcome;
  return out(o, [r.status === 'unchanged' ? `already recorded: ${d.outcome_id} for ${d.use_id}: ${d.result}` : `recorded ${d.outcome_id} for ${d.use_id}: ${d.result} (${d.tier})${r.superseded ? `; it supersedes ${r.superseded}` : ''}`], { ok: true, status: r.status, outcome: d, superseded: r.superseded ?? null });
}

function cmdMine(o, dir) {
  const r = trackRecords(dir, {});
  const bySkill = new Map();
  const add = (id) => { if (!bySkill.has(id)) bySkill.set(id, { skill: id, records: [], insufficient: [] }); return bySkill.get(id); };
  for (const x of r.records) add(x.subject.id).records.push(x);
  for (const x of r.insufficient) add(x.subject.id).insufficient.push(x);
  const skills = [...bySkill.values()].sort((a, b) => (a.skill < b.skill ? -1 : 1));
  const human = [];
  for (const s of skills) {
    human.push(s.skill);
    for (const x of s.records) human.push(`  ${describeRecord(x)}`);
    for (const x of s.insufficient) human.push(`  ${x.subject.version} on ${x.stratum.task_class} (${x.stratum.mode}, ${x.stratum.model_family}): not enough resolved outcomes (${x.n_resolved} of ${x.min_resolved} needed; ${x.n_uses} uses recorded)`);
  }
  if (!skills.length) human.push('(no skill uses recorded)');
  else human.push('A track record describes what was recorded. It is not a claim about the skill.');
  return out(o, human, { ok: true, principal: 'local', skills });
}

function cmdDelete(o, dir) {
  const r = deleteOutcome(dir, o.positional[0] || '');
  return out(o, [r.status === 'deleted' ? `deleted ${r.removed} recorded outcome(s) for ${o.positional[0]}; records recompute without them` : `no recorded outcome for ${o.positional[0]}`], { ok: true, ...r });
}

function cmdCompact(o, dir) {
  const r = compact(dir);
  return out(o, [`kept ${r.uses_kept} uses and ${r.outcomes_kept} outcomes; dropped ${r.uses_dropped} uses, ${r.outcomes_dropped} outcomes and ${r.unreadable_dropped} unreadable lines`], { ok: true, ...r });
}

// Reads one receipt (bounded) and notes each skill use in it. A receipt entry that names no skill (not projectable) is skipped.
function cmdRegister(o, dir) {
  const path = o.positional[0];
  if (!path) throw new CalError('skill_not_found', 'register-uses needs a decision-log.json');
  const fd = openSync(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  let log;
  try { const st = fstatSync(fd); if (!st.isFile() || st.size > 1024 * 1024) throw new CalError('skill_too_large', 'the receipt is not a regular file under 1 MiB'); const b = Buffer.alloc(st.size); readSync(fd, b, 0, st.size, 0); log = JSON.parse(b.toString('utf8')); } finally { closeSync(fd); }
  const tc = process.env.E3D_CALIBRATION_TASK_CLASS;
  if (tc !== undefined && tc !== '' && !(TASK.test(tc) && tc.length >= 3 && tc.length <= 40)) throw new CalError('skill_schema_format', 'E3D_CALIBRATION_TASK_CLASS must be 3 to 40 characters of lower-case letters, digits and single hyphens');
  let n = 0;
  for (const e of Array.isArray(log.skills) ? log.skills : []) {
    if (!e || !e.id || !e.use_id || !e.version || !e.definition_hash) continue;
    registerUse(dir, newUse({ use_id: e.use_id, skill: { id: e.id, version: e.version, hash: e.definition_hash }, mode: 'debate_seat', ...(tc ? { task_class: tc, task_class_source: 'declared' } : {}) }));
    n += 1;
  }
  return out(o, [`noted ${n} skill use(s) for outcome reporting`], { ok: true, noted: n });
}

const COMMANDS = { record: cmdRecord, report: cmdReport, mine: cmdMine, delete: cmdDelete, compact: cmdCompact, 'register-uses': cmdRegister };

const [cmd, ...rest] = process.argv.slice(2);
if (cmd) {
  let o = { json: false };
  let code;
  try {
    if (!COMMANDS[cmd]) throw new CalError('skill_schema_invalid', `unknown command ${cmd}`);
    try { o = parse(rest); } catch (e) { throw new CalError('skill_schema_invalid', e.message); }
    code = COMMANDS[cmd](o, stateDir());
  } catch (e) { code = refuse(o, e instanceof CalError ? e : Object.assign(new CalError('skill_scope_denied', e.message || 'failed'), {})); }
  process.exit(code);
}
