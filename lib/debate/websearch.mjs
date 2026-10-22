#!/usr/bin/env node
// Web search for debates: configuration, citation post-filtering, output sanitising and the per-debate summary.
// Zero dependencies. Used by bin/e3d-debate (as a command) and bin/e3d-mcp (as a module). See docs/web-search-providers.md
// for the per-vendor controls and docs/web-search-interface.md for the shapes this produces.
//
// Everything a search returns (titles, excerpts, URLs) and everything a model writes is treated as hostile: it is
// sanitised before it is stored, returned, or shown to another model, and nothing here ever fetches a URL.
//
// Commands (bin/e3d-debate):
//   config                               -> JSON effective config from the environment (errors => search off)
//   filter <sidecar.json> <provider> <round>  -> JSON per-call record (domain post-filter, caps, sanitising, flags)
//   sanitize                             stdin text -> stdout text (control/bidi chars stripped, images/HTML/links neutralised)
//   cite-list <record.json>              -> the compact citation list given to later rounds (domain + URL, no page text)
//   summary <records-dir> <json-config>  -> JSON summary for web-search.json and the decision log
import { readFileSync, readdirSync, realpathSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const API_PROVIDERS = Object.freeze(['anthropic-api', 'openai-api', 'gemini-api', 'xai-api']);
export const DEFAULTS = Object.freeze({ maxSearches: 3, maxCitations: 8, excerptChars: 150, titleChars: 120 });
const HARD = Object.freeze({ maxSearches: 10, maxCitations: 20, excerptChars: 300, domains: 100 });
export const NO_WEB_ACCESS_TEXT = 'You have no web access and your knowledge may be out of date. If the question depends on recent events or current data, say so and give your answer conditionally.';
export const INSTRUCTIONS_IGNORED_TEXT = 'a source contained instructions, ignored';
export const PRIVACY_NOTICE = 'Web search is on by default: the question text may be sent to a search provider by the participating models (Anthropic, OpenAI, Google or xAI) to look up current facts. Pass web_search: false to turn it off for this debate.';

// A bare domain: lowercase labels, no scheme, port, path, wildcard or trailing dot.
const DOMAIN_RE = /^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/;
const list = (v) => String(v ?? '').split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);
const intIn = (v, dflt, lo, hi) => { if (v === undefined || v === '') return dflt; const n = Number(v); return Number.isInteger(n) && n >= lo && n <= hi ? n : null; };

