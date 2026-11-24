// The internal run listener: the billing service's web "Ask" page runs a debate it has already reserved. Zero dependencies.
//
//   POST   /internal/runs              {reservation_id, debate_id, question, providers?, rounds?, max_words?, web_search?}
//   GET    /internal/runs/{debate_id}  status, progress, and the result once done
//   DELETE /internal/runs/{debate_id}  cancel: finalized as outcome "error" without a result (or, when the verdict was already written and the run had an observer, ok with its stored result and cancelled: true)
//   POST   /internal/chats             {request_id, provider, max_tokens, messages, max_searches?}: one message answered by one model, with the conversation so far as context
//                                      (chat_v1; docs/chat-run.md). Service token only, stateless and not metered here, like recaps; the caller going away cancels the call.
//   POST   /internal/recaps            {request_id, debate_id, provider, max_tokens, rounds}: the recap of a finished debate (recap_v1; docs/debate-recap.md).
//                                      Service token only; stateless and not metered here: the billing service reserves and settles from the usage it returns.
//
// skills_v1 (docs/skills.md "The hosted listener"): skill_attachments, skills_principal, skill_bytes and observer, only with E3D_MCP_SKILLS_RUN=1 and its switches.
//
// Enabled with E3D_MCP_RUN_PORT and E3D_MCP_RUN_TOKEN (32+ characters), hook mode only. It binds to 127.0.0.1 only and is a
// separate listener: the public /mcp listener never serves these paths. Every request carries the service token
// (Authorization: Bearer); GET and DELETE also need the run's own token (X-E3D-Run-Token), returned by POST. Both are compared
// in constant time; failed authentication is rate-limited (E3D_MCP_RUN_AUTH_FAILS_PER_MIN, after which every request is
// refused for up to a minute without being checked). A new run needs finalize, fetch and authorize-run advertised.
//
// The owner is whatever authorize-run says, never the request body; nothing runs unless it authorizes. The run is metered
// from that reservation (no new reserve), executed by the async runner (lib/mcp/runs.js, same slots, limits and recovery)
// and finalized once with source "web". A repeated POST with the same fields returns the same run and run token (answered from
// the request's key before any planning, so a provider that became unavailable never turns a retry into a refusal); changed
// fields, or either id reused with another counterpart, are a conflict. Answers say whether the run was accepted:
//   202 accepted | 200 existing | 400 invalid | 403 not_authorized | 409 conflict | 429 busy        (definitive)
//   503 unavailable / not_ready (nothing was accepted; retry later) | 401 bad service or run token | 429 rate_limited
// Logs carry the method, the route, the status and ids; never a body, a question or a token.
import http from 'node:http';
import { createHash } from 'node:crypto';
import { canonicalJson } from './external-auth.js';
import { questionFitsContract } from './metering.js';
import { DEBATE_ID_RE, safeEqual } from './runs.js';
import { NAME_RE } from './util.js';
import { PER_TOKEN_CAPABILITY, SEARCH_CAPABILITY, EXPERTS_CAPABILITY, SKILLS_CAPABILITY, validatePerTokenFields } from './pricing.js';
import { RECAP_CAPABILITY } from './recap-runner.js';
import { CHAT_CAPABILITY, CHAT_SEARCH_CAPABILITY, CHAT_SKILLS_CAPABILITY } from './chat-runner.js';

