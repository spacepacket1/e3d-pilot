#!/usr/bin/env bash
# Experts, Phase 1.3: the eight built-in experts and three presets in lib/specialists (docs/specs/experts-phase1-private-experts-spec.md section 7).
# Reads the real catalogue; the stub debates use fake provider adapters, so no model and no network are involved.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/fixtures/specialists/harness.sh"
TMPS=()
trap 'for d in "${TMPS[@]}"; do rm -rf "$d"; done' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
NAMES=(skeptic premortem customer compliance implementer architect facilitator factchecker)
CLI="$ROOT/lib/debate/specialists-cli.mjs"
H="$(mktemp -d)"; TMPS+=("$H")

# ---- every expert is present, valid, MIT, tools none, and makes no measured claim ----
list="$(E3D_SPECIALISTS=1 HOME="$H" "$ROOT/bin/e3d-debate" --list-specialists 2>/dev/null)"
for n in "${NAMES[@]}"; do
  grep -q "^$n .*built-in" <<< "$list" || fail "$n is missing from --list-specialists"
  out="$(node "$CLI" validate "$ROOT/lib/specialists/$n")" || fail "$n does not validate: $out"
  grep -q "^OK: $n sha256:" <<< "$out" || fail "$n: unexpected validate output: $out"
  ! grep -q '^warning:' <<< "$out" || fail "$n validates with a warning: $out"
done
node --input-type=module - "$ROOT" "${NAMES[@]}" <<'NODE'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
const [, , root, ...names] = process.argv;
const { validateFolder: validate } = await import(join(root, 'lib/debate/specialists.mjs'));
const VOCAB = new Set(['decide', 'review-spec', 'review-diff', 'find-gaps', 'forecast', 'ideate', 'write', 'judge']);
const HINTED = { skeptic: ['grok-build', 'claude'], implementer: ['codex'] }; // the only two backed by an observation (README)
for (const n of names) {
  const dir = join(root, 'lib/specialists', n);
  const r = validate(dir, { root: join(root, 'lib/specialists') });
  assert.equal(r.ok, true, `${n}: ${JSON.stringify(r.errors)}`);
  const e = r.expert;
  assert.equal(e.license, 'MIT', `${n}: license`);
  assert.equal(e.metadata['e3d.expert.schema'], 'expert/v1', `${n}: schema`);
  assert.equal(e.metadata['e3d.expert.version'], '1', `${n}: version`);
  assert.ok(e.metadata['e3d.expert.lens'], `${n}: lens summary`);
  assert.equal(e.sidecarPresent, true, `${n}: sidecar`);
  assert.equal(e.sidecar.tools, 'none', `${n}: tools`);
  assert.ok(e.sidecar.tasks.length >= 1 && e.sidecar.tasks.every((t) => VOCAB.has(t)), `${n}: tasks ${JSON.stringify(e.sidecar.tasks)}`);
  const hints = e.sidecar.models.map((m) => m.provider);
  assert.deepEqual(hints, HINTED[n] ?? [], `${n}: model hints must be limited to the two backed by an observation`);
  const text = readFileSync(join(dir, 'SKILL.md'), 'utf8');
  assert.equal(/\b(measured|proven|benchmark|best at|guarantee)/i.test(text), false, `${n}: a SKILL.md must not claim a track record`);
}
console.log('catalogue fields: ok');
NODE

