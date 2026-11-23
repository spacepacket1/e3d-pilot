#!/usr/bin/env node
// Command front end for experts (docs/specs/experts-phase1-private-experts-spec.md section 4), called by bin/e3d-debate. Zero dependencies.
//
//   list      --builtin D --user D --repo D
//   show      <name> --builtin D --user D --repo D [--pool a,b,c]
//   validate  <dir>
//   export    <name> <outdir> [--no-sidecar] --builtin D --user D --repo D
//   plan      --builtin D --user D --repo D --pool a,b,c [--min-families N] (--panel NAME | --specialist name[:provider] ...)   -> JSON on stdout
//             hosted runs (docs/specs/experts-phase2b1-hosted-lenses-spec.md section 2.2, all optional): --builtin-only (never read the user or
//             repo folders), --expert-pin name=sha256:<hex> (repeatable; refuse a different content hash), --fill-pool (every pool provider
//             without an expert becomes a plain seat; one seat per provider, never more), --lens-bytes-max N (refuse a larger lens block)
//
// Nothing here calls a model or the network. Only `export` writes, and only inside the new folder it creates under <outdir>.
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, lstatSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadExperts, validateFolder } from './specialists.mjs';
import { assign, independenceOf, lensBlock, parseSpecialistArg, validatePresets } from './specialists-plan.mjs';
// loaded only with --skills (E3D_SKILLS_V1=1), so every other path is independent of lib/skills
const skillsOn = process.argv.includes('--skills');
const skillsReceipt = skillsOn ? await import('../skills/receipt.mjs') : null;
const skillsPlan = skillsOn ? await import('../skills/plan.mjs') : null;
const skillsDef = skillsOn ? await import('../skills/definition.mjs') : null;
const skillsHosted = skillsOn ? await import('../skills/hosted.mjs') : null;

function parse(argv) {
  const o = { positional: [], specialists: [], pins: [], noSidecar: false, minFamilies: 2, builtinOnly: false, fillPool: false, lensBytesMax: null, skills: false, seatSkills: [], onSeatSkillFailure: 'fail', rounds: 2, maxWords: 200, synthesizer: 'claude', questionSha: null, settings: null, roundsGiven: null, maxWordsGiven: null, observerJson: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => { if (i + 1 >= argv.length) throw new Error(`${a} needs a value`); return argv[++i]; };
    if (a === '--builtin') o.builtin = val();
    else if (a === '--user') o.user = val();
    else if (a === '--repo') o.repo = val();
    else if (a === '--pool') o.pool = val();
    else if (a === '--panel') o.panel = val();
    else if (a === '--specialist') o.specialists.push(val());
    else if (a === '--min-families') { const v = val(); if (!/^[1-9][0-9]?$/.test(v)) throw new Error('--min-families must be a whole number of at least 1'); o.minFamilies = Number(v); }
    else if (a === '--builtin-only') o.builtinOnly = true;
    else if (a === '--fill-pool') o.fillPool = true;
    else if (a === '--expert-pin') o.pins.push(val());
    else if (a === '--lens-bytes-max') { const v = val(); if (!/^[1-9][0-9]{0,6}$/.test(v)) throw new Error('--lens-bytes-max must be a whole number of at least 1'); o.lensBytesMax = Number(v); }
    else if (a === '--no-sidecar') o.noSidecar = true;
    else if (a === '--seat-skill') o.seatSkills.push(val());
    else if (a === '--on-seat-skill-failure') { o.onSeatSkillFailure = val(); if (!['fail', 'plain_seat'].includes(o.onSeatSkillFailure)) throw new Error('--on-seat-skill-failure must be fail or plain_seat'); }
    else if (a === '--rounds') o.roundsGiven = val();
    else if (a === '--max-words') o.maxWordsGiven = val();
    else if (a === '--synthesizer') o.synthesizer = val();
    else if (a === '--settings-json') o.settings = val();
    else if (a === '--observer-json') o.observerJson = val();
    else if (a === '--question-sha') o.questionSha = val();
    else if (a === '--hosted-skills') o.hostedSkills = val();
    else if (a === '--skills') o.skills = true; // E3D_SKILLS_V1: add a skills block (resolved id, version, definition_hash, use_id) to the plan, for the receipt
    else if (a.startsWith('--')) throw new Error(`unknown option ${a}`);
    else o.positional.push(a);
  }
  return o;
}