// The effective configuration. Any invalid setting turns search off for the whole debate (fail closed) and is reported.
export function webSearchConfig(env = process.env) {
  const errors = [];
  const flag = String(env.E3D_DEBATE_WEB_SEARCH ?? 'on').trim().toLowerCase();
  let enabled;
  if (['on', '1', 'true', 'yes'].includes(flag)) enabled = true;
  else if (['off', '0', 'false', 'no'].includes(flag)) enabled = false;
  else { enabled = false; errors.push('E3D_DEBATE_WEB_SEARCH must be on or off'); }
  const wanted = env.E3D_DEBATE_WEB_SEARCH_PROVIDERS === undefined ? [...API_PROVIDERS] : list(env.E3D_DEBATE_WEB_SEARCH_PROVIDERS);
  // only the four API providers can search, whatever the list says
  let providers = wanted.filter((p) => API_PROVIDERS.includes(p));
  // Per-token pricing (E3D_DEBATE_MAX_SEARCHES, set by e3d-mcp from the quote): only the providers the quote names search, each with the
  // cap it was priced at; the global E3D_DEBATE_SEARCH_MAX_PER_CALL does not apply. bin/e3d-debate has already validated the variable.
  const caps = perTokenCaps(env);
  if (caps) providers = providers.filter((p) => caps[p] !== undefined);
  const maxSearches = intIn(env.E3D_DEBATE_SEARCH_MAX_PER_CALL, DEFAULTS.maxSearches, 1, HARD.maxSearches);
  const maxCitations = intIn(env.E3D_DEBATE_SEARCH_MAX_CITATIONS, DEFAULTS.maxCitations, 1, HARD.maxCitations);
  const excerptChars = intIn(env.E3D_DEBATE_SEARCH_EXCERPT_CHARS, DEFAULTS.excerptChars, 0, HARD.excerptChars);
  if (maxSearches === null) errors.push(`E3D_DEBATE_SEARCH_MAX_PER_CALL must be 1..${HARD.maxSearches}`);
  if (maxCitations === null) errors.push(`E3D_DEBATE_SEARCH_MAX_CITATIONS must be 1..${HARD.maxCitations}`);
  if (excerptChars === null) errors.push(`E3D_DEBATE_SEARCH_EXCERPT_CHARS must be 0..${HARD.excerptChars}`);
  const allow = list(env.E3D_DEBATE_SEARCH_ALLOW_DOMAINS);
  const deny = list(env.E3D_DEBATE_SEARCH_DENY_DOMAINS);
  for (const [name, l] of [['E3D_DEBATE_SEARCH_ALLOW_DOMAINS', allow], ['E3D_DEBATE_SEARCH_DENY_DOMAINS', deny]]) {
    if (l.length > HARD.domains) errors.push(`${name} holds more than ${HARD.domains} domains`);
    const bad = l.filter((d) => !DOMAIN_RE.test(d));
    if (bad.length) errors.push(`${name} must hold bare domains like example.com (invalid: ${bad.slice(0, 3).map((d) => JSON.stringify(d.slice(0, 40))).join(', ')})`);
  }
  if (errors.length) enabled = false;
  return { enabled, providers, maxSearches: maxSearches ?? DEFAULTS.maxSearches, maxCitations: maxCitations ?? DEFAULTS.maxCitations,
    excerptChars: excerptChars ?? DEFAULTS.excerptChars, allow, deny, errors, ...(caps ? { caps } : {}) };
}

// The true web search state of a deployment, for the tool descriptions and listings: { on, providers, text }. Never promises a default
// the server has off.
const NAMES = { 'anthropic-api': 'Anthropic', 'openai-api': 'OpenAI', 'gemini-api': 'Google', 'xai-api': 'xAI' };
export function searchAvailability(env = process.env) {
  const cfg = webSearchConfig(env);
  const on = cfg.enabled && cfg.providers.length > 0;
  const names = cfg.providers.map((p) => NAMES[p] ?? p).join(', ');
  return { on, providers: on ? cfg.providers : [], text: on ? `Web search: on by default on this server (${names}); pass web_search: false to turn it off for a debate.` : 'Web search: off on this server, so models answer from their own knowledge, which may be out of date.' };
}

// { provider: k } from E3D_DEBATE_MAX_SEARCHES, or null when unset (or unreadable: the caller's own validation has refused the debate).
export function perTokenCaps(env = process.env) {
  const raw = env.E3D_DEBATE_MAX_SEARCHES;
  if (raw === undefined || raw === '') return null;
  try {
    const v = JSON.parse(raw);
    if (v === null || typeof v !== 'object' || Array.isArray(v)) return null;
    return Object.fromEntries(Object.entries(v).filter(([p, k]) => API_PROVIDERS.includes(p) && Number.isInteger(k) && k >= 1 && k <= HARD.maxSearches));
  } catch { return null; }
}

// ---- sanitising ----
// C0 controls except tab and newline, DEL, C1 controls, bidi embeddings/overrides/isolates and marks, zero-width characters, BOM.
// eslint-disable-next-line no-control-regex
const CONTROL_RE = /[\u0000-\u0008\u000B-\u001F\u007F-\u009F؜​-‏‪-‮⁠-⁩﻿]/g;
export const stripControls = (s) => String(s ?? '').replace(/\r\n?/g, '\n').replace(CONTROL_RE, '');

