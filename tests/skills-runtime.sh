#!/usr/bin/env bash
# Skills phase 2b: the local skills runtime (lib/skills, the --*-skill commands of bin/e3d-debate, the skills block of the receipt, and the
# e3d_*_skill MCP tools). No model, no network: fixtures are built in temp directories and the debate uses the stub adapters of the expert tests.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures/specialists"
source "$FIX/harness.sh"
TMPS=()
cleanup() { for d in "${TMPS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
newroot() { local T; T="$(mktemp -d)"; TMPS+=("$T"); printf '%s' "$T"; }

# 1. the library cases (hashing, projection, native folders, tiers, export, diff, receipt entries, MCP tools)
node "$ROOT/tests/fixtures/skills/runtime.mjs" || fail "library cases"

# 2. the built-in projections are pinned
T="$(newroot)"; node "$ROOT/tests/fixtures/skills/projection-snapshot.mjs" > "$T/p.json"
diff -u "$ROOT/tests/fixtures/skills/projection-baseline.json" "$T/p.json" >&2 || fail "a built-in projection changed; if on purpose, regenerate projection-baseline.json and say so in the PR"
echo "skills-runtime 2 (projections pinned): ok"

# 3. the switch and the commands of bin/e3d-debate
T="$(newroot)"; build_root "$T" "$ROOT/bin/e3d-debate" v2 alpha beta
sk() { local es="$1"; shift; env -u E3D_SKILLS_V1 -u E3D_SPECIALISTS ${es:+E3D_SKILLS_V1=$es} HOME="$T/home" "$ROOT/bin/e3d-debate" "$@" > "$T/stdout" 2> "$T/stderr"; }
for es in "" 0; do
  for flag in "--list-skills" "--show-skill skeptic" "--validate-skill /nonexistent" "--project-expert skeptic" "--export-skill skeptic $T/o" "--diff-skill skeptic skeptic"; do
    rc=0; sk "$es" $flag || rc=$?; [[ $rc -eq 1 ]] || fail "E3D_SKILLS_V1='$es' $flag: expected exit 1, got $rc"
    grep -q 'skills are off' "$T/stderr" || fail "E3D_SKILLS_V1='$es' $flag: message missing"
  done
done
rc=0; sk maybe --list-skills || rc=$?; [[ $rc -eq 2 ]] || fail "an invalid E3D_SKILLS_V1 must refuse to start (exit 2), got $rc"
rc=0; sk maybe "q?" --providers alpha,beta --synthesizer synth --out-dir "$T/o2" || rc=$?; [[ $rc -eq 2 ]] || fail "an invalid E3D_SKILLS_V1 refuses even with no skills flag, got $rc"
rc=0; sk 1 --skill-version 1.0.0 || rc=$?; [[ $rc -eq 1 ]] || fail "--skill-version alone must be refused"
cp -R "$ROOT/lib/specialists/." "$T/lib/specialists/"
sk 1 --list-skills || fail "--list-skills failed: $(cat "$T/stderr")"
[[ "$(grep -c '^skill\.e3d\.' "$T/stdout")" == 10 ]] || fail "--list-skills must show the ten built-in skills"
sk 1 --show-skill skeptic --skill-version 1.0.0 || fail "--show-skill with the right version failed"
jq -e '.definition.id == "skill.e3d.skeptic" and .tier == "built-in"' "$T/stdout" >/dev/null || fail "--show-skill output"
rc=0; sk 1 --show-skill skeptic --skill-version 9.9.9 || rc=$?; [[ $rc -eq 1 ]] || fail "a wrong pinned version must fail"; grep -q skill_version_invalid "$T/stderr" || fail "skill_version_invalid missing"
rc=0; sk 1 --show-skill skeptic --skill-hash "sha256:$(printf 'f%.0s' {1..64})" || rc=$?; [[ $rc -eq 1 ]] || fail "a wrong pinned hash must fail"; grep -q skill_hash_mismatch "$T/stderr" || fail "skill_hash_mismatch missing"
rc=0; sk 1 --show-skill skeptic --skill-hash "" || rc=$?; [[ $rc -eq 1 ]] || fail "an empty pin must be refused, not dropped (S6)"
rc=0; sk 1 --show-skill skeptic --skill-version 1 || rc=$?; [[ $rc -eq 1 ]] || fail "a malformed version pin must be refused"
rc=0; sk 1 --show-skill skeptic --skill-hash sha256:xyz || rc=$?; [[ $rc -eq 1 ]] || fail "a malformed hash pin must be refused"
rc=0; sk 1 --list-skills --skill-hash "sha256:$(printf 'a%.0s' {1..64})" || rc=$?; [[ $rc -eq 1 ]] || fail "a pin with --list-skills must be refused"
rc=0; sk 1 --show-skill || rc=$?; [[ $rc -eq 1 ]] || fail "--show-skill with no value must say so"; grep -q 'needs a value' "$T/stderr" || fail "missing-value message"
rc=0; sk 1 --show-skill --hash || rc=$?; [[ $rc -eq 1 ]] || fail "a value that looks like an option is a name, not an option"; grep -q 'skill_not_found' "$T/stderr" || fail "skill_not_found for an option-like value"; ! grep -q "$ROOT" "$T/stderr" || fail "the engine path must not appear in that message"
rc=0; sk 1 --show-skill nonesuch || rc=$?; [[ $rc -eq 1 ]] || fail "an unknown skill must fail"; grep -q skill_not_found "$T/stderr" || fail "skill_not_found missing"
sk 1 --project-expert skeptic || fail "--project-expert failed"
jq -e '.projectable == true and .definition.provenance.source_format == "expert-v1-projection"' "$T/stdout" >/dev/null || fail "--project-expert output"
sk 1 --export-skill skeptic "$T/exp" || fail "--export-skill failed: $(cat "$T/stderr")"
[[ -f "$T/exp/skeptic/SKILL.md" && -f "$T/exp/skeptic/e3d/skill.json" ]] || fail "the exported folder is incomplete"
rc=0; sk 1 --export-skill skeptic "$T/exp" || rc=$?; [[ $rc -eq 1 ]] || fail "exporting over an existing folder must fail"
sk 1 --validate-skill "$T/exp/skeptic" || fail "the exported folder must validate: $(cat "$T/stderr")"
grep -q '^definition_hash: sha256:' "$T/stdout" || fail "--validate-skill prints the hash"
rc=0; sk 1 --diff-skill skeptic "$T/exp/skeptic" || rc=$?; [[ $rc -eq 3 ]] || fail "a local copy has a different hash: exit 3, got $rc"
rc=0; sk 1 --diff-skill skeptic skeptic || rc=$?; [[ $rc -eq 0 ]] || fail "a skill against itself is identical: exit 0, got $rc"
# S7: a bare word is a skill, never a folder in the current directory
mkdir -p "$T/cwd"
cwd_run() { ( cd "$T/cwd" && env -u E3D_SPECIALISTS E3D_SKILLS_V1=1 HOME="$T/home" "$ROOT/bin/e3d-debate" "$@" > "$T/stdout" 2> "$T/stderr" ); }
cwd_run --export-skill skeptic . || fail "export into the current directory"
[[ -d "$T/cwd/skeptic" ]] || fail "the export went to ./skeptic"
rc=0; cwd_run --diff-skill skeptic skeptic || rc=$?; [[ $rc -eq 0 ]] || fail "a bare name is the built-in skill, not ./skeptic: expected identical (exit 0), got $rc"
cwd_run --project-expert skeptic || fail "project by name"; jq -e '.definition.id == "skill.e3d.skeptic"' "$T/stdout" >/dev/null || fail "--project-expert skeptic must project the built-in, not ./skeptic"
rc=0; cwd_run --diff-skill skeptic ./skeptic || rc=$?; [[ $rc -eq 3 ]] || fail "./skeptic is the local copy: exit 3, got $rc"
echo "skills-runtime 3 (commands): ok"

# 4. the receipt: a skills block only with E3D_SKILLS_V1=1; nothing else in the log changes
mkexp() {
  local T="$1" n="$2"
  mkdir -p "$T/lib/specialists/$n"
  printf -- '---\nname: %s\ndescription: The %s lens. Use it in tests.\nlicense: MIT\nmetadata:\n  e3d.expert.version: "2"\n---\nLENS-%s-MARK.\n' "$n" "$n" "$n" > "$T/lib/specialists/$n/SKILL.md"
}
T="$(newroot)"; build_root "$T" "$ROOT/bin/e3d-debate" v2 alpha beta; mkexp "$T" skeptic; mkexp "$T" premortem
run() { local sv="$1"; shift; env -u TYPESAFE_API_KEY -u E3D_SKILLS_V1 ${sv:+E3D_SKILLS_V1=$sv} E3D_SPECIALISTS=1 HOME="$T/home" "$T/bin/e3d-debate" "$@" > "$T/stdout" 2> "$T/stderr"; }
rm -rf "$T/out"; run "" "q?" --providers alpha,beta --rounds 1 --synthesizer synth --specialist skeptic --specialist premortem --out-dir "$T/out" || fail "off run failed: $(cat "$T/stderr")"
jq -e 'has("skills") | not' "$T/out/decision-log.json" >/dev/null || fail "no skills key without E3D_SKILLS_V1"
jq -S 'del(.ts, .seconds)' "$T/out/decision-log.json" > "$T/off.json"
rm -rf "$T/out"; run 1 "q?" --providers alpha,beta --rounds 1 --synthesizer synth --specialist skeptic --specialist premortem --out-dir "$T/out" || fail "on run failed: $(cat "$T/stderr")"
jq -e '.skills | length == 2' "$T/out/decision-log.json" >/dev/null || fail "two skills expected"
jq -e '.skills | map(.id) | sort == ["skill.e3d.premortem", "skill.e3d.skeptic"]' "$T/out/decision-log.json" >/dev/null || fail "the skills block names the two skills by id"
jq -e '.skills | all(.definition_hash | test("^sha256:[0-9a-f]{64}$")) and all(.use_id | test("^use_[0-9a-f]{20}$")) and all(.version == "2.0.0")' "$T/out/decision-log.json" >/dev/null || fail "skills entries must carry a definition_hash, a use_id and the projected version"
[[ "$(jq '[.skills[].use_id] | unique | length' "$T/out/decision-log.json")" == 2 ]] || fail "each use gets its own use_id"
jq -S 'del(.ts, .seconds, .skills, .skills_plan_digest)' "$T/out/decision-log.json" | diff -u "$T/off.json" - >/dev/null || fail "with the flag on, the rest of the decision log must be unchanged"
grep -q 'LENS-skeptic-MARK' "$T/seen-"*.md || fail "the lens must still reach the seats"
echo "skills-runtime 4 (receipt): ok"
echo "skills-runtime: PASS"
