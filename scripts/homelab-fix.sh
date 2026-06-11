#!/usr/bin/env bash
# homelab-fix.sh — restore Ben's homelab tunnel AND serve the coach from it.
# One tunnel (the original homelab one), one service, merged ingress.
set -euo pipefail

HOMELAB=490ecdeb-48ad-44bb-a026-5bc24801e471
ORPHAN=b1f987e5-6c2b-4e6f-86ce-48e6ffeaeb53

# homelab credentials (Apr 27 original, preserved in ~/.cloudflared)
sudo cp "$HOME/.cloudflared/$HOMELAB.json" "/etc/cloudflared/$HOMELAB.json"

# merged config: homelab ingress (from ~/.cloudflared/config.yml) + coach
sudo tee /etc/cloudflared/config.yml >/dev/null <<EOF
tunnel: $HOMELAB
credentials-file: /etc/cloudflared/$HOMELAB.json

ingress:
  # ── homelab (restored) ──────────────────────────────
  - hostname: jellyfin.bennpc.uk
    service: http://192.168.1.236:8096
  - hostname: immich.bennpc.uk
    service: http://192.168.1.236:2283
  - hostname: photo.bennpc.uk
    service: http://192.168.1.236:2283
  - hostname: netflix.bennpc.uk
    service: http://192.168.1.236:8096
  - hostname: watchwhat.bennpc.uk
    service: http://192.168.1.236:5055
  # ── pain-enjoyer coach ──────────────────────────────
  - hostname: coach.bennpc.uk
    service: http://127.0.0.1:8090
  - hostname: run.bennpc.uk
    service: http://127.0.0.1:8090
  # catchall — required at end
  - service: http_status:404
EOF

# repoint coach → homelab tunnel (run.bennpc.uk already CNAMEs there)
cloudflared tunnel route dns --overwrite-dns "$HOMELAB" coach.bennpc.uk

sudo systemctl restart cloudflared
sleep 8
echo "cloudflared: $(systemctl is-active cloudflared)"

echo "--- edge verification:"
for h in jellyfin immich photo netflix watchwhat; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$h.bennpc.uk" || echo fail)
  echo "  $h.bennpc.uk → $code"
done
echo "  coach → $(curl -fsS --max-time 10 https://coach.bennpc.uk/api/coach/health || echo FAIL)"
echo "  run   → $(curl -fsS --max-time 10 https://run.bennpc.uk/api/coach/health || echo FAIL)"

echo "✔ done — homelab restored, coach merged."
echo "Optional cleanup (run yourself if you want the orphan tunnel gone):"
echo "  bash pain-enjoyer/scripts/cleanup-orphan-tunnel.sh"
