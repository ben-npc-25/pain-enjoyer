#!/usr/bin/env bash
# homelab-diag.sh — read-only: confirm what broke the homelab tunnel.
set -uo pipefail

echo "--- current /etc/cloudflared/config.yml:"
sudo cat /etc/cloudflared/config.yml 2>/dev/null || echo "(missing)"

echo "--- ~/.cloudflared contents:"
ls -la "$HOME/.cloudflared/"

echo "--- cloudflared-ish services:"
systemctl list-units --all --no-pager | grep -i cloudflared || echo "(only default)"
systemctl is-active cloudflared

echo "--- docker containers (if any):"
command -v docker >/dev/null && docker ps --format '{{.Names}} {{.Image}} {{.Status}}' 2>/dev/null | head -10 || echo "(no docker)"

echo "--- origin services on this host:"
for p in "jellyfin 8096" "immich 2283" "watchwhat 5055"; do
  name=${p% *}; port=${p#* }
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://192.168.1.236:$port" || echo "no-conn")
  echo "  $name (:$port) → $code"
done

echo "--- edge view:"
for h in jellyfin immich photo watchwhat coach; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://$h.bennpc.uk" || echo "fail")
  echo "  $h.bennpc.uk → $code"
done