export const RUN_TOKEN_MIN = 32;
export const RUN_FEATURES = Object.freeze(['finalize', 'fetch', 'authorize-run']);
const HOST = '127.0.0.1';
const MAX_BODY = 64 * 1024;
const RECAP_BODY_FIELDS = new Set(['request_id', 'debate_id', 'provider', 'max_tokens', 'rounds']);
const CHAT_BODY_FIELDS = new Set(['request_id', 'provider', 'max_tokens', 'messages', 'max_searches', 'skills', 'lens_bytes']);
const CHAT_MAX_BODY = 256 * 1024;
const RID_RE = /^[A-Za-z0-9_.:-]{1,128}$/;
const FIELDS = new Set(['reservation_id', 'debate_id', 'question', 'providers', 'rounds', 'max_words', 'web_search', 'max_tokens', 'answer_bytes', 'max_searches', 'cite_bytes', 'jev', 'investigate']);
const TOKEN_RE = /^[!-~]+$/;
// experts_v1 (docs/specs/experts-phase2b1-hosted-lenses-spec.md section 2.1): an expert is a catalogue id and the content hash the user was shown.
const EXPERT_FIELDS = ['experts', 'lens_bytes'];
const EXPERT_ID_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;
const EXPERT_HASH_RE = /^sha256:[0-9a-f]{64}$/;
export const EXPERTS_LIMITS = Object.freeze({ min: 2, max: 16, lensBytes: [1, 4096] });
// skills_v1 (docs/skills/phase3/plan-3c-hosted-user-skills.md section 3, "Listener fields"): hosted user skills as seats and as the observer.
const SKILL_FIELDS = ['skill_attachments', 'skills_principal', 'skill_bytes', 'observer'];
const SKILLS_PRINCIPAL_RE = /^u_[a-z0-9]{6,36}$/;
const OBSERVER_PROVIDER_RE = /^(?:(?:anthropic|openai|gemini|xai)-api|or-[a-z0-9][a-z0-9-]{0,27})$/; // an API adapter with an output-limit setting (bin/e3d-debate pt_var_of); never claude
export const SKILLS_LIMITS = Object.freeze({ attachments: [1, 4], definitionBytes: 48 * 1024, skillBytes: [1, 32768], observerTokens: [1, 4096], observerInputBytes: [1, 256000], body: 256 * 1024, definitionDepth: 16 });

// Startup checks. Returns { enabled, ok, errors, config: { port, token, failsPerMin } } (the token only in config).
export function validateRunServerConfig(env = process.env) {
  const enabled = Boolean(env.E3D_MCP_RUN_PORT || env.E3D_MCP_RUN_TOKEN);
  const errors = [];
  const config = { port: null, token: null, failsPerMin: 20 };
  if (!enabled) return { enabled, ok: true, errors, config };
  if (!env.E3D_MCP_AUTH_URL) errors.push('the internal run listener (E3D_MCP_RUN_PORT) needs the external auth hook (E3D_MCP_AUTH_URL)');
  const port = String(env.E3D_MCP_RUN_PORT ?? '');
  if (!/^\d{1,5}$/.test(port) || Number(port) > 65535) errors.push('E3D_MCP_RUN_PORT must be a port number (0 to 65535)');
  else config.port = Number(port);
  const token = env.E3D_MCP_RUN_TOKEN ?? '';
  if (token.length < RUN_TOKEN_MIN || token.length > 512 || !TOKEN_RE.test(token)) errors.push(`E3D_MCP_RUN_TOKEN must be ${RUN_TOKEN_MIN} to 512 printable characters without spaces`);
  else config.token = token;
  const fails = env.E3D_MCP_RUN_AUTH_FAILS_PER_MIN;
  if (fails != null && fails !== '') {
    if (!/^\d{1,6}$/.test(fails) || Number(fails) < 1) errors.push('E3D_MCP_RUN_AUTH_FAILS_PER_MIN must be a whole number from 1 to 999999');
    else config.failsPerMin = Number(fails);
  }
  return { enabled, ok: errors.length === 0, errors, config };
}

