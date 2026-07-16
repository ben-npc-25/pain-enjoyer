// macro.js — M9: the goal-anchored training block. THE spine of the app.
//
// Ben's directive (2026-07-03): the app is a marathon PLANNER. Set the race,
// get a structured program from today to race day — how volume builds, when
// the cutback weeks land, how the long run grows without breaking the
// athlete, when the final long run happens, when the taper starts. The
// week-by-week generation (plan.js) executes INSIDE this block and exists for
// minor adjustment; the block is the product.
//
// 100% deterministic — no LLM anywhere in here (cost: zero). The LLM only
// ever narrates the block via engine.forLLM()'s training_block fact.
//
// Principles:
//   volume comes from the ATHLETE (history/ceiling), structure from the RACE
//   (taper length, long-run peak, quality emphasis). Reality re-anchors the
//   block (ensure() regenerates on drift/race change); the block disciplines
//   the week (plan.js caps to it).
//
// MUST stay a require()'d module (fresh-JSVM rule). Requires plan.js for the
// shared week math — one direction only; plan.js reads macro_weeks rows
// directly and never requires this file.

function isoDay(d) {
  return d.toISOString().slice(0, 10);
}

function round1(x) {
  return Math.round(x * 10) / 10;
}

// ── the block algorithm ─────────────────────────────────────────────────

// Growth: +8%/wk normally, +15%/wk while still under 60% of the established
// base (a comeback rebuilds faster than new fitness is built). Every 4th week
// is a cutback at 75% (the growth line itself doesn't advance that week).
// Long run: +2 km/wk toward the race-distance peak, never above 38% of the
// week's volume, pulled back 25% on cutback weeks. Taper: race-distance
// length, fractions of peak volume. Final long run = last pre-taper week.

const TAPER_FRACTIONS = {
  3: [0.7, 0.55, 0.4],
  2: [0.65, 0.45],
  1: [0.5],
};

