#!/usr/bin/env bash
# diag.sh — print the raw /api/coach/advise response + recent service logs.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; source "$HERE/../server/.env"; set +a
BASE_URL="${BASE_URL:-http://127.0.0.1:8090}"

TOKEN=$(curl -fsS -X POST "$BASE_URL/api/collections/users/auth-with-password" \
  -H 'content-type: application/json' \
  -d "{\"identity\":\"$APP_USER_EMAIL\",\"password\":\"$APP_USER_PASS\"}" | jq -r .token)

echo "--- advise raw response:"
curl -s -X POST "$BASE_URL/api/coach/advise" -H "Authorization: $TOKEN"
echo
echo "--- last runs record:"
curl -s "$BASE_URL/api/collections/runs/records?perPage=1&sort=-date" -H "Authorization: $TOKEN" | jq .
echo "--- service log tail:"
sudo journalctl -u pain-enjoyer -n 25 --no-pager
