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
| `ios/` | SwiftUI app (XcodeGen project — needs a Mac to build) |

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

## M2 — the deterministic engine

Code computes, the LLM judges (PLAN.md §1). `server/pb_hooks/engine.js` derives,
from real history only:

- **VDOT + pace zones** (Daniels–Gilbert; best effort in 90 d; E/M/T/I/R paces)
- **ACWR** (7-day vs 28-day distance load; flags spike / detraining / no-base)
- **Recovery score 0–100** (today's HRV / resting HR / sleep vs personal 60-day median)
- **80/20 check** (share of running time at easy HR over 28 d)
- **🟢🟡🔴 traffic light** (worst severity wins; injured-flag in the profile pins it 🔴)

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
