#!/usr/bin/env bash
# cleanup-orphan-tunnel.sh — OPTIONAL, destructive. Run manually.
# Deletes the unused pain-enjoyer tunnel created 2026-06-11 (everything now
# routes through the homelab tunnel) and removes its credential files.
set -euo pipefail
ORPHAN=b1f987e5-6c2b-4e6f-86ce-48e6ffeaeb53

cloudflared tunnel delete -f "$ORPHAN"
sudo rm -f "/etc/cloudflared/$ORPHAN.json"
rm -f "$HOME/.cloudflared/$ORPHAN.json"
echo "✔ orphan tunnel and credentials removed"
