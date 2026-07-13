#!/usr/bin/env bash
# test-m11-local.sh — M11 smoke on a THROWAWAY local PocketBase:
#   ① block continuity — a rebuild preserves completed program weeks (no more
#      "week 1" resets), benchmark lands early for a mature program
#   ② forced benchmark — a benchmark week whose LLM plan came back all-easy
#      still gets its T session deterministically
#   ③ pre-plan check-in — endpoint stores a plan_checkin coach message
#   ④ weather off — planning works with WEATHER_MODE=off (no network needed)
#
# Usage: ./scripts/test-m11-local.sh
# Requires: curl, python3. Reuses the cached pocketbase binary.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."
PB_VERSION="${PB_VERSION:-0.28.4}"
CACHE="$HERE/.cache"
PORT=8097
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

WORK="$(mktemp -d /tmp/pb-m11-test.XXXXXX)"
cleanup() { kill "$PB_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

SU_EMAIL="smoke@test.local"; SU_PASS="smoketest12345"
"$PB_BIN" --dir "$WORK/pb_data" --migrationsDir "$REPO/server/pb_migrations" \
  superuser upsert "$SU_EMAIL" "$SU_PASS" >/dev/null

# Mock weekly plan: deliberately ALL-EASY (no T anywhere) so the forced
# benchmark has something to force. Dates = the CURRENT week (plan-week is
# called with ?start=<this monday>).
CUR_WEEK=($(python3 -c "
import datetime
now = datetime.date.today()
mon = now - datetime.timedelta(days=now.weekday())
print(' '.join(str(mon + datetime.timedelta(days=i)) for i in range(7)))"))
MOCK_WEEKLY='{"rationale":"Easy week while the light is yellow.","days":[
 {"date":"'"${CUR_WEEK[0]}"'","type":"E","distance_km":5,"description":"easy"},
 {"date":"'"${CUR_WEEK[1]}"'","type":"rest","distance_km":0,"description":"off"},
 {"date":"'"${CUR_WEEK[2]}"'","type":"E","distance_km":6,"description":"easy"},
 {"date":"'"${CUR_WEEK[3]}"'","type":"rest","distance_km":0,"description":"off"},
 {"date":"'"${CUR_WEEK[4]}"'","type":"E","distance_km":5,"description":"easy"},
 {"date":"'"${CUR_WEEK[5]}"'","type":"rest","distance_km":0,"description":"off"},
 {"date":"'"${CUR_WEEK[6]}"'","type":"LR","distance_km":12,"description":"long"}]}'

LLM_PROVIDER=mock \
WEATHER_MODE=off \
LLM_MOCK_RESPONSE_WEEKLY="$MOCK_WEEKLY" \
LLM_MOCK_RESPONSE_CHECKIN="Program check-in: how did the body handle this week, and any schedule constraints for next week?" \
"$PB_BIN" serve --dir "$WORK/pb_data" \
  --hooksDir "$REPO/server/pb_hooks" \
  --migrationsDir "$REPO/server/pb_migrations" \
  --http "127.0.0.1:$PORT" >"$WORK/pb.log" 2>&1 &
PB_PID=$!

for i in $(seq 1 50); do
  curl -fsS "$BASE/api/health" >/dev/null 2>&1 && break
  [[ $i == 50 ]] && { echo "✗ pocketbase didn't start"; cat "$WORK/pb.log"; exit 1; }
  sleep 0.2
done
echo "· pocketbase up (pid $PB_PID)"

TOKEN=$(curl -fsS -X POST "$BASE/api/collections/_superusers/auth-with-password" \
  -H 'content-type: application/json' \
  -d "{\"identity\":\"$SU_EMAIL\",\"password\":\"$SU_PASS\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
AUTH=(-H "Authorization: $TOKEN")

post() { curl -fsS -X POST "$BASE/api/collections/$1/records" \
  -H 'content-type: application/json' "${AUTH[@]}" -d "$2" >/dev/null; }
day() { python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=$1)).strftime('%Y-%m-%d'))"; }

# ── seed: race 10 weeks out; VDOT anchor STALE (quality effort 60 d ago);
#    steady recent easy volume so the block has something to build on ────
echo "· seeding athlete (stale VDOT, active retraining)…"
RACE=$(python3 -c "import datetime;print(datetime.date.today()+datetime.timedelta(weeks=10))")
post athlete_profile "{\"race_name\":\"M11 Half\",\"race_date\":\"${RACE}T00:00:00.000Z\",\"days_per_week\":4,\"hr_max\":185}"
post runs "{\"date\":\"$(day 60)T07:30:00.000Z\",\"distance_m\":13120,\"duration_s\":4060,\"avg_hr\":168,\"source_app\":\"m11\",\"healthkit_uuid\":\"m11-quality\"}"
for d in 2 4 6 9 11 13 16 18 20 23 25 27; do
  post runs "{\"date\":\"$(day $d)T07:30:00.000Z\",\"distance_m\":7000,\"duration_s\":2700,\"avg_hr\":135,\"source_app\":\"m11\",\"healthkit_uuid\":\"m11-$d\"}"
done

PASS=0; FAILED=0
check() { local label=$1; shift
  if "$@" >/dev/null 2>&1; then echo "  ✓ $label"; PASS=$((PASS+1));
  else echo "  ✗ $label"; FAILED=$((FAILED+1)); fi }

py() { python3 -c "$1"; }

