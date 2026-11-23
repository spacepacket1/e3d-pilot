// The local calibration store (calibration spec phase 2; ADR-0016 to 0020). Two append-only JSONL files in one private directory:
//   uses.jsonl      one SkillUse document per line (a use of a skill; the use_id is issued here and expires after 90 days)
//   outcomes.jsonl  {"k":"outcome","doc":<Outcome>} or {"k":"tombstone","use_id":..,"at":..} per line
// Holds identifiers, enums, counts and timestamps only: there is no field for free text, and every write is checked against the committed schema.
// Nothing is rewritten in place: a correction is a later outcome that names the one it supersedes; a deletion is a tombstone; `compact` is the only
// rewrite (atomic replace under the lock) and the only way a superseded or deleted outcome leaves the file. Local only: no network, no model.
//
// State directory: $E3D_CALIBRATION_DIR, else ~/.config/e3d-pilot/calibration (the engine's existing per-user state location, beside `specialists`).
// Safety: the directory is created 0700 and files 0600; a symlink as the directory or as a data file (the final path component is checked, parent
// directories are not), a foreign owner, a hard-linked data file or group/other access refuses the call;
// appends are one O_APPEND write of a line capped at MAX_LINE bytes, taken under a lock file; reads refuse a file larger than MAX_FILE and never read more.
import { chmodSync, closeSync, constants, fstatSync, fsyncSync, linkSync, lstatSync, mkdirSync, openSync, readdirSync, readSync, renameSync, unlinkSync, writeSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { homedir } from 'node:os';
import { isAbsolute, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createSchemaSet } from '../skills/jsonschema.mjs';
import { MIN_RESOLVED, computeTrackRecord, extrasFor, strataOf } from './record.mjs';

const schemas = createSchemaSet(fileURLToPath(new URL('../skills/schemas/v1', import.meta.url)));
export const ERROR_CODES = schemas.load('error-codes.json').codes;

export const USE_DAYS = 90;
export const RECORD_DAYS = 365;
export const MAX_FILE = 4 * 1024 * 1024; // a file larger than this is refused, never read
export const MAX_LINE = 4096; // one append is one write of at most this many bytes
export const LOCAL_PRINCIPAL = 'local';
const DAY_MS = 86400000;
const LOCK_HARD_STALE_MS = 10 * 60000; // a lock whose holder is alive but older than this is taken over (a pid can be reused, a process can hang)
const LOCK_UNREADABLE_MS = 2000; // a lock with no readable owner is taken over after this
export const SKEW_MS = DAY_MS; // a timestamp this far ahead of the clock is refused
const LOCK_WAIT_MS = 5000;

export class CalError extends Error {
  constructor(code, message, extra = {}) {
    super(message);
    this.code = code;
    Object.assign(this, extra);
    if (!ERROR_CODES[code]) throw new Error(`unregistered calibration error code ${code}`);
  }
}

export const stateDir = (env = process.env) => {
  const d = env.E3D_CALIBRATION_DIR || join(env.HOME || homedir(), '.config', 'e3d-pilot', 'calibration');
  if (!isAbsolute(d)) throw new CalError('skill_scope_denied', 'the calibration directory must be an absolute path');
  return d;
};

const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
export const newOutcomeId = () => `out_${randomBytes(10).toString('hex')}`;
const me = typeof process.getuid === 'function' ? process.getuid() : null;
const O_NOFOLLOW = constants.O_NOFOLLOW ?? 0;

// ---- the directory and its files -----------------------------------------------------------------------------------------------------------------------
function checkDir(dir, create) {
  let st = null;
  try { st = lstatSync(dir); } catch (e) { if (e.code !== 'ENOENT') throw new CalError('skill_scope_denied', `cannot inspect the calibration directory (${e.code})`); }
  if (!st) {
    if (!create) return false;
    try { mkdirSync(dir, { recursive: true, mode: 0o700 }); chmodSync(dir, 0o700); } catch (e) { throw new CalError('skill_scope_denied', `cannot create the calibration directory (${e.code})`); }
    st = lstatSync(dir);
  }
  if (st.isSymbolicLink()) throw new CalError('skill_scope_denied', 'the calibration directory is a symbolic link; refusing to follow it');
  if (!st.isDirectory()) throw new CalError('skill_scope_denied', 'the calibration path is not a directory');
  if (me !== null && st.uid !== me) throw new CalError('skill_scope_denied', 'the calibration directory belongs to another user');
  if ((st.mode & 0o077) !== 0) throw new CalError('skill_scope_denied', 'the calibration directory must not be accessible to group or others (mode 0700)');
  return true;
}

function checkFd(fd, name) {
  const st = fstatSync(fd);
  if (!st.isFile()) throw new CalError('skill_scope_denied', `${name} is not a regular file`);
  if (me !== null && st.uid !== me) throw new CalError('skill_scope_denied', `${name} belongs to another user`);
  if (st.nlink !== 1) throw new CalError('skill_scope_denied', `${name} has more than one hard link; refusing to use it`);
  if ((st.mode & 0o077) !== 0) throw new CalError('skill_scope_denied', `${name} must not be accessible to group or others (mode 0600)`);
  return st;
}

const openFile = (path, flags, name) => {
  try { return openSync(path, flags | O_NOFOLLOW, 0o600); } catch (e) {
    if (e.code === 'ELOOP' || e.code === 'EMLINK') throw new CalError('skill_scope_denied', `${name} is a symbolic link; refusing to follow it`);
    if (e.code === 'ENOENT') return null;
    throw new CalError('skill_scope_denied', `cannot open ${name} (${e.code})`);
  }
};

const sleepMs = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

// The lock is a file created with O_EXCL that holds `pid:nonce`. It is released only if the file at the path is still the one this process created (same
// inode), so a lock taken over meanwhile is never removed by its old holder. A lock is taken over only when its holder is gone (no such process), when it is
// older than LOCK_HARD_STALE_MS, or when it has had no readable owner for LOCK_UNREADABLE_MS; the takeover is a rename to a unique name, which only one
// contender can win, followed by a check that the file moved is the one that was judged stale (if not, it is put back). A suspended or slow holder that is
// still alive keeps its lock; its writes are also re-checked on read (a fork of one use's chain is flagged, not trusted by file order).
function lockOwner(lock) {
  let fd = null;
  try {
    fd = openSync(lock, constants.O_RDONLY | O_NOFOLLOW);
    const b = Buffer.alloc(128); const n = readSync(fd, b, 0, 128, 0); const st = fstatSync(fd);
    const m = /^(\d{1,10}):([0-9a-f]{16})$/.exec(b.subarray(0, n).toString('utf8'));
    return { pid: m ? Number(m[1]) : null, text: m ? m[0] : null, age: Date.now() - st.mtimeMs, ino: st.ino };
  } catch { return null; } finally { if (fd !== null) try { closeSync(fd); } catch { /* closed */ } }
}
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; } };

