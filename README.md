# 🏃 Pain Enjoyer

Single-user AI marathon coach. Apple Watch / Runkeeper runs sync via HealthKit to a
PocketBase backend on a Raspberry Pi; a provider-agnostic LLM layer (Gemini free tier
for dev → Claude for the real training block) turns computed training facts into
coaching advice. Full design: [PLAN.md](PLAN.md).

```
iPhone (SwiftUI + HealthKit) ──HTTPS (Cloudflare Tunnel)──► Raspberry Pi
                                                              └─ PocketBase (SQLite, auth, REST)
                                                                  ├─ pb_migrations/  schema
                                                                  └─ pb_hooks/       /api/coach/advise + cron → LLM
```

## Repo layout

| Path | What |
|---|---|
| `server/` | Everything that runs on the Pi: setup script, PocketBase migrations + hooks (incl. `engine.js`, the M2 deterministic engine) |
| `scripts/` | `test-e2e.sh` (simulated phone), `test-engine-local.sh` (M2 engine math on a throwaway PB), `test-engine-live.sh` (M2 exit test, read-only), `deploy-server.sh`, `diag.sh`, `cleanup-test-data.sh`, tunnel setup |
| `web/` | Static SPA served from `pb_public` — same origin, same API as the phone; installable to the home screen (M12) |
| `ios/` | SwiftUI app (XcodeGen project — needs a Mac to build; superseded by M12) |

## Quickstart (M0)

### 1. Gemini API key (free, no card)
Create a key at https://aistudio.google.com/apikey — goes into `server/.env` on the Pi.

### 2. Pi
```bash
# on the Pi
git clone <this repo> && cd pain-enjoyer/server
cp .env.example .env && nano .env        # fill in keys + passwords
sudo bash setup-pi.sh                    # installs PocketBase + systemd service + app user
sudo bash setup-pi.sh tunnel             # walks you through Tailscale (no domain) or Cloudflare (domain)
```

> Cloudflare gotcha (learned the hard way): if `~/.cloudflared/config.yml` exists from
> an older tunnel, `cloudflared tunnel route dns <name> <host>` may route the DNS record
> to THAT tunnel instead of the named one. Always pass the tunnel **UUID** explicitly:
> `cloudflared tunnel route dns --overwrite-dns <tunnel-uuid> <host>`

### 3. Prove the slice (no phone needed)
```bash
BASE_URL=https://<your-tunnel-host> ./scripts/test-e2e.sh
# → prints coaching advice generated from a fake run. M0 backend exit test ✔
# afterwards: ./scripts/cleanup-test-data.sh removes the fake runs
```

