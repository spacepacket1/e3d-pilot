#!/usr/bin/env bash
set -euo pipefail

# Tests for the pipeline-over-MCP tools (bin/e3d-mcp). Uses fake providers and a fake e3d-code only,
# so it spends no credits and needs no network.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export E3D_MCP_STATE_DIR="$(mktemp -d)"  # keep usage accounting out of ~/.e3d-pilot during tests
SERVER="$ROOT/bin/e3d-mcp"
CLIENT="$ROOT/tests/fixtures/mcp-test-client.mjs"
SAMPLE_CONFIG="$ROOT/examples/sample-config.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-assert_eq}: expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "${3:-assert_contains}: expected to find [$2] in [$1]"; }

mk_repo() {
  local repo="$TMP/$1"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name Test
  printf '# fixture\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m init
  mkdir -p "$repo/.e3d-pilot"
  cp "$SAMPLE_CONFIG" "$repo/.e3d-pilot/config.json"
  (cd "$repo" && pwd -P)
}

# client '<plan json>' -> prints the client's JSON result
client() { node "$CLIENT" "$1"; }
# call_tool <env-json> <tool> <args-json> [extra plan keys as json object]
call_tool() {
  local env="$1" name="$2" args="$3" extra="${4:-{\}}"
  client "$(jq -nc --arg s "$SERVER" --argjson env "$env" --arg n "$name" --argjson a "$args" --argjson x "$extra" \
    '{server:$s, env:$env, calls:[{name:$n, arguments:$a}]} + $x')"
}
text_of() { jq -r '.results[0].content[0].text'; }
is_error() { jq -r '.results[0].isError // false'; }

REPO_A="$(mk_repo repoA)"
REPO_B="$(mk_repo repoB)"
ENV_A="$(jq -nc --arg r "$REPO_A" '{E3D_MCP_REPOS:$r}')"

# ---- tools/list ----
tools="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | "$SERVER" 2>/dev/null)"
for t in e3d_pilot_config_check e3d_pilot_job_status e3d_pilot_artifact; do
  jq -e --arg t "$t" '.result.tools | map(.name) | index($t) != null' <<< "$tools" >/dev/null || fail "tools/list is missing $t"
  assert_eq "$(jq -r --arg t "$t" '.result.tools[] | select(.name==$t) | .annotations.readOnlyHint' <<< "$tools")" "true" "$t is read-only"
  jq -e --arg t "$t" '.result.tools[] | select(.name==$t) | .description | test("FREE")' <<< "$tools" >/dev/null || fail "$t description must say it is free"
done

# ---- repo allowlist ----
out="$(call_tool "$ENV_A" e3d_pilot_config_check "$(jq -nc --arg r "$REPO_A" '{repo:$r}')")"
assert_eq "$(is_error <<< "$out")" "false" "allowed repo"
assert_eq "$(jq -r '.results[0].structuredContent.valid' <<< "$out")" "true" "sample config validates"

out="$(call_tool "$ENV_A" e3d_pilot_config_check "$(jq -nc --arg r "$REPO_B" '{repo:$r}')")"
assert_eq "$(is_error <<< "$out")" "true" "repo outside the allowlist must be rejected"
assert_contains "$(text_of <<< "$out")" "outside the allowed roots"

out="$(call_tool "$ENV_A" e3d_pilot_config_check '{"repo":"relative/path"}')"
assert_contains "$(text_of <<< "$out")" "absolute path"

out="$(call_tool "$ENV_A" e3d_pilot_config_check "$(jq -nc --arg r "$TMP/nope" '{repo:$r}')")"
assert_contains "$(text_of <<< "$out")" "repo not found"

# a symlink inside the allowed root that points at a repo outside it
mkdir -p "$TMP/parent"
ln -s "$REPO_B" "$TMP/parent/escape"
ln -s "$REPO_A" "$TMP/parent/inside"
ENV_PARENT="$(jq -nc --arg r "$TMP/parent" '{E3D_MCP_REPOS:$r}')"
out="$(call_tool "$ENV_PARENT" e3d_pilot_config_check "$(jq -nc --arg r "$TMP/parent/escape" '{repo:$r}')")"
assert_eq "$(is_error <<< "$out")" "true" "symlink escape must be rejected"
assert_contains "$(text_of <<< "$out")" "outside the allowed roots"
# note: REPO_A lives in $TMP, not under $TMP/parent, so even the "inside" link points outside that root
out="$(call_tool "$ENV_PARENT" e3d_pilot_config_check "$(jq -nc --arg r "$TMP/parent/inside" '{repo:$r}')")"
assert_eq "$(is_error <<< "$out")" "true" "a symlink is judged by where it resolves, not where it sits"

