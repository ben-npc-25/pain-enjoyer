# Pain Enjoyer — session context

Single-user AI marathon coach for Ben. Read `PLAN.md` first (design, data model,
milestones M0–M4) and `README.md` (runbook + hard-won gotchas). Be straight with
Ben; he's technical and cost-conscious (target ≈ $0).

## Status (2026-06-11)

- **M0 done & verified**: backend live, advice flows end-to-end through the public URL.
- **M1 built & deployed (2026-06-11)**: compiled clean (zero fixes needed),
  signed and installed on Ben's iPhone via `devicectl`, launches. Signing: free
  personal team `4YC3X253S5` ("ben Ng"), pinned as `DEVELOPMENT_TEAM` in
  `ios/project.yml` so xcodegen regens keep it (team ID = cert's **OU**, not
  the parenthetical in the cert name). Profiles expire every **7 days**
  (free account) — **automated**: launchd agent
  `com.benng.painenjoyer.refresh` re-signs + reinstalls Sun & Wed 21:00
  (`scripts/refresh-app.sh`, log `~/Library/Logs/pain-enjoyer-refresh.log`,
  macOS notification on outcome). Needs Mac awake + phone reachable; on
  failure run the script manually. Xcode Apple-ID session may occasionally
  need an interactive re-login (job fails loudly when so).
- **M1 closed 2026-06-11**: ① calendar ✓ ② field audit ✓ ③ background sync
  **waived by Ben (injured, not running)** — the observer + background
  delivery code is registered and compiles, but has never been observed
  end-to-end. To verify without running: add a manual *Running* workout in
  Apple Health (Browse → Activity → Workouts → Add Data) with the app closed;
  it must reach the server (source "Health"); then delete it from Health and
  run `./scripts/cleanup-test-data.sh`. Re-verify at return-to-run regardless
  — the weekly re-sign resets background delivery anyway.
- **Audit verdict (settles M2 sourcing)**: Runkeeper is the sole HealthKit
  source (15/15 runs), writes distance + HR on every run, elevation on none,
  all outdoor. → M2 computes VDOT/ACWR/80-20 from distance/duration/avg-HR;
  `elevation_gain_m` stays null from sync (manual entry covers it); recovery
  metrics (HRV/RHR/sleep/VO₂max) come from Watch/iPhone passive recording, not
  Runkeeper — verify they exist in Health when building the recovery score.
- **Ben is injured (as of 2026-06-11, return date unknown)** — no runs until
  further notice; last run in Health is 2026-05-27. Consequences: no fresh
  workouts will land (background sync unobservable in the wild), and ACWR's
  zero-acute / stale-history case is the *normal* state for now, not an edge
  case. M2 onboarding should ask about injury status and return-to-run
  timeline instead of assuming an active race block.
- **M2 done & verified (2026-06-11)**: engine deployed; exit test passed on
  real history — `VDOT 47.7` anchored to the **2026-03-28 marathon (42.2 km @
  4:42 min/km)**, 🟡 light (ACWR 0.00 detraining + 0% easy + stale zones), 77
  runs/180 d, recovery sync live (score 74, HRV present, **no sleep data**).
  Engine math also fixture-verified: `scripts/test-engine-local.sh` (14/14).
  Ben onboarded: race = Tokyo legacy half 2026-10-08; injured flag was left
  OFF (flip in profile → engine pins 🔴). `hr_max` unset → 80/20 uses an
  estimate (180) that classifies everything hard; set real HRmax to calibrate.
  Re-verify any time: `ssh ben@192.168.1.236 'cd ~/pain-enjoyer &&
  BASE_URL=http://127.0.0.1:8090 ./scripts/test-engine-live.sh'` (read-only).
