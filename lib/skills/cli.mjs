#!/usr/bin/env node
// Command front end for skills (docs/skills/phase1/adr/0005-api-names.md), called by bin/e3d-debate behind E3D_SKILLS_V1=1. Zero dependencies.
//
//   list      --builtin D --user D --repo D [--json]
//   show      <ref> --builtin D --user D --repo D [--version V] [--hash H]     the definition as JSON, with its resolved tier and pin
//   validate  <folder>                                                          schema, hash and safety checks; nothing is stored (inert import)
//   project   <name|folder> --builtin D --user D --repo D                       dry run: the definition an expert folder projects to, and what is lossy
//   export    <ref> <outdir> --builtin D --user D --repo D                      writes a NEW native folder <outdir>/<slug>; never overwrites
//   diff      <ref|folder> <ref|folder> --builtin D --user D --repo D           field-level difference and whether the hashes agree
//
// No command calls a model or the network. Only `export` writes, and only inside the new folder it creates.
import { lstatSync } from 'node:fs';
import { resolve } from 'node:path';
import { diffDefinitions, exportSkill, loadSkills, projectExpert, resolveSkill, skillFromFolder } from './definition.mjs';
import { loadExperts, validateFolder } from '../debate/specialists.mjs';

function parse(argv) {
  const o = { positional: [], json: false, builtinOnly: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => { if (i + 1 >= argv.length) throw new Error(`${a} needs a value`); return argv[++i]; };
    if (a === '--builtin') o.builtin = val();
    else if (a === '--user') o.user = val();
    else if (a === '--repo') o.repo = val();
    else if (a === '--version') o.version = val();
    else if (a === '--hash') o.hash = val();
    else if (a === '--json') o.json = true;
    else if (a === '--builtin-only') o.builtinOnly = true;
    else if (a === '--') { o.positional.push(...argv.slice(i + 1)); break; } // everything after -- is a value, never an option
    else if (a.startsWith('--')) throw new Error(`unknown option ${a}`);
    else o.positional.push(a);
  }
  return o;
}

const tiersOf = (o) => (o.builtinOnly ? [{ name: 'built-in', dir: o.builtin }] : [{ name: 'built-in', dir: o.builtin }, { name: 'user', dir: o.user }, { name: 'repo', dir: o.repo }]);
const short = (h) => h.replace('sha256:', '').slice(0, 8);
// An argument is a FOLDER only when it is written like a path (contains a slash or starts with a dot); a bare word is always a skill id or name, so a
// folder that happens to sit in the current directory can never stand in for a skill.
const looksLikePath = (p) => /[\\/]/.test(p) || p.startsWith('.');
const isFolder = (p) => { try { return lstatSync(p).isDirectory(); } catch { return false; } };
const printErrors = (list, prefix = 'error') => { for (const e of list) console.error(`${prefix}: ${e.code}: ${e.message}${e.path ? ` (${e.path})` : ''}`); };

function cmdList(o) {
  const { skills, errors } = loadSkills({ tiers: tiersOf(o) });
  if (o.json) { console.log(JSON.stringify(skills.map((s) => ({ id: s.definition.id, version: s.definition.version, definition_hash: s.definition.definition_hash, tier: s.tier, source_format: s.definition.provenance.source_format, capability_level: s.definition.capability_level })), null, 2)); return 0; }
  const w = Math.max(24, ...skills.map((s) => s.definition.id.length + 1));
  console.log(`${'ID'.padEnd(w)}${'VERSION'.padEnd(9)}${'HASH'.padEnd(10)}${'TIER'.padEnd(10)}${'LEVEL'.padEnd(14)}DESCRIPTION`);
  for (const s of skills) console.log(`${s.definition.id.padEnd(w)}${s.definition.version.padEnd(9)}${short(s.definition.definition_hash).padEnd(10)}${s.tier.padEnd(10)}${s.definition.capability_level.padEnd(14)}${s.definition.description.replace(/\s+/g, ' ').slice(0, 60)}`);
  if (!skills.length) console.log('(no skills found)');
  for (const x of errors) for (const e of x.errors) console.error(`warning: ${x.tier}/${x.folder}: ${e.code}: ${e.message}`);
  return 0;
}

function cmdShow(o) {
  const ref = o.positional[0];
  if (!ref) { console.error('error: --show-skill needs a skill id or name'); return 1; }
  const { skills } = loadSkills({ tiers: tiersOf(o) });
  const r = resolveSkill(skills, ref, { version: o.version, hash: o.hash });
  if (!r.ok) { printErrors([r.error]); return 1; }
  for (const x of r.overridden) console.error(`note: ${x.id} (${x.tier}) is hidden by ${r.skill.definition.id} (${r.skill.tier}) for the name "${ref}"; use the full id to select it`);
  if (r.deprecated) console.error(`warning: ${r.skill.definition.id} is deprecated`);
  console.log(JSON.stringify({ tier: r.skill.tier, definition: r.skill.definition }, null, 2));
  return 0;
}

