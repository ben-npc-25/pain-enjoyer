#!/usr/bin/env bash
# deploy-server.sh — the documented deploy ritual as one command:
#   repo server/ → Pi ~/pain-enjoyer/server/ → sudo cp → /opt/pain-enjoyer
#   → systemctl restart → local health probe.
#
# Usage:
#   ./scripts/deploy-server.sh                    # default ben@suisei.local
#   ./scripts/deploy-server.sh ben@192.168.1.236  # when mDNS is being mDNS
#
# Prereq once per Mac: ssh-copy-id <pi-host>

set -euo pipefail

PI="${1:-ben@suisei.local}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."

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

echo "✔ deployed"
