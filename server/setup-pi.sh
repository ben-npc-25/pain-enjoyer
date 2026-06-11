#!/usr/bin/env bash
# setup-pi.sh — install Pain Enjoyer's backend on a Raspberry Pi.
#
#   sudo ./setup-pi.sh           install/update PocketBase + systemd service + users
#   sudo ./setup-pi.sh tunnel    interactive tunnel setup (Tailscale or Cloudflare)
#
# Idempotent: safe to re-run. Requires: curl, unzip, systemd. Reads ./.env.

set -euo pipefail

APP_DIR=/opt/pain-enjoyer
SERVICE=pain-enjoyer
HTTP_ADDR=127.0.0.1:8090
REPO_SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

require_env() {
  if [[ ! -f "$REPO_SERVER_DIR/.env" ]]; then
    echo "✗ $REPO_SERVER_DIR/.env not found — copy .env.example to .env and fill it in first." >&2
    exit 1
  fi
  # shellcheck disable=SC1091
  set -a; source "$REPO_SERVER_DIR/.env"; set +a
  : "${PB_ADMIN_EMAIL:?set PB_ADMIN_EMAIL in .env}"
  : "${PB_ADMIN_PASS:?set PB_ADMIN_PASS in .env}"
  : "${APP_USER_EMAIL:?set APP_USER_EMAIL in .env}"
  : "${APP_USER_PASS:?set APP_USER_PASS in .env}"
}

install_pocketbase() {
  echo "── Installing/updating PocketBase ──────────────────────────────"
  mkdir -p "$APP_DIR"

  # Resolve latest release tag from GitHub (avoids pinning a stale version).
  local tag arch
  tag=$(curl -fsSL https://api.github.com/repos/pocketbase/pocketbase/releases/latest \
        | grep -oP '"tag_name":\s*"\K[^"]+')
  case "$(uname -m)" in
    aarch64|arm64) arch=arm64 ;;
    armv7l)        arch=armv7 ;;
    x86_64)        arch=amd64 ;;
    *) echo "✗ unsupported arch $(uname -m)" >&2; exit 1 ;;
  esac
  echo "   PocketBase ${tag} (linux_${arch})"

  curl -fsSL -o /tmp/pb.zip \
    "https://github.com/pocketbase/pocketbase/releases/download/${tag}/pocketbase_${tag#v}_linux_${arch}.zip"
  unzip -o -q /tmp/pb.zip -d "$APP_DIR" pocketbase
  chmod +x "$APP_DIR/pocketbase"

  # Sync hooks + migrations from the repo (the repo is the source of truth).
  rm -rf "$APP_DIR/pb_hooks" "$APP_DIR/pb_migrations"
  cp -r "$REPO_SERVER_DIR/pb_hooks" "$REPO_SERVER_DIR/pb_migrations" "$APP_DIR/"
  cp "$REPO_SERVER_DIR/.env" "$APP_DIR/.env"
  chmod 600 "$APP_DIR/.env"

  # Superuser for the admin UI (upsert = idempotent).
  "$APP_DIR/pocketbase" superuser upsert \
    "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASS" --dir "$APP_DIR/pb_data" >/dev/null
  echo "   superuser ready: $PB_ADMIN_EMAIL"
}

install_service() {
  echo "── Installing systemd service ──────────────────────────────────"
  cat > /etc/systemd/system/${SERVICE}.service <<EOF
[Unit]
Description=Pain Enjoyer (PocketBase)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=${APP_DIR}/pocketbase serve --http=${HTTP_ADDR} --dir=${APP_DIR}/pb_data
Restart=on-failure
RestartSec=5
# modest hardening
NoNewPrivileges=true
ProtectSystem=full
ReadWritePaths=${APP_DIR}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now ${SERVICE}
  systemctl restart ${SERVICE}
  echo "   service ${SERVICE} running on ${HTTP_ADDR} (local only — use the tunnel for the phone)"
}

create_app_user() {
  echo "── Creating app user (what the iPhone logs in as) ──────────────"
  # Wait for serve to come up, then create the user via the superuser token.
  local token http
  for _ in $(seq 1 20); do
    http=$(curl -s -o /dev/null -w '%{http_code}' "http://${HTTP_ADDR}/api/health" || true)
    [[ "$http" == "200" ]] && break
    sleep 1
  done

  token=$(curl -fsS -X POST "http://${HTTP_ADDR}/api/collections/_superusers/auth-with-password" \
    -H 'content-type: application/json' \
    -d "{\"identity\":\"${PB_ADMIN_EMAIL}\",\"password\":\"${PB_ADMIN_PASS}\"}" \
    | grep -oP '"token":\s*"\K[^"]+')

  http=$(curl -s -o /tmp/pb-user.json -w '%{http_code}' \
    -X POST "http://${HTTP_ADDR}/api/collections/users/records" \
    -H 'content-type: application/json' -H "Authorization: ${token}" \
    -d "{\"email\":\"${APP_USER_EMAIL}\",\"password\":\"${APP_USER_PASS}\",\"passwordConfirm\":\"${APP_USER_PASS}\"}")

  if [[ "$http" == "200" || "$http" == "201" ]]; then
    echo "   app user created: ${APP_USER_EMAIL}"
  elif grep -q "already in use\|validation_not_unique" /tmp/pb-user.json; then
    echo "   app user already exists: ${APP_USER_EMAIL} (ok)"
  else
    echo "✗ could not create app user (HTTP $http): $(cat /tmp/pb-user.json)" >&2
    exit 1
  fi
}

setup_tunnel() {
  cat <<'EOF'
── Tunnel options (pick ONE) ─────────────────────────────────────────

[1] Tailscale Serve — $0, NO domain needed (recommended if you own no domain)
    The iPhone must run the free Tailscale app, signed into the same tailnet.

      curl -fsSL https://tailscale.com/install.sh | sh
      sudo tailscale up                       # log in, join your tailnet
      sudo tailscale serve --bg --https=443 http://127.0.0.1:8090
      tailscale status                        # note this Pi's name
      # → your base URL: https://<pi-name>.<tailnet>.ts.net
      # Enable MagicDNS + HTTPS certs once in the Tailscale admin console.

[2] Cloudflare Tunnel — $0 but REQUIRES a domain you own, added to Cloudflare
    Public URL, no Tailscale app needed on the phone.

      curl -fsSL https://pkg.cloudflare.com/cloudflared/install.sh | sudo bash  # or apt
      cloudflared tunnel login
      cloudflared tunnel create pain-enjoyer
      cloudflared tunnel route dns pain-enjoyer coach.yourdomain.com
      # /etc/cloudflared/config.yml:
      #   tunnel: <tunnel-id>
      #   credentials-file: /root/.cloudflared/<tunnel-id>.json
      #   ingress:
      #     - hostname: coach.yourdomain.com
      #       service: http://127.0.0.1:8090
      #     - service: http_status:404
      sudo cloudflared service install
      # → your base URL: https://coach.yourdomain.com

Verify either one:   curl https://<base-url>/api/coach/health
EOF
}

case "${1:-install}" in
  install)
    require_env
    install_pocketbase
    install_service
    create_app_user
    echo
    echo "✔ Backend up. Admin UI: http://${HTTP_ADDR}/_/"
    echo "  Next: sudo ./setup-pi.sh tunnel"
    ;;
  tunnel) setup_tunnel ;;
  *) echo "usage: $0 [install|tunnel]" >&2; exit 1 ;;
esac
