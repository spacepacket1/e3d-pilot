#!/usr/bin/env bash
# Skills phase 3a: skills on seats (--seat-skill), the plan preview, the plan digest and the failure policy of bin/e3d-debate. Stub adapters copy the prompt file
# they receive, so each case reads exactly what every seat saw. No model, no network.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures/specialists"
source "$FIX/harness.sh"
TMPS=()
cleanup() { for d in "${TMPS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
newroot() { local T; T="$(mktemp -d)"; TMPS+=("$T"); printf '%s' "$T"; }

# 1. the library cases
node "$ROOT/tests/fixtures/skills/plan.mjs" || fail "library cases"

# an engine copy with three stub providers, two built-in experts and one native user skill steered to gamma
T="$(newroot)"; build_root "$T" "$ROOT/bin/e3d-debate" v2 alpha beta gamma
mkexp() { local n="$1"; mkdir -p "$T/lib/specialists/$n"; printf -- '---\nname: %s\ndescription: The %s lens. Use it in tests.\nlicense: MIT\nmetadata:\n  e3d.expert.version: "2"\n---\nLENS-%s-MARK.\n' "$n" "$n" "$n" > "$T/lib/specialists/$n/SKILL.md"; }
mkexp skeptic; mkexp premortem
NAT="$T/home/.config/e3d-pilot/specialists/steered"; mkdir -p "$NAT/e3d"
printf -- '---\nname: steered\ndescription: A native skill for seat tests.\nlicense: MIT\n---\nLENS-STEERED-MARK. Take the opposing view.\n' > "$NAT/SKILL.md"
printf '%s' '{"version":"1.4.0","capability_level":"instructional","hooks":[{"scope":"debate_seat","event":"seat_prompt"}],"input_schema_ref":"e3d://schemas/seat-input/v1","output_schema_ref":"e3d://schemas/seat-output/v1","model_hints":[{"provider":"gamma"}]}' > "$NAT/e3d/skill.json"
# run <env...> -- <args...>: the engine copy with a clean environment of the switches
run() {
  local -a e=(-u TYPESAFE_API_KEY -u E3D_SKILLS_V1 -u E3D_SKILLS_SEATS -u E3D_SPECIALISTS)
  while [[ "$1" != -- ]]; do e+=("$1"); shift; done; shift
  rc=0; rm -f "$T"/seen-* "$T"/count-*
  env "${e[@]}" HOME="$T/home" "$T/bin/e3d-debate" "$@" > "$T/stdout" 2> "$T/stderr" || rc=$?
}
ON=(E3D_SPECIALISTS=1 E3D_SKILLS_V1=1 E3D_SKILLS_SEATS=1)
Q="Should we ship it?"
ARGS=("$Q" --providers alpha,beta,gamma --rounds 1 --synthesizer synth --min-families 1)
nocall() { ! compgen -G "$T/seen-*" >/dev/null && ! compgen -G "$T/count-*" >/dev/null; }

# 2. the switches
run E3D_SPECIALISTS=1 -- "${ARGS[@]}" --specialist skeptic --seat-skill premortem; [[ $rc -eq 1 ]] || fail "--seat-skill with the skills switches off must be refused (exit 1), got $rc"; grep -q 'skills on seats are off' "$T/stderr" || fail "off message"
run E3D_SPECIALISTS=1 E3D_SKILLS_V1=1 -- "${ARGS[@]}" --specialist skeptic --seat-skill premortem; [[ $rc -eq 1 ]] || fail "E3D_SKILLS_V1 without E3D_SKILLS_SEATS must be refused, got $rc"
run E3D_SPECIALISTS=1 E3D_SKILLS_V1=1 E3D_SKILLS_SEATS=maybe -- --list-skills; [[ $rc -eq 2 ]] || fail "an invalid E3D_SKILLS_SEATS refuses to start (exit 2), got $rc"
run E3D_SKILLS_V1=1 E3D_SKILLS_SEATS=1 -- "${ARGS[@]}" --specialist skeptic --seat-skill premortem; [[ $rc -eq 1 ]] || fail "without E3D_SPECIALISTS the experts switch refuses, got $rc"; nocall || fail "nothing may be called when refused"
run "${ON[@]}" -- "${ARGS[@]}" --on-seat-skill-failure plain_seat --specialist skeptic --specialist premortem; [[ $rc -eq 1 ]] || fail "--on-seat-skill-failure without --seat-skill must be refused"
run "${ON[@]}" -- "${ARGS[@]}" --seat-skill skeptic --seat-skill premortem --on-seat-skill-failure sometimes; [[ $rc -eq 1 ]] || fail "a bad failure policy must be refused"
run E3D_SPECIALISTS=1 -- "${ARGS[@]}" --specialist skeptic --specialist premortem --preview-skills; [[ $rc -eq 1 ]] || fail "--preview-skills needs E3D_SKILLS_V1"
run E3D_SPECIALISTS=1 E3D_SKILLS_V1=1 -- --preview-skills; [[ $rc -eq 1 ]] || fail "--preview-skills needs a panel"
run "${ON[@]}" -- "${ARGS[@]}" --specialist skeptic --specialist premortem --expect-plan sha256:xyz; [[ $rc -eq 1 ]] || fail "a malformed --expect-plan must be refused"
echo "skills-plan 2 (the switches): ok"

# 3. the preview: no call, readable and JSON, a stable digest that follows the question
run "${ON[@]}" -- "${ARGS[@]}" --specialist skeptic --seat-skill premortem --seat-skill steered --preview-skills
[[ $rc -eq 0 ]] || fail "--preview-skills failed: $(cat "$T/stderr")"; nocall || fail "a preview must not call any provider"
grep -q '^Skills plan sha256:' "$T/stdout" || fail "the preview starts with the plan digest"
grep -q 'skill.local_user.steered 1.4.0' "$T/stdout" && grep -q 'skill.e3d.premortem 2.0.0' "$T/stdout" || fail "the preview lists each skill with its version"
! grep -q 'LENS-' "$T/stdout" || fail "a preview must not print lens text"
run "${ON[@]}" -- "${ARGS[@]}" --specialist skeptic --seat-skill premortem --seat-skill steered --preview-skills --preview-json
jq -e '.schema_version == "e3d.skill-preview/v1" and (.seats | length) == 3 and .request.rounds == 1 and (.seats | map(.source) == ["specialist","seat-skill","seat-skill"]) and (.seats[2].adapter == "gamma") and .seats[2].provider_forced == false and .seats[2].hint_used == true' "$T/stdout" >/dev/null || fail "preview JSON shape: $(cat "$T/stdout" | head -c 600)"
D1="$(jq -r .plan_digest "$T/stdout")"
run "${ON[@]}" -- "${ARGS[@]}" --specialist skeptic --seat-skill premortem --seat-skill steered --preview-skills --preview-json; [[ "$(jq -r .plan_digest "$T/stdout")" == "$D1" ]] || fail "the digest is stable"
run "${ON[@]}" -- "Another question?" --providers alpha,beta,gamma --rounds 1 --synthesizer synth --min-families 1 --specialist skeptic --seat-skill premortem --seat-skill steered --preview-skills --preview-json; [[ "$(jq -r .plan_digest "$T/stdout")" != "$D1" ]] || fail "the digest follows the question"
run "${ON[@]}" -- "${ARGS[@]}" --rounds 2 --specialist skeptic --seat-skill premortem --seat-skill steered --preview-skills --preview-json; [[ "$(jq -r .plan_digest "$T/stdout")" != "$D1" ]] || fail "the digest follows the rounds"
run "${ON[@]}" -- "${ARGS[@]}" --specialist skeptic --seat-skill premortem --preview-skills --out-dir "$T/pv-out"
[[ $rc -eq 0 ]] || fail "preview with --out-dir"; [[ ! -e "$T/pv-out" ]] || fail "a preview must not create the output directory"
# settings that change the prompts or the calls are part of the digest, and --expect-plan cannot be bypassed with them
pvd() { run "${ON[@]}" -- "${ARGS[@]}" --specialist skeptic --seat-skill premortem --seat-skill steered --preview-skills --preview-json "$@"; jq -r .plan_digest "$T/stdout"; }
base="$(pvd)"
for extra in "--prompts v3b" "--approach hypotheses" "--web-search off" "--recap alpha" "--jev"; do
  [[ "$(pvd $extra)" != "$base" ]] || fail "the digest must follow: $extra"
  run "${ON[@]}" -- "${ARGS[@]}" --specialist skeptic --seat-skill premortem --seat-skill steered --expect-plan "$base" $extra --out-dir "$T/o-bypass"
  [[ $rc -eq 1 ]] && grep -q skill_quote_expired "$T/stderr" && nocall || fail "--expect-plan must refuse a run that changed: $extra (rc=$rc)"
done
rc=0; E3D_DEBATE_SYNTH_FALLBACK=off pvd >/dev/null; [[ "$(E3D_DEBATE_SYNTH_FALLBACK=off pvd)" != "$base" ]] || fail "the digest must follow the synthesis fallback setting"
# a value the debate itself will reject does not turn the preview into a different, worse error
run "${ON[@]}" -- "${ARGS[@]}" --specialist skeptic --specialist premortem --max-words 5 --preview-skills; [[ $rc -eq 0 ]] || fail "--max-words 5 must preview: $(cat "$T/stderr")"
run "${ON[@]}" -- "${ARGS[@]}" --specialist skeptic --specialist premortem --rounds 99999999999999999999 --max-words 99999999999999999999 --preview-skills; [[ $rc -eq 0 ]] || fail "huge numbers must not break the preview: $(cat "$T/stderr")"
echo "skills-plan 3 (preview): ok"

# 4. a run with seat skills: lenses delivered, the receipt names each skill, the digest is in the receipt; --expect-plan binds the run to the preview
run "${ON[@]}" -- "${ARGS[@]}" --specialist skeptic --seat-skill premortem --seat-skill steered --expect-plan "$D1" --out-dir "$T/out"
[[ $rc -eq 0 ]] || fail "a run with seat skills failed: $(cat "$T/stderr")"
grep -q 'LENS-skeptic-MARK' "$T"/seen-*.md && grep -q 'LENS-premortem-MARK' "$T"/seen-*.md && grep -q 'LENS-STEERED-MARK' "$T/seen-gamma-0.md" || fail "each seat receives its own lens (the steered skill on its hinted provider): $(ls "$T" | tr '\n' ' ') :: $(grep -l 'LENS-' "$T"/seen-*.md 2>&1 | tr '\n' ' ') :: $(head -c 300 "$T/stderr")"
! grep -q 'LENS-' "$T/seen-synth.md" || fail "the synthesis never receives a lens"
jq -e '.skills | length == 3 and (map(.source) == ["specialist","seat-skill","seat-skill"]) and all(.hook == "seat_prompt" and .scope == "debate_seat") and all(.use_id | test("^use_[0-9a-f]{20}$")) and all(.attachment_id | test("^att_[0-9a-f]{16}$"))' "$T/out/decision-log.json" >/dev/null || fail "the skills block of the receipt"
jq -e --arg d "$D1" '.skills_plan_digest == $d' "$T/out/decision-log.json" >/dev/null || fail "the receipt carries the plan digest that was previewed"
jq -e '.skills[2].id == "skill.local_user.steered" and .skills[2].version == "1.4.0" and (.skills[2].definition_hash | test("^sha256:"))' "$T/out/decision-log.json" >/dev/null || fail "the native skill is named with its resolved version and hash"
run "${ON[@]}" -- "Changed question?" --providers alpha,beta,gamma --rounds 1 --synthesizer synth --min-families 1 --specialist skeptic --seat-skill premortem --seat-skill steered --expect-plan "$D1" --out-dir "$T/out2"
[[ $rc -eq 1 ]] || fail "a changed request must not run under an old plan digest, got $rc"; grep -q 'skill_quote_expired' "$T/stderr" || fail "skill_quote_expired"; nocall || fail "a refused plan calls nothing"
echo "skills-plan 4 (run and digest): ok"

# 5. failure policy: a pin that does not match stops the run before any call; plain_seat runs that seat with no lens and records it
BADPIN="premortem#sha256:$(printf 'f%.0s' {1..64})"
run "${ON[@]}" -- "${ARGS[@]}" --specialist skeptic --seat-skill "$BADPIN" --out-dir "$T/o3"
[[ $rc -eq 1 ]] || fail "a pin mismatch must stop the run, got $rc"; grep -q 'skill_hash_mismatch' "$T/stderr" || fail "skill_hash_mismatch"; nocall || fail "a pin mismatch must stop before any call"
run "${ON[@]}" -- "${ARGS[@]}" --specialist skeptic --seat-skill "$BADPIN" --on-seat-skill-failure plain_seat --out-dir "$T/o4"
[[ $rc -eq 0 ]] || fail "plain_seat must let the debate run: $(cat "$T/stderr")"
[[ "$(cat "$T"/seen-*-0.md | grep -c 'LENS-')" == 1 ]] || fail "only the skeptic seat has a lens; the failed skill's seat is plain"
grep -q 'LENS-premortem-MARK' "$T"/seen-*.md && fail "the pinned-out skill must not reach any seat"
PLAIN_ADAPTER="$(jq -r '.panel.plain_seats[0].adapter' "$T/o4/decision-log.json")"; SKEPTIC_ADAPTER="$(jq -r '.panel.experts[0].adapter' "$T/o4/decision-log.json")"
[[ "$PLAIN_ADAPTER" != "$SKEPTIC_ADAPTER" ]] || fail "the plain seat sits on its own adapter in this case"
! grep -q 'LENS-' "$T/seen-$PLAIN_ADAPTER-0.md" || fail "the plain seat's own prompt must carry no lens"
grep -q 'LENS-skeptic-MARK' "$T/seen-$SKEPTIC_ADAPTER-0.md" || fail "the other seat keeps its lens"
jq -e '.panel.plain_seats | length == 1 and .[0].expert == null and .[0].skill_failed.code == "skill_hash_mismatch"' "$T/out4/decision-log.json" 2>/dev/null >/dev/null || jq -e '.panel.plain_seats | length == 1 and .[0].expert == null and .[0].skill_failed.code == "skill_hash_mismatch"' "$T/o4/decision-log.json" >/dev/null || fail "the receipt records the plain seat and why"
jq -e '.skills | map(select(.status == "failed")) | length == 1' "$T/o4/decision-log.json" >/dev/null || fail "the skills block records the failed skill"
grep -q 'runs plain' "$T/stderr" || fail "the plain seat is announced on stderr"
# a broken skill of the same name in a higher tier is never silently replaced by the built-in
BRK="$T/home/.config/e3d-pilot/specialists/skeptic"; mkdir -p "$BRK/e3d"
printf -- '---\nname: skeptic\ndescription: broken on purpose\nlicense: MIT\n---\nLENS-BROKEN-USER-MARK.\n' > "$BRK/SKILL.md"; printf '{"version":"1.0.0",' > "$BRK/e3d/skill.json"
run "${ON[@]}" -- "${ARGS[@]}" --specialist premortem --seat-skill skeptic --out-dir "$T/o6"
[[ $rc -eq 1 ]] && grep -q 'skill_invalid' "$T/stderr" && nocall || fail "a broken user skill must stop the run, not fall back to the built-in (rc=$rc)"
run "${ON[@]}" -- "${ARGS[@]}" --specialist premortem --seat-skill skeptic --on-seat-skill-failure plain_seat --out-dir "$T/o7"
[[ $rc -eq 0 ]] || fail "plain_seat must let it run: $(cat "$T/stderr")"; ! grep -q 'LENS-skeptic-MARK\|LENS-BROKEN' "$T"/seen-*.md || fail "neither the broken skill nor the built-in may sit on that seat"
jq -e '.panel.plain_seats[0].skill_failed.code == "skill_invalid"' "$T/o7/decision-log.json" >/dev/null || fail "the receipt says skill_invalid"
rm -rf "$BRK"
run "${ON[@]}" -- "${ARGS[@]}" --seat-skill "skeptic#sha256:$(printf 'a%.0s' {1..64})" --seat-skill "premortem#sha256:$(printf 'b%.0s' {1..64})" --on-seat-skill-failure plain_seat
[[ $rc -eq 1 ]] && grep -q 'every skill named with --seat-skill failed' "$T/stderr" && nocall || fail "when every skill failed nothing is run, with the real reason (rc=$rc)"
echo "skills-plan 5 (failure policy): ok"

# 6. nothing changes without the switches: a plain --specialist run's log has no skills keys and the panel keeps its shape
run E3D_SPECIALISTS=1 -- "${ARGS[@]}" --specialist skeptic --specialist premortem --out-dir "$T/o5"
[[ $rc -eq 0 ]] || fail "a plain expert run failed"
jq -e 'has("skills") | not' "$T/o5/decision-log.json" >/dev/null && jq -e 'has("skills_plan_digest") | not' "$T/o5/decision-log.json" >/dev/null || fail "no skills keys without E3D_SKILLS_V1"
echo "skills-plan 6 (off by default): ok"
echo "skills-plan: PASS"
