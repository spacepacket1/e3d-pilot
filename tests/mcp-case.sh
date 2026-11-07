#!/usr/bin/env bash
# e3d_investigate (stdio): tool listing, validation, a new case, a continuation with answers, ownership of case_id, closed status, a web run with
# investigate: true. A stub debate binary stands in for the engine and uses the real lib/debate/case.mjs; no model calls.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export E3D_MCP_STATE_DIR="$(mktemp -d)"
SERVER="$ROOT/bin/e3d-mcp"
W="$(mktemp -d)"
trap 'rm -rf "$W" "$E3D_MCP_STATE_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "$W/stub" <<'STUBEOF'
#!/usr/bin/env bash
# stands in for bin/e3d-debate: records its arguments, answers like the case-mode engine
out=""; cont=""; ans=""; follow=0; qf=""; ALLARGS="$*"
while [[ $# -gt 0 ]]; do
  case "$1" in --out-dir) out="$2"; shift 2 ;; --continue) cont="$2"; follow=1; shift 2 ;; --answers) ans="$2"; shift 2 ;; --follow-up) follow=1; shift ;; --question-file) qf="$2"; shift 2 ;; *) shift ;; esac
done
echo "follow=$follow continue=$cont" >> "$STUB_LOG"
echo "$ALLARGS" > "$STUB_LOG.args"; echo "E3D_SPECIALISTS=${E3D_SPECIALISTS:-}" >> "$STUB_LOG.args"
mkdir -p "$out"
CASE="$STUB_ROOT/lib/debate/case.mjs"
if [[ -n "$cont" ]]; then
  node "$CASE" build --prev "$cont" --answers "$ans" --meta "$out/.meta" > "$STUB_LOG.question"
  q="$(cat "$STUB_LOG.question")"
else q="$(cat "$qf")"; fi
printf '# Debate\n\n## Round 1 -- claude\n\nA.\n\n## Round 1 -- codex\n\nB.\n' > "$out/transcript.md"
if (( follow == 1 )); then
  if [[ -n "$cont" ]]; then reply="$STUB_REPLY_NEXT"; else reply="$STUB_REPLY_FIRST"; fi
  printf '%s\n' "$reply" > "$out/synth.raw"
  node "$CASE" extract "$out/synth.raw" "$out/questions.json" "$out/verdict.txt"
  if [[ -n "$cont" ]]; then node "$CASE" record "$out/case.json" --questions "$out/questions.json" --verdict "$out/verdict.txt" --meta "$out/.meta"
  else printf '%s' "$q" > "$out/q.txt"; node "$CASE" record "$out/case.json" --questions "$out/questions.json" --verdict "$out/verdict.txt" --question-file "$out/q.txt"; fi
  cat "$out/verdict.txt"
else printf 'FINAL ANSWER: plain.\nCONSENSUS: full\nDISSENT: none\n'; fi
STUBEOF
chmod +x "$W/stub"

FIRST='FINAL ANSWER: Ship behind a flag.
CONSENSUS: majority
DISSENT: codex: wait a week | "not yet."

## Questions for you

1. Is the migration reversible?

```json
{"status":"open","questions":[{"id":"q1","text":"Is the migration reversible?","why":"rollback cost","swing":"yes: ship now","answerable_by":"checkable"},{"id":"q2","text":"Is there a launch date?","why":"timing","swing":"a date favours the flag","answerable_by":"user","kind":"intake"}]}
```'
NEXT='FINAL ANSWER: Ship now.
CONSENSUS: full
DISSENT: none

## Questions for you

Case closed: nothing left would change it.

```json
{"status":"closed","questions":[]}
```'
export STUB_LOG="$W/log" STUB_ROOT="$ROOT" STUB_REPLY_FIRST="$FIRST" STUB_REPLY_NEXT="$NEXT"
: > "$STUB_LOG"

call() { # <id> <tool> <args-json> ; prints the whole response
  printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$1,\"method\":\"tools/call\",\"params\":{\"name\":\"$2\",\"arguments\":$3}}" | E3D_MCP_DEBATE_BIN="$W/stub" "$SERVER" 2>/dev/null
}

