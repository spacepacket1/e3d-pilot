#!/usr/bin/env bash
# Experts, Phase 2a.3: the free rule-based --suggest-panel (docs/specs/experts-phase2a-seats-and-suggest-spec.md section 3).
# No model, no network: the logic is read-only; the script runs it with network tools shimmed to fail.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
H="$(mktemp -d)"; trap 'rm -rf "$H"' EXIT
# Shims that fail loudly: any curl/wget/nc/ssh the suggestion might start is a failure.
mkdir -p "$H/shim"; for c in curl wget nc ssh; do printf '#!/bin/sh\necho "NETWORK-USED %s" >&2\nexit 99\n' "$c" > "$H/shim/$c"; chmod +x "$H/shim/$c"; done
run() { env -u E3D_SPECIALISTS PATH="$H/shim:$PATH" HOME="$H" E3D_SPECIALISTS=1 "$ROOT/bin/e3d-debate" "$@"; }
SUG="$ROOT/lib/specialists/suggest.mjs"

# ---- (1) the rules, directly ----
node --input-type=module - "$ROOT" <<'NODE'
import assert from 'node:assert/strict';
import { join } from 'node:path';
const root = process.argv[2];
const m = await import(join(root, 'lib/specialists/suggest.mjs'));
const table = m.loadTable(); const cat = m.catalogue(); const names = cat.map((e) => e.name);
// every rule target is a real expert, and the fallback is a real preset
for (const r of table.rules) for (const t of Object.keys(r.add)) assert.ok(names.includes(t), `rule ${r.id} targets unknown expert ${t}`);
const panels = JSON.parse((await import('node:fs')).readFileSync(join(root, 'lib/specialists/panels.json'), 'utf8'));
assert.ok(panels.presets[table.fallback_preset], 'fallback preset exists');
// each rule fires on each of its words (alone, upper-case, inside a sentence) and names the word; not inside a longer word
const ADD = (r) => Object.keys(r.add);
for (const r of table.rules) for (const w of r.words) {
  for (const q of [`We discuss ${w} today`, `${w.toUpperCase()}.`, `(${w})`]) {
    const res = m.suggest({ question: q });
    for (const t of ADD(r)) { const e = res.experts.find((x) => x.name === t); const all = m.suggest({ question: q, table: { ...table, council_size: 99 } }).experts.find((x) => x.name === t); assert.ok(all, `${w} (${q}) did not reach ${t}`); assert.ok(all.words.includes(w), `${w} not named for ${t}`); }
  }
  for (const q of [`un${w}ed`, `${w}ing${w}`.replace(/\s/g, ''), `x${w}`, `${w}x`]) {
    const hits = m.suggest({ question: q, table: { ...table, council_size: 99 } }).experts.flatMap((e) => e.words);
    assert.ok(!hits.includes(w), `${w} fired inside ${q}`);
  }
}
const ws = (q, n) => m.suggest({ question: q, table: { ...table, council_size: 99 } }).experts.find((e) => e.name === n)?.words || [];
assert.deepEqual(ws('the planet', 'implementer'), []);   assert.deepEqual(ws('a good relationship', 'skeptic'), []);
assert.deepEqual(ws('Our PLAN', 'implementer'), ['plan']); assert.deepEqual(ws('According   to the study', 'factchecker'), ['study', 'according to']);
assert.deepEqual(ws('we ship', 'premortem'), ['ship']);
// the spec's examples
for (const [q, e] of [['money', 'compliance'], ['regulation', 'compliance'], ['migrate', 'skeptic'], ['migrate', 'premortem'], ['onboarding', 'customer'], ['monorepo', 'architect'], ['requirements', 'implementer'], ['statistics', 'factchecker'], ['brainstorm', 'facilitator'], ['open question', 'facilitator']]) assert.ok(ws(q, e).length, `${q} -> ${e}`);
// ties are stable: catalogue order; same input, same answer
const tie = m.suggest({ question: 'money customer design plan survey options' });
assert.deepEqual(tie.experts.map((e) => e.name), tie.experts.map((e) => e.name).slice().sort((a, b) => names.indexOf(a) - names.indexOf(b)), 'equal scores keep catalogue order');
assert.equal(tie.experts.length, 4, 'council size is 4');
assert.deepEqual(m.suggest({ question: 'money customer design plan survey options' }), tie);
// highest weight wins over catalogue order
assert.equal(m.suggest({ question: 'money legal privacy design' }).experts[0].name, 'compliance');
// low confidence: under 2 experts -> risk-review, not a guess
for (const q of ['hello world', 'security', '']) { const r = m.suggest({ question: q }); assert.equal(r.confidence, 'low'); assert.equal(r.preset, 'risk-review'); }
assert.match(m.suggest({ question: 'security' }).reason, /1 expert matched \(at least 2 needed\)/);
assert.match(m.render('security', m.suggest({ question: 'security' })), /--panel risk-review/);
assert.doesNotMatch(m.render('security', m.suggest({ question: 'security' })), /--specialist/);
// below the weight threshold is low even with 2 experts; at it, medium; never high
assert.equal(m.suggest({ question: 'launch' }).confidence, 'low');
assert.equal(m.suggest({ question: 'launch release migrate deadline money legal privacy security customer pricing users design plan spec estimate survey options' }).confidence, 'medium');
for (const q of ['launch release migrate deadline money legal privacy security customer pricing users design plan spec estimate survey options unclear', 'x', 'ship']) assert.notEqual(m.suggest({ question: q }).confidence, 'high');
assert.ok(!JSON.stringify(table).includes('"high"') && !m.render('ship launch', m.suggest({ question: 'ship launch deadline money' })).toLowerCase().includes('confidence: high'));
// --task: +task_boost for experts whose sidecar lists the task; it reorders but never adds an expert no rule matched
const base = m.suggest({ question: 'design plan' }); const tb = m.suggest({ question: 'design plan', task: 'review-spec' });
assert.equal(tb.experts.length, base.experts.length); assert.ok(tb.experts.every((e) => e.boosted === cat.find((c) => c.name === e.name).sidecar.tasks.includes('review-spec')));
assert.equal(tb.experts[0].total, tb.experts[0].rule_score + table.task_boost);
assert.equal(m.suggest({ question: 'hello', task: 'decide' }).confidence, 'low');
// output: fixed sentence, matched words, a command whose experts all exist
const q = "Should we ship the pricing change to customers before the deadline? It's risky";
const out = m.render(q, m.suggest({ question: q }));
assert.ok(out.includes('Rule-based advice, not a measurement. It matches words; it does not understand your question.'));
assert.match(out, /matched: .*ship/);
const specs = [...out.matchAll(/--specialist (\S+)/g)].map((x) => x[1]); assert.deepEqual(specs, m.suggest({ question: q }).experts.map((e) => e.name), 'the command names exactly the proposed experts, in order'); assert.ok(specs.length >= 2); for (const s of specs) assert.ok(names.includes(s), `${s} is a real expert`);
assert.ok(!/multi-model|accura|better|proven|reliab/i.test(out), 'no claim about quality');
NODE

