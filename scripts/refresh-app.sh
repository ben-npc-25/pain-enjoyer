#!/usr/bin/env bash
# refresh-app.sh — keep the app's free-account 7-day provisioning profile alive
# (PLAN.md risk #1, automated).
#
# Loaded as a launchd agent that fires often (at login + every ~4 h the Mac is
# awake — see scripts/com.benng.painenjoyer.refresh.plist). Cheap by design: it
# rebuilds + reinstalls ONLY when a re-sign is actually DUE, so firing
# frequently costs nothing. That's what makes it survive a laptop asleep at any
# fixed time — the old Sun/Wed 21:00 schedule never ran (the Mac was asleep).
#
# Manual run any time:        ./scripts/refresh-app.sh
# Force a re-sign now:        ./scripts/refresh-app.sh --force
#
# Run-time needs: Mac awake + logged in, iPhone on USB or same Wi-Fi, Xcode
# signed into the Apple ID.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE_ID="361EB43E-EF16-5391-8B65-E93BE5FF5E03" # NPC (iPhone 13)
APP="$HOME/Library/Developer/Xcode/DerivedData/PainEnjoyer-fnhyvyrmyteuyjfjnwurwwmyvvui/Build/Products/Debug-iphoneos/PainEnjoyer.app"
LOG="$HOME/Library/Logs/pain-enjoyer-refresh.log"
STAMP="$HOME/Library/Logs/.pain-enjoyer-last-resign" # epoch of last success
RESIGN_EVERY_DAYS=5  # profiles last 7; re-sign once older than this (2-day buffer)
ESCALATE_DAYS=6      # past here, an unreachable phone is a real alarm

log()    { echo "[$(date '+%F %T')] $1" >> "$LOG"; }
notify() { /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" 2>/dev/null || true; }
fail()   { log "✗ $1"; notify "Pain Enjoyer re-sign FAILED" "$1 — run scripts/refresh-app.sh manually."; exit 1; }

FORCE=false; [[ "${1:-}" == "--force" ]] && FORCE=true

# ── is a re-sign due? (cheap path — no device query, no build) ──────────
now=$(date +%s)
last=0; [[ -f "$STAMP" ]] && last=$(cat "$STAMP" 2>/dev/null || echo 0)
age_days=$(( (now - last) / 86400 ))

if ! $FORCE && [[ -e "$APP" && $age_days -lt $RESIGN_EVERY_DAYS ]]; then
  # Not due. Stay silent (this fires every ~4 h — don't spam the log).
  exit 0
fi

# ── due: we need the phone reachable + Xcode ────────────────────────────
if ! xcrun devicectl list devices 2>/dev/null | grep -q "$DEVICE_ID"; then
  if [[ $age_days -ge $ESCALATE_DAYS ]]; then
    fail "iPhone unreachable and the profile expires within ~1 day — connect NPC (USB/Wi-Fi) + unlock once"
  fi
  log "re-sign due (${age_days}d) but iPhone unreachable — will retry next heartbeat"
  exit 0
fi

log "re-sign due (${age_days}d since last success) — rebuilding"

cd "$REPO/ios" || fail "repo missing"
/opt/homebrew/bin/xcodegen >> "$LOG" 2>&1 || xcodegen >> "$LOG" 2>&1 || fail "xcodegen failed"
xcodebuild -project PainEnjoyer.xcodeproj -scheme PainEnjoyer \
  -destination "id=$DEVICE_ID" -allowProvisioningUpdates build >> "$LOG" 2>&1 \
  || fail "build failed (Xcode may need an interactive Apple ID re-login)"

xcrun devicectl device install app --device "$DEVICE_ID" "$APP" >> "$LOG" 2>&1 \
  || fail "install failed (unlock the phone once and retry?)"

echo "$now" > "$STAMP"
log "✓ re-signed + installed; profile good for 7 more days"
notify "Pain Enjoyer re-signed ✓" "Fresh 7-day profile installed on NPC."