# listing: e3d_investigate is added after the original four tools, annotated like e3d_debate, and tells the agent not to fabricate
tools="$(printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | "$SERVER" 2>/dev/null)"
[[ "$(jq -r '.result.tools[0:4]|map(.name)|join(",")' <<< "$tools")" == "e3d_debate,e3d_list_providers,e3d_provenance_trace,e3d_ideas_list" ]] || fail "original tool order changed"
[[ "$(jq -r '.result.tools[] | select(.name=="e3d_investigate") | [.annotations.readOnlyHint, .annotations.destructiveHint, .annotations.openWorldHint] | map(tostring) | join(",")' <<< "$tools")" == "false,false,true" ]] || fail "e3d_investigate annotations"
d="$(jq -r '.result.tools[] | select(.name=="e3d_investigate") | .description' <<< "$tools")"
[[ "$d" == *'ONLY "checkable"'* && "$d" == *'`source`'* && "$d" == *'Never guess, never fabricate'* && "$d" == *'Pass every "user" question to the human'* ]] || fail "description lacks the agent rules"
[[ "$(jq -r '.result.tools[] | select(.name=="e3d_investigate") | .outputSchema.required | index("questions") != null' <<< "$tools")" == true ]] || fail "outputSchema"

# validation
r="$(call 3 e3d_investigate '{}')"; [[ "$(jq -r .result.isError <<< "$r")" == true ]] || fail "neither question nor case_id accepted"
r="$(call 3 e3d_investigate '{"question":"q","case_id":"case_aaaaaaaaaaaaaaaaaaaaaaaa"}')"; [[ "$(jq -r .result.isError <<< "$r")" == true ]] || fail "both accepted"
r="$(call 3 e3d_investigate '{"question":"q","answers":[]}')"; [[ "$(jq -r .result.isError <<< "$r")" == true ]] || fail "answers with question accepted"
r="$(call 3 e3d_investigate '{"case_id":"case_aaaaaaaaaaaaaaaaaaaaaaaa","answers":[]}')"; [[ "$(jq -r .result.content[0].text <<< "$r")" == *"unknown case_id"* ]] || fail "unknown case_id"
r="$(call 3 e3d_investigate '{"case_id":"../../etc","answers":[]}')"; [[ "$(jq -r .result.content[0].text <<< "$r")" == *"unknown case_id"* ]] || fail "malformed case_id"
r="$(call 3 e3d_investigate '{"case_id":"case_aaaaaaaaaaaaaaaaaaaaaaaa","answers":[{"id":"q1","answer":5}]}')"; [[ "$(jq -r .result.isError <<< "$r")" == true ]] || fail "non-string answer accepted"