function breakStale(lock) {
  const o = lockOwner(lock);
  if (!o) return; // gone already
  const stale = o.pid === null ? o.age > LOCK_UNREADABLE_MS : (!alive(o.pid) || o.age > LOCK_HARD_STALE_MS);
  if (!stale) return;
  const moved = `${lock}.stale.${randomBytes(6).toString('hex')}`;
  try { renameSync(lock, moved); } catch { return; } // another contender won the takeover
  const again = lockOwner(moved);
  if (!again || again.text !== o.text) { try { linkSync(moved, lock); } catch { /* a newer lock exists */ } } // we moved a different lock than the one judged stale: put it back
  try { unlinkSync(moved); } catch { /* gone */ }
}

export function withLock(dir, fn) {
  checkDir(dir, true);
  const lock = join(dir, '.lock');
  const t0 = Date.now();
  const mine = `${process.pid}:${randomBytes(8).toString('hex')}`;
  let fd = null;
  for (;;) {
    try { fd = openSync(lock, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | O_NOFOLLOW, 0o600); writeSync(fd, mine); break; } catch (e) {
      if (fd !== null) { try { closeSync(fd); } catch { /* closed */ } fd = null; try { unlinkSync(lock); } catch { /* gone */ } }
      if (e.code !== 'EEXIST') throw new CalError('skill_scope_denied', `cannot take the calibration lock (${e.code})`);
      breakStale(lock);
      if (Date.now() - t0 > LOCK_WAIT_MS) throw new CalError('skill_scope_denied', 'the calibration store is busy; try again');
      sleepMs(5);
    }
  }
  const held = fstatSync(fd);
  try { return fn(); } finally {
    try { closeSync(fd); } catch { /* closed */ }
    try { const now = lstatSync(lock); if (now.ino === held.ino && now.dev === held.dev) unlinkSync(lock); } catch { /* gone or replaced */ }
  }
}