// --builtin-only: a hosted run never reads a folder found on the host, so nothing can override a built-in expert by name.
const tiersOf = (o) => (o.builtinOnly ? [{ name: 'built-in', dir: o.builtin }] : [{ name: 'built-in', dir: o.builtin }, { name: 'user', dir: o.user }, { name: 'repo', dir: o.repo }]);
const oneLine = (e) => (e.metadata['e3d.expert.lens'] || e.description || '').replace(/\s+/g, ' ').slice(0, 100);
const short = (h) => h.replace('sha256:', '').slice(0, 8);

function loadPresets(builtin) {
  const file = builtin && join(builtin, 'panels.json');
  if (!file || !existsSync(file)) return { ok: true, presets: {}, errors: [] };
  let json;
  try { json = JSON.parse(readFileSync(file, 'utf8')); } catch { return { ok: false, presets: {}, errors: ['panels.json is not valid JSON'] }; }
  const v = validatePresets(json);
  return { ok: v.ok, presets: v.ok ? json.presets : {}, errors: v.errors };
}

function cmdList(o) {
  const { experts, errors, overridden } = loadExperts({ tiers: tiersOf(o) });
  const pre = loadPresets(o.builtin);
  const w = Math.max(16, ...experts.map((e) => e.name.length + 1), ...Object.keys(pre.presets).map((id) => id.length + 1));
  console.log(`${'NAME'.padEnd(w)}${'TIER'.padEnd(10)}${'HASH'.padEnd(10)}LENS`);
  for (const e of experts) console.log(`${e.name.padEnd(w)}${e.tier.padEnd(10)}${short(e.hash).padEnd(10)}${oneLine(e)}`);
  if (!experts.length) console.log('(no experts found)');
  if (Object.keys(pre.presets).length) {
    console.log('\nPRESETS');
    for (const [id, p] of Object.entries(pre.presets)) console.log(`${id.padEnd(w)}${p.experts.join(', ')}  (at least ${p.min_seats} seats)`);
  }
  for (const x of overridden) console.error(`note: ${x.name} from ${x.from} is overridden by ${x.by}`);
  for (const x of errors) for (const e of x.errors) console.error(`warning: ${x.tier}/${x.folder}: ${e.code}: ${e.message}`);
  for (const e of pre.errors) console.error(`warning: panels.json: ${e}`);
  return 0;
}

function cmdShow(o) {
  const name = o.positional[0];
  const { experts } = loadExperts({ tiers: tiersOf(o) });
  const e = experts.find((x) => x.name === name);
  if (!e) { console.error(`error: no expert named "${name}" (try --list-specialists)`); return 1; }
  const pool = o.pool ? o.pool.split(',').filter(Boolean) : [];
  let assigned = 'decided when a debate runs, from the providers available';
  if (pool.length) {
    const r = assign({ requests: [{ expert: e }], pool });
    assigned = r.ok ? `${r.seats[0].provider} (from the pool ${pool.join(', ')})` : r.error;
  }
  const models = e.sidecar.models.map((m) => `${m.provider}${m.effort ? ` (effort ${m.effort})` : ''}`).join(', ') || 'none';
  console.log(`Expert:      ${e.name}  (${e.tier}, version ${e.metadata['e3d.expert.version'] ?? 'unset'}, ${e.hash})`);
  console.log(`Description: ${e.description.replace(/\s+/g, ' ')}`);
  console.log(`License:     ${e.license ?? 'not stated'}`);
  console.log('Tools:       none');
  console.log(`Word limit:  ${e.sidecar.limits.max_words ?? 'not set'} (advisory in Phase 1; the debate's own --max-words still applies)`);
  console.log(`Model hints: ${models} (a tie-break only: the engine assigns the provider)`);
  console.log(`Provider:    ${assigned}`);
  console.log('Price:       not shown. A local run is not priced.');
  for (const w of e.warnings) console.log(`Warning:     ${w.code}: ${w.message}`);
  console.log('\n--- the exact text a seat receives, before the question ---');
  process.stdout.write(lensBlock(e));
  return 0;
}

