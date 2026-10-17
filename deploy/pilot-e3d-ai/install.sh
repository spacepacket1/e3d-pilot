#!/usr/bin/env bash
# Idempotent installer for the hosted e3d-mcp service on Ubuntu (nginx + systemd). Run ON THE SERVER as root:
#   sudo REF=main CERTBOT_EMAIL=you@example.com bash install.sh
# It creates an unprivileged user, installs the code read-only, writes /etc/e3d-mcp/pilot.env from the template
# (only if absent, generating tokens), installs the systemd unit and nginx site, and gets a TLS certificate.
# It never overwrites an existing pilot.env, and it never prints or stores your model API keys.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
REPO_URL="${REPO_URL:-https://github.com/spacepacket1/e3d-pilot.git}"; REF="${REF:-main}"
APP_USER=e3dpilot; APP_DIR=/opt/e3d-pilot; STATE_DIR=/var/lib/e3d-mcp; ENV_DIR=/etc/e3d-mcp; ENV_FILE=$ENV_DIR/pilot.env
HOST_NAME="${HOST_NAME:-pilot.e3d.ai}"; CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for c in git node jq curl nginx openssl; do command -v "$c" >/dev/null || { echo "missing required command: $c" >&2; exit 1; }; done
(( $(bash -c 'echo ${BASH_VERSINFO[0]}') >= 4 )) || { echo "bash 4+ required" >&2; exit 1; }
(( $(node -p 'process.versions.node.split(".")[0]') >= 18 )) || { echo "node 18+ required" >&2; exit 1; }
NODE_BIN="$(command -v node)"

id -u "$APP_USER" >/dev/null 2>&1 || useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin "$APP_USER"

if [[ -d $APP_DIR/.git ]]; then git -C "$APP_DIR" fetch --depth 1 origin "$REF" && git -C "$APP_DIR" checkout -q FETCH_HEAD
else git clone --depth 1 --branch "$REF" "$REPO_URL" "$APP_DIR"; fi
chown -R root:root "$APP_DIR"   # the service can read the code but never change it
echo "code at $(git -C "$APP_DIR" rev-parse --short HEAD)"

install -d -o "$APP_USER" -g "$APP_USER" -m 0750 "$STATE_DIR"
install -d -o root -g "$APP_USER" -m 0750 "$ENV_DIR"
if [[ ! -f $ENV_FILE ]]; then
  tok() { openssl rand -hex 24; }
  tokens="chris:$(tok),guest1:$(tok),guest2:$(tok)"
  sed "s|__GENERATED__|$tokens|" "$KIT/pilot.env.example" > "$ENV_FILE"
  chown root:"$APP_USER" "$ENV_FILE"; chmod 0640 "$ENV_FILE"
  echo; echo "Created $ENV_FILE. Your access tokens (shown ONCE, also stored in that file):"; echo "$tokens" | tr ',' '\n' | sed 's/^/  /'
  echo "NEXT: edit $ENV_FILE and replace the three __PASTE_...__ values, then: systemctl restart e3d-mcp"
else echo "$ENV_FILE already exists, leaving it unchanged"; fi

sed "s|@NODE@|$NODE_BIN|" "$KIT/e3d-mcp.service" > /etc/systemd/system/e3d-mcp.service
echo 'limit_req_zone $binary_remote_addr zone=pilot:10m rate=20r/m;' > /etc/nginx/conf.d/pilot-ratelimit.conf
install -m 0644 "$KIT/nginx-pilot.e3d.ai.conf" "/etc/nginx/sites-available/$HOST_NAME"
ln -sf "/etc/nginx/sites-available/$HOST_NAME" "/etc/nginx/sites-enabled/$HOST_NAME"
nginx -t
systemctl daemon-reload
if grep -q '__PASTE_' "$ENV_FILE"; then echo "keys not filled in yet: NOT starting the service. Fill them in, then: systemctl enable --now e3d-mcp"
else systemctl enable --now e3d-mcp && sleep 2 && curl -fsS http://127.0.0.1:8787/healthz && echo; fi
systemctl reload nginx

if [[ -n $CERTBOT_EMAIL ]] && command -v certbot >/dev/null; then
  certbot --nginx -d "$HOST_NAME" --non-interactive --agree-tos -m "$CERTBOT_EMAIL" --redirect
else echo "TLS: run  certbot --nginx -d $HOST_NAME -m <email> --agree-tos --redirect  (needs the DNS record to exist first)"; fi
echo "Done. From your own machine run: verify.sh https://$HOST_NAME <token>"
