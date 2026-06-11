# Pain Enjoyer — session context

Single-user AI marathon coach for Ben. Read `PLAN.md` first (design, data model,
milestones M0–M4) and `README.md` (runbook + hard-won gotchas). Be straight with
Ben; he's technical and cost-conscious (target ≈ $0).

## Status (2026-06-11)

- **M0 done & verified**: backend live, advice flows end-to-end through the public URL.
- **M1 code written, NEVER COMPILED** (was authored on a Windows machine):
  calendar UI, anchored HealthKit sync + background delivery, manual entry,
  HealthKit field audit. **First task on the Mac:** `cd ios && xcodegen`
  (required — new files + new `healthkit.background-delivery` entitlement),
  build, fix whatever the compiler finds, run on Ben's iPhone.
- **M1 exit tests**: ① calendar shows 180-day history → ② run the audit (ECG
  icon) and read what fields Runkeeper actually writes (decides M2 sourcing) →
  ③ record a real run WITHOUT opening the app; it must appear on the server.
- **M2 next**: deterministic engine (VDOT from real efforts, ACWR, recovery
  score, 🟢🟡🔴 traffic light) + onboarding (race goal). LLM never computes
  numbers — code computes, LLM judges (PLAN.md §1).

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
