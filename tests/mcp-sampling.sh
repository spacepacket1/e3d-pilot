#!/usr/bin/env bash
set -euo pipefail

# Tests for the Copilot-first default: MCP sampling bridge, voice selection, independence warnings.
# The "editor" is a scripted test client answering sampling/createMessage; no real model is ever called.
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

# ---- voice selection (pure logic, so it does not depend on which CLIs this machine has) ----
node --input-type=module - "$ROOT" <<'JS'
import assert from 'node:assert/strict';
const { chooseVoices, independence } = await import(`${process.argv[2]}/lib/mcp/voices.js`);
const k = (...n) => n.map((name) => ({ name, available: true }));

let v = chooseVoices({ known: k('claude', 'codex', 'gemini'), samplingOn: false, env: {} });
assert.deepEqual(v.providers, ['claude', 'codex'], 'without sampling the default is unchanged: claude + codex');
assert.equal(v.synthesizer, 'claude');

v = chooseVoices({ known: k('codex', 'gemini'), samplingOn: false, env: {} });
assert.deepEqual(v.providers, ['codex', 'gemini'], 'without claude it now falls back to what is installed');
assert.equal(v.synthesizer, 'codex');

v = chooseVoices({ known: k('claude', 'codex', 'gemini'), samplingOn: true, env: {} });
assert.deepEqual(v.providers, ['mcp-sampling', 'claude', 'codex'], "sampling: the client's models first, then detected CLIs");
assert.equal(v.synthesizer, 'mcp-sampling');
assert.match(v.note, /detected: claude, codex/);

v = chooseVoices({ known: [], samplingOn: true, env: {} });
assert.deepEqual(v.providers, ['mcp-sampling', 'mcp-sampling-b'], 'sampling alone still gets two voices');

v = chooseVoices({ known: k('claude', 'codex'), samplingOn: true, env: { E3D_MCP_AUTO_VOICES: '2' } });
assert.deepEqual(v.providers, ['mcp-sampling', 'claude'], 'E3D_MCP_AUTO_VOICES caps the number of voices');

v = chooseVoices({ known: k('claude', 'codex'), samplingOn: true, env: { E3D_MCP_PROVIDERS: 'codex,gemini' } });
assert.deepEqual(v.providers, ['codex', 'gemini']);
assert.equal(v.selection, 'pinned');

v = chooseVoices({ known: k('claude'), samplingOn: false, env: {} });
assert.equal(v.providers.length, 1, 'one provider is reported as-is so the caller can say "need 2"');

const sm = (...ms) => ms.map(([provider, model]) => ({ provider, model }));
assert.equal(independence(['mcp-sampling', 'mcp-sampling-b'], sm(['mcp-sampling', 'x'], ['mcp-sampling-b', 'x'])).independent, false);
assert.equal(independence(['mcp-sampling', 'mcp-sampling-b'], sm(['mcp-sampling', 'x'], ['mcp-sampling-b', 'y'])).independent, true);
assert.equal(independence(['mcp-sampling', 'claude'], sm(['mcp-sampling', 'x'])).independent, true, 'an unknown-family model plus a CLI voice are distinct');
// vendor families: Copilot's Claude and the claude CLI are the same family
let ind = independence(['mcp-sampling', 'claude'], sm(['mcp-sampling', 'claude-sonnet-5.5']));
assert.equal(ind.independent, false, 'Copilot Claude + claude CLI is one family');
assert.match(ind.warnings[0], /anthropic family/);
ind = independence(['mcp-sampling', 'claude', 'codex'], sm(['mcp-sampling', 'claude-sonnet-5.5']));
assert.equal(ind.independent, true);
assert.match(ind.warnings.join(' '), /2 of 3 voices are anthropic models/, 'overlap is reported even when the debate is independent');
assert.deepEqual(ind.families.sort(), ['anthropic', 'openai']);
ind = independence(['mcp-sampling', 'mcp-sampling-b'], sm(['mcp-sampling', 'claude-sonnet-5.5'], ['mcp-sampling-b', 'gpt-5.1']));
assert.equal(ind.independent, true); assert.equal(ind.warnings.length, 0);
assert.equal(independence(['codex', 'openai-api'], []).independent, false, 'two OpenAI providers are one family');
console.log('voices ok');
JS