# not the top level of a git repo / not a git repo at all
mkdir -p "$REPO_A/subdir" "$TMP/plain"
out="$(call_tool "$ENV_A" e3d_pilot_config_check "$(jq -nc --arg r "$REPO_A/subdir" '{repo:$r}')")"
assert_contains "$(text_of <<< "$out")" "not the top level of a git repository"
ENV_TMP="$(jq -nc --arg r "$TMP" '{E3D_MCP_REPOS:$r}')"
out="$(call_tool "$ENV_TMP" e3d_pilot_config_check "$(jq -nc --arg r "$TMP/plain" '{repo:$r}')")"
assert_contains "$(text_of <<< "$out")" "not the top level of a git repository"

# the client's workspace roots are the default allowlist (no E3D_MCP_REPOS)
out="$(call_tool '{}' e3d_pilot_config_check "$(jq -nc --arg r "$REPO_A" '{repo:$r}')" "$(jq -nc --arg r "$REPO_A" '{capabilities:{roots:{}}, roots:[$r]}')")"
assert_eq "$(is_error <<< "$out")" "false" "client root should allow its own workspace"
out="$(call_tool '{}' e3d_pilot_config_check "$(jq -nc --arg r "$REPO_B" '{repo:$r}')" "$(jq -nc --arg r "$REPO_A" '{capabilities:{roots:{}}, roots:[$r]}')")"
assert_eq "$(is_error <<< "$out")" "true" "a repo outside the client's roots must be rejected"
# no env, no roots, and a working directory that is not a git repo -> nothing is allowed
out="$(call_tool '{}' e3d_pilot_config_check "$(jq -nc --arg r "$REPO_A" '{repo:$r}')" "$(jq -nc --arg c "$TMP/plain" '{cwd:$c}')")"
assert_contains "$(text_of <<< "$out")" "no repositories are allowed yet"

# ---- config check ----
BAD="$(mk_repo bad)"
printf '{ not json' > "$BAD/.e3d-pilot/config.json"
ENV_BAD="$(jq -nc --arg r "$BAD" '{E3D_MCP_REPOS:$r}')"
out="$(call_tool "$ENV_BAD" e3d_pilot_config_check "$(jq -nc --arg r "$BAD" '{repo:$r}')")"
assert_eq "$(jq -r '.results[0].structuredContent.valid' <<< "$out")" "false" "invalid config is reported, not thrown"
assert_eq "$(jq -r '.results[0].structuredContent.ready_to_execute' <<< "$out")" "false"
out="$(call_tool "$ENV_A" e3d_pilot_config_check "$(jq -nc --arg r "$REPO_A" '{repo:$r}')")"
assert_eq "$(jq -r '.results[0].structuredContent.execute_backend' <<< "$out")" "e3d-code"
jq -e '.results[0].structuredContent.e3d_code | has("needed") and has("found")' <<< "$out" >/dev/null || fail "config_check must report e3d-code availability"