// One line appended with a single write. A torn last line (a writer that died mid-line) gets a newline first, so the next record starts on its own line.
export function appendLine(dir, file, obj) {
  const line = `${JSON.stringify(obj)}\n`;
  const bytes = Buffer.byteLength(line);
  if (bytes > MAX_LINE) throw new CalError('skill_too_large', `a calibration record is larger than ${MAX_LINE} bytes`);
  const fd = openFile(join(dir, file), constants.O_RDWR | constants.O_APPEND | constants.O_CREAT, file);
  try {
    const st = checkFd(fd, file);
    if (st.size + bytes + 1 > MAX_FILE) throw new CalError('skill_too_large', `${file} is full (${MAX_FILE} bytes); run the compact command`);
    let prefix = '';
    if (st.size > 0) { const b = Buffer.alloc(1); readSync(fd, b, 0, 1, st.size - 1); if (b[0] !== 0x0a) prefix = '\n'; }
    const buf = Buffer.from(prefix + line);
    if (writeSync(fd, buf) !== buf.length) throw new CalError('skill_too_large', `a short write to ${file}`);
    fsyncSync(fd);
  } finally { closeSync(fd); }
}

// -> { rows: [parsed objects], corrupt: n } ; a missing file is empty. Never reads more than MAX_FILE bytes.
function readRows(dir, file) {
  if (!checkDir(dir, false)) return { rows: [], corrupt: 0 };
  const fd = openFile(join(dir, file), constants.O_RDONLY, file);
  if (fd === null) return { rows: [], corrupt: 0 };
  try {
    const st = checkFd(fd, file);
    if (st.size > MAX_FILE) throw new CalError('skill_too_large', `${file} is larger than ${MAX_FILE} bytes; refusing to read it`);
    const buf = Buffer.alloc(st.size);
    let off = 0;
    while (off < buf.length) { const r = readSync(fd, buf, off, buf.length - off, off); if (r === 0) break; off += r; }
    const rows = []; let corrupt = 0;
    for (const raw of buf.subarray(0, off).toString('utf8').split('\n')) {
      if (!raw) continue;
      try { const v = JSON.parse(raw); if (v && typeof v === 'object' && !Array.isArray(v)) rows.push(v); else corrupt += 1; } catch { corrupt += 1; }
    }
    return { rows, corrupt };
  } finally { closeSync(fd); }
}

// ---- validation -----------------------------------------------------------------------------------------------------------------------------------------
const fieldErrors = (list) => list.map((e) => ({ path: e.path, code: e.code }));
// The schema's time pattern accepts 2026-02-30 and 24:00:00; a real instant round-trips through Date.
export function validTime(t) {
  const m = /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)Z$/.exec(t);
  if (!m) return false;
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]));
  return !Number.isNaN(d.getTime()) && d.toISOString().startsWith(`${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6]}`);
}

// The rules the schema cannot say: a verified outcome carries evidence, an inferred outcome claims no result, the time is a real instant.
export function validateOutcome(doc) {
  if (!doc || typeof doc !== 'object' || Array.isArray(doc)) return [{ path: '$', code: 'skill_schema_type' }];
  const errs = fieldErrors(schemas.check('outcome', doc));
  if (!errs.length) {
    if (doc.tier === 'verified' && !doc.evidence_ref) errs.push({ path: '$.evidence_ref', code: 'skill_outcome_invalid' });
    if (doc.tier === 'inferred' && doc.result !== 'unknown') errs.push({ path: '$.result', code: 'skill_outcome_invalid' });
    if (!validTime(doc.reported_at)) errs.push({ path: '$.reported_at', code: 'skill_schema_format' });
  }
  return errs;
}

