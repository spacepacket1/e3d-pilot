#!/usr/bin/env bash
# Creates (idempotently) the DNS-only A record pilot.e3d.ai -> the server, using the Cloudflare token in
# ~/.config/e3d-pilot/cloudflare-token. DNS-only on purpose: Cloudflare's proxy cuts requests at ~100 seconds,
# which would kill a long debate (mcp.e3d.ai is set up the same way).
#   cf-dns.sh status | create | delete
set -euo pipefail
NAME="${NAME:-pilot.e3d.ai}"; ZONE_NAME="${ZONE_NAME:-e3d.ai}"; IP="${IP:-3.131.8.46}"
TOKEN_FILE="${CF_TOKEN_FILE:-$HOME/.config/e3d-pilot/cloudflare-token}"
T="$(tr -d '\n ' < "$TOKEN_FILE")"
api() { curl -sS -m 20 -H "Authorization: Bearer $T" -H 'Content-Type: application/json' "$@"; }
ZONE="$(api "https://api.cloudflare.com/client/v4/zones?name=$ZONE_NAME" | jq -r '.result[0].id')"
[[ -n "$ZONE" && "$ZONE" != null ]] || { echo "zone $ZONE_NAME not visible to this token" >&2; exit 1; }
existing() { api "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records?type=A&name=$NAME" | jq -r '.result[0].id // empty'; }
case "${1:-status}" in
  status) id="$(existing)"; if [[ -n "$id" ]]; then api "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records/$id" | jq -c '.result | {name, content, proxied}'; else echo "$NAME has no A record"; fi ;;
  create)
    [[ -z "$(existing)" ]] || { echo "$NAME already exists"; exit 0; }
    api -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records" \
      --data "$(jq -nc --arg n "$NAME" --arg ip "$IP" '{type:"A",name:$n,content:$ip,ttl:120,proxied:false,comment:"e3d-mcp hosted debate service"}')" | jq -c '{success, errors, name: .result.name, content: .result.content, proxied: .result.proxied}' ;;
  delete) id="$(existing)"; [[ -n "$id" ]] || { echo "nothing to delete"; exit 0; }; api -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records/$id" | jq -c '{success, errors}' ;;
  *) echo "usage: cf-dns.sh status|create|delete" >&2; exit 2 ;;
esac
