#!/usr/bin/env bash
# test-engine-local.sh — M2 engine smoke test on a THROWAWAY local PocketBase.
# No Pi, no phone, no LLM key needed (the /api/coach/engine endpoint is pure
# deterministic code). Seeds synthetic history with hand-computed expectations
# and asserts the engine's math.
#
# Usage: ./scripts/test-engine-local.sh
# Requires: curl, python3. Downloads a pocketbase binary on first run.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."
PB_VERSION="${PB_VERSION:-0.28.4}"
CACHE="$HERE/.cache"
PORT=8099
BASE="http://127.0.0.1:$PORT"

# ── 1. pocketbase binary ────────────────────────────────────────────────
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

# ── 2. throwaway instance with the repo's hooks + migrations ────────────
WORK="$(mktemp -d /tmp/pb-engine-test.XXXXXX)"
cleanup() { kill "$PB_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

SU_EMAIL="smoke@test.local"
SU_PASS="smoketest12345"
"$PB_BIN" --dir "$WORK/pb_data" --migrationsDir "$REPO/server/pb_migrations" \
  superuser upsert "$SU_EMAIL" "$SU_PASS" >/dev/null

# Mock LLM: plan/chat handlers run with zero network and zero keys. The
# weekly mock deliberately BREAKS the rails (34 km over a 13 km cap, an
# unknown type, 5 run days vs days_per_week=4, runs while injured) so the
# test proves the deterministic sanitizer repairs all of it.
NEXT_WEEK=($(python3 -c "
import datetime
now = datetime.datetime.now(datetime.timezone.utc).date()
days = ((8 - now.isoweekday()) % 7) or 7   # next strictly-future Monday (matches plan.js)
m = now + datetime.timedelta(days=days)
print(' '.join(str(m + datetime.timedelta(days=i)) for i in range(7)))"))

MOCK_WEEKLY='{"rationale":"Aggressive build week.","days":[
 {"date":"'"${NEXT_WEEK[0]}"'","type":"E","distance_km":10,"description":"easy"},
 {"date":"'"${NEXT_WEEK[1]}"'","type":"T","distance_km":10,"description":"tempo"},
 {"date":"'"${NEXT_WEEK[2]}"'","type":"rest","distance_km":0,"description":"off"},
 {"date":"'"${NEXT_WEEK[3]}"'","type":"E","distance_km":0,"description":"strides"},
 {"date":"'"${NEXT_WEEK[4]}"'","type":"rest","distance_km":0,"description":"off"},
 {"date":"'"${NEXT_WEEK[5]}"'","type":"banana","distance_km":4,"description":"???"},
 {"date":"'"${NEXT_WEEK[6]}"'","type":"LR","distance_km":10,"description":"long"}]}'

MOCK_DISTILL='{"facts":[
 {"id":null,"fact":"Ankle injury since June 2026; cleared date unknown","confidence":0.9},
 {"id":null,"fact":"Prefers data-driven feedback over pep talk","confidence":0.7}]}'

LLM_PROVIDER=mock \
LLM_MOCK_RESPONSE_DAILY="Canned coach reply: ease back into it." \
LLM_MOCK_RESPONSE_WEEKLY="$MOCK_WEEKLY" \
LLM_MOCK_RESPONSE_DISTILL="$MOCK_DISTILL" \
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

post() { # post <collection> <json>
  curl -fsS -X POST "$BASE/api/collections/$1/records" \
    -H 'content-type: application/json' -H "Authorization: $TOKEN" \
    -d "$2" >/dev/null
}

# ── 3. seed: profile + 8 runs + 8 recovery days ─────────────────────────
# Dates are relative to TODAY so window logic (7/28/90 d) is really exercised.
day() { python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=$1)).strftime('%Y-%m-%d'))"; }

echo "· seeding synthetic athlete…"
post athlete_profile "{\"race_name\":\"Test Marathon\",\"race_date\":\"2027-01-24T00:00:00.000Z\",
  \"days_per_week\":4,\"injured\":true,\"injury_note\":\"ankle\",
  \"return_to_run_date\":\"$(day -34)T00:00:00.000Z\",\"hr_max\":185}"