# ---- job status over crafted job files (the engine's classification of every outcome) ----
JOBS="$REPO_A/.e3d-pilot/mcp-jobs"
mkdir -p "$JOBS"
craft_job() {  # craft_job <id> <state> <pid> <started-iso> [timeout_ms] [run_id]
  jq -n --arg id "$1" --arg repo "$REPO_A" --arg state "$2" --argjson pid "$3" --arg started "$4" \
        --argjson timeout "${5:-3600000}" --arg run "${6:-}" --arg dir "$JOBS" \
    '{job_id:$id, repo:$repo, kind:"stage", label:"run --stage all", args:["run","--repo",$repo,"--stage","all"],
      run_id:(if $run=="" then null else $run end), idea_id:null, state:$state, started_at:$started, finished_at:null,
      timeout_ms:$timeout, latest_run_before:null, log_file:($dir+"/"+$id+".log"), exit_file:($dir+"/"+$id+".exit"), pid:$pid, exit_code:null}' > "$JOBS/$1.json"
}
status_of_job() {  # status_of_job <id> -> structuredContent json
  call_tool "$ENV_A" e3d_pilot_job_status "$(jq -nc --arg r "$REPO_A" --arg j "$1" '{repo:$r, job_id:$j}')" | jq -c '.results[0].structuredContent'
}
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# exit 0 -> succeeded
craft_job job-ok running 999999 "$NOW"; printf 'discover: done\n' > "$JOBS/job-ok.log"; printf 0 > "$JOBS/job-ok.exit"
assert_eq "$(status_of_job job-ok | jq -r .state)" "succeeded" "exit 0"
# exit 0 + pending-approval marker -> waiting_for_human with the idea id
craft_job job-gate running 999999 "$NOW"
printf 'ideate: idea idea-abc is not approved for implementation (status: proposed); stopping before draft\npilot: pending-approval idea=idea-abc status=proposed\n' > "$JOBS/job-gate.log"; printf 0 > "$JOBS/job-gate.exit"
s="$(status_of_job job-gate)"
assert_eq "$(jq -r .state <<< "$s")" "waiting_for_human" "approval gate"
assert_eq "$(jq -r .idea_id <<< "$s")" "idea-abc"
assert_contains "$(jq -r .next_action <<< "$s")" "ideas approve"
# exit 0 + paused marker -> waiting_for_human, paused_before
craft_job job-paused running 999999 "$NOW"
printf 'ideas: paused idea-abc run=impl-1 before=execute\n' > "$JOBS/job-paused.log"; printf 0 > "$JOBS/job-paused.exit"
s="$(status_of_job job-paused)"
assert_eq "$(jq -r .state <<< "$s")" "waiting_for_human" "paused"
assert_eq "$(jq -r .paused_before <<< "$s")" "execute"

# the draft's scope warnings are kept on the job record as a LIST (not only printed in the status text)
RUNW="$REPO_A/.e3d-pilot/runs/impl-warn"; mkdir -p "$RUNW"
printf 'Drafted spec has an estimated ~200 changed lines, exceeding max_diff_lines=100; advisory only\n' > "$RUNW/draft-scope-warnings.txt"
craft_job job-warn running 999999 "$NOW" 3600000 impl-warn
printf 'ideas: paused idea-abc run=impl-warn before=execute\n' > "$JOBS/job-warn.log"; printf 0 > "$JOBS/job-warn.exit"
s="$(status_of_job job-warn)"
assert_eq "$(jq -r '.warnings | length' <<< "$s")" "1" "status warnings is a list"
assert_contains "$(jq -r '.warnings[0]' <<< "$s")" "max_diff_lines=100"
assert_contains "$(jq -c '.warnings' "$JOBS/job-warn.json")" "max_diff_lines=100" "the stored job record carries the warnings list"
# a failed implementation names its real cause, not just "exited 1"
RUNF="$REPO_A/.e3d-pilot/runs/impl-fail"; mkdir -p "$RUNF"
printf '# Draft rejected\n\nstatus: too-large\nThe repo has only README.md, so the scope cannot be estimated\n' > "$RUNF/draft-rejected.md"
craft_job job-fail running 999999 "$NOW" 3600000 impl-fail
printf 'ideas: implementation failed for idea-x run=impl-fail\n' > "$JOBS/job-fail.log"; printf 1 > "$JOBS/job-fail.exit"
s="$(status_of_job job-fail)"
assert_eq "$(jq -r .state <<< "$s")" "failed"
assert_contains "$(jq -r .failure_detail <<< "$s")" "too-large" "the real cause is in failure_detail"
assert_contains "$(jq -r .reason <<< "$s")" "Cause: draft-rejected.md" "and in the reason"
# after a cancel the log still ends with the old "paused" line: the status says it is history
craft_job job-cancelled cancelled 999999 "$NOW"
printf 'ideas: paused idea-abc run=impl-1 before=execute\n' > "$JOBS/job-cancelled.log"
tmp_job="$(jq '.reason="cancelled: QA test" | .finished_at=$n' --arg n "$NOW" "$JOBS/job-cancelled.json")"; printf '%s' "$tmp_job" > "$JOBS/job-cancelled.json"
out="$(call_tool "$ENV_A" e3d_pilot_job_status "$(jq -nc --arg r "$REPO_A" '{repo:$r, job_id:"job-cancelled"}')")"
assert_contains "$(text_of <<< "$out")" "history, not current state" "a cancelled job's old log line must not read as current"
assert_eq "$(jq -r '.results[0].structuredContent.log_is_stale' <<< "$out")" "true"
# CLI exit codes 3/4 -> waiting_for_human, 5 -> failed, 6 -> blocked, 1 -> failed with the last log line
for pair in "3:waiting_for_human" "4:waiting_for_human" "5:failed" "6:blocked" "1:failed"; do
  code="${pair%%:*}"; want="${pair##*:}"
  craft_job "job-x$code" running 999999 "$NOW"; printf 'some output\nlast line %s\n' "$code" > "$JOBS/job-x$code.log"; printf '%s' "$code" > "$JOBS/job-x$code.exit"
  assert_eq "$(status_of_job "job-x$code" | jq -r .state)" "$want" "exit code $code"
