# 🏃 Pain Enjoyer

Single-user AI marathon coach. Apple Watch / Runkeeper runs sync via HealthKit to a
PocketBase backend on a Raspberry Pi; a provider-agnostic LLM layer (Gemini free tier
for dev → Claude for the real training block) turns computed training facts into
coaching advice. Full design: [PLAN.md](PLAN.md).

```
iPhone (SwiftUI + HealthKit) ──HTTPS (tunnel)──► Raspberry Pi
                                                   └─ PocketBase (SQLite, auth, REST)
                                                       ├─ pb_migrations/  schema
                                                       └─ pb_hooks/       /api/coach/advise + cron → LLM
```

## Repo layout

| Path | What |
|---|---|
| `server/` | Everything that runs on the Pi: setup script, PocketBase migrations + hooks |
| `scripts/test-e2e.sh` | Simulated phone: pushes a fake run, requests advice — proves the whole slice without the iOS app |
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

### 3. Prove the slice (no phone needed)
```bash
BASE_URL=https://<your-tunnel-host> ./scripts/test-e2e.sh
# → prints coaching advice generated from a fake run. M0 backend exit test ✔
```

### 4. iOS app (needs a Mac)
```bash
cd ios && brew install xcodegen && xcodegen   # generates PainEnjoyer.xcodeproj
```
Open in Xcode, set your team (free personal team works), run on your iPhone.
First launch: enter server URL + the app user credentials from `server/.env`,
grant HealthKit access, tap **Sync latest run → Coach**.

> Free Apple account: the install expires every **7 days** — re-run from Xcode weekly.
> (Documented as risk #1 in PLAN.md; $99/yr removes it.)

## Provider flip (dev → real season)

In `server/.env`: set `LLM_PROVIDER=claude` and `ANTHROPIC_API_KEY=...`, restart the
service. Nothing else changes.
