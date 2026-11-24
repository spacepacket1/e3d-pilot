// The in-memory use-ticket ledger for calibration over MCP (plan-calibration-3-mcp.md, sections 3, 4 and 5; threat rows C-T10, C-T13).
// Pure: the clock and the random source are injected; no file, no network, no process state. Nothing is wired to bin/e3d-mcp yet (P3-1).
//
// What it holds: one ticket per `e3d_get_skill` fetch, { use_id, session_id, skill{id,version,definition_hash}, task_class, issued_at, expires_at }.
// It never goes to disk. "Session" means this process (subagents share the process). Every failed lookup returns the SAME code,
// `skill_use_not_found` (unknown, foreign session, other skill/version/hash, expired): no oracle for guessing ids.
//
// Limits (constants below, each can be overridden for tests):
//   ticket life 24 h; 64 outstanding tickets; 20 issues per 10 min; 30 write attempts per hour; 3 supersessions per use;
//   a decline or cancel pauses WRITES for 10 min; 5 refusals in a row do the same; reads are never blocked;
//   at most one elicitation pending per process; work on one use_id is serialised.
import { randomBytes } from 'node:crypto';

export const TICKET_MS = 24 * 3600 * 1000;
export const MAX_OUTSTANDING = 64;
export const ISSUE_PER_WINDOW = 20;
export const ISSUE_WINDOW_MS = 10 * 60 * 1000;
export const WRITES_PER_WINDOW = 30;
export const WRITE_WINDOW_MS = 3600 * 1000;
export const MAX_SUPERSESSIONS = 3;
export const PAUSE_MS = 10 * 60 * 1000;
export const REFUSALS_IN_A_ROW = 5;
export const NOT_FOUND = 'skill_use_not_found';

const USE_ID = /^use_[0-9a-f]{32}$/;
const SLUG = /^[a-z0-9][a-z0-9._-]{1,38}[a-z0-9]$/; // 3-40 characters, as the task_class slug rule

