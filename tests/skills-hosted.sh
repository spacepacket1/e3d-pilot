#!/usr/bin/env bash
# Skills phase 3c, PR H2a: hosted skills in bin/e3d-debate (--hosted-skills FILE). The file is written by the hosted listener; every definition goes through the intake
# checks and joins the catalogue as tier "hosted", reachable by full id only. Stub adapters copy the prompt they receive. No model, no network.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures/specialists"
source "$FIX/harness.sh"
TMPS=()
cleanup() { for d in "${TMPS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
newroot() { local T; T="$(mktemp -d)"; TMPS+=("$T"); printf '%s' "$T"; }

node "$ROOT/tests/fixtures/skills/hosted.mjs" || fail "library cases"

T="$(newroot)"; build_root "$T" "$ROOT/bin/e3d-debate" v2 alpha beta gamma
P=u_abc123def456
cat > "$T/lib/providers/obs" <<STUB
#!/usr/bin/env bash
if [[ "\${E3D_PILOT_CHECK:-}" == 1 ]]; then exit 0; fi
cp "\$1" "$T/seen-obs.md"
printf 'OBSERVER REPORT\nThe dissent added no new evidence.\n'
STUB
chmod +x "$T/lib/providers/obs"
mk() { node "$ROOT/tests/fixtures/skills/hosted-make.mjs" "$1" "$2" "$3"; }
mk "$T/good.json" "$P" '[{"name":"lens-a","body":"LENS-A-MARK. Argue the opposite.","hooks":["seat"]},{"name":"lens-b","body":"LENS-B-MARK. Look for the cost.","hooks":["seat","observer"]}]'
mk "$T/tools.json" "$P" '[{"name":"lens-a","body":"LENS-A-MARK.","hooks":["seat"]},{"name":"sneaky","body":"SNEAKY-MARK.","hooks":["seat"],"mutate":"tools"}]'
mk "$T/other.json" "u_zzzzzz999999" '[{"name":"lens-a","body":"LENS-A-MARK.","hooks":["seat"]},{"name":"lens-b","body":"LENS-B-MARK.","hooks":["seat"]}]'
# definitions owned by someone else, sent under this run's principal: the engine refuses (the owner is not the authenticated principal)
jq --arg p "$P" '.principal = $p' "$T/other.json" > "$T/mismatch.json"
# a host folder skill named like a hosted one: a hosted run never reads it
mkdir -p "$T/home/.config/e3d-pilot/specialists/lens-a"; printf -- '---\nname: lens-a\ndescription: A host folder.\nlicense: MIT\n---\nHOST-FOLDER-MARK.\n' > "$T/home/.config/e3d-pilot/specialists/lens-a/SKILL.md"
run() {
  local -a e=(-u TYPESAFE_API_KEY -u E3D_SKILLS_V1 -u E3D_SKILLS_SEATS -u E3D_SKILLS_HOSTED -u E3D_SPECIALISTS -u E3D_SKILLS_OBSERVER)
  while [[ "$1" != -- ]]; do e+=("$1"); shift; done; shift
  rc=0; rm -f "$T"/seen-* "$T"/count-*
  env "${e[@]}" HOME="$T/home" "$T/bin/e3d-debate" "$@" > "$T/stdout" 2> "$T/stderr" || rc=$?
}
ON=(E3D_SPECIALISTS=1 E3D_SKILLS_V1=1 E3D_SKILLS_SEATS=1 E3D_SKILLS_HOSTED=1)
nocall() { ! compgen -G "$T/seen-*" >/dev/null && ! compgen -G "$T/count-*" >/dev/null; }
Q="Should we ship it?"
ARGS=("$Q" --providers alpha,beta,gamma --rounds 1 --synthesizer synth --min-families 1 --builtin-only)
SEATS=(--seat-skill "skill.$P.lens-a" --seat-skill "skill.$P.lens-b")

# 1. the switches
run E3D_SPECIALISTS=1 E3D_SKILLS_V1=1 E3D_SKILLS_SEATS=1 -- "${ARGS[@]}" "${SEATS[@]}" --hosted-skills "$T/good.json"; [[ $rc -eq 1 ]] || fail "--hosted-skills without E3D_SKILLS_HOSTED must be refused, got $rc"; grep -q 'hosted skills are off' "$T/stderr" || fail "says why"; nocall || fail "no call when refused"
run E3D_SPECIALISTS=1 E3D_SKILLS_SEATS=1 E3D_SKILLS_HOSTED=1 -- "${ARGS[@]}" "${SEATS[@]}" --hosted-skills "$T/good.json"; [[ $rc -eq 1 ]] || fail "needs E3D_SKILLS_V1"
run E3D_SPECIALISTS=1 E3D_SKILLS_V1=1 E3D_SKILLS_SEATS=1 E3D_SKILLS_HOSTED=maybe -- "${ARGS[@]}" "${SEATS[@]}" --hosted-skills "$T/good.json"; [[ $rc -eq 2 ]] || fail "an invalid E3D_SKILLS_HOSTED refuses to start (exit 2), got $rc"
run "${ON[@]}" -- "$Q" --providers alpha,beta,gamma --rounds 1 --synthesizer synth --min-families 1 "${SEATS[@]}" --hosted-skills "$T/good.json"; [[ $rc -eq 1 ]] || fail "without --builtin-only a hosted run is refused"; grep -q 'needs --builtin-only' "$T/stderr" || fail "says why"; nocall || fail "no call"
ln -sf "$T/good.json" "$T/link.json"; run "${ON[@]}" -- "${ARGS[@]}" "${SEATS[@]}" --hosted-skills "$T/link.json"; [[ $rc -eq 1 ]] || fail "a symlinked file is refused"; nocall || fail "no call"
run "${ON[@]}" -- "${ARGS[@]}" "${SEATS[@]}" --hosted-skills "$T/missing.json"; [[ $rc -eq 1 ]] || fail "a missing file is refused"
echo "skills-hosted 1 (the switches): ok"

# 2. a good run: each hosted skill sits on its own seat; the lens is the skill text; the other seat is plain; the receipt names the skills
run "${ON[@]}" -- "${ARGS[@]}" "${SEATS[@]}" --hosted-skills "$T/good.json" --out-dir "$T/out"
[[ $rc -eq 0 ]] || fail "a hosted run failed: $(cat "$T/stderr")"
grep -l 'LENS-A-MARK' "$T"/seen-* >/dev/null && grep -l 'LENS-B-MARK' "$T"/seen-* >/dev/null || fail "each seat saw its hosted skill's text"
[[ "$(grep -l 'LENS-A-MARK' "$T"/seen-* | wc -l | tr -d ' ')" == 1 ]] || fail "a skill's text reaches one seat only"
! grep -q 'HOST-FOLDER-MARK' "$T"/seen-* || fail "a host folder with the same name is never read in a hosted run"
jq -e --arg a "skill.$P.lens-a" --arg b "skill.$P.lens-b" '(.skills | map(.id) | sort) == ([$a,$b] | sort) and (.skills | all(.definition_hash | startswith("sha256:")))' "$T/out/decision-log.json" >/dev/null || fail "the receipt names both hosted skills with their hashes: $(jq -c '.skills' "$T/out/decision-log.json")"
jq -e '.skills | all(.use_id != null)' "$T/out/decision-log.json" >/dev/null || fail "the receipt carries a use_id per skill"
echo "skills-hosted 2 (a hosted run): ok"

# 3. refusals happen before any call, and say codes, never text
for pair in tools:skill_capability_denied mismatch:skill_tenant_denied; do
  f="${pair%%:*}"; code="${pair##*:}"
  run "${ON[@]}" -- "${ARGS[@]}" "${SEATS[@]}" --hosted-skills "$T/$f.json"; [[ $rc -ne 0 ]] || fail "$f.json must be refused"; nocall || fail "$f.json: nothing may be called"
  ! grep -q 'SNEAKY-MARK\|LENS-A-MARK' "$T/stderr" || fail "$f.json: the error must not echo skill text"
  grep -q "$code" "$T/stderr" || fail "$f.json: the code $code is named: $(cat "$T/stderr")"
done
echo "skills-hosted 3 (refusals): ok"

# 4. by full id only: a bare name does not reach a hosted skill, a wrong pin is refused
run "${ON[@]}" -- "${ARGS[@]}" --seat-skill lens-a --seat-skill lens-b --hosted-skills "$T/good.json"; [[ $rc -ne 0 ]] || fail "a bare name must not resolve a hosted skill"; nocall || fail "no call"
run "${ON[@]}" -- "${ARGS[@]}" --seat-skill "skill.$P.lens-a#sha256:$(printf '1%.0s' $(seq 64))" --seat-skill "skill.$P.lens-b" --hosted-skills "$T/good.json"; [[ $rc -ne 0 ]] || fail "a wrong hash pin is refused"; nocall || fail "no call"
grep -q 'skill_hash_mismatch' "$T/stderr" || fail "names the pin failure"
echo "skills-hosted 4 (full id and pins): ok"

# 5. the preview works for a hosted plan and shows tier hosted; the digest follows the skill
run "${ON[@]}" -- "${ARGS[@]}" "${SEATS[@]}" --hosted-skills "$T/good.json" --preview-skills --preview-json
[[ $rc -eq 0 ]] || fail "preview failed: $(cat "$T/stderr")"; nocall || fail "a preview calls nothing"
jq -e '(.seats | map(.tier) | all(. == "hosted")) and (.seats | all(.skill != null))' "$T/stdout" >/dev/null || fail "the preview names each hosted skill: $(jq -c '.seats' "$T/stdout" | head -c 400)"
D1="$(jq -r .plan_digest "$T/stdout")"
mk "$T/changed.json" "$P" '[{"name":"lens-a","body":"LENS-A-MARK. Argue the opposite, harder.","hooks":["seat"]},{"name":"lens-b","body":"LENS-B-MARK. Look for the cost.","hooks":["seat","observer"]}]'
run "${ON[@]}" -- "${ARGS[@]}" "${SEATS[@]}" --hosted-skills "$T/changed.json" --preview-skills --preview-json; [[ "$(jq -r .plan_digest "$T/stdout")" != "$D1" ]] || fail "the digest follows the skill text"
run "${ON[@]}" -- "${ARGS[@]}" "${SEATS[@]}" --hosted-skills "$T/good.json" --expect-plan "$D1" --out-dir "$T/out2"; [[ $rc -eq 0 ]] || fail "a run with the previewed digest runs: $(cat "$T/stderr")"
run "${ON[@]}" -- "${ARGS[@]}" "${SEATS[@]}" --hosted-skills "$T/changed.json" --expect-plan "$D1"; [[ $rc -ne 0 ]] || fail "a changed skill stops a run bound to the old digest"; grep -q skill_quote_expired "$T/stderr" || fail "names skill_quote_expired"; nocall || fail "nothing runs"
echo "skills-hosted 5 (preview and digest): ok"

# 6. the observer plan resolves a hosted skill (the per-token run of an observer comes in a later PR)
O="$(E3D_SKILLS_OBSERVER_ADAPTERS=alpha,beta node "$ROOT/lib/skills/observer.mjs" plan --builtin "$T/lib/specialists" --user /nonexistent --repo /nonexistent --builtin-only --hosted-skills "$T/good.json" --skill "skill.$P.lens-b" --pool alpha,beta --synthesizer alpha)"
jq -e '.ok == true and .observer.tier == "hosted" and .observer.skill.id == "skill.'"$P"'.lens-b"' <<< "$O" >/dev/null || fail "observer plan for a hosted skill: $O"
O="$(E3D_SKILLS_OBSERVER_ADAPTERS=alpha,beta node "$ROOT/lib/skills/observer.mjs" plan --builtin "$T/lib/specialists" --user /nonexistent --repo /nonexistent --hosted-skills "$T/good.json" --skill "skill.$P.lens-b" --pool alpha,beta --synthesizer alpha || true)"
jq -e '.ok == false and .error.code == "skill_scope_denied"' <<< "$O" >/dev/null || fail "an observer call with a hosted file but without --builtin-only is refused: $O"
echo "skills-hosted 6 (observer plan): ok"

# 7. a hosted OBSERVER run end to end: the report is recorded (observers.json, a valid run record), stdout untouched
OBS=(E3D_SKILLS_OBSERVER=1 E3D_SKILLS_OBSERVER_ADAPTERS=alpha,beta,gamma,obs,synth)
run "${ON[@]}" "${OBS[@]}" -- "${ARGS[@]}" "${SEATS[@]}" --hosted-skills "$T/good.json" --observer "skill.$P.lens-b:obs" --out-dir "$T/outo"
[[ $rc -eq 0 ]] || fail "a hosted observer run failed: $(cat "$T/stderr")"
[[ -s "$T/outo/observers.json" ]] || fail "observers.json must exist for a hosted observer: $(grep -i 'warning' "$T/stderr")"
jq -e '.[0].run.status == "completed" and .[0].run.skill_source.tier == "hosted" and (.[0].run.skill_source | has("legacy_folder_hash") | not)' "$T/outo/observers.json" >/dev/null || fail "a valid hosted run record: $(jq -c '.[0].run | {status, skill_source}' "$T/outo/observers.json")"
grep -q 'LENS-B-MARK' "$T/seen-obs.md" || fail "the observer prompt carries the hosted skill's text"
! grep -q 'OBSERVER REPORT' "$T/stdout" || fail "the report never reaches stdout"
echo "skills-hosted 7 (hosted observer end to end): ok"

# 8. the path is passed as one quoted argument everywhere: a space or glob characters never change which file is read
mkdir -p "$T/sp ace"; cp "$T/good.json" "$T/sp ace/good.json"
run "${ON[@]}" "${OBS[@]}" -- "${ARGS[@]}" "${SEATS[@]}" --hosted-skills "$T/sp ace/good.json" --observer "skill.$P.lens-b:obs" --out-dir "$T/outs"
[[ $rc -eq 0 && -s "$T/outs/observers.json" ]] || fail "a path with a space works with an observer: $(cat "$T/stderr")"
mkdir -p "$T/g"; cp "$T/good.json" "$T/g/g[a]x.json"
mk "$T/g/gax.json" "$P" '[{"name":"lens-a","body":"LENS-A-MARK.","hooks":["seat"]},{"name":"lens-b","body":"OTHER-FILE-OBSERVER-BODY","hooks":["seat","observer"]}]'
run "${ON[@]}" "${OBS[@]}" -- "${ARGS[@]}" "${SEATS[@]}" --hosted-skills "$T/g/g[a]x.json" --observer "skill.$P.lens-b:obs" --out-dir "$T/outg"
[[ $rc -eq 0 ]] || fail "a path with glob characters works: $(cat "$T/stderr")"
! grep -q 'OTHER-FILE-OBSERVER-BODY' "$T/seen-obs.md" || fail "a glob in the path must never pick another file"
grep -q 'LENS-B-MARK' "$T/seen-obs.md" || fail "the observer read the file that was validated"
echo "skills-hosted 8 (the path is one argument): ok"

# 9. a hosted run never degrades: plain_seat is refused, a bad file is refused even when nothing uses it, an empty path is refused
run "${ON[@]}" -- "${ARGS[@]}" "${SEATS[@]}" --hosted-skills "$T/good.json" --on-seat-skill-failure plain_seat; [[ $rc -eq 1 ]] || fail "plain_seat is refused with hosted skills, got $rc"; nocall || fail "no call"
printf '{not json' > "$T/junk.json"
run "${ON[@]}" -- "${ARGS[@]}" --hosted-skills "$T/junk.json"; [[ $rc -eq 1 ]] || fail "a bad hosted file is refused even when no seat or observer uses it, got $rc"; nocall || fail "no call"; grep -q 'skill_schema_invalid' "$T/stderr" || fail "names the code"
run "${ON[@]}" -- "${ARGS[@]}" "${SEATS[@]}" --hosted-skills ""; [[ $rc -eq 1 ]] || fail "an empty path is refused, got $rc"; nocall || fail "no call"
run "${ON[@]}" -- "${ARGS[@]}" --seat-skill "skill.$P.lens-a" --seat-skill "skill.$P.lens-missing" --hosted-skills "$T/good.json" --on-seat-skill-failure fail; [[ $rc -ne 0 ]] || fail "a skill id that is not in the file stops the run"; nocall || fail "no call"
echo "skills-hosted 9 (no degrade): ok"

# 10. the lens size limit of a hosted run applies to hosted skills as to experts
run "${ON[@]}" -- "${ARGS[@]}" "${SEATS[@]}" --hosted-skills "$T/good.json" --lens-bytes-max 50; [[ $rc -ne 0 ]] || fail "a hosted skill over --lens-bytes-max is refused"; nocall || fail "no call"
run "${ON[@]}" -- "${ARGS[@]}" "${SEATS[@]}" --hosted-skills "$T/good.json" --lens-bytes-max 4096; [[ $rc -eq 0 ]] || fail "within the limit runs: $(cat "$T/stderr")"
echo "skills-hosted 10 (lens bytes): ok"
echo "skills-hosted: ok"
