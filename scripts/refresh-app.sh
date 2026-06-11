#!/usr/bin/env bash
# refresh-app.sh — re-sign + reinstall the app on Ben's iPhone before the
# free-account 7-day provisioning profile expires (PLAN.md risk #1, automated).
#
# Runs from launchd twice a week (see scripts/com.benng.painenjoyer.refresh.plist)
# or manually any time:  ./scripts/refresh-app.sh
#
# Requirements at run time: Mac awake + logged in, iPhone on USB or same Wi-Fi
# (network debugging stays paired via Xcode), Xcode signed into the Apple ID.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE_ID="361EB43E-EF16-5391-8B65-E93BE5FF5E03" # NPC (iPhone 13)
APP="$HOME/Library/Developer/Xcode/DerivedData/PainEnjoyer-fnhyvyrmyteuyjfjnwurwwmyvvui/Build/Products/Debug-iphoneos/PainEnjoyer.app"
LOG="$HOME/Library/Logs/pain-enjoyer-refresh.log"

notify() { # notify <title> <message>
  /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" 2>/dev/null || true
}

fail() {
  echo "[$(date '+%F %T')] ✗ $1" >> "$LOG"
  notify "Pain Enjoyer re-sign FAILED" "$1 — run scripts/refresh-app.sh manually before the profile expires."
  exit 1
}

echo "[$(date '+%F %T')] re-sign starting" >> "$LOG"

# 1. phone reachable?
xcrun devicectl list devices 2>/dev/null | grep -q "$DEVICE_ID" \
  || fail "iPhone not reachable (USB/Wi-Fi)"

# 2. regenerate project (cheap, deterministic) + build with a fresh profile
cd "$REPO/ios" || fail "repo missing"
/opt/homebrew/bin/xcodegen >> "$LOG" 2>&1 || xcodegen >> "$LOG" 2>&1 || fail "xcodegen failed"
xcodebuild -project PainEnjoyer.xcodeproj -scheme PainEnjoyer \
  -destination "id=$DEVICE_ID" -allowProvisioningUpdates build >> "$LOG" 2>&1 \
  || fail "build failed (Xcode may need an interactive Apple ID re-login)"

# 3. install (works while the phone is locked)
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" >> "$LOG" 2>&1 \
  || fail "install failed (unlock the phone once and retry?)"

echo "[$(date '+%F %T')] ✓ re-signed + installed; profile good for 7 more days" >> "$LOG"
notify "Pain Enjoyer re-signed ✓" "Fresh 7-day profile installed on NPC."
