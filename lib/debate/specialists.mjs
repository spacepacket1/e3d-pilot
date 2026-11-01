// Experts as standard Agent Skill folders: parse, validate, hash and load (docs/specs/experts-phase1-private-experts-spec.md, Phase 1.1).
// Zero dependencies. This module only READS files: it opens no network connection, runs no process, executes nothing from a skill
// folder (scripts/ is never run) and writes nothing. Nothing calls it yet (the command line and the prompt change are Phase 1.2).
//
//   validateFolder(dir, { root })   -> { ok, errors[], warnings[], expert }   every rule of the spec, one coded error each
//   hashFolder(dir)                 -> 'sha256:<hex>'                          the content hash, computed here and never trusted from the folder
//   loadExperts({ tiers })          -> { experts[], errors[], overridden[] }   tiers low to high ([{ name, dir }]); a later tier wins by name
//
// An expert folder is a standard skill (agentskills.io/specification: SKILL.md with YAML frontmatter plus the lens text) with an optional
// sidecar e3d/expert.json for what the standard has no place for. The frontmatter parser reads a small YAML subset (scalars, quoted
// strings, | and > block scalars, one metadata map of strings) and refuses anything else with a coded error, so the engine needs no
// YAML library. A frontmatter field the engine does not know fails validation; allowed-tools is ignored with a warning, never granted.
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readdirSync, readFileSync, realpathSync } from 'node:fs';
import { basename, join, sep } from 'node:path';

export const LIMITS = Object.freeze({
  skillMdBytes: 32768, bodyChars: 8000, descriptionMax: 1024, licenseMax: 200, compatibilityMax: 500,
  metadataKeys: 32, metadataKeyMax: 64, metadataValueMax: 512, files: 200, totalBytes: 2 * 1024 * 1024,
  sidecarBytes: 32768, sidecarList: 50, sidecarString: 200, maxWordsMin: 20, maxWordsMax: 2000,
});

const NAME_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/; // the spec: lowercase letters, digits, single hyphens, none leading or trailing
const PROVIDER_RE = /^[a-z][a-z0-9-]{0,31}$/;
const FRONT_KEYS = new Set(['name', 'description', 'license', 'compatibility', 'metadata', 'allowed-tools']);
const SIDECAR_KEYS = new Set(['schema', 'tasks', 'models', 'tools', 'limits', 'required_evidence', 'tests']);
const EFFORTS = new Set(['low', 'medium', 'high']);
const SKIP_NAMES = new Set(['.git', '.DS_Store']); // machine-specific files never belong to a skill's identity
const HASH_KEY = 'e3d.expert.hash';

const err = (code, message, file) => ({ code, message, ...(file ? { file } : {}) });

// ---------- the YAML subset ----------

function unquote(raw) {
  const q = raw[0];
  if (raw.length < 2 || raw[raw.length - 1] !== q) return null;
  const inner = raw.slice(1, -1);
  if (q === "'") return inner.replace(/''/g, '').includes("'") ? null : inner.replace(/''/g, "'");
  let out = '';
  for (let i = 0; i < inner.length; i++) {
    const c = inner[i];
    if (c === '\\') {
      const n = inner[++i];
      if (n === '"' || n === '\\') out += n;
      else if (n === 'n') out += '\n';
      else if (n === 't') out += '\t';
      else return null;
    } else if (c === '"') return null;
    else out += c;
  }
  return out;
}

