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
 {"date":"'"${NEXT_WEEK[1]}"'","type":"T","distance_km":10,"description":"threshold reps 5 × 4min @ T pace"},
 {"date":"'"${NEXT_WEEK[2]}"'","type":"rest","distance_km":0,"description":"off"},
 {"date":"'"${NEXT_WEEK[3]}"'","type":"E","distance_km":0,"description":"strides"},
 {"date":"'"${NEXT_WEEK[4]}"'","type":"rest","distance_km":0,"description":"off"},
 {"date":"'"${NEXT_WEEK[5]}"'","type":"banana","distance_km":4,"description":"???"},
 {"date":"'"${NEXT_WEEK[6]}"'","type":"LR","distance_km":10,"description":"long"}]}'

MOCK_DISTILL='{"facts":[
 {"id":null,"fact":"Ankle injury since June 2026; cleared date unknown","confidence":0.9},
 {"id":null,"fact":"Prefers data-driven feedback over pep talk","confidence":0.7}]}'

# M7 Phase 2: a synthetic week 60d out (clear of the date-relative run seeds);
# "today" is pinned to its Wednesday (P2[2]) so the replan always has a past
# (skipped) day + ≥2 future days regardless of the real weekday it runs on.
P2=($(python3 -c "
import datetime
mon = datetime.date.today() + datetime.timedelta(days=60)
mon = mon - datetime.timedelta(days=mon.weekday())
print(' '.join(str(mon+datetime.timedelta(days=i)) for i in range(7)))"))
# Mock replan deliberately breaks rails: a tempo day (quality, illegal under
# red) and 34 km of running over a 13 km cap, plus a past-day change to ignore.
MOCK_REPLAN='{"rationale":"Easing the rest of the week after the skip.","changes":[
 {"date":"'"${P2[3]}"'","type":"E","distance_km":6,"description":"easy"},
 {"date":"'"${P2[4]}"'","type":"T","distance_km":8,"description":"tempo"},
 {"date":"'"${P2[5]}"'","type":"LR","distance_km":20,"description":"long"},
 {"date":"'"${P2[0]}"'","type":"E","distance_km":5,"description":"past day — must be ignored"}]}'

LLM_PROVIDER=mock \
LLM_LOG_PROMPT=1 \
LLM_MOCK_RESPONSE_DAILY="Canned coach reply: ease back into it." \
LLM_MOCK_RESPONSE_WEEKLY="$MOCK_WEEKLY" \
LLM_MOCK_RESPONSE_REPLAN="$MOCK_REPLAN" \
LLM_MOCK_RESPONSE_DISTILL="$MOCK_DISTILL" \
LLM_MOCK_RESPONSE_TRENDS='{"volume":"Volume is at zero while you heal.","hrv":"HRV is depressed vs baseline.","resting_hr":"RHR slightly elevated.","vo2max_health":"VO2max steady - health signal OK.","fitness":"Fitness decays slowly; patience."}' \
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

# Traffic light: detraining(yellow) + recovery(red) + intensity(yellow). M7:
# injury is NO LONGER a light driver — recovery (30/100) is what makes it red.
expect("traffic_light.light", s["traffic_light"]["light"], "red")
expect("n reasons", len(s["traffic_light"]["reasons"]), 3)
expect("injury not in light", any("INJURED" in r for r in s["traffic_light"]["reasons"]), False)

# LLM projection: strings only (gotcha #4 — no raw decimals reach the LLM)
all_strings = all(isinstance(v, str) for v in s["for_llm"].values())
expect("for_llm all strings", all_strings, True)

print()
if fails:
    print(f"✗ ENGINE SMOKE TEST FAILED ({len(fails)}): {', '.join(fails)}")
    sys.exit(1)
print("✔ engine smoke test passed — every number matched the hand computation")
PYEOF

# ── 5. M7: injury is a MINOR signal — it no longer forces rest/cap-0 ────
# Explicit ?start = next Monday → a full future week (matches the 7-day mock).
echo "· M7: plan-week while injured (injury must NOT zero the week)…"
curl -fsS -X POST "$BASE/api/coach/plan-week?start=${NEXT_WEEK[0]}" -H "Authorization: $TOKEN" > "$WORK/plan-injured.json"
python3 - "$WORK/plan-injured.json" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["cap_km"] == 13, p["cap_km"]                       # round(11.6 × 1.15), NOT 0
assert len(p["days"]) == 7, len(p["days"])
assert any(d["type"] != "rest" for d in p["days"]), p["days"] # injury ≠ forced rest
assert not any("injured" in a for a in p["adjustments"]), p["adjustments"]  # no rest override
assert p["phase"] == "base", p["phase"]   # race 2027-01-24 is ~32 weeks out
print("  ✓ injured week: cap 13 km, real training days, no rest override (injury is minor)")
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

