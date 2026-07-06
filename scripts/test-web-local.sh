#!/usr/bin/env bash
# test-web-local.sh — smoke the web planner on a THROWAWAY local PocketBase.
# Verifies what the browser would do: static files served from the public dir,
# login via the users collection, and every API call web/app.js makes.
#
# Usage: ./scripts/test-web-local.sh          # run asserts and exit
#        ./scripts/test-web-local.sh --serve  # keep it running for manual poking
# Requires: curl, python3. Reuses the pocketbase binary cached by
# test-engine-local.sh (downloads on first run).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."
PB_VERSION="${PB_VERSION:-0.28.4}"
CACHE="$HERE/.cache"
PORT=8098
BASE="http://127.0.0.1:$PORT"

case "$(uname -sm)" in
  "Darwin arm64") PB_ARCH="darwin_arm64" ;;
  "Darwin x86_64") PB_ARCH="darwin_amd64" ;;
  "Linux aarch64") PB_ARCH="linux_arm64" ;;
  "Linux x86_64") PB_ARCH="linux_amd64" ;;
  *) echo "✗ unsupported platform: $(uname -sm)"; exit 1 ;;
esac
PB_BIN="$CACHE/pocketbase-$PB_VERSION"
if [[ ! -x "$PB_BIN" ]]; then
  echo "· downloading pocketbase $PB_VERSION ($PB_ARCH)…"
  mkdir -p "$CACHE"
  curl -fsSL -o "$CACHE/pb.zip" \
    "https://github.com/pocketbase/pocketbase/releases/download/v$PB_VERSION/pocketbase_${PB_VERSION}_${PB_ARCH}.zip"
  (cd "$CACHE" && unzip -oq pb.zip pocketbase && mv pocketbase "pocketbase-$PB_VERSION" && rm pb.zip)
fi

WORK="$(mktemp -d /tmp/pb-web-test.XXXXXX)"
cleanup() { kill "$PB_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

SU_EMAIL="smoke@test.local"; SU_PASS="smoketest12345"
"$PB_BIN" --dir "$WORK/pb_data" --migrationsDir "$REPO/server/pb_migrations" \
  superuser upsert "$SU_EMAIL" "$SU_PASS" >/dev/null

LLM_PROVIDER=mock \
LLM_MOCK_RESPONSE_DAILY="Canned coach reply for the web smoke." \
LLM_MOCK_RESPONSE_TRENDS='{"volume":"Mock volume read.","hrv":"Mock HRV read.","resting_hr":"Mock RHR.","vo2max_health":"Mock VO2.","weight":"Mock weight.","fitness":"Mock fitness."}' \
"$PB_BIN" serve --dir "$WORK/pb_data" \
  --hooksDir "$REPO/server/pb_hooks" \
  --migrationsDir "$REPO/server/pb_migrations" \
  --publicDir "$REPO/web" \
  --http "127.0.0.1:$PORT" >"$WORK/pb.log" 2>&1 &
PB_PID=$!

for i in $(seq 1 50); do
  curl -fsS "$BASE/api/health" >/dev/null 2>&1 && break
  [[ $i == 50 ]] && { echo "✗ pocketbase didn't start"; cat "$WORK/pb.log"; exit 1; }
  sleep 0.2
done
echo "· pocketbase up (pid $PB_PID)"

SU_TOKEN=$(curl -fsS -X POST "$BASE/api/collections/_superusers/auth-with-password" \
  -H 'content-type: application/json' \
  -d "{\"identity\":\"$SU_EMAIL\",\"password\":\"$SU_PASS\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

post_su() {
  curl -fsS -X POST "$BASE/api/collections/$1/records" \
    -H 'content-type: application/json' -H "Authorization: $SU_TOKEN" -d "$2" >/dev/null
}

# ── seed: app user (what the web login uses) + a bit of history ─────────
APP_EMAIL="ben@test.local"; APP_PASS="webtest12345"
post_su users "{\"email\":\"$APP_EMAIL\",\"password\":\"$APP_PASS\",\"passwordConfirm\":\"$APP_PASS\"}"

day() { python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=$1)).strftime('%Y-%m-%d'))"; }
post_su athlete_profile "{\"race_name\":\"Web Smoke Half\",\"race_date\":\"$(python3 -c "import datetime;print((datetime.date.today()+datetime.timedelta(days=90)))")T00:00:00.000Z\",\"days_per_week\":4,\"hr_max\":185}"
for d in 2 4 6 9 11 13; do
  post_su runs "{\"date\":\"$(day $d)T07:30:00.000Z\",\"distance_m\":8000,\"duration_s\":2880,\"avg_hr\":150,\"source_app\":\"web-smoke\",\"healthkit_uuid\":\"web-$d\"}"
done
for d in 0 1 2 3; do
  post_su recovery_daily "{\"date\":\"$(day $d)T00:00:00.000Z\",\"hrv_sdnn_ms\":60,\"resting_hr\":50,\"sleep_hours\":7.5,\"body_mass_kg\":70}"
done

