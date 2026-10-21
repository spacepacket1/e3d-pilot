// Token pricing, hosted mode (per_token_v1; docs/token-pricing.md, billing's docs/token-pricing-interface.md). Zero dependencies.
//
//   validatePricingConfig(env, ...)  E3D_MCP_PRICING (unset | per_token), checked at startup
//   PER_TOKEN_CAPABILITY             the capability the run listener advertises, only with E3D_MCP_PRICING=per_token
//   validatePerTokenFields(...)      the four run fields billing adds (rounds, max_words, max_tokens, answer_bytes): all or none,
//                                    honoured exactly or refused, never clamped or defaulted
//   createPricingClient(...)         POST /pricing/v1/quote (before a connector reserve) and POST /usage/v1/report (before finalize)
//   readUsageRows(file)              the usage.json bin/e3d-debate writes
//
// Nothing here changes the hook protocol (docs/external-auth/*, CONTRACT-VERSION): the quote and the usage report are versioned
// side channels, like the panel resolve, and a body without the new fields is handled exactly as before.
import { readFile } from 'node:fs/promises';
import { validateConfig as validateAuthConfig } from './external-auth.js';
import { NAME_RE } from './util.js';

export const PER_TOKEN_CAPABILITY = 'per_token_v1';
export const PRICING_VERSION = '1';
export const USAGE_VERSION = '1';
export const QUOTE_ROUTE = '/pricing/v1/quote';
export const USAGE_ROUTE = '/usage/v1/report';
// The only providers a per-token debate may use: the four API adapters (CLI and sampling voices have no rate).
export const PRICED_PROVIDERS = Object.freeze(['anthropic-api', 'openai-api', 'gemini-api', 'xai-api']);
// Ceilings the interface allows (billing's run client validates the same ranges).
export const FIELD_LIMITS = Object.freeze({ rounds: [1, 10], max_words: [1, 10000], max_tokens: [1, 200000], answer_bytes: [1, 3200000] });
export const PER_TOKEN_FIELDS = Object.freeze(['rounds', 'max_words', 'max_tokens', 'answer_bytes']);
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isInt = (v, [lo, hi]) => Number.isSafeInteger(v) && v >= lo && v <= hi;

// E3D_MCP_PRICING: unset (today's behaviour) or per_token. per_token needs the hosted hook and the customer limits stated
// explicitly (they must equal billing's PILOT_TOKEN_MAX_ROUNDS and PILOT_TOKEN_MAX_WORDS, and a default would hide a mismatch).
export function validatePricingConfig(env = process.env, { http = true, hook = Boolean(env.E3D_MCP_AUTH_URL) } = {}) {
  const raw = env.E3D_MCP_PRICING;
  const errors = [];
  if (raw === undefined || raw === '') return { ok: true, errors, mode: null };
  if (raw !== 'per_token') return { ok: false, errors: ['E3D_MCP_PRICING must be unset or per_token'], mode: null };
  if (!http || !hook) errors.push('E3D_MCP_PRICING=per_token is only supported in hosted mode (--http) with the external auth hook (E3D_MCP_AUTH_URL)');
  if (!env.E3D_MCP_CUSTOMER_LIMITS) errors.push('E3D_MCP_PRICING=per_token needs E3D_MCP_CUSTOMER_LIMITS (rounds and max_words equal to billing\'s PILOT_TOKEN_MAX_ROUNDS and PILOT_TOKEN_MAX_WORDS)');
  return { ok: errors.length === 0, errors, mode: 'per_token' };
}