# ── 6b. M7 Phase 1: per-run effort (RPE) persists + rides into prompts ──
echo "· M7.1: per-run effort…"
RUN_ID=$(curl -fsS "$BASE/api/collections/runs/records?perPage=1&sort=-date" -H "Authorization: $TOKEN" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["items"][0]["id"])')
curl -fsS -X PATCH "$BASE/api/collections/runs/records/$RUN_ID" \
  -H "Authorization: $TOKEN" -H 'content-type: application/json' -d '{"effort":4}' >/dev/null
curl -fsS "$BASE/api/collections/runs/records/$RUN_ID" -H "Authorization: $TOKEN" \
  | python3 -c 'import sys,json; assert json.load(sys.stdin)["effort"]==4; print("  ✓ effort persisted to PB (4/5)")'
# engine surfaces it: raw number in state, pre-formatted string for the LLM
curl -fsS "$BASE/api/coach/engine" -H "Authorization: $TOKEN" \
  | python3 -c '
import sys, json
s = json.load(sys.stdin)
assert s["last_run_effort"] == 4, s.get("last_run_effort")
assert "4/5" in s["for_llm"].get("last_run_effort", ""), s["for_llm"]
print("  ✓ engine: last_run_effort=4, for_llm carries the \"4/5\" string")'
# rides into the chat prompt (LLM_LOG_PROMPT mirrors prompts to pb.log)
curl -fsS -X POST "$BASE/api/coach/chat" -H "Authorization: $TOKEN" \
  -H 'content-type: application/json' -d '{"message":"how was that one?"}' >/dev/null
if grep -q "effort 4/5" "$WORK/pb.log"; then
  echo "  ✓ effort string reached the LLM prompt (\"effort 4/5\")"
else
  echo "  ✗ effort string not found in logged prompt"; exit 1
fi

# ── 6c. M7: per-run coach feedback saved ON the run, NOT in the chat ─────
echo "· M7: run-feedback → coach_note on the activity (out of chat)…"
msg_count() { curl -fsS "$BASE/api/collections/coach_messages/records?perPage=1" -H "Authorization: $TOKEN" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["totalItems"])'; }
BEFORE=$(msg_count)
curl -fsS -X POST "$BASE/api/coach/run-feedback" -H "Authorization: $TOKEN" \
  | python3 -c 'import sys,json; r=json.load(sys.stdin); assert "Canned coach reply" in r["coach_note"], r; print("  ✓ run-feedback returns a coach note")'
curl -fsS "$BASE/api/collections/runs/records/$RUN_ID" -H "Authorization: $TOKEN" \
  | python3 -c 'import sys,json; r=json.load(sys.stdin); assert "Canned coach reply" in (r.get("coach_note") or ""), r; print("  ✓ coach note persisted on the run")'
AFTER=$(msg_count)
[ "$BEFORE" = "$AFTER" ] && echo "  ✓ no chat message created (feedback stays on the activity)" \
  || { echo "  ✗ run-feedback leaked into chat ($BEFORE → $AFTER)"; exit 1; }

# ── 6d. M7: sheet-backup endpoint is wired + degrades gracefully ────────
echo "· M7: sheet-backup endpoint (unconfigured → graceful 400, not a crash)…"
CODE=$(curl -s -o "$WORK/backup.json" -w "%{http_code}" -X POST "$BASE/api/coach/backup-sheet" -H "Authorization: $TOKEN")
if [ "$CODE" = "400" ] && grep -q "BACKUP_SHEET_URL" "$WORK/backup.json"; then
  echo "  ✓ backup-sheet wired, no-ops cleanly when BACKUP_SHEET_URL unset"
else
  echo "  ✗ backup-sheet unexpected response ($CODE): $(cat "$WORK/backup.json")"; exit 1
fi

# ── 7. M3: heal the athlete, regenerate — every rail must clamp ─────────
echo "· M3: plan-week healthy (cap / unknown-type / days_per_week / paces)…"
PROF_ID=$(curl -fsS "$BASE/api/collections/athlete_profile/records?perPage=1" -H "Authorization: $TOKEN" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["items"][0]["id"])')
curl -fsS -X PATCH "$BASE/api/collections/athlete_profile/records/$PROF_ID" \
  -H "Authorization: $TOKEN" -H 'content-type: application/json' -d '{"injured":false}' >/dev/null
