#!/usr/bin/env bash
set -euo pipefail

# Experts, Phase 2b.1a (docs/specs/experts-phase2b1-hosted-lenses-spec.md section 2): the hosted ENGINE side. Unit checks of the strict run fields,
# then bin/e3d-debate against a fake vendor (four API providers, per-token limits: --builtin-only, --fill-pool, --expert-pin, --lens-bytes-max,
# the transcript line), then the real run listener (E3D_MCP_EXPERTS_RUN) against the reference stub with a stub debate binary. No model, no network
# beyond 127.0.0.1.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-assert_eq}: expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "${3:-assert_contains}: expected to find [$2] in [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "${3:-assert_not_contains}: did not expect [$2] in [$1]"; }

# ---------------------------------------------------------------- unit level
node "$ROOT/tests/fixtures/experts-run-test.mjs" | tee "$TMP/unit.out"
assert_contains "$(cat "$TMP/unit.out")" "experts-run unit tests:"

hash_of() { node -e "import('$ROOT/lib/debate/specialists.mjs').then((m) => { const e = m.loadExperts({ tiers: [{ name: 'built-in', dir: '$ROOT/lib/specialists' }] }).experts.find((x) => x.name === process.argv[1]); process.stdout.write(e.hash); })" "$1"; }
lens_of() { node -e "import('$ROOT/lib/debate/specialists.mjs').then((m) => { const e = m.loadExperts({ tiers: [{ name: 'built-in', dir: '$ROOT/lib/specialists' }] }).experts.find((x) => x.name === process.argv[1]); process.stdout.write(e.lens.trim().split('\n')[0].slice(0, 60)); })" "$1"; }
H_SKEPTIC="$(hash_of skeptic)"; H_CUSTOMER="$(hash_of customer)"; H_ARCH="$(hash_of architect)"
L_SKEPTIC="$(lens_of skeptic)"; L_CUSTOMER="$(lens_of customer)"
[[ "$H_SKEPTIC" =~ ^sha256:[0-9a-f]{64}$ && -n "$L_SKEPTIC" && -n "$L_CUSTOMER" ]] || fail "could not read the built-in experts"

# ---------------------------------------------------------------- bin/e3d-debate against a fake vendor
VREQ="$TMP/vendor.jsonl"; : > "$VREQ"
FAKE_ANSWER='FINAL ANSWER: ok
CONSENSUS: split
DISSENT: none' node "$ROOT/tests/fixtures/fake-vendor.mjs" "$VREQ" "$TMP/vendor.port" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$TMP/vendor.port" ]] && break; sleep 0.05; done
VP="$(cat "$TMP/vendor.port")"
vendor_env=(ANTHROPIC_API_KEY=k-anth ANTHROPIC_API_BASE_URL="http://127.0.0.1:$VP" OPENAI_API_KEY=k-oai OPENAI_API_BASE_URL="http://127.0.0.1:$VP/v1"
  GEMINI_API_KEY=k-gem GEMINI_API_BASE_URL="http://127.0.0.1:$VP/v1" XAI_API_KEY=k-xai XAI_API_BASE_URL="http://127.0.0.1:$VP/v1"
  ANTHROPIC_API_MODEL=claude-test OPENAI_API_MODEL=gpt-test GEMINI_API_MODEL=gem-test XAI_API_MODEL=xai-test
  OPENAI_API_TIMEOUT=5 ANTHROPIC_API_TIMEOUT=5 E3D_DEBATE_WEB_SEARCH=off TYPESAFE_API_KEY="")
P4=anthropic-api,openai-api,gemini-api,xai-api
LIM='{"anthropic-api":300,"openai-api":300,"gemini-api":300,"xai-api":300}'
ANS='{"anthropic-api":4000,"openai-api":4000,"gemini-api":4000,"xai-api":4000}'
vreq_count() { wc -l < "$VREQ" | tr -d ' '; }
prompts_with() { jq -c --arg s "$1" 'select(.body.messages[0].content | contains($s))' "$VREQ" | wc -l | tr -d ' '; }

