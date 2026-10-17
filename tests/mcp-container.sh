#!/usr/bin/env bash
set -euo pipefail

# Builds deploy/Dockerfile and exercises the hosted server inside a real container: non-root, read-only
# filesystem, token enforcement, a full debate against fake Azure/local model endpoints on the host, and
# budget persistence across a container restart. OPT-IN: set E3D_TEST_DOCKER=1 (needs a running Docker daemon).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${E3D_TEST_DOCKER:-0}" != "1" ]]; then echo "mcp-container.sh: skipped (set E3D_TEST_DOCKER=1 to run)"; exit 0; fi
docker info >/dev/null 2>&1 || { echo "mcp-container.sh: skipped (docker daemon not running)"; exit 0; }

TMP="$(mktemp -d)"
NAME="e3d-mcp-test-$$"
VOL="e3d-mcp-test-state-$$"
FAKE_PID=""
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; docker volume rm "$VOL" >/dev/null 2>&1 || true; [[ -n "$FAKE_PID" ]] && kill "$FAKE_PID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-assert_eq}: expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "${3:-assert_contains}: expected to find [$2] in [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "${3:-assert_not_contains}: did not expect [$2] in [$1]"; }

IMAGE="e3d-mcp:test-$$"
docker build -q -f "$ROOT/deploy/Dockerfile" -t "$IMAGE" "$ROOT" >/dev/null || fail "image build failed"
trap 'docker rmi -f "$IMAGE" >/dev/null 2>&1 || true; cleanup' EXIT

# 1. fail-fast: listening beyond loopback without tokens must refuse to start
out="$(docker run --rm "$IMAGE" 2>&1)" && fail "the container must refuse to start without E3D_MCP_AUTH_TOKENS" || true
assert_contains "$out" "requires auth"

# fake model endpoints on the host (Azure-style and OpenAI-compatible "local"), both answering with a verdict
BLOCK=$'FINAL ANSWER: Use JSON.\nCONSENSUS: split\nDISSENT: one voice prefers SQLite.\n'
cat > "$TMP/fake.mjs" <<'JS'
import http from 'node:http';
const srv = http.createServer((req, res) => { req.resume(); req.on('end', () => {
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ model: 'fake', choices: [{ message: { content: process.env.BLOCK } }], usage: { total_tokens: 12 } }));
}); });
srv.listen(0, '0.0.0.0', () => console.log(srv.address().port));
JS
BLOCK="$BLOCK" node "$TMP/fake.mjs" > "$TMP/fake.port" & FAKE_PID=$!
for _ in $(seq 1 50); do [[ -s "$TMP/fake.port" ]] && break; sleep 0.1; done
FAKE="http://host.docker.internal:$(cat "$TMP/fake.port")"

TOKEN="container-token-0123456789abcdef"
run_container() {
  docker run -d --name "$NAME" --read-only --tmpfs /tmp -v "$VOL:/var/lib/e3d-mcp" -p 127.0.0.1::8787 \
    -e E3D_MCP_AUTH_TOKENS="ci:$TOKEN" -e E3D_MCP_DAILY_CALLS=6 \
    -e AZURE_OPENAI_ENDPOINT="$FAKE" -e AZURE_OPENAI_DEPLOYMENT=dep -e AZURE_OPENAI_API_KEY="azure-secret-0123456789" \
    -e LOCAL_MODEL_ENDPOINT="$FAKE/v1" -e TYPESAFE_API_KEY= \
    "$IMAGE" >/dev/null
  for _ in $(seq 1 60); do
    PORT="$(docker port "$NAME" 8787/tcp 2>/dev/null | head -1 | sed 's/.*://')"
    [[ -n "$PORT" ]] && curl -s -m 2 "http://127.0.0.1:$PORT/healthz" | grep -q '"ok"' && return 0
    sleep 0.5
  done
  docker logs "$NAME" >&2; fail "container did not become healthy"
}
mcp() {  # mcp <session|-> <json>  -> body
  local a=(); [[ "$1" != "-" ]] && a=(-H "mcp-session-id: $1")
  curl -s -m 60 -X POST "http://127.0.0.1:$PORT/mcp" -H 'content-type: application/json' -H 'accept: application/json' -H "Authorization: Bearer $TOKEN" "${a[@]}" -d "$2"
}
newsession() {
  curl -s -m 20 -D - -o /dev/null -X POST "http://127.0.0.1:$PORT/mcp" -H 'content-type: application/json' -H "Authorization: Bearer $TOKEN" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ci","version":"0"}}}' | grep -i '^mcp-session-id' | tr -d '\r' | awk '{print $2}'
}
tool() { mcp "$1" "$(jq -nc --arg n "$2" --argjson a "$3" '{jsonrpc:"2.0",id:5,method:"tools/call",params:{name:$n,arguments:$a}}')"; }

