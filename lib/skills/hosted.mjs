// Hosted skills for one run (docs/skills/phase3/plan-3c-hosted-user-skills.md, PR H2a). Zero dependencies; reads one file, writes nothing, calls no model.
//
//   readHostedFile(path)            -> { ok, principal, definitions } | { ok: false, error }
//   addHosted(catalogue, file)      -> { ok, catalogue } | { ok: false, error }
//
// The hosted service (the listener, H2c) writes ONE private file for a run: { principal, skills: [definition, ...] }. Here every definition goes through
// intakeSkill (the engine recomputes the hash and checks everything the hash does not cover against the principal) and joins the catalogue as tier "hosted",
// reachable only by its full id. All or nothing: one refused definition refuses the run before any call, and the error carries codes and paths only, never text.
import { closeSync, constants, fstatSync, lstatSync, openSync, readSync } from 'node:fs';
import { intakeSkill } from './intake.mjs';

export const HOSTED_FILE_MAX = 256 * 1024;
export const HOSTED_MAX_SKILLS = 4;
const err = (code, message, path) => ({ code, message, ...(path ? { path } : {}) });

export function readHostedFile(path) {
  if (typeof path !== 'string' || path === '') return { ok: false, error: err('skill_not_found', 'no hosted skills file was named') };
  let st;
  try { st = lstatSync(path); } catch { return { ok: false, error: err('skill_not_found', 'the hosted skills file does not exist') }; }
  if (!st.isFile()) return { ok: false, error: err('skill_invalid', 'the hosted skills path is not a regular file') };
  // read through ONE descriptor opened without following a symlink: the size cap is checked on that descriptor and at most the cap plus one byte is read, so a file
  // swapped between the check and the read can never make this read more than the cap or read another file
  let fd; let text;
  try {
    fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    const fst = fstatSync(fd);
    if (!fst.isFile()) return { ok: false, error: err('skill_invalid', 'the hosted skills path is not a regular file') };
    if (fst.size > HOSTED_FILE_MAX) return { ok: false, error: err('skill_too_large', `the hosted skills file is larger than ${HOSTED_FILE_MAX} bytes`) };
    const buf = Buffer.alloc(HOSTED_FILE_MAX + 1);
    let got = 0;
    for (;;) { const r = readSync(fd, buf, got, buf.length - got, null); if (r === 0) break; got += r; if (got > HOSTED_FILE_MAX) return { ok: false, error: err('skill_too_large', `the hosted skills file is larger than ${HOSTED_FILE_MAX} bytes`) }; }
    text = buf.subarray(0, got).toString('utf8');
  } catch { return { ok: false, error: err('skill_invalid', 'the hosted skills file could not be read') }; } finally { if (fd !== undefined) try { closeSync(fd); } catch { /* nothing to do */ } }
  let j;
  try { j = JSON.parse(text); } catch { return { ok: false, error: err('skill_schema_invalid', 'the hosted skills file is not valid JSON') }; }
  if (j === null || typeof j !== 'object' || Array.isArray(j) || Object.keys(j).sort().join() !== 'principal,skills') return { ok: false, error: err('skill_schema_unknown_field', 'the hosted skills file must be { principal, skills } and nothing else') };
  if (!Array.isArray(j.skills) || j.skills.length < 1 || j.skills.length > HOSTED_MAX_SKILLS) return { ok: false, error: err('skill_schema_limit', `skills must be 1 to ${HOSTED_MAX_SKILLS} definitions`, 'skills') };
  return { ok: true, principal: j.principal, definitions: j.skills };
}

export function addHosted(catalogue, file, opts = {}) {
  const r = readHostedFile(file);
  if (!r.ok) return r;
  const entries = [];
  const seen = new Set();
  for (let i = 0; i < r.definitions.length; i++) {
    const x = intakeSkill(r.definitions[i], { principal: r.principal, ...opts });
    if (!x.ok) return { ok: false, error: err(x.errors[0]?.code ?? 'skill_invalid', `hosted skill ${i + 1} was refused (${[...new Set(x.errors.map((e) => e.code))].join(', ')})`, `skills[${i}]`) };
    if (seen.has(x.definition.id)) return { ok: false, error: err('skill_conflict', `hosted skill ${i + 1} repeats an id`, `skills[${i}]`) };
    seen.add(x.definition.id);
    entries.push(x.entry);
  }
  return { ok: true, catalogue: { ...catalogue, skills: [...catalogue.skills, ...entries] }, principal: r.principal };
}
