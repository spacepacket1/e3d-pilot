// F vs E: one model (claude-haiku-5-5) on three seats. E = three seats, same prompt, no lenses. F = the same three seats with three different lenses
// (skeptic, customer, architect). Round 1 only; each seat's answer is capped (ANTHROPIC_API_MAX_TOKENS) so a seat lists only its top findings.
// Score: an error is caught when ANY seat's answer catches it (the union the coverage model E5 describes). Run: node run.mjs <outdir> <repeats> <token-cap>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { TASKS, caught } from './score.mjs';

const [OUT, REPS, CAP] = [process.argv[2], Number(process.argv[3] ?? 8), Number(process.argv[4] ?? 800000)];
const ROOT = path.resolve(import.meta.dirname, '..', '..');
const SEATS = ['anthropic-api', 'anthropic-api.2', 'anthropic-api.3'];
const LENSES = ['skeptic', 'customer', 'architect'];
fs.mkdirSync(OUT, { recursive: true });

// An engine copy whose anthropic-api adapter logs each call's usage line (the real adapter prints it to stderr).
const ENG = fs.mkdtempSync(path.join(os.tmpdir(), 'fve-engine-'));
fs.cpSync(path.join(ROOT, 'bin'), path.join(ENG, 'bin'), { recursive: true });
fs.cpSync(path.join(ROOT, 'lib'), path.join(ENG, 'lib'), { recursive: true });
fs.renameSync(path.join(ENG, 'lib/providers/anthropic-api'), path.join(ENG, 'lib/providers/anthropic-api.real'));
fs.writeFileSync(path.join(ENG, 'lib/providers/anthropic-api'), `#!/usr/bin/env bash
real="$(dirname "$0")/anthropic-api.real"
err="$(mktemp)"; "$real" "$@" 2>"$err"; rc=$?
[[ -n "\${FVE_USAGE_LOG:-}" ]] && grep -h '^e3d_provider_usage=' "$err" >> "$FVE_USAGE_LOG" 2>/dev/null
grep -v '^e3d_provider_usage=' "$err" >&2 || true; rm -f "$err"; exit $rc
`, { mode: 0o755 });

let seed = 20261102; const rnd = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 2 ** 32);
const shuffle = (a) => { const b = [...a]; for (let i = b.length - 1; i > 0; i--) { const j = Math.floor(rnd() * (i + 1)); [b[i], b[j]] = [b[j], b[i]]; } return b; };
const ask = (id) => spawnSync('node', [path.join(import.meta.dirname, 'ask.mjs'), id], { encoding: 'utf8' }).stdout;
const tokensIn = (f) => (fs.existsSync(f) ? fs.readFileSync(f, 'utf8').split('\n').filter(Boolean).reduce((s, l) => s + (Number(/"tokens":(\d+)/.exec(l)?.[1]) || 0), 0) : 0);

const results = path.join(OUT, 'results.jsonl');
const done = new Set(fs.existsSync(results) ? fs.readFileSync(results, 'utf8').split('\n').filter(Boolean).map((l) => { const r = JSON.parse(l); return `${r.rep}|${r.task}|${r.arm}`; }) : []);
let spent = fs.existsSync(results) ? fs.readFileSync(results, 'utf8').split('\n').filter(Boolean).reduce((s, l) => s + JSON.parse(l).tokens, 0) : 0;

const env = { ...process.env, ANTHROPIC_API_THINKING: 'disabled', ANTHROPIC_API_MAX_TOKENS: '220', ANTHROPIC_API_MODEL: 'claude-haiku-5-5',
  ANTHROPIC_API_KEY_FILE: path.join(os.homedir(), '.config/e3d-pilot/anthropic-api-key'), E3D_DEBATE_SEAT_ADAPTERS: JSON.stringify({ 'anthropic-api.2': 'anthropic-api', 'anthropic-api.3': 'anthropic-api' }) };
delete env.TYPESAFE_API_KEY;

for (let rep = 1; rep <= REPS; rep++) {
  for (const t of shuffle(TASKS)) for (const arm of shuffle(['E', 'F'])) {
    if (done.has(`${rep}|${t.id}|${arm}`)) continue;
    if (spent >= CAP) { console.log(`STOP: token cap ${CAP} reached at ${spent}`); process.exit(0); }
    const dir = path.join(OUT, 'runs', `${rep}-${t.id}-${arm}`); fs.mkdirSync(dir, { recursive: true });
    const usage = path.join(dir, 'usage.log'); fs.rmSync(usage, { force: true });
    const args = [ask(t.id), '--providers', SEATS.join(','), '--rounds', '1', '--web-search', 'off', '--synthesizer', 'anthropic-api', '--out-dir', path.join(dir, 'out')];
    if (arm === 'F') for (const l of LENSES) args.push('--specialist', l);
    const r = spawnSync(path.join(ENG, 'bin/e3d-debate'), args, { env: { ...env, FVE_USAGE_LOG: usage, ...(arm === 'F' ? { E3D_SPECIALISTS: '1' } : {}) }, encoding: 'utf8', timeout: 240000 });
    const tr = fs.existsSync(path.join(dir, 'out/transcript.md')) ? fs.readFileSync(path.join(dir, 'out/transcript.md'), 'utf8') : '';
    const answers = {};
    for (const m of tr.matchAll(/^## Round 1 -- (\S+)\n([\s\S]*?)(?=^## )/gm)) answers[m[1]] = m[2];
    const tok = tokensIn(usage); spent += tok;
    const perSeat = Object.fromEntries(Object.entries(answers).map(([s, a]) => [s, caught(t, [a])]));
    const row = { rep, task: t.id, arm, rc: r.status, seats: Object.keys(answers).length, tokens: tok, union: caught(t, Object.values(answers)), perSeat, panel: (r.stderr.match(/^panel: .*$/m) ?? [''])[0] };
    fs.appendFileSync(results, `${JSON.stringify(row)}\n`);
    console.log(`${rep} ${t.id} ${arm} rc=${r.status} seats=${row.seats} tok=${tok} caught=${Object.values(row.union).filter(Boolean).length}/3  spent=${spent}`);
  }
}
console.log(`DONE spent=${spent}`);