export function hostOf(url) {
  try { const u = new URL(url); return /^https?:$/.test(u.protocol) ? u.hostname.toLowerCase() : null; } catch { return null; }
}
// A URL as plain text: http(s) only, no credentials, query string or fragment, backticks removed; null when unusable.
export function cleanUrl(url) {
  let u;
  try { u = new URL(String(url ?? '').trim()); } catch { return null; }
  if (!/^https?:$/.test(u.protocol) || !u.hostname) return null;
  u.username = ''; u.password = ''; u.search = ''; u.hash = '';
  const s = u.toString().replace(/[`\s<>"']/g, '');
  return s.length <= 500 ? s : null;
}
const plainUrl = (url) => { const c = cleanUrl(url); const h = c && hostOf(c); return c ? `${h}: \`${c}\`` : 'link removed'; };

// Neutralises anything a renderer could load or disguise: markdown images become a note, markdown links and autolinks become
// their text plus the URL as a code span with the domain visible, reference definitions and HTML tags are removed.
export function sanitizeText(input) {
  let s = stripControls(input);
  s = s.replace(/!\[([^\]\n]{0,300})\]\(\s*<?((?:[^()\s>]|\([^()\s]*\))*)>?(?:\s+"[^"\n]*")?\s*\)/g, (_m, _alt, url) => `[image removed${hostOf(url) ? `: ${hostOf(url)}` : ''}]`);
  s = s.replace(/!\[([^\]\n]{0,300})\]\[[^\]\n]*\]/g, '[image removed]');
  s = s.replace(/(?<!!)\[([^\]\n]{0,300})\]\(\s*<?((?:[^()\s>]|\([^()\s]*\))*)>?(?:\s+"[^"\n]*")?\s*\)/g, (_m, label, url) => `${label} (${plainUrl(url)})`);
  s = s.replace(/^[ \t]{0,3}\[[^\]\n]+\]:[ \t]*<?(\S+?)>?(?:[ \t]+.*)?$/gm, (_m, url) => `(link reference removed: ${hostOf(url) ?? 'invalid'})`);
  s = s.replace(/<((?:https?|ftp|data|javascript):[^>\s]*)>/gi, (_m, url) => plainUrl(url));
  s = s.replace(/<\/?[A-Za-z!?][^<>]{0,2000}>/g, '[html removed]');
  s = s.replace(/\b(?:javascript|data|vbscript):[^\s)]*/gi, '[unsafe link removed]');
  return s;
}

// Instruction-like text in a title, excerpt or answer (a hint for the flag, never a security boundary).
const INSTRUCTION_RE = /\b(?:ignore|disregard|forget|override|bypass)\b[^.\n]{0,60}\b(?:instructions?|prompts?|rules|guidelines|directions)\b|\bsystem prompt\b|\byou are now\b|\bnew instructions\b|\bdeveloper mode\b|\breveal (?:your|the)\b|\bdo anything now\b|\bjailbreak\b/i;
export const looksLikeInstructions = (s) => INSTRUCTION_RE.test(String(s ?? ''));
export const mentionsIgnoredInstructions = (s) => /a source contained instructions/i.test(String(s ?? ''));