// The strict shape of a run request. Returns { fields, key, perToken } (key: sha256 of the canonical fields) or { error }.
// pricing: { mode, customer } (token pricing, lib/mcp/pricing.js). rounds, max_words, max_tokens and answer_bytes are sent together
// by a per_token billing service and honoured exactly (never clamped, never defaulted); without them nothing here changes. max_searches and
// cite_bytes (web search priced inside per-token pricing) come together, with those four, only to a server that advertised per_token_search_v1
// (pricing.search); anything else is refused 400 invalid before anything runs.
// experts (pricing.experts, only a listener with E3D_MCP_EXPERTS_RUN=1): `experts` [{id, hash}] (2 to 16, distinct ids) and `lens_bytes` (1 to 4096)
// come together and only with the per-token fields; without the capability they are refused 400 invalid like any field this listener does not know.
// skills (pricing.skills, only a listener with skills_v1: { seats, observer }): `skill_attachments`, `skills_principal`, `skill_bytes` and (with an observer attachment) `observer`,
// all together and only with the per-token fields; without the capability they are refused 400 invalid like any field this listener does not know.
export function validateRunRequest(b, pricing = { mode: null, customer: null, search: false, experts: false, skills: false }) {
  if (!b || typeof b !== 'object' || Array.isArray(b)) return { error: 'the body must be a JSON object' };
  for (const k of Object.keys(b)) if (!FIELDS.has(k) && !(pricing.experts && EXPERT_FIELDS.includes(k)) && !(pricing.skills && SKILL_FIELDS.includes(k))) return { error: `unknown field ${JSON.stringify(k.slice(0, 40))}` };
  if (typeof b.reservation_id !== 'string' || !RID_RE.test(b.reservation_id)) return { error: 'reservation_id is missing or malformed' };
  if (typeof b.debate_id !== 'string' || !DEBATE_ID_RE.test(b.debate_id)) return { error: 'debate_id must be dbt_ followed by 24 lowercase hex characters' };
  if (!questionFitsContract(b.question) || !b.question.trim()) return { error: 'the question must be 1 to 8000 characters without control characters' };
  if (b.providers !== undefined && (!Array.isArray(b.providers) || b.providers.length < 1 || b.providers.length > 16 || b.providers.some((p) => typeof p !== 'string' || p.length > 64 || !NAME_RE.test(p)))) return { error: 'providers must be an array of provider names' };
  if (b.rounds !== undefined && (!Number.isSafeInteger(b.rounds) || b.rounds < 1 || b.rounds > 100)) return { error: 'rounds must be a whole number' };
  if (b.max_words !== undefined && (!Number.isSafeInteger(b.max_words) || b.max_words < 1 || b.max_words > 100000)) return { error: 'max_words must be a whole number' };
  if (b.web_search !== undefined && typeof b.web_search !== 'boolean') return { error: 'web_search must be a boolean' };
  if (b.jev !== undefined && b.jev !== true) return { error: 'jev must be true when sent' };
  if (b.investigate !== undefined && b.investigate !== true) return { error: 'investigate must be true when sent' };
  const tokens = validatePerTokenFields(b, pricing);
  if (tokens.error) return { error: tokens.error };
  if (tokens.max_searches && b.web_search === false) return { error: 'web_search false contradicts max_searches' };
  let experts = null;
  if (pricing.experts && EXPERT_FIELDS.some((k) => b[k] !== undefined)) {
    const bad = expertsError(b, tokens);
    if (bad) return { error: bad };
    experts = { list: b.experts.map((e) => ({ id: e.id, hash: e.hash })), lens_bytes: b.lens_bytes };
  }
  let skills = null;
  if (pricing.skills && SKILL_FIELDS.some((k) => b[k] !== undefined)) {
    const bad = skillsError(b, tokens, pricing.skills);
    if (bad) return { error: bad };
    skills = { attachments: b.skill_attachments.map((x) => ({ hook: x.hook, ...(x.target !== undefined ? { target: x.target } : {}), definition: x.definition })), principal: b.skills_principal, skill_bytes: b.skill_bytes,
      observer: b.observer === undefined ? null : { provider: b.observer.provider, max_tokens: b.observer.max_tokens, input_bytes: b.observer.input_bytes } };
  }
  const fields = {};
  for (const k of FIELDS) if (b[k] !== undefined) fields[k] = b[k];
  if (experts) for (const k of EXPERT_FIELDS) fields[k] = b[k];
  if (skills) for (const k of SKILL_FIELDS) if (b[k] !== undefined) fields[k] = b[k];
  let key;
  try { key = createHash('sha256').update(canonicalJson(fields)).digest('hex'); } catch { return { error: 'the request is nested too deeply' }; }   // never a 503 that a caller would retry
  return { fields, key, perToken: tokens.absent ? null : tokens, experts, skills };
}

