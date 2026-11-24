// The observer's outcome as a bounded block for the finished run's result (hosted skills, PR H2d). Built ONLY from the engine's own files in the run's out dir
// (observers.json, observer-skip.json, observer-<name>.md, usage.json), never from stderr text, and never from the debate, the prompt or the skill text.
//   observer: { status: "ok" | "failed" | "timeout" | "skipped", code: "skill_*" | null, report: string | null, tokens: { input, output } | null, latency_ms: int | null }
// The report is UNTRUSTED model output: plain text (lib/skills/observer.mjs plainText, then the web-search sanitiser that also neutralises markdown images and links and
// HTML tags), at most min(the skill's max_output_bytes, REPORT_HARD_CAP) bytes. Zero dependencies beyond the engine's own libs.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { plainText, cutBytes } from './observer.mjs';
import { sanitizeText } from '../debate/websearch.mjs';

export const REPORT_HARD_CAP = 4096;
const CODE_RE = /^skill_[a-z_]{1,40}$/;
const readJson = (f) => { try { return JSON.parse(readFileSync(f, 'utf8')); } catch { return null; } };
const code = (c) => (typeof c === 'string' && CODE_RE.test(c) ? c : null);
const count = (n) => (Number.isSafeInteger(n) && n >= 0 && n <= 1e9 ? n : null);

// slug: the skill name (the usage row key is observer:<slug>); maxOutputBytes: the skill's own limit (a missing one means the hard cap alone).
export function observerResult({ outDir, slug, maxOutputBytes }) {
  const entry = (() => { const a = readJson(join(outDir, 'observers.json')); return Array.isArray(a) && a[0] && typeof a[0] === 'object' ? a[0] : null; })();
  const rows = readJson(join(outDir, 'usage.json'));
  const row = Array.isArray(rows) ? rows.find((r) => r && r.key === `observer:${slug}`) : null;
  const tokens = row && count(row.input_tokens) !== null && count(row.output_tokens) !== null ? { input: row.input_tokens, output: row.output_tokens } : null;
  if (!entry) {
    // no run record: the engine made no call (it left observer-skip.json, or nothing at all), or its record could not be written after a call
    const skip = readJson(join(outDir, 'observer-skip.json'));
    if (!row) return { status: 'skipped', code: code(skip?.code), report: null, tokens: null, latency_ms: null };
    return { status: 'failed', code: 'skill_provider_error', report: null, tokens, latency_ms: null };
  }
  const run = entry.run ?? {};
  const first = Array.isArray(run.errors) ? run.errors[0] : null;
  const c = code(first?.code);
  const status = run.status === 'completed' ? 'ok' : c === 'skill_timeout' ? 'timeout' : 'failed';
  const lat = count(run.metrics?.latency_ms);
  let report = null;
  const file = entry.output?.file;
  if (status === 'ok' && typeof file === 'string' && /^observer-[a-z0-9][a-z0-9_-]{0,63}\.md$/.test(file)) {
    let raw = null;
    try { raw = readFileSync(join(outDir, file), 'utf8'); } catch { /* no report file */ }
    if (raw !== null) {
      const cap = Math.min(Number.isSafeInteger(maxOutputBytes) && maxOutputBytes > 0 ? maxOutputBytes : REPORT_HARD_CAP, REPORT_HARD_CAP);
      // cut BEFORE sanitising: the markup patterns in sanitizeText are quadratic on a hostile reply (a 64 KB run of spaces after "![a](" took seconds and would stall the whole listener), so they only ever see
      // at most `cap` bytes (4096 at most); then cut again, because sanitising can lengthen text a little
      report = cutBytes(sanitizeText(cutBytes(plainText(raw), cap)).trim(), cap);
    }
  }
  return { status, code: c ?? (status === 'failed' ? 'skill_provider_error' : null), report, tokens, latency_ms: lat };
}
