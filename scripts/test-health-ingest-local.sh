#!/usr/bin/env bash
# test-health-ingest-local.sh — M12 smoke on a THROWAWAY local PocketBase:
#   ① auth — no token / wrong token / unset server token are all refused
#   ② workouts → runs: km→m, duration from start−end, avg+max HR, elevation,
#      activity_type mapping, zero-distance sessions skipped (schema requires
#      non-zero), in-batch and cross-post dedupe on healthkit_uuid
#   ③ metrics → recovery_daily: HRV mean, RHR, VO₂max, lb→kg weight, and
#      sleep attributed to the WAKE day (matches HealthKitService.swift)
#   ④ partial re-post upserts without nulling fields it didn't carry
#   ⑤ the FREE Shortcuts path: flat daily row, flat workout, and the
#      same data as URL PARAMS ONLY (no request body to configure)
#   ⑥ the engine still reads a database fed this way
#   ⑦ the web app is installable (manifest + icons + apple meta tags)
#
# Usage: ./scripts/test-health-ingest-local.sh
# Requires: curl, python3. Reuses the cached pocketbase binary.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."
PB_VERSION="${PB_VERSION:-0.28.4}"
CACHE="$HERE/.cache"
PORT=8096
BASE="http://127.0.0.1:$PORT"
TOKEN_GOOD="m12-ingest-token-0123456789abcdef"

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

WORK="$(mktemp -d /tmp/pb-m12-test.XXXXXX)"
cleanup() { kill "$PB_PID" 2>/dev/null || true; kill "$PB_PID_NOTOKEN" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

SU_EMAIL="smoke@test.local"; SU_PASS="smoketest12345"
"$PB_BIN" --dir "$WORK/pb_data" --migrationsDir "$REPO/server/pb_migrations" \
  superuser upsert "$SU_EMAIL" "$SU_PASS" >/dev/null

LLM_PROVIDER=mock WEATHER_MODE=off \
HEALTH_INGEST_TOKEN="$TOKEN_GOOD" \
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

PASS=0; FAILED=0
check() { local label=$1; shift
  if "$@" >/dev/null 2>&1; then echo "  ✓ $label"; PASS=$((PASS+1));
  else echo "  ✗ $label"; FAILED=$((FAILED+1)); fi }
py() { python3 -c "$1"; }

# Local-time day labels with a real offset, exactly as the exporter sends them
# (+0800 = Ben's zone). D0 = today, D1 = yesterday, …
day() { python3 -c "import datetime;print((datetime.date.today()-datetime.timedelta(days=$1)).isoformat())"; }
D1=$(day 1); D2=$(day 2); D3=$(day 3)
# URL-encoded stamp for the query-param test (a space would break the URL)
D4T="$(day 4)T06%3A00%3A00%2B08%3A00"

# ── the payload: shaped like Health Auto Export's REST export ─────────────
cat > "$WORK/payload.json" <<JSON
{"data":{
  "workouts":[
    {"id":"HK-RUN-0001","name":"Outdoor Running",
     "start":"$D2 07:00:00 +0800","end":"$D2 07:50:00 +0800",
     "distance":{"qty":10.2,"units":"km"},
     "elevationUp":{"qty":86,"units":"m"},
     "heartRateData":[{"date":"$D2 07:10:00 +0800","Min":121,"Avg":150,"Max":163},
                      {"date":"$D2 07:40:00 +0800","Min":140,"Avg":160,"Max":178}],
     "source":"Runkeeper"},
    {"id":"HK-RUN-0001","name":"Outdoor Running",
     "start":"$D2 07:00:00 +0800","end":"$D2 07:50:00 +0800",
     "distance":{"qty":10.2,"units":"km"},"source":"Runkeeper"},
    {"id":"HK-HIKE-0002","name":"Hiking",
     "start":"$D3 09:00:00 +0800","end":"$D3 11:30:00 +0800",
     "distance":{"qty":7.5,"units":"km"},"source":"Apple Watch"},
    {"id":"HK-STR-0003","name":"Functional Strength Training",
     "start":"$D3 18:00:00 +0800","end":"$D3 18:45:00 +0800",
     "source":"Apple Watch"}
  ],
  "metrics":[
    {"name":"heart_rate_variability","units":"ms","data":[
      {"date":"$D1 03:00:00 +0800","qty":40},
      {"date":"$D1 05:00:00 +0800","qty":50}]},
    {"name":"resting_heart_rate","units":"bpm","data":[
      {"date":"$D1 08:00:00 +0800","qty":48}]},
    {"name":"vo2_max","units":"mL/min·kg","data":[
      {"date":"$D1 08:00:00 +0800","qty":51.4}]},
    {"name":"weight_body_mass","units":"lb","data":[
      {"date":"$D1 07:30:00 +0800","qty":154.324}]},
    {"name":"sleep_analysis","units":"hr","data":[
      {"date":"$D2 23:10:00 +0800","sleepEnd":"$D1 07:00:00 +0800",
       "inBed":8.0,"awake":0.4,"deep":1.2,"core":4.3,"rem":1.5}]},
    {"name":"step_count","units":"count","data":[
      {"date":"$D1 12:00:00 +0800","qty":8400}]}
  ]}}
JSON

ingest() { # $1 = auth style, $2 = file
  case "$1" in
    good) curl -sS -o "$WORK/resp.json" -w '%{http_code}' -X POST "$BASE/api/health/ingest" \
            -H 'content-type: application/json' -H "X-Ingest-Token: $TOKEN_GOOD" --data-binary "@$2" ;;
    query) curl -sS -o "$WORK/resp.json" -w '%{http_code}' -X POST "$BASE/api/health/ingest?token=$TOKEN_GOOD" \
            -H 'content-type: application/json' --data-binary "@$2" ;;
    bearer) curl -sS -o "$WORK/resp.json" -w '%{http_code}' -X POST "$BASE/api/health/ingest" \
            -H 'content-type: application/json' -H "Authorization: Bearer $TOKEN_GOOD" --data-binary "@$2" ;;
    wrong) curl -sS -o "$WORK/resp.json" -w '%{http_code}' -X POST "$BASE/api/health/ingest" \
            -H 'content-type: application/json' -H "X-Ingest-Token: nope-nope-nope-nope-nope" --data-binary "@$2" ;;
    none) curl -sS -o "$WORK/resp.json" -w '%{http_code}' -X POST "$BASE/api/health/ingest" \
            -H 'content-type: application/json' --data-binary "@$2" ;;
  esac
}

