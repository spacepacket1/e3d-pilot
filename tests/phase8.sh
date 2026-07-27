#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; BIN="$ROOT/bin/e3d-pilot"; SAMPLE="$ROOT/examples/sample-config.json"
PROVIDER="$ROOT/lib/providers/phase8-review"; trap 'rm -f "$PROVIDER"' EXIT
assert_contains(){ [[ "$1" == *"$2"* ]] || { echo "missing: $2" >&2; exit 1; }; }

make_provider(){ cat > "$PROVIDER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${E3D_PILOT_CHECK:-0}" == 1 ]] && { echo available; exit; }
cat >/dev/null; echo 'Review approved: correct and in scope.'
EOF
chmod +x "$PROVIDER"; }

setup_run(){
  local repo run_id="$1" worktree branch run_dir name
  repo="$(mktemp -d)"; git init -q "$repo"; git -C "$repo" config user.email test@example.com; git -C "$repo" config user.name Test
  printf '# Target\n' > "$repo/README.md"; printf '.e3d-pilot/\n.codex-spec-runner/\n' > "$repo/.gitignore"
  git -C "$repo" add .; git -C "$repo" commit -q -m initial
  mkdir -p "$repo/.e3d-pilot"; jq '.verify=["true"] | .providers.review="phase8-review" | .pr.backend="local"' "$SAMPLE" > "$repo/.e3d-pilot/config.json"
  branch="e3d-pilot/$run_id"; worktree="$(mktemp -d)"; rmdir "$worktree"; git -C "$repo" worktree add -q -b "$branch" "$worktree"
  printf '\nimplemented\n' >> "$worktree/README.md"
  run_dir="$repo/.e3d-pilot/runs/$run_id"; mkdir -p "$run_dir/csr-state"
  printf '%s\t%s\n' "$branch" "$worktree" > "$run_dir/execute-worktree.txt"
  for name in findings.md candidates.md negotiation-log.md spec-final.md; do printf '# %s\n' "$name" > "$run_dir/$name"; done
  printf 'manifest row\n' > "$run_dir/csr-state/manifest.tsv"
  printf '%s' "$repo"
}

verify_failure_blocks_publish(){
  local repo=phase8-fail run_id=phase8-fail out status
  repo="$(setup_run "$run_id")"; jq '.verify=["false"]' "$repo/.e3d-pilot/config.json" > "$repo/.e3d-pilot/c"; mv "$repo/.e3d-pilot/c" "$repo/.e3d-pilot/config.json"
  set +e; "$BIN" run --repo "$repo" --stage review --run-id "$run_id" >/dev/null 2>&1; status=$?; set -e; [[ $status -ne 0 ]]
  set +e; out="$("$BIN" run --repo "$repo" --stage publish --run-id "$run_id" 2>&1)"; status=$?; set -e
  [[ $status -ne 0 ]]; assert_contains "$out" 'verification has not passed'
}

local_publish_commits_audit(){
  local run_id=phase8-local repo worktree summary name
  repo="$(setup_run "$run_id")"; "$BIN" run --repo "$repo" --stage review --run-id "$run_id" >/dev/null
  "$BIN" run --repo "$repo" --stage publish --run-id "$run_id" >/dev/null
  worktree="$(cut -f2 "$repo/.e3d-pilot/runs/$run_id/execute-worktree.txt")"; summary="$repo/.e3d-pilot/runs/$run_id/publish-summary.md"
  [[ -f "$summary" ]]; for name in findings.md candidates.md negotiation-log.md spec-final.md csr-manifest.tsv; do
    git -C "$worktree" cat-file -e "HEAD:.e3d-pilot/runs/$run_id/$name"; assert_contains "$(cat "$summary")" "$name"
  done
}

github_dry_run_is_draft(){
  local run_id=phase8-github repo fake out
  repo="$(setup_run "$run_id")"; git -C "$repo" remote add origin git@github.com:example/repo.git
  jq '.pr.backend="github"' "$repo/.e3d-pilot/config.json" > "$repo/.e3d-pilot/c"; mv "$repo/.e3d-pilot/c" "$repo/.e3d-pilot/config.json"
  "$BIN" run --repo "$repo" --stage review --run-id "$run_id" >/dev/null
  fake="$(mktemp -d)"; printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/gh"; chmod +x "$fake/gh"
  out="$(PATH="$fake:$PATH" E3D_PILOT_PUBLISH_DRY_RUN=1 "$BIN" run --repo "$repo" --stage publish --run-id "$run_id")"
  assert_contains "$out" 'pr create'; assert_contains "$out" '--draft'; assert_contains "$out" 'push -u origin'; [[ "$(git -C "$repo" remote get-url origin)" == *github.com* ]]
}

make_provider; verify_failure_blocks_publish; local_publish_commits_audit; github_dry_run_is_draft
echo 'phase8: all tests passed'
