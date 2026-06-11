#!/usr/bin/env bash
# cleanup-test-data.sh — remove e2e fake runs so the calendar starts clean.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; source "$HERE/../server/.env"; set +a
BASE_URL="${BASE_URL:-http://127.0.0.1:8090}"

TOKEN=$(curl -fsS -X POST "$BASE_URL/api/collections/users/auth-with-password" \
  -H 'content-type: application/json' \
  -d "{\"identity\":\"$APP_USER_EMAIL\",\"password\":\"$APP_USER_PASS\"}" | jq -r .token)

IDS=$(curl -fsS "$BASE_URL/api/collections/runs/records?perPage=200&filter=(source_app='e2e-test')" \
  -H "Authorization: $TOKEN" | jq -r '.items[].id')

for id in $IDS; do
  curl -fsS -X DELETE "$BASE_URL/api/collections/runs/records/$id" -H "Authorization: $TOKEN"
  echo "deleted run $id"
done
echo "✔ test runs removed"
