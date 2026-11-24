#!/usr/bin/env bash
# Calibration phase 2: local capture (lib/calibration, the calibration commands of bin/e3d-debate, the note of each skill use in the local store).
# No model, no network, no API key: fixtures are built in temp directories and the debate uses the stub adapters of the expert tests.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures/specialists"
source "$FIX/harness.sh"
TMPS=()
cleanup() { for d in "${TMPS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
newroot() { local T; T="$(mktemp -d)"; TMPS+=("$T"); printf '%s' "$T"; }

# 1. the library and command cases (the interval maths, the store, the records, retention, races, permissions, wording)
node "$ROOT/tests/fixtures/calibration/local.mjs" || fail "library and command cases"
echo "calibration-local 1 (library and commands): ok"

# 2. the switch: strict unset/0/1, off by default
T="$(newroot)"; mkdir -p "$T/home"
cal() { local v="$1"; shift; env -u E3D_CALIBRATION_V1 ${v:+E3D_CALIBRATION_V1=$v} HOME="$T/home" "$ROOT/bin/e3d-debate" "$@" > "$T/stdout" 2> "$T/stderr"; }
for v in 2 yes true on 01 -1 1x; do
  rc=0; cal "$v" --my-calibration || rc=$?; [[ $rc -eq 2 ]] || fail "E3D_CALIBRATION_V1='$v' must refuse to start (exit 2), got $rc"
  grep -q 'E3D_CALIBRATION_V1 must be 0 or 1' "$T/stderr" || fail "E3D_CALIBRATION_V1='$v': message"
  rc=0; cal "$v" "q?" --providers alpha,beta --out-dir "$T/o" || rc=$?; [[ $rc -eq 2 ]] || fail "an invalid value refuses even with no calibration command, got $rc"
done
for v in "" 0; do
  for flag in "--my-calibration" "--skill-record skeptic" "--report-outcome use_abcd1234 --result worked" "--delete-outcome use_abcd1234" "--compact-calibration" "--my-calibration --json"; do
    rc=0; cal "$v" $flag || rc=$?; [[ $rc -eq 1 ]] || fail "E3D_CALIBRATION_V1='$v' $flag: expected exit 1, got $rc"
    grep -q 'calibration is off' "$T/stderr" || fail "E3D_CALIBRATION_V1='$v' $flag: message missing"
  done
done
[[ ! -e "$T/home/.config" ]] || fail "with the switch off nothing is created in the state directory"
cal 1 --my-calibration --json || fail "--my-calibration with the switch on: $(cat "$T/stderr")"
jq -e '.ok == true and .principal == "local" and (.skills | length == 0)' "$T/stdout" >/dev/null || fail "--my-calibration --json output"
[[ ! -e "$T/home/.config" ]] || fail "a read creates nothing"
rc=0; cal 1 --skill-version 1.0.0 || rc=$?; [[ $rc -eq 1 ]] || fail "--skill-version alone is still refused"
echo "calibration-local 2 (the switch): ok"

# 3. a debate: the receipt is the same with the switch off, unset or on (apart from fresh ids); only the switch on notes the uses
mkexp() {
  mkdir -p "$1/lib/specialists/$2"
  printf -- '---\nname: %s\ndescription: The %s lens. Use it in tests.\nlicense: MIT\nmetadata:\n  e3d.expert.version: "2"\n---\nLENS-%s-MARK.\n' "$2" "$2" "$2" > "$1/lib/specialists/$2/SKILL.md"
}
T="$(newroot)"; build_root "$T" "$ROOT/bin/e3d-debate" v2 alpha beta; mkexp "$T" skeptic; mkexp "$T" premortem
cp -R "$ROOT/lib/calibration" "$T/lib/"
run() { local cv="$1"; shift; env -u TYPESAFE_API_KEY -u E3D_CALIBRATION_V1 ${cv:+E3D_CALIBRATION_V1=$cv} E3D_SKILLS_V1=1 E3D_SPECIALISTS=1 HOME="$T/home" "$T/bin/e3d-debate" "$@" > "$T/stdout" 2> "$T/stderr"; }
norm() { jq -S 'del(.ts, .seconds, .skills_plan_digest) | if .skills then .skills |= map(del(.use_id, .attachment_id)) else . end' "$1"; }
ARGS=("q?" --providers alpha,beta --rounds 1 --synthesizer synth --specialist skeptic --specialist premortem)
rm -rf "$T/out" "$T/home/.config"; run "" "${ARGS[@]}" --out-dir "$T/out" || fail "unset run failed: $(cat "$T/stderr")"
norm "$T/out/decision-log.json" > "$T/unset.json"; cp "$T/stdout" "$T/stdout.unset"; cp "$T/stderr" "$T/stderr.unset"
[[ ! -e "$T/home/.config/e3d-pilot/calibration" ]] || fail "unset: no state directory may exist"
rm -rf "$T/out"; run 0 "${ARGS[@]}" --out-dir "$T/out" || fail "off run failed: $(cat "$T/stderr")"
norm "$T/out/decision-log.json" | diff -u "$T/unset.json" - >/dev/null || fail "=0 and unset must give the same receipt"
diff -u "$T/stdout.unset" "$T/stdout" >/dev/null || fail "=0 and unset must print the same"
[[ ! -e "$T/home/.config/e3d-pilot/calibration" ]] || fail "=0: no state directory may exist"
jq -e '.skills | length == 2 and all(.use_id | test("^use_[0-9a-f]{20}$"))' "$T/out/decision-log.json" >/dev/null || fail "the receipt still carries a use_id per skill with the switch off"
rm -rf "$T/out"; run 1 "${ARGS[@]}" --out-dir "$T/out" || fail "on run failed: $(cat "$T/stderr")"
norm "$T/out/decision-log.json" | diff -u "$T/unset.json" - >/dev/null || fail "with the switch on the receipt must not change"
diff -u "$T/stdout.unset" "$T/stdout" >/dev/null || fail "with the switch on stdout must not change"
diff -u "$T/stderr.unset" "$T/stderr" >/dev/null || fail "with the switch on stderr must not change"
CALDIR="$T/home/.config/e3d-pilot/calibration"
[[ -d "$CALDIR" && "$(stat -f %Lp "$CALDIR" 2>/dev/null || stat -c %a "$CALDIR")" == 700 ]] || fail "the state directory exists and is 0700"
[[ "$(wc -l < "$CALDIR/uses.jsonl" | tr -d ' ')" == 2 ]] || fail "both skill uses are noted"
for id in $(jq -r '.skills[].use_id' "$T/out/decision-log.json"); do grep -q "\"$id\"" "$CALDIR/uses.jsonl" || fail "$id is not noted in the store"; done
echo "calibration-local 3 (receipt unchanged, uses noted only with the switch on): ok"

# 4. end to end: report an outcome against a receipt's use_id, read the record, correct it, delete it
USE="$(jq -r '.skills[0].use_id' "$T/out/decision-log.json")"
cal 1 --report-outcome "$USE" --result worked --json || fail "report: $(cat "$T/stderr")"
jq -e '.status == "recorded" and .outcome.tier == "user_marked" and .outcome.use_id == "'"$USE"'"' "$T/stdout" >/dev/null || fail "report output"
[[ "$(stat -f %Lp "$CALDIR/outcomes.jsonl" 2>/dev/null || stat -c %a "$CALDIR/outcomes.jsonl")" == 600 ]] || fail "outcomes.jsonl is 0600"
rc=0; cal 1 --skill-record skeptic --json || rc=$?; [[ $rc -eq 1 || $rc -eq 0 ]] || fail "record"
jq -e '(.error.code == "skill_record_insufficient") and (.insufficient[0].n_resolved <= 1) and (tostring | test("\"rate\"") | not)' "$T/stdout" >/dev/null || fail "a single outcome is not enough for a record: $(cat "$T/stdout")"
cal 1 --report-outcome "$USE" --result failed || fail "correction"; grep -q 'supersedes out_' "$T/stdout" || fail "the correction supersedes"
[[ "$(wc -l < "$CALDIR/outcomes.jsonl" | tr -d ' ')" == 2 ]] || fail "both outcomes stay in the file"
cal 1 --delete-outcome "$USE" --json || fail "delete"; jq -e '.status == "deleted"' "$T/stdout" >/dev/null || fail "delete output"
cal 1 --compact-calibration || fail "compact"; [[ "$(wc -l < "$CALDIR/outcomes.jsonl" | tr -d ' ')" == 0 ]] || fail "compact removes the deleted outcomes"
rc=0; cal 1 --report-outcome use_00000000000000000000 --result worked || rc=$?; [[ $rc -eq 1 ]] || fail "a use never issued is refused"; grep -q skill_use_not_found "$T/stderr" || fail "skill_use_not_found"
echo "calibration-local 4 (end to end): ok"
echo "calibration-local: PASS"
