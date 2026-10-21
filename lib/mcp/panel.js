// Per-account model panel, hosted mode (pilot.e3d.ai docs/panel-config-spec.md section 4.3). Zero dependencies.
//
//   validatePanelConfig(env)   E3D_MCP_ALLOWED_PROVIDERS (the hosted allowlist) and E3D_MCP_PANEL, checked at startup
//   createPanelClient(...)     billing's POST /panel/v1/resolve {principal} -> the account's panel, per debate
//   accountPanel / degrade / explicitPanel / requireFamilies
//                              the decisions: never add a vendor the account did not choose, degrade an account panel by
//                              dropping unavailable vendors (in order), refuse an explicit list that is not a subset
//
// The allowlist is enforced for every debate whenever it is set (independent of E3D_MCP_PANEL): the default, an account's
// panel, a run-listener list and a client's own `providers`. MCP sampling voices are never in it, so hosted mode refuses
// them. With E3D_MCP_PANEL=1 every hosted debate asks billing for the account's panel BEFORE anything is reserved: no cache
// on the spend path (one loopback call per debate, single-flight per principal for concurrent calls), and any answer but a
// well-formed 200 refuses the debate; nothing ever falls back to a default. Logs carry provider ids and counts only, never
// a principal, a token or a question.
import { PROVIDER_FAMILY } from './voices.js';
import { NAME_RE } from './util.js';
import { validateConfig as validateAuthConfig } from './external-auth.js';

export const PANEL_VERSION = '1';
export const PANEL_ROUTE = '/panel/v1/resolve';
const MAX_RESPONSE = 16 * 1024;
const SOURCES = new Set(['account', 'default']);
const FAMILY_RE = /^[a-z][a-z0-9-]{0,31}$/;
const list = (v) => (v || '').split(',').map((s) => s.trim()).filter(Boolean);
export const familyOf = (id) => PROVIDER_FAMILY[id] ?? null;
export const familiesOf = (ids) => [...new Set(ids.map(familyOf).filter(Boolean))];

// Startup checks. Returns { ok, errors, allowed: [ids] | null, panel: boolean }; messages never echo a value but ids.
export function validatePanelConfig(env = process.env) {
  const errors = [];
  let allowed = null;
  const raw = env.E3D_MCP_ALLOWED_PROVIDERS;
  if (raw !== undefined && raw.trim() !== '') {
    allowed = list(raw);
    const bad = allowed.filter((p) => !NAME_RE.test(p) || p.length > 64);
    if (bad.length) errors.push('E3D_MCP_ALLOWED_PROVIDERS must be a comma-separated list of provider names');
    else {
      if (new Set(allowed).size !== allowed.length) errors.push('E3D_MCP_ALLOWED_PROVIDERS lists a provider twice');
      const noFamily = allowed.filter((p) => !familyOf(p));
      if (noFamily.length) errors.push(`E3D_MCP_ALLOWED_PROVIDERS names a provider with no vendor family: ${noFamily.join(', ')}`);
      const outside = list(env.E3D_MCP_PROVIDERS).filter((p) => !allowed.includes(p));
      if (outside.length) errors.push(`E3D_MCP_PROVIDERS must be inside E3D_MCP_ALLOWED_PROVIDERS (not allowed: ${outside.join(', ')})`);
    }
  }
  const flag = env.E3D_MCP_PANEL;
  if (flag !== undefined && !['', '0', '1'].includes(flag)) errors.push('E3D_MCP_PANEL must be 1 or unset');
  const panel = flag === '1';
  if (panel && !allowed) errors.push('E3D_MCP_PANEL=1 needs E3D_MCP_ALLOWED_PROVIDERS');
  if (panel && !env.E3D_MCP_AUTH_URL) errors.push('E3D_MCP_PANEL=1 needs the external auth hook (E3D_MCP_AUTH_URL)');
  return { ok: errors.length === 0, errors, allowed: allowed ? Object.freeze(allowed) : null, panel };
}

// A resolve answer, strictly: { ok: true, source, providers: [{ id, family }] } with at most 16 distinct providers.
function validAnswer(b) {
  if (!b || typeof b !== 'object' || Array.isArray(b) || b.ok !== true || !SOURCES.has(b.source) || !Array.isArray(b.providers) || b.providers.length > 16) return null;
  const out = [];
  for (const p of b.providers) {
    if (!p || typeof p !== 'object' || typeof p.id !== 'string' || p.id.length > 64 || !NAME_RE.test(p.id) || typeof p.family !== 'string' || !FAMILY_RE.test(p.family)) return null;
    if (out.some((x) => x.id === p.id)) return null;
    out.push({ id: p.id, family: p.family });
  }
  return { source: b.source, providers: out };
}

