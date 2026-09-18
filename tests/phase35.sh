#!/usr/bin/env bash
set -euo pipefail

# Phase 35: config.execute_local_data_paths carries gitignored local data
# (credentials, live instance config -- anything a repo deliberately never
# commits) forward into every fresh execute worktree, since `git worktree
# add` only ever checks out tracked, committed files and would otherwise
# leave tests/tooling depending on that data failing inside execute no
# matter what machine or network access is available.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"
SAMPLE_CONFIG="$ROOT/examples/sample-config.json"
PROVIDER="$ROOT/lib/providers/phase35-provider"

assert_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] || {
    printf 'expected to find %q in output\n' "$needle" >&2
    exit 1
  }
}

assert_eq() {
  local actual="$1" expected="$2" msg="${3:-}"
  [[ "$actual" == "$expected" ]] || {
    printf 'expected %q, got %q (%s)\n' "$expected" "$actual" "$msg" >&2
    exit 1
  }
}

cleanup() {
  rm -f "$PROVIDER"
}
trap cleanup EXIT

install_provider() {
  cat > "$PROVIDER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
prompt_file="${1:-}"
if [[ "${E3D_PILOT_CHECK:-0}" == "1" ]]; then
  printf 'available (phase35-provider)\n'
  exit 0
fi
[[ -n "$prompt_file" && -f "$prompt_file" ]] || { echo "missing prompt" >&2; exit 1; }
case "$(basename "$prompt_file")" in
  draft-prompt.md)
    cat <<'OUT'
```spec
# Local Data Fixture

## Overview

Touch the README through the approved implementation flow.

## Goals

- Exercise local-data carry-forward into the execute worktree.

## Non-Goals

- No protected path changes.

## Existing Files

- `README.md`

## Shared Constraints

- Keep the fixture small.

## Phase 1 - Update Readme

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=README.md -->
<!-- runner:verify=test -f README.md -->

### Requirements

- Update README.md.

### Acceptance Criteria

- README.md still exists.
```

---DRAFT-STATUS---
status: ok
reason: scoped fixture
OUT
    ;;
  negotiate-*)
    cat <<'OUT'
---STATUS---
status: approved
reason: fixture approved
OUT
    ;;
  review-prompt.md)
    printf 'review ok\n'
    ;;
  *)
    echo "unexpected prompt: $prompt_file" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$PROVIDER"
}

# The stub csr backend itself is the assertion: it fails loudly if the
# gitignored local-data path isn't present in its own cwd (the fresh execute
# worktree) by the time it runs, and records what it actually saw so the
# test can also assert on the negative case (an unconfigured/missing path
# must never error, just be skipped).
make_csr_bin() {
  local bin_dir="$1" expect_marker="$2" trace_file="$3"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex-spec-runner" <<EOF
#!/usr/bin/env bash
set -euo pipefail
spec="\${1:?spec required}"
stage="\${2:?stage required}"
[[ "\$stage" == "all" && -f "\$spec" ]] || exit 1
if [[ -f "$expect_marker" ]]; then
  printf 'marker-present:%s\n' "\$(cat "$expect_marker")" >> "$trace_file"
else
  printf 'marker-missing\n' >> "$trace_file"
fi
mkdir -p .codex-spec-runner
printf '{"phase":1,"status":"ok"}\n' > .codex-spec-runner/manifest.json
printf '\nimplemented by phase35 csr\n' >> README.md
EOF
  chmod +x "$bin_dir/codex-spec-runner"
}

make_repo() {
  local local_data_paths_json="$1" repo
  repo="$(mktemp -d)"
  git init -q "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test User"
  cat > "$repo/README.md" <<'EOF'
# Phase 35 Repo
EOF
  # A real gitignored local-data directory: tracked in .gitignore, never
  # committed, exactly the pattern this feature exists for.
  mkdir -p "$repo/local-secrets"
  printf 'real-local-secret-value\n' > "$repo/local-secrets/marker.txt"
  printf 'local-secrets/\n' > "$repo/.gitignore"
  git -C "$repo" add README.md .gitignore
  git -C "$repo" commit -q -m "initial"
  mkdir -p "$repo/.e3d-pilot"
  jq \
    --argjson local_paths "$local_data_paths_json" \
    '.verify = ["test -f README.md"]
     | .pr.backend = "local"
     | .providers.draft = "phase35-provider"
     | .providers.negotiate = ["phase35-provider"]
     | .providers.review = "phase35-provider"
     | .execute_local_data_paths = $local_paths
     | del(.live_verify)' \
    "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  printf '%s' "$repo"
}

