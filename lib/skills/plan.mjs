// The local plan of a skills debate (docs/skills/phase3/plan.md, decisions D1, D3, D4, D9). Pure functions over what the planner already loaded: no file, network
// or model access. It resolves a seat skill reference (`--seat-skill`) to an expert-shaped seat, checks it fits the seat hook, and builds the PREVIEW a person (or a
// script) can read before anything runs, with a digest of exactly what a run would do. The hosted service wraps the same facts in its own plan (identity, quote,
// approval; schema skill-plan); this local preview has none of those and validates against skill-preview.
//
//   parseSeatSkill("skeptic@1.0.0#sha256:...:claude") -> { ref, version, hash, override } | null
//   resolveSeatSkill(catalogue, spec)                 -> { ok, skill, override, expert } | { ok: false, error }
//   buildPreview({ seats, plain, ... })               -> the skill-preview document (throws if it would not validate)
//   renderPreview(preview)                            -> plain text
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { canonicalize } from './canonical.mjs';
import { resolveSkill } from './definition.mjs';
import { createSchemaSet } from './jsonschema.mjs';
import { familyOf, independenceOf, lensBlock } from '../debate/specialists-plan.mjs';
import { tokens } from '../debate/cost-model.mjs';

export const PREVIEW_VERSION = 'e3d.skill-preview/v1';
const schemas = createSchemaSet(fileURLToPath(new URL('./schemas/v1', import.meta.url)));
const err = (code, message) => ({ code, message });
const SEAT_SPEC = /^((?:skill\.[a-z0-9_]{2,40}\.)?[a-z0-9]+(?:-[a-z0-9]+)*)(?:@((?:0|[1-9][0-9]{0,5})\.(?:0|[1-9][0-9]{0,5})\.(?:0|[1-9][0-9]{0,5})))?(?:#(sha256:[0-9a-f]{64}))?(?::([a-z][a-z0-9-]{0,31}))?$/;

// <id|name>[@version][#sha256:hash][:provider]
export function parseSeatSkill(arg) {
  const m = SEAT_SPEC.exec(arg || '');
  return m ? { ref: m[1], version: m[2], hash: m[3], override: m[4] ?? null } : null;
}

// An expert-shaped object for a catalogue entry, so the existing planner (assign, lensBlock) takes a skill like any expert. The lens is the instruction text;
// provider hints come from the skill's hashed model_hints (for a native skill) or the sidecar (for a projected expert: the same list).
export function expertFromSkill(entry) {
  const d = entry.definition;
  const base = entry.expert;
  return {
    ...base,
    name: entry.slug,
    lens: d.instructions.method,
    tier: entry.tier,
    sidecar: { ...base.sidecar, tools: 'none', models: (d.model_hints ?? []).map((m) => ({ provider: m.provider, ...(m.effort ? { effort: m.effort } : {}) })), limits: d.limits.max_words !== undefined ? { max_words: d.limits.max_words } : {} },
    warnings: (entry.warnings ?? []).map((w) => ({ code: w.code, message: w.message, file: w.path })),
    skill_id: d.id,
  };
}

// The entry of a catalogue that IS this expert (same name, tier and folder bytes), or null: a folder that changed between the two loads is never matched.
export const findSkill = (catalogue, expert) => catalogue.skills.find((s) => s.slug === expert.name && s.tier === expert.tier && s.definition.provenance.legacy_folder_hash === expert.hash) ?? null;

export function resolveSeatSkill(catalogue, spec) {
  const p = parseSeatSkill(spec);
  if (!p) return { ok: false, error: err('skill_schema_format', `"${String(spec).replace(/[^\x20-\x7E]/g, '?').slice(0, 60)}" is not <id|name>[@version][#sha256:hash][:provider]`) };
  const r = resolveSkill(catalogue.skills, p.ref, { version: p.version, hash: p.hash });
  if (!r.ok) return { ok: false, error: r.error };
  const d = r.skill.definition;
  if (!d.hooks.some((h) => h.scope === 'debate_seat' && h.event === 'seat_prompt')) return { ok: false, error: err('skill_conflict', `${d.id} does not declare the hook debate_seat/seat_prompt, so it cannot sit on a seat`) };
  return { ok: true, skill: r.skill, override: p.override, expert: expertFromSkill(r.skill) };
}

export const planDigest = (parts) => `sha256:${createHash('sha256').update(canonicalize(parts), 'utf8').digest('hex')}`;

// seats: [{ seat, adapter, expert, source: 'preset'|'specialist'|'seat-skill', hint_used, override }]; plain: [{ seat, adapter, reason, code }]
export function buildPreview({ seats, plain = [], rounds, maxWords, synthesizer, questionSha256 = null, catalogue, observers = [], warnings = [], conflicts = [] }) {
  const outSeats = seats.map((s) => {
    const hit = findSkill(catalogue, s.expert);
    if (!hit) warnings.push(`${s.expert.name}: no skill definition matches this folder (not projectable, or it changed while loading); it runs as the expert it is`);
    return {
      seat: s.seat, adapter: s.adapter, family: familyOf(s.adapter), source: s.source, hook: 'seat_prompt',
      skill: hit ? { id: hit.definition.id, version: hit.definition.version, hash: hit.definition.definition_hash } : null,
      legacy_folder_hash: s.expert.hash, tier: s.expert.tier, lens_block_bytes: Math.min(4096, Buffer.byteLength(lensBlock(s.expert))),
      hint_used: !!s.hint_used, provider_forced: !!s.override,
    };
  });
  const outPlain = plain.map((p) => ({ seat: p.seat, adapter: p.adapter, family: familyOf(p.adapter), reason: p.reason, code: p.code ?? null }));
  const all = [...outSeats.map((s) => ({ provider: s.adapter })), ...outPlain.map((p) => ({ provider: p.adapter }))];
  const n = all.length;
  if (n < 1) throw new Error('the preview does not validate (a plan needs at least one seat)');
  const nominal = n * rounds + 1 + observers.length;
  const t = tokens({ n, r: rounds, lens: outSeats.length > 0 });
  const preview = {
    schema_version: PREVIEW_VERSION,
    plan_digest: `sha256:${'0'.repeat(64)}`,
    request: { question_sha256: questionSha256, rounds, max_words: maxWords, synthesizer },
    seats: outSeats, plain_seats: outPlain, observers,
    independence: independenceOf(all),
    estimate: { model_calls: { nominal, with_retries: nominal * 2 }, tokens: { input: t.input, output: t.output, total: t.total, basis: 'the cost model for a typical short question; an estimate, not a bound. Credits are quoted by the hosted service, not here' } },
    conflicts, warnings,
  };
  preview.plan_digest = planDigest({ v: 1, request: preview.request, seats: outSeats.map((s) => ({ seat: s.seat, adapter: s.adapter, source: s.source, skill: s.skill, legacy_folder_hash: s.legacy_folder_hash, lens_block_bytes: s.lens_block_bytes, provider_forced: s.provider_forced })), plain: outPlain.map((p) => ({ seat: p.seat, adapter: p.adapter, reason: p.reason })), observers });
  const bad = schemas.check('skill-preview', preview);
  if (bad.length) throw new Error(`the preview does not validate (${bad.slice(0, 3).map((e) => `${e.path} ${e.code}`).join('; ')})`);
  return preview;
}

export function renderPreview(p) {
  const L = [];
  L.push(`Skills plan ${p.plan_digest}`);
  L.push(`Request: ${p.request.rounds} round${p.request.rounds === 1 ? '' : 's'}, ${p.request.max_words} words, synthesizer ${p.request.synthesizer}${p.request.question_sha256 ? '' : ', no question given (the digest will differ once one is)'}`);
  L.push('');
  L.push('Seats (each receives its skill as a role block; the synthesis never sees a lens):');
  for (const s of p.seats) L.push(`  ${s.seat.padEnd(10)} ${s.adapter}/${s.family}  ${s.skill ? `${s.skill.id} ${s.skill.version} ${s.skill.hash.slice(7, 19)}` : `expert ${s.legacy_folder_hash.slice(7, 19)} (no skill definition)`}  [${s.tier}, ${s.source}${s.provider_forced ? ', provider forced' : s.hint_used ? ', provider hint used' : ''}] ${s.lens_block_bytes} bytes`);
  for (const s of p.plain_seats) L.push(`  ${s.seat.padEnd(10)} ${s.adapter}/${s.family}  plain seat (${s.reason === 'skill_failed' ? `its skill failed: ${s.code}` : 'fills the pool'})`);
  if (p.observers.length) { L.push(''); L.push('Observer (after the verdict is stored; read-only; cannot change it):'); for (const o of p.observers) L.push(`  ${o.skill.id} ${o.skill.version} on ${o.adapter}/${o.family}, at most ${o.max_output_bytes} bytes, ${o.timeout_ms} ms`); }
  L.push('');
  L.push(`Independence: ${p.independence.seats} seats on ${p.independence.adapters} adapters in ${p.independence.families} vendor ${p.independence.families === 1 ? 'family' : 'families'}`);
  L.push(`Model calls: ${p.estimate.model_calls.nominal} nominal, up to ${p.estimate.model_calls.with_retries} with one retry each. Tokens (estimate): about ${p.estimate.tokens.total} (${p.estimate.tokens.basis})`);
  for (const c of p.conflicts) L.push(`CONFLICT ${c.code}: ${c.message}`);
  for (const w of p.warnings) L.push(`warning: ${w}`);
  return L.join('\n');
}