// completedWeeks (M11): how many weeks of this SAME program already happened.
// A mid-program rebuild continues the block — cutback cadence and benchmark
// placement count from the program's true start, and the summary says
// "continuing at week N", never "week 1" again.
function buildWeeks(state, profile, engine, plan, now, completedWeeks) {
  const completed = completedWeeks || 0;
  const race = new Date(String(profile.race_date).replace(" ", "T"));
  const thisMonday = plan._mondayOf(now);
  const raceMonday = plan._mondayOf(race);
  const n = Math.round((raceMonday.getTime() - thisMonday.getTime()) / (7 * 86400000)) + 1;
  if (n < 1) return { error: "race date is in the past" };

  const distM = engine.raceDistanceM(profile);
  const raceLabel =
    distM >= 42000 ? "marathon" : distM >= 21000 ? "half marathon" : distM >= 10000 ? "10K" : "5K";
  // Ben's call (2026-07-03): 1-week taper is enough for a half and below.
  // Marathon keeps the classic 3 — revisit when he races a full.
  let taperN = distM >= 42000 ? 3 : 1;
  if (taperN > n - 1) taperN = Math.max(1, n - 1);

  const baseline = state.chronic_baseline_km || 0;
  const rampNow = engine.returnRampPlan(profile, thisMonday, baseline);
  // Week 1 starts where the athlete actually IS (same math as the weekly cap).
  const seed = Math.max(plan._weeklyCapKm(state, profile, rampNow), 10);
  // Volume ceiling is the athlete's, not the race's: their explicit weekly
  // target if set, else 20% above the established base (progressive overload
  // across a block, no more).
  const ceiling =
    profile.weekly_target_km > 0
      ? profile.weekly_target_km
      : Math.max(Math.round(baseline * 1.2), seed, 20);
  const lrPeakByRace = distM >= 42000 ? 32 : distM >= 21000 ? 18 : distM >= 10000 ? 12 : 10;
  const lrStep = distM >= 42000 ? 2 : 1.5;

  const finalLrIdx = n - 1 - taperN; // last pre-taper week (<0 → arc is all taper)
  const weeks = [];
  let vol = seed;
  let lr = Math.max(4, Math.round(seed * 0.3));
  let peakVol = seed, peakLr = lr, cutbacks = 0;

  for (let i = 0; i < n; i++) {
    const monday = new Date(thisMonday.getTime() + i * 7 * 86400000);
    const weeksToRace = n - 1 - i;
    const isRace = i === n - 1;
    const inTaper = i > finalLrIdx;
    const ramp = engine.returnRampPlan(profile, monday, baseline);

    let phase, target, lrKm, quality, cutback = false, milestone = "";

    if (inTaper) {
      phase = "taper";
      const fr = TAPER_FRACTIONS[taperN] || TAPER_FRACTIONS[1];
      const tIdx = Math.min(i - (finalLrIdx + 1), fr.length - 1);
      target = Math.max(5, Math.round(peakVol * fr[tIdx]));
      lrKm = isRace ? 0 : Math.round(peakLr * 0.55);
      quality = isRace ? 0 : 1;
      if (isRace) milestone = "race_week";
    } else {
      // cutback cadence counts from the PROGRAM start, not from this rebuild
      cutback = (i + completed) % 4 === 3 && i !== finalLrIdx;
      if (i > 0 && !cutback) {
        const grow = baseline > 0 && vol < 0.6 * baseline ? 1.15 : 1.08;
        vol = Math.min(vol * grow, ceiling);
      }
      let t = cutback ? vol * 0.75 : vol;
      if (ramp) t = Math.min(t, ramp.cap_km); // explicit return-to-run governs
      target = Math.round(t);

      if (i > 0 && !cutback) lr = Math.min(lr + lrStep, lrPeakByRace, 0.38 * vol);
      lrKm = Math.round(cutback ? lr * 0.75 : lr);
      if (ramp) lrKm = Math.min(lrKm, Math.round(target * 0.3));

      phase = weeksToRace <= taperN + 3 ? "peak" : weeksToRace <= 16 ? "build" : "base";
      quality = ramp && ramp.no_quality ? 0 : phase === "base" ? 1 : 2;
      if (cutback) { quality = Math.min(quality, 1); cutbacks++; }
      if (i === finalLrIdx) milestone = "final_long_run";
      if (target > peakVol) peakVol = target;
      if (lrKm > peakLr) peakLr = lrKm;
    }

    weeks.push({
      week_idx: plan._weekIdx(monday),
      week_start: isoDay(monday),
      phase: phase,
      target_km: target,
      long_run_km: lrKm,
      quality_sessions: quality,
      is_cutback: cutback,
      milestone: milestone,
    });
  }

  // M9.2→M11.1: the block schedules a BENCHMARK — one controlled 3 km steady
  // effort — when the zones anchor is stale/missing OR the athlete's current
  // anchor sits well below their demonstrated peak (the comeback gap): a
  // controlled test shows where fitness really is and re-anchors the race
  // projection. Deterministic placement: first ordinary week (no cutback,
  // has a quality slot, no other milestone) from program week 4 onward.
  const staleVdot =
    !state.vdot.available ||
    (state.vdot.source_run && state.vdot.source_run.days_ago > 45) ||
    (state.vdot.reference && state.vdot.reference.vdot - state.vdot.value > 3);
  if (staleVdot) {
    // "from week 4" counts PROGRAM weeks: a rebuild of a program that's already
    // 4+ weeks old may benchmark immediately (the reset used to push it out
    // forever — stale zones then kept the light yellow indefinitely).
    const firstEligible = Math.max(0, 3 - completed);
    for (let i = firstEligible; i < finalLrIdx; i++) { // short blocks skip it
      const w = weeks[i];
      if (!w.is_cutback && w.quality_sessions > 0 && !w.milestone) {
        w.milestone = "benchmark";
        break;
      }
    }
  }

  const finalLr = finalLrIdx >= 0 ? weeks[finalLrIdx] : null;
  const benchmark = weeks.find(function (w) { return w.milestone === "benchmark"; }) || null;
  const summary =
    (completed > 0
      ? "program re-anchored at week " + (completed + 1) + " of " + (completed + n) + " — "
      : "") +
    n + "-week block to " + (profile.race_name || "the race") + " (" + raceLabel + "): " +
    "volume " + Math.round(seed) + "→" + Math.round(peakVol) + " km/wk with " +
    cutbacks + " cutback week" + (cutbacks === 1 ? "" : "s") + "; " +
    (benchmark
      ? "benchmark effort week of " + benchmark.week_start + " to re-anchor your pace zones; "
      : "") +
    (finalLr
      ? "final long run ~" + finalLr.long_run_km + " km week of " + finalLr.week_start + "; "
      : "") +
    taperN + "-week taper into race day " + isoDay(race) + ".";

  return { weeks: weeks, summary: summary, peak_km: Math.round(peakVol), taper_weeks: taperN };
}

// ── persistence ─────────────────────────────────────────────────────────

function loadWeeks(app) {
  try {
    return app.findRecordsByFilter("macro_weeks", "id != ''", "week_start", 200, 0);
  } catch (_) {
    return [];
  }
}

