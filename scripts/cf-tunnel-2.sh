#!/usr/bin/env bash
# cf-tunnel-2.sh — after login: create tunnel, config, DNS route, service, verify.
set -euo pipefail

HOST=run.bennpc.uk
NAME=pain-enjoyer
CERT="$HOME/.cloudflared/cert.pem"

echo "waiting for login cert…"
for _ in $(seq 1 90); do [ -f "$CERT" ] && break; sleep 5; done
[ -f "$CERT" ] || { echo "✗ cert.pem never appeared — auth link not completed"; exit 1; }
echo "✓ logged in"

if ! cloudflared tunnel list 2>/dev/null | awk '{print $2}' | grep -qx "$NAME"; then
  cloudflared tunnel create "$NAME"
fi
TID=$(cloudflared tunnel list | awk -v n="$NAME" '$2==n {print $1}')
echo "✓ tunnel id: $TID"

sudo mkdir -p /etc/cloudflared
sudo cp "$HOME/.cloudflared/$TID.json" "/etc/cloudflared/$TID.json"
sudo tee /etc/cloudflared/config.yml >/dev/null <<EOF
tunnel: $TID
credentials-file: /etc/cloudflared/$TID.json
ingress:
  - hostname: $HOST
    service: http://127.0.0.1:8090
  - service: http_status:404
EOF

cloudflared tunnel route dns "$NAME" "$HOST" 2>/dev/null || echo "(dns route already exists)"
sudo cloudflared service install 2>/dev/null || true
sudo systemctl enable --now cloudflared 2>/dev/null || true
sudo systemctl restart cloudflared
sleep 6
echo "cloudflared: $(systemctl is-active cloudflared)"
echo "--- public health check:"
curl -fsS "https://$HOST/api/coach/health"
echo
echo "✔ tunnel live: https://$HOST"
