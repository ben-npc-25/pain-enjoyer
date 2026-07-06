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
# ⚠ The clock that matters is the PROFILE's ExpirationDate, not "days since we
# last installed". Xcode reuses a still-valid cached profile on rebuild, so
# re-signing does NOT extend expiry by itself (bit us 2026-07-06: installed
# Jul 3, profile minted Jun 29, app died Jul 6). So this script (a) decides
# due-ness from the embedded profile's real expiry, (b) deletes our cached
# profiles before building to force Xcode to mint a fresh one, and (c) verifies
# the freshly built app's profile actually has ≥3 days left before installing.
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
BUNDLE_ID="com.benng.painenjoyer"
PROFILE_DIRS=("$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
              "$HOME/Library/MobileDevice/Provisioning Profiles")
LOG="$HOME/Library/Logs/pain-enjoyer-refresh.log"
STAMP="$HOME/Library/Logs/.pain-enjoyer-last-resign" # epoch of last success
RESIGN_BUFFER_DAYS=2   # re-sign once the installed profile has < this many days left
ESCALATE_DAYS_LEFT=1   # below this, an unreachable phone is a real alarm
MIN_FRESH_DAYS=3       # a newly minted profile must have at least this much runway

log()    { echo "[$(date '+%F %T')] $1" >> "$LOG"; }
notify() { /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" 2>/dev/null || true; }
fail()   { log "✗ $1"; notify "Pain Enjoyer re-sign FAILED" "$1 — run scripts/refresh-app.sh manually."; exit 1; }

# Epoch of a profile's ExpirationDate; empty on any parse failure.
profile_expiry() {
  local iso
  iso=$(security cms -D -i "$1" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null) || return 0
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null || true
}

FORCE=false; [[ "${1:-}" == "--force" ]] && FORCE=true

# ── is a re-sign due? (cheap path — no device query, no build) ──────────
now=$(date +%s)
expiry=""
[[ -e "$APP/embedded.mobileprovision" ]] && expiry=$(profile_expiry "$APP/embedded.mobileprovision")

if [[ -n "$expiry" ]]; then
  days_left=$(( (expiry - now) / 86400 ))   # floor; 1.9 days → 1
else
  days_left=-1  # no build / unreadable profile → treat as overdue
fi

if ! $FORCE && [[ $days_left -ge $RESIGN_BUFFER_DAYS ]]; then
  # Not due. Stay silent (this fires every ~4 h — don't spam the log).
  exit 0
fi

# ── due: we need the phone reachable + Xcode ────────────────────────────
if ! xcrun devicectl list devices 2>/dev/null | grep -q "$DEVICE_ID"; then
  if [[ $days_left -le $ESCALATE_DAYS_LEFT ]]; then
    fail "iPhone unreachable and the profile expires within ~${ESCALATE_DAYS_LEFT} day(s) — connect NPC (USB/Wi-Fi) + unlock once"
  fi
  log "re-sign due (${days_left}d left on profile) but iPhone unreachable — will retry next heartbeat"
  exit 0
fi

log "re-sign due (${days_left}d left on profile) — rebuilding"

# Force Xcode to mint a FRESH profile: a cached still-valid one would be reused
# as-is and the expiry wouldn't move. Only remove profiles for OUR bundle id.
for dir in "${PROFILE_DIRS[@]}"; do
  [[ -d "$dir" ]] || continue
  for p in "$dir"/*.mobileprovision; do
    [[ -e "$p" ]] || continue
    if security cms -D -i "$p" 2>/dev/null | grep -q "$BUNDLE_ID"; then
      rm -f "$p" && log "dropped cached profile $(basename "$p") to force a fresh mint"
    fi
  done
done

cd "$REPO/ios" || fail "repo missing"
/opt/homebrew/bin/xcodegen >> "$LOG" 2>&1 || xcodegen >> "$LOG" 2>&1 || fail "xcodegen failed"
# Build for a GENERIC device so a locked/asleep phone can't fail the build with
# a "developer disk image could not be mounted" timeout. The signed .app is the
# same; only the install step below needs the phone awake + unlocked.
xcodebuild -project PainEnjoyer.xcodeproj -scheme PainEnjoyer \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build >> "$LOG" 2>&1 \
  || fail "build failed (Xcode may need an interactive Apple ID re-login)"

# Verify the mint actually bought us time before touching the phone.
new_expiry=$(profile_expiry "$APP/embedded.mobileprovision")
[[ -n "$new_expiry" ]] || fail "built app has no readable embedded profile"
new_days_left=$(( (new_expiry - now) / 86400 ))
if [[ $new_days_left -lt $MIN_FRESH_DAYS ]]; then
  fail "fresh build's profile still expires in ${new_days_left}d — Xcode did not mint a new profile (interactive Apple ID re-login likely needed)"
fi

xcrun devicectl device install app --device "$DEVICE_ID" "$APP" >> "$LOG" 2>&1 \
  || fail "install failed — unlock the iPhone (and keep it unlocked) once, then retry"

echo "$now" > "$STAMP"
expiry_date=$(date -j -u -r "$new_expiry" "+%F %H:%M UTC" 2>/dev/null || echo "+${new_days_left}d")
log "✓ re-signed + installed; profile valid until $expiry_date (${new_days_left}d)"
notify "Pain Enjoyer re-signed ✓" "Profile valid until $expiry_date."