curl -fsS -X POST "$BASE/api/coach/plan-week?start=${NEXT_WEEK[0]}" -H "Authorization: $TOKEN" > "$WORK/plan-healthy.json"
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
# M7 Phase 3: time-based reps ("5 × 4min") rewritten to distance (240s ÷ 309 s/km
# → 800 m), no minutes left in the description.
assert "800m" in t["description"], t["description"]
assert "min" not in t["description"], t["description"]
assert any("time to distance" in a for a in p["adjustments"]), p["adjustments"]
lr = next(d for d in days if d["type"] == "LR")
assert (lr["pace_low"], lr["pace_high"]) == (355, 408), lr # easy range from zones
assert any("banana" in a for a in p["adjustments"]), p["adjustments"]
assert any("scaled" in a for a in p["adjustments"]), p["adjustments"]
print("  ✓ healthy week: 13 km cap, banana→E, 4 run days, paces from VDOT zones")
PYEOF

# ── 7a. M7: default plan horizon is the CURRENT week, from today forward ──
echo "· M7: plan-week default targets THIS week (today → Sunday)…"
THIS_MON=$(python3 -c "import datetime;d=datetime.date.today();print(d-datetime.timedelta(days=d.weekday()))")
THIS_SUN=$(python3 -c "import datetime;d=datetime.date.today();print(d-datetime.timedelta(days=d.weekday())+datetime.timedelta(days=6))")
TODAY=$(python3 -c "import datetime;print(datetime.date.today())")
curl -fsS -X POST "$BASE/api/coach/plan-week" -H "Authorization: $TOKEN" > "$WORK/plan-thisweek.json"
THIS_MON="$THIS_MON" THIS_SUN="$THIS_SUN" TODAY="$TODAY" python3 - "$WORK/plan-thisweek.json" <<'PYEOF'
import json, os, sys
p = json.load(open(sys.argv[1]))
this_mon, this_sun, today = os.environ["THIS_MON"], os.environ["THIS_SUN"], os.environ["TODAY"]
assert p["week_start"] == this_mon, (p["week_start"], this_mon)   # current week, not next
assert p["cap_km"] == 13, p["cap_km"]                            # no runs logged this week → full cap
dates = [d["date"] for d in p["days"]]
assert dates, "no days planned"
assert all(today <= d <= this_sun for d in dates), dates          # today-forward, within this week
print("  ✓ default plan = current week from %s; %d day(s), cap 13" % (today, len(dates)))
PYEOF

# ── 7b. M7 Phase 6: return-to-run ramp (recently returned → short, easy-only) ──
# Heal stays false (section 7); set the return date to TODAY → a comeback ramp.
echo "· M7.6: return-to-run ramp…"
curl -fsS -X PATCH "$BASE/api/collections/athlete_profile/records/$PROF_ID" \
  -H "Authorization: $TOKEN" -H 'content-type: application/json' \
  -d "{\"return_to_run_date\":\"$(day 0)T00:00:00.000Z\"}" >/dev/null

# Engine: pre-injury baseline = peak 28-day rolling weekly volume over 180d.
# Densest 28-day block (days_ago 14..40) = 62.39 km → 15.6 km/wk. The ramp is
# anchored to NOW → week 1, cap round(15.6 × 0.30) = 5 km, easy-only.
curl -fsS "$BASE/api/coach/engine" -H "Authorization: $TOKEN" > "$WORK/engine-ramp.json"
python3 - "$WORK/engine-ramp.json" <<'PYEOF'
import json, sys
s = json.load(open(sys.argv[1]))
fails = []
def expect(label, got, want):
    ok = got == want
    print(("  ✓" if ok else "  ✗") + f" {label}: {got!r}" + ("" if ok else f"  (expected {want!r})"))
    if not ok: fails.append(label)
expect("chronic_baseline_km", s["chronic_baseline_km"], 15.6)
r = s["return_ramp"]
expect("return_ramp present", bool(r), True)
expect("return_ramp.week (now)", r and r["week"], 1)
expect("return_ramp.of", r and r["of"], 4)
expect("return_ramp.cap_km", r and r["cap_km"], 5)
expect("return_ramp.no_quality", r and r["no_quality"], True)
expect("for_llm has return_to_run", "return_to_run" in s["for_llm"], True)
if fails:
    print(f"✗ RAMP ENGINE CHECK FAILED: {', '.join(fails)}"); sys.exit(1)
print("  ✓ baseline 15.6 km/wk, ramp week 1 (now), cap 5 km, easy-only flagged")
PYEOF

