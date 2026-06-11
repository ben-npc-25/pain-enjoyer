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
- **M2 code complete (2026-06-11), deploy pending one SSH key**: engine
  (`server/pb_hooks/engine.js`: VDOT/zones/ACWR/recovery/80-20/🟢🟡🔴) +
  `GET /api/coach/engine` + engine facts in every coach prompt; iOS onboarding
  (person icon: race, constraints, injured flag, HRmax), traffic-light card,
  recovery sync (60-d backfill → rolling 7-d upsert). Engine math verified
  locally: `scripts/test-engine-local.sh` = 14/14 vs hand-computed fixtures.
  iOS build compiled clean + installed on the phone. **Blocked**: this Mac's
  key isn't on the Pi (`ssh-copy-id ben@192.168.1.236` — mDNS for
  `suisei.local` doesn't resolve here; that LAN IP is the Pi). Then:
  `./scripts/deploy-server.sh ben@192.168.1.236` and the M2 exit test
  `BASE_URL=https://coach.bennpc.uk ./scripts/test-engine-live.sh` (read-only,
  no cleanup). In-app: onboarding auto-appears (no profile row yet) — set
  injured=ON.

## Infrastructure

| What | Where |
|---|---|
| Pi | `ssh ben@suisei.local` (user ben, passwordless sudo, arm64). New Mac? `ssh-copy-id` first. |
| Live backend | `/opt/pain-enjoyer` — PocketBase + systemd service `pain-enjoyer`, bound 127.0.0.1:8090 |
| Repo copy on Pi | `~/pain-enjoyer` (deploy = scp there → `sudo cp` into /opt → `systemctl restart pain-enjoyer`) |
| Public URL | `https://coach.bennpc.uk` (alias `run.bennpc.uk`) — probe `/api/coach/health` |
| Secrets | `server/.env` — gitignored, NOT on GitHub. Canonical copy on the Pi (`~/pain-enjoyer/server/.env` and `/opt/pain-enjoyer/.env`). |
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