export function validateUse(doc) {
  if (!doc || typeof doc !== 'object' || Array.isArray(doc)) return [{ path: '$', code: 'skill_schema_type' }];
  const errs = fieldErrors(schemas.check('skill-use', doc));
  if (!errs.length) {
    if (!validTime(doc.issued_at) || !validTime(doc.expires_at)) errs.push({ path: '$.issued_at', code: 'skill_schema_format' });
    else { const span = Date.parse(doc.expires_at) - Date.parse(doc.issued_at); if (!(span > 0) || span > USE_DAYS * DAY_MS) errs.push({ path: '$.expires_at', code: 'skill_schema_limit' }); }
  }
  return errs;
}

// A tombstone is exactly { k, use_id, at }.
export const validateTombstone = (r) => !!r && typeof r === 'object' && !Array.isArray(r) && JSON.stringify(Object.keys(r).sort()) === '["at","k","use_id"]' && r.k === 'tombstone'
  && typeof r.use_id === 'string' && /^use_[0-9a-zA-Z]{4,40}$/.test(r.use_id) && typeof r.at === 'string' && validTime(r.at);
// An outcome row is exactly { k, doc } (no sibling field can carry text past the schema-checked document).
const validOutcomeRow = (r) => !!r && typeof r === 'object' && !Array.isArray(r) && JSON.stringify(Object.keys(r).sort()) === '["doc","k"]' && r.k === 'outcome' && validateOutcome(r.doc).length === 0;

export function validateTrackRecord(doc) { return fieldErrors(schemas.check('track-record', doc)); }

// ---- reading --------------------------------------------------------------------------------------------------------------------------------------------
// ONE function reads and judges the files, for reads and for compact, so both count the same lines. A line is unreadable (`corrupt`) when it is not JSON,
// not an object, fails its schema or wrapper, repeats an id already seen, or forks a chain (an outcome that does not supersede the use's current one while it
// has one). Retention is applied after, by the callers.
function scan(dir) {
  const u = readRows(dir, 'uses.jsonl');
  const o = readRows(dir, 'outcomes.jsonl');
  let corrupt = u.corrupt + o.corrupt; let dups = 0;
  const uses = new Map();
  for (const d of u.rows) {
    if (validateUse(d).length) corrupt += 1;
    else if (uses.has(d.use_id)) { corrupt += 1; dups += 1; } else uses.set(d.use_id, d);
  }
  const chains = new Map(); // use_id -> [outcome docs in file order, after the last tombstone]
  const deleted = new Map(); // use_id -> how many outcomes tombstones removed
  const tombstoned = new Set();
  const ids = new Set(); const order = []; // every accepted outcome doc, in file order
  for (const r of o.rows) {
    if (r.k === 'tombstone') {
      if (!validateTombstone(r)) { corrupt += 1; continue; }
      deleted.set(r.use_id, (deleted.get(r.use_id) || 0) + (chains.get(r.use_id) || []).length);
      chains.delete(r.use_id); tombstoned.add(r.use_id);
    } else if (validOutcomeRow(r)) {
      const d = r.doc;
      if (ids.has(d.outcome_id)) { corrupt += 1; dups += 1; continue; }
      const chain = chains.get(d.use_id) || [];
      if (chain.length && d.supersedes !== chain[chain.length - 1].outcome_id) { corrupt += 1; continue; } // a fork: not the correction of the current outcome
      ids.add(d.outcome_id); order.push(d); chain.push(d); chains.set(d.use_id, chain);
    } else corrupt += 1;
  }
  return { uses, chains, deleted, tombstoned, ids, order, corrupt, dups };
}