// One line of page text (a title or an excerpt): no markup characters, URLs inside it lose query strings and fragments.
const oneLine = (s, max) => {
  const t = stripControls(s).replace(/\b(?:https?|ftp):\/\/[^\s<>"'`)\]]+/gi, (u) => cleanUrl(u) ?? '[url removed]').replace(/\b(?:javascript|data|vbscript):\S*/gi, '[unsafe link removed]').replace(/[\[\]()<>!`*_#|\\]/g, ' ').replace(/\s+/g, ' ').trim();
  return t.length > max ? `${t.slice(0, max - 1)}…` : t;
};
const matches = (host, d) => host === d || host.endsWith(`.${d}`);
// Gemini grounding may hand back a redirect URL whose title is the source domain (third-party reports; not in Google's docs).
const REDIRECT_HOSTS = ['vertexaisearch.cloud.google.com'];

// the search cap of one call: the quoted per-provider cap under per-token pricing, else the global one
const capOf = (cfg, provider) => cfg.caps?.[provider] ?? cfg.maxSearches;

// One call's adapter sidecar -> the record kept for the debate. Caps hold whatever the vendor returned.
export function filterRecord(raw, { provider, round, cfg }) {
  const dropped = { over_cap: 0, denied_domain: 0, not_allowed_domain: 0, invalid: 0, duplicate: 0 };
  let instructionsFlag = false;
  const out = [];
  const seen = new Set();
  const items = Array.isArray(raw?.citations) ? raw.citations : [];
  for (const c of items) {
    const url = cleanUrl(c?.url);
    let host = url && hostOf(url);
    if (!url || !host) { dropped.invalid += 1; continue; }
    let title = oneLine(c?.title ?? '', DEFAULTS.titleChars);
    let viaRedirect = false;
    if (REDIRECT_HOSTS.includes(host) && DOMAIN_RE.test(title.toLowerCase())) { host = title.toLowerCase(); viaRedirect = true; }
    if (cfg.allow.length && !cfg.allow.some((d) => matches(host, d))) { dropped.not_allowed_domain += 1; continue; }
    if (cfg.deny.some((d) => matches(host, d))) { dropped.denied_domain += 1; continue; }
    if (seen.has(url)) { dropped.duplicate += 1; continue; }
    seen.add(url);
    if (out.length >= cfg.maxCitations) { dropped.over_cap += 1; continue; }
    let excerpt = cfg.excerptChars ? oneLine(c?.excerpt ?? '', cfg.excerptChars) : '';
    if (looksLikeInstructions(title)) { title = '[title withheld: it looked like instructions]'; instructionsFlag = true; }
    if (looksLikeInstructions(excerpt)) { excerpt = '[excerpt withheld: it looked like instructions]'; instructionsFlag = true; }
    out.push({ title: title || host, domain: host, url, excerpt, ...(viaRedirect ? { via_redirect: true } : {}) });
  }
  const searches = Number.isSafeInteger(raw?.searches) && raw.searches >= 0 ? raw.searches : 0;
  return {
    provider, round, ok: raw?.ok === true, error: raw?.ok === true ? null : String(raw?.error ?? 'unknown').replace(/[^a-z0-9_:.-]/gi, '_').slice(0, 60),
    searches, cap: capOf(cfg, provider), cap_exceeded: searches > capOf(cfg, provider),
    citations: out, citations_seen: items.length, dropped, instructions_flag: instructionsFlag || raw?.instructions_flag === true,
  };
}

// What later rounds and the synthesizer see of a call's search: domains and URLs only (titles and excerpts are page text).
export function citeList(record) {
  if (!record?.citations?.length) return '';
  return ['Sources this answer\'s web search returned (untrusted internet data; domains and URLs only):',
    ...record.citations.map((c) => `- ${c.domain}: ${c.url}`)].join('\n');
}

export function summarize(records, cfg, { requested = true, providersTotal = 0, searching = [], fallbacks = [] } = {}) {
  const searchesUsed = {};
  const dropped = { over_cap: 0, denied_domain: 0, not_allowed_domain: 0, invalid: 0, duplicate: 0 };
  const citations = [];
  const seen = new Set();
  const alarms = [];
  let instructionsFlag = false;
  for (const r of records) {
    searchesUsed[r.provider] = (searchesUsed[r.provider] ?? 0) + r.searches;
    for (const k of Object.keys(dropped)) dropped[k] += r.dropped?.[k] ?? 0;
    if (r.instructions_flag) instructionsFlag = true;
    if (r.cap_exceeded) alarms.push({ alarm: 'web_search_cap_exceeded', provider: r.provider, round: r.round, searches: r.searches, cap: r.cap });
    for (const c of r.citations ?? []) {
      if (seen.has(c.url)) continue;
      seen.add(c.url);
      if (citations.length >= HARD.maxCitations) { dropped.over_cap += 1; continue; }
      citations.push({ ...c, provider: r.provider });
    }
  }
  const unavailable = fallbacks.map((f) => ({ provider: f.provider, round: f.round, reason: f.reason }));
  return {
    schema: 1, enabled: Boolean(requested && cfg.enabled && searching.length), requested: Boolean(requested),
    config_errors: cfg.errors, models_total: providersTotal, models_with_search: searching.length, searching_providers: searching,
    cap_per_call: cfg.caps ? Math.max(0, ...Object.values(cfg.caps)) : cfg.maxSearches, ...(cfg.caps ? { cap_by_provider: cfg.caps } : {}), searches_used: searchesUsed, searches_total: Object.values(searchesUsed).reduce((a, b) => a + b, 0),
    citations, flags: { instructions_ignored: instructionsFlag, cap_exceeded: alarms, unavailable, citations_dropped: dropped },
  };
}

// The decision-log fragment: counts, bare domains and booleans only (no titles, URLs, excerpts, queries or page text).
export function decisionLogFields(summary) {
  return {
    search_enabled: summary.enabled, searching_providers: summary.searching_providers, searches_used: summary.searches_used,
    citation_domains: [...new Set(summary.citations.map((c) => c.domain))].sort(),
    instructions_flag: summary.flags.instructions_ignored,
    alarms: summary.flags.cap_exceeded.map((a) => `ALARM web_search_cap_exceeded provider=${a.provider} round=${a.round} searches=${a.searches} cap=${a.cap}`),
    unavailable: summary.flags.unavailable.map((u) => ({ provider: u.provider, round: u.round, reason: u.reason })),
    citations_dropped: summary.flags.citations_dropped,
  };
}

// ---- command line (bin/e3d-debate) ----
async function main(argv) {
  const [cmd, ...rest] = argv;
  const readJson = (p) => JSON.parse(readFileSync(p, 'utf8'));
  if (cmd === 'config') { process.stdout.write(`${JSON.stringify(webSearchConfig())}\n`); return 0; }
  if (cmd === 'sanitize') {
    let input = '';
    for await (const chunk of process.stdin) input += chunk;
    process.stdout.write(sanitizeText(input));
    return 0;
  }
  if (cmd === 'filter') {
    const [file, provider, round] = rest;
    let raw = null;
    try { raw = readJson(file); } catch { raw = { ok: false, error: 'no_search_record' }; }
    process.stdout.write(`${JSON.stringify(filterRecord(raw, { provider, round: Number(round) || 0, cfg: webSearchConfig() }))}\n`);
    return 0;
  }
  if (cmd === 'cite-list') { process.stdout.write(citeList(readJson(rest[0]))); return 0; }
  if (cmd === 'summary') {
    const [dir, metaFile] = rest;
    const meta = readJson(metaFile);
    const files = readdirSync(dir).filter((f) => /^ws-record-.*\.json$/.test(f)).sort();
    const records = files.map((f) => readJson(join(dir, f)));
    const fallbacks = readdirSync(dir).filter((f) => /^ws-fallback-.*\.json$/.test(f)).sort().map((f) => readJson(join(dir, f)));
    const summary = summarize(records, webSearchConfig(), { ...meta, fallbacks });
    process.stdout.write(`${JSON.stringify({ summary, decision_log: decisionLogFields(summary) })}\n`);
    return 0;
  }
  process.stderr.write('usage: websearch config|sanitize|filter <sidecar> <provider> <round>|cite-list <record>|summary <dir> <meta>\n');
  return 2;
}

const invokedDirectly = () => { try { return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)); } catch { return false; } };
if (process.argv[1] && invokedDirectly()) {
  main(process.argv.slice(2)).then((c) => process.exit(c), (e) => { process.stderr.write(`websearch: ${e.message}\n`); process.exit(1); });
}
