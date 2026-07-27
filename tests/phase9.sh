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
echo 'phase9: all tests passed'