done
assert_contains "$(status_of_job job-x1 | jq -r .reason)" "last line 1"
# a process that vanished without an exit file
craft_job job-gone running 999999 "$NOW"
s="$(status_of_job job-gone)"
assert_eq "$(jq -r .state <<< "$s")" "failed" "vanished process"
assert_contains "$(jq -r .reason <<< "$s")" "without reporting an exit code"
# timeout kills the process group and marks the job failed
python3 -c 'import os,time; os.setsid(); time.sleep(300)' & SLEEPER=$!
sleep 0.5
craft_job job-slow running "$SLEEPER" "2020-01-01T00:00:00Z" 1000
s="$(status_of_job job-slow)"
assert_eq "$(jq -r .state <<< "$s")" "failed" "timed out job"
assert_contains "$(jq -r .reason <<< "$s")" "timed out"
sleep 0.5
kill -0 "$SLEEPER" 2>/dev/null && fail "the timed-out process should have been stopped"
# secrets in logs are redacted in status output
craft_job job-secret running 999999 "$NOW"; printf 'ANTHROPIC_API_KEY=sk-abcdefghijklmnopqrstuv123 leaked?\n' > "$JOBS/job-secret.log"; printf 0 > "$JOBS/job-secret.exit"
tailtxt="$(status_of_job job-secret | jq -r '.log_tail | join("\n")')"
[[ "$tailtxt" != *abcdefghijklmnop* ]] || fail "status must redact secrets from log tails"
# invalid / unknown job ids
out="$(call_tool "$ENV_A" e3d_pilot_job_status "$(jq -nc --arg r "$REPO_A" '{repo:$r, job_id:"../../etc/passwd"}')")"
assert_eq "$(is_error <<< "$out")" "true" "path-like job id"
# no job_id -> latest job
craft_job job-zzz-latest running 999999 "2099-01-01T00:00:00Z"; printf 'x\n' > "$JOBS/job-zzz-latest.log"; printf 0 > "$JOBS/job-zzz-latest.exit"
out="$(call_tool "$ENV_A" e3d_pilot_job_status "$(jq -nc --arg r "$REPO_A" '{repo:$r}')")"
assert_eq "$(jq -r '.results[0].structuredContent.job_id' <<< "$out")" "job-zzz-latest" "default is the latest job"

# wait_seconds: returns as soon as the job settles, and reports progress when asked
python3 - "$JOBS/job-wait.exit" <<'PY' &
import os,sys,time
os.setsid()
time.sleep(2.5)
open(sys.argv[1],'w').write('0')
PY
WAITER=$!
sleep 0.3
craft_job job-wait running "$WAITER" "$NOW"; printf 'working...\n' > "$JOBS/job-wait.log"
out="$(client "$(jq -nc --arg s "$SERVER" --argjson env "$ENV_A" --arg r "$REPO_A" \
  '{server:$s, env:$env, calls:[{name:"e3d_pilot_job_status", arguments:{repo:$r, job_id:"job-wait", wait_seconds:20}, progress:true}]}')")"