# a new case
r="$(call 4 e3d_investigate '{"question":"Should we ship the migration?"}')"
s=".result.structuredContent"
[[ "$(jq -r "$s.status" <<< "$r")" == open ]] || fail "status: $r"
[[ "$(jq -r "$s.questions|length" <<< "$r")" == 2 ]] || fail "questions"
[[ "$(jq -r "$s.questions[0].answerable_by" <<< "$r")" == checkable ]] || fail "answerable_by"
[[ "$(jq -r "$s.final_answer" <<< "$r")" == "Ship behind a flag." ]] || fail "final_answer (questions section must not leak into it): $(jq -r "$s.final_answer" <<< "$r")"
[[ "$(jq -r "$s.consensus" <<< "$r")" == majority ]] || fail "consensus"
[[ "$(jq -r "$s.dissent.summary" <<< "$r")" == "codex: wait a week | \"not yet.\"" ]] || fail "dissent must stop before the questions: $(jq -r "$s.dissent.summary" <<< "$r")"
CID="$(jq -r "$s.case_id" <<< "$r")"
[[ "$CID" =~ ^case_[0-9a-f]{24}$ ]] || fail "case_id"
t="$(jq -r .result.content[0].text <<< "$r")"
[[ "$t" == *"Case open"* && "$t" == *"[checkable]"* && "$t" == *"$CID"* && "$t" == *"Pass each \"user\" question to the human"* ]] || fail "text rendering"
[[ "$(jq -r "$s.questions[1].kind" <<< "$r")" == intake && "$(jq -r "$s.questions[0] | has(\"kind\")" <<< "$r")" == false ]] || fail "kind must pass through when present and stay absent otherwise: $(jq -c "$s.questions" <<< "$r")"
[[ "$t" == *"[user, intake]"* ]] || fail "kind not shown in the text: $t"
[[ "$(jq -r '.result.tools[] | select(.name=="e3d_investigate") | .outputSchema.properties.questions.items | (.properties.kind.enum | join(",")), (.required | index("kind") == null)' <<< "$tools")" == $'discriminating,shared_assumption,intake\ntrue' ]] || fail "kind must be an optional enum in the output schema"
grep -q 'follow=1 continue=$' "$STUB_LOG" || fail "engine not asked for --follow-up"

# the plain e3d_debate is untouched
r="$(call 5 e3d_debate '{"question":"q"}')"
[[ "$(jq -r '.result.structuredContent|has("questions")' <<< "$r")" == false ]] || fail "e3d_debate result gained questions"
tail -1 "$STUB_LOG" | grep -qx 'follow=0 continue=' || fail "e3d_debate must not run in case mode"

# the next round: answers reach the engine's question as data, the case closes
ANS='[{"id":"q1","answer":"Yes, down.sql exists","source":"file:migrations/0042_down.sql","answered_by":"agent"}]'
r="$(call 6 e3d_investigate "{\"case_id\":\"$CID\",\"answers\":$ANS}")"
[[ "$(jq -r "$s.status" <<< "$r")" == closed ]] || fail "closed: $r"
[[ "$(jq -r "$s.questions|length" <<< "$r")" == 0 ]] || fail "closed has no questions"
[[ "$(jq -r "$s.round" <<< "$r")" == 2 ]] || fail "round"
CID2="$(jq -r "$s.case_id" <<< "$r")"
[[ "$CID2" =~ ^case_[0-9a-f]{24}$ && "$CID2" != "$CID" ]] || fail "a new case_id per round"
grep -q "continue=$E3D_MCP_STATE_DIR/cases/$CID" "$STUB_LOG" || fail "engine not asked to continue the stored round: $(tail -1 "$STUB_LOG")"
q="$(cat "$STUB_LOG.question")"
[[ "$q" == *"Should we ship the migration?"* && "$q" == *"Yes, down.sql exists"* && "$q" == *"file:migrations/0042_down.sql"* && "$q" == *"codex: wait a week"* && "$q" == *"by agent"* && "$q" == *"DATA recorded from earlier steps"* ]] || fail "continuation question: $q"
[[ "$(jq -r "$s.dissent.present" <<< "$r")" == false ]] || fail "dissent after closing"
[[ "$(jq -r .result.content[0].text <<< "$r")" == *"Case closed"* ]] || fail "closed text"

# the case belongs to the key that ran it (hosted keys are principals; stdio is one)
node --input-type=module -e "
import { createCaseStore } from '$ROOT/lib/mcp/case.js';
const st = createCaseStore({ dir: process.env.E3D_MCP_STATE_DIR });
const id = '$CID';
if (!(await st.find('local', id))) throw new Error('owner cannot find its case');
if (await st.find('someone-else', id)) throw new Error('another principal found the case');
const k = st.idFor('p', 'key-12345678'); if (k !== st.idFor('p', 'key-12345678') || k === st.idFor('q', 'key-12345678')) throw new Error('idempotent ids');
" || fail "case store ownership"

# an answers-only partial round and a free-form "don't know" are accepted
r="$(call 7 e3d_investigate "{\"case_id\":\"$CID\",\"answers\":[{\"id\":\"q2\",\"answer\":\"don't know\"}]}")"
[[ "$(jq -r "$s.status" <<< "$r")" == closed ]] || fail "partial answers round: $r"
grep -q "don't know" "$STUB_LOG.question" && grep -q 'ANSWER: (not answered)' "$STUB_LOG.question" || fail "unanswered question not passed on"
# a hosted web run: investigate must be true when sent; it is a known field
node --input-type=module -e "
import { validateRunRequest } from '$ROOT/lib/mcp/run-server.js';
const base = { reservation_id: 'r-' + 'a'.repeat(30), debate_id: 'dbt_' + 'a'.repeat(24), question: 'q?' };
const ok = validateRunRequest({ ...base, investigate: true });
if (ok.error || ok.fields.investigate !== true) throw new Error('investigate refused: ' + ok.error);
if (!validateRunRequest({ ...base, investigate: false }).error) throw new Error('investigate false accepted');
if (validateRunRequest({ ...base }).fields.investigate !== undefined) throw new Error('investigate appeared by itself');
" || fail "run-server investigate field"
# experts: ids (2 to 4) reach the engine as --specialist flags, pinned to the catalogue hash, built-in only; E3D_SPECIALISTS=1
r="$(call 20 e3d_investigate '{"question":"Should we ship the migration?","experts":["skeptic","architect"],"providers":["claude","codex","gemini"]}')"
[[ "$(jq -r "$s.status" <<< "$r")" == open ]] || fail "case with experts: $r"
a="$(cat "$STUB_LOG.args")"
[[ "$a" == *"--specialist skeptic --specialist architect"* && "$a" == *"--builtin-only"* && "$a" == *"--fill-pool"* && "$a" == *"--expert-pin skeptic=sha256:"* && "$a" == *"--expert-pin architect=sha256:"* && "$a" == *"E3D_SPECIALISTS=1"* ]] || fail "experts not passed as --specialist: $a"
[[ "$(jq -r "$s | has(\"suggested_experts\")" <<< "$r")" == false ]] || fail "no hint when experts were given"
ECID="$(jq -r "$s.case_id" <<< "$r")"
# a continuation reuses the stored experts, pinned to the stored hash
call 21 e3d_investigate "{\"case_id\":\"$ECID\",\"answers\":[],\"providers\":[\"claude\",\"codex\",\"gemini\"]}" > /dev/null
a="$(cat "$STUB_LOG.args")"
[[ "$a" == *"--specialist skeptic --specialist architect"* && "$a" == *"--continue"* ]] || fail "continuation did not reuse the experts: $a"
# ... unless the caller passes new ones
call 22 e3d_investigate "{\"case_id\":\"$ECID\",\"answers\":[],\"experts\":[\"premortem\",\"customer\"],\"providers\":[\"claude\",\"codex\",\"gemini\"]}" > /dev/null
a="$(cat "$STUB_LOG.args")"
[[ "$a" == *"--specialist premortem --specialist customer"* && "$a" != *"--specialist skeptic"* ]] || fail "new experts on a continuation: $a"
# a case without experts stays without
call 23 e3d_investigate '{"question":"Plain question"}' > /dev/null
[[ "$(cat "$STUB_LOG.args")" != *"--specialist"* ]] || fail "specialist flags without experts"
# refused before anything runs: unknown id, malformed, too few, too many, duplicates, more experts than providers
: > "$W/n"; before="$(wc -l < "$STUB_LOG")"
for bad in '["nope","skeptic"]' '["skeptic"]' '["skeptic","architect","customer","premortem","compliance"]' '["skeptic","skeptic"]' '["Skeptic","../x"]' '"skeptic"'; do
  r="$(call 24 e3d_investigate "{\"question\":\"q\",\"experts\":$bad}")"
  [[ "$(jq -r .result.isError <<< "$r")" == true && "$(jq -r .result.content[0].text <<< "$r")" == *"invalid"* ]] || fail "experts $bad accepted: $r"
done
r="$(call 25 e3d_investigate '{"question":"q","experts":["skeptic","architect","customer"],"providers":["claude","codex"]}')"
[[ "$(jq -r .result.isError <<< "$r")" == true && "$(jq -r .result.content[0].text <<< "$r")" == *experts_exceed_panel* ]] || fail "more experts than providers accepted: $r"
[[ "$(wc -l < "$STUB_LOG")" == "$before" ]] || fail "the engine ran for a refused experts argument"
[[ "$(jq -r '.result.tools[] | select(.name=="e3d_investigate") | .inputSchema.properties.experts | [.minItems, .maxItems] | join(",")' <<< "$tools")" == "2,4" ]] || fail "experts missing from the e3d_investigate schema"
# suggested_experts: present for a question about agents (rule agent-terms), never run; absent for any other
r="$(call 26 e3d_investigate '{"question":"Why does our agent skip tool calls and ignore its skill?"}')"
[[ "$(jq -r "$s.suggested_experts.experts[0]" <<< "$r")" == agent-diagnosis && "$(jq -r "$s.suggested_experts.experts|length>=2" <<< "$r")" == true ]] || fail "suggested_experts missing for an agent question: $r"
[[ "$(cat "$STUB_LOG.args")" != *"--specialist"* ]] || fail "a suggestion must not be run"
[[ "$(jq -r .result.content[0].text <<< "$r")" == *"Suggested experts (not run)"* ]] || fail "suggestion not in the text"
r="$(call 27 e3d_investigate '{"question":"Should we ship the migration next week?"}')"
[[ "$(jq -r "$s | has(\"suggested_experts\")" <<< "$r")" == false ]] || fail "suggested_experts for a question that is not about agents"
r="$(call 28 e3d_investigate '{"question":"Why does our agent skip tool calls?","experts":["skeptic","architect"],"providers":["claude","codex"]}')"
[[ "$(jq -r "$s | has(\"suggested_experts\")" <<< "$r")" == false ]] || fail "hint although experts were passed"
# agent-diagnosis is a built-in expert: listed by the read-only experts tools (E3D_MCP_EXPERTS=1)
ex="$(printf '%s\n' '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"e3d_list_experts","arguments":{}}}' | E3D_MCP_EXPERTS=1 "$SERVER" 2>/dev/null)"
grep -q 'agent-diagnosis' <<< "$ex" || fail "agent-diagnosis missing from e3d_list_experts: $ex"
echo "mcp-case: ok"