# runs: (days_ago, distance_m, duration_s, avg_hr)
# d15 13120/4060 is THE quality effort → VDOT 39.4, threshold 5:09 min/km.
# 28-day window (d<28): d12..d26 → chronic 46.33 km → 11.6 km/wk; acute (d<7) = 0.
RUNS="
12 5050 1850 142
14 6330 2280 139
15 13120 4060 168
22 7120 2560 141
26 14710 5430 144
33 13230 4920 138
40 7880 2900 146
47 10120 3650 140
"
while read -r d m s hr; do
  [[ -z "$d" ]] && continue
  post runs "{\"date\":\"$(day "$d")T07:30:00.000Z\",\"distance_m\":$m,\"duration_s\":$s,
    \"avg_hr\":$hr,\"source_app\":\"engine-smoke\",\"healthkit_uuid\":\"smoke-$d\"}"
done <<< "$RUNS"

# recovery: today is depressed (HRV 45 vs ~61, RHR 54 vs 50, sleep 6.0 vs 7.45)
# → hand-computed score: 100 − 34.16 (HRV) − 24 (RHR) − 11.4 (sleep) ≈ 30
REC="
7 62 50 7.5
6 60 51 7.2
5 64 49 7.8
4 58 50 7.4
3 61 52 7.6
2 63 50 7.3
1 59 49 7.7
0 45 54 6.0
"
while read -r d hrv rhr slp; do
  [[ -z "$d" ]] && continue
  post recovery_daily "{\"date\":\"$(day "$d")T00:00:00.000Z\",\"hrv_sdnn_ms\":$hrv,
    \"resting_hr\":$rhr,\"sleep_hours\":$slp}"
done <<< "$REC"

# ── 4. hit the engine & assert ──────────────────────────────────────────
echo "· querying /api/coach/engine…"
curl -fsS "$BASE/api/coach/engine" -H "Authorization: $TOKEN" > "$WORK/engine.json"

python3 - "$WORK/engine.json" <<'PYEOF'
import json, sys

s = json.load(open(sys.argv[1]))
fails = []
def expect(label, got, want):
    ok = got == want
    print(("  ✓" if ok else "  ✗") + f" {label}: {got!r}" + ("" if ok else f"  (expected {want!r})"))
    if not ok: fails.append(label)

# VDOT (Daniels-Gilbert on 13.12 km / 4060 s, hand-computed 39.38 → 39.4)
expect("vdot.value", s["vdot"]["value"], 39.4)
expect("zones.threshold", s["vdot"]["zones"]["threshold"], "5:09 min/km")
expect("zones.easy", s["vdot"]["zones"]["easy"], "6:48–5:55 min/km")
expect("vdot source distance", s["vdot"]["source_run"]["distance_km"], 13.12)

# ACWR: 46.33 km in 28d → 11.6 km/wk chronic; 0 km in 7d → detraining
expect("acwr.state", s["acwr"]["state"], "detraining")
expect("acwr.acute_week_km", s["acwr"]["acute_week_km"], 0)
expect("acwr.chronic_weekly_km", s["acwr"]["chronic_weekly_km"], 11.6)

# Recovery: 100 − 34.16 − 24 − 11.4 = 30.44 → 30, "poor"
expect("recovery.score", s["recovery"]["score"], 30)
expect("recovery.band", s["recovery"]["band"], "poor")

# 80/20: easy time 6690/16180 s → 41%
expect("intensity.pct_easy_time", s["intensity"]["pct_easy_time"], 41)

# Traffic light: injured(red) + detraining(yellow) + recovery(red) + intensity(yellow)
expect("traffic_light.light", s["traffic_light"]["light"], "red")
expect("n reasons", len(s["traffic_light"]["reasons"]), 4)
assert_injured = any("INJURED" in r for r in s["traffic_light"]["reasons"])
expect("injury reason present", assert_injured, True)