// keepBeforeIso (M11): when set, rows for weeks BEFORE that Monday survive —
// the program's history is part of the program. null = full wipe (new race).
function persist(app, weeks, keepBeforeIso) {
  for (const rec of loadWeeks(app)) {
    if (keepBeforeIso && rec.getString("week_start").slice(0, 10) < keepBeforeIso) continue;
    app.delete(rec);
  }
  const col = app.findCollectionByNameOrId("macro_weeks");
  for (const w of weeks) {
    const rec = new Record(col);
    rec.set("week_idx", w.week_idx);
    rec.set("week_start", w.week_start + " 00:00:00.000Z");
    rec.set("phase", w.phase);
    rec.set("target_km", w.target_km);
    rec.set("long_run_km", w.long_run_km);
    rec.set("quality_sessions", w.quality_sessions);
    rec.set("is_cutback", w.is_cutback);
    rec.set("milestone", w.milestone);
    app.save(rec);
  }
}

// ── public API ──────────────────────────────────────────────────────────

// Generate (or regenerate) the whole block from today's reality. Returns
// { skipped, reason } when there's nothing to anchor to.
function generate(app, engine, plan) {
  const now = new Date();
  const state = engine.computeEngineState(app);
  const profile = state.profile;
  if (!profile || !profile.race_date) {
    return { skipped: true, reason: "no race set — the block anchors to a race date" };
  }

  // M11: a rebuild CONTINUES the program, it never restarts it. If the
  // existing block points at the same race, its completed weeks are history —
  // count them, keep their rows, and only regenerate from this week forward.
  // Only a race change starts a genuinely new program (full wipe).
  const thisMonday = plan._mondayOf(now);
  const thisMondayIso = isoDay(thisMonday);
  const raceMonday = plan._mondayOf(new Date(String(profile.race_date).replace(" ", "T")));
  let completed = 0;
  const rows = loadWeeks(app);
  if (rows.length && rows[rows.length - 1].getFloat("week_idx") === plan._weekIdx(raceMonday)) {
    for (const r of rows) {
      if (r.getString("week_start").slice(0, 10) < thisMondayIso) completed++;
    }
  }

  const built = buildWeeks(state, profile, engine, plan, now, completed);
  if (built.error) return { skipped: true, reason: built.error };
  persist(app, built.weeks, completed > 0 ? thisMondayIso : null);
  console.log("macro: block generated — " + built.summary);
  return {
    skipped: false,
    weeks: built.weeks,
    summary: built.summary,
    peak_km: built.peak_km,
    taper_weeks: built.taper_weeks,
  };
}

// Keep the block honest without churning it: regenerate ONLY when it's
// missing, the race moved, time ran past it, or reality drifted far from the
// current week's target (fell behind by >30% / ran ahead by >60%). Called by
// the Sunday cron and after profile saves. Quiet no-op otherwise.
function ensure(app, engine, plan) {
  const now = new Date();
  const state = engine.computeEngineState(app);
  const profile = state.profile;
  if (!profile || !profile.race_date) {
    // race removed → a stale block would coach toward nothing; clear it
    const rows = loadWeeks(app);
    for (const r of rows) app.delete(r);
    return { skipped: true, reason: "no race set", cleared: rows.length };
  }
  const rows = loadWeeks(app);
  const thisMonday = plan._mondayOf(now);
  const raceMonday = plan._mondayOf(new Date(String(profile.race_date).replace(" ", "T")));

  let reason = null;
  if (!rows.length) {
    reason = "no block yet";
  } else {
    const last = rows[rows.length - 1];
    if (last.getFloat("week_idx") !== plan._weekIdx(raceMonday)) {
      reason = "race date changed";
    } else {
      let current = null;
      for (const r of rows) {
        if (r.getFloat("week_idx") === plan._weekIdx(thisMonday)) { current = r; break; }
      }
      if (!current) {
        reason = "block does not cover this week";
      } else {
        const target = current.getFloat("target_km");
        const ramp = engine.returnRampPlan(profile, thisMonday, state.chronic_baseline_km);
        const cap = plan._weeklyCapKm(state, profile, ramp);
        if (target > 0 && (cap < 0.7 * target || cap > 1.6 * target)) {
          reason = "re-anchored to actual training (week target " + target +
            " km vs sustainable " + round1(cap) + " km)";
        }
      }
    }
  }
  if (!reason) return { regenerated: false };
  const r = generate(app, engine, plan);
  if (r.skipped) return { regenerated: false, reason: r.reason };
  return { regenerated: true, reason: reason, summary: r.summary };
}

module.exports = {
  generate: generate,
  ensure: ensure,
  // exposed for tests
  _buildWeeks: buildWeeks,
};