// rng(n) -> n random bytes (Buffer or Uint8Array). The default is crypto.randomBytes.
export function createLedger({ now = Date.now, rng = randomBytes, sessionId, limits = {} } = {}) {
  const L = { ticketMs: TICKET_MS, maxOutstanding: MAX_OUTSTANDING, issuePerWindow: ISSUE_PER_WINDOW, issueWindowMs: ISSUE_WINDOW_MS,
    writesPerWindow: WRITES_PER_WINDOW, writeWindowMs: WRITE_WINDOW_MS, maxSupersessions: MAX_SUPERSESSIONS, pauseMs: PAUSE_MS, refusalsInARow: REFUSALS_IN_A_ROW, ...limits };
  const hex = (n) => Buffer.from(rng(n)).toString('hex');
  const session_id = sessionId ?? hex(8);
  const tickets = new Map();
  let issues = [];       // timestamps of recent issues
  let writes = [];       // timestamps of recent write attempts
  let pausedUntil = 0;
  let refusalStreak = 0;
  let pending = null;    // the use_id of the one elicitation in flight
  const chains = new Map(); // use_id -> tail promise

  const purge = () => { const t = now(); for (const [k, v] of tickets) if (v.expires_at <= t) tickets.delete(k); };
  const retryAfter = (until) => Math.max(1, Math.ceil((until - now()) / 1000));
  const slide = (arr, windowMs) => { const t = now(); return arr.filter((x) => x > t - windowMs); };
  const err = (code, extra = {}) => ({ ok: false, code, ...extra });

  const matches = (a, b) => !!a && !!b && a.id === b.id && a.version === b.version && a.definition_hash === b.definition_hash;

  return {
    session_id,

    // Issue a ticket for a skill definition actually served. -> { ok, use_id, expires_in_hours } | { ok:false, code, retry_after_s }
    issue({ skill, task_class = null } = {}) {
      if (!skill || typeof skill.id !== 'string' || typeof skill.version !== 'string' || typeof skill.definition_hash !== 'string' || !skill.id || !skill.version || !skill.definition_hash) return err('invalid_ticket');
      if (task_class !== null && !(typeof task_class === 'string' && SLUG.test(task_class))) return err('invalid_task_class');
      purge();
      issues = slide(issues, L.issueWindowMs);
      if (issues.length >= L.issuePerWindow) return err('rate_limited', { retry_after_s: retryAfter(issues[0] + L.issueWindowMs) });
      if (tickets.size >= L.maxOutstanding) return err('ticket_cap', { retry_after_s: retryAfter(Math.min(...[...tickets.values()].map((v) => v.expires_at))) });
      let use_id;
      do { use_id = `use_${hex(16)}`; } while (tickets.has(use_id));
      const t = now();
      issues.push(t);
      tickets.set(use_id, { use_id, session_id, skill: { id: skill.id, version: skill.version, definition_hash: skill.definition_hash }, task_class, issued_at: t, expires_at: t + L.ticketMs, persisted: false, supersessions: 0 });
      return { ok: true, use_id, expires_in_hours: Math.round(L.ticketMs / 3600000) };
    },

    // Look a ticket up. `expect` may carry session_id and skill{id,version,definition_hash}; any mismatch is the same answer as an unknown id.
    // -> { ok, ticket } (a copy) | { ok:false, code:'skill_use_not_found' }
    lookup(use_id, expect = {}) {
      purge();
      const miss = err(NOT_FOUND);
      if (typeof use_id !== 'string' || !USE_ID.test(use_id)) return miss;
      const e = tickets.get(use_id);
      if (!e) return miss;
      if (e.session_id !== (expect.session_id ?? session_id)) return miss;
      if (expect.skill && !matches(e.skill, expect.skill)) return miss;
      return { ok: true, ticket: { ...e, skill: { ...e.skill } } };
    },

    // After the use row is persisted. The ticket stays so a later outcome in this session can find it; the caller must not echo the id again.
    markPersisted(use_id) { const r = this.lookup(use_id); if (!r.ok) return r; tickets.get(use_id).persisted = true; return { ok: true }; },
    isPersisted(use_id) { const r = this.lookup(use_id); return r.ok && r.ticket.persisted; },

    // One more result for the same use (a supersession); capped.
    noteSupersession(use_id) {
      const r = this.lookup(use_id); if (!r.ok) return r;
      const e = tickets.get(use_id);
      if (e.supersessions >= L.maxSupersessions) return err('supersession_cap');
      e.supersessions += 1; return { ok: true, count: e.supersessions };
    },

    // Reads are never blocked by a pause, a refusal streak or the write rate.
    admitRead() { return { ok: true }; },

    // A write attempt (report_use, report_outcome, delete_outcome). -> { ok } | { ok:false, code:'rate_limited', retry_after_s, reason }
    admitWrite() {
      const t = now();
      if (t < pausedUntil) return err('rate_limited', { reason: 'paused', retry_after_s: retryAfter(pausedUntil) });
      writes = slide(writes, L.writeWindowMs);
      if (writes.length >= L.writesPerWindow) return err('rate_limited', { reason: 'write_rate', retry_after_s: retryAfter(writes[0] + L.writeWindowMs) });
      writes.push(t);
      return { ok: true };
    },

    // The user declined or cancelled: writes pause for 10 minutes.
    noteDecline() { pausedUntil = now() + L.pauseMs; refusalStreak = 0; },
    // Any other refusal (bad id, wrong scope, ...): N in a row pause writes as well.
    noteRefusal() { refusalStreak += 1; if (refusalStreak >= L.refusalsInARow) { pausedUntil = now() + L.pauseMs; refusalStreak = 0; } },
    // A confirmed write resets the streak (it does not lift a pause).
    noteAccepted() { refusalStreak = 0; },
    writesPausedUntil() { return pausedUntil > now() ? pausedUntil : 0; },

    // At most one elicitation pending per process. -> { ok, done() } | { ok:false, code:'elicitation_pending' }
    beginElicitation(use_id) {
      if (pending !== null) return err('elicitation_pending');
      pending = use_id;
      let released = false;
      return { ok: true, done() { if (!released) { released = true; pending = null; } } };
    },
    elicitationPending() { return pending !== null; },

    // Run fn after every earlier call for the same use_id has settled. Other ids do not wait.
    serialize(use_id, fn) {
      const prev = chains.get(use_id) || Promise.resolve();
      const run = prev.catch(() => {}).then(fn);
      const tail = run.catch(() => {});
      chains.set(use_id, tail);
      tail.then(() => { if (chains.get(use_id) === tail) chains.delete(use_id); });
      return run;
    },

    outstanding() { purge(); return tickets.size; },
  };
}