# LLM projection: strings only (gotcha #4 — no raw decimals reach the LLM)
all_strings = all(isinstance(v, str) for v in s["for_llm"].values())
expect("for_llm all strings", all_strings, True)

print()
if fails:
    print(f"✗ ENGINE SMOKE TEST FAILED ({len(fails)}): {', '.join(fails)}")
    sys.exit(1)
print("✔ engine smoke test passed — every number matched the hand computation")
PYEOF

# ── 5. M3: plan generation while injured (rails override everything) ────
echo "· M3: plan-week while injured…"
curl -fsS -X POST "$BASE/api/coach/plan-week" -H "Authorization: $TOKEN" > "$WORK/plan-injured.json"
python3 - "$WORK/plan-injured.json" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["cap_km"] == 0, p["cap_km"]
assert len(p["days"]) == 7, len(p["days"])
assert all(d["type"] == "rest" and d["distance_km"] == 0 for d in p["days"]), p["days"]
assert any("injured" in a for a in p["adjustments"]), p["adjustments"]
assert p["phase"] == "base", p["phase"]   # race 2027-01-24 is ~32 weeks out
print("  ✓ injured week: 7×rest, cap 0 km, override logged, phase base")
PYEOF

# ── 6. M3: chat round-trip (athlete + coach rows persisted) ─────────────
echo "· M3: chat…"
curl -fsS -X POST "$BASE/api/coach/chat" -H "Authorization: $TOKEN" \
  -H 'content-type: application/json' -d '{"message":"ankle is sore today"}' |
  python3 -c 'import sys,json; r=json.load(sys.stdin); assert "Canned coach reply" in r["reply"], r; print("  ✓ chat reply flows")'
curl -fsS "$BASE/api/collections/coach_messages/records?perPage=2&sort=-created" -H "Authorization: $TOKEN" |
  python3 -c '
import sys, json
roles = sorted(i["role"] for i in json.load(sys.stdin)["items"])
assert roles == ["athlete", "coach"], roles
print("  ✓ both sides of the conversation persisted")'

# ── 7. M3: heal the athlete, regenerate — every rail must clamp ─────────
echo "· M3: plan-week healthy (cap / unknown-type / days_per_week / paces)…"
PROF_ID=$(curl -fsS "$BASE/api/collections/athlete_profile/records?perPage=1" -H "Authorization: $TOKEN" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["items"][0]["id"])')
curl -fsS -X PATCH "$BASE/api/collections/athlete_profile/records/$PROF_ID" \
  -H "Authorization: $TOKEN" -H 'content-type: application/json' -d '{"injured":false}' >/dev/null
curl -fsS -X POST "$BASE/api/coach/plan-week" -H "Authorization: $TOKEN" > "$WORK/plan-healthy.json"
python3 - "$WORK/plan-healthy.json" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
days = p["days"]
total = sum(d["distance_km"] for d in days)
assert p["cap_km"] == 13, p["cap_km"]                      # round(11.6 × 1.15)
assert abs(total - 13) <= 0.5, total                       # scaled to the cap
run_days = [d for d in days if d["type"] != "rest"]
assert len(run_days) == 4, [d["type"] for d in days]       # days_per_week enforced
t = next(d for d in days if d["type"] == "T")
assert (t["pace_low"], t["pace_high"]) == (303, 315), t    # threshold 309 ±2%
lr = next(d for d in days if d["type"] == "LR")
assert (lr["pace_low"], lr["pace_high"]) == (355, 408), lr # easy range from zones
assert any("banana" in a for a in p["adjustments"]), p["adjustments"]
assert any("scaled" in a for a in p["adjustments"]), p["adjustments"]
print("  ✓ healthy week: 13 km cap, banana→E, 4 run days, paces from VDOT zones")
PYEOF