# a work dir with a repo-tier override of skeptic and a user-tier override of customer (the folders a host could hold)
WORK="$TMP/work"; HOMED="$TMP/home"
plant() { # plant <dir> <name> <mark>
  mkdir -p "$1/$2"
  printf -- '---\nname: %s\ndescription: Planted override of %s. Use it in tests.\nlicense: MIT\nmetadata:\n  e3d.expert.version: "1"\n---\n%s. You are a planted lens.\n' "$2" "$2" "$3" > "$1/$2/SKILL.md"
}
plant "$WORK/.e3d-pilot/specialists" skeptic PLANTED-SKEPTIC-MARK
plant "$HOMED/.config/e3d-pilot/specialists" customer PLANTED-CUSTOMER-MARK

dbt() { # dbt <out-dir> <E3D_SPECIALISTS value or unset> <extra e3d-debate args...>; sets rc; output in $TMP/dbt.out
  local out="$1" es="$2"; shift 2
  local -a e=(-u E3D_SPECIALISTS -u E3D_SPECIALISTS_BUILTIN_ONLY)
  [[ "$es" == unset ]] || e+=("E3D_SPECIALISTS=$es")
  rc=0
  (cd "$WORK" && env "${e[@]}" "${vendor_env[@]}" HOME="$HOMED" E3D_DEBATE_MAX_TOKENS="$LIM" E3D_DEBATE_ANSWER_BYTES_MAX="$ANS" \
    "$ROOT/bin/e3d-debate" --providers "${PROVS:-$P4}" --synthesizer anthropic-api --out-dir "$out" --rounds 2 "$@" "Which one?") > "$TMP/dbt.out" 2>&1 || rc=$?
}
HOSTED=(--specialist skeptic --specialist customer --builtin-only --fill-pool --lens-bytes-max 640 --expert-pin "skeptic=$H_SKEPTIC" --expert-pin "customer=$H_CUSTOMER")

# 1. hosted shape: 2 experts on a 4-vendor per-token pool: planted folders ignored, plain seats for the rest, one seat per provider
: > "$VREQ"
dbt "$TMP/o1" 1 "${HOSTED[@]}"
[[ $rc -eq 0 ]] || fail "hosted run failed ($rc): $(cat "$TMP/dbt.out")"
assert_eq "$(vreq_count)" "9" "4 seats x 2 rounds + the synthesis, one vendor call each (per-token seat check passes: seat ids equal adapters)"
assert_eq "$(prompts_with PLANTED)" "0" "--builtin-only: a planted user or repo folder never reaches a prompt"
assert_eq "$(prompts_with "$L_SKEPTIC")" "2" "the built-in skeptic text, in both rounds of its seat"
assert_eq "$(prompts_with "$L_CUSTOMER")" "2" "the built-in customer text, in both rounds of its seat"
assert_eq "$(prompts_with '[Your role in this debate]')" "4" "only the two expert seats get a lens block (2 experts x 2 rounds); plain seats and the synthesis get none"
assert_eq "$(jq -c '[.[] | .key] | map(select(startswith("r1:"))) | length' "$TMP/o1/usage.json")" "4" "four seats answered round 1"
assert_eq "$(jq -c '.providers' "$TMP/o1/decision-log.json")" '["anthropic-api","openai-api","gemini-api","xai-api"]'
assert_eq "$(jq -c '[.panel.experts[] | [.name, .seat, .tier]]' "$TMP/o1/decision-log.json")" '[["skeptic","anthropic-api","built-in"],["customer","openai-api","built-in"]]' "the receipt carries the experts, tier built-in"
assert_eq "$(jq -c '.panel.plain_seats' "$TMP/o1/decision-log.json")" '[{"seat":"gemini-api","adapter":"gemini-api","expert":null},{"seat":"xai-api","adapter":"xai-api","expert":null}]' "plain seats: expert null"
assert_eq "$(jq -c '.panel.independence' "$TMP/o1/decision-log.json")" '{"seats":4,"adapters":4,"families":4}' "independence over all seats"
echo "ok - hosted shape: 2 experts + 2 plain seats on 4 priced vendors, built-in text only, per-token seat check passes"