### 4. iOS app (needs a Mac)
```bash
cd ios && brew install xcodegen && xcodegen   # generates PainEnjoyer.xcodeproj
```
Open in Xcode, set your team (free personal team works), run on your iPhone.
First launch: Settings (gear) → server URL + app user credentials from `server/.env`,
grant HealthKit access. The app then:
- imports the last **180 days** of runs (anchored incremental sync after that)
- shows the **calendar** (month grid, tap a day for run details, swipe to delete)
- syncs **in the background** when a new workout lands in Health (M1 exit test:
  finish a run, don't open the app, run appears on the server)
- pull-to-refresh = manual sync · **+** = manual run entry
- the ECG icon runs the **HealthKit field audit** — share its output to see
  exactly which fields Runkeeper/Watch actually write

> Free Apple account: the install expires every **7 days** — re-run from Xcode weekly.
> (Documented as risk #1 in PLAN.md; $99/yr removes it.)
>
> ⚠ **Superseded on 2026-08-23 — see [M12](#m12--no-mac-healthkit-without-the-native-app).**
> The weekly re-sign turned out to be unautomatable on Ben's work Mac, so the
> phone now runs the web app + an App Store HealthKit exporter instead. This
> section is kept for anyone building the native app on a Mac they control.

## M2 — the deterministic engine

Code computes, the LLM judges (PLAN.md §1). `server/pb_hooks/engine.js` derives,
from real history only:

- **The macro training block (M9 — the core product)**: one deterministic
  program from today to race day. Volume arc with cutback weeks, a long-run
  curve that grows without breaking the athlete, the final long run, and a
  race-length taper. `POST /api/coach/macro-plan` builds it (zero LLM);
  `macro_weeks` stores it; the weekly generator executes inside it; the
  Sunday cron re-anchors it when reality drifts or the race moves.
- **VDOT + pace zones** (Daniels–Gilbert; best effort in 90 d; E/M/T/I/R paces)
- **ACWR** (7-day vs 28-day distance load; flags spike / detraining / no-base;
  M8: **rebuilding** — a comeback after a break is judged against the 180-day
  peak baseline, not the collapsed 28-day average, so it never false-flags as
  a load spike)
- **Recovery score 0–100** (today's HRV / resting HR / sleep vs personal 60-day median)
- **80/20 check** (share of running time at easy HR over 28 d; only flags with ≥5 runs)
- **🟢🟡🔴 traffic light** (worst severity wins; exports machine-readable
  `drivers`. M8: the light is a *dial on today's stress, never a program
  switch* — a red day downgrades to short easy running, it never cancels the
  plan; injury is a soft signal the coach weighs, not a light driver)

`GET /api/coach/engine` (auth) returns the full state; its `for_llm` projection
(strings only — see gotcha below) rides along in every coach prompt and is
visible in-app via the traffic-light card. The app's **person icon** opens the
athlete profile (race goal, constraints, **injury status**, HRmax) — shown
automatically on first launch; the app also pushes daily HRV/RHR/sleep/VO₂max
into `recovery_daily` on every sync (60-day backfill on the first one).

```bash
./scripts/test-engine-local.sh   # engine math vs hand-computed fixtures (throwaway PB, no Pi)
./scripts/deploy-server.sh       # hooks+migrations → Pi → /opt → restart → health
BASE_URL=https://coach.bennpc.uk ./scripts/test-engine-live.sh   # M2 exit test (read-only)
```

## M3 — race plan + conversation

- **Weekly plan**: `POST /api/coach/plan-week` + a Sunday-evening cron
  (`COACH_PLAN_CRON_UTC`, default 10:00 UTC Sun). Code owns the rails — weekly
  km cap from chronic load (×1.15, ACWR-safe), phase from weeks-to-race, pace
  targets from the VDOT zones, **injured → all-rest week** — and mechanically
  repairs whatever the LLM proposes outside them (repairs are logged into the
  week's rationale). The LLM only chooses structure and writes the words.
- **Plan vs actual**: planned workouts overlay the calendar (type letter;
  blue planned / green done / red skipped), 🏁 on race day. The morning cron
  reconciles yesterday: run landed → `done`, no run → `skipped`, rest → `done`.
- **Chat**: two-way thread with the coach — `POST /api/coach/chat`; both sides
  persist in `coach_messages` (role `athlete`/`coach`), and every reply is
  grounded in the engine facts + recent conversation. (M4's coach_memory will
  distill from this thread.)
- **Run notes**: per-run athlete notes ("ankle twinged at km 4") ride along in
  advise/chat prompts — subjective context is LLM territory, never engine math.
- All of it is testable offline: `LLM_PROVIDER=mock` (canned responses via
  `LLM_MOCK_RESPONSE[_WEEKLY|_DAILY]`) — `./scripts/test-engine-local.sh` runs
  the engine fixtures plus a deliberately rail-breaking plan to prove the
  sanitizer holds.

## M4 — the coach knows you (+ the UI pass)

- **coach_memory**: the morning cron (and `POST /api/coach/distill`) runs a
  cheap LLM pass over the last 48 h of chat and upserts durable facts
  (injuries+dates, preferences, patterns — never metrics the engine computes).
  Code owns persistence: upsert-only, nothing auto-deleted — wrong memories
  die by swipe in the app's **Coach memory** screen (brain icon), not by LLM
  omission. Top facts ride as a stable block after the persona in every
  prompt, so replies compound.
- **Traffic-light tone rules** in the persona: 🔴 never prescribes running,
  🟡 leads with caution, 🟢 may push.
- **UI**: four tabs (Coach / Calendar / Trends / Chat), hero traffic-light
  card, this-week strip, **Trends** (Swift Charts: weekly volume, HRV + RHR
  vs baseline, per-run effort VDOT), app icon (regenerate:
  `swift scripts/make-app-icon.swift`), accent color, haptics.

## M5 — adaptive proactivity

- **Engagement score** (deterministic, 14-day window): chat-response rate ×
  workout completion × app-open rate (`POST /api/coach/ping` from the app;
  `GET /api/coach/engagement` to inspect). Maps to a cadence: ≥0.55 daily ·
  ≥0.25 every 2–3 days · else weekly digest. Race ≤14 days away forces daily.
- **The morning cron now decides whether to speak**: quiet days are logged,
  never silent ghosting — a cadence change always gets one message
  acknowledging the new rhythm.
- **Red light pulls today's workout**: a planned non-rest day under a 🔴 light
  is converted to rest (`status: modified`, original preserved in the
  description) and the morning message must lead with the why. PLAN.md's M4
  exit test ("HRV tanks → coach pulls a workout"), delivered in M5.
- **One-tap check-ins** under the coach card (✅ / 😮‍💨 / 🤕) post straight to
  chat and feed the engagement score; planned workouts grew an "Ask the coach
  about this" shortcut. Week strip is fixed Sunday→Saturday.

## M6 — design pass + depth

- **Readable coach prose everywhere**: SwiftUI `Text` only parses Markdown in
  string *literals* — LLM replies (String variables) showed raw `**asterisks**`.
  `CoachProse` renders via `AttributedString(markdown:)` with
  `.inlineOnlyPreservingWhitespace` (keeps line breaks), body-size font, line
  spacing.
- **Bright theme**: light color scheme, white cards + soft shadows on a gray
  canvas, gradient wordmark instead of the plain title, new app icon (GPS
  route motif — `swift scripts/make-app-icon.swift`).
- **Plan tab**: race countdown + goal, **equivalent race times** from current
  VDOT (5K/10K/Half/Marathon — the parked race-time predictor, deterministic),
  upcoming weeks day-by-day with the coach's rationale, generate button.
- **Run detail**: tap a run → type chip (auto-classified vs VDOT zones:
  easy/steady/tempo/speed/long), big stats, **GPS route map** (HKWorkoutRoute →
  MapKit polyline; empirically answers whether Runkeeper writes routes),
  notes editor.
- **Trends: "Coach's read"** — on-demand 2–4 sentence commentary on the charts
  (`POST /api/coach/trends-review`, stored as kind `weekly_review`).
- Quick check-in buttons removed (felt cheap); chat + "Ask coach" entry points
  remain.

## M12 — no Mac: HealthKit without the native app

**Why.** The custom app needs a free-account provisioning profile re-minted
every 7 days from a Mac with a live Xcode Apple ID. Ben's work Mac is
Jamf-managed (`exwzd.jamfcloud.com`) with a policy literally named **"Find
AppleID signedin users"** running on every ~15-minute check-in; it removes the
Xcode account within days. `refresh-app.sh` failed **108 times in a row** on
`error: No Accounts`, and the proof it's a real removal rather than a launchd
quirk is in the log: a *manual* run also failed, and only succeeded two
minutes later after an interactive Xcode re-login.

Rather than fight a security control on a company machine, the phone stops
being a build target:

| Was | Now |
|---|---|
| Native SwiftUI app, re-signed weekly | **Web app on the home screen** (`pb_public`, never expires) |
| `HealthKitService.swift` → server | **App Store HealthKit exporter** → `POST /api/health/ingest` |
| Mac + Xcode + Apple ID in the loop | Nothing but the phone and the Pi |

`health_ingest.js` maps the exporter's JSON onto the **same** `runs` +
`recovery_daily` rows the phone wrote, preserving every semantic the engine
depends on: `healthkit_uuid` stays the dedupe key (so rows the old app
uploaded are recognised, never duplicated), `runs.date` is a true instant
while `recovery_daily.date` is a local day label, and sleep is filed under the
**wake day** exactly as `HealthKitService.swift` did it.

### Server setup (once)

```bash
openssl rand -hex 24                      # generate the ingest token
# add to the CANONICAL env file (the service reads only this one):
sudo sh -c 'echo HEALTH_INGEST_TOKEN=<token> >> /opt/pain-enjoyer/.env'
# keep the convenience copy in sync so the test scripts see it too:
echo HEALTH_INGEST_TOKEN=<token> >> ~/pain-enjoyer/server/.env
./scripts/deploy-server.sh ben@192.168.1.236   # ships the hook + web files
```

With no `HEALTH_INGEST_TOKEN` set the route returns **503** — it never stands
open. A token shorter than 16 chars is refused for the same reason.

### Phone setup — option A: Apple Shortcuts (free)

Health Auto Export is only free for 7 days, so this is the default path.
Shortcuts ships on every iPhone and the endpoint accepts a **flat shape** you
can build with a single Dictionary action:

```json
{"date":"2026-08-22","hrv":45.2,"rhr":48,"sleep":7.1,"vo2max":51.4,"weight":70}
```

**Shortcut 1 — daily recovery** (≈12 actions, no loops):

1. For each of Heart Rate Variability, Resting Heart Rate, VO₂ Max, Weight
   (and Sleep if your Health has it):
   - **Find Health Samples** → Type = the metric, Start Date = *today*
   - **Calculate Statistics** → Average → over those samples
   - **Set Variable** → `hrv` / `rhr` / `vo2max` / `weight` / `sleep`
2. **Format Date** → Current Date, custom format `yyyy-MM-dd` → variable `day`
3. **Dictionary** → `date`=`day`, `hrv`, `rhr`, `sleep`, `vo2max`, `weight`
   (omit any key you don't have — a partial post never nulls what's already
   stored)
4. **Get Contents of URL**
   - URL `https://coach.bennpc.uk/api/health/ingest?token=<token>`
   - Method **POST**, Headers `Content-Type: application/json`
   - Request Body **JSON** → the Dictionary from step 3
5. Shortcuts → **Automation** → *Time of Day*, daily (e.g. 08:00), and turn
   **Ask Before Running off** so it fires unattended.

Units in this shape: **weight in kg, sleep in hours, HRV in ms** (no `units`
field — the exporter path is the one that converts lb/ms).

**Shortcut 2 — workouts.** First check whether your Shortcuts app has a
**Find Workouts** action (search "workout" in the action list — availability
depends on iOS version). If it does: *Repeat with Each* workout, build a
Dictionary, and POST one per iteration — posting is idempotent, so one call
per workout is fine:

```json
{"workout":{"id":"<workout UUID>","activity":"Running",
            "start":"2026-08-22 06:30:00 +0800",
            "duration_s":2400,"distance_m":8000,
            "avg_hr":146,"max_hr":171,"elevation_gain_m":42}}
```

The `workout` wrapper is optional — a bare flat object works too. Here
`distance_m`/`duration_s`/`avg_hr`/`max_hr` are already in the schema's units,
so nothing is converted. `id` is what makes re-posts idempotent: use the
workout's UUID if you can get it; without one a key is synthesised from the
start instant, which still dedupes but won't match rows the old native app
uploaded.

> ⚠ If your Shortcuts build has **no** workout action, recovery metrics still
> work (they're plain quantity samples) but runs have no free automated path —
> the options are a one-time-purchase exporter (HealthFit, RunGap) or adding
> manual run entry to the web app, which it doesn't have yet.

### Phone setup — option B: Health Auto Export (paid after the trial)

Same endpoint, no Shortcut to build. New Automation → type **REST API**:

- URL `https://coach.bennpc.uk/api/health/ingest?token=<token>`
  (the query param is the compatible-everywhere option; `X-Ingest-Token:` and
  `Authorization: Bearer` headers work too if your build supports them)
- Method **POST**, `Content-Type: application/json`
- Export **Workouts** *and* **Health Metrics**
- Metrics: Heart Rate Variability, Resting Heart Rate, Sleep Analysis,
  VO₂ Max, Weight & Body Mass
- Schedule: hourly or daily — posting is **idempotent**, so overlap is free
- First export: widen the date range (180 days) once to backfill, then drop
  back to a rolling window

### Then, either way

Safari → `https://coach.bennpc.uk` → Share → **Add to Home Screen**. It
launches standalone (no browser chrome) and never expires.

Runs still reach the server the same way they always did — Runkeeper writes
them to Apple Health, and the exporter forwards them. That path is untouched.

### Reading the response

Every post returns a report instead of a bare 200, so a partial import is
loud rather than silent:

```json
{"runs_created":2,"runs_duplicate":1,"runs_unusable":1,
 "recovery_created":1,"recovery_updated":0,"days_seen":1,
 "ignored_metrics":["step_count"]}
```

- `runs_duplicate` — already on the server by `healthkit_uuid`. Expected on
  every repeat post; not a problem.
- `runs_unusable` — no distance or no duration. `distance_m`/`duration_s` are
  `required` in the schema and PocketBase rejects 0, which is also why
  strength/yoga sessions never landed from the native app either.
- `ignored_metrics` — sent by the exporter, not mapped here (steps, energy…).
  If a metric you *want* shows up in this list, its name changed upstream and
  the alias table in `health_ingest.js` needs it.

The endpoint accepts three shapes so a paid exporter and a free Shortcut can
both post: the exporter's nested `{data:{workouts,metrics}}`, a flat daily
recovery row, and a single flat workout.

Smoke test: `./scripts/test-health-ingest-local.sh` (28 checks — auth, unit
conversion, dedupe, wake-day sleep, partial upsert, both flat shapes, engine
integration, PWA).

### What this gives up

Honest list — both were native-only:

- **GPS route maps** on run detail (`HKWorkoutRoute`, M6). Exporters don't
  send route data and the web app can't read HealthKit.
- **Per-km splits** (M7 Phase 4 durability score). The exporter has no split
  payload, so `runs.splits` stays null on new rows; the score degrades
  gracefully and old rows keep theirs.

Everything else — program, calendar, trends, chat, notes, effort, weight,
recovery — is already at parity in the web app.

## Provider flip (dev → real season)

In `server/.env`: set `LLM_PROVIDER=claude` and `ANTHROPIC_API_KEY=...`, then
`sudo cp server/.env /opt/pain-enjoyer/.env && sudo systemctl restart pain-enjoyer`.
Nothing else changes.

## Deploying hook/migration changes to the Pi

```bash
scp server/pb_hooks/* ben@<pi>:pain-enjoyer/server/pb_hooks/
ssh ben@<pi> "sudo cp pain-enjoyer/server/pb_hooks/* /opt/pain-enjoyer/pb_hooks/ && sudo systemctl restart pain-enjoyer"
```

### PocketBase JSVM gotchas (cost us real debugging time)
- `routerAdd`/`cronAdd` handlers run in **fresh JSVM instances** — they cannot see
  top-level functions in the same `*.pb.js` file. Shared logic must live in a module
  (`coach.js`, `llm.js`) and be `require()`d **inside** each handler.
- `.env` is sourced by bash — values with spaces (like cron expressions) **must be quoted**.
- Numbers sent to the LLM must be **pre-formatted strings** (e.g. `"5:47 min/km"`),
  or the model may mangle decimals into fake mm:ss (we got `5:79/km` from `5.79`).
