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

function loadRuns(app, now, days) {
  const cutoff = pbDate(new Date(now.getTime() - days * 86400000));
  const recs = app.findRecordsByFilter(
    "runs",
    "date >= '" + cutoff + "'",
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
    });
  }
  return runs; // newest first
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
    injured: p.getBool("injured"),
    injury_note: p.getString("injury_note") || null,
    return_to_run_date: p.getString("return_to_run_date") || null,
    hr_max: p.getFloat("hr_max") || null,
  };
}

// ── components ──────────────────────────────────────────────────────────

// VDOT = best (max) single-run VDOT in the window. Easy runs score low, so
// max() naturally finds real efforts without needing intent labels.
function computeVdot(runs, now) {
  const WINDOW = 90, MIN_M = 3000, MIN_S = 720;
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
function computeAcwr(runs, now) {
  let acuteKm = 0, chronicKm = 0;
  for (const r of runs) {
    const d = daysAgo(r.date, now);
    if (d < 0 || d >= 28) continue;
    chronicKm += r.distM / 1000;
    if (d < 7) acuteKm += r.distM / 1000;
  }
  const chronicWeekly = chronicKm / 4;
  let state, ratio = null;
  if (chronicWeekly < 3) {
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
    summary:
      state === "no_base"
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
    let maxAvg = 0;
    for (const r of runs) if (r.avgHr > maxAvg) maxAvg = r.avgHr;
    hrMax = maxAvg + 8; // avg-HR ceiling underestimates true max
    hrMaxNote = Math.round(hrMax) + " bpm (estimated from history — set hr_max in profile to fix)";
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

// ── traffic light ───────────────────────────────────────────────────────
// Worst severity wins; ALL triggered reasons are reported so the LLM can
// explain the full picture, not just the loudest signal.

function computeTrafficLight(profile, vdot, acwr, recovery, intensity, lastRunDaysAgo) {
  const reasons = [];
  let severity = 0; // 0 green · 1 yellow · 2 red
  function flag(level, msg) {
    reasons.push(msg);
    if (level > severity) severity = level;
  }

  if (profile && profile.injured) {
    flag(2,
      "athlete is marked INJURED" +
        (profile.return_to_run_date
          ? " (target return " + String(profile.return_to_run_date).slice(0, 10) + ")"
          : "") +
        (profile.injury_note ? " — " + profile.injury_note : "") +
        " — no running load until cleared"
    );
  }

  if (acwr.state === "no_base") {
    flag(1, "not enough recent history to judge training load");
  } else if (acwr.ratio > 1.5) {
    flag(2, "load spike: ACWR " + acwr.ratio.toFixed(2) + " (danger zone is >1.5)");
  } else if (acwr.ratio > 1.3) {
    flag(1, "load climbing fast: ACWR " + acwr.ratio.toFixed(2) + " (sweet spot 0.8–1.3)");
  } else if (acwr.state === "detraining" || acwr.ratio < 0.8) {
    flag(1,
      "load well below base (ACWR " +
        (acwr.ratio === null ? "n/a" : acwr.ratio.toFixed(2)) +
        ") — fitness is decaying; rebuild gradually when able"
    );
  }

  if (recovery.available) {
    if (recovery.score < 40) {
      flag(2, "recovery is poor (" + recovery.score + "/100) — body is under strain");
    } else if (recovery.score < 65) {
      flag(1, "recovery below normal (" + recovery.score + "/100)");
    }
  }

  if (intensity.available && intensity.pct_easy_time < 75) {
    flag(1,
      "intensity discipline: only " +
        intensity.pct_easy_time +
        "% of time easy in 28 days (80/20 target ≥80%)"
    );
  }

  if (!vdot.available) {
    flag(1, "no recent quality effort to anchor pace zones (" + vdot.reason + ")");
  } else if (vdot.source_run.days_ago > 45) {
    flag(1, "pace zones anchored to a " + vdot.source_run.days_ago + "-day-old effort — treat as optimistic");
  }

  if (severity === 0) {
    reasons.push("load, recovery, and intensity distribution all in normal ranges");
  }
  const light = severity === 2 ? "red" : severity === 1 ? "yellow" : "green";
  const emoji = severity === 2 ? "🔴" : severity === 1 ? "🟡" : "🟢";
  return { light: light, emoji: emoji, reasons: reasons };
}

// ── public API ──────────────────────────────────────────────────────────

function computeEngineState(app) {
  const now = new Date();
  const profile = loadProfile(app);
  const runs = loadRuns(app, now, 180);
  const recoveryRows = loadRecovery(app, now, 60);

  const vdot = computeVdot(runs, now);
  const acwr = computeAcwr(runs, now);
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
    profile, vdot, acwr, recovery, intensity, lastRunDaysAgo
  );

  return {
    computed_at: now.toISOString(),
    profile: profile,
    vdot: vdot,
    acwr: acwr,
    recovery: recovery,
    intensity: intensity,
    history: history,
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
  // exposed for the smoke test
  _vdotForEffort: vdotForEffort,
  _paceSecPerKmForFraction: paceSecPerKmForFraction,
};