// Same checks for the skills fields. null when they are well formed, else the reason (a static message: never a value from the request, never a definition).
// true when v is nested deeper than max (objects and arrays), checked iteratively; a cycle cannot come from JSON.parse but is counted as too deep as well
function tooDeep(v, max) {
  const stack = [[v, 1]];
  let visited = 0;
  while (stack.length) {
    const [x, d] = stack.pop();
    if (x === null || typeof x !== 'object') continue;
    if (d > max || ++visited > 100000) return true;
    for (const k of Object.keys(x)) stack.push([x[k], d + 1]);
  }
  return false;
}

function skillsError(b, tokens, caps) {
  if (SKILL_FIELDS.slice(0, 3).some((k) => b[k] === undefined)) return 'skill_attachments, skills_principal and skill_bytes are sent together';
  if (tokens.absent) return 'skills need the token fields (rounds, max_words, max_tokens, answer_bytes)';
  if (b.experts !== undefined || b.lens_bytes !== undefined) return 'experts and skills cannot be sent in the same request';
  const a = b.skill_attachments;
  if (!Array.isArray(a) || a.length < SKILLS_LIMITS.attachments[0] || a.length > SKILLS_LIMITS.attachments[1]) return 'skill_attachments must be 1 to 4 objects';
  let observers = 0;
  const targets = new Set();
  for (const x of a) {
    if (!x || typeof x !== 'object' || Array.isArray(x) || Object.keys(x).some((k) => k !== 'hook' && k !== 'target' && k !== 'definition')) return 'each attachment must be an object with only a hook, a target and a definition';
    if (x.hook !== 'seat' && x.hook !== 'observer') return 'an attachment hook must be seat or observer';
    if (x.hook === 'seat' ? !caps.seats : !caps.observer) return `${x.hook} skill attachments are not enabled on this server`;
    if (x.hook === 'seat') {
      if (typeof x.target !== 'string' || x.target.length > 64 || !NAME_RE.test(x.target)) return 'a seat attachment needs a target provider name';
      if (!Array.isArray(b.providers)) return 'seat attachments need the providers of the request';
      if (b.providers.length < 2) return 'a run with seat attachments needs at least 2 providers (one skill is enough: the other seats run plain)';
      if (!b.providers.includes(x.target)) return 'a seat target must be one of the providers of the request';
      if (targets.has(x.target)) return 'two seat attachments name the same target';
      targets.add(x.target);
    } else {
      if (x.target !== undefined) return 'an observer attachment has no target';
      if (++observers > 1) return 'at most one observer attachment';
    }
    if (x.definition === null || typeof x.definition !== 'object' || Array.isArray(x.definition)) return 'an attachment definition must be an object';
    // the raw size is bounded before anything reads the definition any deeper (the engine's intake checks it fully)
    // depth first, with a loop (no recursion): a definition nested thousands of levels deep is a 400 here, never a stack overflow further on (the engine's intake allows 8)
    if (tooDeep(x.definition, SKILLS_LIMITS.definitionDepth)) return 'an attachment definition is nested too deeply';
    let size;
    try { size = Buffer.byteLength(JSON.stringify(x.definition), 'utf8'); } catch { return 'an attachment definition is nested too deeply'; }
    if (size > SKILLS_LIMITS.definitionBytes) return `an attachment definition is larger than ${SKILLS_LIMITS.definitionBytes} bytes`;
  }
  if (typeof b.skills_principal !== 'string' || !SKILLS_PRINCIPAL_RE.test(b.skills_principal)) return 'skills_principal is malformed';
  const [lo, hi] = SKILLS_LIMITS.skillBytes;
  if (!Number.isSafeInteger(b.skill_bytes) || b.skill_bytes < lo || b.skill_bytes > hi) return `skill_bytes must be a whole number from ${lo} to ${hi}`;
  const o = b.observer;
  if (observers === 0) return o === undefined ? null : 'observer limits are sent only with an observer attachment';
  if (o === undefined) return 'an observer attachment needs the observer limits';
  if (o === null || typeof o !== 'object' || Array.isArray(o) || Object.keys(o).some((k) => k !== 'provider' && k !== 'max_tokens' && k !== 'input_bytes')) return 'observer must be an object with only provider, max_tokens and input_bytes';
  if (typeof o.provider !== 'string' || !OBSERVER_PROVIDER_RE.test(o.provider)) return 'observer.provider must be an API adapter with an output-limit setting';
  const [tl, th] = SKILLS_LIMITS.observerTokens; const [il, ih] = SKILLS_LIMITS.observerInputBytes;
  if (!Number.isSafeInteger(o.max_tokens) || o.max_tokens < tl || o.max_tokens > th) return `observer.max_tokens must be a whole number from ${tl} to ${th}`;
  if (!Number.isSafeInteger(o.input_bytes) || o.input_bytes < il || o.input_bytes > ih) return `observer.input_bytes must be a whole number from ${il} to ${ih}`;
  return null;
}

