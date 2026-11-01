#!/usr/bin/env node
// Command front end for experts (docs/specs/experts-phase1-private-experts-spec.md section 4), called by bin/e3d-debate. Zero dependencies.
//
//   list      --builtin D --user D --repo D
//   show      <name> --builtin D --user D --repo D [--pool a,b,c]
//   validate  <dir>
//   export    <name> <outdir> [--no-sidecar] --builtin D --user D --repo D
//   plan      --builtin D --user D --repo D --pool a,b,c (--panel NAME | --specialist name[:provider] ...)   -> JSON on stdout
//
// Nothing here calls a model or the network. Only `export` writes, and only inside the new folder it creates under <outdir>.
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, lstatSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadExperts, validateFolder } from './specialists.mjs';
import { assign, lensBlock, parseSpecialistArg, validatePresets } from './specialists-plan.mjs';

function parse(argv) {
  const o = { positional: [], specialists: [], noSidecar: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => { if (i + 1 >= argv.length) throw new Error(`${a} needs a value`); return argv[++i]; };
    if (a === '--builtin') o.builtin = val();
    else if (a === '--user') o.user = val();
    else if (a === '--repo') o.repo = val();
    else if (a === '--pool') o.pool = val();
    else if (a === '--panel') o.panel = val();
    else if (a === '--specialist') o.specialists.push(val());
    else if (a === '--no-sidecar') o.noSidecar = true;
    else if (a.startsWith('--')) throw new Error(`unknown option ${a}`);
    else o.positional.push(a);
  }
  return o;
}

const tiersOf = (o) => [{ name: 'built-in', dir: o.builtin }, { name: 'user', dir: o.user }, { name: 'repo', dir: o.repo }];
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
  console.log(`${'NAME'.padEnd(16)}${'TIER'.padEnd(10)}${'HASH'.padEnd(10)}LENS`);
  for (const e of experts) console.log(`${e.name.padEnd(16)}${e.tier.padEnd(10)}${short(e.hash).padEnd(10)}${oneLine(e)}`);
  if (!experts.length) console.log('(no experts found)');
  if (Object.keys(pre.presets).length) {
    console.log('\nPRESETS');
    for (const [id, p] of Object.entries(pre.presets)) console.log(`${id.padEnd(16)}${p.experts.join(', ')}  (at least ${p.min_seats} seats)`);
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

function cmdPlan(o) {
  if (o.panel && o.specialists.length) return fail('use --panel or --specialist, not both');
  if (!o.panel && !o.specialists.length) return fail('name a panel (--panel) or experts (--specialist)');
  const pool = (o.pool || '').split(',').filter(Boolean);
  if (pool.length < 2) return fail('at least two usable providers are needed to debate');
  const { experts, errors } = loadExperts({ tiers: tiersOf(o) });
  const byName = new Map(experts.map((e) => [e.name, e]));
  const warnings = errors.flatMap((x) => x.errors.map((e) => `${x.tier}/${x.folder}: ${e.code}: ${e.message}`));
  let requests; let minSeats = 2; let isPreset = false; let presetId = null;
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
    for (const n of p.experts) { if (!byName.has(n)) return fail(`preset ${o.panel} names ${missing(n)}`); requests.push({ expert: byName.get(n), override: null }); }
  } else {
    requests = [];
    const seen = new Set();
    for (const a of o.specialists) {
      const r = parseSpecialistArg(a);
      if (!r) return fail(`"${a}" is not name or name:provider`);
      if (seen.has(r.name)) return fail(`${r.name} was named twice; one expert sits on one provider`);
      seen.add(r.name);
      if (!byName.has(r.name)) return fail(missing(r.name));
      requests.push({ expert: byName.get(r.name), override: r.override });
    }
    if (requests.length < 2) return fail('name at least two experts to debate');
  }
  const a = assign({ requests, pool, isPreset, minSeats });
  if (!a.ok) return fail(a.error);
  const seats = a.seats.map((s) => ({
    seat: s.provider, // the provider adapter the expert sits on (the debate keys its seats by provider)
    name: s.expert.name,
    version: s.expert.metadata['e3d.expert.version'] ?? null,
    content_hash: s.expert.hash,
    tier: s.expert.tier,
    effort_requested: s.effort_requested,
    effort_applied: false, // no adapter exposes an effort setting yet; the receipt says so rather than implying it
    hint_used: s.hint_used,
    override: s.override,
  }));
  for (const s of a.seats) for (const w of s.expert.warnings) warnings.push(`${s.expert.name}: ${w.code}: ${w.message}`);
  console.log(JSON.stringify({
    ok: true,
    providers: seats.map((s) => s.seat),
    lens: Object.fromEntries(a.seats.map((s) => [s.provider, lensBlock(s.expert)])),
    panel: { preset: presetId, dropped: a.dropped, experts: seats },
    warnings,
  }));
  return 0;
}

const cmd = process.argv[2];
let o;
try { o = parse(process.argv.slice(3)); } catch (e) { console.error(`error: ${e.message}`); process.exit(2); }
const table = { list: cmdList, show: cmdShow, validate: cmdValidate, export: cmdExport, plan: cmdPlan };
if (!table[cmd]) { console.error(`usage: specialists-cli.mjs ${Object.keys(table).join('|')} ...`); process.exit(2); }
try { process.exit(table[cmd](o)); } catch (e) { console.error(`error: ${e.message}`); process.exit(2); }
