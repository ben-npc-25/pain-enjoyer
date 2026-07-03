// engine.js — the deterministic spine (M2, PLAN.md §1).
//
// Code computes, the LLM judges. Everything here is arithmetic from the
// athlete's real history; nothing is ever asked of the LLM. Outputs carry both
// raw values (for the app) and pre-formatted strings (the ONLY form the LLM
// sees — gotcha #4: a raw 5.79 once became "5:79/km").
//
// MUST stay a require()'d module: PB runs each *.pb.js handler in a fresh JSVM.
//
// Daniels–Gilbert VDOT math, validated against the published VDOT-50 row:
//   5k 19:57 → VDOT 49.95 · T 4:15/km · M 4:31/km · I 3:55/km (all match).

// ── tiny helpers ────────────────────────────────────────────────────────

function parseDate(s) {
  // PB stores "2026-05-27 07:30:00.000Z"; goja's Date wants the T.
  return new Date(String(s).replace(" ", "T"));
}

function daysAgo(d, now) {
  return Math.floor((now.getTime() - d.getTime()) / 86400000);
}

function pbDate(d) {
  // Date → PB filter literal "2026-05-27 07:30:00.000Z"
  return d.toISOString().replace("T", " ").replace(/\.\d{3}Z$/, ".000Z");
}

function isoDay(d) {
  return d.toISOString().slice(0, 10);
}

