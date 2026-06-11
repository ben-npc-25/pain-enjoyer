# Pain Enjoyer — AI Marathon Coach (POC)

> Plan finalized 2026-06-11. Single-user POC for Ben. Fresh build — nothing reused from the prior Firebase app.

## Decisions (locked)

| Decision | Choice | Why |
|---|---|---|
| Platform | Native iOS, SwiftUI | Apple Watch data lives in HealthKit; best sync fidelity |
| Data source | HealthKit only | Runkeeper + Watch + most running apps all write to HealthKit — one integration covers all |
| Backend | **PocketBase on Raspberry Pi + Cloudflare Tunnel** | True $0, no credit card, data in one SQLite file at home; PB gives auth + REST + admin UI + JS hooks + cron in one Go binary |
| AI | **Provider-agnostic `LLM` interface on the Pi** (key server-side only). Dev/POC: **Gemini Developer API free tier** — $0, no card, ~10 RPM / 250 req/day vs our ~34 calls/mo. Real training block: flip one config to **Claude** (Haiku 4.5 daily + Sonnet 4.6 weekly ≈ $0.26/mo → ~$5/yr, since prepaid credits expire after 12 months) | Verified: Claude subscriptions (incl. Team) do NOT include API access — API is separate prepaid credits. Gemini free tier may use inputs/outputs for training; Anthropic API doesn't train on data by default — that privacy upgrade is part of the Claude flip |
| Methodology | **Hybrid: Daniels VDOT engine + 80/20 guardrail + LLM free-flow inside the rails** | Paces are computed, never hallucinated; 80/20 enforced from real HR data; LLM does judgment/personality. Methodology is a profile setting — switchable later |
| Apple account | **Free for POC, upgrade to $99/yr if it sticks** | Accepts: app re-sign from Xcode every 7 days (background sync dies silently when provisioning lapses), no remote push. Proactive coach uses **local notifications + fetch-on-open** for now; push layer abstracted so paid APNs is a config swap later |
| Cost target | **$0.00 during dev**; ~$5/yr once flipped to Claude | Firebase backend eliminated: Spark blocks outbound calls from Functions to non-Google APIs AND can't run scheduled functions (morning-coach cron needs Blaze + card); the Pi crons for free |

## Core architecture principle

**Deterministic spine, LLM judgment.** Code computes: VDOT + pace zones (from real HealthKit efforts), ACWR load ratio, recovery score (HRV/resting-HR/sleep vs personal baseline), 80/20 distribution check, and a 🟢🟡🔴 push/pull traffic light. The LLM receives those facts (never raw logs) and decides: weekly plan narrative, adaptations, tone, when to push/pull and how to say it.

```
HealthKit ─► iOS app (SwiftUI, local mirror) ─► Pi: PocketBase (SQLite, auth, REST)
                                                  │ nightly cron + on-sync hook
                                                  ▼
                                       Deterministic engine ─► 🟢🟡🔴
                                                  ▼
                              persona + coach_memory + computed facts
                                                  ▼
                       LLM interface (dev: Gemini free → later: Claude)
                                                  ▼
                              advice · plan updates · check-ins
```

## Coach brain

- **coach_memory**: cheap distillation call after notable interactions extracts durable facts ("overreaches when motivated", "wants data not pep talk") → injected into every prompt. Compounds over months.
- **Push/pull**: traffic light from HRV trend vs personal baseline, RHR drift, sleep, ACWR (sweet spot 0.8–1.3, danger >1.5). LLM gets light + numbers, personality-adjusts delivery.
- **Adaptive proactivity**: engagement score (check-in response rate + workout completion, 14-day window) drives cadence daily → every 2–3 days → weekly digest. Coach acknowledges the downshift, never silently ghosts. Auto re-escalates on re-engagement and always during taper/race week.
- **Prompting**: persona + profile kept byte-stable as a cacheable prefix (caching off for single user — calls outlive cache TTL — but free to enable at scale). Volatile data (date, today's metrics) after the prefix.

## Data model (PocketBase collections)

```
athlete_profile   race goal/date, methodology, constraints(days/wk, long-run day),
                  personality_json, proactivity_level
runs              date, distance_m, duration_s, avg/max HR, splits[], cadence,
                  elevation, source_app, matched_workout_id
recovery_daily    date, hrv_sdnn, resting_hr, sleep_hours, vo2max
plan_weeks        week_idx, phase(base|build|peak|taper), rationale
planned_workouts  date, type(E|T|I|R|MP|LR), target_pace_range, distance,
                  description, status(planned|done|skipped|modified)
coach_messages    role, content, kind(daily|weekly_review|plan_change|feedback)
coach_memory      fact, confidence, learned_from, last_reinforced
engagement        date, opens, checkin_responded, workout_completed
```

Calendar = join of `runs` ⟂ `planned_workouts` (planned vs actual per day) — same view the coach reasons over.

## Milestones

| | Name | Delivers | Exit test |
|---|---|---|---|
| M0 | Walking skeleton | Xcode project · PocketBase on Pi · tunnel (Tailscale or CF) · `LLM` interface (Gemini provider first) · thinnest end-to-end slice | Phone reads 1 HealthKit run → Pi → LLM → advice on screen (backend half provable via `scripts/test-e2e.sh` without the phone) |
| M1 | Base building | HealthKit observer + background delivery, local mirror, calendar UI, manual-entry fallback, **Runkeeper field audit** | Run with watch → appears on calendar without opening app first |
| M2 | The engine | VDOT/ACWR/recovery computations + onboarding (race, date, constraints) | True VDOT + traffic light computed from real history |
| M3 | Race plan | Weekly plan generation (Sonnet), plan-vs-actual overlay, daily check-in (Haiku) | A generated week you'd actually run |
| M4 | The coach knows you | coach_memory, traffic-light-aware advice, adaptive proactivity | Skip 3 check-ins → cadence drops; HRV tanks → coach pulls a workout |

Parked for later: route maps, race-time predictor, taper specialization, injury flags, Android/Health Connect, multi-user.

## Risks & rituals

1. **7-day provisioning expiry (free Apple account)** — background sync dies silently weekly. Ritual: re-deploy from Xcode each week, or upgrade to $99/yr (also unlocks APNs push + TestFlight). Push layer is abstracted so the upgrade is config, not rework.
2. **HealthKit completeness varies by source app** — Runkeeper may write distance/duration but spotty HR/route. M1 field audit answers this empirically; manual-entry covers gaps.
3. **iOS background delivery is opportunistic** — fine for daily-cadence coaching; don't expect instant sync.
4. **Pi ops** — SSD boot or nightly automated SQLite backup off-device (set up in M0); home-internet downtime acceptable for one user.
5. **Pricing drift** — Claude prices verified 2026-06 against official docs; re-check (incl. minimum credit purchase) when flipping providers.
6. **Gemini free-tier privacy** — during dev, coach calls carry real HRV/sleep/run data and Google may use free-tier data for training. If that bothers you mid-dev, test with mock athlete data; the Claude flip removes the concern entirely.
7. **Tunnel prerequisite (discovered at M0)** — a *named* Cloudflare Tunnel requires a domain you own on Cloudflare. No domain → use **Tailscale Serve** instead ($0, stable `*.ts.net` HTTPS URL, ATS-compliant; phone runs the free Tailscale app). Both paths scripted in `server/setup-pi.sh tunnel`.