function cmdValidate(o) {
  const dir = o.positional[0];
  if (!dir) { console.error('error: validate needs a folder'); return 2; }
  const abs = resolve(dir);
  const r = validateFolder(abs, { root: dirname(abs) });
  for (const w of r.warnings) console.log(`warning: ${w.code}: ${w.message}${w.file ? ` (${w.file})` : ''}`);
  for (const e of r.errors) console.log(`error: ${e.code}: ${e.message}${e.file ? ` (${e.file})` : ''}`);
  if (r.ok) { console.log(`OK: ${r.expert.name} ${r.expert.hash}`); return 0; }
  console.log(`INVALID: ${r.errors.length} error${r.errors.length === 1 ? '' : 's'}`);
  return 1;
}

function copyTree(src, dst, { skipSidecar }) {
  mkdirSync(dst, { recursive: true });
  for (const name of readdirSync(src).sort()) {
    if (name === '.git' || name === '.DS_Store') continue;
    if (skipSidecar && name === 'e3d') continue;
    const s = join(src, name);
    const st = lstatSync(s);
    if (st.isDirectory()) copyTree(s, join(dst, name), { skipSidecar: false });
    else if (st.isFile()) copyFileSync(s, join(dst, name));
  }
}

function cmdExport(o) {
  const [name, outdir] = o.positional;
  if (!name || !outdir) { console.error('error: export needs an expert name and an output folder'); return 2; }
  const { experts } = loadExperts({ tiers: tiersOf(o) });
  const e = experts.find((x) => x.name === name);
  if (!e) { console.error(`error: no expert named "${name}"`); return 1; }
  const target = join(resolve(outdir), e.name);
  if (existsSync(target)) { console.error(`error: ${target} already exists; nothing was copied`); return 1; }
  copyTree(e.dir, target, { skipSidecar: o.noSidecar });
  const r = validateFolder(target, { root: resolve(outdir) });
  if (!r.ok) { for (const x of r.errors) console.error(`error: ${x.code}: ${x.message}`); return 1; }
  console.log(`exported ${e.name} to ${target}${o.noSidecar ? ' (without the e3d/ sidecar)' : ''}`);
  console.log(`${r.expert.hash}`);
  return 0;
}

function fail(error) { console.log(JSON.stringify({ ok: false, error })); return 1; }

// A seat whose skill failed and which may run plain: it still takes a provider (assign needs an expert-shaped request) but sends no lens.
const placeholderExpert = (i) => ({ name: `skill-failed-${i + 1}`, description: '', lens: '', hash: `sha256:${'0'.repeat(64)}`, tier: 'built-in', metadata: {}, sidecar: { tasks: [], models: [], tools: 'none', limits: {} }, warnings: [], placeholder: true });