# Plan: anchored to NEXT Monday → ramp week 2, cap round(15.6 × 0.50) = 8 km,
# still easy-only. The mock plan breaks rails (tempo day + 34 km) — the
# sanitizer must force quality→E and scale the volume under the ramp cap.
curl -fsS -X POST "$BASE/api/coach/plan-week?start=${NEXT_WEEK[0]}" -H "Authorization: $TOKEN" > "$WORK/plan-ramp.json"
python3 - "$WORK/plan-ramp.json" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["ramp_week"] == 2, p["ramp_week"]
assert p["cap_km"] == 8, p["cap_km"]
quality = [d["type"] for d in p["days"] if d["type"] in ("T", "I", "R", "MP")]
assert not quality, quality                                   # no quality in the ramp
total = sum(d["distance_km"] for d in p["days"])
assert total <= 8 + 0.5, total                                # scaled under the ramp cap
assert any("easy only" in a for a in p["adjustments"]), p["adjustments"]
assert any("scaled" in a for a in p["adjustments"]), p["adjustments"]
print("  ✓ ramp week 2: cap 8 km, tempo→E (quality-free), volume within cap")
PYEOF
# restore the original (out-of-window) return date so later sections see a
# healthy, non-ramp athlete again
curl -fsS -X PATCH "$BASE/api/collections/athlete_profile/records/$PROF_ID" \
  -H "Authorization: $TOKEN" -H 'content-type: application/json' \
  -d "{\"return_to_run_date\":\"$(day -34)T00:00:00.000Z\"}" >/dev/null

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
  python3 -c '
import sys, json
r = json.load(sys.stdin)["review"]
assert set(r.keys()) == {"volume", "hrv", "resting_hr", "vo2max_health", "fitness"}, r
print("  ✓ trends review: structured per-chart commentary")'
curl -fsS -G "$BASE/api/collections/coach_messages/records" \
  --data-urlencode "filter=kind = 'weekly_review'" --data-urlencode "perPage=1" \
  -H "Authorization: $TOKEN" |
  python3 -c 'import sys,json; assert json.load(sys.stdin)["totalItems"] >= 1; print("  ✓ stored as weekly_review")'

# ── 12. M7 Phase 2: mid-week re-plan (skipped trigger + red easy-only rail) ──
echo "· M7.2: mid-week re-plan…"
# Plain cap (no ramp/injury): chronic 11.6 → cap round(11.6×1.15)=13 km. Light
# stays RED (recovery 30/100) → the remainder must be forced easy-only.
curl -fsS -X PATCH "$BASE/api/collections/athlete_profile/records/$PROF_ID" \
  -H "Authorization: $TOKEN" -H 'content-type: application/json' \
  -d '{"injured":false,"return_to_run_date":null}' >/dev/null
# Synthetic week: Mon skipped quality (the trigger), Wed = pinned today, then
# 3 future training days the replan may move, bracketed by rest days.
post planned_workouts "{\"date\":\"${P2[0]}T00:00:00.000Z\",\"type\":\"T\",\"distance_m\":8000,\"description\":\"tempo (skipped)\",\"status\":\"skipped\"}"
post planned_workouts "{\"date\":\"${P2[1]}T00:00:00.000Z\",\"type\":\"rest\",\"distance_m\":0,\"description\":\"rest\",\"status\":\"planned\"}"
post planned_workouts "{\"date\":\"${P2[2]}T00:00:00.000Z\",\"type\":\"E\",\"distance_m\":6000,\"description\":\"today\",\"status\":\"planned\"}"
post planned_workouts "{\"date\":\"${P2[3]}T00:00:00.000Z\",\"type\":\"E\",\"distance_m\":6000,\"description\":\"thu\",\"status\":\"planned\"}"
post planned_workouts "{\"date\":\"${P2[4]}T00:00:00.000Z\",\"type\":\"E\",\"distance_m\":6000,\"description\":\"fri\",\"status\":\"planned\"}"
post planned_workouts "{\"date\":\"${P2[5]}T00:00:00.000Z\",\"type\":\"LR\",\"distance_m\":12000,\"description\":\"sat\",\"status\":\"planned\"}"
post planned_workouts "{\"date\":\"${P2[6]}T00:00:00.000Z\",\"type\":\"rest\",\"distance_m\":0,\"description\":\"sun\",\"status\":\"planned\"}"

curl -fsS -X POST "$BASE/api/coach/replan?force=1&today=${P2[2]}" -H "Authorization: $TOKEN" > "$WORK/replan.json"
python3 - "$WORK/replan.json" "${P2[0]}" "${P2[2]}" "${P2[3]}" "${P2[4]}" "${P2[5]}" <<'PYEOF'
import json, sys
r = json.load(open(sys.argv[1]))
MON, WED, THU, FRI, SAT = sys.argv[2:7]
assert r["replanned"] is True, r
assert any("skipped" in x for x in r["reasons"]), r["reasons"]      # (a) trigger fired
assert r["remaining_cap_km"] == 13, r["remaining_cap_km"]
changed = set(r["changed_dates"])
assert MON not in changed, ("past day must not change", changed)     # only future days
assert WED not in changed, ("today must not change", changed)
assert changed <= {THU, FRI, SAT}, changed
print("  ✓ trigger=skip, only future days changed, remaining cap 13 km")
PYEOF

