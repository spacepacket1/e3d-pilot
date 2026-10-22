#!/usr/bin/env node
// Token pricing support for bin/e3d-debate (per_token_v1; docs/token-pricing.md). Zero dependencies. Used by bin/e3d-debate as a
// command and by lib/mcp/pricing.js as a module.
//
// The per-token limits reach a debate through two environment variables, both JSON objects keyed by provider id:
//   E3D_DEBATE_MAX_TOKENS         { "<provider>": n }  the vendor output limit of every call of that provider (per-token mode)
//   E3D_DEBATE_ANSWER_BYTES_MAX   { "<provider>": n }  the most UTF-8 bytes of a provider's answer inserted into a later prompt
// Both unset: today's behaviour exactly. E3D_DEBATE_MAX_TOKENS switches a debate to per-token mode (API providers only, no
// retry of a call that may have reached the vendor, no second opinion call, usage.json written; web search only as below).
// Web search inside per-token pricing (per_token_search_v1, docs/token-pricing.md) adds two more, set together or not at all, and only
// with E3D_DEBATE_MAX_TOKENS:
//   E3D_DEBATE_MAX_SEARCHES       { "<provider>": k }  the searching providers and the per-call search cap each was quoted (1..10)
//   E3D_DEBATE_CITE_BYTES_MAX     n                    the most UTF-8 bytes of one answer's citation list inserted into a later prompt
// A provider not in the map never searches; the synthesizer never searches. Both unset: search is off in a per-token debate.
//
// Commands (bin/e3d-debate):
//   config <synthesizer> <provider>...   -> JSON { perToken, maxTokens, answerBytes[, maxSearches, citeBytes] } from the environment; exit 1 with a message when invalid
//   truncate <max-bytes>                 stdin text -> stdout text cut to at most <max-bytes> UTF-8 bytes on a character boundary
//   row <key> <provider> <prompt-file> <out-file> <stderr-file> <exit-status> <max-tokens> [none|search]
//                                        -> one JSON usage row, or nothing when the call never reached the vendor; the last argument
//                                           (per-token search) adds the `searches` field: none = no search tool was offered, search = it was
import { readFileSync, realpathSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export const API_PROVIDERS = Object.freeze(['anthropic-api', 'openai-api', 'gemini-api', 'xai-api']);
export const MAX_TOKENS_ENV = Object.freeze({ 'anthropic-api': 'ANTHROPIC_API_MAX_TOKENS', 'openai-api': 'OPENAI_API_MAX_TOKENS', 'gemini-api': 'GEMINI_API_MAX_TOKENS', 'xai-api': 'XAI_API_MAX_TOKENS' });
const NAME_RE = /^[a-z0-9][a-z0-9_-]{0,63}$/;
const MODEL_RE = /^[!-~]{1,128}$/;
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isInt = (v, lo, hi) => Number.isSafeInteger(v) && v >= lo && v <= hi;
export const LIMITS = Object.freeze({ maxTokens: 200000, answerBytes: 3200000, maxSearches: 10, citeBytes: 20000 });

// A { provider: n } map. Returns { value } or { error }.
export function parseLimitMap(raw, name, hi) {
  let v;
  try { v = JSON.parse(raw); } catch { return { error: `${name} must be a JSON object` }; }
  if (!isObj(v) || Object.keys(v).length < 1 || Object.keys(v).length > 16) return { error: `${name} must be an object with 1 to 16 providers` };
  for (const [p, n] of Object.entries(v)) {
    if (!NAME_RE.test(p)) return { error: `${name} has an invalid provider name` };
    if (!isInt(n, 1, hi)) return { error: `${name}.${p} must be a whole number from 1 to ${hi}` };
  }
  return { value: v };
}

// The effective per-debate limits from the environment, for the providers that will be called (the synthesizer included).
// panel: the providers that answer the rounds (the synthesizer may be one of them, or only the synthesizer); default: all of providers.
export function limitsFromEnv(env, providers, panel = providers) {
  const out = { perToken: false, maxTokens: null, answerBytes: null };
  const need = [...new Set(providers)];
  if (env.E3D_DEBATE_MAX_TOKENS !== undefined && env.E3D_DEBATE_MAX_TOKENS !== '') {
    const m = parseLimitMap(env.E3D_DEBATE_MAX_TOKENS, 'E3D_DEBATE_MAX_TOKENS', LIMITS.maxTokens);
    if (m.error) return { error: m.error };
    const notApi = need.filter((p) => !API_PROVIDERS.includes(p));
    if (notApi.length) return { error: `per-token pricing prices API providers only (not ${notApi.join(', ')})` };
    const missing = need.filter((p) => m.value[p] === undefined);
    if (missing.length) return { error: `E3D_DEBATE_MAX_TOKENS has no limit for ${missing.join(', ')}` };
    out.perToken = true; out.maxTokens = m.value;
  }
  if (env.E3D_DEBATE_ANSWER_BYTES_MAX !== undefined && env.E3D_DEBATE_ANSWER_BYTES_MAX !== '') {
    const a = parseLimitMap(env.E3D_DEBATE_ANSWER_BYTES_MAX, 'E3D_DEBATE_ANSWER_BYTES_MAX', LIMITS.answerBytes);
    if (a.error) return { error: a.error };
    const missing = need.filter((p) => a.value[p] === undefined);
    if (missing.length) return { error: `E3D_DEBATE_ANSWER_BYTES_MAX has no limit for ${missing.join(', ')}` };
    out.answerBytes = a.value;
  }
  const search = searchFromEnv(env, panel, out.perToken);
  if (search.error) return { error: search.error };
  if (search.maxSearches) { out.maxSearches = search.maxSearches; out.citeBytes = search.citeBytes; }
  return out;
}

// E3D_DEBATE_MAX_SEARCHES and E3D_DEBATE_CITE_BYTES_MAX: both or neither (a half-set pair is refused, never completed with a default),
// per-token mode only, every key an API provider that answers the rounds. Returns { maxSearches, citeBytes } (both null: search off) or { error }.
export function searchFromEnv(env, panel, perToken) {
  const given = (v) => v !== undefined && v !== '';
  const hasMax = given(env.E3D_DEBATE_MAX_SEARCHES);
  const hasCite = given(env.E3D_DEBATE_CITE_BYTES_MAX);
  if (!hasMax && !hasCite) return { maxSearches: null, citeBytes: null };
  if (hasMax !== hasCite) return { error: 'E3D_DEBATE_MAX_SEARCHES and E3D_DEBATE_CITE_BYTES_MAX are set together or not at all' };
  if (!perToken) return { error: 'E3D_DEBATE_MAX_SEARCHES needs E3D_DEBATE_MAX_TOKENS (web search is priced inside per-token pricing only)' };
  const m = parseLimitMap(env.E3D_DEBATE_MAX_SEARCHES, 'E3D_DEBATE_MAX_SEARCHES', LIMITS.maxSearches);
  if (m.error) return { error: m.error };
  const bad = Object.keys(m.value).filter((p) => !API_PROVIDERS.includes(p) || !panel.includes(p));
  if (bad.length) return { error: `E3D_DEBATE_MAX_SEARCHES names ${bad.join(', ')}, which is not an API provider of this debate` };
  if (!/^\d{1,6}$/.test(String(env.E3D_DEBATE_CITE_BYTES_MAX)) || Number(env.E3D_DEBATE_CITE_BYTES_MAX) > LIMITS.citeBytes) return { error: `E3D_DEBATE_CITE_BYTES_MAX must be a whole number from 0 to ${LIMITS.citeBytes}` };
  return { maxSearches: m.value, citeBytes: Number(env.E3D_DEBATE_CITE_BYTES_MAX) };
}

// At most maxBytes UTF-8 bytes of s, cut on a character (code point) boundary: never a partial character, never more bytes.
export function truncateBytes(s, maxBytes) {
  const str = String(s);
  if (Buffer.byteLength(str, 'utf8') <= maxBytes) return str;
  let bytes = 0;
  let end = 0;
  for (const ch of str) {
    const n = Buffer.byteLength(ch, 'utf8');
    if (bytes + n > maxBytes) break;
    bytes += n;
    end += ch.length;
  }
  return str.slice(0, end);
}

const utf8Bytes = (file) => { try { return statSync(file).size; } catch { return 0; } };
const readText = (file) => { try { return readFileSync(file, 'utf8'); } catch { return ''; }; };
const count = (v) => (isInt(v, 0, 1e9) ? v : null);

// The vendor's usage as the adapters print it: the last e3d_provider_usage= line of the call's stderr, input_tokens and
// output_tokens being every billed token (the adapters normalise: cache classes, reasoning and thinking included).
export function vendorUsage(stderr) {
  const lines = String(stderr).split('\n').filter((l) => l.startsWith('e3d_provider_usage='));
  if (!lines.length) return null;
  let u;
  try { u = JSON.parse(lines[lines.length - 1].slice('e3d_provider_usage='.length)); } catch { return null; }
  if (!isObj(u)) return null;
  const input = count(u.input_tokens);
  const output = count(u.output_tokens);
  if (input === null || output === null) return null;
  // searches: the count the adapter read from the vendor's own counter (null when the line has none; never an estimate)
  return { input, output, searches: count(u.searches), model: typeof u.model === 'string' && MODEL_RE.test(u.model) ? u.model : 'unspecified' };
}

// Did a call that left no usable usage line reach the vendor? A vendor HTTP error (4xx or 5xx) and a failure before any request
// was sent (no key, no connection) never bill a token. A success with no usage line, a transport failure after the request was
// sent (timeout, reset, partial response) and a 200 with no content may have, so they are rows.
export function reachedVendor({ status, stderr }) {
  if (status === 0 || status === 'inflight') return true;
  if (/\bHTTP \d{3}\b/.test(stderr)) return false;
  if (/returned no (text content|message content)/.test(stderr)) return true;
  // a search call (adapters' ws_fail): a timeout, or a failure AFTER a 200 arrived (the answer was refused by our own checks), may have been
  // billed; a vendor HTTP error (http_NNN) and a failure before the request left were not
  if (/web search unavailable \((timeout|bad_response|response_failed|unexpected_tool|search_failed|no_text|status_[a-z_]*|response_errors|search_error_[a-z_]*|pause_turn_limit)\)/.test(stderr)) return true;
  const m = /curl exit (\d+)/.exec(stderr);
  return Boolean(m) && [18, 28, 52, 55, 56].includes(Number(m[1]));
}

// One usage row per attempted call. source 'vendor': the vendor's counts. source 'bytes' (the interface's name for an estimate): the
// usage line was missing or unparseable, so input_tokens = UTF-8 bytes of the prompt sent and output_tokens = UTF-8 bytes of the output
// received, or maxTokens when the response was lost (never an undercount: a token is at least one byte).
// search: undefined = no `searches` field (usage report version 1, today's rows); 'none' = the call was made without the search tool
// (searches 0); 'search' = a call with the search tool: the vendor's own counter, or null when there is none (a row from bytes, a usage
// line without a counter). Search-result tokens are in the vendor's input_tokens exactly as the vendor reports them.
export function usageRow({ key, provider, promptFile, outFile, stderrFile, status, maxTokens, search }) {
  const stderr = readText(stderrFile);
  const v = vendorUsage(stderr);
  const extra = (reported) => (search === undefined ? {} : { searches: search === 'none' ? 0 : reported });
  if (v) return { key, provider, model: v.model, input_tokens: v.input, output_tokens: v.output, source: 'vendor', ...extra(v.searches) };
  if (!reachedVendor({ status, stderr })) return null;
  const received = status === 0 ? utf8Bytes(outFile) : 0;
  const output = status === 0 && received > 0 ? received : maxTokens;
  const model = (() => { const m = /e3d_provider_usage=\{[^}]*"model":"([!-~]{1,128}?)"/.exec(stderr); return m ? m[1] : 'unspecified'; })();
  return { key, provider, model, input_tokens: utf8Bytes(promptFile), output_tokens: Math.min(output, 1e9), source: 'bytes', ...extra(null) };
}

function main(argv) {
  const [cmd, ...a] = argv;
  if (cmd === 'config') {
    const r = limitsFromEnv(process.env, a, a.slice(1));
    if (r.error) { process.stderr.write(`error: ${r.error}\n`); return 1; }
    process.stdout.write(`${JSON.stringify(r)}\n`);
    return 0;
  }
  if (cmd === 'truncate') {
    const max = Number(a[0]);
    if (!isInt(max, 1, LIMITS.answerBytes)) { process.stderr.write('error: truncate needs a byte limit\n'); return 1; }
    process.stdout.write(truncateBytes(readFileSync(0, 'utf8'), max));
    return 0;
  }
  if (cmd === 'row') {
    const [key, provider, promptFile, outFile, stderrFile, status, maxTokens, search] = a;
    const row = usageRow({ key, provider, promptFile, outFile, stderrFile, status: status === 'inflight' ? 'inflight' : Number(status), maxTokens: Number(maxTokens) || 0,
      ...(search === 'none' || search === 'search' ? { search } : {}) });
    if (row) process.stdout.write(`${JSON.stringify(row)}\n`);
    return 0;
  }
  process.stderr.write('usage: token-pricing.mjs config|truncate|row ...\n');
  return 2;
}

if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) process.exitCode = main(process.argv.slice(2));
