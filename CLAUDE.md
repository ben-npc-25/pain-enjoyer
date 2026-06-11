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
  the parenthetical in the cert name). Xcode-managed profile + install expire
  **2026-06-18** (7-day free account) — re-deploy weekly.
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
- **M4 next**: coach_memory distillation (chat thread is now the raw
  material), adaptive proactivity from engagement, traffic-light-aware
  morning advice tone.

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
4. Numbers going to the LLM must be pre-formatted strings ("5:47 min/km") —
   it once turned decimal 5.79 into "5:79/km".
5. Free Apple account: app install expires every 7 days; background sync dies
   silently with it. No remote push — coach messages are fetch-on-open.
6. PB cron runs in **UTC** (`COACH_CRON_UTC`, default 22:00 UTC = 06:00 HKT).

## House rules

- Repo is the source of truth; Pi gets synced copies.
- Don't put secrets in tracked files (`.env.example` is a sanitized template).
- Test e2e without the phone: `BASE_URL=https://coach.bennpc.uk ./scripts/test-e2e.sh`
  (then `./scripts/cleanup-test-data.sh` to remove the fake runs).
- Destructive infra ops (DNS, tunnel config, deleting tunnels): propose, let Ben run.