// The four fields of a run request. Returns { absent: true } (max_tokens and answer_bytes not sent: today's behaviour), or { error }, or
// { rounds, max_words, max_tokens, answer_bytes } validated. mode: the listener's pricing mode (null: it never advertised
// per_token_v1, so it cannot honour the fields and refuses them). customer: { rounds, max_words } maxima (E3D_MCP_CUSTOMER_LIMITS).
export function validatePerTokenFields(body, { mode, customer }) {
  // rounds and max_words are older optional fields (clamped to the customer maxima as before); the per-token mode is signalled by the
  // new ones, max_tokens and answer_bytes, and then all four must be sent
  if (body.max_tokens === undefined && body.answer_bytes === undefined) return { absent: true };
  if (mode !== 'per_token') return { error: 'token pricing is not enabled on this server' };
  const missing = PER_TOKEN_FIELDS.filter((k) => body[k] === undefined);
  if (missing.length) return { error: `rounds, max_words, max_tokens and answer_bytes are sent together (missing ${missing.join(', ')})` };
  if (!isInt(body.rounds, FIELD_LIMITS.rounds)) return { error: 'rounds must be a whole number from 1 to 10' };
  if (!isInt(body.max_words, FIELD_LIMITS.max_words)) return { error: 'max_words must be a whole number from 1 to 10000' };
  // never clamped: a quote above what this server may run is refused, so the price paid is the run that happens
  if (customer && body.rounds > customer.rounds) return { error: `rounds ${body.rounds} is above this server's limit of ${customer.rounds}` };
  if (customer && body.max_words > customer.max_words) return { error: `max_words ${body.max_words} is above this server's limit of ${customer.max_words}` };
  for (const k of ['max_tokens', 'answer_bytes']) {
    const m = body[k];
    if (!isObj(m) || Object.keys(m).length < 1 || Object.keys(m).length > 16) return { error: `${k} must be an object with 1 to 16 providers` };
    for (const [p, n] of Object.entries(m)) {
      if (!NAME_RE.test(p) || p.length > 64) return { error: `${k} has an invalid provider name` };
      if (!isInt(n, FIELD_LIMITS[k])) return { error: `${k}.${p} must be a whole number from ${FIELD_LIMITS[k][0]} to ${FIELD_LIMITS[k][1]}` };
    }
  }
  const a = Object.keys(body.max_tokens).sort().join(',');
  const b = Object.keys(body.answer_bytes).sort().join(',');
  if (a !== b) return { error: 'max_tokens and answer_bytes must name the same providers' };
  return { rounds: body.rounds, max_words: body.max_words, max_tokens: { ...body.max_tokens }, answer_bytes: { ...body.answer_bytes } };
}

// The limits a plan must carry, from the validated fields and the plan's providers: every provider that can be called (the
// panel after degrade, the synthesizer among them) needs both limits, and must be an API provider this server can price.
// xAI reasoning tokens are counted but not capped by max_tokens, so xai-api is not offered unless the operator accepted that
// (E3D_MCP_PER_TOKEN_ALLOW_XAI=1; billing clamps what it charges, the vendor invoice may still be higher).
export function pricedError(providers, { env = process.env } = {}) {
  const need = [...new Set(providers)];
  const notPriced = need.filter((p) => !PRICED_PROVIDERS.includes(p));
  if (notPriced.length) return `${notPriced.join(', ')} cannot be priced per token (API providers only)`;
  if (need.includes('xai-api') && env.E3D_MCP_PER_TOKEN_ALLOW_XAI !== '1') return 'xai-api cannot be offered per token: its reasoning tokens are not capped by max_tokens (set E3D_MCP_PER_TOKEN_ALLOW_XAI=1 to accept that)';
  return null;
}

export function limitsForPlan(fields, providers, { env = process.env } = {}) {
  const need = [...new Set(providers)];
  const bad = pricedError(need, { env });
  if (bad) return { error: bad };
  const missing = need.filter((p) => fields.max_tokens[p] === undefined || fields.answer_bytes[p] === undefined);
  if (missing.length) return { error: `no token limits for ${missing.join(', ')}` };
  return {
    maxTokens: Object.fromEntries(need.map((p) => [p, fields.max_tokens[p]])),
    answerBytes: Object.fromEntries(need.map((p) => [p, fields.answer_bytes[p]])),
  };
}

// The environment e3d-debate reads for a plan's limits (bin/e3d-debate, lib/debate/token-pricing.mjs).
export const debateEnvFor = (limits) => (limits ? { E3D_DEBATE_MAX_TOKENS: JSON.stringify(limits.maxTokens), E3D_DEBATE_ANSWER_BYTES_MAX: JSON.stringify(limits.answerBytes) } : {});

const ROW_SOURCES = new Set(['vendor', 'bytes']);
const MODEL_RE = /^[!-~]{1,128}$/;
const KEY_RE = /^(r\d{1,3}:[a-z0-9][a-z0-9_-]{0,63}|synth)$/;
// usage.json: an array of rows. Returns the rows that are well-formed (a row the billing service would refuse is dropped here
// and logged by the caller; an unreadable file is no rows). Never throws.
export async function readUsageRows(file) {
  let rows;
  try { rows = JSON.parse(await readFile(file, 'utf8')); } catch { return { rows: [], dropped: 0, present: false }; }
  if (!Array.isArray(rows)) return { rows: [], dropped: 0, present: true };
  const seen = new Set();
  const good = [];
  for (const r of rows) {
    const ok = isObj(r) && typeof r.key === 'string' && KEY_RE.test(r.key) && !seen.has(r.key) && typeof r.provider === 'string' && NAME_RE.test(r.provider)
      && typeof r.model === 'string' && MODEL_RE.test(r.model) && Number.isSafeInteger(r.input_tokens) && r.input_tokens >= 0 && r.input_tokens <= 1e9
      && Number.isSafeInteger(r.output_tokens) && r.output_tokens >= 0 && r.output_tokens <= 1e9 && ROW_SOURCES.has(r.source);
    if (!ok) continue;
    seen.add(r.key);
    good.push({ key: r.key, provider: r.provider, model: r.model, input_tokens: r.input_tokens, output_tokens: r.output_tokens, source: r.source });
  }
  return { rows: good, dropped: rows.length - good.length, present: true };
}