# Inspect the persisted workouts: red light → no quality survives; modified
# status; original preserved; total scaled under the remaining cap.
curl -fsS -G "$BASE/api/collections/planned_workouts/records" \
  --data-urlencode "filter=date >= '${P2[3]} 00:00:00.000Z' && date <= '${P2[5]} 23:59:59.000Z'" \
  --data-urlencode "perPage=10" -H "Authorization: $TOKEN" > "$WORK/replan-wos.json"
python3 - "$WORK/replan-wos.json" <<'PYEOF'
import json, sys
items = json.load(open(sys.argv[1]))["items"]
modified = [i for i in items if i["status"] == "modified"]
assert modified, [i["status"] for i in items]
assert all(i["type"] in ("E", "LR", "rest") for i in modified), [i["type"] for i in modified]  # red → no quality
assert all("🔄 was" in (i["description"] or "") for i in modified), [i["description"] for i in modified]
total = sum((i["distance_m"] or 0)/1000 for i in items)
assert total <= 13 + 0.5, total                                       # scaled under cap
print("  ✓ red light forced easy-only (T→E), modified + original kept, total %.1f km ≤ 13" % total)
PYEOF

# Once-per-day guard: a second (non-forced) replan today is a no-op.
curl -fsS -X POST "$BASE/api/coach/replan?today=${P2[2]}" -H "Authorization: $TOKEN" |
  python3 -c 'import sys,json; r=json.load(sys.stdin); assert r["replanned"] is False and "already replanned" in r["reason"], r; print("  ✓ once-per-day guard holds")'

# The change is announced as a plan_change coach message.
curl -fsS -G "$BASE/api/collections/coach_messages/records" \
  --data-urlencode "filter=kind = 'plan_change'" --data-urlencode "perPage=1" \
  -H "Authorization: $TOKEN" |
  python3 -c 'import sys,json; assert json.load(sys.stdin)["totalItems"] >= 1; print("  ✓ plan_change message posted")'

# ── 12b. M7: preferred run days + weekly volume target (athlete-owned rails) ──
echo "· M7: run_days + weekly_target_km…"
# Chronic 11.6, baseline 15.6 → engine cap 13; safety ceiling = max(11.6,15.6,15)×1.5
# = round(23.4) = 23. Target 40 is above the ceiling → capped to 23. Run days
# Mon/Wed/Fri only → every other weekday must be rest.
curl -fsS -X PATCH "$BASE/api/collections/athlete_profile/records/$PROF_ID" \
  -H "Authorization: $TOKEN" -H 'content-type: application/json' \
  -d '{"injured":false,"return_to_run_date":null,"run_days":"Monday,Wednesday,Friday","weekly_target_km":40}' >/dev/null
curl -fsS -X POST "$BASE/api/coach/plan-week?start=${NEXT_WEEK[0]}" -H "Authorization: $TOKEN" > "$WORK/plan-sched.json"
python3 - "$WORK/plan-sched.json" <<'PYEOF'
import json, sys, datetime
p = json.load(open(sys.argv[1]))
assert p["cap_km"] == 23, ("target 40 should be safety-capped to 23", p["cap_km"])
allowed = {"Monday", "Wednesday", "Friday"}
wd = ["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"]
for d in p["days"]:
    day = wd[datetime.date.fromisoformat(d["date"]).weekday()]
    if day not in allowed:
        assert d["type"] == "rest" and d["distance_km"] == 0, ("non-run day must rest", d)
assert any("safety-capped" in a for a in p["adjustments"]), p["adjustments"]
print("  ✓ runs only Mon/Wed/Fri, target 40 km safety-capped to 23 km, flagged")
PYEOF
# reset so later sections see the baseline athlete
curl -fsS -X PATCH "$BASE/api/collections/athlete_profile/records/$PROF_ID" \
  -H "Authorization: $TOKEN" -H 'content-type: application/json' \
  -d '{"run_days":"","weekly_target_km":0,"return_to_run_date":"'"$(day -34)"'T00:00:00.000Z"}' >/dev/null

# ── 13. M7 Phase 5: goal trajectory (required vs projected VDOT) ────────
echo "· M7.5: goal trajectory…"
# Off-track: a 1:30 marathon goal needs a VDOT far above any projection.
curl -fsS -X PATCH "$BASE/api/collections/athlete_profile/records/$PROF_ID" \
  -H "Authorization: $TOKEN" -H 'content-type: application/json' -d '{"goal_time_s":5400}' >/dev/null
curl -fsS "$BASE/api/coach/engine" -H "Authorization: $TOKEN" |
  python3 -c '