// The state at `now`: uses kept 365 days from issue, outcomes 365 days from report. Superseded outcomes stay in the file but only the current one counts.
function load(dir, now) {
  const sc = scan(dir);
  const cutoff = now - RECORD_DAYS * DAY_MS;
  const uses = new Map();
  for (const [id, d] of sc.uses) if (Date.parse(d.issued_at) > cutoff && d.principal_ref === LOCAL_PRINCIPAL) uses.set(id, d);
  const current = new Map(); const history = new Map(); const corrections = new Map();
  for (const [id, list] of sc.chains) {
    const kept = list.filter((d) => Date.parse(d.reported_at) > cutoff && uses.has(id));
    if (!kept.length) continue;
    history.set(id, kept); current.set(id, kept[kept.length - 1]);
  }
  for (const id of uses.keys()) { const c = Math.max(0, (history.get(id) || []).length - 1) + (sc.deleted.get(id) || 0); if (c) corrections.set(id, c); }
  return { uses, current, history, corrections, corrupt: sc.corrupt, ids: sc.ids, tombstoned: sc.tombstoned, allUses: sc.uses, allChains: sc.chains };
}

export const getUse = (dir, useId, now = Date.now()) => load(dir, now).uses.get(useId) || null;

// ---- writing --------------------------------------------------------------------------------------------------------------------------------------------
export function newUse({ use_id, skill, mode = 'debate_seat', host = { family: 'e3d-debate', model_family: 'unknown' }, task_class = 'unclassified', task_class_source = 'none',
  reminder_enabled = false, run_ref = null }, now = Date.now()) {
  return { schema_version: 'e3d.skill-use/v1', use_id, skill, mode, host, task_class, task_class_source, principal_ref: LOCAL_PRINCIPAL, reminder_enabled, run_ref,
    issued_at: iso(now), expires_at: iso(now + USE_DAYS * DAY_MS) };
}

const sameUse = (a, b) => JSON.stringify(a.skill) === JSON.stringify(b.skill) && a.task_class === b.task_class && a.mode === b.mode && a.host?.model_family === b.host.model_family
  && a.run_ref === b.run_ref && a.issued_at === b.issued_at;

// Records a use. Same use_id with the same content: no change. Same use_id with different content: skill_outcome_conflict (ids are never reused). A use_id
// that has outcomes or a deletion on file but no use row is refused too (a use never comes back under an id whose records still exist).
export function registerUse(dir, doc) {
  const errs = validateUse(doc);
  if (errs.length) throw new CalError('skill_schema_invalid', 'the use does not match the schema', { details: errs });
  return withLock(dir, () => {
    const sc = scan(dir);
    const prior = sc.uses.get(doc.use_id);
    if (prior) {
      if (sameUse(prior, doc)) return { status: 'unchanged' };
      throw new CalError('skill_outcome_conflict', 'that use_id is already recorded for a different use');
    }
    if (sc.chains.has(doc.use_id) || sc.tombstoned.has(doc.use_id)) throw new CalError('skill_outcome_conflict', 'that use_id still has records on file and cannot be registered again');
    appendLine(dir, 'uses.jsonl', doc);
    return { status: 'recorded' };
  });
}

// The path a receipt takes: the use is issued at the receipt's own time, refused if that is older than the use_id lifetime or ahead of the clock.
export function registerReceiptUse(dir, doc, now = Date.now()) {
  const errs = validateUse(doc);
  if (errs.length) throw new CalError('skill_schema_invalid', 'the use does not match the schema', { details: errs });
  if (Date.parse(doc.issued_at) > now + SKEW_MS) throw new CalError('skill_schema_invalid', 'the receipt is dated in the future');
  if (now > Date.parse(doc.expires_at)) throw new CalError('skill_use_expired', 'the receipt is older than 90 days, so its use_id can no longer be registered');
  return registerUse(dir, doc);
}

const sameReport = (a, b) => a.result === b.result && a.tier === b.tier && a.reported_by === b.reported_by && JSON.stringify(a.evidence_ref) === JSON.stringify(b.evidence_ref);

