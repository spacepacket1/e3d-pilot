#!/usr/bin/env bash
set -euo pipefail

# End-to-end tests of the pipeline-over-MCP tools: propose -> approve gate -> implement (pauses) -> code_plan
# -> execute -> PR, plus the refusals. Fake providers, a fake e3d-code and a fake gh: no credits, no network.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export E3D_MCP_STATE_DIR="$(mktemp -d)"  # keep usage accounting out of ~/.e3d-pilot during tests
SERVER="$ROOT/bin/e3d-mcp"
BIN="$ROOT/bin/e3d-pilot"
CLIENT="$ROOT/tests/fixtures/mcp-test-client.mjs"
SAMPLE_CONFIG="$ROOT/examples/sample-config.json"
PROVIDER="$ROOT/lib/providers/mcpflow-provider"
SLEEPY="$ROOT/lib/providers/mcpflow-sleepy"
TMP="$(mktemp -d)"
cleanup() { rm -f "$PROVIDER" "$SLEEPY"; pkill -f "mcpflow-sleepy" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-assert_eq}: expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "${3:-assert_contains}: expected to find [$2] in [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "${3:-assert_not_contains}: did not expect [$2] in [$1]"; }

cat > "$PROVIDER" <<'PEOF'
#!/usr/bin/env bash
set -euo pipefail
prompt_file="${1:-}"
if [[ "${E3D_PILOT_CHECK:-0}" == "1" ]]; then printf 'available (mcpflow-provider)\n'; exit 0; fi
[[ -n "$prompt_file" && -f "$prompt_file" ]] || { echo "missing prompt" >&2; exit 1; }
trace() { [[ -n "${MCPFLOW_PROVIDER_TRACE:-}" ]] && printf '%s\n' "$1" >> "$MCPFLOW_PROVIDER_TRACE" || true; }
case "$(basename "$prompt_file")" in
  draft-prompt.md)
    trace draft
    cat <<'OUT'
