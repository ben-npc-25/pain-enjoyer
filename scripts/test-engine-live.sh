#!/usr/bin/env bash
# test-engine-live.sh — M2 exit test against the LIVE server:
#   "True VDOT + traffic light computed from real history."
#
# Read-only: unlike test-e2e.sh it pushes NOTHING — the engine computes from
# whatever history is already on the server. No cleanup needed.
#
# Usage:
#   BASE_URL=https://coach.bennpc.uk APP_USER_EMAIL=... APP_USER_PASS=... ./scripts/test-engine-live.sh
#   (or run on the Pi: BASE_URL=http://127.0.0.1:8090 ./scripts/test-engine-live.sh — reads server/.env)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$HERE/../server/.env" ]] && { set -a; source "$HERE/../server/.env"; set +a; }

BASE_URL="${BASE_URL:?set BASE_URL, e.g. https://coach.bennpc.uk}"
APP_USER_EMAIL="${APP_USER_EMAIL:?set APP_USER_EMAIL}"
APP_USER_PASS="${APP_USER_PASS:?set APP_USER_PASS}"

command -v jq >/dev/null || { echo "✗ jq required"; exit 1; }

echo "1/3 health…"
curl -fsS "$BASE_URL/api/coach/health" | jq -c .

echo "2/3 auth…"
TOKEN=$(curl -fsS -X POST "$BASE_URL/api/collections/users/auth-with-password" \
  -H 'content-type: application/json' \
  -d "{\"identity\":\"$APP_USER_EMAIL\",\"password\":\"$APP_USER_PASS\"}" | jq -r .token)
[[ -n "$TOKEN" && "$TOKEN" != "null" ]] || { echo "✗ auth failed"; exit 1; }

echo "3/3 engine state from real history…"
curl -fsS "$BASE_URL/api/coach/engine" -H "Authorization: $TOKEN" > /tmp/engine-live.json

echo
echo "────────────── what the coach sees ──────────────"
jq -r '.for_llm | to_entries[] | "\(.key):\n    \(.value)"' /tmp/engine-live.json
echo "──────────────────────────────────────────────────"
echo

LIGHT=$(jq -r .traffic_light.light /tmp/engine-live.json)
VDOT_OK=$(jq -r .vdot.available /tmp/engine-live.json)
RUNS=$(jq -r .history.runs_180d /tmp/engine-live.json)

[[ "$LIGHT" =~ ^(red|yellow|green)$ ]] || { echo "✗ no traffic light computed"; exit 1; }
if [[ "$VDOT_OK" != "true" ]]; then
  echo "⚠ traffic light = $LIGHT, but VDOT unavailable ($(jq -r .vdot.reason /tmp/engine-live.json))"
  echo "  ($RUNS runs in 180 d on the server — exit test needs at least one ≥3 km effort)"
  exit 1
fi
echo "✔ M2 exit test passed: VDOT $(jq -r .vdot.value /tmp/engine-live.json) + $LIGHT light from $RUNS real runs."
