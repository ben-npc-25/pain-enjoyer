#!/usr/bin/env bash
# cf-tunnel-1.sh — install cloudflared + start interactive login, print the auth URL.
set -euo pipefail

if ! command -v cloudflared >/dev/null; then
  echo "installing cloudflared…"
  curl -fsSL -o /tmp/cf.deb \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb
  sudo dpkg -i /tmp/cf.deb >/dev/null
fi
cloudflared --version

if [ -f "$HOME/.cloudflared/cert.pem" ]; then
  echo "ALREADY_LOGGED_IN"
  exit 0
fi

rm -f /tmp/cf-login.log
nohup cloudflared tunnel login > /tmp/cf-login.log 2>&1 &
sleep 5
echo "AUTH_URL:"
grep -oE 'https://[^[:space:]]+' /tmp/cf-login.log | head -1 || cat /tmp/cf-login.log
