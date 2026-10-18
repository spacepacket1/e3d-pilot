#!/usr/bin/env bash
set -euo pipefail
# execute stage hands E3D_CODE_EXTRA_GUIDANCE_FILE to e3d-code (env var or config), records its sha256,
# and passes nothing when unset. Reuses the fixtures from tests/phase16.sh (everything before its first call).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source <(sed -e '/^ROOT=/d' -e '/^install_provider$/,$d' "$ROOT/tests/phase16.sh")
install_provider

run_case() {  # run_case <label> -> prints "<env seen by e3d-code>|<recorded file>" for that run
  local repo bin_dir idea seen_file run_dir
  repo="$(make_repo)"; bin_dir="$(mktemp -d)"; seen_file="$bin_dir/seen"
  make_e3d_code_bin "$bin_dir"
  # make the stub record the env it received, then behave like the base stub
  { printf '#!/usr/bin/env bash\nprintf "%%s" "${E3D_CODE_EXTRA_GUIDANCE_FILE-UNSET}" > %q\n' "$seen_file"; tail -n +2 "$bin_dir/e3d-code"; } > "$bin_dir/e3d-code.new"
  mv "$bin_dir/e3d-code.new" "$bin_dir/e3d-code"; chmod +x "$bin_dir/e3d-code"
  printf 'Prefer small commits.\n' > "$repo/guidance.md"
  [[ "$1" == config ]] && jq '.execute_extra_guidance_file = "guidance.md"' "$repo/.e3d-pilot/config.json" > "$repo/c.tmp" && mv "$repo/c.tmp" "$repo/.e3d-pilot/config.json"
  idea="$(ingest_idea "$repo" run-1 "Guidance $1")"
  "$BIN" ideas approve --repo "$repo" "$idea" --actor approver@example.com >/dev/null
  if [[ "$1" == env ]]; then
    PATH="$bin_dir:$PATH" E3D_PILOT_EXTRA_GUIDANCE_FILE="$repo/guidance.md" "$BIN" ideas implement --repo "$repo" "$idea" >/dev/null
  else
    PATH="$bin_dir:$PATH" "$BIN" ideas implement --repo "$repo" "$idea" >/dev/null
  fi
  run_dir="$(ls -d "$repo"/.e3d-pilot/runs/impl-* | head -1)"
  printf '%s|%s' "$(cat "$seen_file")" "$(cut -f1 "$run_dir/execute-extra-guidance.txt" 2>/dev/null || true)"
  [[ "$1" == unset ]] || [[ -n "$(cut -f2 "$run_dir/execute-extra-guidance.txt")" ]] || { echo "sha missing" >&2; exit 1; }
  printf '\n%s' "$repo" > "$bin_dir/repo"; rm -rf "$bin_dir"
}

r="$(run_case unset | head -1)"; assert_eq "$r" "|" "unset passes empty value and records nothing"
r="$(run_case env | head -1)"; assert_contains "$r" "guidance.md|"; assert_contains "$r" "/guidance.md"
r="$(run_case config | head -1)"; assert_contains "$r" "/guidance.md|"
printf 'execute-extra-guidance ok\n'
