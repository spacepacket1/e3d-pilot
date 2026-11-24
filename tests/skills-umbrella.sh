#!/usr/bin/env bash
# E3D_SKILLS=1 umbrella switch for the local skills features. Deterministic: no model, no network.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D="$ROOT/bin/e3d-debate"; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
run() { env -i PATH="$PATH" HOME="$TMP" "$@"; }

out="$(run E3D_SKILLS=1 "$D" --list-skills 2>&1)" || fail "E3D_SKILLS=1 --list-skills failed: $out"
[[ "$out" == *skeptic* ]] || fail "E3D_SKILLS=1 --list-skills did not list the built-ins"
run "$D" --list-skills 2>&1 | grep -q 'skills are off' || fail "--list-skills was not refused with no switch"
run E3D_SKILLS=0 "$D" --list-skills 2>&1 | grep -q 'skills are off' || fail "E3D_SKILLS=0 turned skills on"
run E3D_SKILLS=2 "$D" --list-skills 2>&1 | grep -q 'E3D_SKILLS must be 0 or 1' || fail "E3D_SKILLS=2 was not refused"
# a switch set by name wins
run E3D_SKILLS=1 E3D_SKILLS_V1=0 "$D" --list-skills 2>&1 | grep -q 'skills are off' || fail "E3D_SKILLS_V1=0 did not win over E3D_SKILLS=1"
run E3D_SKILLS=1 E3D_SKILLS_OBSERVER=0 "$D" "q" --observer x 2>&1 | grep -q 'observers are off' || fail "E3D_SKILLS_OBSERVER=0 did not keep observers off"
# it does not turn on calibration or hosted skills
run E3D_SKILLS=1 "$D" --my-calibration 2>&1 | grep -qi 'calibration.*off\|E3D_CALIBRATION_V1' || fail "E3D_SKILLS=1 appears to turn calibration on"
run E3D_SKILLS=1 "$D" "q" --hosted-skills "$TMP/x.json" 2>&1 | grep -q 'E3D_SKILLS_HOSTED' || fail "E3D_SKILLS=1 appears to allow --hosted-skills"
echo "skills-umbrella: ok"