# ---- the socket is private and cleaned up ----
node --input-type=module - "$ROOT" <<'JS'
import assert from 'node:assert/strict';
import { statSync, existsSync } from 'node:fs';
import { dirname } from 'node:path';
const { createSampling } = await import(`${process.argv[2]}/lib/mcp/sampling.js`);
const s = createSampling({ rpc: { request: async () => ({}) } });
assert.deepEqual(await s.env({ capabilities: {} }, { tag: 't' }), {}, 'no sampling capability -> no socket, no env');
const env = await s.env({ capabilities: { sampling: {} } }, { tag: 't', maxTokens: 321 });
const sock = env.E3D_MCP_SAMPLING_SOCKET;
assert.equal(statSync(sock).mode & 0o777, 0o600, 'socket must be owner-only');
assert.equal(statSync(dirname(sock)).mode & 0o777, 0o700, 'socket dir must be owner-only');
assert.equal(env.E3D_MCP_SAMPLING_MAX_TOKENS, '321');
await s.stop();
assert.equal(existsSync(sock), false, 'stop() removes the socket');
console.log('socket ok');
JS

# ---- adapter availability ----
out="$(env -u E3D_MCP_SAMPLING_SOCKET E3D_PILOT_CHECK=1 "$ROOT/lib/providers/mcp-sampling" 2>&1)" && fail "adapter must be unavailable without a socket" || true
assert_contains "$out" "unavailable"
out="$(E3D_MCP_SAMPLING_SOCKET="$TMP/nope.sock" E3D_PILOT_CHECK=1 "$ROOT/lib/providers/mcp-sampling-b" 2>&1)" && fail "adapter must be unavailable when the socket is dead" || true
assert_contains "$out" "unavailable"

# ---- through the MCP server ----
call() {  # call <tool> <args-json> <plan-extra-json> [env-json]
  local env="${4:-{\}}"
  node "$CLIENT" "$(jq -nc --arg s "$SERVER" --arg n "$1" --argjson a "$2" --argjson x "$3" --argjson e "$env" \
    '{server:$s, env:({TYPESAFE_API_KEY:""}+$e), calls:[{name:$n, arguments:$a}]} + $x')"
}
sc() { jq -c '.results[0].structuredContent'; }
txt() { jq -r '.results[0].content[0].text'; }
SAMPLING_CAP='{"capabilities":{"sampling":{}}}'
BLOCK=$'FINAL ANSWER: Use a flat JSON file.\nCONSENSUS: split\nDISSENT: model-b prefers SQLite for transactions.\n'

# listing: sampling voices appear only for clients that support sampling; the default-voices line always does
out="$(call e3d_list_providers '{}' "$SAMPLING_CAP")"
assert_contains "$(txt <<< "$out")" "mcp-sampling: available"
assert_contains "$(txt <<< "$out")" "Default voices for e3d_debate: mcp-sampling"
out="$(call e3d_list_providers '{}' '{}')"
[[ "$(txt <<< "$out")" != *"mcp-sampling:"* ]] || fail "a client without sampling must not be offered sampling voices"
assert_contains "$(txt <<< "$out")" "Default voices for e3d_debate:"