# ── ① auth ───────────────────────────────────────────────────────────────
echo "· ① auth on POST /api/health/ingest…"
check "no token → 401"    [ "$(ingest none  "$WORK/payload.json")" = 401 ]
check "wrong token → 401" [ "$(ingest wrong "$WORK/payload.json")" = 401 ]
check "nothing was written by a rejected post" bash -c \
  "curl -fsS '$BASE/api/collections/runs/records?perPage=1' -H 'Authorization: $TOKEN' | grep -q '\"totalItems\":0'"

# ── ② workouts → runs ────────────────────────────────────────────────────
echo "· ② workouts → runs…"
CODE=$(ingest good "$WORK/payload.json")
check "valid token → 200" [ "$CODE" = 200 ]
cat "$WORK/resp.json" | python3 -c '
import sys, json
r = json.load(sys.stdin)
assert r["runs_created"] == 2, r          # run + hike
assert r["runs_duplicate"] == 1, r        # the repeated id inside one batch
assert r["runs_unusable"] == 1, r         # strength: no distance
' && { echo "  ✓ report: 2 created, 1 in-batch duplicate, 1 unusable"; PASS=$((PASS+1)); } \
  || { echo "  ✗ report counts wrong: $(cat "$WORK/resp.json")"; FAILED=$((FAILED+1)); }

curl -fsS "$BASE/api/collections/runs/records?perPage=50&sort=-date" "${AUTH[@]}" > "$WORK/runs.json"
python3 <<EOF > "$WORK/runcheck.txt" 2>&1
import json
rows = json.load(open("$WORK/runs.json"))["items"]
by = {r["healthkit_uuid"]: r for r in rows}
assert len(rows) == 2, rows
r = by["HK-RUN-0001"]
assert r["distance_m"] == 10200, r["distance_m"]          # km → m
assert r["duration_s"] == 3000, r["duration_s"]           # end − start, not the duration field
assert r["avg_hr"] == 155, r["avg_hr"]                    # mean of bucket Avgs
assert r["max_hr"] == 178, r["max_hr"]                    # peak of bucket Maxes
assert r["elevation_gain_m"] == 86, r["elevation_gain_m"]
assert r["activity_type"] == "running", r["activity_type"]
assert r["source_app"] == "Runkeeper", r["source_app"]
h = by["HK-HIKE-0002"]
assert h["activity_type"] == "hiking", h["activity_type"]
assert h["distance_m"] == 7500 and h["duration_s"] == 9000, h
print("ok")
EOF
check "run mapped exactly (10200 m / 3000 s / HR 155-178 / +86 m / running)" \
  bash -c "grep -q '^ok$' '$WORK/runcheck.txt'"