import sys, json
s = json.load(sys.stdin)
gt = s["goal_trajectory"]
assert gt["available"] is True, gt
# logic self-check: status follows the ±1 VDOT rule the engine claims
diff = round(gt["projected_vdot"] - gt["required_vdot"], 1)
expected = "on_track" if diff > 1 else "off_track" if diff < -1 else "borderline"
assert gt["status"] == expected, (gt["status"], expected, diff)
assert gt["status"] == "off_track", gt
assert "goal_trajectory" in s["for_llm"] and "needs VDOT" in s["for_llm"]["goal_trajectory"], s["for_llm"]
print("  ✓ 1:30 goal → off_track (needs %.1f, projected %.1f)" % (gt["required_vdot"], gt["projected_vdot"]))'

# On-track: a 7:00 marathon goal is well under the current trajectory.
curl -fsS -X PATCH "$BASE/api/collections/athlete_profile/records/$PROF_ID" \
  -H "Authorization: $TOKEN" -H 'content-type: application/json' -d '{"goal_time_s":25200}' >/dev/null
curl -fsS "$BASE/api/coach/engine" -H "Authorization: $TOKEN" |
  python3 -c '
import sys, json
gt = json.load(sys.stdin)["goal_trajectory"]
assert gt["status"] == "on_track", gt
print("  ✓ 7:00 goal → on_track (needs %.1f, projected %.1f, trend %+.1f/mo)" % (gt["required_vdot"], gt["projected_vdot"], gt["trend_per_month"]))'

# ── 14. M8: comeback after a break must NOT read as a load spike ─────────
# Reproduces the real bug: a month mostly off collapses the 28-day chronic, so
# 8 km of careful comeback running reads as ACWR 2.67 → red → program
# cancelled. M8: chronic < 50% of the established 180-day baseline + running
# again = "rebuilding", judged against the baseline. Cross-training (a hike)
# must be visible to the coach but stay out of ALL running math.
echo "· M8: comeback ≠ load spike (rebuilding state)…"

# recovery today → healthy (so the light reflects load logic only)
REC_ID=$(curl -fsS -G "$BASE/api/collections/recovery_daily/records" \
  --data-urlencode "sort=-date" --data-urlencode "perPage=1" -H "Authorization: $TOKEN" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["items"][0]["id"])')
curl -fsS -X PATCH "$BASE/api/collections/recovery_daily/records/$REC_ID" \
  -H "Authorization: $TOKEN" -H 'content-type: application/json' \
  -d '{"hrv_sdnn_ms":61,"resting_hr":50,"sleep_hours":7.5}' >/dev/null

# carve the break: remove all runs inside the 28-day window
for uuid in smoke-12 smoke-14 smoke-15 smoke-22 smoke-26; do
  RID=$(curl -fsS -G "$BASE/api/collections/runs/records" \
    --data-urlencode "filter=healthkit_uuid = '$uuid'" --data-urlencode "perPage=1" \
    -H "Authorization: $TOKEN" | python3 -c 'import sys,json;i=json.load(sys.stdin)["items"];print(i[0]["id"] if i else "")')
  [[ -n "$RID" ]] && curl -fsS -X DELETE "$BASE/api/collections/runs/records/$RID" -H "Authorization: $TOKEN"
done

# the established base (~2 months back): peak 28-day window = 56 km → 14.0 km/wk
BASE_RUNS="
60 15000 5400 140
64 12000 4350 138
68 15000 5460 141
75 14000 5100 139
"
while read -r d m s hr; do
  [[ -z "$d" ]] && continue
  post runs "{\"date\":\"$(day "$d")T07:30:00.000Z\",\"distance_m\":$m,\"duration_s\":$s,
    \"avg_hr\":$hr,\"source_app\":\"engine-smoke\",\"healthkit_uuid\":\"m8-base-$d\"}"
done <<< "$BASE_RUNS"

# the careful comeback: 8 km this week (d4 wins VDOT → zones not stale),
# 4 km three weeks ago → chronic (12 km / 4) = 3.0 km/wk, acute 8.0 km.
# Old math: ACWR 8.0/3.0 = 2.67 → red "danger spike". New: rebuilding.
COMEBACK="
1 4500 1710 145
4 3500 1050 155
20 4000 1560 140
"
while read -r d m s hr; do
  [[ -z "$d" ]] && continue
  post runs "{\"date\":\"$(day "$d")T07:30:00.000Z\",\"distance_m\":$m,\"duration_s\":$s,
    \"avg_hr\":$hr,\"source_app\":\"engine-smoke\",\"healthkit_uuid\":\"m8-back-$d\"}"
done <<< "$COMEBACK"

# a hike (cross-training) — visible to the coach, out of the running math
post runs "{\"date\":\"$(day 2)T09:00:00.000Z\",\"distance_m\":10000,\"duration_s\":10800,
  \"avg_hr\":110,\"source_app\":\"engine-smoke\",\"healthkit_uuid\":\"m8-hike-2\",\"activity_type\":\"hiking\"}"