// Appends a complete Outcome document (what an adapter submits). Checks, in order: the document (skill_outcome_invalid), the use (skill_use_not_found,
// skill_use_expired), then supersession (skill_outcome_conflict). A document identical to the current one is accepted once and changes nothing.
export function appendOutcome(dir, doc, now = Date.now()) {
  const errs = validateOutcome(doc);
  if (errs.length) throw new CalError('skill_outcome_invalid', 'the outcome breaks a rule', { details: errs });
  if (Date.parse(doc.reported_at) > now + SKEW_MS) throw new CalError('skill_outcome_invalid', 'the outcome is dated in the future', { details: [{ path: '$.reported_at', code: 'skill_schema_value' }] });
  return withLock(dir, () => {
    const st = load(dir, now);
    const use = st.uses.get(doc.use_id);
    if (!use) throw new CalError('skill_use_not_found', 'no use with that id is recorded here');
    if (now > Date.parse(use.expires_at)) throw new CalError('skill_use_expired', `the use id expired on ${use.expires_at}`);
    if (st.ids.has(doc.outcome_id)) throw new CalError('skill_outcome_conflict', 'that outcome_id is already recorded');
    const cur = st.current.get(doc.use_id) || null;
    if (cur && (doc.supersedes === null || doc.supersedes === cur.outcome_id) && sameReport(cur, doc)) return { status: 'unchanged', outcome: cur };
    if (cur ? doc.supersedes !== cur.outcome_id : doc.supersedes !== null) throw new CalError('skill_outcome_conflict', cur ? `the use already has outcome ${cur.outcome_id}; a correction must name it in supersedes` : 'supersedes names an outcome this use does not have');
    appendLine(dir, 'outcomes.jsonl', { k: 'outcome', doc });
    return { status: 'recorded', outcome: doc, superseded: cur ? cur.outcome_id : null };
  });
}

// The command's way in: builds the document (fixed fields only, so no free text can arrive) and names the current outcome as the one it supersedes.
export function reportOutcome(dir, { use_id, result, tier = 'user_marked', reported_by = 'user', evidence_ref = null }, now = Date.now()) {
  for (let attempt = 0; ; attempt += 1) {
    const cur = load(dir, now).current.get(use_id) || null;
    const doc = { schema_version: 'e3d.outcome/v1', outcome_id: newOutcomeId(), use_id, result, tier, reported_by, evidence_ref, supersedes: cur ? cur.outcome_id : null, reported_at: iso(now) };
    try { return appendOutcome(dir, doc, now); } catch (e) {
      // another writer changed this use's current outcome between the read and the lock: look again (a few times), then say so
      if (!(e instanceof CalError) || e.code !== 'skill_outcome_conflict' || attempt >= 8) throw e;
    }
  }
}

// Records a deletion (a tombstone) of every outcome of one use; the derived record recomputes without them. Needs the use to exist.
export function deleteOutcome(dir, use_id, now = Date.now()) {
  if (typeof use_id !== 'string' || !/^use_[0-9a-zA-Z]{4,40}$/.test(use_id)) throw new CalError('skill_use_not_found', 'not a use id');
  return withLock(dir, () => {
    const st = load(dir, now);
    if (!st.uses.has(use_id)) throw new CalError('skill_use_not_found', 'no use with that id is recorded here');
    const had = (st.history.get(use_id) || []).length;
    if (!had) return { status: 'unchanged', removed: 0 };
    appendLine(dir, 'outcomes.jsonl', { k: 'tombstone', use_id, at: iso(now) });
    return { status: 'deleted', removed: had };
  });
}

function fsyncDir(dir) { try { const fd = openSync(dir, constants.O_RDONLY); try { fsyncSync(fd); } finally { closeSync(fd); } } catch { /* a filesystem that cannot fsync a directory */ } }