// The clients for billing's two side channels (same base URL and service token as the hook). Neither throws: quote answers
// { ok: true, ...answer } or { ok: false, code, ...} (a definitive refusal) or { ok: false, retry: true, why }; report answers
// { ok: true, replay } or { ok: false, code, why? } (400 and 409 are definitive: the caller still finalizes) or { ok: false, why }
// after its retries (5xx, 429 and transport failures are retried with the same body).
export function createPricingClient({ env = process.env, url, serviceToken, fetchImpl = globalThis.fetch, log = () => {}, timeoutMs = 5000,
  reportAttempts = 6, sleep = (ms) => new Promise((r) => setTimeout(r, ms)) } = {}) {
  const checked = validateAuthConfig(env, { url: url ?? env.E3D_MCP_AUTH_URL, serviceToken, fetchImpl });
  if (!checked.ok) throw new Error(`token pricing: ${checked.errors.join('; ')}`);
  const { base } = checked.config;
  const secret = checked.config.serviceToken;
  const counters = { quotes: 0, reports: 0, report_retries: 0 };

  async function exchange(route, versionHeader, body) {
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), timeoutMs);
    timer.unref?.();
    try {
      let res;
      try {
        res = await fetchImpl(`${base}${route}`, {
          method: 'POST', redirect: 'manual', signal: ac.signal, body: JSON.stringify(body),
          headers: { authorization: `Bearer ${secret}`, [versionHeader]: '1', accept: 'application/json', 'content-type': 'application/json' },
        });
      } catch { return { failure: ac.signal.aborted ? 'timeout' : 'connection' }; }
      if (res.type === 'opaqueredirect' || (res.status >= 300 && res.status < 400)) { res.body?.cancel().catch(() => {}); return { failure: 'redirect' }; }
      let parsed = null;
      try {
        const buf = Buffer.from(await res.arrayBuffer());
        if (buf.length > 64 * 1024) return { failure: 'too_large' };
        parsed = JSON.parse(buf.toString('utf8'));
      } catch { parsed = null; }
      return { status: res.status, body: isObj(parsed) ? parsed : null };
    } finally { clearTimeout(timer); }
  }

  // The connector quote, before the reserve. body: the fields of the interface's section 2.
  async function quote(body) {
    counters.quotes++;
    const r = await exchange(QUOTE_ROUTE, 'x-e3d-pricing-version', body);
    if (r.failure) { log(`pricing: quote failed (${r.failure})`); return { ok: false, retry: true, why: r.failure }; }
    const b = r.body;
    if (r.status === 200 && b?.ok === true && Number.isSafeInteger(b.credits) && Number.isSafeInteger(b.max_credits) && isObj(b.max_tokens) && isObj(b.answer_bytes) && typeof b.rate_version === 'string') {
      return { ok: true, credits: b.credits, max_credits: b.max_credits, rate_version: b.rate_version, max_tokens: b.max_tokens, answer_bytes: b.answer_bytes };
    }
    if (b?.ok === false && typeof b.code === 'string' && r.status >= 400 && r.status < 500 && r.status !== 429) {
      return { ok: false, code: b.code, ...(Number.isSafeInteger(b.credits) ? { credits: b.credits } : {}), ...(Number.isSafeInteger(b.max_credits) ? { max_credits: b.max_credits } : {}), status: r.status };
    }
    log(`pricing: quote answered HTTP ${r.status}`);
    return { ok: false, retry: true, why: `http_${r.status}`, status: r.status };
  }

  async function report(body) {
    counters.reports++;
    let last = { ok: false, why: 'not_sent' };
    let delay = 250;
    for (let attempt = 0; attempt < reportAttempts; attempt++) {
      if (attempt) { counters.report_retries++; await sleep(delay); delay = Math.min(delay * 2, 4000); }
      const r = await exchange(USAGE_ROUTE, 'x-e3d-usage-version', body);
      if (r.failure) { last = { ok: false, why: r.failure }; continue; }
      const b = r.body;
      if (r.status === 200 && b?.ok === true) return { ok: true, replay: b.replay === true };
      if (r.status >= 500 || r.status === 429) { last = { ok: false, why: `http_${r.status}` }; continue; }
      // 400 and 409 (and 401, a configuration error) will not improve: the caller logs it and still finalizes
      return { ok: false, definitive: true, status: r.status, code: typeof b?.code === 'string' ? b.code.slice(0, 40) : `http_${r.status}`, ...(typeof b?.why === 'string' ? { why: b.why.slice(0, 40) } : {}) };
    }
    return last;
  }

  return { quote, report, stats: () => ({ ...counters }) };
}