// null when the expert fields are well formed, else the reason (never a value from the request).
function expertsError(b, tokens) {
  if (b.experts === undefined || b.lens_bytes === undefined) return 'experts and lens_bytes are sent together';
  if (tokens.absent) return 'experts need the token fields (rounds, max_words, max_tokens, answer_bytes)';
  const { min, max, lensBytes } = EXPERTS_LIMITS;
  if (!Array.isArray(b.experts) || b.experts.length < min || b.experts.length > max) return `experts must be ${min} to ${max} objects with an id and a hash`;
  for (const e of b.experts) {
    if (!e || typeof e !== 'object' || Array.isArray(e) || Object.keys(e).some((k) => k !== 'id' && k !== 'hash')) return 'each expert must be an object with only an id and a hash';
    if (typeof e.id !== 'string' || e.id.length > 64 || !EXPERT_ID_RE.test(e.id)) return 'an expert id is malformed';
    if (typeof e.hash !== 'string' || !EXPERT_HASH_RE.test(e.hash)) return 'an expert hash must be sha256: followed by 64 lowercase hex characters';
  }
  if (new Set(b.experts.map((e) => e.id)).size !== b.experts.length) return 'an expert is listed twice';
  if (!Number.isSafeInteger(b.lens_bytes) || b.lens_bytes < lensBytes[0] || b.lens_bytes > lensBytes[1]) return `lens_bytes must be a whole number from ${lensBytes[0]} to ${lensBytes[1]}`;
  return null;
}