// The resolve client: the same base URL and service token as the external auth hook. resolve(principal) never throws:
// { ok: true, source, providers } or { ok: false, why } (why: timeout, connection, http_<status>, redirect, too_large,
// garbled). Concurrent calls for one principal share one request; nothing is kept once it answers.
export function createPanelClient({ env = process.env, url, serviceToken, fetchImpl = globalThis.fetch, timeoutMs = 3000, log = () => {} } = {}) {
  const checked = validateAuthConfig(env, { url: url ?? env.E3D_MCP_AUTH_URL, serviceToken, fetchImpl });
  if (!checked.ok) throw new Error(`panel resolve: ${checked.errors.join('; ')}`);
  const { base } = checked.config;
  const secret = checked.config.serviceToken;
  const inflight = new Map();
  const counters = { calls: 0, shared: 0, refused: 0 };

  async function exchange(principal) {
    counters.calls++;
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), timeoutMs);
    timer.unref?.();
    try {
      let res;
      try {
        res = await fetchImpl(`${base}${PANEL_ROUTE}`, {
          method: 'POST', redirect: 'manual', signal: ac.signal, body: JSON.stringify({ principal }),
          headers: { authorization: `Bearer ${secret}`, 'x-e3d-panel-version': PANEL_VERSION, accept: 'application/json', 'content-type': 'application/json' },
        });
      } catch { return { ok: false, why: ac.signal.aborted ? 'timeout' : 'connection' }; }
      if (res.type === 'opaqueredirect' || (res.status >= 300 && res.status < 400)) { res.body?.cancel().catch(() => {}); return { ok: false, why: 'redirect' }; }
      if (res.status !== 200) { res.body?.cancel().catch(() => {}); return { ok: false, why: `http_${res.status}` }; }
      let text;
      try {
        const buf = Buffer.from(await res.arrayBuffer());
        if (buf.length > MAX_RESPONSE) return { ok: false, why: 'too_large' };
        text = buf.toString('utf8');
      } catch { return { ok: false, why: ac.signal.aborted ? 'timeout' : 'connection' }; }
      let body;
      try { body = JSON.parse(text); } catch { return { ok: false, why: 'garbled' }; }
      const v = validAnswer(body);
      return v ? { ok: true, ...v } : { ok: false, why: 'garbled' };
    } finally { clearTimeout(timer); }
  }

  async function resolve(principal) {
    if (typeof principal !== 'string' || principal === '') return { ok: false, why: 'no_principal' };
    const pending = inflight.get(principal);
    if (pending) { counters.shared++; return pending; }
    const p = exchange(principal).then((r) => {
      if (!r.ok) { counters.refused++; log(`panel: resolve failed (${r.why}); the debate is refused`); }
      return r;
    }).finally(() => inflight.delete(principal));
    inflight.set(principal, p);
    return p;
  }

  return { resolve, stats: () => ({ ...counters, inflight: inflight.size }) };
}

const refuse = (code, message) => ({ error: `error: ${code}: ${message}`, code });

// Billing's family for every resolved provider must equal ours; otherwise nothing runs (an operator alert).
export function checkFamilies(resolved, log = () => {}) {
  const off = resolved.providers.filter((p) => familyOf(p.id) !== p.family);
  if (!off.length) return null;
  log(`ALERT panel: billing and e3d-mcp disagree on vendor families (${off.map((p) => `${p.id}: billing ${p.family}, here ${familyOf(p.id) ?? 'none'}`).join('; ')}); debates for this panel are refused until the two maps agree`);
  return refuse('panel_config_mismatch', 'the server is misconfigured for your debate panel; nothing was charged. Please try again later.');
}

// Fewer than two vendor families is not a debate (spec 4.3 item 7). Returns an error or null.
export function requireFamilies(ids) {
  return familiesOf(ids).length >= 2 && ids.every((p) => familyOf(p)) ? null
    : refuse('panel_unavailable', `a debate needs at least two vendors from different companies (got: ${ids.join(', ') || 'none'}). Change your panel in Settings > Debate panel.`);
}

// An account panel (or a run-listener list, which is one): drop what is not allowed here or not available, in order; refuse
// when fewer than two vendors or one family is left, or when it is longer than `max` (refused, never truncated).
// Returns { providers, dropped } or { error, code }.
export function degrade(ids, { allowed, isAvailable, max }) {
  const kept = ids.filter((p) => (!allowed || allowed.includes(p)) && isAvailable(p));
  const dropped = ids.filter((p) => !kept.includes(p));
  if (kept.length < 2 || familiesOf(kept).length < 2) {
    return refuse('panel_unavailable', `your panel needs at least two available vendors from different companies${dropped.length ? `; ${dropped.join(', ')} ${dropped.length === 1 ? 'is' : 'are'} unavailable` : ''}. Change it in Settings > Debate panel. Nothing was charged.`);
  }
  if (kept.length > max) return refuse('panel_too_large', `at most ${max} vendors per debate; your panel has ${kept.length}. Nothing was charged.`);
  return { providers: kept, dropped };
}

// A client's own `providers`: strict. Every one allowed here, every one on the account's panel (when there is one), at
// most `max`, every one available. It may narrow the panel; it can never add a vendor. Returns { providers } or { error }.
export function explicitPanel(ids, { allowed, accountIds, isAvailable, max }) {
  const notAllowed = allowed ? ids.filter((p) => !allowed.includes(p)) : [];
  if (notAllowed.length) return refuse('provider_not_allowed', `provider(s) not offered on this server: ${notAllowed.join(', ')} (call e3d_list_providers). Nothing was charged.`);
  const outside = accountIds ? ids.filter((p) => !accountIds.includes(p)) : [];
  if (outside.length) return refuse('not_on_panel', `provider(s) not on your account's debate panel: ${outside.join(', ')}. Name a subset of your panel (${accountIds.join(', ')}), or change it in Settings > Debate panel. Nothing was charged.`);
  if (ids.length > max) return refuse('panel_too_large', `at most ${max} providers per debate. Nothing was charged.`);
  const unavailable = ids.filter((p) => !isAvailable(p));
  if (unavailable.length) return refuse('provider_unavailable', `provider(s) not available here: ${unavailable.join(', ')}. Nothing was charged.`);
  return { providers: ids };
}