```spec
# MCP Flow Fixture

## Overview

Touch the README through the approved flow.

## Goals

- Exercise the MCP pipeline tools.

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
  negotiate-*) trace negotiate; printf -- '---STATUS---\nstatus: approved\nreason: fixture approved\n' ;;
  review-prompt.md) trace review; printf 'review ok\n' ;;
  *) echo "unexpected prompt: $prompt_file" >&2; exit 1 ;;
esac
PEOF
cat > "$SLEEPY" <<'SEOF'
#!/usr/bin/env bash
if [[ "${E3D_PILOT_CHECK:-0}" == "1" ]]; then printf 'available (mcpflow-sleepy)\n'; exit 0; fi
exec -a mcpflow-sleepy sleep "${SLEEPY_SECS:-60}"
SEOF
chmod +x "$PROVIDER" "$SLEEPY"

FAKE_BIN="$TMP/fakebin"; mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/e3d-code" <<'CEOF'
#!/usr/bin/env bash
set -euo pipefail
spec="${1:?spec required}"; shift || true
mode="${1:-}"
[[ -n "${MCPFLOW_CODE_TRACE:-}" ]] && printf '%s\n' "${mode:-none}" >> "$MCPFLOW_CODE_TRACE"
case "$mode" in
  --list) awk '/^## Phase [0-9]+ - /{ sub(/^## Phase /,""); n=$1; sub(/^[0-9]+ - /,""); printf "Phase %s\tcodex\tgpt-5.4-mini\t%s\n", n, $0 }' "$spec" ;;
  --preflight) echo "result: ok" ;;
  all)
    mkdir -p .e3d-code
    printf 'ts\tspec.md\t1\tUpdate Readme\tcodex\tgpt-5.4-mini\texec\t0\t0\n' >> .e3d-code/manifest.tsv
    printf '\nimplemented by mcpflow e3d-code\n' >> README.md ;;
  *) echo "unexpected e3d-code mode: $mode" >&2; exit 1 ;;
esac
CEOF
cat > "$FAKE_BIN/gh" <<'GEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "pr" && "${2:-}" == "create" ]]; then echo "https://github.com/example/mcpflow/pull/1"; exit 0; fi
exit 1
GEOF
chmod +x "$FAKE_BIN/e3d-code" "$FAKE_BIN/gh"

CODE_TRACE="$TMP/code-trace"; PROVIDER_TRACE="$TMP/provider-trace"; : > "$CODE_TRACE"; : > "$PROVIDER_TRACE"

mk_repo() {
  local repo="$TMP/$1" bare="$TMP/$1.git"
  mkdir -p "$repo"; git init -q "$repo"
  git -C "$repo" config user.email t@example.com; git -C "$repo" config user.name Test
  printf '# MCP flow repo\n' > "$repo/README.md"; git -C "$repo" add README.md; git -C "$repo" commit -q -m init
  git init -q --bare "$bare"; git -C "$repo" remote add origin "$bare"
  mkdir -p "$repo/.e3d-pilot"
  jq '.verify = ["test -f README.md"] | .pr.backend = "github" | .pr.labels = ["e3d-pilot"]
      | .providers.draft = "mcpflow-provider" | .providers.negotiate = ["mcpflow-provider"] | .providers.review = "mcpflow-provider"
      | .providers.discover = "mcpflow-sleepy" | del(.live_verify)' "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  (cd "$repo" && pwd -P)
}

# mcp <repo> <tool> <args-json> [extra-plan-json] -> client output. Extra env via MCP_ENV (json object).
mcp() {
  local repo="$1" name="$2" args="$3" extra="${4:-{\}}"
  local env; env="$(jq -nc --arg r "$repo" --arg p "$FAKE_BIN:$PATH" --arg ct "$CODE_TRACE" --arg pt "$PROVIDER_TRACE" --argjson x "${MCP_ENV:-{\}}" \
    '{E3D_MCP_REPOS:$r, PATH:$p, MCPFLOW_CODE_TRACE:$ct, MCPFLOW_PROVIDER_TRACE:$pt} + $x')"
  node "$CLIENT" "$(jq -nc --arg s "$SERVER" --argjson env "$env" --arg n "$name" --argjson a "$args" --argjson x "$extra" \
    '{server:$s, env:$env, calls:[{name:$n, arguments:$a}]} + $x')"
}
sc() { jq -c '.results[0].structuredContent'; }
txt() { jq -r '.results[0].content[0].text'; }
iserr() { jq -r '.results[0].isError // false'; }
ELICIT_YES='{"capabilities":{"elicitation":{}},"elicit":{"action":"accept","content":{"confirm":true}}}'
ELICIT_NO='{"capabilities":{"elicitation":{}},"elicit":{"action":"decline"}}'

idea_status() { "$BIN" ideas show --repo "$1" "$2" --json | jq -r .status; }
propose() { mcp "$1" e3d_pilot_propose "$(jq -nc --arg r "$1" --arg t "$2" '{repo:$r,title:$t,rationale:"Touch the README safely."}')" | sc | jq -r .idea_id; }
cli_approve() { "$BIN" ideas approve --repo "$1" "$2" --actor human@example.com >/dev/null; }
wait_job() {  # wait_job <repo> <job_id> -> final structuredContent (polls with wait_seconds)
  local out state i
  for i in 1 2 3 4; do
    out="$(mcp "$1" e3d_pilot_job_status "$(jq -nc --arg r "$1" --arg j "$2" '{repo:$r,job_id:$j,wait_seconds:45}')" | sc)"
    state="$(jq -r .state <<< "$out")"
    [[ "$state" != "running" ]] && break
  done
  printf '%s' "$out"
}

# ================= happy path =================
REPO="$(mk_repo happy)"
out="$(mcp "$REPO" e3d_pilot_propose "$(jq -nc --arg r "$REPO" '{repo:$r,title:"Touch the README",rationale:"Make a tiny README change.",source:{question:"JSON or SQLite?",final_answer:"Use JSON.",consensus:"split",dissent:{present:true,summary:"Codex prefers SQLite."},providers:["claude","codex"],positions:[{provider:"claude",text:"JSON."},{provider:"codex",text:"SQLite."}]}}')")"
assert_eq "$(iserr <<< "$out")" "false" "propose"
IDEA="$(sc <<< "$out" | jq -r .idea_id)"
[[ "$IDEA" == idea-* ]] || fail "propose should return an idea id, got [$IDEA]"
assert_eq "$(idea_status "$REPO" "$IDEA")" "proposed"
EVID="$(sc <<< "$out" | jq -r .evidence_ref)"
[[ -f "$REPO/$EVID" ]] || fail "debate evidence file should exist at $EVID"
assert_contains "$(cat "$REPO/$EVID")" "Codex prefers SQLite."
assert_contains "$(cat "$REPO/.e3d-pilot/events.jsonl")" "e3d_debate verdict (split)"
assert_contains "$(cat "$REPO/.e3d-pilot/events.jsonl")" "mcp:test-client"
assert_eq "$(jq -r 'select(.event=="idea_proposed" and .idea_id=="'"$IDEA"'") | .actor' "$REPO/.e3d-pilot/events.jsonl")" "mcp:test-client" "the proposer is recorded, not \"system\""

# input limits are enforced, not just declared
out="$(mcp "$REPO" e3d_pilot_propose "$(jq -nc --arg r "$REPO" --arg t "$(head -c 300 /dev/zero | tr '\0' 'x')" '{repo:$r,title:$t,rationale:"r"}')")"
assert_eq "$(iserr <<< "$out")" "true" "over-long title"; assert_contains "$(txt <<< "$out")" "200 characters"
out="$(mcp "$REPO" e3d_pilot_propose "$(jq -nc --arg r "$REPO" '{repo:$r,title:"t",rationale:"r",category:"bad/category"}')")"
assert_eq "$(iserr <<< "$out")" "true" "bad category"

# --- gate 1: approval stays human ---
out="$(mcp "$REPO" e3d_pilot_approve "$(jq -nc --arg r "$REPO" --arg i "$IDEA" '{repo:$r,idea_id:$i}')" "$ELICIT_YES")"
assert_eq "$(sc <<< "$out" | jq -r .outcome)" "waiting_for_human" "approval is read-only by default, even if the client could be asked"
assert_contains "$(sc <<< "$out" | jq -r .cli_command)" "ideas approve --repo $REPO $IDEA"
assert_eq "$(idea_status "$REPO" "$IDEA")" "proposed" "nothing was approved"
MCP_ENV='{"E3D_MCP_ALLOW_APPROVAL":"1"}'
out="$(mcp "$REPO" e3d_pilot_approve "$(jq -nc --arg r "$REPO" --arg i "$IDEA" '{repo:$r,idea_id:$i}')")"
assert_eq "$(sc <<< "$out" | jq -r .outcome)" "waiting_for_human" "enabled but the client cannot prompt the person -> still read-only"
out="$(mcp "$REPO" e3d_pilot_approve "$(jq -nc --arg r "$REPO" --arg i "$IDEA" '{repo:$r,idea_id:$i}')" "$ELICIT_NO")"
assert_eq "$(sc <<< "$out" | jq -r .outcome)" "declined" "the person said no"
assert_contains "$(jq -r 'select(.idea_id=="'"$IDEA"'") | .text // empty' "$REPO/.e3d-pilot/events.jsonl")" "approval was declined by the person in the editor" "a declined approval must leave an audit note"
assert_eq "$(idea_status "$REPO" "$IDEA")" "proposed" "declined approval changes nothing"
out="$(mcp "$REPO" e3d_pilot_approve "$(jq -nc --arg r "$REPO" --arg i "$IDEA" '{repo:$r,idea_id:$i}')" "$ELICIT_YES")"
assert_eq "$(sc <<< "$out" | jq -r .outcome)" "approved" "the person confirmed in the editor"
jq -e '[.events[] | select(.request=="elicitation/create")] | length == 1' <<< "$out" >/dev/null || fail "approval must go through an elicitation prompt"
assert_contains "$(jq -r '.events[] | select(.request=="elicitation/create") | .params.message' <<< "$out")" "does NOT authorize merging"
assert_eq "$(idea_status "$REPO" "$IDEA")" "approved_for_implementation"
MCP_ENV='{}'

# --- before pausing: nothing to plan or execute ---
out="$(mcp "$REPO" e3d_pilot_execute "$(jq -nc --arg r "$REPO" --arg i "$IDEA" '{repo:$r,idea_id:$i,plan_token:"x"}')")"
assert_eq "$(iserr <<< "$out")" "true"; assert_contains "$(txt <<< "$out")" "no implementation paused"
out="$(mcp "$REPO" e3d_pilot_code_plan "$(jq -nc --arg r "$REPO" --arg i "$IDEA" '{repo:$r,idea_id:$i}')")"
assert_eq "$(iserr <<< "$out")" "true"

# an unapproved idea cannot be implemented
IDEA2="$(propose "$REPO" "Another idea")"
out="$(mcp "$REPO" e3d_pilot_implement "$(jq -nc --arg r "$REPO" --arg i "$IDEA2" '{repo:$r,idea_id:$i}')")"
assert_eq "$(iserr <<< "$out")" "true" "implement requires approval"; assert_contains "$(txt <<< "$out")" "not approved yet"

# --- implement: drafts and negotiates, then pauses before any code ---
out="$(mcp "$REPO" e3d_pilot_implement "$(jq -nc --arg r "$REPO" --arg i "$IDEA" '{repo:$r,idea_id:$i}')")"
JOB="$(sc <<< "$out" | jq -r .job_id)"; [[ "$JOB" == job-* ]] || fail "implement should return a job id"
final="$(wait_job "$REPO" "$JOB")"
assert_eq "$(jq -r .state <<< "$final")" "waiting_for_human" "paused: $(jq -c . <<< "$final" | cut -c1-300)"
assert_eq "$(jq -r .paused_before <<< "$final")" "execute"
RUN="$(jq -r .run_id <<< "$final")"; [[ -n "$RUN" && "$RUN" != null ]] || fail "paused job should report its run id"
assert_eq "$(wc -l < "$CODE_TRACE" | tr -d ' ')" "0" "e3d-code must not have run before the pause"
assert_eq "$(idea_status "$REPO" "$IDEA")" "implementing"
art="$(mcp "$REPO" e3d_pilot_artifact "$(jq -nc --arg r "$REPO" --arg run "$RUN" '{repo:$r,run_id:$run,name:"spec-final"}')")"
assert_contains "$(txt <<< "$art")" "## Phase 1 - Update Readme"

# --- execute refuses without a plan, with a wrong token, and when the spec or HEAD moved ---
EX() { mcp "$REPO" e3d_pilot_execute "$(jq -nc --arg r "$REPO" --arg i "$IDEA" --arg t "$1" '{repo:$r,idea_id:$i,plan_token:$t}')"; }
out="$(EX anything)"; assert_eq "$(iserr <<< "$out")" "true"; assert_contains "$(txt <<< "$out")" "no plan on record"
printf 'Drafted spec has an estimated ~180 changed lines (9 bullets x 20 lines/bullet), exceeding max_diff_lines=100; advisory only (the actual post-execution diff ceiling remains enforced)\n' > "$REPO/.e3d-pilot/runs/$RUN/draft-scope-warnings.txt"
st="$(mcp "$REPO" e3d_pilot_job_status "$(jq -nc --arg r "$REPO" --arg j "$JOB" '{repo:$r,job_id:$j}')" | sc)"
assert_contains "$(jq -r '.warnings | join(" ")' <<< "$st")" "estimated ~180 changed lines" "a paused job's status must carry the draft's scope warning"
art2="$(mcp "$REPO" e3d_pilot_artifact "$(jq -nc --arg r "$REPO" --arg run "$RUN" '{repo:$r,run_id:$run,name:"draft-warnings"}')")"
assert_contains "$(txt <<< "$art2")" "max_diff_lines=100"
plan="$(mcp "$REPO" e3d_pilot_code_plan "$(jq -nc --arg r "$REPO" --arg i "$IDEA" '{repo:$r,idea_id:$i}')")"
assert_eq "$(iserr <<< "$plan")" "false" "code_plan"
assert_contains "$(sc <<< "$plan" | jq -r '.warnings | join(" ")')" "draft: Drafted spec has an estimated ~180 changed lines" "the plan must surface the draft's scope warning"
assert_contains "$(txt <<< "$plan")" "WARNING: draft:"
TOKEN="$(sc <<< "$plan" | jq -r .plan_token)"; [[ -n "$TOKEN" && "$TOKEN" != null ]] || fail "plan token"
assert_eq "$(sc <<< "$plan" | jq -r '.phases | length')" "1"
assert_eq "$(sc <<< "$plan" | jq -r '.phases[0].model')" "gpt-5.4-mini"
assert_eq "$(sc <<< "$plan" | jq -r '.phases[0].touches[0]')" "README.md"
assert_eq "$(sc <<< "$plan" | jq -r '.preflight.ok')" "true"
assert_contains "$(txt <<< "$plan")" "Show this to the user"
assert_not_contains "$(cat "$CODE_TRACE")" "--dry-run" "the plan must never use --dry-run (it writes state)"
[[ ! -d "$REPO/.e3d-code" ]] || fail "planning must not create e3d-code state in the repo"
assert_eq "$(wc -l < "$CODE_TRACE" | tr -d ' ')" "2" "plan = exactly --list and --preflight"
out="$(EX wrong-token)"; assert_eq "$(iserr <<< "$out")" "true"; assert_contains "$(txt <<< "$out")" "does not match"

SPEC="$REPO/.e3d-pilot/runs/$RUN/spec-final.md"; cp "$SPEC" "$TMP/spec-final.orig"
printf '\n<!-- edited after the plan -->\n' >> "$SPEC"
out="$(EX "$TOKEN")"; assert_eq "$(iserr <<< "$out")" "true"; assert_contains "$(txt <<< "$out")" "spec changed"
cp "$TMP/spec-final.orig" "$SPEC"
printf 'drift\n' >> "$REPO/README.md"; git -C "$REPO" commit -q -am "move HEAD"
out="$(EX "$TOKEN")"; assert_eq "$(iserr <<< "$out")" "true"; assert_contains "$(txt <<< "$out")" "HEAD moved"
git -C "$REPO" reset -q --hard HEAD~1
assert_eq "$(wc -l < "$CODE_TRACE" | tr -d ' ')" "2" "refused executes must not run e3d-code"

# the phase cap is enforced at plan time (warning) and at execute time (refusal)
cat >> "$SPEC" <<'SPECEOF'

## Phase 2 - Second Phase

<!-- runner:model=codex:gpt-5.4-mini -->
<!-- pilot:touches=README.md -->

### Requirements

- More.

### Acceptance Criteria

- Done.
SPECEOF
MCP_ENV='{"E3D_MCP_MAX_PHASES":"1"}'
plan2="$(mcp "$REPO" e3d_pilot_code_plan "$(jq -nc --arg r "$REPO" --arg i "$IDEA" '{repo:$r,idea_id:$i}')")"
assert_contains "$(sc <<< "$plan2" | jq -r '.warnings | join(" ")')" "exceeds the cap"
out="$(EX "$(sc <<< "$plan2" | jq -r .plan_token)")"; assert_eq "$(iserr <<< "$out")" "true"; assert_contains "$(txt <<< "$out")" "over the cap"
MCP_ENV='{}'
cp "$TMP/spec-final.orig" "$SPEC"

# --- finally: a fresh plan, then execute through to a draft PR ---
plan="$(mcp "$REPO" e3d_pilot_code_plan "$(jq -nc --arg r "$REPO" --arg i "$IDEA" '{repo:$r,idea_id:$i}')")"
TOKEN="$(sc <<< "$plan" | jq -r .plan_token)"
out="$(EX "$TOKEN")"; assert_eq "$(iserr <<< "$out")" "false" "execute with a valid plan: $(txt <<< "$out")"
JOB2="$(sc <<< "$out" | jq -r .job_id)"
final="$(wait_job "$REPO" "$JOB2")"
st="$(mcp "$REPO" e3d_pilot_job_status "$(jq -nc --arg r "$REPO" --arg j "$JOB" '{repo:$r,job_id:$j}')" | sc)"
assert_eq "$(jq -r .state <<< "$st")" "resumed" "the paused job must stop saying it is waiting once execution continues"
assert_contains "$(jq -r .reason <<< "$st")" "$JOB2"
assert_eq "$(jq -r .state <<< "$final")" "succeeded" "execute job: $(jq -c . <<< "$final" | cut -c1-400)"
assert_eq "$(idea_status "$REPO" "$IDEA")" "implemented"
assert_eq "$(grep -c '^all$' "$CODE_TRACE")" "1" "e3d-code ran exactly once"
assert_eq "$(grep -c '^draft$' "$PROVIDER_TRACE")" "1" "draft was not repeated on resume"
mani="$(mcp "$REPO" e3d_pilot_artifact "$(jq -nc --arg r "$REPO" --arg run "$RUN" '{repo:$r,run_id:$run,name:"manifest"}')")"
assert_eq "$(sc <<< "$mani" | jq -r '.phases[0].model')" "gpt-5.4-mini" "per-phase result from the e3d-code manifest"
assert_eq "$(sc <<< "$mani" | jq -r '.phases[0].succeeded')" "true"
out="$(EX "$TOKEN")"; assert_eq "$(iserr <<< "$out")" "true" "a plan can only be used once"
# after implementation, a human can send the draft PR back for rework
out="$(mcp "$REPO" e3d_pilot_request_changes "$(jq -nc --arg r "$REPO" --arg i "$IDEA" '{repo:$r,idea_id:$i,reason:"tighten the README change"}')" "$ELICIT_NO")"
assert_eq "$(sc <<< "$out" | jq -r .outcome)" "declined"; assert_eq "$(idea_status "$REPO" "$IDEA")" "implemented"
out="$(mcp "$REPO" e3d_pilot_request_changes "$(jq -nc --arg r "$REPO" --arg i "$IDEA" '{repo:$r,idea_id:$i,reason:"tighten the README change"}')" "$ELICIT_YES")"
assert_eq "$(sc <<< "$out" | jq -r .outcome)" "changes_requested"; assert_eq "$(idea_status "$REPO" "$IDEA")" "changes_requested"
# nothing the MCP server did may write the checkout owner's git email into the ledger
assert_eq "$(grep -c 't@example.com' "$REPO/.e3d-pilot/events.jsonl" || true)" "0" "the git identity must not leak into the ledger"
assert_contains "$(jq -r 'select(.event=="implementation_started") | .actor' "$REPO/.e3d-pilot/events.jsonl")" "mcp:test-client" "implement is attributed to the MCP client"
assert_contains "$(jq -r 'select(.event=="implementation_completed") | .actor' "$REPO/.e3d-pilot/events.jsonl")" "mcp:test-client"
# merging is not exposed
tools="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | "$SERVER" 2>/dev/null)"
assert_not_contains "$(jq -r '.result.tools[].name' <<< "$tools")" "merge" "no merge tool may be exposed"

# ================= cancel path =================
REPO="$(mk_repo cancel)"
IDEA="$(propose "$REPO" "Cancel me")"; cli_approve "$REPO" "$IDEA"
out="$(mcp "$REPO" e3d_pilot_implement "$(jq -nc --arg r "$REPO" --arg i "$IDEA" '{repo:$r,idea_id:$i}')")"
final="$(wait_job "$REPO" "$(sc <<< "$out" | jq -r .job_id)")"
assert_eq "$(jq -r .state <<< "$final")" "waiting_for_human"
out="$(mcp "$REPO" e3d_pilot_cancel_paused "$(jq -nc --arg r "$REPO" --arg i "$IDEA" '{repo:$r,idea_id:$i,reason:"plan too broad"}')")"
assert_eq "$(iserr <<< "$out")" "false" "cancel: $(txt <<< "$out")"
assert_eq "$(idea_status "$REPO" "$IDEA")" "implementation_failed"
CJOB="$(sc <<< "$(mcp "$REPO" e3d_pilot_job_status "$(jq -nc --arg r "$REPO" '{repo:$r}')")" | jq -r .job_id)"
cst="$(mcp "$REPO" e3d_pilot_job_status "$(jq -nc --arg r "$REPO" --arg j "$CJOB" '{repo:$r,job_id:$j}')" | sc)"
assert_eq "$(jq -r .state <<< "$cst")" "cancelled" "a cancelled implementation must not still read waiting_for_human"
assert_contains "$(jq -r .reason <<< "$cst")" "plan too broad"
[[ "$(jq -r .next_action <<< "$cst")" == "null" ]] || fail "a cancelled job has no next action"
assert_eq "$(grep -c 't@example.com' "$REPO/.e3d-pilot/events.jsonl" || true)" "0" "cancel must not record the git identity"
assert_contains "$(jq -r 'select(.event=="implementation_failed") | .actor' "$REPO/.e3d-pilot/events.jsonl")" "mcp:test-client"
out="$(mcp "$REPO" e3d_pilot_cancel_paused "$(jq -nc --arg r "$REPO" --arg i "$IDEA" '{repo:$r,idea_id:$i,reason:"again"}')")"
assert_eq "$(iserr <<< "$out")" "true" "nothing left to cancel"

# ================= reject / request changes gates =================
REPO="$(mk_repo gates)"
IDEA="$(propose "$REPO" "Gate me")"
out="$(mcp "$REPO" e3d_pilot_reject "$(jq -nc --arg r "$REPO" --arg i "$IDEA" '{repo:$r,idea_id:$i,reason:"no"}')")"
assert_eq "$(sc <<< "$out" | jq -r .outcome)" "waiting_for_human" "no confirmation -> nothing happens"
out="$(mcp "$REPO" e3d_pilot_reject "$(jq -nc --arg r "$REPO" --arg i "$IDEA" '{repo:$r,idea_id:$i,reason:"no",confirm_phrase:"reject idea-other"}')")"
assert_eq "$(sc <<< "$out" | jq -r .outcome)" "waiting_for_human" "wrong confirm phrase"
assert_eq "$(idea_status "$REPO" "$IDEA")" "proposed"
# request_changes is a post-implementation gate: refused on a merely proposed idea
out="$(mcp "$REPO" e3d_pilot_request_changes "$(jq -nc --arg r "$REPO" --arg i "$IDEA" '{repo:$r,idea_id:$i,reason:"narrow it"}')" "$ELICIT_YES")"
assert_eq "$(iserr <<< "$out")" "true" "request_changes does not apply to a proposed idea"; assert_contains "$(txt <<< "$out")" "only applies to implemented"
assert_eq "$(idea_status "$REPO" "$IDEA")" "proposed"
IDEA3="$(propose "$REPO" "Reject me")"
out="$(mcp "$REPO" e3d_pilot_reject "$(jq -nc --arg r "$REPO" --arg i "$IDEA3" '{repo:$r,idea_id:$i,reason:"out of scope",confirm_phrase:"reject '"$IDEA3"'"}')")"
assert_eq "$(sc <<< "$out" | jq -r .outcome)" "rejected" "the exact confirm phrase works when the client cannot prompt"
assert_eq "$(idea_status "$REPO" "$IDEA3")" "rejected"

# ================= start: jobs, lock, timeout, restart recovery =================
REPO="$(mk_repo jobs)"
printf '' > "$REPO/.e3d-pilot/paused"
out="$(mcp "$REPO" e3d_pilot_start "$(jq -nc --arg r "$REPO" '{repo:$r,stage:"discover"}')")"
JOB="$(sc <<< "$out" | jq -r .job_id)"
final="$(wait_job "$REPO" "$JOB")"
assert_eq "$(jq -r .state <<< "$final")" "failed" "a paused repo stops stages before external work"
assert_contains "$(jq -r '.log_tail | join(" ")' <<< "$final")" "paused"
out="$(mcp "$REPO" e3d_pilot_start "$(jq -nc --arg r "$REPO" '{repo:$r,stage:"all"}')")"
assert_eq "$(iserr <<< "$out")" "true" "'all' is not startable: it would run past the plan preview"
rm -f "$REPO/.e3d-pilot/paused"

MCP_ENV='{"E3D_MCP_JOB_TIMEOUT_SEC":"4","SLEEPY_SECS":"60"}'
out="$(mcp "$REPO" e3d_pilot_start "$(jq -nc --arg r "$REPO" '{repo:$r,stage:"discover"}')")"
JOB="$(sc <<< "$out" | jq -r .job_id)"; [[ "$JOB" == job-* ]] || fail "start should return a job id: $(txt <<< "$out")"
out="$(mcp "$REPO" e3d_pilot_start "$(jq -nc --arg r "$REPO" '{repo:$r,stage:"discover"}')")"
assert_eq "$(iserr <<< "$out")" "true" "a second job in the same repo is refused"; assert_contains "$(txt <<< "$out")" "already running"
# a NEW server process (restart) still sees the running job
st="$(mcp "$REPO" e3d_pilot_job_status "$(jq -nc --arg r "$REPO" --arg j "$JOB" '{repo:$r,job_id:$j}')" | sc)"
assert_eq "$(jq -r .state <<< "$st")" "running" "job state survives a server restart"
sleep 5
st="$(mcp "$REPO" e3d_pilot_job_status "$(jq -nc --arg r "$REPO" --arg j "$JOB" '{repo:$r,job_id:$j}')" | sc)"
assert_eq "$(jq -r .state <<< "$st")" "failed" "the timeout stops the job"; assert_contains "$(jq -r .reason <<< "$st")" "timed out"
sleep 1
pgrep -f mcpflow-sleepy >/dev/null && fail "the timed-out job's processes should be gone"
MCP_ENV='{}'

# ================= budget: jobs that spend credits are reserved against the daily cap =================
REPO="$(mk_repo budget)"
BUD="$TMP/budget-state"
IDEA="$(propose "$REPO" "Budgeted")"; cli_approve "$REPO" "$IDEA"
usage_calls() { MCP_ENV="$(jq -nc --arg d "$BUD" '{E3D_MCP_STATE_DIR:$d, E3D_MCP_DAILY_CALLS:"4"}')" mcp "$REPO" e3d_usage '{}' | sc | jq -r .calls_today; }
# implement costs 1 draft + 2 negotiation rounds x 1 reviewer = 3 calls: a cap of 2 refuses it BEFORE any job starts
MCP_ENV="$(jq -nc --arg d "$BUD" '{E3D_MCP_STATE_DIR:$d, E3D_MCP_DAILY_CALLS:"2"}')"
out="$(mcp "$REPO" e3d_pilot_implement "$(jq -nc --arg r "$REPO" --arg i "$IDEA" '{repo:$r,idea_id:$i}')")"
assert_eq "$(iserr <<< "$out")" "true" "implement must be refused when its reservation would break the cap"
assert_contains "$(txt <<< "$out")" "daily budget"
assert_eq "$(idea_status "$REPO" "$IDEA")" "approved_for_implementation" "a refused implement changes nothing"
[[ ! -d "$REPO/.e3d-pilot/mcp-jobs" ]] || [[ -z "$(ls "$REPO/.e3d-pilot/mcp-jobs" 2>/dev/null)" ]] || fail "a refused implement must not start a job"
MCP_ENV='{}'
assert_eq "$(usage_calls)" "0" "a refusal reserves nothing"
# with room, it starts and the reservation is recorded and reported
MCP_ENV="$(jq -nc --arg d "$BUD" '{E3D_MCP_STATE_DIR:$d, E3D_MCP_DAILY_CALLS:"4"}')"
out="$(mcp "$REPO" e3d_pilot_implement "$(jq -nc --arg r "$REPO" --arg i "$IDEA" '{repo:$r,idea_id:$i}')")"
assert_eq "$(iserr <<< "$out")" "false" "implement with room: $(txt <<< "$out")"
assert_eq "$(sc <<< "$out" | jq -r .reserved.calls)" "3" "the reservation is reported"
assert_eq "$(sc <<< "$out" | jq -r .reserved.estimate)" "true" "and labelled an estimate"
assert_contains "$(txt <<< "$out")" "Reserved against today's budget"
JOB="$(sc <<< "$out" | jq -r .job_id)"
final="$(wait_job "$REPO" "$JOB")"
assert_eq "$(jq -r .state <<< "$final")" "waiting_for_human"
assert_eq "$(usage_calls)" "3" "e3d_usage counts the job"
# 1 call is left: a discover/ideate start (2 calls) is refused, and nothing new starts
out="$(mcp "$REPO" e3d_pilot_start "$(jq -nc --arg r "$REPO" '{repo:$r,stage:"discover"}')")"
assert_eq "$(iserr <<< "$out")" "true" "start must be refused: only 1 call left"
assert_contains "$(txt <<< "$out")" "only 1 of today's 4"
assert_eq "$(usage_calls)" "3" "the refused start reserved nothing"
# a job that cannot start gives its reservation back: the discover job below runs a sleepy fake provider, so a second
# start in the same repo is refused by the job lock AFTER its reservation was taken
MCP_ENV="$(jq -nc --arg d "$BUD" '{E3D_MCP_STATE_DIR:$d, E3D_MCP_DAILY_CALLS:"40", SLEEPY_SECS:"60"}')"
out="$(mcp "$REPO" e3d_pilot_start "$(jq -nc --arg r "$REPO" '{repo:$r,stage:"discover"}')")"
assert_eq "$(iserr <<< "$out")" "false" "start with room: $(txt <<< "$out")"
assert_eq "$(sc <<< "$out" | jq -r .reserved.calls)" "2" "a discover/ideate start reserves 2 calls"
before="$(MCP_ENV="$(jq -nc --arg d "$BUD" '{E3D_MCP_STATE_DIR:$d, E3D_MCP_DAILY_CALLS:"40"}')" mcp "$REPO" e3d_usage '{}' | sc | jq -r .calls_today)"
out="$(mcp "$REPO" e3d_pilot_start "$(jq -nc --arg r "$REPO" '{repo:$r,stage:"discover"}')")"
assert_eq "$(iserr <<< "$out")" "true" "a second job in the same repo is refused"; assert_contains "$(txt <<< "$out")" "already running"
after="$(MCP_ENV="$(jq -nc --arg d "$BUD" '{E3D_MCP_STATE_DIR:$d, E3D_MCP_DAILY_CALLS:"40"}')" mcp "$REPO" e3d_usage '{}' | sc | jq -r .calls_today)"
assert_eq "$after" "$before" "the reservation of a job that could not start is released"
MCP_ENV='{}'
out="$(mcp "$REPO" e3d_pilot_cancel_paused "$(jq -nc --arg r "$REPO" --arg i "$IDEA" '{repo:$r,idea_id:$i,reason:"budget test"}')")"
assert_eq "$(iserr <<< "$out")" "false" "cleanup cancel: $(txt <<< "$out")"

echo "mcp-flow.sh: ok"