// runs: the run store (accept/get/cancel); external: the auth client (features, authorizeRun); plan(fields) -> { plan, worst }
// or { error } (the debate plan with the customer maxima applied).
export async function startRunServer({ port, token, runs, external, plan, log = () => {}, failsPerMin = 20, now = Date.now, pricing = { mode: null, customer: null, search: false, experts: false, skills: false }, recap = null, chat = null }) {
  if (typeof token !== 'string' || token.length < RUN_TOKEN_MIN) throw new Error(`refusing to start the internal run listener: E3D_MCP_RUN_TOKEN must be at least ${RUN_TOKEN_MIN} characters`);
  const fails = [];
  const recentFails = () => { const t = now(); while (fails.length && t - fails[0] >= 60000) fails.shift(); return fails.length; };
  const counters = { requests: 0, auth_failures: 0, rate_limited: 0 };

  const send = (res, status, body, headers = {}) => {
    res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', ...headers });
    res.end(JSON.stringify(body));
  };
  const reject = (res, status, code, message, extra = {}) => send(res, status, { ok: false, accepted: false, code, ...(message ? { message } : {}), ...extra });
  const unauthorized = (res) => {
    counters.auth_failures++; fails.push(now()); if (fails.length > 4096) fails.splice(0, fails.length - 4096);
    return reject(res, 401, 'unauthorized', null);
  };
  async function readJson(req, maxBody = MAX_BODY) {
    if (!/^application\/json\b/i.test(req.headers['content-type'] ?? '')) return { error: 'content-type must be application/json' };
    const declared = Number(req.headers['content-length']);
    if (Number.isFinite(declared) && declared > maxBody) return { tooLarge: true };
    const chunks = []; let size = 0;
    for await (const c of req) { size += c.length; if (size > maxBody) return { tooLarge: true }; chunks.push(c); }
    try { return { body: JSON.parse(Buffer.concat(chunks).toString('utf8')) }; } catch { return { error: 'the body is not valid JSON' }; }
  }
  const enabled = () => RUN_FEATURES.every((f) => external?.hasFeature?.(f));
  // per_token_v1 is advertised in the health answer (the 400 an empty run request gets), only with E3D_MCP_PRICING=per_token
  // per_token_search_v1 next to it, only when this server can run the searches it is told to (lib/mcp/pricing.js searchCapable)
  const capList = [...(pricing.mode === 'per_token' ? [PER_TOKEN_CAPABILITY, ...(pricing.search ? [SEARCH_CAPABILITY] : []), ...(pricing.experts ? [EXPERTS_CAPABILITY] : []), ...(pricing.skills ? [SKILLS_CAPABILITY] : [])] : []), ...(recap ? [RECAP_CAPABILITY] : []), ...(chat ? [CHAT_CAPABILITY, ...(chat.searchAvailable?.() ? [CHAT_SEARCH_CAPABILITY] : []), ...(chat.skillsAvailable?.() ? [CHAT_SKILLS_CAPABILITY] : [])] : [])];
  const capabilities = capList.length ? { capabilities: capList } : {};

  // POST /internal/chats: validated here, run by lib/mcp/chat-runner.js. The service token is the only credential. The call is cancelled when the caller closes the connection.
  async function createChat(req, res) {
    if (!chat) return reject(res, 404, 'not_found', null);
    const got = await readJson(req, CHAT_MAX_BODY);
    if (got.tooLarge) return reject(res, 413, 'invalid', 'the body is too large');
    if (got.error) return reject(res, 400, 'invalid', got.error, capabilities);
    const b = got.body;
    if (b === null || typeof b !== 'object' || Array.isArray(b) || Object.keys(b).some((k) => !CHAT_BODY_FIELDS.has(k))) return reject(res, 400, 'invalid', 'the chat request has a missing or unknown field');
    const ac = new AbortController();
    res.on('close', () => { if (!res.writableEnded) ac.abort(); });
    const r = await chat.run({ requestId: b.request_id, provider: b.provider, maxTokens: b.max_tokens, messages: b.messages, ...(b.max_searches !== undefined ? { maxSearches: b.max_searches } : {}), ...(b.skills !== undefined ? { skills: b.skills } : {}), ...(b.lens_bytes !== undefined ? { lensBytes: b.lens_bytes } : {}), signal: ac.signal });
    if (r.ok) return send(res, 200, { ok: true, answer: r.answer, usage: r.usage });
    if (r.code === 'cancelled') return undefined; // the caller is gone
    if (r.code === 'invalid') return reject(res, 400, 'invalid', 'the chat request is invalid');
    if (r.code === 'not_allowed') return reject(res, 403, 'not_allowed', 'this provider is not allowed to answer chats');
    if (r.code === 'search_unavailable') return reject(res, 409, 'search_unavailable', 'web search is not available for this provider on this server; nothing was called');
    if (r.code === 'skills_unavailable') return reject(res, 409, 'skills_unavailable', 'skills are not available on this server; nothing was called');
    // the call was made and answered with nothing: a definitive answer, with what it used so the service can settle it
    if (r.code === 'unusable') return send(res, 200, { ok: false, code: 'unusable', usage: r.usage });
    return reject(res, 503, 'unavailable', 'temporarily unavailable; retry later', { retry: true, ...(r.usage ? { usage: r.usage } : {}) });
  }

  // POST /internal/recaps: validated here, run by lib/mcp/recap-runner.js. The service token is the only credential: there is no run and no run token.
  async function createRecap(req, res) {
    if (!recap) return reject(res, 404, 'not_found', null);
    const got = await readJson(req);
    if (got.tooLarge) return reject(res, 413, 'invalid', 'the body is too large');
    if (got.error) return reject(res, 400, 'invalid', got.error, capabilities);
    const b = got.body;
    if (b === null || typeof b !== 'object' || Array.isArray(b) || Object.keys(b).some((k) => !RECAP_BODY_FIELDS.has(k))) return reject(res, 400, 'invalid', 'the recap request has a missing or unknown field');
    const r = await recap.run({ requestId: b.request_id, debateId: b.debate_id, provider: b.provider, maxTokens: b.max_tokens, rounds: b.rounds });
    if (r.ok) return send(res, 200, { ok: true, recap: r.recap, usage: r.usage });
    if (r.code === 'invalid') return reject(res, 400, 'invalid', 'the recap request is invalid');
    if (r.code === 'not_allowed') return reject(res, 403, 'not_allowed', 'this provider is not allowed to write recaps');
    // the call was made but nothing in the answer could be checked: a definitive answer, with what it used so the service can settle it
    if (r.code === 'unusable') return send(res, 200, { ok: false, code: 'unusable', usage: r.usage });
    return reject(res, 503, 'unavailable', 'temporarily unavailable; retry later', { retry: true, ...(r.usage ? { usage: r.usage } : {}) });
  }

  async function create(req, res) {
    // after a restart the features are unknown until the service has answered; ask it now (throttled) rather than wait for a client call
    if (!enabled()) await external?.warmFeatures?.();
    if (!enabled()) return reject(res, 503, 'not_ready', 'the billing service does not advertise finalize, fetch and authorize-run', { retry: true });
    const got = await readJson(req, pricing.skills ? SKILLS_LIMITS.body : MAX_BODY);
    if (got.tooLarge) return reject(res, 413, 'invalid', 'the body is too large');
    if (got.error) return reject(res, 400, 'invalid', got.error, capabilities);
    const v = validateRunRequest(got.body, pricing);
    if (v.error) return reject(res, 400, 'invalid', v.error, capabilities);
    // A run this listener already holds is answered from its key BEFORE any planning: an identical retry after a provider
    // became unavailable is `200 existing`, never a `400` that would make the service zero-charge a run that exists.
    const ids = { reservation_id: v.fields.reservation_id, debate_id: v.fields.debate_id, key: v.key };
    const prior = runs.known ? await runs.known(ids) : null;
    let r = prior;
    if (!r) {
      const p = await plan(v.fields, { perToken: v.perToken, experts: v.experts, skills: v.skills });
      if (p.error) return reject(res, 400, 'invalid', String(p.error).replace(/^error:\s*/, '').slice(0, 300));
      r = await runs.accept({ ...ids, plan: p.plan, worst: p.worst, authorize: (args) => external.authorizeRun(args) });
    }
    if (r.ok) return send(res, r.existing ? 200 : 202, { ok: true, accepted: true, existing: r.existing, debate_id: r.debate_id, status: r.status, run_token: r.run_token });
    switch (r.kind) {
      case 'conflict': return reject(res, 409, 'conflict', 'a run with this debate_id or reservation_id already exists with other fields');
      case 'invalid': return reject(res, 400, 'invalid', 'the run request is invalid');
      case 'busy': return reject(res, 429, 'busy', 'too many debates are queued or running; retry later');
      case 'caps': return reject(res, 429, 'busy', 'the server cannot store more debates right now; retry later');
      case 'refused': return r.code === 'conflict' ? reject(res, 409, 'conflict', 'the reservation is bound to another debate')
        : r.code === 'invalid' ? reject(res, 400, 'invalid', 'the billing service refused the run request')
          : reject(res, 403, 'not_authorized', 'the billing service did not authorize this run', { reason: r.code });
      case 'begin': return r.rsv?.kind === 'local' ? reject(res, 429, 'busy', 'the daily budget for this account is used up')
        : r.rsv?.kind === 'invalid' ? reject(res, 400, 'invalid', 'the run request is invalid')
          : reject(res, 503, 'unavailable', 'temporarily unavailable; retry later', { retry: true });
      default: return reject(res, 503, 'unavailable', 'temporarily unavailable; retry later', { retry: true });
    }
  }

  const server = http.createServer(async (req, res) => {
    counters.requests++;
    const started = now();
    const path = (req.url ?? '').split('?')[0];
    const route = path === '/internal/runs' || path === '/internal/recaps' || path === '/internal/chats' ? path : /^\/internal\/runs\/dbt_[0-9a-f]{24}$/.test(path) ? path : '-';
    res.on('finish', () => log(`run-server: ${req.method} ${route} ${res.statusCode} ${now() - started}ms`));
    try {
      if (recentFails() >= failsPerMin) { counters.rate_limited++; return reject(res, 429, 'rate_limited', 'too many failed authentications; retry later', { retry: true }); }
      // a browser can reach loopback; it can never pass these checks or read an answer
      if (req.headers.origin || !/^(127\.0\.0\.1|localhost)(:\d+)?$/.test(req.headers.host ?? '')) return reject(res, 403, 'forbidden', null);
      const bearer = /^Bearer\s+(\S+)$/i.exec(req.headers.authorization ?? '')?.[1] ?? '';
      if (!safeEqual(bearer, token)) return unauthorized(res);
      if (path === '/internal/runs') return req.method === 'POST' ? await create(req, res) : reject(res, 405, 'method_not_allowed', null);
      if (path === '/internal/chats') return req.method === 'POST' ? await createChat(req, res) : reject(res, 405, 'method_not_allowed', null);
      if (path === '/internal/recaps') return req.method === 'POST' ? await createRecap(req, res) : reject(res, 405, 'method_not_allowed', null);
      const m = /^\/internal\/runs\/([^/]+)$/.exec(path);
      if (!m || !['GET', 'DELETE'].includes(req.method)) return reject(res, 404, 'not_found', null);
      const runToken = req.headers['x-e3d-run-token'];
      // an unknown id and a wrong run token look the same
      const r = req.method === 'GET' ? await runs.get(m[1], typeof runToken === 'string' ? runToken : '') : await runs.cancel(m[1], typeof runToken === 'string' ? runToken : '');
      if (!r) return unauthorized(res);
      return send(res, 200, { ok: true, run: r.run });
    } catch (e) {
      log(`run-server: ERROR ${req.method} ${route} (${e.code ?? e.message})`);
      if (!res.headersSent) reject(res, 503, 'unavailable', null, { retry: true });
    }
  });
  server.requestTimeout = 30000;
  server.headersTimeout = 10000;
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, HOST, () => { server.off('error', reject); resolve(); }); });
  const bound = server.address();
  log(`run-server: listening on ${bound.address}:${bound.port} (internal runs, loopback only)`);
  return {
    port: bound.port, host: bound.address, stats: () => ({ ...counters }),
    close: () => new Promise((r) => { server.close(() => r()); server.closeAllConnections?.(); }),
  };
}
