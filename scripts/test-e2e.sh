#!/usr/bin/env bash
# test-e2e.sh — simulated phone. Proves the M0 slice WITHOUT the iOS app:
#   auth → push one fake run → POST /api/coach/advise → print the advice.
#
# Usage:
#   BASE_URL=https://<tunnel-host> APP_USER_EMAIL=... APP_USER_PASS=... ./scripts/test-e2e.sh
#   (or run on the Pi itself with BASE_URL=http://127.0.0.1:8090; reads server/.env if present)
#
# Exit 0 + printed advice = M0 backend exit test passed.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$HERE/../server/.env" ]] && { set -a; source "$HERE/../server/.env"; set +a; }

BASE_URL="${BASE_URL:?set BASE_URL, e.g. https://pi.tailnet.ts.net}"
APP_USER_EMAIL="${APP_USER_EMAIL:?set APP_USER_EMAIL}"
APP_USER_PASS="${APP_USER_PASS:?set APP_USER_PASS}"

command -v jq >/dev/null || { echo "✗ jq required (apt install jq / winget install jqlang.jq)"; exit 1; }

echo "1/4 health check…"
curl -fsS "$BASE_URL/api/coach/health" | jq .

echo "2/4 auth as app user…"
TOKEN=$(curl -fsS -X POST "$BASE_URL/api/collections/users/auth-with-password" \
  -H 'content-type: application/json' \
  -d "{\"identity\":\"$APP_USER_EMAIL\",\"password\":\"$APP_USER_PASS\"}" | jq -r .token)
[[ -n "$TOKEN" && "$TOKEN" != "null" ]] || { echo "✗ auth failed"; exit 1; }

echo "3/4 pushing a fake run (10.02 km easy run, this morning)…"
TODAY=$(date -u +%Y-%m-%dT07:30:00Z)
HTTP=$(curl -s -o /tmp/run.json -w '%{http_code}' -X POST \
  "$BASE_URL/api/collections/runs/records" \
  -H 'content-type: application/json' -H "Authorization: $TOKEN" \
  -d "{
    \"date\": \"$TODAY\",
    \"distance_m\": 10020,
    \"duration_s\": 3480,
    \"avg_hr\": 152,
    \"elevation_gain_m\": 86,
    \"source_app\": \"e2e-test\",
    \"healthkit_uuid\": \"e2e-$(date +%s)\"
  }")
[[ "$HTTP" == "200" || "$HTTP" == "201" ]] || { echo "✗ run create failed ($HTTP): $(cat /tmp/run.json)"; exit 1; }
echo "    run id: $(jq -r .id /tmp/run.json)"

echo "4/4 asking the coach…"
curl -fsS -X POST "$BASE_URL/api/coach/advise" -H "Authorization: $TOKEN" | tee /tmp/advice.json | jq .

echo
echo "──────────────────────────────────────────────────────"
echo "COACH ($(jq -r .provider /tmp/advice.json)) says:"
echo
jq -r .advice /tmp/advice.json
echo
echo "✔ M0 end-to-end slice verified."