curl -fsS "$BASE/api/coach/engine" -H "Authorization: $TOKEN" > "$WORK/engine-m8.json"
python3 - "$WORK/engine-m8.json" <<'PYEOF'
import json, sys
s = json.load(open(sys.argv[1]))
fails = []
def expect(label, got, want):
    ok = got == want
    print(("  ✓" if ok else "  ✗") + f" {label}: {got!r}" + ("" if ok else f"  (expected {want!r})"))
    if not ok: fails.append(label)
a = s["acwr"]
expect("acwr.state", a["state"], "rebuilding")
expect("acwr.acute_week_km", a["acute_week_km"], 8.0)
expect("acwr.chronic_weekly_km", a["chronic_weekly_km"], 3.0)
expect("acwr.baseline_weekly_km", a["baseline_weekly_km"], 14.0)
# THE fix: old code read this as ACWR 2.67 → red → all-rest program
expect("traffic_light.light", s["traffic_light"]["light"], "green")
expect("traffic_light.drivers", s["traffic_light"]["drivers"], [])
expect("rebuilding reason", "rebuilding" in s["traffic_light"]["reasons"][0], True)
# intensity guard: 3 runs w/ HR is too small a sample to flag 80/20
expect("intensity not flagged", any("intensity" in d for d in s["traffic_light"]["drivers"]), False)
# cross-training: coach sees the hike; running math does not
expect("for_llm.cross_training mentions hike", "hiking" in s["for_llm"].get("cross_training", ""), True)
expect("hike outside run count", s["history"]["runs_180d"], 10)
if fails:
    print(f"✗ M8 REBUILDING CHECK FAILED: {', '.join(fails)}"); sys.exit(1)
print("  ✓ comeback = rebuilding (green), hike visible but out of run math")
PYEOF

# plan generation during a rebuild: graduated cap min(12, max(8×1.3, 14×0.35))
# = 10 km — a real training week, never an all-rest week.
curl -fsS -X POST "$BASE/api/coach/plan-week?start=${NEXT_WEEK[0]}" -H "Authorization: $TOKEN" > "$WORK/plan-m8.json"
python3 - "$WORK/plan-m8.json" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["cap_km"] == 10, ("rebuilding cap should be 10", p["cap_km"])
nonrest = [d for d in p["days"] if d["type"] != "rest"]
assert nonrest, "rebuilding week must contain real training days"
total = sum(d["distance_km"] for d in p["days"])
assert total <= 10.5, total
print("  ✓ rebuilding week: cap 10 km, %d training days, %.1f km — program continues" % (len(nonrest), total))
PYEOF

# ramping back too fast (14 km acute > 60% of the 14 km/wk base) → yellow, not red
post runs "{\"date\":\"$(day 2)T18:00:00.000Z\",\"distance_m\":6000,\"duration_s\":2280,
  \"avg_hr\":150,\"source_app\":\"engine-smoke\",\"healthkit_uuid\":\"m8-fast-2\"}"
curl -fsS "$BASE/api/coach/engine" -H "Authorization: $TOKEN" |
  python3 -c '
import sys, json
s = json.load(sys.stdin)
t = s["traffic_light"]
assert s["acwr"]["state"] == "rebuilding", s["acwr"]
assert t["light"] == "yellow", (t["light"], t["reasons"])
assert "ramp_fast" in t["drivers"], t["drivers"]
print("  ✓ over-eager ramp (14 km vs 14 km/wk base) → yellow ramp_fast, still not red")'

# ── 15. M9: the goal-anchored training block (macro plan) ────────────────
# The program IS the product: one deterministic block from today to race day —
# volume arc + cutbacks, long-run curve, final long run, race-length taper —
# and the weekly generator must plan INSIDE it. Zero LLM cost.
echo "· M9: macro training block…"

curl -fsS -X POST "$BASE/api/coach/macro-plan" -H "Authorization: $TOKEN" > "$WORK/macro.json"
python3 - "$WORK/macro.json" <<'PYEOF'
import json, sys, datetime
r = json.load(open(sys.argv[1]))
assert not r.get("skipped"), r
weeks = r["weeks"]

# span: this Monday → the race's Monday, inclusive (race 2027-01-24 in fixture)
today = datetime.date.today()
mon_today = today - datetime.timedelta(days=today.weekday())
race = datetime.date(2027, 1, 24)
mon_race = race - datetime.timedelta(days=race.weekday())
n = (mon_race - mon_today).days // 7 + 1
assert len(weeks) == n, (len(weeks), n)
assert weeks[0]["week_start"] == str(mon_today), weeks[0]

# week 1 starts where the athlete IS (rebuilding cap 12, computed in §14)
assert weeks[0]["target_km"] == 12, weeks[0]