# the transcript line; the Gallery parser's INFO_LINE (cloud:src/gallery-snapshot.js) skips it; the synthesis prompt never carries it
LINE='**Experts (perspectives, not measured):** skeptic on anthropic-api, customer on openai-api; plain seats: gemini-api, xai-api.'
assert_eq "$(sed -n '7p' "$TMP/o1/transcript.md")" "$LINE" "the info line, after the question"
assert_eq "$(sed -n '1,6p' "$TMP/o1/transcript.md" | head -5 | tail -1)" "**Question:** Which one?"
node - "$TMP/o1/transcript.md" <<'JS'
const fs = require('node:fs');
const t = fs.readFileSync(process.argv[2], 'utf8');
const INFO_LINE = /^\*\*[A-Za-z][^\n]{0,400}\*\*[^\n]{0,400}\n\n/; // copied from cloud:src/gallery-snapshot.js (e3d-pilot-cloud origin/main)
const q = 'Which one?';
let at = t.indexOf(q) + q.length + 2;
let skipped = 0;
for (let x = INFO_LINE.exec(t.slice(at, at + 1000)); x; x = INFO_LINE.exec(t.slice(at, at + 1000))) { at += x[0].length; skipped++; }
if (skipped !== 1) throw new Error(`expected one info line skipped, got ${skipped}`);
if (!t.slice(at).startsWith('## Round 1 -- anthropic-api')) throw new Error(`the body must start at the first round heading: ${JSON.stringify(t.slice(at, at + 40))}`);
const heads = [...t.matchAll(/^## Round (\d+) -- (\S+)$/gm)].map((m) => m[2]);
if (heads.join() !== 'anthropic-api,openai-api,gemini-api,xai-api,anthropic-api,openai-api,gemini-api,xai-api') throw new Error(`headings are adapter names: ${heads}`);
JS
assert_eq "$(prompts_with 'Experts (perspectives')" "0" "no prompt carries the experts line (the synthesis prompt is built from the copy made before it)"
echo "ok - the transcript has one Experts line after the question, the parser skips it, headings stay adapter names, no prompt carries it"

# 2. the control: without --builtin-only a host folder DOES win (so test 1 proves the switch, not an empty plant)
: > "$VREQ"
dbt "$TMP/o2" 1 --specialist skeptic --specialist customer --fill-pool
[[ $rc -eq 0 ]] || fail "control run failed: $(cat "$TMP/dbt.out")"
assert_eq "$(prompts_with PLANTED-SKEPTIC-MARK)" "2" "without --builtin-only the repo folder overrides the built-in"
assert_eq "$(prompts_with PLANTED-CUSTOMER-MARK)" "2" "without --builtin-only the user folder overrides the built-in"
# the same through the environment variable
: > "$VREQ"; rc=0
(cd "$WORK" && env -u E3D_SPECIALISTS "${vendor_env[@]}" HOME="$HOMED" E3D_SPECIALISTS=1 E3D_SPECIALISTS_BUILTIN_ONLY=1 E3D_DEBATE_MAX_TOKENS="$LIM" E3D_DEBATE_ANSWER_BYTES_MAX="$ANS" \
  "$ROOT/bin/e3d-debate" --providers "$P4" --synthesizer anthropic-api --out-dir "$TMP/o2b" --rounds 1 --specialist skeptic --specialist customer "Which one?") > "$TMP/dbt.out" 2>&1 || rc=$?
[[ $rc -eq 0 ]] || fail "env builtin-only failed: $(cat "$TMP/dbt.out")"
assert_eq "$(prompts_with PLANTED)" "0" "E3D_SPECIALISTS_BUILTIN_ONLY=1 does the same"
echo "ok - the planted folders do override without --builtin-only (control) and are ignored with it"

# 3. --fill-pool keeps priced vendors: 3 experts on a 4-vendor pool leave exactly one plain seat; seat ids equal adapters
: > "$VREQ"
dbt "$TMP/o3" 1 --specialist skeptic --specialist customer --specialist architect --builtin-only --fill-pool
[[ $rc -eq 0 ]] || fail "3 experts failed: $(cat "$TMP/dbt.out")"
assert_eq "$(jq -c '.providers' "$TMP/o3/decision-log.json")" '["anthropic-api","openai-api","gemini-api","xai-api"]'
assert_eq "$(jq -c '[.panel.plain_seats[].seat]' "$TMP/o3/decision-log.json")" '["xai-api"]'
assert_eq "$(sed -n '7p' "$TMP/o3/transcript.md")" '**Experts (perspectives, not measured):** skeptic on anthropic-api, customer on openai-api, architect on gemini-api; plain seat: xai-api.'
# 4 experts: no plain seat, and the line has no plain-seat clause
dbt "$TMP/o3b" 1 --specialist skeptic --specialist customer --specialist architect --specialist premortem --builtin-only --fill-pool
[[ $rc -eq 0 ]] || fail "4 experts failed: $(cat "$TMP/dbt.out")"
assert_eq "$(jq -c '.panel.plain_seats' "$TMP/o3b/decision-log.json")" '[]'
assert_eq "$(sed -n '7p' "$TMP/o3b/transcript.md")" '**Experts (perspectives, not measured):** skeptic on anthropic-api, customer on openai-api, architect on gemini-api, premortem on xai-api.'
# without --fill-pool the planner is what it was: the panel shrinks to the experts
dbt "$TMP/o3c" 1 --specialist skeptic --specialist customer --builtin-only
[[ $rc -eq 0 ]] || fail "no fill-pool failed: $(cat "$TMP/dbt.out")"
assert_eq "$(jq -c '.providers' "$TMP/o3c/decision-log.json")" '["anthropic-api","openai-api"]' "without --fill-pool the council is only the experts (Phase 1 behaviour)"
assert_eq "$(jq -c '.panel | has("plain_seats")' "$TMP/o3c/decision-log.json")" "false"
! grep -q 'Experts (perspectives' "$TMP/o3c/transcript.md" || fail "no info line without --fill-pool (a local run's transcript is unchanged)"
echo "ok - --fill-pool keeps every priced vendor as a plain seat; without it the planner is unchanged"

# 4. refusals (nothing is called): more experts than providers never adds seats; a pin mismatch; an oversized lens; flags without experts on
: > "$VREQ"
PROVS=anthropic-api,openai-api dbt "$TMP/o4" 1 --specialist skeptic --specialist customer --specialist architect --builtin-only --fill-pool
assert_eq "$rc" "1" "3 experts for 2 providers is refused"; assert_contains "$(cat "$TMP/dbt.out")" "one expert on each provider"
dbt "$TMP/o4" 1 --specialist skeptic --specialist customer --builtin-only --fill-pool --expert-pin "skeptic=sha256:$(printf '0%.0s' $(seq 1 64))" --expert-pin "customer=$H_CUSTOMER"
assert_eq "$rc" "1" "a pin mismatch is refused"; assert_contains "$(cat "$TMP/dbt.out")" "pinned content hash"
dbt "$TMP/o4" 1 --specialist skeptic --specialist customer --fill-pool --expert-pin "skeptic=$H_SKEPTIC"
assert_eq "$rc" "1" "a pin does not match an overriding host folder (without --builtin-only the planted skeptic has another hash)"; assert_contains "$(cat "$TMP/dbt.out")" "pinned content hash"
dbt "$TMP/o4" 1 --specialist skeptic --specialist customer --builtin-only --fill-pool --expert-pin "architect=$H_SKEPTIC"
assert_eq "$rc" "1" "a pin for an expert that was not named is refused"
dbt "$TMP/o4" 1 --specialist skeptic --specialist customer --builtin-only --fill-pool --expert-pin "skeptic=notahash"
assert_eq "$rc" "1" "a malformed pin is refused"
dbt "$TMP/o4" 1 --specialist skeptic --specialist customer --builtin-only --fill-pool --lens-bytes-max 100
assert_eq "$rc" "1" "a lens block larger than --lens-bytes-max is refused"; assert_contains "$(cat "$TMP/dbt.out")" "larger than the limit of 100 bytes"
dbt "$TMP/o4" 1 --specialist skeptic --specialist customer --builtin-only --fill-pool --lens-bytes-max "$(( $(printf '%s' "$(node -e "import('$ROOT/lib/debate/specialists-plan.mjs').then((p)=>import('$ROOT/lib/debate/specialists.mjs').then((m)=>{const e=m.loadExperts({tiers:[{name:'b',dir:'$ROOT/lib/specialists'}]}).experts.find((x)=>x.name==='skeptic');process.stdout.write(String(Buffer.byteLength(p.lensBlock(e))))}))")") - 1 ))"
assert_eq "$rc" "1" "one byte under the block is refused (the limit is exact)"
dbt "$TMP/o4" unset --specialist skeptic --specialist customer --builtin-only
assert_eq "$rc" "1" "the new flags need E3D_SPECIALISTS=1"; assert_contains "$(cat "$TMP/dbt.out")" "experts are off"
dbt "$TMP/o4" 1 --panel risk-review --fill-pool
assert_eq "$rc" "1" "--fill-pool is for --specialist experts"
assert_eq "$(vreq_count)" "0" "none of the refusals reached a vendor"
echo "ok - refused before any call: more experts than providers, a pin mismatch (also against a host override), an oversized lens, flags without experts on"

# ---------------------------------------------------------------- the real run listener
STUB="$ROOT/examples/external-auth-stub.js"
SERVER="$ROOT/bin/e3d-mcp"
SVC="svc-MARKER-$(openssl rand -hex 12)"
RUNTOK="runtok-MARKER-$(openssl rand -hex 16)"
TOK_A="caller-MARKER-a-$(openssl rand -hex 12)"
jq -n --arg a "$TOK_A" '{accounts: [{principal: "acct_web", balance: 1000000, keys: [{id: "key-a", token: $a}]}]}' > "$TMP/seed.json"
env STUB_SERVICE_TOKEN="$SVC" STUB_SEED="$TMP/seed.json" STUB_URL_FILE="$TMP/stub.url" STUB_FEATURES="finalize,fetch,authorize-run" STUB_PRICING=1 node "$STUB" > "$TMP/stub.out" 2> "$TMP/stub.log" &
PIDS+=("$!")
for _ in $(seq 1 100); do [[ -s "$TMP/stub.url" ]] && break; sleep 0.05; done
URL="$(cat "$TMP/stub.url")"
billing() { curl -sS -X POST -H "authorization: Bearer $SVC" -H 'content-type: application/json' "${@:2}" "$URL/$1"; }
new_id() { echo "dbt_$(openssl rand -hex 12)"; }
Q="QCONTENT: which expert lenses?"
DEBATE="$TMP/stub-debate"; ARGS="$TMP/debate.args"; ENVS="$TMP/debate.envs"; : > "$ARGS"; : > "$ENVS"
cat > "$DEBATE" <<STUBEOF
#!/usr/bin/env bash
out=""; all="\$*"
while [[ \$# -gt 0 ]]; do case "\$1" in --out-dir) out="\$2"; shift 2 ;; *) shift ;; esac; done
echo "\$all" | sed -E "s#--question-file [^ ]+#--question-file F#; s#--out-dir [^ ]+#--out-dir D#" >> "$ARGS"
echo "specialists=\${E3D_SPECIALISTS:-unset}" >> "$ENVS"
mkdir -p "\$out"
printf '# Debate\n\n## Round 1 -- anthropic-api\n\nJSON file.\n\n## Round 1 -- openai-api\n\nSQLite.\n' > "\$out/transcript.md"
printf 'FINAL ANSWER: use a JSON file.\nCONSENSUS: split\nDISSENT: SQLite has a case.\n'
STUBEOF
chmod +x "$DEBATE"
BASE_ENV=(E3D_MCP_AUTH_URL="$URL" E3D_MCP_AUTH_SERVICE_TOKEN="$SVC" E3D_MCP_DEBATE_BIN="$DEBATE" TYPESAFE_API_KEY="" E3D_MCP_PRINCIPAL=""
  E3D_MCP_AUTH_CACHE_SEC=1 E3D_MCP_TIMEOUT_SEC=20 E3D_MCP_AUTH_HEALTH_SEC=1 E3D_MCP_RATE_PER_MIN=100000
  E3D_MCP_PRICING=per_token E3D_MCP_CUSTOMER_LIMITS='rounds=2,max_words=300,providers=4' E3D_MCP_PER_TOKEN_ALLOW_XAI=1)

out="$(env "${BASE_ENV[@]}" E3D_MCP_STATE_DIR="$TMP/state-bad" E3D_MCP_EXPERTS_RUN=2 "$SERVER" --http --port 0 2>&1)" && fail "a bad E3D_MCP_EXPERTS_RUN must refuse to start" || true
assert_contains "$out" "E3D_MCP_EXPERTS_RUN must be unset, 0 or 1"
out="$(env "${BASE_ENV[@]}" E3D_MCP_STATE_DIR="$TMP/state-bad" E3D_MCP_PRICING= E3D_MCP_EXPERTS_RUN=1 "$SERVER" --http --port 0 2>&1)" && fail "experts run needs per-token pricing" || true
assert_contains "$out" "E3D_MCP_EXPERTS_RUN=1 needs E3D_MCP_PRICING=per_token"
echo "ok - E3D_MCP_EXPERTS_RUN is validated at startup"

start_server() { # start_server <name> [VAR=value ...]
  local name="$1"; shift
  : > "$TMP/$name.port"; : > "$TMP/$name.runport"
  env "${BASE_ENV[@]}" E3D_MCP_STATE_DIR="$TMP/state-$name" E3D_MCP_PORT_FILE="$TMP/$name.port" E3D_MCP_RUN_PORT=0 E3D_MCP_RUN_PORT_FILE="$TMP/$name.runport" E3D_MCP_RUN_TOKEN="$RUNTOK" "$@" \
    "$SERVER" --http --port 0 2>> "$TMP/$name.log" &
  PIDS+=("$!")
  for _ in $(seq 1 100); do [[ -s "$TMP/$name.runport" ]] && break; sleep 0.1; done
  [[ -s "$TMP/$name.runport" ]] || { cat "$TMP/$name.log" >&2; fail "server $name did not start"; }
  RUN="http://127.0.0.1:$(cat "$TMP/$name.runport")/internal/runs"
  curl -s -o /dev/null -X POST -H 'content-type: application/json' -H 'accept: application/json' -H "Authorization: Bearer $TOK_A" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"experts-run-test","version":"0"}}}' "http://127.0.0.1:$(cat "$TMP/$name.port")/mcp"
}
rpost() { curl -s -o "$TMP/rbody" -w '%{http_code}' -X POST -H "authorization: Bearer $RUNTOK" -H 'content-type: application/json' -d "$1" "$RUN"; echo; cat "$TMP/rbody"; echo; }
code() { head -1 <<< "$1"; }
js() { tail -n +2 <<< "$1"; }
rget() { curl -s -H "authorization: Bearer $RUNTOK" -H "x-e3d-run-token: $2" "$RUN/$1"; }
wait_run() { for _ in $(seq 1 150); do [[ "$(rget "$1" "$2" | jq -r '.run.status // empty')" == "$3" ]] && return 0; sleep 0.2; done; fail "run $1 did not reach $3: $(rget "$1" "$2")"; }
web_reserve() { billing reserve -H 'x-e3d-auth-version: 1' -d "$(jq -nc --arg r "$(uuidgen | tr 'A-Z' 'a-z')" '{principal:"acct_web",request_id:$r,kind:"debate",tool:"web",units:{calls:9,est_tokens:0}}')" | jq -r .reservation_id; }
web_debate() { billing _stub/web-debate -d "$(jq -nc --arg r "$1" --arg d "$2" --arg q "$Q" '{reservation_id:$r,debate_id:$d,question:$q}')" > /dev/null; }
LIMS='{"anthropic-api":300,"openai-api":300,"gemini-api":300,"xai-api":300}'
body() { # body <providers json> [jq filter]: a complete per-token run body with two experts, a fresh reservation and debate id
  local r d; r="$(web_reserve)"; d="$(new_id)"; web_debate "$r" "$d"
  jq -nc --arg r "$r" --arg d "$d" --arg q "$Q" --argjson p "$1" --argjson m "$LIMS" --arg hs "$H_SKEPTIC" --arg hc "$H_CUSTOMER" \
    '{reservation_id:$r,debate_id:$d,question:$q,providers:$p,rounds:2,max_words:300,max_tokens:$m,answer_bytes:$m,experts:[{id:"skeptic",hash:$hs},{id:"customer",hash:$hc}],lens_bytes:640} | '"${2:-.}"
}
ALL4='["anthropic-api","openai-api","gemini-api","xai-api"]'
nruns() { wc -l < "$ARGS" | tr -d ' '; }

# --- a listener WITHOUT E3D_MCP_EXPERTS_RUN: the capability is not advertised, the fields are refused, a body without them runs as before ---
start_server off
r="$(rpost '{}')"
assert_eq "$(code "$r")" "400"; assert_eq "$(js "$r" | jq -c '.capabilities')" '["per_token_v1"]' "no experts_v1 without the variable"
n0="$(nruns)"
r="$(rpost "$(body "$ALL4")")"
assert_eq "$(code "$r")" "400" "experts sent to a listener without experts_v1: $(js "$r")"; assert_eq "$(js "$r" | jq -r '[.code, .accepted] | join(",")')" "invalid,false"
assert_contains "$(js "$r")" "unknown field"
r="$(rpost "$(body "$ALL4" 'del(.experts)')")"; assert_eq "$(code "$r")" "400" "lens_bytes alone is refused as well"
sleep 0.3; assert_eq "$(nruns)" "$n0" "nothing ran"
PLAIN="$(body "$ALL4" 'del(.experts, .lens_bytes)')"
r="$(rpost "$PLAIN")"; assert_eq "$(code "$r")" "202" "a body without the new fields is accepted: $(js "$r")"; wait_run "$(jq -r .debate_id <<< "$PLAIN")" "$(js "$r" | jq -r .run_token)" done
ARGS_OFF="$(tail -1 "$ARGS")"; ENV_OFF="$(tail -1 "$ENVS")"
assert_not_contains "$ARGS_OFF" "--specialist"; assert_not_contains "$ARGS_OFF" "--fill-pool"; assert_eq "$ENV_OFF" "specialists=unset"
echo "ok - without E3D_MCP_EXPERTS_RUN: no experts_v1, both fields refused (400 invalid, nothing runs), a body without them runs as before"

# --- a listener WITH it ---
start_server on E3D_MCP_EXPERTS_RUN=1
r="$(rpost '{}')"
assert_eq "$(js "$r" | jq -c '.capabilities')" '["per_token_v1","experts_v1"]' "experts_v1 is advertised next to per_token_v1"
# a body without experts is exactly what it was: same arguments, no experts environment
PLAIN2="$(body "$ALL4" 'del(.experts, .lens_bytes)')"
r="$(rpost "$PLAIN2")"; assert_eq "$(code "$r")" "202"; wait_run "$(jq -r .debate_id <<< "$PLAIN2")" "$(js "$r" | jq -r .run_token)" done
assert_eq "$(tail -1 "$ARGS")" "$ARGS_OFF" "flag on, no experts: the debate arguments are byte-identical to flag off"
assert_eq "$(tail -1 "$ENVS")" "$ENV_OFF"
# a valid expert run: the arguments the engine receives
B1="$(body "$ALL4")"; D1="$(jq -r .debate_id <<< "$B1")"
r="$(rpost "$B1")"; assert_eq "$(code "$r")" "202" "accepted: $(js "$r")"; RT1="$(js "$r" | jq -r .run_token)"; wait_run "$D1" "$RT1" done
assert_eq "$(tail -1 "$ARGS")" "--question-file F --providers anthropic-api,openai-api,gemini-api,xai-api --rounds 2 --max-words 300 --out-dir D --synthesizer $(tail -1 "$ARGS" | sed -E 's/.*--synthesizer ([^ ]+).*/\1/') --web-search off --specialist skeptic --specialist customer --builtin-only --fill-pool --lens-bytes-max 640 --expert-pin skeptic=$H_SKEPTIC --expert-pin customer=$H_CUSTOMER" "experts go in request order, then the switches and the pins; every other argument as before"
assert_eq "$(tail -1 "$ENVS")" "specialists=1"
# an identical retry is the same run; changed experts or lens_bytes is a conflict
r="$(rpost "$B1")"; assert_eq "$(code "$r")" "200" "identical retry: existing"; assert_eq "$(js "$r" | jq -r '.run_token == "'"$RT1"'"')" "true"
n1="$(nruns)"
r="$(rpost "$(jq -c '.experts |= reverse' <<< "$B1")")"; assert_eq "$(code "$r")" "409" "a different expert order is a different request"
r="$(rpost "$(jq -c '.lens_bytes = 641' <<< "$B1")")"; assert_eq "$(code "$r")" "409" "lens_bytes is part of the key"
assert_eq "$(nruns)" "$n1" "no second run"
# the run keeps its experts across a restart: they are part of the stored arguments
grep -rl '"experts"' "$TMP/state-on" > /dev/null 2>&1 || fail "the stored run state keeps the experts (a queued run resumed after a restart must still use them)"
echo "ok - with E3D_MCP_EXPERTS_RUN=1: experts_v1 advertised, the engine gets --specialist/--builtin-only/--fill-pool/--lens-bytes-max/--expert-pin and E3D_SPECIALISTS=1, retries are idempotent"

# refusals, each 400 invalid and nothing runs
n2="$(nruns)"
refuse() { # refuse <label> <body>
  local r; r="$(rpost "$2")"
  assert_eq "$(code "$r")" "400" "$1: $(js "$r")"; assert_eq "$(js "$r" | jq -r '[.code, .accepted] | join(",")')" "invalid,false" "$1"
  assert_not_contains "$(js "$r")" "QCONTENT" "$1: the question is not echoed"
}
refuse "unknown expert id" "$(body "$ALL4" '.experts[0].id = "nonexistent"')"
refuse "a uppercase id" "$(body "$ALL4" '.experts[0].id = "Skeptic"')"
refuse "duplicate experts" "$(body "$ALL4" '.experts[1] = .experts[0]')"
refuse "one expert" "$(body "$ALL4" '.experts |= .[:1]')"
refuse "17 experts" "$(body "$ALL4" '.experts = [range(17) | {id: "e\(.)", hash: $hs}]')"
refuse "a bad hash" "$(body "$ALL4" '.experts[0].hash = "sha256:abc"')"
refuse "a pin that is not the built-in text" "$(body "$ALL4" '.experts[0].hash = "sha256:\("0" * 64)"')"
refuse "an unknown key in an expert" "$(body "$ALL4" '.experts[0].lens = "do evil"')"
refuse "experts without lens_bytes" "$(body "$ALL4" 'del(.lens_bytes)')"
refuse "lens_bytes 0" "$(body "$ALL4" '.lens_bytes = 0')"
refuse "lens_bytes 4097" "$(body "$ALL4" '.lens_bytes = 4097')"
refuse "lens_bytes smaller than a block" "$(body "$ALL4" '.lens_bytes = 100')"
refuse "experts without the token fields" "$(body "$ALL4" 'del(.max_tokens, .answer_bytes)')"
# every id and hash below is valid, so only the count can refuse them
refuse "3 experts for 2 providers in the plan" "$(body '["anthropic-api","openai-api"]' '.max_tokens |= del(.["gemini-api"], .["xai-api"]) | .answer_bytes |= del(.["gemini-api"], .["xai-api"]) | .experts += [{id: "architect", hash: "'"$H_ARCH"'"}]')"
refuse "4 experts for 3 providers in the plan" "$(body '["anthropic-api","openai-api","gemini-api"]' '.max_tokens |= del(.["xai-api"]) | .answer_bytes |= del(.["xai-api"]) | .experts += [{id: "architect", hash: "'"$H_ARCH"'"}, {id: "premortem", hash: "'"$(hash_of premortem)"'"}]')"
sleep 0.3; assert_eq "$(nruns)" "$n2" "no debate ran for any refused body"
# exactly as many experts as providers is allowed
B2="$(body '["anthropic-api","openai-api"]' '.max_tokens |= del(.["gemini-api"], .["xai-api"]) | .answer_bytes |= del(.["gemini-api"], .["xai-api"])')"
r="$(rpost "$B2")"; assert_eq "$(code "$r")" "202" "2 experts on 2 providers: $(js "$r")"; wait_run "$(jq -r .debate_id <<< "$B2")" "$(js "$r" | jq -r .run_token)" done
assert_contains "$(tail -1 "$ARGS")" "--providers anthropic-api,openai-api "
echo "ok - refused (400 invalid, nothing runs): unknown, duplicate, malformed, mismatched-hash and too-many experts, bad lens_bytes, a lens block over lens_bytes, experts outnumbering providers"
echo "mcp-experts-run: all passed"