assert_eq "$(jq -r '.results[0].structuredContent.state' <<< "$out")" "succeeded" "wait_seconds returns once the job settles"
jq -e '[.events[] | select(.notification=="notifications/progress")] | length >= 1' <<< "$out" >/dev/null || fail "expected progress notifications while waiting"

# ---- artifacts ----
RUN="run-art-1"; RD="$REPO_A/.e3d-pilot/runs/$RUN"; mkdir -p "$RD/e3d-code-state/summaries"
printf '# Spec\n\n## Phase 1 - A\n' > "$RD/spec-final.md"
printf 'token=hunter2-should-not-leak\n' > "$RD/findings.md"
head -c 5000 /dev/zero | tr '\0' 'x' > "$RD/candidates.md"
printf '2026-10-16T10:00:00-0700\tspec.md\t1\tCore Parser\tcodex\tgpt-5.4-mini\texec\t0\t0\n2026-10-16T10:05:00-0700\tspec.md\t2\tWriter\tclaude\tsonnet\texec\t0\t1\n' > "$RD/e3d-code-state/manifest.tsv"
printf 'Phase 1 summary: verify passed\n' > "$RD/e3d-code-state/summaries/phase-1.md"
art() { call_tool "$ENV_A" e3d_pilot_artifact "$(jq -nc --arg r "$REPO_A" --arg run "$RUN" --argjson x "$1" '{repo:$r, run_id:$run} + $x')"; }

out="$(art '{"name":"list"}')"
for n in spec-final findings candidates manifest phase-summary; do jq -e --arg n "$n" '.results[0].structuredContent.artifacts | index($n) != null' <<< "$out" >/dev/null || fail "list should include $n"; done
out="$(art '{"name":"spec-final"}')"; assert_contains "$(text_of <<< "$out")" "## Phase 1 - A"
out="$(art '{"name":"findings"}')"
[[ "$(text_of <<< "$out")" != *hunter2* ]] || fail "artifacts must be redacted"
out="$(art '{"name":"candidates","max_bytes":1000}')"
assert_eq "$(jq -r '.results[0].structuredContent.truncated' <<< "$out")" "true" "size cap"
assert_eq "$(jq -r '.results[0].structuredContent.content | length' <<< "$out")" "1000" "capped length"
out="$(art '{"name":"manifest"}')"
assert_eq "$(jq -r '.results[0].structuredContent.phases | length' <<< "$out")" "2"
assert_eq "$(jq -r '.results[0].structuredContent.phases[0].model' <<< "$out")" "gpt-5.4-mini" "per-phase model"
assert_eq "$(jq -r '.results[0].structuredContent.phases[0].succeeded' <<< "$out")" "true"
assert_eq "$(jq -r '.results[0].structuredContent.phases[1].succeeded' <<< "$out")" "false" "dry-run rows do not count as success"
out="$(art '{"name":"phase-summary","phase":1}')"; assert_contains "$(text_of <<< "$out")" "verify passed"
out="$(art '{"name":"../../../etc/passwd"}')"; assert_eq "$(is_error <<< "$out")" "true" "traversal via name"
out="$(call_tool "$ENV_A" e3d_pilot_artifact "$(jq -nc --arg r "$REPO_A" '{repo:$r, run_id:"../..", name:"list"}')")"; assert_eq "$(is_error <<< "$out")" "true" "traversal via run_id"
out="$(art '{"name":"spec-draft"}')"; assert_eq "$(is_error <<< "$out")" "true" "missing artifact is an error"
# legacy runs keep the pre-rename state directory name
RUN2="run-art-legacy"; mkdir -p "$REPO_A/.e3d-pilot/runs/$RUN2/s2c-state"
printf 't\tspec.md\t1\tOld\tcodex\tgpt\texec\t0\t0\n' > "$REPO_A/.e3d-pilot/runs/$RUN2/s2c-state/manifest.tsv"
out="$(call_tool "$ENV_A" e3d_pilot_artifact "$(jq -nc --arg r "$REPO_A" --arg run "$RUN2" '{repo:$r, run_id:$run, name:"manifest"}')")"
assert_eq "$(jq -r '.results[0].structuredContent.phases[0].title' <<< "$out")" "Old" "legacy s2c-state is still readable"

echo "mcp-pipeline.sh: ok"