function cmdPlan(o) {
  if (o.panel && (o.specialists.length || o.seatSkills.length)) return fail('use --panel or --specialist/--seat-skill, not both');
  if (!o.panel && !o.specialists.length && !o.seatSkills.length) return fail('name a panel (--panel) or experts (--specialist, --seat-skill)');
  if (o.seatSkills.length && !skillsOn) return fail('--seat-skill needs E3D_SKILLS_V1=1');
  // request values come from the user and are checked properly later by the debate itself; here a bad one never makes the PLAN fail (the debate gives its own error)
  const reqWarnings = [];
  const intIn = (raw, def, lo, hi, what) => { if (raw === null) return def; if (/^[0-9]{1,7}$/.test(raw) && Number(raw) >= lo && Number(raw) <= hi) return Number(raw); reqWarnings.push(`${what} "${String(raw).replace(/[^\x20-\x7E]/g, '?').slice(0, 20)}" is outside what the preview can describe; the plan digest uses ${def}`); return def; };
  o.rounds = intIn(o.roundsGiven, 2, 1, 100000, '--rounds');
  o.maxWords = intIn(o.maxWordsGiven, 200, 1, 1000000, '--max-words');
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(o.synthesizer)) { reqWarnings.push('the synthesizer name is outside what the preview can describe; the plan digest uses "unspecified"'); o.synthesizer = 'unspecified'; }
  let settings = skillsOn ? { ...skillsPlan.DEFAULT_SETTINGS } : null;
  if (skillsOn && o.settings) {
    try { const j = JSON.parse(o.settings); for (const k of Object.keys(skillsPlan.DEFAULT_SETTINGS)) if (Object.hasOwn(j, k) && typeof j[k] === typeof settings[k]) settings[k] = j[k]; } catch { reqWarnings.push('the digest settings could not be read; defaults are used'); }
  }
  const pool = (o.pool || '').split(',').filter(Boolean);
  if (pool.length < 1) return fail('at least one usable provider is needed to debate');
  const { experts, errors } = loadExperts({ tiers: tiersOf(o) });
  const byName = new Map(experts.map((e) => [e.name, e]));
  let catalogue = skillsOn ? skillsDef.loadSkills({ tiers: tiersOf(o) }) : null;
  // hosted skills of this run (E3D_SKILLS_HOSTED): refused unless the run reads built-in folders only; every definition goes through the intake checks
  if (o.hostedSkills) {
    if (!skillsOn) return fail('--hosted-skills needs E3D_SKILLS_V1=1');
    if (!o.builtinOnly) return fail('--hosted-skills needs --builtin-only: a hosted run never reads a folder found on the host');
    if (o.onSeatSkillFailure === 'plain_seat') return fail('--hosted-skills does not allow --on-seat-skill-failure plain_seat: a skill that cannot run refuses the run before any call');
    const h = skillsHosted.addHosted(catalogue, o.hostedSkills);
    if (!h.ok) return fail(`${h.error.code}: ${h.error.message}`);
    catalogue = h.catalogue;
  }
  const noted = (w) => (skillsOn ? w.replace(/[^\x20-\x7E]/g, '?').slice(0, 300) : w); // hostile folder names never carry control characters into a person's terminal
  const warnings = errors.flatMap((x) => x.errors.map((e) => `${x.tier}/${x.folder}: ${e.code}: ${e.message}`));
  warnings.push(...reqWarnings);
  let requests; let minSeats = 2; let isPreset = false; let presetId = null; let failure = null;
  const missing = (n) => {
    const bad = errors.find((x) => x.folder === n);
    return bad ? `expert ${n} is invalid (${bad.errors.map((e) => e.code).join(', ')}); run --validate-specialist on its folder` : `no expert named "${n}" (try --list-specialists)`;
  };
  if (o.panel) {
    const pre = loadPresets(o.builtin);
    if (!pre.ok) return fail(`panels.json is invalid: ${pre.errors.join('; ')}`);
    const p = pre.presets[o.panel];
    if (!p) return fail(`no preset named "${o.panel}" (known: ${Object.keys(pre.presets).join(', ') || 'none'})`);
    isPreset = true; presetId = o.panel; minSeats = p.min_seats;
    requests = [];
    for (const n of p.experts) { if (!byName.has(n)) return fail(`preset ${o.panel} names ${missing(n)}`); requests.push({ expert: byName.get(n), override: null, source: 'preset' }); }
  } else {
    requests = [];
    const seen = new Set();
    for (const a of o.specialists) {
      const r = parseSpecialistArg(a);
      if (!r) return fail(`"${a}" is not name or name:provider`);
      if (seen.has(r.name)) return fail(`${r.name} was named twice; one expert sits on one provider`);
      seen.add(r.name);
      if (!byName.has(r.name)) return fail(missing(r.name));
      requests.push({ expert: byName.get(r.name), override: r.override, source: 'specialist' });
    }
    // seat skills (E3D_SKILLS_V1, E3D_SKILLS_SEATS): by id or name, with an optional version and hash pin. A skill that cannot be used stops the run before any
    // call, unless --on-seat-skill-failure plain_seat says its seat may run plain (never silently: the receipt and the preview say so).
    o.seatSkills.forEach((spec, i) => {
      const r = skillsPlan.resolveSeatSkill(catalogue, spec);
      if (!r.ok) {
        const parsed = skillsPlan.parseSeatSkill(spec);
        if (o.onSeatSkillFailure === 'plain_seat' && parsed) { requests.push({ expert: placeholderExpert(i), override: parsed.override, source: 'seat-skill', failure: r.error }); return; }
        failure = `${r.error.code}: ${r.error.message}`; return;
      }
      if (seen.has(r.expert.name)) { failure = `${r.expert.name} was named twice; one skill sits on one provider`; return; }
      seen.add(r.expert.name);
      requests.push({ expert: r.expert, override: r.override, source: 'seat-skill' });
    });
    if (failure) return fail(failure);
    if (requests.every((q) => q.expert.placeholder)) return fail(`every skill named with --seat-skill failed (${requests.map((q) => q.failure.code).join(', ')}); no seat would carry a skill, so nothing is run`);
    // One named skill is enough with --fill-pool (a hosted run): the other seats of the pool run plain, by design. Two are needed without it.
    // Named experts (--specialist) keep the two-expert rule: --fill-pool does not relax it.
    const oneSkillFilled = o.fillPool && requests.length === 1 && o.seatSkills.length === 1 && o.specialists.length === 0;
    if (requests.length < 2 && !oneSkillFilled) return fail('name at least two experts to debate');
  }
  if ((o.fillPool || o.pins.length || o.lensBytesMax !== null) && !o.specialists.length && !o.seatSkills.length) return fail('--fill-pool, --expert-pin and --lens-bytes-max apply to --specialist and --seat-skill experts');
  const pinned = new Map();
  for (const x of o.pins) {
    const m = /^([a-z0-9]+(?:-[a-z0-9]+)*)=(sha256:[0-9a-f]{64})$/.exec(x);
    if (!m) return fail('--expert-pin must be name=sha256:<64 hex characters>');
    if (pinned.has(m[1])) return fail(`${m[1]} is pinned twice`);
    pinned.set(m[1], m[2]);
  }
  for (const [n, h] of pinned) {
    const r = requests.find((q) => q.expert.name === n);
    if (!r) return fail(`${n} is pinned but not named with --specialist`);
    if (r.expert.hash !== h) return fail(`expert ${n} does not match its pinned content hash (the text of this expert changed); nothing was run`);
  }
  if (o.lensBytesMax !== null) {
    for (const { expert } of requests) if (!expert.placeholder && Buffer.byteLength(lensBlock(expert)) > o.lensBytesMax) return fail(`the lens block of ${expert.name} is larger than the limit of ${o.lensBytesMax} bytes`);
  }
  const a = assign({ requests, pool, isPreset, minSeats });
  if (!a.ok) return fail(a.error);
  // --fill-pool: one seat per provider and no more. More experts than providers would share a provider; refuse rather than add or hide seats.
  if (o.fillPool && a.seats.some((s) => s.seat !== s.provider)) return fail(`${requests.length} experts were named for ${pool.length} provider${pool.length === 1 ? '' : 's'}; a hosted panel puts one expert on each provider`);
  const plain = o.fillPool ? pool.filter((p) => !a.seats.some((s) => s.provider === p)) : [];
  const independence = independenceOf([...a.seats, ...plain.map((p) => ({ provider: p }))]);
  if (independence.families < o.minFamilies) {
    return fail(`this panel has ${independence.seats} seats on ${independence.families} vendor ${independence.families === 1 ? 'family' : 'families'} (${[...new Set(a.seats.map((s) => s.provider))].join(', ')}), fewer than --min-families ${o.minFamilies}; make a provider from another vendor available, or pass --min-families ${independence.families} to run lenses on one vendor deliberately (the lenses differ, the model does not)`);
  }
  const allSeats = a.seats.map((s, k) => ({
    seat: s.seat, // the seat id: the adapter name for the first seat on an adapter, adapter.2, adapter.3 after that
    adapter: s.provider,
    name: s.expert.name,
    version: s.expert.metadata['e3d.expert.version'] ?? null,
    content_hash: s.expert.hash,
    tier: s.expert.tier,
    effort_requested: s.effort_requested,
    effort_applied: false, // no adapter exposes an effort setting yet; the receipt says so rather than implying it
    hint_used: s.hint_used,
    override: s.override,
    _expert: s.expert, _source: requests[k]?.source ?? 'specialist', _failure: requests[k]?.failure ?? null,
  }));
  const seats = allSeats.filter((s) => !s._expert.placeholder).map(({ _expert, _source, _failure, ...rest }) => rest);
  const failedPlain = allSeats.filter((s) => s._expert.placeholder).map((s) => ({ seat: s.seat, adapter: s.adapter, expert: null, skill_failed: { code: s._failure.code, message: s._failure.message } }));
  for (const s of a.seats) for (const w of s.expert.warnings) warnings.push(`${s.expert.name}: ${w.code}: ${w.message}`);
  for (const f of failedPlain) warnings.push(`seat ${f.seat} runs plain: its skill failed (${f.skill_failed.code}: ${f.skill_failed.message})`);
  const plainSeats = [...plain.map((p) => ({ seat: p, adapter: p, expert: null })), ...failedPlain];
  const out = {
    ok: true,
    providers: [...allSeats.map((s) => s.seat), ...plain],
    lens: { ...Object.fromEntries(a.seats.map((s) => [s.seat, s.expert.placeholder ? '' : lensBlock(s.expert)])), ...Object.fromEntries(plain.map((p) => [p, ''])) },
    // plain seats (--fill-pool, or a seat whose skill failed under plain_seat) hold no expert: an empty lens, expert null; the key is absent otherwise
    panel: { preset: presetId, dropped: a.dropped, independence, experts: seats, ...(o.fillPool || failedPlain.length ? { plain_seats: plainSeats } : {}) },
    warnings: skillsOn ? warnings.map(noted) : warnings,
  };
  let observers = []; let observerWarnings = [];
  if (o.skills && o.observerJson) {
    try { const j = JSON.parse(o.observerJson); const x = j.observer; observers = [{ skill: x.skill, hook: 'after_synthesis', adapter: x.adapter, family: x.family, max_output_bytes: x.max_output_bytes, timeout_ms: x.timeout_ms }]; observerWarnings = (j.warnings ?? []).map((w) => `observer: ${w}`); } catch { observerWarnings = ['the observer plan could not be read; the preview omits it']; }
  }
  if (o.skills) {
    const real = allSeats.filter((s) => !s._expert.placeholder);
    out.skills = [
      ...skillsReceipt.skillReceiptEntries(real.map((s) => ({ seat: s.seat, expert: s._expert, source: s._source })), catalogue),
      ...allSeats.filter((s) => s._expert.placeholder).map((s) => ({ seat: s.seat, hook: 'seat_prompt', scope: 'debate_seat', source: s._source, status: 'failed', code: s._failure.code })),
    ];
    out.preview = skillsPlan.buildPreview({
      seats: real.map((s) => ({ seat: s.seat, adapter: s.adapter, expert: s._expert, source: s._source, hint_used: s.hint_used, override: s.override })),
      plain: [...plain.map((p) => ({ seat: p, adapter: p, reason: 'fill_pool', code: null })), ...failedPlain.map((f) => ({ seat: f.seat, adapter: f.adapter, reason: 'skill_failed', code: f.skill_failed.code }))],
      rounds: o.rounds, maxWords: o.maxWords, synthesizer: o.synthesizer, questionSha256: o.questionSha, settings, catalogue, observers, warnings: [...warnings, ...observerWarnings],
    });
  }
  console.log(JSON.stringify(out));
  return 0;
}

const cmd = process.argv[2];
let o;
try { o = parse(process.argv.slice(3)); } catch (e) { console.error(`error: ${e.message}`); process.exit(2); }
const table = { list: cmdList, show: cmdShow, validate: cmdValidate, export: cmdExport, plan: cmdPlan };
if (!table[cmd]) { console.error(`usage: specialists-cli.mjs ${Object.keys(table).join('|')} ...`); process.exit(2); }
try { process.exit(table[cmd](o)); } catch (e) { console.error(`error: ${e.message}`); process.exit(2); }