# ---- presets: four seats, minimum three, only real experts, and the README table agrees with them ----
node --input-type=module - "$ROOT" "${NAMES[@]}" <<'NODE'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
const [, , root, ...names] = process.argv;
const panels = JSON.parse(readFileSync(join(root, 'lib/specialists/panels.json'), 'utf8'));
assert.equal(panels.schema, 'panels/v1');
assert.deepEqual(Object.keys(panels.presets).sort(), ['gap-finding', 'risk-review', 'spec-review']);
const used = new Map(names.map((n) => [n, []]));
for (const [id, p] of Object.entries(panels.presets)) {
  assert.equal(p.experts.length, 4, `${id}: four seats, matching Pilot's four-vendor council`);
  assert.equal(p.min_seats, 3, `${id}: min_seats`);
  for (const n of p.experts) { assert.ok(used.has(n), `${id} names ${n}, which is not in the catalogue`); used.get(n).push(id); }
}
const readme = readFileSync(join(root, 'lib/specialists/README.md'), 'utf8');
for (const n of names) {
  const row = readme.split('\n').find((l) => l.startsWith(`| \`${n}\` |`));
  assert.ok(row, `README has no row for ${n}`);
  const cell = row.split('|')[3].trim().split(',').map((s) => s.trim()).sort();
  assert.deepEqual(cell, used.get(n).sort(), `README presets for ${n} disagree with panels.json`);
  assert.ok(used.get(n).length >= 1, `${n} is in no preset`);
}
console.log('presets: ok');
NODE

# ---- every preset runs in a stub debate and each seat receives its own lens, once ----
declare -a MARKS=("skeptic:find the strongest reason this should NOT be done" "premortem:Assume this shipped and failed" "customer:You are the person who would use or pay" "compliance:Review as a compliance and security officer" "implementer:You will implement this tomorrow" "architect:Review the design for coupling" "facilitator:list the 3 questions a careful person" "factchecker:say TRUE, FALSE or UNVERIFIABLE")
mark_of() { local m; for m in "${MARKS[@]}"; do [[ "${m%%:*}" == "$1" ]] && { printf '%s' "${m#*:}"; return; }; done; }
PROVS=(claude codex gemini grok-build)
for preset in risk-review spec-review gap-finding; do
  T="$(mktemp -d)"; TMPS+=("$T")
  build_root "$T" "$ROOT/bin/e3d-debate" v2 "${PROVS[@]}"
  cp -R "$ROOT/lib/specialists/." "$T/lib/specialists/"
  rc=0; env -u TYPESAFE_API_KEY E3D_SPECIALISTS=1 HOME="$T/home" "$T/bin/e3d-debate" "q?" --panel "$preset" --providers claude,codex,gemini,grok-build --rounds 2 --synthesizer synth --out-dir "$T/out" > "$T/stdout" 2> "$T/stderr" || rc=$?
  [[ $rc -eq 0 ]] || fail "$preset: the debate failed: $(cat "$T/stderr")"
  [[ "$(jq '.panel.experts | map(.seat) | unique | length' "$T/out/decision-log.json")" == 4 ]] || fail "$preset: four experts must sit on four providers"
  while IFS=$'\t' read -r name seat; do
    mark="$(mark_of "$name")"
    for k in 0 1; do
      f="$T/seen-$seat-$k.md"
      [[ "$(grep -c -F -- "$mark" "$f")" == 1 ]] || fail "$preset: $name on $seat round $((k + 1)) must carry its own lens exactly once"
      for other in "${NAMES[@]}"; do [[ "$other" == "$name" ]] || ! grep -q -F -- "$(mark_of "$other")" "$f" || fail "$preset: $name on $seat saw the $other lens"; done
    done
  done < <(jq -r '.panel.experts[] | [.name, .seat] | @tsv' "$T/out/decision-log.json")
  grep -q 'Your role in this debate' "$T/seen-synth.md" && fail "$preset: the synthesis saw a lens"
done

# ---- the docs match the product ----
for t in "E3D_SPECIALISTS=1" "risk-review" "spec-review" "gap-finding" "--show-specialist" "--export-specialist" "allowed-tools" "never run"; do grep -q -F -- "$t" "$ROOT/docs/experts.md" || fail "docs/experts.md does not mention $t"; done
grep -q 'docs/experts.md' "$ROOT/README.md" || fail "README.md should point to docs/experts.md"
echo "specialists-catalogue: PASS"