run_container

# 2. hardening: non-root, read-only root filesystem, state dir writable
assert_eq "$(docker exec "$NAME" id -u)" "1000" "runs as the unprivileged node user"
docker exec "$NAME" sh -c 'touch /etc/should-fail' 2>/dev/null && fail "root filesystem must be read-only"
docker exec "$NAME" sh -c 'touch /var/lib/e3d-mcp/.w && rm /var/lib/e3d-mcp/.w' || fail "state volume must be writable"
docker exec "$NAME" bash -c 'echo ${BASH_VERSINFO[0]}' | grep -q '^5$' || fail "bash 5 expected in the image"
docker exec "$NAME" node -e "fetch('http://127.0.0.1:8787/healthz').then(r=>process.exit(r.ok?0:1))" || fail "the HEALTHCHECK command must succeed"

# 3. auth in front of everything
assert_eq "$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/mcp" -H 'content-type: application/json' -d '{}')" "401"

# 4. providers inside the image: the two cloud adapters see their config, claude/codex are simply absent
SID="$(newsession)"; [[ -n "$SID" ]] || fail "no session"
list="$(tool "$SID" e3d_list_providers '{}' | jq -r '.result.content[0].text')"
assert_contains "$list" "azure-openai: available"; assert_contains "$list" "local: available"; assert_contains "$list" "claude: unavailable"

# 5. a real hosted debate end to end (default voices = whatever is configured here)
res="$(tool "$SID" e3d_debate '{"question":"JSON or SQLite?"}' | jq -c .result)"
[[ "$(jq -r '.isError // false' <<< "$res")" == "false" ]] || fail "debate failed: $res"
assert_eq "$(jq -r .structuredContent.consensus <<< "$res")" "split"
assert_eq "$(jq -r '.structuredContent.providers | sort | join(",")' <<< "$res")" "azure-openai,local" "auto-detected the configured cloud/local providers"
assert_eq "$(jq -r .structuredContent.budget.principal <<< "$res")" "ci"
assert_eq "$(jq -r .structuredContent.budget.calls_today <<< "$res")" "3"

# 6. secrets never reach the logs
logs="$(docker logs "$NAME" 2>&1)"
assert_not_contains "$logs" "$TOKEN"; assert_not_contains "$logs" "azure-secret"
assert_contains "$logs" "principal=ci"

# 7. the budget survives a container restart (volume), and the cap holds
docker rm -f "$NAME" >/dev/null
run_container
SID="$(newsession)"
assert_eq "$(tool "$SID" e3d_usage '{}' | jq -r .result.structuredContent.calls_today)" "3" "usage persisted on the volume"
res="$(tool "$SID" e3d_debate '{"question":"again"}' | jq -c .result)"; assert_eq "$(jq -r '.isError // false' <<< "$res")" "false"
res="$(tool "$SID" e3d_debate '{"question":"over the cap"}' | jq -c .result)"
assert_eq "$(jq -r '.isError // false' <<< "$res")" "true" "6 of 6 used: the next request is refused"
assert_contains "$(jq -r '.content[0].text' <<< "$res")" "daily budget"

echo "mcp-container.sh: ok"