function median(arr) {
  if (!arr.length) return null;
  const s = arr.slice().sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

function round(x, dp) {
  const f = Math.pow(10, dp || 0);
  return Math.round(x * f) / f;
}

function fmtPace(secPerKm) {
  // → "5:47" (unit appended by callers so ranges read "6:49–5:55 min/km")
  const m = Math.floor(secPerKm / 60);
  const s = Math.round(secPerKm % 60);
  if (s === 60) return (m + 1) + ":00";
  return m + ":" + (s < 10 ? "0" : "") + s;
}

function fmtKm(km) {
  return round(km, 1).toFixed(1) + " km";
}

// ── Daniels–Gilbert VDOT ────────────────────────────────────────────────

// VO2 cost of running at v m/min, and %VO2max sustainable for t minutes.
function vo2AtVelocity(v) {
  return -4.6 + 0.182258 * v + 0.000104 * v * v;
}

function pctVo2maxAt(tMin) {
  return (
    0.8 +
    0.1894393 * Math.exp(-0.012778 * tMin) +
    0.2989558 * Math.exp(-0.1932605 * tMin)
  );
}

function vdotForEffort(distanceM, durationS) {
  const tMin = durationS / 60;
  const v = distanceM / tMin; // m/min
  return vo2AtVelocity(v) / pctVo2maxAt(tMin);
}

// Invert the VO2 quadratic: velocity (m/min) that costs `vo2`.
function velocityForVo2(vo2) {
  const a = 0.000104, b = 0.182258, c = -(4.6 + vo2);
  return (-b + Math.sqrt(b * b - 4 * a * c)) / (2 * a);
}

function paceSecPerKmForFraction(vdot, frac) {
  return 60000 / velocityForVo2(vdot * frac); // (1000 m / v) * 60 s
}

// Training-zone intensities as fractions of VDOT (Daniels' tables, validated
// above). E is a range; the rest are single target paces.
const ZONE_FRACTIONS = {
  easy_low: 0.62,
  easy_high: 0.74,
  marathon: 0.815,
  threshold: 0.88,
  interval: 0.975,
  repetition: 1.05,
};

// ── data loading ────────────────────────────────────────────────────────

// Running only — VDOT/ACWR/80-20 are running-specific. Cross-training rows
// (M8: hikes, rides, …) live in the same collection but never enter run math.
function loadRuns(app, now, days) {
  const cutoff = pbDate(new Date(now.getTime() - days * 86400000));
  const recs = app.findRecordsByFilter(
    "runs",
    "date >= '" + cutoff + "' && (activity_type = '' || activity_type = 'running')",
    "-date",
    500,
    0
  );
  const runs = [];
  for (const r of recs) {
    const distM = r.getFloat("distance_m");
    const durS = r.getFloat("duration_s");
    if (!(distM > 0) || !(durS > 0)) continue;
    runs.push({
      date: parseDate(r.getString("date")),
      distM: distM,
      durS: durS,
      avgHr: r.getFloat("avg_hr") || null,
      maxHr: r.getFloat("max_hr") || null, // M9.2: observed peak HR (HRmax calibration)
      effort: r.getFloat("effort") || null, // M7 Phase 1: RPE 1–5, null if unrated
    });
  }
  return runs; // newest first
}

// M8: non-running activity (hiking, cycling, …) — evidence the athlete is
// active even when no runs land. Feeds the LLM facts + softens "detraining"
// judgments; deliberately kept OUT of the running math above.
function loadCrossTraining(app, now, days) {
  const cutoff = pbDate(new Date(now.getTime() - days * 86400000));
  const recs = app.findRecordsByFilter(
    "runs",
    "date >= '" + cutoff + "' && activity_type != '' && activity_type != 'running'",
    "-date",
    200,
    0
  );
  const byType = {};
  let count = 0;
  for (const r of recs) {
    const durS = r.getFloat("duration_s");
    if (!(durS > 0)) continue;
    const t = r.getString("activity_type");
    if (!byType[t]) byType[t] = { n: 0, km: 0, hours: 0 };
    byType[t].n++;
    byType[t].km += (r.getFloat("distance_m") || 0) / 1000;
    byType[t].hours += durS / 3600;
    count++;
  }
  if (!count) return { count: 0, summary: null };
  const parts = [];
  for (const t in byType) {
    const b = byType[t];
    let s = b.n + " " + t + (b.n > 1 ? " sessions" : " session") +
      " (" + round(b.hours, 1) + " h";
    if (b.km >= 1) s += ", " + fmtKm(b.km);
    s += ")";
    parts.push(s);
  }
  return {
    count: count,
    summary: parts.join(", ") + " in the last " + days + " days",
  };
}

function loadRecovery(app, now, days) {
  const cutoff = pbDate(new Date(now.getTime() - days * 86400000));
  const recs = app.findRecordsByFilter(
    "recovery_daily",
    "date >= '" + cutoff + "'",
    "-date",
    200,
    0
  );
  const rows = [];
  for (const r of recs) {
    rows.push({
      date: parseDate(r.getString("date")),
      hrv: r.getFloat("hrv_sdnn_ms") || null,
      rhr: r.getFloat("resting_hr") || null,
      sleep: r.getFloat("sleep_hours") || null,
      vo2max: r.getFloat("vo2max") || null,
    });
  }
  return rows; // newest first
}

function loadProfile(app) {
  const profs = app.findRecordsByFilter("athlete_profile", "id != ''", "-created", 1, 0);
  if (profs.length === 0) return null;
  const p = profs[0];
  return {
    race_name: p.getString("race_name") || null,
    race_date: p.getString("race_date") || null,
    goal_time_s: p.getFloat("goal_time_s") || null,
    days_per_week: p.getFloat("days_per_week") || null,
    long_run_day: p.getString("long_run_day") || null,
    run_days: p.getString("run_days") || null, // M7: "Monday,Wednesday,…" or null
    weekly_target_km: p.getFloat("weekly_target_km") || null, // M7: athlete volume target
    injured: p.getBool("injured"),
    injury_note: p.getString("injury_note") || null,
    return_to_run_date: p.getString("return_to_run_date") || null,
    hr_max: p.getFloat("hr_max") || null,
  };
}

// ── return-to-run ramp (M7 Phase 6) ─────────────────────────────────────
// A graduated comeback after injury. The recent ACWR chronic has decayed
// toward zero while hurt, so the ramp scales off a longer-memory baseline:
// the peak 28-day rolling weekly volume over the last 180 days ("pre-injury
// chronic"). The week containing return_to_run_date is ramp week 1; the
// window is 4 weeks. All engine math — the LLM only narrates it.

const RAMP_FACTORS = [0.3, 0.5, 0.7, 0.9]; // wk1 30% of baseline, +20%/wk after

// M7 Phase 1: effort (RPE) → pre-formatted string (gotcha #4 — never bare).
const EFFORT_LABELS = { 1: "very easy", 2: "easy", 3: "moderate", 4: "hard", 5: "max" };
function effortString(n) {
  const r = Math.round(n || 0);
  if (r < 1 || r > 5) return null;
  return r + "/5 (" + EFFORT_LABELS[r] + ")";
}

function mondayOf(d) {
  const u = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
  const back = (u.getUTCDay() + 6) % 7; // 0 Sun..6 Sat → days back to Monday
  return new Date(u.getTime() - back * 86400000);
}

// Established weekly volume that survives a training gap: the peak 28-day
// rolling average over the last 180 days. round(,1) for display parity.
function chronicBaselineKm(runs, now) {
  const DAYS = 180;
  const daily = new Array(DAYS).fill(0);
  for (const r of runs) {
    const d = daysAgo(r.date, now);
    if (d >= 0 && d < DAYS) daily[d] += r.distM / 1000;
  }
  let best = 0, windowSum = 0;
  for (let i = 0; i < DAYS; i++) {
    windowSum += daily[i];
    if (i >= 28) windowSum -= daily[i - 28];
    if (i >= 27 && windowSum / 4 > best) best = windowSum / 4; // full 28-day window
  }
  return round(best, 1);
}

// Which ramp week (1..4) `ref` (a Date) falls in, or null if outside the
// 4-week post-return window / no return date set.
function returnRampWeek(profile, ref) {
  if (!profile || !profile.return_to_run_date) return null;
  const rd = parseDate(profile.return_to_run_date);
  if (isNaN(rd.getTime())) return null;
  const weeksSince = Math.round(
    (mondayOf(ref).getTime() - mondayOf(rd).getTime()) / (7 * 86400000)
  );
  if (weeksSince < 0 || weeksSince > 3) return null;
  return weeksSince + 1;
}

// The ramp's rails for the week `ref` falls in, or null when not ramping.
// Single source of truth shared by forLLM (daily advice) and plan.js
// (next-week generation) so the cap + no-quality rule never drift.
function returnRampPlan(profile, ref, baselineKm) {
  const week = returnRampWeek(profile, ref);
  if (!week) return null;
  return {
    week: week,
    of: RAMP_FACTORS.length,
    no_quality: week <= 2, // all-easy for the first 2 weeks regardless of light
    cap_km: Math.max(0, Math.round((baselineKm || 0) * RAMP_FACTORS[week - 1])),
    baseline_km: round(baselineKm || 0, 1),
  };
}

// ── components ──────────────────────────────────────────────────────────

// VDOT = best (max) single-run VDOT in the window. Easy runs score low, so
// max() naturally finds real efforts without needing intent labels.
function computeVdot(runs, now) {
  // Reference fitness = the athlete's BEST effort over a long window (a year),
  // so a short layoff doesn't erase demonstrated fitness. Staleness is surfaced
  // separately (the traffic light flags an anchor >45 days old as optimistic),
  // and the coach trains by effort on easy days accordingly.
  const WINDOW = 365, MIN_M = 3000, MIN_S = 720;
  let best = null;
  for (const r of runs) {
    if (daysAgo(r.date, now) > WINDOW) continue;
    if (r.distM < MIN_M || r.durS < MIN_S) continue;
    const v = vdotForEffort(r.distM, r.durS);
    if (!best || v > best.vdot) best = { vdot: v, run: r };
  }
  if (!best) {
    return {
      available: false,
      reason: "no run ≥3 km in the last " + WINDOW + " days",
    };
  }
  const vdot = round(best.vdot, 1);
  // Raw sec/km per zone — the plan generator fills workout pace targets from
  // these (LLM never computes paces). Strings below are for display/LLM.
  const zonesSec = {
    easy_low: Math.round(paceSecPerKmForFraction(vdot, ZONE_FRACTIONS.easy_low)),
    easy_high: Math.round(paceSecPerKmForFraction(vdot, ZONE_FRACTIONS.easy_high)),
    marathon: Math.round(paceSecPerKmForFraction(vdot, ZONE_FRACTIONS.marathon)),
    threshold: Math.round(paceSecPerKmForFraction(vdot, ZONE_FRACTIONS.threshold)),
    interval: Math.round(paceSecPerKmForFraction(vdot, ZONE_FRACTIONS.interval)),
    repetition: Math.round(paceSecPerKmForFraction(vdot, ZONE_FRACTIONS.repetition)),
  };
  const zones = {
    easy:
      fmtPace(paceSecPerKmForFraction(vdot, ZONE_FRACTIONS.easy_low)) +
      "–" +
      fmtPace(paceSecPerKmForFraction(vdot, ZONE_FRACTIONS.easy_high)) +
      " min/km",
    marathon: fmtPace(paceSecPerKmForFraction(vdot, ZONE_FRACTIONS.marathon)) + " min/km",
    threshold: fmtPace(paceSecPerKmForFraction(vdot, ZONE_FRACTIONS.threshold)) + " min/km",
    interval: fmtPace(paceSecPerKmForFraction(vdot, ZONE_FRACTIONS.interval)) + " min/km",
    repetition: fmtPace(paceSecPerKmForFraction(vdot, ZONE_FRACTIONS.repetition)) + " min/km",
  };
  const r = best.run;
  const paceStr = fmtPace(r.durS / (r.distM / 1000)) + " min/km";
  return {
    available: true,
    value: vdot,
    zones: zones,
    zones_sec: zonesSec,
    source_run: {
      date: isoDay(r.date),
      distance_km: round(r.distM / 1000, 2),
      pace: paceStr,
      days_ago: daysAgo(r.date, now),
    },
    summary:
      vdot +
      " (best effort: " +
      fmtKm(r.distM / 1000) +
      " @ " +
      paceStr +
      " on " +
      isoDay(r.date) +
      ", " +
      daysAgo(r.date, now) +
      " days ago)",
  };
}

// ACWR on distance: acute = last 7 days; chronic = 28-day total / 4.
//
// M8 comeback fix: after a training break the 28-day chronic collapses toward
// zero, so ANY resumption produces an absurd ratio (11.5 km against a 3.8 km/wk
// denominator once read as a 2.99 "danger spike" and pinned the light red for
// weeks). When the chronic has fallen below half the established baseline (the
// 180-day peak 28-day volume) and the athlete is running again, the state is
// "rebuilding": judged against the baseline, not the collapsed average.
function computeAcwr(runs, now, baselineKm) {
  let acuteKm = 0, chronicKm = 0;
  for (const r of runs) {
    const d = daysAgo(r.date, now);
    if (d < 0 || d >= 28) continue;
    chronicKm += r.distM / 1000;
    if (d < 7) acuteKm += r.distM / 1000;
  }
  const chronicWeekly = chronicKm / 4;
  const baseline = baselineKm || 0;
  const rebuilding = baseline >= 10 && chronicWeekly < 0.5 * baseline && acuteKm > 0;
  let state, ratio = null;
  if (rebuilding) {
    state = "rebuilding";
    if (chronicWeekly >= 3) ratio = round(acuteKm / chronicWeekly, 2);
  } else if (chronicWeekly < 3) {
    state = "no_base"; // < 3 km/wk average — a ratio would be noise
  } else {
    ratio = round(acuteKm / chronicWeekly, 2);
    state = acuteKm === 0 ? "detraining" : "ok";
  }
  return {
    state: state,
    ratio: ratio,
    acute_week_km: round(acuteKm, 1),
    chronic_weekly_km: round(chronicWeekly, 1),
    baseline_weekly_km: round(baseline, 1),
    summary:
      state === "rebuilding"
        ? fmtKm(acuteKm) + " in the last 7 days, rebuilding after a break — recent 28-day average is only " +
          fmtKm(chronicWeekly) + "/wk vs an established base of " + fmtKm(baseline) +
          "/wk, so the acute:chronic ratio is not meaningful right now; ramp gradually toward the base"
        : state === "no_base"
        ? "not enough history for a load ratio (" + fmtKm(chronicWeekly) + "/wk over 28 days)"
        : fmtKm(acuteKm) +
          " in the last 7 days vs " +
          fmtKm(chronicWeekly) +
          "/wk 28-day average — ACWR " +
          ratio.toFixed(2) +
          (state === "detraining" ? " (no runs this week)" : ""),
  };
}

// Recovery score 0–100: today's HRV / resting HR / sleep vs the athlete's own
// 60-day median baseline. Missing metrics just don't contribute.
function computeRecovery(rows, now) {
  if (!rows.length) {
    return { available: false, reason: "no recovery data synced yet" };
  }
  const latest = rows[0];
  if (daysAgo(latest.date, now) > 3) {
    return {
      available: false,
      reason: "latest recovery data is " + daysAgo(latest.date, now) + " days old",
    };
  }
  const base = {
    hrv: median(rows.map((r) => r.hrv).filter((x) => x > 0)),
    rhr: median(rows.map((r) => r.rhr).filter((x) => x > 0)),
    sleep: median(rows.map((r) => r.sleep).filter((x) => x > 0)),
  };
  const nBaseline = rows.length;
  if (nBaseline < 7) {
    return {
      available: false,
      reason: "building baseline (" + nBaseline + "/7 days of recovery data)",
    };
  }

  let score = 100;
  const parts = [];
  if (latest.hrv && base.hrv) {
    const ratio = latest.hrv / base.hrv;
    if (ratio < 1) score -= Math.min(40, (40 * (1 - ratio)) / 0.3);
    parts.push("HRV " + Math.round(latest.hrv) + " ms (baseline " + Math.round(base.hrv) + " ms)");
  }
  if (latest.rhr && base.rhr) {
    const delta = latest.rhr - base.rhr;
    if (delta > 0) score -= Math.min(30, 6 * delta);
    parts.push("resting HR " + Math.round(latest.rhr) + " bpm (baseline " + Math.round(base.rhr) + " bpm)");
  }
  if (latest.sleep && base.sleep) {
    const deficit = base.sleep - latest.sleep;
    if (deficit > 0.5) score -= Math.min(30, 12 * (deficit - 0.5));
    parts.push("sleep " + round(latest.sleep, 1) + " h (baseline " + round(base.sleep, 1) + " h)");
  }
  if (!parts.length) {
    return { available: false, reason: "recovery rows exist but carry no metrics" };
  }
  score = Math.max(0, Math.min(100, Math.round(score)));
  const band = score >= 65 ? "good" : score >= 40 ? "caution" : "poor";
  return {
    available: true,
    score: score,
    band: band,
    date: isoDay(latest.date),
    summary: "score " + score + "/100 (" + band + ") — " + parts.join("; "),
  };
}

// 80/20: share of running TIME at easy intensity over 28 days, classified by
// avg HR vs ~77% of HRmax (≈ the top of Seiler zone 1).
function computeIntensity(runs, profile, now) {
  const withHr = runs.filter(
    (r) => r.avgHr > 0 && daysAgo(r.date, now) < 28
  );
  if (withHr.length < 3) {
    return {
      available: false,
      reason: "fewer than 3 runs with heart rate in the last 28 days",
    };
  }
  let hrMax = profile && profile.hr_max > 120 ? profile.hr_max : null;
  let hrMaxNote;
  if (hrMax) {
    hrMaxNote = Math.round(hrMax) + " bpm (from profile)";
  } else {
    // M9.2: observed per-run PEAK HR is a far better ceiling than avg+8 —
    // the old estimate (avg-based 180) classified every run as hard.
    let maxObs = 0;
    for (const r of runs) if (r.maxHr > maxObs) maxObs = r.maxHr;
    if (maxObs > 120) {
      hrMax = maxObs + 2; // true max is at least the highest ever seen
      hrMaxNote = Math.round(hrMax) + " bpm (from observed run peak HR — set hr_max in profile to override)";
    } else {
      let maxAvg = 0;
      for (const r of runs) if (r.avgHr > maxAvg) maxAvg = r.avgHr;
      hrMax = maxAvg + 8; // avg-HR ceiling underestimates true max
      hrMaxNote = Math.round(hrMax) + " bpm (estimated from history — set hr_max in profile to fix)";
    }
  }
  const threshold = 0.77 * hrMax;
  let easyS = 0, totalS = 0;
  for (const r of withHr) {
    totalS += r.durS;
    if (r.avgHr <= threshold) easyS += r.durS;
  }
  const pctEasy = Math.round((100 * easyS) / totalS);
  return {
    available: true,
    pct_easy_time: pctEasy,
    runs_counted: withHr.length,
    hr_max_used: hrMaxNote,
    summary:
      pctEasy +
      "% of running time easy over the last 28 days (" +
      withHr.length +
      " runs, easy = avg HR ≤ " +
      Math.round(threshold) +
      " bpm, HRmax " +
      hrMaxNote +
      "; target ≥80%)",
  };
}

// ── goal trajectory (M7 Phase 5) ──────────────────────────────────────────
// Deterministic "can I hit my goal?" — no probabilities, just a gap + a trend.
// required VDOT = the forward Daniels–Gilbert math (vdotForEffort) applied to
// the goal race; trend = linear fit of best-effort VDOT over 120d, projected to
// race day. Status is honest: on_track / borderline (±1 VDOT) / off_track.

function raceDistanceM(profile) {
  const n = String(profile.race_name || "").toLowerCase();
  if (/half|21\.1|21\s?k/.test(n)) return 21097.5;
  if (/10\s?k/.test(n)) return 10000;
  if (/5\s?k/.test(n)) return 5000;
  // marathon coach: anything else (incl. "marathon"/"full"/blank) is the full
  return 42195;
}

function computeTrajectory(runs, profile, now, vdot, acwrState) {
  if (!profile || !profile.race_date || !profile.goal_time_s) {
    return { available: false, reason: "no race goal set (need a race date and goal time)" };
  }
  const race = parseDate(profile.race_date);
  const daysToRace = Math.round((race.getTime() - now.getTime()) / 86400000);
  if (daysToRace <= 0) return { available: false, reason: "race date is in the past" };

  const distM = raceDistanceM(profile);
  const requiredVdot = round(vdotForEffort(distM, profile.goal_time_s), 1);

  // Best-effort VDOT per 14-day bucket over the last 120d — bucket-max filters
  // out easy-run noise so the fit tracks fitness, not training mix.
  const WINDOW = 120, BUCKET = 14, MIN_M = 3000, MIN_S = 720;
  const buckets = {};
  for (const r of runs) {
    const da = daysAgo(r.date, now);
    if (da < 0 || da > WINDOW || r.distM < MIN_M || r.durS < MIN_S) continue;
    const v = vdotForEffort(r.distM, r.durS);
    const idx = Math.floor(da / BUCKET);
    if (!buckets[idx] || v > buckets[idx].v) buckets[idx] = { v: v, daysAgo: da };
  }
  const pts = Object.keys(buckets).map((k) => ({ x: -buckets[k].daysAgo, y: buckets[k].v }));
  if (pts.length < 2) {
    return { available: false, reason: "not enough quality efforts in the last 120 days to project a trend" };
  }

  // least-squares slope (VDOT per day); x = -daysAgo so time increases with x
  let sx = 0, sy = 0, sxx = 0, sxy = 0;
  for (const p of pts) { sx += p.x; sy += p.y; sxx += p.x * p.x; sxy += p.x * p.y; }
  const n = pts.length, denom = n * sxx - sx * sx;
  const slope = denom !== 0 ? (n * sxy - sx * sy) / denom : 0;

  // Trend clamped to a plausible ±2 VDOT/month — a short window's raw slope
  // extrapolated months out otherwise produces absurd projections.
  let trendPerMonth = round(slope * 30, 1);
  if (trendPerMonth > 2) trendPerMonth = 2;
  if (trendPerMonth < -2) trendPerMonth = -2;

  const currentVdot = vdot && vdot.available ? vdot.value : round((sy - slope * sx) / n, 1);
  const weeks = Math.round(daysToRace / 7);

  // M8: a break-then-comeback produces a negative slope that, extrapolated
  // months out, projects absurd decay ("40.6 by race day") — demotivating
  // nonsense once training has RESUMED. While rebuilding, freeze the
  // projection at current fitness and say the trend is paused. (True
  // detraining — still not running — keeps the honest decay projection.)
  if (acwrState === "rebuilding" && trendPerMonth < 0) {
    const diff0 = round(currentVdot - requiredVdot, 1);
    const status0 = diff0 > 1 ? "on_track" : diff0 < -1 ? "off_track" : "borderline";
    return {
      available: true,
      required_vdot: requiredVdot,
      current_vdot: currentVdot,
      trend_per_month: null,
      projected_vdot: currentVdot,
      weeks_to_race: weeks,
      status: status0,
      summary:
        "needs VDOT " + requiredVdot + " for the goal; currently " + currentVdot +
        " (" + weeks + " wks to race) — trend projection paused while rebuilding " +
        "after a break; it resumes once regular quality efforts return",
    };
  }

  const projectedVdot = round(currentVdot + trendPerMonth * (daysToRace / 30), 1);
  const diff = round(projectedVdot - requiredVdot, 1);
  const status = diff > 1 ? "on_track" : diff < -1 ? "off_track" : "borderline";

  return {
    available: true,
    required_vdot: requiredVdot,
    current_vdot: currentVdot,
    trend_per_month: trendPerMonth,
    projected_vdot: projectedVdot,
    weeks_to_race: weeks,
    status: status,
    summary:
      "needs VDOT " + requiredVdot + " for the goal; currently " + currentVdot +
      ", trending " + (trendPerMonth >= 0 ? "+" : "") + trendPerMonth + "/mo → projected " +
      projectedVdot + " by race day (" + weeks + " wks) — " + status.replace("_", " "),
  };
}

// ── training block (M9) ─────────────────────────────────────────────────
// The macro block's slice for the current week + the next milestones, read
// straight from macro_weeks (written by macro.js). null when no block exists
// (or pre-migration) — everything degrades to the old week-by-week behavior.

function loadMacroContext(app, now) {
  try {
    const rows = app.findRecordsByFilter("macro_weeks", "id != ''", "week_start", 200, 0);
    if (!rows.length) return null;
    const monday = isoDay(mondayOf(now));
    let current = null, position = 0, finalLr = null, raceWeek = null, taperStart = null;
    for (let i = 0; i < rows.length; i++) {
      const r = rows[i];
      if (r.getString("week_start").slice(0, 10) === monday) { current = r; position = i + 1; }
      if (r.getString("milestone") === "final_long_run") finalLr = r;
      if (r.getString("milestone") === "race_week") raceWeek = r;
      if (!taperStart && r.getString("phase") === "taper") taperStart = r;
    }
    if (!current) return null; // block stale/out of range — ensure() will fix it
    return {
      week_number: position,
      weeks_total: rows.length,
      phase: current.getString("phase"),
      target_km: current.getFloat("target_km"),
      long_run_km: current.getFloat("long_run_km"),
      quality_sessions: current.getFloat("quality_sessions"),
      is_cutback: current.getBool("is_cutback"),
      milestone: current.getString("milestone"),
      final_long_run: finalLr
        ? { week_start: finalLr.getString("week_start").slice(0, 10), km: finalLr.getFloat("long_run_km") }
        : null,
      taper_start: taperStart ? taperStart.getString("week_start").slice(0, 10) : null,
      race_week_start: raceWeek ? raceWeek.getString("week_start").slice(0, 10) : null,
    };
  } catch (_) {
    return null;
  }
}

// ── traffic light ───────────────────────────────────────────────────────
// Worst severity wins; ALL triggered reasons are reported so the LLM can
// explain the full picture, not just the loudest signal.

function computeTrafficLight(profile, vdot, acwr, recovery, intensity, lastRunDaysAgo, crossTraining) {
  const reasons = [];
  const drivers = []; // M8: machine-readable — lets code react to WHY, not just the color
  let severity = 0; // 0 green · 1 yellow · 2 red
  function flag(level, driver, msg) {
    reasons.push(msg);
    drivers.push(driver);
    if (level > severity) severity = level;
  }
  const xtrain = crossTraining && crossTraining.count > 0 ? crossTraining.summary : null;

  // M7: injury is intentionally NOT a traffic-light driver anymore — it's a
  // minor, contextual signal the coach weighs (surfaced via athlete_status),
  // not a hard rail that pins the light red. The light reflects load, recovery,
  // and intensity; the LLM decides how much the noted injury should matter.

  if (acwr.state === "rebuilding") {
    // M8: comeback weeks are judged against the established base, never the
    // collapsed 28-day average. Only ramping back too fast flags — a careful
    // return contributes green.
    if (acwr.acute_week_km > 0.6 * acwr.baseline_weekly_km) {
      flag(1, "ramp_fast",
        "ramping back fast after a break: " + fmtKm(acwr.acute_week_km) +
          " this week is already >60% of your " + fmtKm(acwr.baseline_weekly_km) +
          "/wk base — hold volume a week before building further");
    }
  } else if (acwr.state === "no_base") {
    flag(1, "no_base", "not enough recent history to judge training load");
  } else if (acwr.ratio > 1.5) {
    flag(2, "load_spike", "load spike: ACWR " + acwr.ratio.toFixed(2) + " (danger zone is >1.5)");
  } else if (acwr.ratio > 1.3) {
    flag(1, "load_climbing", "load climbing fast: ACWR " + acwr.ratio.toFixed(2) + " (sweet spot 0.8–1.3)");
  } else if (acwr.state === "detraining" || acwr.ratio < 0.8) {
    flag(1, "load_low",
      "load well below base (ACWR " +
        (acwr.ratio === null ? "n/a" : acwr.ratio.toFixed(2)) +
        ") — fitness is decaying; rebuild gradually when able" +
        (xtrain ? " (though cross-training is keeping you active: " + xtrain + ")" : "")
    );
  }

  if (recovery.available) {
    if (recovery.score < 40) {
      flag(2, "recovery_poor", "recovery is poor (" + recovery.score + "/100) — body is under strain");
    } else if (recovery.score < 65) {
      flag(1, "recovery_low", "recovery below normal (" + recovery.score + "/100)");
    }
  }

  // M8: 3 runs is too small a sample to scold about intensity discipline —
  // and during a rebuild every run being short/steep says nothing about 80/20.
  if (
    intensity.available &&
    intensity.pct_easy_time < 75 &&
    intensity.runs_counted >= 5 &&
    acwr.state !== "rebuilding"
  ) {
    flag(1, "intensity",
      "intensity discipline: only " +
        intensity.pct_easy_time +
        "% of time easy in 28 days (80/20 target ≥80%)"
    );
  }

  if (!vdot.available) {
    flag(1, "zones_missing", "no recent quality effort to anchor pace zones (" + vdot.reason + ")");
  } else if (vdot.source_run.days_ago > 45) {
    flag(1, "zones_stale", "pace zones anchored to a " + vdot.source_run.days_ago + "-day-old effort — treat as optimistic");
  }

  if (severity === 0) {
    reasons.push(
      acwr.state === "rebuilding"
        ? "rebuilding after a break at a sensible rate — recovery and ramp both look right"
        : "load, recovery, and intensity distribution all in normal ranges"
    );
  }
  const light = severity === 2 ? "red" : severity === 1 ? "yellow" : "green";
  const emoji = severity === 2 ? "🔴" : severity === 1 ? "🟡" : "🟢";
  return { light: light, emoji: emoji, reasons: reasons, drivers: drivers };
}

// ── public API ──────────────────────────────────────────────────────────

function computeEngineState(app) {
  const now = new Date();
  const profile = loadProfile(app);
  const runs = loadRuns(app, now, 365); // a year: enough to anchor the best-effort reference
  const recoveryRows = loadRecovery(app, now, 60);

  // M8: baseline first — the ACWR comeback logic needs it as its yardstick.
  const chronicBaseline = chronicBaselineKm(runs, now);
  const crossTraining = loadCrossTraining(app, now, 28);

  const vdot = computeVdot(runs, now);
  const acwr = computeAcwr(runs, now, chronicBaseline);
  const recovery = computeRecovery(recoveryRows, now);
  const intensity = computeIntensity(runs, profile, now);

  let km28 = 0;
  for (const r of runs) if (daysAgo(r.date, now) < 28) km28 += r.distM / 1000;
  const lastRun = runs.length ? runs[0] : null;
  const lastRunDaysAgo = lastRun ? daysAgo(lastRun.date, now) : null;
  const history = {
    runs_180d: runs.length,
    km_28d: round(km28, 1),
    last_run: lastRun
      ? isoDay(lastRun.date) + " (" + lastRunDaysAgo + " days ago)"
      : "no runs in the last 180 days",
  };

  const trafficLight = computeTrafficLight(
    profile, vdot, acwr, recovery, intensity, lastRunDaysAgo, crossTraining
  );

  // M7 Phase 6: this-moment return-to-run ramp state (baseline computed above).
  const returnRamp = returnRampPlan(profile, now, chronicBaseline);

  // M7 Phase 5: goal trajectory (required vs projected VDOT).
  const trajectory = computeTrajectory(runs, profile, now, vdot, acwr.state);

  // M9: where this week sits in the macro training block (null = no block).
  const macroWeek = loadMacroContext(app, now);

  return {
    computed_at: now.toISOString(),
    profile: profile,
    vdot: vdot,
    acwr: acwr,
    recovery: recovery,
    intensity: intensity,
    history: history,
    last_run_effort: lastRun && lastRun.effort ? lastRun.effort : null, // M7 Phase 1
    cross_training: crossTraining, // M8: non-running activity, 28 days
    chronic_baseline_km: chronicBaseline,
    return_ramp: returnRamp, // null unless actively ramping back
    goal_trajectory: trajectory, // M7 Phase 5
    macro_week: macroWeek, // M9: this week's slice of the training block
    traffic_light: trafficLight,
  };
}

// Projection for the LLM: every value a pre-formatted STRING (gotcha #4).
// This is the ONLY view of the engine a prompt may embed.
function forLLM(state) {
  const f = {
    traffic_light:
      state.traffic_light.emoji +
      " " +
      state.traffic_light.light.toUpperCase() +
      " — " +
      state.traffic_light.reasons.join("; "),
    training_load: state.acwr.summary,
    history:
      state.history.runs_180d +
      " runs in 180 days, " +
      fmtKm(state.history.km_28d) +
      " in the last 28; last run " +
      state.history.last_run,
  };
  f.current_vdot = state.vdot.available ? state.vdot.summary : "unknown — " + state.vdot.reason;
  if (state.vdot.available) {
    f.pace_zones =
      "easy " + state.vdot.zones.easy +
      ", marathon " + state.vdot.zones.marathon +
      ", threshold " + state.vdot.zones.threshold +
      ", interval " + state.vdot.zones.interval +
      ", repetition " + state.vdot.zones.repetition;
  }
  if (state.last_run_effort) {
    f.last_run_effort = "athlete rated the most recent run's effort " + effortString(state.last_run_effort);
  }
  if (state.cross_training && state.cross_training.count > 0) {
    f.cross_training =
      "non-running activity (does not count toward running load, but the athlete " +
      "is staying active): " + state.cross_training.summary;
  }
  f.recovery = state.recovery.available ? state.recovery.summary : "unknown — " + state.recovery.reason;
  f.intensity_8020 = state.intensity.available ? state.intensity.summary : "unknown — " + state.intensity.reason;
  if (state.profile) {
    f.athlete_status = state.profile.injured
      ? "INJURED" +
        (state.profile.injury_note ? " (" + state.profile.injury_note + ")" : "") +
        (state.profile.return_to_run_date
          ? ", target return " + String(state.profile.return_to_run_date).slice(0, 10)
          : "")
      : "healthy";
    if (state.profile.race_name || state.profile.race_date) {
      f.race_goal =
        (state.profile.race_name || "race") +
        (state.profile.race_date ? " on " + String(state.profile.race_date).slice(0, 10) : "");
    }
  }
  if (state.goal_trajectory && state.goal_trajectory.available) {
    f.goal_trajectory = state.goal_trajectory.summary;
  }
  if (state.macro_week) {
    const m = state.macro_week;
    let s =
      "block week " + m.week_number + " of " + m.weeks_total + " (" + m.phase + ") — " +
      "target " + fmtKm(m.target_km) + ", long run ~" + fmtKm(m.long_run_km) +
      ", " + m.quality_sessions + " quality session" + (m.quality_sessions === 1 ? "" : "s");
    if (m.is_cutback) s += "; CUTBACK week (deliberately easier — recovery is the point)";
    if (m.milestone === "benchmark") {
      s += "; BENCHMARK week — one controlled 3 km steady effort (strong but not " +
        "all-out) to re-anchor pace zones and the race projection";
    }
    if (m.milestone === "final_long_run") s += "; FINAL LONG RUN of the block this week";
    if (m.milestone === "race_week") {
      s += "; RACE WEEK";
    } else {
      const thisMon = isoDay(mondayOf(new Date()));
      if (m.final_long_run && m.final_long_run.week_start > thisMon) {
        s += ". Final long run ~" + fmtKm(m.final_long_run.km) + " week of " + m.final_long_run.week_start;
      }
      if (m.taper_start && m.taper_start > thisMon) {
        s += "; taper starts week of " + m.taper_start;
      }
    }
    f.training_block = s + ". Coach toward executing this block.";
  }
  if (state.return_ramp) {
    const r = state.return_ramp;
    f.return_to_run =
      "post-injury comeback ramp — week " + r.week + " of " + r.of +
      ", volume capped at " + fmtKm(r.cap_km) + " this week (off a " +
      fmtKm(r.baseline_km) + "/wk pre-injury baseline)" +
      (r.no_quality
        ? "; EASY RUNNING ONLY, no quality (no tempo/interval/rep/marathon-pace) yet"
        : "; easy-biased, ease quality back in") +
      ". A 🟢 light here does NOT mean push — respect the ramp.";
  }
  return f;
}

// M6.1: compact, pre-formatted trend summaries for the per-chart coach
// commentary (deterministic — the LLM only interprets these).
function trendFacts(app) {
  const now = new Date();
  const runs = loadRuns(app, now, 60);
  const rec = loadRecovery(app, now, 90);

  const weeks = [0, 0, 0, 0]; // 7-day buckets back from today
  for (const r of runs) {
    const idx = Math.floor(daysAgo(r.date, now) / 7);
    if (idx >= 0 && idx < 4) weeks[idx] += r.distM / 1000;
  }
  const weeklyStr = weeks.slice().reverse().map(function (k) { return round(k, 1); })
    .join(", ") + " km (oldest week → this week)";

  function avg(arr) {
    return arr.length ? arr.reduce(function (a, b) { return a + b; }, 0) / arr.length : null;
  }
  const hrv7 = avg(rec.filter(function (r) { return r.hrv > 0 && daysAgo(r.date, now) < 7; }).map(function (r) { return r.hrv; }));
  const hrvMed = median(rec.map(function (r) { return r.hrv; }).filter(function (x) { return x > 0; }));
  const rhr7 = avg(rec.filter(function (r) { return r.rhr > 0 && daysAgo(r.date, now) < 7; }).map(function (r) { return r.rhr; }));
  const rhrMed = median(rec.map(function (r) { return r.rhr; }).filter(function (x) { return x > 0; }));
  const vo2s = rec.filter(function (r) { return r.vo2max > 0; }); // newest first
  const vo2New = vo2s.length ? vo2s[0] : null;
  const vo2Old = vo2s.length > 1 ? vo2s[vo2s.length - 1] : null;

  return {
    weekly_volume_last_4: weeklyStr,
    hrv: hrv7 && hrvMed
      ? Math.round(hrv7) + " ms 7-day avg vs " + Math.round(hrvMed) + " ms 90-day median"
      : "no HRV data yet",
    resting_hr: rhr7 && rhrMed
      ? Math.round(rhr7) + " bpm 7-day avg vs " + Math.round(rhrMed) + " bpm 90-day median"
      : "no resting-HR data yet",
    vo2max: vo2New
      ? round(vo2New.vo2max, 1) + " ml/kg/min on " + isoDay(vo2New.date) +
        (vo2Old ? " (vs " + round(vo2Old.vo2max, 1) + " on " + isoDay(vo2Old.date) + ")" : "")
      : "no VO2max data yet",
  };
}

module.exports = {
  computeEngineState: computeEngineState,
  forLLM: forLLM,
  trendFacts: trendFacts,
  returnRampPlan: returnRampPlan, // M7 Phase 6: shared by plan.js
  raceDistanceM: raceDistanceM, // M9: macro.js sizes the block by race distance
  // exposed for the smoke test
  _vdotForEffort: vdotForEffort,
  _paceSecPerKmForFraction: paceSecPerKmForFraction,
  _chronicBaselineKm: chronicBaselineKm,
  _returnRampWeek: returnRampWeek,
};
