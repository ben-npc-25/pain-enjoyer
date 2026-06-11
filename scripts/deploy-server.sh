#!/usr/bin/env bash
# deploy-server.sh — the documented deploy ritual as one command.
#
# Two modes, auto-detected:
#   on the Mac:  syncs repo → Pi ~/pain-enjoyer → /opt/pain-enjoyer → restart
#   on the Pi:   (detected via /opt/pain-enjoyer) skips scp, installs straight
#                from the local repo checkout → /opt → restart
#
# Usage:
#   ./scripts/deploy-server.sh                    # Mac, default ben@suisei.local
#   ./scripts/deploy-server.sh ben@192.168.1.236  # Mac, when mDNS is being mDNS
#   ./scripts/deploy-server.sh                    # on the Pi (after git pull)
#
# Prereq for Mac mode, once per Mac: your key in the Pi's authorized_keys
# (sshd is publickey-only — ssh-copy-id can't bootstrap; paste the key from an
# existing Pi session instead).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."

wait_for_health() {
  for i in $(seq 1 20); do
    curl -fsS http://127.0.0.1:8090/api/coach/health >/dev/null 2>&1 && break
    [ "$i" = 20 ] && { echo "✗ service did not come back"; sudo journalctl -u pain-enjoyer -n 20 --no-pager; exit 1; }
    sleep 0.5
  done
  echo "  service healthy: $(curl -fsS http://127.0.0.1:8090/api/coach/health)"
}

if [[ -d /opt/pain-enjoyer ]]; then
  # ── local mode: we ARE the Pi ─────────────────────────────────────────
  echo "· Pi detected — installing from $REPO/server → /opt/pain-enjoyer"
  sudo cp "$REPO/server/pb_hooks/"*.js /opt/pain-enjoyer/pb_hooks/
  sudo mkdir -p /opt/pain-enjoyer/pb_migrations
  sudo cp "$REPO/server/pb_migrations/"*.js /opt/pain-enjoyer/pb_migrations/
  sudo systemctl restart pain-enjoyer
  wait_for_health
else
  # ── remote mode: Mac → Pi ─────────────────────────────────────────────
  PI="${1:-ben@suisei.local}"
  echo "· syncing pb_hooks + pb_migrations → $PI:pain-enjoyer/server/"
  scp -q "$REPO/server/pb_hooks/"*.js "$PI:pain-enjoyer/server/pb_hooks/"
  scp -q "$REPO/server/pb_migrations/"*.js "$PI:pain-enjoyer/server/pb_migrations/"

  echo "· installing into /opt/pain-enjoyer + restart…"
  ssh "$PI" 'set -e
    sudo cp ~/pain-enjoyer/server/pb_hooks/*.js /opt/pain-enjoyer/pb_hooks/
    sudo mkdir -p /opt/pain-enjoyer/pb_migrations
    sudo cp ~/pain-enjoyer/server/pb_migrations/*.js /opt/pain-enjoyer/pb_migrations/
    sudo systemctl restart pain-enjoyer
    for i in $(seq 1 20); do
      curl -fsS http://127.0.0.1:8090/api/coach/health >/dev/null 2>&1 && break
      [ "$i" = 20 ] && { echo "✗ service did not come back"; sudo journalctl -u pain-enjoyer -n 20 --no-pager; exit 1; }
      sleep 0.5
    done
    echo "  service healthy: $(curl -fsS http://127.0.0.1:8090/api/coach/health)"'
fi

echo "✔ deployed"
