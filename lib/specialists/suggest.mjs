#!/usr/bin/env node
// Experts, Phase 2a.3 (docs/specs/experts-phase2a-seats-and-suggest-spec.md section 3): a free, rule-based panel suggestion, called by bin/e3d-debate.
//
//   suggest.mjs suggest --question TEXT [--task decide|review-spec|find-gaps]
//   suggest.mjs rules
//
// It only READS: the rule table (suggest.json), panels.json and the built-in expert folders. No model, no network, no process, nothing written.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadExperts } from '../debate/specialists.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
export const TASKS = ['decide', 'review-spec', 'find-gaps'];
export const FIXED_SENTENCE = 'Rule-based advice, not a measurement. It matches words; it does not understand your question.';

export const loadTable = (dir = HERE) => JSON.parse(readFileSync(join(dir, 'suggest.json'), 'utf8'));
// Catalogue order = the order of --list-specialists (alphabetical by name). Built-in experts only, so the answer never depends on a person's own folders.
export const catalogue = (dir = HERE) => loadExperts({ tiers: [{ name: 'built-in', dir }] }).experts;

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
// Whole-word, case-insensitive: the trigger must not touch a letter or digit on either side ("plan" is not in "planet", "ship" not in "relationship").
export function matches(text, word) {
  const body = word.trim().toLowerCase().split(/\s+/).map(escapeRe).join('\\s+');
  return new RegExp(`(?<![\\p{L}\\p{N}_])${body}(?![\\p{L}\\p{N}_])`, 'u').test(text.toLowerCase().replace(/[‘’]/g, "'"));
}

export function suggest({ question, task, table = loadTable(), experts = catalogue() }) {
  const order = experts.map((e) => e.name);
  const taskOf = new Map(experts.map((e) => [e.name, e.sidecar.tasks]));
  const score = new Map(); const words = new Map();
  for (const rule of table.rules) {
    const hit = rule.words.filter((w) => matches(question, w));
    if (!hit.length) continue;
    const n = Math.min(hit.length, table.max_hits_per_rule);
    for (const [name, w] of Object.entries(rule.add)) {
      if (!order.includes(name)) continue;
      score.set(name, (score.get(name) || 0) + n * w);
      const list = words.get(name) || []; for (const h of hit) if (!list.includes(h)) list.push(h); words.set(name, list);
    }
  }
  const matched = order.filter((n) => score.has(n));
  const boost = (n) => (task && (taskOf.get(n) || []).includes(task) ? table.task_boost : 0);
  // Rank by rule score plus the task boost; ties keep catalogue order (Array.sort is stable). Only experts a rule matched can be proposed.
  const ranked = matched.map((n, i) => ({ name: n, i, rule_score: score.get(n), total: score.get(n) + boost(n), boosted: boost(n) > 0, words: words.get(n) }))
    .sort((a, b) => b.total - a.total || a.i - b.i).slice(0, table.council_size);
  const weight = ranked.reduce((s, r) => s + r.rule_score, 0);
  if (matched.length < 2) {
    return { low: true, reason: `${matched.length} expert${matched.length === 1 ? '' : 's'} matched (at least 2 needed)`, preset: table.fallback_preset, experts: ranked, weight, confidence: 'low', task: task || null };
  }
  return { low: weight < table.low_confidence_below, reason: weight < table.low_confidence_below ? `total rule weight ${weight} is below ${table.low_confidence_below}` : '', preset: table.fallback_preset, experts: ranked, weight, confidence: weight < table.low_confidence_below ? 'low' : 'medium', task: task || null };
}

const shq = (s) => `'${s.replace(/'/g, `'\\''`)}'`;

export function render(question, r, table = loadTable()) {
  const out = [];
  out.push(`Suggested panel (rule-based; nothing was run, no model was called, nothing was spent)${r.task ? `  task: ${r.task}` : ''}`);
  for (const e of r.experts) out.push(`  ${e.name.padEnd(14)} matched: ${e.words.join(', ')}${e.boosted ? `  (+${table.task_boost} for task ${r.task})` : ''}`);
  if (!r.experts.length) out.push('  (no rule matched)');
  out.push(`Confidence: ${r.confidence}${r.confidence === 'low' ? ` (${r.reason})` : ` (total rule weight ${r.weight}; low is below ${table.low_confidence_below})`}`);
  const cmd = r.confidence === 'low'
    ? `E3D_SPECIALISTS=1 e3d-debate ${shq(question)} --panel ${r.preset}`
    : `E3D_SPECIALISTS=1 e3d-debate ${shq(question)} ${r.experts.map((e) => `--specialist ${e.name}`).join(' ')}`;
  if (r.confidence === 'low') out.push(`Low confidence: not guessing. The general preset ${r.preset} is proposed instead (the experts above, if any, are only weak matches).`);
  out.push('Command to run it yourself (nothing runs by itself):', `  ${cmd}`, FIXED_SENTENCE);
  return out.join('\n');
}

export function renderRules(table = loadTable(), experts = catalogue()) {
  const out = [`Suggest rules (${table.schema}). ${FIXED_SENTENCE}`,
    `Council size ${table.council_size}; each rule counts at most ${table.max_hits_per_rule} matched words; low confidence below total weight ${table.low_confidence_below}; --task adds ${table.task_boost} to experts that list the task; fewer than 2 matched experts proposes the ${table.fallback_preset} preset.`, ''];
  for (const r of table.rules) out.push(`${r.id}: ${Object.entries(r.add).map(([k, v]) => `${k} +${v}`).join(', ')}`, `  words: ${r.words.join(', ')}`);
  return out.join('\n');
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const [cmd, ...rest] = process.argv.slice(2);
  try {
    if (cmd === 'rules') { console.log(renderRules()); process.exit(0); }
    const o = {};
    for (let i = 0; i < rest.length; i += 2) { if (rest[i] === '--question') o.question = rest[i + 1]; else if (rest[i] === '--task') o.task = rest[i + 1]; else throw new Error(`unknown option ${rest[i]}`); }
    if (cmd !== 'suggest') throw new Error('usage: suggest.mjs suggest --question TEXT [--task T] | rules');
    if (!o.question || !o.question.trim()) throw new Error('--suggest-panel needs a question');
    if (o.task && !TASKS.includes(o.task)) throw new Error(`--task must be one of ${TASKS.join(', ')}`);
    console.log(render(o.question, suggest(o)));
  } catch (e) { console.error(`error: ${e.message}`); process.exit(1); }
}