- **M3 code complete + smoke-tested (2026-06-11), deploy = Ben's one-liner**:
  weekly plan generation with deterministic rails (`plan.js`: cap =
  chronic×1.15, phase from weeks-to-race, paces from `zones_sec`, injured →
  all-rest; sanitizer repairs rail-breaking LLM output and logs adjustments
  into the rationale), `POST /api/coach/plan-week` + Sunday 10:00 UTC cron
  (`COACH_PLAN_CRON_UTC`) + reconcile (morning cron and before each
  generation: run→done, miss→skipped, rest→done). Two-way **chat**
  (`POST /api/coach/chat`, roles in coach_messages), **runs.notes** in
  prompts. iOS: calendar overlay (type letters, status colors, 🏁 race day,
  future months), day detail planned-vs-actual + notes editor, chat sheet,
  "Plan next week" button. Local smoke (mock LLM, deliberately rail-breaking
  fixture): engine 14/14 + injured-rest + clamps + chat + reconcile all pass.
  iOS built clean + installed. **To finish**: `./scripts/deploy-server.sh
  ben@192.168.1.236`, then in-app "Plan next week" (expect an all-rest rehab
  week while injured) + a chat message round-trip.
- **M4 code complete + smoke-tested (2026-06-11), deploy = Ben's one-liner**:
  coach_memory distillation (`memory.js` — morning cron + POST
  /api/coach/distill; upsert-only, deletion = swipe in app; memory block
  appended to persona in all 5 prompt paths), traffic-light tone rules in
  persona (🔴 never prescribes running). UI overhaul: 4 tabs
  (Coach/Calendar/Trends/Chat), hero light card + week strip, Trends (Swift
  Charts: weekly km, HRV/RHR vs baseline, per-run effort VDOT), Memory
  screen, app icon (traffic light; `swift scripts/make-app-icon.swift`),
  accent color, haptics. Smoke: distill creates facts from mock + chat still
  flows with memory injected. iOS built + installed. NO new migration (M4
  uses M0's coach_memory collection). Deploy: `./scripts/deploy-server.sh
  ben@192.168.1.236`.
- **M5 done & deployed (2026-06-11)**: adaptive proactivity. `engagement.js`
  (ping/score/cadence: 14-d response+completion+opens → daily /
  every_2_3_days / weekly_digest, race ≤14 d forces daily, level persisted to
  profile), morning cron decides whether to speak (quiet days logged; cadence
  changes always acknowledged), `plan.pullTodayIfRed` converts today's
  planned non-rest to rest under 🔴 and the message leads with why. iOS:
  Sun→Sat week strip, one-tap check-ins (✅😮‍💨🤕 → chat), "Ask the coach about
  this" on planned workouts, app-open ping. Endpoints: POST /api/coach/ping,
  GET /api/coach/engagement. Verified live (ping + score). NOTE: cron-only
  behaviors (pull, cadence shifts) verify naturally at 06:00 HKT — pull needs
  a non-rest workout today + red light (test: injured OFF → plan week →
  injured ON → next morning).
- **M6 done & deployed (2026-06-11)**: design pass + depth. Coach prose was
  unreadable because SwiftUI Text doesn't parse markdown from String vars →
  `CoachProse` (AttributedString, inlineOnlyPreservingWhitespace). Light
  theme (white cards/shadows, gradient wordmark, route-motif icon), **Plan
  tab** (race countdown + VDOT-equivalent race times — predictor unparked —
  weeks w/ rationale), **run detail w/ GPS route map** (HKWorkoutRoute; also
  the empirical test of whether Runkeeper writes routes), run type chips
  (pace vs zones_sec), Trends "Coach's read" (`POST /api/coach/trends-review`
  → kind weekly_review). Quick check-in buttons removed (Ben: cheap).
- **Restructure (2026-06-11 evening, Ben's feedback)**: activity-first home
  (hero notice + latest-activity card; coach card removed — advice lives in
  chat via ✨ toolbar button), **fresh-slate chat** (UI shows last 24 h only;
  full history server-side, memory carries context), **blue theme** (accent +
  icon + wordmark; planned-workout color → orange), audit UI removed, Plan
  tab status surfaced top + spinner ("add plan not working" = invisible
  feedback; endpoint verified live 200), Trends = per-chart coach commentary
  (structured JSON weekly_review via `trends` LLM tier; `engine.trendFacts`)
  + VO₂max health chart. Quick check-ins removed earlier same day.
- **M8 built + tested (2026-07-03), deploy = Ben's one-liner**: the light is a
  dial, not a kill switch (Ben's feedback: "stopping me from my program is
  totally against this purpose"). Root cause of the stuck-red: Ben resumed
  running after ~a month off (hiking meanwhile) and ACWR compared 11.5 km
  acute to a collapsed 3.8 km/wk chronic → 2.99 "spike" → red → persona
  refused to prescribe running + pullTodayIfRed rested the day. Fixes:
  ① ACWR **"rebuilding" state** — chronic < 50% of the 180-d peak baseline
  while running again ⇒ judged vs the baseline (no flag if acute ≤ 60% of
  base, yellow `ramp_fast` above, never red); ② traffic light exports
  machine-readable `drivers`; ③ `pullTodayIfRed` → **`adaptTodayIfRed`**
  (red day = quality→E at half distance, never rest-cancel); ④ persona: red
  adapts the day, full stop only if the athlete reports pain/illness; ⑤ 80/20
  flags only at ≥5 runs w/ HR; ⑥ trajectory freezes negative-trend
  extrapolation while rebuilding (was projecting VDOT 40.6 fifteen weeks
  out); ⑦ **cross-training sync** — runs.activity_type (migration
  1783036800), iOS predicate widened (hike/walk/ride/swim/strength/yoga,
  anchor key bumped → v2 auto re-import backfills old hikes; server dedupe
  absorbs it), engine facts gain `cross_training`; running math, reconcile,
  and sheet backup stay running-only; ⑧ rebuilding weekly cap =
  min(old cap, max(acute×1.3, base×0.35)) — graduated without needing
  return_to_run_date; ⑨ iOS Hike/Ride chips, VDOT/volume charts filter to
  runs. Local suite extended (M8 section: an old-code-red fixture must be
  green; all pre-M8 sections still pass). iOS built + signed; install hung
  (iPhone unreachable at build time). **To finish**: ① `./scripts/deploy-server.sh
  ben@192.168.1.236`, ② `./scripts/refresh-app.sh --force` with the phone
  reachable, ③ re-verify with the read-only live engine test (expect
  rebuilding, not red) and open the app once so the widened sync backfills
  the hikes.
- **M9 built + tested (2026-07-03), deploy = Ben's one-liner — THE core
  feature (Ben: "the app is a marathon planner; everything builds around
  it")**: the goal-anchored **macro training block**. `macro.js` generates
  one deterministic program from today to race day (zero LLM): volume arc
  (+8%/wk, +15% while under 60% of base; every 4th week a 75% cutback;
  ceiling = weekly_target_km or 1.2× the 180-d baseline — volume from the
  ATHLETE, structure from the RACE), long-run curve (+2 km/wk marathon,
  capped at 38% of week volume, peak 32 km marathon / 18 km half), **final
  long run** = last pre-taper week (never a cutback), race-length **taper**
  (3 wk marathon / 1 wk half & below — Ben's call 2026-07-03; existing blocks
  need a rebuild tap to pick a taper change up). Persisted in `macro_weeks`
  (migration 1783123200, wiped+rewritten on regen). `POST
  /api/coach/macro-plan` (app button, announced as plan_change
  provider=engine); `macro.ensure()` re-anchors on Sunday cron + profile-save
  hook (missing / race moved / stale / drift >30% behind or >60% ahead), else
  leaves the block stable. Weekly generation now EXECUTES the block:
  `generateWeek` caps to min(reactive, block target), takes phase from it,
  clamps LR to the block's LR target (+20% tolerance), and the prompt carries
  the block slice (cutback/final-LR/race-week instructions).
  `engine.forLLM().training_block` puts "block week N of M …" in every
  prompt path; persona leads with "the program is the product." iOS: Plan
  tab renamed **Program** and is now the FIRST tab + app opens on it; block
  chart (bars colored by phase, dimmed cutbacks, 🏁 race week, flag on final
  LR, actual weekly km as points), "Build my program" button,
  week-N-of-M badge; profile save refetches the block. Suite: 15 sections /
  69 checks all pass (M9: structure, block→weekly integration, race-move
  re-anchor). **Deploy with M8's one-liner; install = unlock the phone first
  (it was reachable but locked — error 12040/10003).**
- **M9.1 (2026-07-03, Ben's field report)**: re-planning erased his week —
  `run_days` was set to days that excluded Fri/Sat/Sun, and the rail RESTED
  every misplaced workout → all-rest despite a 23 km block week. Fixes:
  ① run_days rail now **moves** workouts to free chosen days (LR relocates
  first), rests only when no slot remains; ② **block long-run guarantee** —
  if the plan lacks an LR, the block's LR target > 0, and no ≥80%-of-target
  run landed yet, the biggest planned day is upgraded to LR (or an eligible
  rest day claimed, preferring long_run_day), cap-safe, logged; ③ iOS: day
  descriptions no longer clipped at 3 lines ("…" complaint), plan-update
  status shortened (full rationale on the week card); ④ trends decode fix
  (client read `review` as String; server sends an object since M6.1);
  ⑤ pull-to-refresh no longer surfaces "✗ cancelled" (unstructured task).
  NOTE: Ben's profile run_days is now EMPTY (unclear if he cleared it) — if
  he re-sets it, include Saturday (his long_run_day). Suite: 16 sections
  incl. move + LR-guarantee asserts.
- **M9.2 (2026-07-03)**: self-calibration. ① **HRmax from observed peak HR**
  — iOS now uploads per-run `max_hr` (schema field existed, never filled) +
  one-time backfill of old rows (UserDefaults `runs.maxhr.backfill.v1`);
  engine's 80/20 ceiling = max observed + 2 when profile hr_max unset (the
  avg+8 guess made everything read "hard"/0% easy). ② **Benchmark week** —
  when the VDOT anchor is stale (>45 d) at block generation, the block
  schedules milestone `benchmark` (first ordinary week from week 4): one
  controlled 3 km steady effort to re-anchor zones + un-pause the race
  projection; surfaced in prompts, plan rules, block summary, and the chart
  (⏱). Ben's block needs a rebuild tap (↻) to pick the benchmark up. Suite:
  17 sections.
- **M10 built + tested (2026-07-03)**: health-coach layer (Ben: "a coach that
  also takes care of your health, nutrition opinions"). **Body weight** syncs
  daily (recovery_daily.body_mass_kg, migration 1783209600; iOS seed key
  bumped → recovery.seeded.v2 so the 60-day window backfills weight into
  existing rows once). Engine: `health_snapshot` (weight + ≥21-day trend) and
  `fueling_guidelines` — deterministic, weight-personalized strings (30–60 g
  carbs/h >75 min; post-session 0.3 g/kg protein + 1 g/kg carbs; race-week
  8–10 g/kg carb load) in every prompt; generic fallback when no weigh-ins.
  Persona: health section (reads HRV/RHR/sleep/VO₂max/weight as whole-person
  signals; fueling opinions quote ONLY provided figures; not-a-doctor rule
  for persistent anomalies). Weekly plan: long runs >75 min end with one
  fueling sentence. Trends: Weight chart (90 d) + "weight" key in the
  trends-review JSON. LLM cost: zero new calls. Needs weigh-ins in Apple
  Health to personalize (no scale data = generic ranges + a nudge). Suite:
  18 sections.
- **Web planner deployed & verified live (2026-07-06)**: `web/` — static SPA
  (vanilla JS + hand-rolled SVG, no build step) served from PocketBase's
  `pb_public` at `https://coach.bennpc.uk` — same origin, same users-collection
  login, same API as the phone, so sync is automatic and the shared Cloudflare
  tunnel was untouched. Tabs (deep-linkable via `/#calendar` etc.): Program
  (light hero, race countdown + VDOT race-time predictions, block chart,
  build/plan buttons), Calendar (planned vs actual, notes + effort editing),
  Trends (SVG charts + Coach's read), Chat (fresh-slate 24 h, ✨ advice);
  profile editor modal. Web opens count as engagement pings. deploy-server.sh
  now ships `web/` → `/opt/pain-enjoyer/pb_public`. Smoke:
  `./scripts/test-web-local.sh` (22 checks — static + login + every API call
  the page makes; `--serve` keeps it up for manual poking).
- **All PLAN.md milestones shipped** (+M8 adaptive light, +M9 macro block,
  +M10 health layer, +web planner).
  Parked still: taper specialization beyond the deterministic taper, Android,
  multi-user, auto-fetch race info from the web. UI polish is iterative from
  here.

## Infrastructure

| What | Where |
|---|---|
| Pi | `ssh ben@suisei.local` — or `ben@192.168.1.236` (mDNS doesn't resolve on some networks). User ben, passwordless sudo, arm64. sshd is **publickey-only** → `ssh-copy-id` can't bootstrap; paste new Macs' keys into `~/.ssh/authorized_keys` from an existing session. |
| Live backend | `/opt/pain-enjoyer` — PocketBase + systemd service `pain-enjoyer`, bound 127.0.0.1:8090 |
| Repo copy on Pi | `~/pain-enjoyer` (deploy = scp there → `sudo cp` into /opt → `systemctl restart pain-enjoyer`) |
| Public URL | `https://coach.bennpc.uk` (alias `run.bennpc.uk`) — probe `/api/coach/health` |
| Secrets | `server/.env` — gitignored, NOT on GitHub. **Canonical = `/opt/pain-enjoyer/.env` (root)**; `~/pain-enjoyer/server/.env` is a convenience copy for the test scripts (went missing once — restored 2026-06-11 via `sudo install -o ben -m 600`). |
| LLM | Gemini free tier now; flip = `LLM_PROVIDER=claude` + key in `.env`, restart (see README) |

## ⚠ Things that bite (details in README)

1. **Cloudflare tunnel is SHARED with Ben's homelab** (jellyfin/immich/photo/
   netflix/watchwhat) — one `cloudflared` service, homelab tunnel UUID
   `490ecdeb-…`, config `/etc/cloudflared/config.yml`. **Never overwrite that
   file — merge.** Route DNS only with explicit tunnel UUIDs (an ambient
   `~/.cloudflared/config.yml` hijacks name-based routing). We broke his homelab
   once this way.
2. PocketBase JSVM: handlers run in fresh VMs — shared logic must be
   `require()`d modules (`coach.js`, `llm.js`), never top-level functions in
   `*.pb.js`.
3. `.env` is bash-sourced — quote values with spaces (cron expressions).
   Also: the service reads ONLY `/opt/pain-enjoyer/.env` (`EnvironmentFile=`);
   editing `~/pain-enjoyer/server/.env` changes nothing live. And
   `APP_USER_EMAIL/PASS` only *seed* the account at setup — changing them
   later never touches the real PocketBase users record (bit Ben 2026-07-13;
   fixed by PATCHing the user via superuser, then syncing both .env copies).
4. Numbers going to the LLM must be pre-formatted strings ("5:47 min/km") —
   it once turned decimal 5.79 into "5:79/km".
5. Free Apple account: app install expires every 7 days; background sync dies
   silently with it. No remote push — coach messages are fetch-on-open.
   **The 7 days run from the profile's MINT date, not the install date** —
   Xcode reuses a still-valid cached profile on rebuild, so re-signing alone
   extends nothing (app died 2026-07-06 three days after a fresh install).
   `refresh-app.sh` now reads the embedded profile's ExpirationDate, deletes
   cached profiles pre-build to force a fresh mint, and fails loudly if the
   new profile has <3 days runway. Minting needs a live Xcode Apple-ID
   session — "No Accounts" in the log means Ben must re-login in Xcode →
   Settings → Accounts, then run `./scripts/refresh-app.sh --force`.
6. PB cron runs in **UTC** (`COACH_CRON_UTC`, default 22:00 UTC = 06:00 HKT).

## House rules

- Repo is the source of truth; Pi gets synced copies.
- **Commit + push to GitHub after each completed feature** (Ben's standing
  request, 2026-07-03) — one commit per feature, no need to ask.
- Don't put secrets in tracked files (`.env.example` is a sanitized template).
- Test e2e without the phone: `BASE_URL=https://coach.bennpc.uk ./scripts/test-e2e.sh`
  (then `./scripts/cleanup-test-data.sh` to remove the fake runs).
- Destructive infra ops (DNS, tunnel config, deleting tunnels): propose, let Ben run.
