#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; BIN="$ROOT/bin/e3d-pilot"; SAMPLE="$ROOT/examples/sample-config.json"
PROVIDER="$ROOT/lib/providers/phase9-stub"; trap 'rm -f "$PROVIDER"' EXIT
assert_contains(){ [[ "$1" == *"$2"* ]] || { echo "missing: $2" >&2; exit 1; }; }
make_repo(){ local repo; repo="$(mktemp -d)"; git init -q "$repo"; git -C "$repo" config user.email test@example.com; git -C "$repo" config user.name Test; printf '# Repo\n' > "$repo/README.md"; git -C "$repo" add .; git -C "$repo" commit -q -m initial; printf '%s' "$repo"; }
cat > "$PROVIDER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${E3D_PILOT_CHECK:-0}" == 1 ]] && { echo available; exit; }
cat >/dev/null
cat <<'OUT'
stub context
### Candidate 1: Existing work
Duplicate: yes
Dedup rationale: test stop
Description: none
---IDEATE-STATUS---
selected: none
reason: all duplicate
OUT
EOF
chmod +x "$PROVIDER"

good="$(make_repo)"; broken="$(make_repo)"; mkdir -p "$good/.e3d-pilot"
jq '.providers.discover="phase9-stub" | .providers.ideate="phase9-stub"' "$SAMPLE" > "$good/.e3d-pilot/config.json"
fleet="$(mktemp)"; jq -n --arg good "$good" --arg broken "$broken" '[$good,$broken]' > "$fleet"
set +e; out="$("$BIN" fleet "$fleet" 2>&1)"; status=$?; set -e
[[ $status -ne 0 ]]; assert_contains "$out" "fleet: PASS $good"; assert_contains "$out" "fleet: FAIL $broken"; assert_contains "$out" 'total=2 passed=1 failed=1'
grep -q '## Fleet mode' "$ROOT/README.md"; grep -q 'LOCAL_MODEL_ENDPOINT' "$ROOT/README.md"; grep -q 'run-id' "$ROOT/README.md"

# examples/sample-fleet.json itself (not just an ad hoc fixture matching its
# shape) must be a valid 2+-entry JSON array of repo path strings, per Phase
# 9's acceptance criteria.
jq -e 'type == "array" and length >= 2 and all(.[]; type == "string")' "$ROOT/examples/sample-fleet.json" >/dev/null \
  || { echo "examples/sample-fleet.json must be a JSON array of 2+ repo path strings" >&2; exit 1; }

# examples/sample-fleet.json is documentation (placeholder paths a real user
# edits), so it can't be run verbatim -- but substituting its exact
# placeholder entries with real throwaway repos, preserving its shape
# exactly, and running `e3d-pilot fleet` against that means the literal
# file's structure is what actually gets exercised here, not an unrelated
# hand-rolled fixture.
sample_fleet_copy="$(mktemp)"
jq --arg good "$good" --arg broken "$broken" '.[0] = $good | .[1] = $broken' \
  "$ROOT/examples/sample-fleet.json" > "$sample_fleet_copy"
set +e; out="$("$BIN" fleet "$sample_fleet_copy" 2>&1)"; status=$?; set -e
[[ $status -ne 0 ]]
assert_contains "$out" "fleet: PASS $good"
assert_contains "$out" "fleet: FAIL $broken"
rm -f "$sample_fleet_copy"

echo 'phase9: all tests passed'