# ── ① continuity ─────────────────────────────────────────────────────────
echo "· ① block continuity across rebuilds…"
curl -fsS -X POST "$BASE/api/coach/macro-plan" "${AUTH[@]}" > "$WORK/macro1.json"
N1=$(py "import json;print(len(json.load(open('$WORK/macro1.json'))['weeks']))")
check "fresh block generated ($N1 weeks)" [ "$N1" -ge 8 ]

# fake 4 completed program weeks (same race ⇒ history must survive a rebuild).
# 4, not 3: with 3, "this week" is program week 4 = the cadence cutback, and a
# benchmark correctly refuses a cutback week.
for k in 4 3 2 1; do
  MON=$(python3 -c "
import datetime
now = datetime.date.today()
mon = now - datetime.timedelta(days=now.weekday(), weeks=$k)
print(mon)")
  IDX=$(python3 -c "
import datetime
now = datetime.date.today()
mon = now - datetime.timedelta(days=now.weekday(), weeks=$k)
jan1 = datetime.date(mon.year, 1, 1)
print(mon.year * 100 + (mon - jan1).days // 7 + 1)")
  post macro_weeks "{\"week_idx\":$IDX,\"week_start\":\"${MON}T00:00:00.000Z\",\"phase\":\"build\",\"target_km\":20,\"long_run_km\":10,\"quality_sessions\":1}"
done

curl -fsS -X POST "$BASE/api/coach/macro-plan" "${AUTH[@]}" > "$WORK/macro2.json"
curl -fsS "$BASE/api/collections/macro_weeks/records?perPage=200&sort=week_start" "${AUTH[@]}" > "$WORK/rows.json"

check "rebuild summary says 're-anchored at week 5'" \
  bash -c "grep -q 're-anchored at week 5' '$WORK/macro2.json'"
check "4 past program weeks survived the rebuild" python3 - <<EOF
import json, datetime
rows = json.load(open("$WORK/rows.json"))["items"]
mon = (datetime.date.today() - datetime.timedelta(days=datetime.date.today().weekday())).isoformat()
past = [r for r in rows if r["week_start"][:10] < mon]
assert len(past) == 4, past
EOF
check "regenerated future starts this Monday" python3 - <<EOF
import json, datetime
rows = json.load(open("$WORK/rows.json"))["items"]
mon = (datetime.date.today() - datetime.timedelta(days=datetime.date.today().weekday())).isoformat()
future = [r for r in rows if r["week_start"][:10] >= mon]
assert future and future[0]["week_start"][:10] == mon, (mon, future[:1])
EOF
check "stale VDOT ⇒ benchmark scheduled in the FIRST future week (program week 5)" python3 - <<EOF
import json, datetime
rows = json.load(open("$WORK/rows.json"))["items"]
mon = (datetime.date.today() - datetime.timedelta(days=datetime.date.today().weekday())).isoformat()
future = [r for r in rows if r["week_start"][:10] >= mon]
marks = [r["week_start"][:10] for r in future if r["milestone"] == "benchmark"]
assert marks and marks[0] == mon, marks
EOF
check "engine narrates 'block week 5 of'" bash -c \
  "curl -fsS '$BASE/api/coach/engine' -H 'Authorization: $TOKEN' | grep -q 'block week 5 of'"

# ── ② forced benchmark ───────────────────────────────────────────────────
echo "· ② benchmark forced into an all-easy LLM plan…"
MON=${CUR_WEEK[0]}
curl -fsS -X POST "$BASE/api/coach/plan-week?start=$MON" "${AUTH[@]}" > "$WORK/week.json"
curl -fsS "$BASE/api/collections/planned_workouts/records?perPage=50&filter=$(python3 -c "import urllib.parse;print(urllib.parse.quote(\"date >= '$MON 00:00:00.000Z'\"))")" "${AUTH[@]}" > "$WORK/planned.json"
check "a T session exists despite the all-easy mock" python3 - <<EOF
import json
days = json.load(open("$WORK/planned.json"))["items"]
ts = [d for d in days if d["type"] == "T"]
assert ts, [(d["date"][:10], d["type"]) for d in days]
EOF
check "…and it is the 3 km benchmark" python3 - <<EOF
import json
days = json.load(open("$WORK/planned.json"))["items"]
t = [d for d in days if d["type"] == "T"][0]
assert "enchmark" in t["description"] and "3 km" in t["description"], t["description"]
EOF
check "plan rationale/adjustments mention the forced benchmark" \
  bash -c "grep -q 'benchmark' '$WORK/week.json'"

# ── ③ pre-plan check-in ──────────────────────────────────────────────────
echo "· ③ pre-plan check-in…"
check "POST /api/coach/plan-checkin returns the question" \
  bash -c "curl -fsS -X POST '$BASE/api/coach/plan-checkin' -H 'Authorization: $TOKEN' | grep -q 'schedule constraints'"
check "check-in stored as kind checkin_question" bash -c \
  "curl -fsS '$BASE/api/collections/coach_messages/records?perPage=10&sort=-created' -H 'Authorization: $TOKEN' | grep -q 'checkin_question'"

# ── ④ weather off ────────────────────────────────────────────────────────
echo "· ④ WEATHER_MODE=off didn't break planning (implicit in ②③) …"
check "no weather errors in the log" bash -c "! grep -q 'weather fetch failed' '$WORK/pb.log'"

echo
if [[ $FAILED -gt 0 ]]; then echo "✗ $FAILED failed ($PASS passed)"; tail -30 "$WORK/pb.log"; exit 1; fi
echo "✔ all $PASS checks passed"