// Atomic rewrite: drops everything past retention, every deleted outcome, every tombstone it consumed, every unreadable and every duplicate line, and writes only
// validated rows ({k, doc} rebuilt from the checked document, never the raw line). Leftover temporary files of a crashed compaction are removed first. -> counts
export function compact(dir, now = Date.now()) {
  return withLock(dir, () => {
    for (const f of readdirSync(dir)) { if (/^\.(uses|outcomes)\.jsonl\.[0-9a-f]+\.tmp$/.test(f)) { try { if (lstatSync(join(dir, f)).isFile()) unlinkSync(join(dir, f)); } catch { /* gone */ } } }
    const cutoff = now - RECORD_DAYS * DAY_MS;
    const sc = scan(dir);
    const keepUses = [...sc.uses.values()].filter((d) => Date.parse(d.issued_at) > cutoff);
    const useIds = new Set(keepUses.map((d) => d.use_id));
    const live = new Set(); for (const list of sc.chains.values()) for (const d of list) live.add(d.outcome_id);
    const keepOut = sc.order.filter((d) => live.has(d.outcome_id) && useIds.has(d.use_id) && Date.parse(d.reported_at) > cutoff).map((doc) => ({ k: 'outcome', doc }));
    const write = (file, rows) => {
      const tmp = join(dir, `.${file}.${randomBytes(6).toString('hex')}.tmp`);
      const fd = openSync(tmp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | O_NOFOLLOW, 0o600);
      try { const body = rows.map((r) => `${JSON.stringify(r)}\n`).join(''); if (Buffer.byteLength(body) > MAX_FILE) throw new CalError('skill_too_large', `${file} would exceed ${MAX_FILE} bytes`); writeSync(fd, body); fsyncSync(fd); } catch (e) { closeSync(fd); try { unlinkSync(tmp); } catch { /* gone */ } throw e; }
      closeSync(fd);
      renameSync(tmp, join(dir, file));
      fsyncDir(dir);
    };
    // rewrite only a file that exists, so compacting an empty store creates nothing
    const exists = (f) => { try { return lstatSync(join(dir, f)).isFile(); } catch { return false; } };
    if (exists('uses.jsonl')) write('uses.jsonl', keepUses);
    if (exists('outcomes.jsonl')) write('outcomes.jsonl', keepOut);
    return { uses_dropped: sc.uses.size - keepUses.length, outcomes_dropped: sc.order.length - keepOut.length, unreadable_dropped: sc.corrupt, duplicates_dropped: sc.dups, uses_kept: keepUses.length, outcomes_kept: keepOut.length };
  });
}

// ---- derived records ------------------------------------------------------------------------------------------------------------------------------------
// sel: { skill (id), version, hash, task_class, mode, model_family } any may be omitted.
// -> { records, details (one per record: n_unknown, n_inferred, corrections), insufficient (with the same three), corrupt (lines ignored) }
export function trackRecords(dir, sel = {}, now = Date.now()) {
  const st = load(dir, now);
  let uses = [...st.uses.values()];
  if (sel.skill) uses = uses.filter((u) => u.skill.id === sel.skill);
  if (sel.version) uses = uses.filter((u) => u.skill.version === sel.version);
  if (sel.hash) uses = uses.filter((u) => u.skill.hash === sel.hash);
  if (sel.task_class) uses = uses.filter((u) => u.task_class === sel.task_class);
  if (sel.mode) uses = uses.filter((u) => u.mode === sel.mode);
  if (sel.model_family) uses = uses.filter((u) => u.host.model_family === sel.model_family);
  const records = []; const details = []; const insufficient = [];
  for (const group of strataOf(uses)) {
    const r = computeTrackRecord(group, st.current, now);
    const x = extrasFor(group, st.current, st.corrections);
    if (r.status === 'insufficient_evidence') insufficient.push({ subject: r.subject, stratum: r.stratum, n_uses: r.n_uses, n_resolved: r.n_resolved, ...x, min_resolved: MIN_RESOLVED, code: 'skill_record_insufficient' });
    else { records.push(r); details.push(x); }
  }
  return { records, details, insufficient, corrupt: st.corrupt };
}

// All skill ids that have uses here (for resolving a bare name).
export const skillIds = (dir, now = Date.now()) => [...new Set([...load(dir, now).uses.values()].map((u) => u.skill.id))].sort();
