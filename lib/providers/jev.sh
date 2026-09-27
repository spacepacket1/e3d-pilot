#!/usr/bin/env bash
# Thin client for TypeSafe's System One API ("Jev"): typed Choice/Score/Noul
# judgments over structured state, not chat completion.
# https://docs.typesafe.ai/api.md
#
# This is a helper library (sourced), not a pipeline-stage provider adapter
# like lib/providers/claude|codex|local: Jev isn't selectable in the
# "providers" config block, it's called directly by internal advisory checks
# (e.g. lib/ideas/jev_dedup.sh).

JEV_API_URL="${JEV_API_URL:-https://api.typesafe.ai/v1/systemone}"
JEV_CALL_TIMEOUT="${JEV_CALL_TIMEOUT:-10}"

jev_available() {
  [[ -n "${TYPESAFE_API_KEY:-}" ]]
}

# jev_call <model> <state_json> <questions_json>
# state_json/questions_json must already be valid JSON text (e.g. from
# `jq -ncS ...`). Prints the raw response JSON on stdout; returns non-zero on
# any failure (missing key, network error, non-2xx status, malformed
# response). Every caller must treat failure as "no signal" and skip -- never
# fabricate an answer.
#
# Testing seam: if E3D_PILOT_JEV_STUB_RESPONSE names a readable file, its
# contents are returned as-is instead of making a real request.
jev_call() {
  local model="$1" state_json="$2" questions_json="$3"
  local body tmp_body http_status

  if [[ -n "${E3D_PILOT_JEV_STUB_RESPONSE:-}" ]]; then
    [[ -f "$E3D_PILOT_JEV_STUB_RESPONSE" ]] || {
      echo "jev: stub response file not found: $E3D_PILOT_JEV_STUB_RESPONSE" >&2
      return 1
    }
    cat "$E3D_PILOT_JEV_STUB_RESPONSE"
    return 0
  fi

  jev_available || { echo "jev: TYPESAFE_API_KEY not set" >&2; return 1; }

  body="$(jq -ncS --argjson state "$state_json" --arg model "$model" --argjson questions "$questions_json" \
    '{state:$state, model:$model, questions:$questions}')" || return 1

  tmp_body="$(mktemp "${TMPDIR:-/tmp}/e3d-jev-response.XXXXXX")"
  http_status="$(curl -sS -o "$tmp_body" -w '%{http_code}' \
    --max-time "$JEV_CALL_TIMEOUT" \
    -X POST "$JEV_API_URL" \
    -H "Authorization: Bearer ${TYPESAFE_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$body" 2>/dev/null)" || {
    rm -f "$tmp_body"
    echo "jev: request failed" >&2
    return 1
  }

  if [[ "$http_status" != 2* ]]; then
    echo "jev: request failed with status $http_status: $(cat "$tmp_body" 2>/dev/null)" >&2
    rm -f "$tmp_body"
    return 1
  fi
  if ! jq -e . "$tmp_body" >/dev/null 2>&1; then
    echo "jev: invalid JSON response" >&2
    rm -f "$tmp_body"
    return 1
  fi
  cat "$tmp_body"
  rm -f "$tmp_body"
}
