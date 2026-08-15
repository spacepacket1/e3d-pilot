#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/e3d-pilot"
SAMPLE_CONFIG="$ROOT/examples/sample-config.json"

assert_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] || {
    printf 'expected to find %q in output:\n%s\n' "$needle" "$haystack" >&2
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

make_repo() {
  local repo
  repo="$(mktemp -d)"
  git init -q "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test User"
  printf '# Phase 23 Repo\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m init
  mkdir -p "$repo/.e3d-pilot"
  jq '.approval.implementation_required=true | .approval.merge_required=true' "$SAMPLE_CONFIG" > "$repo/.e3d-pilot/config.json"
  printf '%s' "$repo"
}

ingest_idea() {
  local repo="$1" title="$2" candidate idea
  candidate="$(mktemp)"
  jq -ncS --arg title "$title" '{
    title:$title,summary:"Phase 23 fixture.",scores:{attraction:3,retention:3,revenue:2,effort:"low"},
    category:"testing",dedup_rationale:"new",validation:{approvable:true,eligibility_reason:null,warnings:[]}
  }' > "$candidate"
  idea="$("$BIN" ideas ingest --repo "$repo" --run-id run-1 --candidate-id candidate-1 --candidate-json "$candidate")"
  rm -f "$candidate"
  printf '%s' "$idea"
}

extract_csrf() {
  local page="$1"
  echo "$page" | grep -o 'name="_csrf" value="[^"]*"' | head -1 | sed 's/.*value="//;s/"$//'
}

start_server() {
  local repo="$1" port="$2" auth="$3" log="$4"
  if [[ "$auth" == "1" ]]; then
    E3D_PILOT_WEB_AUTH_USER=testuser E3D_PILOT_WEB_AUTH_PASS=testpass \
      "$BIN" web --repo "$repo" --port "$port" >"$log" 2>&1 &
  else
    env -u E3D_PILOT_WEB_AUTH_USER -u E3D_PILOT_WEB_AUTH_PASS \
      "$BIN" web --repo "$repo" --port "$port" >"$log" 2>&1 &
  fi
  printf '%s' "$!"
}

wait_for_server() {
  local port="$1" attempt=0
  until curl -s -o /dev/null -m 1 "http://127.0.0.1:$port/ideas" || [[ $attempt -ge 50 ]]; do
    attempt=$((attempt + 1))
    sleep 0.1
  done
  [[ $attempt -lt 50 ]]
}

# --- refuses without node/env vars, syntax --------------------------------

syntax_checks() {
  bash -n "$BIN"
  for f in "$ROOT"/lib/web/*.js; do
    node --check "$f" || { echo "node --check failed for $f" >&2; exit 1; }
  done
}

refuses_to_start_without_auth_env_vars() {
  local repo out status
  repo="$(make_repo)"
  set +e
  out="$(env -u E3D_PILOT_WEB_AUTH_USER -u E3D_PILOT_WEB_AUTH_PASS "$BIN" web --repo "$repo" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "expected web to refuse without auth env vars" >&2; exit 1; }
  assert_contains "$out" "E3D_PILOT_WEB_AUTH_USER"
  rm -rf "$repo"
}

refuses_unknown_repo() {
  local out status
  set +e
  out="$("$BIN" web --repo /nonexistent/path/does-not-exist 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "expected web to refuse a nonexistent repo path" >&2; exit 1; }
}

# --- live server end to end -----------------------------------------------

full_round_trip() {
  local repo port pid log idea page token status
  repo="$(make_repo)"
  idea="$(ingest_idea "$repo" "Web UI fixture idea")"
  port=$(( (RANDOM % 5000) + 25000 ))
  log="$(mktemp)"

  pid="$(start_server "$repo" "$port" 1 "$log")"
  if ! wait_for_server "$port"; then
    kill "$pid" 2>/dev/null || true
    cat "$log" >&2
    echo "web server never became reachable" >&2
    exit 1
  fi

  # no auth -> 401
  status="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/ideas")"
  assert_eq "$status" "401" "GET /ideas without auth"

  # wrong auth -> 401
  status="$(curl -s -o /dev/null -w '%{http_code}' -u wrong:creds "http://127.0.0.1:$port/ideas")"
  assert_eq "$status" "401" "GET /ideas with wrong auth"

  # correct auth -> 200, fixture idea title present
  page="$(curl -s -u testuser:testpass "http://127.0.0.1:$port/ideas")"
  assert_contains "$page" "Web UI fixture idea"

  # detail page renders
  page="$(curl -s -u testuser:testpass "http://127.0.0.1:$port/ideas/$(basename "$repo")/$idea")"
  assert_contains "$page" "Web UI fixture idea"
  assert_contains "$page" "proposed"

  # POST without CSRF token -> 403
  status="$(curl -s -o /dev/null -w '%{http_code}' -u testuser:testpass -X POST -d "x=1" "http://127.0.0.1:$port/ideas/$(basename "$repo")/$idea/approve")"
  assert_eq "$status" "403" "POST approve without csrf token"

  # POST with a valid CSRF token actually flips ledger status, not just HTTP 200
  local jar
  jar="$(mktemp)"
  page="$(curl -s -c "$jar" -b "$jar" -u testuser:testpass "http://127.0.0.1:$port/ideas/$(basename "$repo")/$idea")"
  token="$(extract_csrf "$page")"
  [[ -n "$token" ]] || { echo "failed to extract csrf token from detail page" >&2; exit 1; }
  status="$(curl -s -c "$jar" -b "$jar" -u testuser:testpass -o /dev/null -w '%{http_code}' -X POST --data-urlencode "_csrf=$token" "http://127.0.0.1:$port/ideas/$(basename "$repo")/$idea/approve")"
  assert_eq "$status" "302" "POST approve with valid csrf token"
  assert_eq "$("$BIN" ideas show --repo "$repo" "$idea" --json | jq -r '.status')" "approved_for_implementation" "approve actually mutated the ledger, not just rendered a form"

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$repo"; rm -f "$log" "$jar"
}

main() {
  syntax_checks
  refuses_to_start_without_auth_env_vars
  refuses_unknown_repo
  full_round_trip
  echo "phase23: all tests passed"
}

main "$@"