check "hike mapped with activity_type=hiking" bash -c "grep -q '^ok$' '$WORK/runcheck.txt'"

echo "· ② dedupe across posts…"
ingest query "$WORK/payload.json" >/dev/null
# 3 duplicates: the run is in the payload twice, plus the hike (query-param
# auth path exercised here).
check "re-post created nothing new" bash -c \
  "python3 -c \"import json;r=json.load(open('$WORK/resp.json'));assert r['runs_created']==0 and r['runs_duplicate']==3, r\""
check "still exactly 2 runs" bash -c \
  "curl -fsS '$BASE/api/collections/runs/records?perPage=1' -H 'Authorization: $TOKEN' | grep -q '\"totalItems\":2'"

# ── ③ metrics → recovery_daily ───────────────────────────────────────────
echo "· ③ metrics → recovery_daily…"
curl -fsS "$BASE/api/collections/recovery_daily/records?perPage=50&sort=-date" "${AUTH[@]}" > "$WORK/rec.json"
python3 <<EOF > "$WORK/reccheck.txt" 2>&1
import json
rows = json.load(open("$WORK/rec.json"))["items"]
by = {r["date"][:10]: r for r in rows}
assert "$D1" in by, ("wake day missing", sorted(by))
d = by["$D1"]
assert d["hrv_sdnn_ms"] == 45, d["hrv_sdnn_ms"]        # mean of 40 and 50
assert d["resting_hr"] == 48, d["resting_hr"]
assert d["vo2max"] == 51.4, d["vo2max"]
assert d["body_mass_kg"] == 70.0, d["body_mass_kg"]    # 154.324 lb → 70.0 kg
assert d["sleep_hours"] == 7.0, d["sleep_hours"]       # deep+core+rem, NOT inBed
# the night STARTED on $D2 but must be filed under the wake day $D1
assert "$D2" not in by or not by["$D2"].get("sleep_hours"), by.get("$D2")
print("ok")
EOF
check "HRV mean / RHR / VO₂max / lb→kg weight all correct" \
  bash -c "grep -q '^ok$' '$WORK/reccheck.txt'"
check "sleep = asleep stages (7.0 h, not 8.0 inBed), filed on the WAKE day" \
  bash -c "grep -q '^ok$' '$WORK/reccheck.txt'"
check "unmapped metrics reported, not silently dropped" bash -c \
  "grep -q 'step_count' '$WORK/resp.json'"

# ── ④ partial re-post must not null existing fields ──────────────────────
echo "· ④ partial upsert…"
cat > "$WORK/partial.json" <<JSON
{"data":{"metrics":[
  {"name":"weight_body_mass","units":"kg","data":[{"date":"$D1 07:30:00 +0800","qty":69.4}]}]}}
JSON
ingest bearer "$WORK/partial.json" >/dev/null
curl -fsS "$BASE/api/collections/recovery_daily/records?perPage=50&sort=-date" "${AUTH[@]}" > "$WORK/rec2.json"
python3 <<EOF > "$WORK/upsert.txt" 2>&1
import json
by = {r["date"][:10]: r for r in json.load(open("$WORK/rec2.json"))["items"]}
d = by["$D1"]
assert d["body_mass_kg"] == 69.4, d["body_mass_kg"]   # updated
assert d["hrv_sdnn_ms"] == 45, d["hrv_sdnn_ms"]       # NOT nulled
assert d["sleep_hours"] == 7.0, d["sleep_hours"]      # NOT nulled
print("ok")
EOF
check "weight updated, HRV/sleep preserved (Bearer auth path works)" \
  bash -c "grep -q '^ok$' '$WORK/upsert.txt'"
check "row was updated, not duplicated" bash -c \
  "python3 -c \"import json;r=json.load(open('$WORK/resp.json'));assert r['recovery_updated']==1 and r['recovery_created']==0, r\""