# ---- (2) the command: runs nothing, same answer twice, rules table, refusals ----
Q='Should we launch the new pricing for our customers before the deadline?'
cd "$H"
run "$Q" --suggest-panel > "$H/a" 2> "$H/ea" || fail "suggest failed: $(cat "$H/ea")"
run "$Q" --suggest-panel > "$H/b" 2>> "$H/ea"; diff "$H/a" "$H/b" >/dev/null || fail "same question gave two answers"
! grep -q NETWORK-USED "$H/ea" || fail "the suggestion used the network"
grep -q 'Rule-based advice, not a measurement. It matches words; it does not understand your question.' "$H/a" || fail "fixed sentence missing"
grep -q 'matched: .*launch' "$H/a" && grep -q 'matched: .*pricing' "$H/a" || fail "matched words not named"
grep -q 'Confidence: medium' "$H/a" || fail "expected medium"; ! grep -qi 'confidence: high' "$H/a" || fail "high confidence printed"
cmd="$(grep -E '^  E3D_SPECIALISTS=1 e3d-debate' "$H/a")"; [[ "$cmd" == *"--specialist "* ]] || fail "no command line"
for s in $(grep -oE -- '--specialist [a-z-]+' <<< "$cmd" | awk '{print $2}'); do [[ -d "$ROOT/lib/specialists/$s" ]] || fail "$s is not an expert"; done
run "hello there" --suggest-panel --task find-gaps > "$H/c"; grep -q 'Confidence: low' "$H/c" && grep -q -- '--panel risk-review' "$H/c" || fail "low confidence fallback"
run "plan the planet relationship" --suggest-panel > "$H/d"; grep -q 'implementer.*matched: plan$' "$H/d" || fail "plan in planet fired or plan missed"
run "x" --suggest-panel --task bogus >/dev/null 2>&1 && fail "bad --task accepted"
[[ -z "$(find "$H" -newer "$H/a" -type f ! -path "$H/shim/*" ! -name 'b' ! -name 'c' ! -name 'd' ! -name 'ea')" ]] || fail "something was written"
run --show-suggest-rules > "$H/r"
node -e 'const t=require(process.argv[1]);const s=require("fs").readFileSync(process.argv[2],"utf8");for(const r of t.rules){if(!s.includes(r.id+":"))process.exit(3);for(const w of r.words)if(!s.includes(w))process.exit(4)}' "$ROOT/lib/specialists/suggest.json" "$H/r" || fail "--show-suggest-rules misses a rule or word"
for a in "x --auto --suggest-panel" "--suggest-panel --auto" "x --auto"; do
  rc=0; run $a > "$H/o" 2> "$H/e" || rc=$?; [[ $rc -eq 2 ]] && grep -q -- '--auto does not exist' "$H/e" && [[ ! -s "$H/o" ]] || fail "--auto was not refused ($a)"
done
for f in "--suggest-panel" "--show-suggest-rules"; do
  rc=0; env -u E3D_SPECIALISTS HOME="$H" "$ROOT/bin/e3d-debate" "q" $f > "$H/o" 2> "$H/e" || rc=$?
  [[ $rc -eq 1 ]] && grep -q 'experts are off' "$H/e" && [[ ! -s "$H/o" ]] || fail "switch off did not refuse $f"
done
rc=0; E3D_SPECIALISTS=0 HOME="$H" "$ROOT/bin/e3d-debate" q --suggest-panel >/dev/null 2>&1 || rc=$?; [[ $rc -eq 1 ]] || fail "E3D_SPECIALISTS=0 did not refuse"

# ---- (3) the logic file uses no network, process or write ----
for w in 'fetch(' 'node:net' 'node:http' 'node:https' 'node:dgram' 'child_process' 'spawn' 'exec(' 'execSync' 'writeFile' 'appendFile' 'mkdir' 'import('; do
  ! grep -qF "$w" "$SUG" || fail "suggest.mjs must not use $w"
done
echo "PASS: experts-suggest"