// One scalar after "key:". Returns { value } or { error }.
function scalar(rawValue) {
  const raw = rawValue.trim();
  if (raw === '' || raw[0] === '#') return { value: '' };
  if (raw[0] === '"' || raw[0] === "'") {
    const v = unquote(raw);
    return v === null ? { error: 'a quoted string is not closed or has an unsupported escape' } : { value: v };
  }
  if ('[{&*!%@`'.includes(raw[0]) || raw === '|' || raw === '>') return { error: `"${raw[0]}" starts a YAML construct this engine does not read; quote the value` };
  return { value: raw.replace(/\s+#.*$/, '').trim() };
}

function parseFrontmatter(text) {
  const errors = [];
  const data = {};
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.trim() === '' || line.trim()[0] === '#') continue;
    if (/^\t/.test(line) || /^\s/.test(line)) { errors.push(err('yaml_unsupported', `line ${i + 1}: unexpected indentation`)); continue; }
    const m = /^([A-Za-z0-9_.-]+):(?:[ \t]+(.*))?$/.exec(line);
    if (!m) { errors.push(err('yaml_unsupported', `line ${i + 1}: expected "key: value"`)); continue; }
    const key = m[1];
    const rest = m[2] ?? '';
    if (Object.prototype.hasOwnProperty.call(data, key)) { errors.push(err('duplicate_field', `"${key}" appears twice`)); continue; }
    if (key === 'metadata') {
      if (rest.trim() !== '' && rest.trim()[0] !== '#') { errors.push(err('bad_metadata', 'metadata must be a map on the following indented lines')); continue; }
      const map = {};
      let indent = null;
      while (i + 1 < lines.length && (lines[i + 1].trim() === '' || /^[ \t]/.test(lines[i + 1]))) {
        const l = lines[++i];
        if (l.trim() === '' || l.trim()[0] === '#') continue;
        const mm = /^( +)([A-Za-z0-9_.-]+):(?:[ \t]+(.*))?$/.exec(l);
        if (!mm || /\t/.test(l.slice(0, mm[1].length))) { errors.push(err('bad_metadata', `line ${i + 1}: expected an indented "key: value" with spaces`)); continue; }
        if (indent === null) indent = mm[1].length;
        if (mm[1].length !== indent) { errors.push(err('bad_metadata', `line ${i + 1}: metadata values may not be nested`)); continue; }
        if (['__proto__', 'constructor', 'prototype'].includes(mm[2])) { errors.push(err('bad_metadata', `metadata key "${mm[2]}" is not allowed`)); continue; }
        if (Object.prototype.hasOwnProperty.call(map, mm[2])) { errors.push(err('duplicate_field', `metadata key "${mm[2]}" appears twice`)); continue; }
        const s = scalar(mm[3] ?? '');
        if (s.error) { errors.push(err('bad_metadata', `line ${i + 1}: ${s.error}`)); continue; }
        map[mm[2]] = s.value;
      }
      data.metadata = map;
      continue;
    }
    const block = /^([|>])([+-]?)\s*(#.*)?$/.exec(rest.trim());
    if (block) {
      const body = [];
      let base = null;
      while (i + 1 < lines.length && (lines[i + 1].trim() === '' || /^[ ]/.test(lines[i + 1]))) {
        const l = lines[++i];
        if (l.trim() === '') { body.push(''); continue; }
        const lead = /^ */.exec(l)[0].length;
        if (base === null) base = lead;
        body.push(l.slice(Math.min(lead, base)));
      }
      while (body.length && body[body.length - 1] === '') body.pop();
      data[key] = block[1] === '|' ? body.join('\n') : body.join('\n').replace(/([^\n])\n(?!\n)/g, '$1 ').replace(/\n\n/g, '\n');
      continue;
    }
    const s = scalar(rest);
    if (s.error) { errors.push(err('yaml_unsupported', `"${key}": ${s.error}`)); continue; }
    data[key] = s.value;
  }
  return { data, errors };
}

// Splits SKILL.md into { front, body }; the file must open with a --- line and close the frontmatter with another.
function splitSkill(text) {
  const t = text.replace(/\r\n/g, '\n').replace(/^﻿/, '');
  if (!t.startsWith('---\n')) return { error: err('no_frontmatter', 'SKILL.md must start with a "---" line and YAML frontmatter', 'SKILL.md') };
  const end = t.indexOf('\n---', 3);
  if (end === -1 || !/^(\n|$)/.test(t.slice(end + 4))) return { error: err('no_frontmatter', 'the frontmatter is not closed by a "---" line', 'SKILL.md') };
  return { front: t.slice(4, end), body: t.slice(end + 4).replace(/^\n+/, '').replace(/\s+$/, '') };
}

// ---------- the folder walk and the hash ----------

function walk(dir) {
  const files = [];
  const errors = [];
  let total = 0;
  const visit = (abs, rel) => {
    for (const name of readdirSync(abs).sort()) {
      if (SKIP_NAMES.has(name)) continue;
      const a = join(abs, name);
      const r = rel ? `${rel}/${name}` : name;
      const st = lstatSync(a);
      if (st.isSymbolicLink()) { errors.push(err('symlink_in_skill', `${r} is a symbolic link; links are not allowed inside a skill folder`, r)); continue; }
      if (st.isDirectory()) { visit(a, r); continue; }
      if (!st.isFile()) { errors.push(err('special_file', `${r} is not a regular file`, r)); continue; }
      total += st.size;
      files.push({ rel: r, abs: a, size: st.size });
      if (files.length > LIMITS.files) { errors.push(err('too_many_files', `more than ${LIMITS.files} files`)); return false; }
      if (total > LIMITS.totalBytes) { errors.push(err('too_large', `the folder is larger than ${LIMITS.totalBytes} bytes`)); return false; }
    }
    return true;
  };
  visit(dir, '');
  return { files, errors };
}

function isText(buf) {
  return !buf.includes(0) && Buffer.from(buf.toString('utf8'), 'utf8').equals(buf);
}

// SKILL.md may carry the hash of the folder in metadata; the hash cannot cover itself, so that one line is left out of the hashed text.
function hashed(rel, buf) {
  if (!isText(buf)) return buf;
  let t = buf.toString('utf8').replace(/\r\n/g, '\n');
  if (rel === 'SKILL.md') t = t.replace(new RegExp(`^[ \\t]*${HASH_KEY.replace(/\./g, '\\.')}[ \\t]*:.*(\\n|$)`, 'gm'), '');
  return Buffer.from(t, 'utf8');
}

export function hashFolder(dir) {
  const { files, errors } = walk(dir);
  if (errors.length) throw new Error(errors[0].message);
  const rows = files.map((f) => {
    const buf = hashed(f.rel, readFileSync(f.abs));
    return { rel: f.rel, line: `${f.rel}\0${buf.length}\0${createHash('sha256').update(buf).digest('hex')}\n` };
  });
  rows.sort((a, b) => Buffer.compare(Buffer.from(a.rel), Buffer.from(b.rel)));
  return `sha256:${createHash('sha256').update(rows.map((r) => r.line).join('')).digest('hex')}`;
}

// ---------- the sidecar ----------

const isStr = (v, max = LIMITS.sidecarString) => typeof v === 'string' && v.length > 0 && v.length <= max;

function readSidecar(dir) {
  const errors = [];
  const file = join(dir, 'e3d', 'expert.json');
  const base = { schema: 'expert/v1', tasks: [], models: [], tools: 'none', limits: {}, required_evidence: [], tests: [] };
  if (!existsSync(file)) return { sidecar: base, errors, present: false };
  const bytes = readFileSync(file);
  if (bytes.length > LIMITS.sidecarBytes) return { sidecar: base, errors: [err('bad_sidecar', `e3d/expert.json is larger than ${LIMITS.sidecarBytes} bytes`, 'e3d/expert.json')], present: true };
  let j;
  try { j = JSON.parse(bytes.toString('utf8')); } catch { return { sidecar: base, errors: [err('bad_sidecar', 'e3d/expert.json is not valid JSON', 'e3d/expert.json')], present: true }; }
  const bad = (m) => errors.push(err('bad_sidecar', m, 'e3d/expert.json'));
  if (j === null || typeof j !== 'object' || Array.isArray(j)) { bad('must be a JSON object'); return { sidecar: base, errors, present: true }; }
  for (const k of Object.keys(j)) if (!SIDECAR_KEYS.has(k)) bad(`unknown field "${k}"`);
  if (j.schema !== undefined && j.schema !== 'expert/v1') bad('schema must be "expert/v1"');
  if (j.tools !== undefined && j.tools !== 'none') bad('tools must be "none" in Phase 1 (read access is not enforced the same way by every provider)');
  const list = (k, ok) => {
    if (j[k] === undefined) return;
    if (!Array.isArray(j[k]) || j[k].length > LIMITS.sidecarList) { bad(`${k} must be a list of at most ${LIMITS.sidecarList} items`); return; }
    j[k].forEach((v, i) => { if (!ok(v)) bad(`${k}[${i}] is not valid`); });
  };
  list('tasks', (v) => isStr(v, 64));
  list('required_evidence', (v) => isStr(v));
  list('tests', (v) => isStr(v) || (v !== null && typeof v === 'object' && !Array.isArray(v) && JSON.stringify(v).length <= 1000));
  list('models', (v) => v !== null && typeof v === 'object' && !Array.isArray(v)
    && Object.keys(v).every((k) => k === 'provider' || k === 'effort') && typeof v.provider === 'string' && PROVIDER_RE.test(v.provider)
    && (v.effort === undefined || EFFORTS.has(v.effort)));
  if (j.limits !== undefined) {
    const l = j.limits;
    if (l === null || typeof l !== 'object' || Array.isArray(l) || Object.keys(l).some((k) => k !== 'max_words')) bad('limits may only contain max_words');
    else if (l.max_words !== undefined && !(Number.isInteger(l.max_words) && l.max_words >= LIMITS.maxWordsMin && l.max_words <= LIMITS.maxWordsMax)) bad(`limits.max_words must be a whole number from ${LIMITS.maxWordsMin} to ${LIMITS.maxWordsMax}`);
  }
  return { sidecar: errors.length ? base : { ...base, ...j }, errors, present: true };
}

// ---------- one folder ----------

// root: the tier directory the folder must stay inside (a folder that is a link out of it is refused).
export function validateFolder(dir, { root } = {}) {
  const errors = [];
  const warnings = [];
  const folder = basename(dir);
  let st;
  try { st = lstatSync(dir); } catch { return { ok: false, errors: [err('not_found', `${dir} does not exist`)], warnings, expert: null }; }
  if (st.isSymbolicLink()) {
    let real;
    try { real = realpathSync(dir); } catch { return { ok: false, errors: [err('symlink_escape', 'the folder is a broken link')], warnings, expert: null }; }
    const realRoot = root ? realpathSync(root) : null;
    if (!realRoot || !(real === realRoot || real.startsWith(realRoot + sep))) return { ok: false, errors: [err('symlink_escape', 'the folder is a link that leaves its tier directory')], warnings, expert: null };
  }
  if (!(st.isDirectory() || st.isSymbolicLink())) return { ok: false, errors: [err('not_a_folder', `${dir} is not a folder`)], warnings, expert: null };

  const { files, errors: walkErrors } = walk(dir);
  errors.push(...walkErrors);

  const skillFile = join(dir, 'SKILL.md');
  if (!existsSync(skillFile)) { errors.push(err('missing_skill_md', 'the folder has no SKILL.md', 'SKILL.md')); return { ok: false, errors, warnings, expert: null }; }
  const raw = readFileSync(skillFile);
  if (raw.length > LIMITS.skillMdBytes) errors.push(err('skill_md_too_large', `SKILL.md is larger than ${LIMITS.skillMdBytes} bytes`, 'SKILL.md'));
  if (raw.includes(0)) errors.push(err('binary_skill_md', 'SKILL.md contains a NUL byte', 'SKILL.md'));

  let front = null;
  let body = '';
  const parts = errors.some((e) => e.code === 'skill_md_too_large' || e.code === 'binary_skill_md') ? null : splitSkill(raw.toString('utf8'));
  if (parts && parts.error) errors.push(parts.error);
  else if (parts) {
    const parsed = parseFrontmatter(parts.front);
    errors.push(...parsed.errors.map((e) => ({ ...e, file: 'SKILL.md' })));
    front = parsed.data;
    body = parts.body;
  }

  if (front) {
    for (const k of Object.keys(front)) {
      if (!FRONT_KEYS.has(k)) errors.push(err('unknown_field', `frontmatter field "${k}" is not part of the skill standard and is not known to this engine`, 'SKILL.md'));
    }
    const name = front.name;
    if (typeof name !== 'string' || name === '') errors.push(err('bad_name', 'name is required', 'SKILL.md'));
    else if (name.length > 64 || !NAME_RE.test(name)) errors.push(err('bad_name', 'name must be 1 to 64 characters: lowercase letters, digits and single hyphens, none leading or trailing', 'SKILL.md'));
    else if (name !== folder) errors.push(err('name_folder_mismatch', `name "${name}" must equal the folder name "${folder}"`, 'SKILL.md'));
    const d = front.description;
    if (typeof d !== 'string' || d.trim() === '') errors.push(err('bad_description', 'description is required and may not be empty', 'SKILL.md'));
    else if (d.length > LIMITS.descriptionMax) errors.push(err('bad_description', `description is longer than ${LIMITS.descriptionMax} characters`, 'SKILL.md'));
    if (front.license !== undefined && (typeof front.license !== 'string' || front.license.length > LIMITS.licenseMax)) errors.push(err('bad_license', `license must be short text (at most ${LIMITS.licenseMax} characters)`, 'SKILL.md'));
    if (front.compatibility !== undefined && (typeof front.compatibility !== 'string' || front.compatibility.length < 1 || front.compatibility.length > LIMITS.compatibilityMax)) errors.push(err('bad_compatibility', `compatibility must be 1 to ${LIMITS.compatibilityMax} characters`, 'SKILL.md'));
    if (front.metadata !== undefined) {
      const keys = Object.keys(front.metadata);
      if (keys.length > LIMITS.metadataKeys) errors.push(err('bad_metadata', `more than ${LIMITS.metadataKeys} metadata keys`, 'SKILL.md'));
      for (const k of keys) {
        if (k.length > LIMITS.metadataKeyMax) errors.push(err('bad_metadata', `metadata key "${k.slice(0, 20)}..." is longer than ${LIMITS.metadataKeyMax}`, 'SKILL.md'));
        if (front.metadata[k].length > LIMITS.metadataValueMax) errors.push(err('bad_metadata', `metadata value for "${k}" is longer than ${LIMITS.metadataValueMax}`, 'SKILL.md'));
      }
    }
    if (Object.prototype.hasOwnProperty.call(front, 'allowed-tools')) warnings.push(err('allowed_tools_ignored', 'allowed-tools is ignored: a skill file never pre-approves a tool', 'SKILL.md'));
    if (body === '') errors.push(err('empty_body', 'the lens text (the Markdown after the frontmatter) is empty', 'SKILL.md'));
    else if (body.length > LIMITS.bodyChars) errors.push(err('body_too_large', `the lens text is longer than ${LIMITS.bodyChars} characters (it is repeated in every round)`, 'SKILL.md'));
  }

  if (files.some((f) => f.rel === 'scripts' || f.rel.startsWith('scripts/'))) warnings.push(err('scripts_present_never_run', 'scripts/ is present; it is never run and is ignored', 'scripts'));

  const side = readSidecar(dir);
  errors.push(...side.errors);

  if (errors.length) return { ok: false, errors, warnings, expert: null };

  let hash;
  try { hash = hashFolder(dir); } catch (e) { return { ok: false, errors: [err('hash_failed', e.message)], warnings, expert: null }; }
  const claimed = front.metadata && front.metadata[HASH_KEY];
  if (claimed !== undefined && claimed !== hash) warnings.push(err('stale_metadata_hash', `metadata ${HASH_KEY} does not match the folder (computed ${hash}); the computed value is used`, 'SKILL.md'));

  return {
    ok: true,
    errors,
    warnings,
    expert: {
      name: front.name,
      description: front.description,
      license: front.license ?? null,
      metadata: front.metadata ?? {},
      lens: body,
      sidecar: side.sidecar,
      sidecarPresent: side.present,
      hash,
      dir,
    },
  };
}

// ---------- the tiers ----------

// tiers: low to high precedence, [{ name: 'built-in'|'user'|'repo', dir }]. A missing tier directory is simply empty. One bad folder never hides the others.
export function loadExperts({ tiers }) {
  const byName = new Map();
  const errors = [];
  const overridden = [];
  for (const tier of tiers) {
    if (!tier.dir || !existsSync(tier.dir)) continue;
    let entries;
    try { entries = readdirSync(tier.dir).sort(); } catch { continue; }
    for (const entry of entries) {
      if (entry.startsWith('.')) continue;
      const dir = join(tier.dir, entry);
      let st;
      try { st = lstatSync(dir); } catch { continue; }
      if (!st.isDirectory() && !st.isSymbolicLink()) continue;
      const r = validateFolder(dir, { root: tier.dir });
      if (!r.ok) { errors.push({ tier: tier.name, folder: entry, errors: r.errors }); continue; }
      const expert = { ...r.expert, tier: tier.name, warnings: r.warnings };
      const prior = byName.get(expert.name);
      if (prior) overridden.push({ name: expert.name, from: prior.tier, by: tier.name });
      byName.set(expert.name, expert);
    }
  }
  return { experts: [...byName.values()].sort((a, b) => (a.name < b.name ? -1 : 1)), errors, overridden };
}