function cmdValidate(o) {
  const dir = o.positional[0];
  if (!dir) { console.error('error: --validate-skill needs a folder'); return 1; }
  const r = skillFromFolder(resolve(dir), { root: resolve(dir, '..'), tier: 'user' });
  for (const w of r.warnings) console.error(`warning: ${w.code}: ${w.message}`);
  if (!r.ok) { printErrors(r.errors); return 1; }
  const d = r.definition;
  console.log(`ok: ${d.id} ${d.version} ${d.capability_level} (${d.provenance.source_format})`);
  console.log(`definition_hash: ${d.definition_hash}`);
  console.log(`legacy_folder_hash: ${d.provenance.legacy_folder_hash}`);
  for (const l of r.lossy) console.log(`note: ${l.field}: ${l.note}`);
  return 0;
}

function cmdProject(o) {
  const target = o.positional[0];
  if (!target) { console.error('error: --project-expert needs an expert name or folder'); return 1; }
  let expert; let tier = 'user';
  if (looksLikePath(target)) {
    if (!isFolder(target)) { console.error(`error: ${target} is not a folder`); return 1; }
    const r = validateFolder(resolve(target), { root: resolve(target, '..') });
    if (!r.ok) { printErrors(r.errors); return 1; }
    expert = r.expert;
  } else {
    const { experts } = loadExperts({ tiers: tiersOf(o) });
    expert = experts.find((e) => e.name === target);
    if (!expert) { console.error(`error: no expert named "${target}" and no folder at that path`); return 1; }
    tier = expert.tier;
  }
  const p = projectExpert(expert, tier);
  console.log(JSON.stringify({ projectable: p.notProjectable.length === 0, notProjectable: p.notProjectable, lossy: p.lossy, definition: p.definition }, null, 2));
  return p.notProjectable.length ? 1 : 0;
}

function cmdExport(o) {
  const [ref, outdir] = o.positional;
  if (!ref || !outdir) { console.error('error: --export-skill needs a skill id or name and a new output folder'); return 1; }
  const { skills } = loadSkills({ tiers: tiersOf(o) });
  const r = resolveSkill(skills, ref);
  if (!r.ok) { printErrors([r.error]); return 1; }
  try {
    const { dir, definition } = exportSkill(r.skill.definition, resolve(outdir));
    const copied = definition.id !== r.skill.definition.id;
    console.log(`exported ${r.skill.definition.id} ${r.skill.definition.version} to ${dir}`);
    if (copied) console.log(`note: a built-in is exported as a local copy: ${definition.id} (private, draft), so its hash differs from the built-in's`);
    console.log(`definition_hash: ${definition.definition_hash} (reproduced from the exported folder)`);
    return 0;
  } catch (e) { console.error(`error: ${e.message}`); return 1; }
}

function load1(o, what) {
  if (looksLikePath(what)) {
    if (!isFolder(what)) { console.error(`error: ${what} is not a folder`); return null; }
    const r = skillFromFolder(resolve(what), { root: resolve(what, '..'), tier: 'user' });
    if (!r.ok) { printErrors(r.errors); return null; }
    return r.definition;
  }
  const { skills } = loadSkills({ tiers: tiersOf(o) });
  const r = resolveSkill(skills, what);
  if (!r.ok) { printErrors([r.error]); return null; }
  return r.skill.definition;
}

function cmdDiff(o) {
  const [a, b] = o.positional;
  if (!a || !b) { console.error('error: --diff-skill needs two skill ids, names or folders'); return 1; }
  const da = load1(o, a); const db = load1(o, b);
  if (!da || !db) return 1;
  const d = diffDefinitions(da, db);
  console.log(`${da.id} ${da.version} ${short(da.definition_hash)}  vs  ${db.id} ${db.version} ${short(db.definition_hash)}`);
  console.log(d.hashEqual ? 'definition_hash: identical' : 'definition_hash: different');
  if (d.same) console.log('no field differs');
  for (const f of d.fields) console.log(`  ${f.change.padEnd(8)} ${f.field}`);
  return d.hashEqual ? 0 : 3; // 3: different, so a script can tell "differs" from an error
}

const [cmd, ...rest] = process.argv.slice(2);
const table = { list: cmdList, show: cmdShow, validate: cmdValidate, project: cmdProject, export: cmdExport, diff: cmdDiff };
if (!table[cmd]) { console.error(`usage: cli.mjs ${Object.keys(table).join('|')} ...`); process.exit(2); }
try { process.exit(table[cmd](parse(rest))); } catch (e) { console.error(`error: ${e.message}`); process.exit(2); }