# marathon → 3-week taper; last week is race week; final LR right before taper
assert [w["phase"] for w in weeks[-3:]] == ["taper", "taper", "taper"], [w["phase"] for w in weeks[-3:]]
assert weeks[-1]["milestone"] == "race_week" and weeks[-1]["long_run_km"] == 0, weeks[-1]
flr = weeks[n - 4]
assert flr["milestone"] == "final_long_run", flr
assert flr["long_run_km"] == max(w["long_run_km"] for w in weeks), flr  # the peak LR

# volume: ceiling respected (baseline 14 → ceiling 20), taper descends
assert all(w["target_km"] <= 20 for w in weeks), max(w["target_km"] for w in weeks)
assert weeks[-1]["target_km"] < weeks[-3]["target_km"], [w["target_km"] for w in weeks[-3:]]
# structure: cutback weeks exist and are easier than their neighbours
cuts = [i for i, w in enumerate(weeks) if w["is_cutback"]]
assert cuts, "no cutback weeks in a %d-week block" % n
i = cuts[0]
assert weeks[i]["target_km"] < weeks[i - 1]["target_km"], (weeks[i - 1], weeks[i])
assert all(0 <= w["quality_sessions"] <= 2 for w in weeks)
print("  ✓ block: %d weeks, 12→%d km/wk, %d cutbacks, final LR %d km, 3-wk taper, race week last"
      % (n, max(w["target_km"] for w in weeks), len(cuts), flr["long_run_km"]))
print("  ✓ summary: " + r["summary"])
PYEOF

# the block is announced in the plan feed (kind plan_change, engine-made)
curl -fsS -G "$BASE/api/collections/coach_messages/records" \
  --data-urlencode "filter=kind = 'plan_change' && provider = 'engine'" \
  --data-urlencode "perPage=1" -H "Authorization: $TOKEN" |
  python3 -c 'import sys,json; r=json.load(sys.stdin); assert r["totalItems"] >= 1 and "training block" in r["items"][0]["content"].lower(); print("  ✓ block announced as a plan_change message (provider=engine, no LLM)")'

# the engine now carries the block in every prompt
curl -fsS "$BASE/api/coach/engine" -H "Authorization: $TOKEN" |
  python3 -c '
import sys, json
s = json.load(sys.stdin)
m = s["macro_week"]
assert m and m["week_number"] == 1, m
assert "training_block" in s["for_llm"] and "block week 1 of" in s["for_llm"]["training_block"], s["for_llm"]
print("  ✓ engine: macro_week present, for_llm.training_block =", json.dumps(s["for_llm"]["training_block"])[:80] + "…")'

# weekly generation executes the block: next week = block week 2 (13 km) but
# the reactive cap (12) still bounds it — min() wins; macro rides in the result
curl -fsS -X POST "$BASE/api/coach/plan-week?start=${NEXT_WEEK[0]}" -H "Authorization: $TOKEN" > "$WORK/plan-m9.json"
python3 - "$WORK/plan-m9.json" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["macro"] is not None, "weekly plan did not see the block"
assert p["cap_km"] == 12, ("cap = min(reactive 12, block 13)", p["cap_km"])
assert p["phase"] == p["macro"]["phase"], (p["phase"], p["macro"])
total = sum(d["distance_km"] for d in p["days"])
assert total <= 12.5, total
print("  ✓ weekly plan executes block week 2: phase %s, cap 12 km, %.1f km planned"
      % (p["phase"], total))
PYEOF

# re-anchor: race date moves → ensure() rebuilds the block around the new date
NEW_RACE="2027-03-14"
curl -fsS -X PATCH "$BASE/api/collections/athlete_profile/records/$PROF_ID" \
  -H "Authorization: $TOKEN" -H 'content-type: application/json' \
  -d "{\"race_date\":\"${NEW_RACE}T00:00:00.000Z\"}" >/dev/null
curl -fsS -G "$BASE/api/collections/macro_weeks/records" \
  --data-urlencode "sort=-week_start" --data-urlencode "perPage=1" -H "Authorization: $TOKEN" |
  NEW_RACE="$NEW_RACE" python3 -c '
import sys, json, os, datetime
race = datetime.date.fromisoformat(os.environ["NEW_RACE"])
mon = race - datetime.timedelta(days=race.weekday())
last = json.load(sys.stdin)["items"][0]
assert last["week_start"].startswith(str(mon)), (last["week_start"], str(mon))
assert last["milestone"] == "race_week", last
print("  ✓ race moved → profile-save hook re-anchored the block to week of", str(mon))'

echo
echo "✔ engine + M3 plan/chat + M4 memory + M5 engagement + M6 trends + M7(1,2,3,5,6) + M8 rebuilding + M9 macro block — all passed"
