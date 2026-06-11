#!/usr/bin/env bash
# check-status.sh — service bind + recent runs summary (no secrets printed).
set -uo pipefail
echo "--- bind:"
systemctl cat pain-enjoyer | grep ExecStart
set -a; source /home/ben/pain-enjoyer/server/.env; set +a
TOKEN=$(curl -fsS -X POST http://127.0.0.1:8090/api/collections/users/auth-with-password \
  -H 'content-type: application/json' \
  -d "{\"identity\":\"$APP_USER_EMAIL\",\"password\":\"$APP_USER_PASS\"}" | jq -r .token)
echo "--- runs (latest 5):"
curl -fsS "http://127.0.0.1:8090/api/collections/runs/records?perPage=5&sort=-created" \
  -H "Authorization: $TOKEN" \
  | jq -r '.items[] | "\(.date)  \(.distance_m)m  src=\(.source_app)"'
echo "--- coach messages: $(curl -fsS "http://127.0.0.1:8090/api/collections/coach_messages/records?perPage=1" -H "Authorization: $TOKEN" | jq -r .totalItems)"