# a real debate through the bridge, two different models
plan="$(jq -nc --arg t "$BLOCK" '{capabilities:{sampling:{}}, sampling:{models:["model-a","model-b"], text:$t}}')"
out="$(call e3d_debate '{"question":"JSON or SQLite?","providers":["mcp-sampling","mcp-sampling-b"],"mode":"quick"}' "$plan")"
[[ "$(jq -r '.results[0].isError // false' <<< "$out")" == "false" ]] || fail "debate via sampling failed: $(txt <<< "$out")"
assert_eq "$(sc <<< "$out" | jq -r .consensus)" "split"
assert_eq "$(sc <<< "$out" | jq -r .dissent.present)" "true"
assert_eq "$(sc <<< "$out" | jq -r .independent)" "true" "two different models answered"
assert_eq "$(sc <<< "$out" | jq -r '.warnings | length')" "0"
assert_eq "$(sc <<< "$out" | jq -r .selection)" "explicit"
assert_eq "$(sc <<< "$out" | jq -r .synthesizer)" "mcp-sampling" "the client's model writes the verdict"
assert_eq "$(sc <<< "$out" | jq -r '[.models[].model] | unique | join(",")')" "model-a,model-b" "which models actually answered is reported"
assert_eq "$(sc <<< "$out" | jq -r '[.models[].calls] | add')" "3" "per-model call counts add up to the three sampling requests"
assert_eq "$(sc <<< "$out" | jq -r '[.models[] | "\(.provider)|\(.model)"] | (length == (unique | length))')" "true" "one entry per provider and model, not one per call"
n="$(jq '[.events[] | select(.request=="sampling/createMessage")] | length' <<< "$out")"
assert_eq "$n" "3" "2 voices x 1 round + 1 synthesis"
assert_eq "$(jq -r '[.events[] | select(.request=="sampling/createMessage") | .params.modelPreferences.hints[0].name] | unique | join(",")' <<< "$out")" "claude,gpt" "the two voices ask for different model families"
assert_eq "$(jq -r '[.events[] | select(.request=="sampling/createMessage") | .params.includeContext] | unique | join(",")' <<< "$out")" "none" "no workspace context is shared"
assert_eq "$(jq -r '[.events[] | select(.request=="sampling/createMessage") | .params.maxTokens] | unique | join(",")' <<< "$out")" "300" "token cap follows max_words"
assert_contains "$(txt <<< "$out")" "Models that answered:"

# one model arguing with itself is flagged
plan="$(jq -nc --arg t "$BLOCK" '{capabilities:{sampling:{}}, sampling:{model:"same-model", text:$t}}')"
out="$(call e3d_debate '{"question":"JSON or SQLite?","providers":["mcp-sampling","mcp-sampling-b"]}' "$plan")"
assert_eq "$(sc <<< "$out" | jq -r .independent)" "false"
assert_contains "$(sc <<< "$out" | jq -r '.warnings[0]')" "same model (same-model)"
assert_contains "$(txt <<< "$out")" "WARNING"

# the editor refusing/failing the request surfaces as an error (and nothing leaks)
plan="$(jq -nc '{capabilities:{sampling:{}}, sampling:{error:"user denied; token=sk-abcdefghijklmnopqrstuvwx"}}')"
out="$(call e3d_debate '{"question":"q","providers":["mcp-sampling","mcp-sampling-b"]}' "$plan")"
assert_eq "$(jq -r '.results[0].isError // false' <<< "$out")" "true" "denied sampling must fail the debate, not fake an answer"
[[ "$(jq -r '.results[0].content[0].text' <<< "$out")" != *abcdefghijklmnop* ]] || fail "secret leaked from a sampling error"

# naming a sampling voice without client support is a clear error
out="$(call e3d_debate '{"question":"q","providers":["mcp-sampling","mcp-sampling-b"]}' '{}')"
assert_eq "$(jq -r '.results[0].isError // false' <<< "$out")" "true"
assert_contains "$(txt <<< "$out")" "supports sampling"

# ---- config_check warns about sampling-backed stages that cannot work ----
REPO="$TMP/repo"; mkdir -p "$REPO"; git init -q "$REPO"; git -C "$REPO" config user.email t@e.com; git -C "$REPO" config user.name T
printf x > "$REPO/a"; git -C "$REPO" add a; git -C "$REPO" commit -q -m i; mkdir -p "$REPO/.e3d-pilot"
REPO="$(cd "$REPO" && pwd -P)"
jq '.providers.draft = "mcp-sampling" | .providers.review = "mcp-sampling"' "$SAMPLE_CONFIG" > "$REPO/.e3d-pilot/config.json"
out="$(call e3d_pilot_config_check "$(jq -nc --arg r "$REPO" '{repo:$r}')" '{}' "$(jq -nc --arg r "$REPO" '{E3D_MCP_REPOS:$r}')")"
w="$(sc <<< "$out" | jq -r '.warnings | join(" | ")')"
assert_contains "$w" "providers.draft uses mcp-sampling: that stage must read the repository"
assert_contains "$w" "providers.review uses mcp-sampling: it works only while the editor is connected"

echo "mcp-sampling.sh: ok"