ingest_idea() {
  local repo="$1" run_id="$2" title="$3" candidate_json
  candidate_json="$(mktemp)"
  jq -ncS --arg title "$title" '{
    title:$title,
    summary:"Approved fixture implementation.",
    scores:{attraction:3,retention:3,revenue:2,effort:"low"},
    category:"testing",
    dedup_rationale:"new fixture",
    validation:{approvable:true,eligibility_reason:null,warnings:[]}
  }' > "$candidate_json"
  "$BIN" ideas ingest --repo "$repo" --run-id "$run_id" --candidate-id candidate-1 --candidate-json "$candidate_json"
  rm -f "$candidate_json"
}

configured_local_data_path_is_copied_into_worktree() {
  local repo bin_dir idea trace state
  repo="$(make_repo '["local-secrets"]')"
  bin_dir="$(mktemp -d)"
  trace="$(mktemp)"
  make_csr_bin "$bin_dir" "\$PWD/local-secrets/marker.txt" "$trace"
  idea="$(ingest_idea "$repo" run-1 "Local data carry-forward")"
  "$BIN" ideas approve --repo "$repo" "$idea" >/dev/null
  PATH="$bin_dir:$PATH" "$BIN" ideas implement --repo "$repo" "$idea" >/dev/null
  state="$("$BIN" ideas show --repo "$repo" "$idea" --json)"
  assert_eq "$(jq -r '.status' <<<"$state")" "implemented" "implemented with local data present"
  assert_contains "$(cat "$trace")" "marker-present:real-local-secret-value"
  rm -rf "$bin_dir"; rm -f "$trace"
}

unconfigured_or_missing_local_data_path_is_skipped_without_error() {
  local repo bin_dir idea trace state
  repo="$(make_repo '["does-not-exist-in-this-repo"]')"
  bin_dir="$(mktemp -d)"
  trace="$(mktemp)"
  make_csr_bin "$bin_dir" "\$PWD/does-not-exist-in-this-repo/marker.txt" "$trace"
  idea="$(ingest_idea "$repo" run-1 "Missing local data path")"
  "$BIN" ideas approve --repo "$repo" "$idea" >/dev/null
  PATH="$bin_dir:$PATH" "$BIN" ideas implement --repo "$repo" "$idea" >/dev/null
  state="$("$BIN" ideas show --repo "$repo" "$idea" --json)"
  assert_eq "$(jq -r '.status' <<<"$state")" "implemented" "implemented even though configured path does not exist"
  assert_contains "$(cat "$trace")" "marker-missing"
  rm -rf "$bin_dir"; rm -f "$trace"
}

no_config_field_defaults_to_copying_nothing() {
  local repo bin_dir idea state
  repo="$(make_repo 'null')"
  jq 'del(.execute_local_data_paths)' "$repo/.e3d-pilot/config.json" > "$repo/.e3d-pilot/config.json.tmp"
  mv "$repo/.e3d-pilot/config.json.tmp" "$repo/.e3d-pilot/config.json"
  bin_dir="$(mktemp -d)"
  make_csr_bin "$bin_dir" "\$PWD/local-secrets/marker.txt" "$(mktemp)"
  idea="$(ingest_idea "$repo" run-1 "No local data config")"
  "$BIN" ideas approve --repo "$repo" "$idea" >/dev/null
  PATH="$bin_dir:$PATH" "$BIN" ideas implement --repo "$repo" "$idea" >/dev/null
  state="$("$BIN" ideas show --repo "$repo" "$idea" --json)"
  assert_eq "$(jq -r '.status' <<<"$state")" "implemented" "implemented with no execute_local_data_paths configured at all"
  rm -rf "$bin_dir"
}

install_provider
bash -n "$ROOT/bin/e3d-pilot"
configured_local_data_path_is_copied_into_worktree
unconfigured_or_missing_local_data_path_is_skipped_without_error
no_config_field_defaults_to_copying_nothing

printf 'phase35 ok\n'