# ── 8. M3: reconcile (yesterday's plan → done/skipped) ──────────────────
echo "· M3: reconcile…"
Y="$(day 1)"
post planned_workouts "{\"date\":\"${Y}T00:00:00.000Z\",\"type\":\"E\",\"distance_m\":5000,\"description\":\"missed\",\"status\":\"planned\"}"
post planned_workouts "{\"date\":\"${Y}T00:00:00.000Z\",\"type\":\"rest\",\"distance_m\":0,\"description\":\"off\",\"status\":\"planned\"}"
curl -fsS -X POST "$BASE/api/coach/plan-week" -H "Authorization: $TOKEN" >/dev/null  # reconciles first
curl -fsS -G "$BASE/api/collections/planned_workouts/records" \
  --data-urlencode "filter=date < '$(day 0) 00:00:00.000Z'" \
  --data-urlencode "perPage=10" -H "Authorization: $TOKEN" |
  python3 -c '
import sys, json
st = {i["type"]: i["status"] for i in json.load(sys.stdin)["items"]}
assert st.get("E") == "skipped", st     # no run yesterday → skipped
assert st.get("rest") == "done", st     # rest days complete themselves
print("  ✓ reconcile: missed E → skipped, rest → done")'

# ── 9. M4: memory distillation (chat above seeded an athlete message) ───
echo "· M4: distill memory from the conversation…"
curl -fsS -X POST "$BASE/api/coach/distill" -H "Authorization: $TOKEN" |
  python3 -c 'import sys,json; r=json.load(sys.stdin); assert r.get("created")==2, r; print("  ✓ distill created 2 facts")'
curl -fsS "$BASE/api/collections/coach_memory/records?perPage=10" -H "Authorization: $TOKEN" |
  python3 -c '
import sys, json
items = json.load(sys.stdin)["items"]
assert len(items) == 2, len(items)
facts = " | ".join(i["fact"] for i in items)
assert "Ankle injury" in facts and "data-driven" in facts, facts
assert all(0 <= i["confidence"] <= 1 for i in items), items
print("  ✓ coach_memory holds the facts with confidence + provenance")'
# memory block must now ride in prompts without breaking the handlers
curl -fsS -X POST "$BASE/api/coach/chat" -H "Authorization: $TOKEN" \
  -H 'content-type: application/json' -d '{"message":"thanks coach"}' |
  python3 -c 'import sys,json; assert "reply" in json.load(sys.stdin); print("  ✓ chat still flows with memory block injected")'

# ── 10. M5: engagement ping + deterministic score ────────────────────────
echo "· M5: engagement…"
curl -fsS -X POST "$BASE/api/coach/ping" -H "Authorization: $TOKEN" >/dev/null
curl -fsS -X POST "$BASE/api/coach/ping" -H "Authorization: $TOKEN" |
  python3 -c 'import sys,json; r=json.load(sys.stdin); assert r["opens"]==2, r; print("  ✓ ping upserts (opens=2 after two pings)")'
# Deterministic from seeds: no coach "daily" msgs → response null; yesterday's
# E was skipped → completion 0/1; opens 1 day of 14 → ≈0.07; score (0+0.07)/2.
curl -fsS "$BASE/api/coach/engagement" -H "Authorization: $TOKEN" |
  python3 -c '
import sys, json
r = json.load(sys.stdin)
assert r["response_rate"] is None, r
assert r["completion_rate"] == 0, r
assert abs(r["score"] - 0.04) < 0.011, r
print("  ✓ score components match hand computation (score %.2f)" % r["score"])'

# ── 11. M6: trends review ────────────────────────────────────────────────
echo "· M6: trends review…"
curl -fsS -X POST "$BASE/api/coach/trends-review" -H "Authorization: $TOKEN" |
  python3 -c 'import sys,json; r=json.load(sys.stdin); assert "Canned coach reply" in r["review"], r; print("  ✓ trends review flows")'
curl -fsS -G "$BASE/api/collections/coach_messages/records" \
  --data-urlencode "filter=kind = 'weekly_review'" --data-urlencode "perPage=1" \
  -H "Authorization: $TOKEN" |
  python3 -c 'import sys,json; assert json.load(sys.stdin)["totalItems"] >= 1; print("  ✓ stored as weekly_review")'

echo
echo "✔ engine + M3 plan/chat + M4 memory + M5 engagement + M6 trends — all passed"