# ── ⑤ the free Shortcuts path: flat shapes ───────────────────────────────
echo "· ⑤ flat Shortcuts payloads (no paid exporter)…"

# ⑤a one flat daily row — what a Shortcut builds with a single Dictionary
cat > "$WORK/flat-day.json" <<JSON
{"date":"$D3","hrv":52.5,"rhr":46,"sleep":7.8,"vo2max":52.1,"weight":69.9}
JSON
ingest good "$WORK/flat-day.json" >/dev/null
curl -fsS "$BASE/api/collections/recovery_daily/records?perPage=50&sort=-date" "${AUTH[@]}" > "$WORK/rec3.json"
python3 <<EOF > "$WORK/flatday.txt" 2>&1
import json
by = {r["date"][:10]: r for r in json.load(open("$WORK/rec3.json"))["items"]}
d = by["$D3"]
assert d["hrv_sdnn_ms"] == 52.5, d
assert d["resting_hr"] == 46 and d["sleep_hours"] == 7.8, d
assert d["vo2max"] == 52.1 and d["body_mass_kg"] == 69.9, d
print("ok")
EOF
check "flat {date,hrv,rhr,sleep,vo2max,weight} → one recovery row" \
  bash -c "grep -q '^ok\$' '$WORK/flatday.txt'"

# ⑤b one flat workout — what a Shortcut posts per iteration of a Repeat loop
cat > "$WORK/flat-run.json" <<JSON
{"workout":{"id":"SC-RUN-9001","activity":"Running","start":"$D1 06:30:00 +0800",
 "duration_s":2400,"distance_m":8000,"avg_hr":146,"max_hr":171,"elevation_gain_m":42}}
JSON
ingest good "$WORK/flat-run.json" >/dev/null
check "flat workout reported as created" bash -c \
  "python3 -c \"import json;r=json.load(open('$WORK/resp.json'));assert r['runs_created']==1, r\""
curl -fsS "$BASE/api/collections/runs/records?perPage=50&sort=-date" "${AUTH[@]}" > "$WORK/runs2.json"
python3 <<EOF > "$WORK/flatrun.txt" 2>&1
import json
by = {r["healthkit_uuid"]: r for r in json.load(open("$WORK/runs2.json"))["items"]}
r = by["SC-RUN-9001"]
assert r["distance_m"] == 8000, r["distance_m"]     # already metres — no conversion
assert r["duration_s"] == 2400, r["duration_s"]     # already seconds
assert r["avg_hr"] == 146 and r["max_hr"] == 171, r
assert r["elevation_gain_m"] == 42, r["elevation_gain_m"]
assert r["activity_type"] == "running", r["activity_type"]
print("ok")
EOF
check "flat workout mapped without unit conversion" \
  bash -c "grep -q '^ok\$' '$WORK/flatrun.txt'"
ingest good "$WORK/flat-run.json" >/dev/null
check "flat workout dedupes on re-post" bash -c \
  "python3 -c \"import json;r=json.load(open('$WORK/resp.json'));assert r['runs_created']==0 and r['runs_duplicate']==1, r\""

# ⑤c a bare flat workout (no wrapper) still works
cat > "$WORK/flat-bare.json" <<JSON
{"id":"SC-HIKE-9002","activity":"Hiking","start":"$D1 14:00:00 +0800",
 "duration_s":5400,"distance_m":6200}
JSON
ingest good "$WORK/flat-bare.json" >/dev/null
check "bare flat workout (no \"workout\" wrapper) created" bash -c \
  "python3 -c \"import json;r=json.load(open('$WORK/resp.json'));assert r['runs_created']==1, r\""

# ⑤d URL-PARAMS ONLY — no request body at all. This is the shape the
#    beginner Shortcut posts (one Text action builds the URL).
D4=$(day 4)
check "query-param daily row → recovery row" bash -c \
  "curl -fsS -X POST '$BASE/api/health/ingest?token=$TOKEN_GOOD&date=$D4&hrv=38.5&rhr=51&sleep=6.4&vo2max=50.2&weight=71.2' -o '$WORK/q1.json' && python3 -c \"import json;r=json.load(open('$WORK/q1.json'));assert r['recovery_created']==1, r\""