# ── asserts ─────────────────────────────────────────────────────────────
PASS=0; FAILED=0
check() { # check <label> <cmd…>
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then echo "  ✓ $label"; PASS=$((PASS+1));
  else echo "  ✗ $label"; FAILED=$((FAILED+1)); fi
}

echo "· static files (the pb_public role)…"
check "GET / serves index.html"    bash -c "curl -fsS $BASE/ | grep -q 'Pain Enjoyer'"
check "GET /app.js"                bash -c "curl -fsS $BASE/app.js | grep -q 'loadProgram'"
check "GET /api.js"                bash -c "curl -fsS $BASE/api.js | grep -q 'auth-with-password'"
check "GET /style.css"             bash -c "curl -fsS $BASE/style.css | grep -q 'wordmark'"

echo "· login as the app user (what the web form does)…"
TOKEN=$(curl -fsS -X POST "$BASE/api/collections/users/auth-with-password" \
  -H 'content-type: application/json' \
  -d "{\"identity\":\"$APP_EMAIL\",\"password\":\"$APP_PASS\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
[[ -n "$TOKEN" ]] && { echo "  ✓ users auth-with-password"; PASS=$((PASS+1)); } || { echo "  ✗ users auth"; FAILED=$((FAILED+1)); }

AUTH=(-H "Authorization: $TOKEN")
echo "· every call web/app.js makes…"
check "POST /api/coach/ping"           curl -fsS -X POST "$BASE/api/coach/ping" "${AUTH[@]}"
check "GET  /api/coach/engine"         curl -fsS "$BASE/api/coach/engine" "${AUTH[@]}"
check "GET  runs"                      bash -c "curl -fsS '$BASE/api/collections/runs/records?perPage=500&sort=-date' -H 'Authorization: $TOKEN' | grep -q web-smoke"
check "GET  planned_workouts"          curl -fsS "$BASE/api/collections/planned_workouts/records?perPage=500" "${AUTH[@]}"
check "GET  macro_weeks"               curl -fsS "$BASE/api/collections/macro_weeks/records?perPage=200" "${AUTH[@]}"
check "GET  coach_messages"            curl -fsS "$BASE/api/collections/coach_messages/records?perPage=50" "${AUTH[@]}"
check "GET  recovery_daily"            bash -c "curl -fsS '$BASE/api/collections/recovery_daily/records?perPage=400' -H 'Authorization: $TOKEN' | grep -q body_mass_kg"
check "GET  athlete_profile"           bash -c "curl -fsS '$BASE/api/collections/athlete_profile/records?perPage=1' -H 'Authorization: $TOKEN' | grep -q 'Web Smoke Half'"
check "POST /api/coach/macro-plan"     curl -fsS -X POST "$BASE/api/coach/macro-plan" "${AUTH[@]}"
check "macro_weeks populated after build" bash -c "curl -fsS '$BASE/api/collections/macro_weeks/records?perPage=200' -H 'Authorization: $TOKEN' | python3 -c 'import sys,json; assert json.load(sys.stdin)[\"totalItems\"] > 0'"
check "POST /api/coach/chat"           curl -fsS -X POST "$BASE/api/coach/chat" "${AUTH[@]}" -H 'content-type: application/json' -d '{"message":"web smoke hello"}'
check "POST /api/coach/advise"         curl -fsS -X POST "$BASE/api/coach/advise" "${AUTH[@]}"
check "POST /api/coach/trends-review"  curl -fsS -X POST "$BASE/api/coach/trends-review" "${AUTH[@]}"
RUN_ID=$(curl -fsS "$BASE/api/collections/runs/records?perPage=1&sort=-date" "${AUTH[@]}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["items"][0]["id"])')
check "PATCH run notes"                curl -fsS -X PATCH "$BASE/api/collections/runs/records/$RUN_ID" "${AUTH[@]}" -H 'content-type: application/json' -d '{"notes":"felt fine (web)"}'
check "PATCH run effort"               curl -fsS -X PATCH "$BASE/api/collections/runs/records/$RUN_ID" "${AUTH[@]}" -H 'content-type: application/json' -d '{"effort":3}'
PROF_ID=$(curl -fsS "$BASE/api/collections/athlete_profile/records?perPage=1" "${AUTH[@]}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["items"][0]["id"])')
check "PATCH athlete_profile"          curl -fsS -X PATCH "$BASE/api/collections/athlete_profile/records/$PROF_ID" "${AUTH[@]}" -H 'content-type: application/json' -d '{"weekly_target_km":40}'
check "unauth engine is rejected"      bash -c "! curl -fsS '$BASE/api/coach/engine' >/dev/null 2>&1"

echo
if [[ $FAILED -gt 0 ]]; then echo "✗ $FAILED failed ($PASS passed)"; exit 1; fi
echo "✔ all $PASS checks passed"

if [[ "${1:-}" == "--serve" ]]; then
  echo
  echo "Serving at $BASE — login: $APP_EMAIL / $APP_PASS  (ctrl-c to stop)"
  wait "$PB_PID"
fi