curl -fsS "$BASE/api/collections/recovery_daily/records?perPage=50&sort=-date" "${AUTH[@]}" > "$WORK/rec4.json"
python3 <<EOF > "$WORK/qday.txt" 2>&1
import json
by = {r["date"][:10]: r for r in json.load(open("$WORK/rec4.json"))["items"]}
d = by["$D4"]
assert d["hrv_sdnn_ms"] == 38.5 and d["resting_hr"] == 51, d
assert d["sleep_hours"] == 6.4 and d["vo2max"] == 50.2, d
assert d["body_mass_kg"] == 71.2, d
print("ok")
EOF
check "query-param values parsed from strings correctly" \
  bash -c "grep -q '^ok\$' '$WORK/qday.txt'"

check "query-param workout → run row" bash -c \
  "curl -fsS -X POST '$BASE/api/health/ingest?token=$TOKEN_GOOD&id=SC-RUN-9003&activity=Running&start=$D4T&duration_s=1800&distance_m=6000&avg_hr=140&max_hr=165' -o '$WORK/q2.json' && python3 -c \"import json;r=json.load(open('$WORK/q2.json'));assert r['runs_created']==1, r\""
curl -fsS "$BASE/api/collections/runs/records?perPage=50&sort=-date" "${AUTH[@]}" > "$WORK/runs3.json"
python3 <<EOF > "$WORK/qrun.txt" 2>&1
import json
by = {r["healthkit_uuid"]: r for r in json.load(open("$WORK/runs3.json"))["items"]}
r = by["SC-RUN-9003"]
assert r["distance_m"] == 6000 and r["duration_s"] == 1800, r
assert r["avg_hr"] == 140 and r["max_hr"] == 165, r
assert r["activity_type"] == "running", r["activity_type"]
print("ok")
EOF
check "query-param workout fields all landed" \
  bash -c "grep -q '^ok\$' '$WORK/qrun.txt'"

# ── ⑥ the engine reads a database fed this way ───────────────────────────
echo "· ⑥ engine over ingested data…"
check "GET /api/coach/engine still 200s" bash -c \
  "curl -fsS '$BASE/api/coach/engine' -H 'Authorization: $TOKEN' -o '$WORK/engine.json'"
check "engine saw the ingested run (10.2 km)" bash -c "grep -q '10.2' '$WORK/engine.json'"
check "cross-training facts saw the hike" bash -c "grep -qi 'hik' '$WORK/engine.json'"

# ── ⑦ server with no token configured refuses outright ───────────────────
echo "· ⑦ unset HEALTH_INGEST_TOKEN → 503 (never stands open)…"
kill "$PB_PID" 2>/dev/null; wait "$PB_PID" 2>/dev/null
LLM_PROVIDER=mock WEATHER_MODE=off \
"$PB_BIN" serve --dir "$WORK/pb_data" --hooksDir "$REPO/server/pb_hooks" \
  --migrationsDir "$REPO/server/pb_migrations" \
  --http "127.0.0.1:$PORT" >"$WORK/pb2.log" 2>&1 &
PB_PID_NOTOKEN=$!
for i in $(seq 1 50); do curl -fsS "$BASE/api/health" >/dev/null 2>&1 && break; sleep 0.2; done
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/api/health/ingest" \
  -H 'content-type: application/json' --data-binary "@$WORK/payload.json")
check "no server token → 503" [ "$CODE" = 503 ]

# ── ⑧ web app is installable ─────────────────────────────────────────────
echo "· ⑧ web app installable to the home screen…"
check "manifest.webmanifest exists and is valid JSON" bash -c \
  "python3 -c \"import json;m=json.load(open('$REPO/web/manifest.webmanifest'));assert m['display']=='standalone' and m['icons']\""
check "apple-touch-icon 180 present" [ -f "$REPO/web/icon-180.png" ]
check "manifest icons 192 + 512 present" bash -c \
  "[ -f '$REPO/web/icon-192.png' ] && [ -f '$REPO/web/icon-512.png' ]"
check "index.html links the manifest" bash -c \
  "grep -q 'rel=\"manifest\"' '$REPO/web/index.html'"
check "index.html declares apple-mobile-web-app-capable" bash -c \
  "grep -q 'apple-mobile-web-app-capable' '$REPO/web/index.html'"

echo
if [[ $FAILED -gt 0 ]]; then echo "✗ $FAILED failed ($PASS passed)"; tail -40 "$WORK/pb.log"; exit 1; fi
echo "✔ all $PASS checks passed"
