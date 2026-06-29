// plan.js — M3 weekly plan generation. require()'d module (fresh-JSVM rule).
//
// Division of labor (PLAN.md §1): CODE decides the rails — weekly distance
// cap, training phase, pace targets from VDOT zones, the injured override —
// and validates/sanitizes whatever the LLM proposes. The LLM decides the
// judgment — which days, which workout types, how to describe them, and the
// week's rationale. A malformed or rail-breaking LLM response is repaired
// deterministically, never re-asked (cost-conscious; adjustments are logged
// into the rationale).

const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const TYPES = ["E", "T", "I", "R", "MP", "LR", "rest"];

function isoDay(d) {
  return d.toISOString().slice(0, 10);
}

// Monday 00:00 UTC of the week AFTER the one containing `now`.
function nextMonday(now) {
  const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const dow = d.getUTCDay(); // 0 Sun … 6 Sat
  const daysUntil = ((8 - dow) % 7) || 7; // always strictly in the future
  d.setUTCDate(d.getUTCDate() + daysUntil);
  return d;
}

// week_idx = ISO-ish yearweek int (e.g. 202625) — unique + sortable.
function weekIdx(monday) {
  const jan1 = new Date(Date.UTC(monday.getUTCFullYear(), 0, 1));
  const week = Math.floor((monday.getTime() - jan1.getTime()) / (7 * 86400000)) + 1;
  return monday.getUTCFullYear() * 100 + week;
}

function phaseFor(weeksToRace) {
  if (weeksToRace === null) return "base";
  if (weeksToRace <= 3) return "taper";
  if (weeksToRace <= 6) return "peak";
  if (weeksToRace <= 16) return "build";
  return "base";
}

// The deterministic weekly distance cap the LLM must plan inside.
// `ramp` is engine.returnRampPlan(...) for the week being planned, or null.
function weeklyCapKm(state, profile, ramp) {
  // M7: injury no longer zeroes the week — it's a soft signal the coach weighs.
  // The return-to-run ramp (an explicit return date) still governs the cap.
  if (ramp) return ramp.cap_km; // M7 Phase 6: graduated return-to-run cap
  const chronic = state.acwr.chronic_weekly_km || 0;
  if (chronic < 3) return 15; // no base — conservative starter volume
  return Math.round(chronic * 1.15); // ≤ ~ACWR 1.15: inside the 0.8–1.3 sweet spot
}

function pacesForType(type, zonesSec) {
  if (!zonesSec || type === "rest") return { low: null, high: null };
  switch (type) {
    case "E":
    case "LR":
      return { low: zonesSec.easy_high, high: zonesSec.easy_low }; // faster..slower
    case "MP":
      return { low: Math.round(zonesSec.marathon * 0.98), high: Math.round(zonesSec.marathon * 1.02) };
    case "T":
      return { low: Math.round(zonesSec.threshold * 0.98), high: Math.round(zonesSec.threshold * 1.02) };
    case "I":
      return { low: Math.round(zonesSec.interval * 0.97), high: Math.round(zonesSec.interval * 1.03) };
    case "R":
      return { low: Math.round(zonesSec.repetition * 0.97), high: Math.round(zonesSec.repetition * 1.03) };
    default:
      return { low: null, high: null };
  }
}

// M7 Phase 3: distance-based workout rail. Ben never counts minutes — reps
// must be prescribed as distance ("6 × 600m"), never time. The planner/replan
// prompts ask for it; this sanitizes any time-based prescription the LLM still
// emits, converting rep duration × zone pace → distance rounded to 100 m.
const ZONE_FOR_TYPE = { I: "interval", R: "repetition", T: "threshold", MP: "marathon" };

function distanceifyDescription(type, description, zonesSec) {
  if (!zonesSec || !ZONE_FOR_TYPE[type] || !description) {
    return { description: description, repaired: false };
  }
  const pace = zonesSec[ZONE_FOR_TYPE[type]]; // sec per km
  if (!(pace > 0)) return { description: description, repaired: false };
  let repaired = false;
  const out = String(description).replace(
    /(\d+(?:\.\d+)?)\s*(minutes?|mins?|seconds?|secs?|['’]|")/gi,
    function (_m, num, unit) {
      const u = unit.toLowerCase();
      const isSec = u.charAt(0) === "s" || u === '"';
      const timeSec = parseFloat(num) * (isSec ? 1 : 60);
      let dm = Math.round(((timeSec / pace) * 1000) / 100) * 100; // nearest 100 m
      if (dm < 100) dm = 100;
      repaired = true;
      return dm >= 1000 ? dm / 1000 + "km" : dm + "m";
    }
  );
  return {
    description: out,
    repaired: repaired,
    note: repaired ? type + " reps converted from time to distance (Ben trains by distance, not time)" : null,
  };
}

function buildPrompt(engineFacts, profile, weekDates, capKm, phase, weeksToRace, ramp, convo) {
  const constraints = {
    week_dates: weekDates,
    training_phase: phase,
    weeks_to_race: weeksToRace === null ? "no race set" : weeksToRace,
    weekly_distance_cap_km: capKm,
    days_per_week_max: (profile && profile.days_per_week) || 5,
    long_run_day: (profile && profile.long_run_day) || "Sunday",
    athlete_injured: !!(profile && profile.injured),
    return_to_run: ramp
      ? { ramp_week: ramp.week, of: ramp.of, easy_only: ramp.no_quality }
      : null,
  };
  return (
    "Plan the athlete's training for the dates listed in week_dates below (this " +
    "may be the rest of the current week, not a full 7 days). Today is " +
    new Date().toISOString().slice(0, 10) + ".\n\n" +
    "Deterministic engine state (all numbers pre-computed; do not recompute):\n" +
    JSON.stringify(engineFacts) + "\n\n" +
    (convo
      ? "Recent conversation with the athlete — honor any explicit requests they " +
        "made (e.g. 'make Saturday longer', 'I want more speedwork') wherever they " +
        "fit inside the hard constraints below:\n" + convo + "\n\n"
      : "") +
    "Hard constraints (the server enforces these mechanically afterwards — " +
    "violations get clamped, so plan inside them):\n" +
    JSON.stringify(constraints) + "\n\n" +
    "If athlete_injured is true: it's a noted niggle, not a stop sign — use your " +
    "judgment (the engine facts carry the detail). Adjust intensity/volume if it " +
    "seems wise, but you are not required to prescribe rest.\n\n" +
    "If return_to_run is present: this is a graduated comeback from injury. The " +
    "low distance cap is deliberate — do NOT exceed it, and a green light does " +
    "NOT mean push. When easy_only is true, every running day must be easy (type " +
    "E or LR) — no T/I/R/MP; the server forces this regardless.\n\n" +
    "Interval/threshold/rep workouts MUST be prescribed as DISTANCE reps " +
    "(e.g. \"6 × 600m\", \"3 × 2km\") — never time. Do not write minutes or " +
    "seconds in any workout description; the server rewrites time to distance.\n\n" +
    "Respond with STRICT JSON only (no markdown fences, no commentary):\n" +
    '{"rationale":"2-4 sentences on the week\'s intent",' +
    '"days":[{"date":"YYYY-MM-DD","type":"E|T|I|R|MP|LR|rest","distance_km":0,"description":"..."}]}' +
    "\nExactly one entry per date in week_dates, in order. Workout paces are " +
    "NOT yours to choose — the server attaches pace targets from the VDOT zones."
  );
}

function parsePlanJSON(text) {
  // tolerate ```json fences and stray prose around the object
  let t = String(text).trim();
  const fence = t.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (fence) t = fence[1].trim();
  const start = t.indexOf("{");
  const end = t.lastIndexOf("}");
  if (start === -1 || end <= start) throw new Error("plan LLM returned no JSON object");
  return JSON.parse(t.slice(start, end + 1));
}

// Repair the LLM's proposal into something rail-legal. Returns
// { days: [...7], rationale, adjustments: [strings] }.
function sanitizePlan(raw, weekDates, capKm, profile, opts) {
  const adjustments = [];
  const noQuality = !!(opts && opts.noQuality); // M7 Phase 6: return-to-run easy-only
  // maxDays can be overridden (current-week re-plan budgets out days already run)
  const maxDays = (opts && opts.maxDays != null) ? opts.maxDays : ((profile && profile.days_per_week) || 5);
  const longRunDay = (profile && profile.long_run_day) || "Sunday";

  const byDate = {};
  const rawDays = Array.isArray(raw && raw.days) ? raw.days : [];
  for (const d of rawDays) {
    if (d && typeof d.date === "string") byDate[d.date.slice(0, 10)] = d;
  }

  let days = weekDates.map((date) => {
    const src = byDate[date];
    if (!src) {
      adjustments.push(date + " missing from LLM plan — filled as rest");
      return { date: date, type: "rest", distance_km: 0, description: "Rest day." };
    }
    let type = TYPES.indexOf(src.type) >= 0 ? src.type : null;
    if (type === null) {
      adjustments.push(date + ": unknown type '" + src.type + "' → E");
      type = "E";
    }
    let km = Number(src.distance_km);
    if (!isFinite(km) || km < 0) km = 0;
    if (type === "rest") km = 0;
    return {
      date: date,
      type: type,
      distance_km: Math.round(km * 10) / 10,
      description: String(src.description || "").slice(0, 2000),
    };
  });

  // M7: no injured→all-rest override anymore (injury is a soft signal). The
  // return-to-run easy-only window still forces quality back to easy first.
  if (noQuality) {
    for (const d of days) {
      if (d.type === "T" || d.type === "I" || d.type === "R" || d.type === "MP") {
        adjustments.push(d.date + " (" + d.type + ") → E (return-to-run: easy only)");
        d.type = "E";
      }
    }
  }

  {
    // days_per_week: demote the smallest E days to rest until inside the cap
    let runDays = days.filter((d) => d.type !== "rest");
    while (runDays.length > maxDays) {
      const eDays = runDays.filter((d) => d.type === "E").sort((a, b) => a.distance_km - b.distance_km);
      const victim = eDays[0] || runDays.sort((a, b) => a.distance_km - b.distance_km)[0];
      adjustments.push(victim.date + " (" + victim.type + " " + victim.distance_km + " km) → rest (days_per_week " + maxDays + ")");
      victim.type = "rest";
      victim.distance_km = 0;
      runDays = days.filter((d) => d.type !== "rest");
    }

    // long run on the configured day: swap if the LLM put it elsewhere
    const lr = days.find((d) => d.type === "LR");
    if (lr) {
      const lrWeekday = WEEKDAYS[new Date(lr.date + "T00:00:00Z").getUTCDay()];
      if (lrWeekday !== longRunDay) {
        const target = days.find((d) => {
          return WEEKDAYS[new Date(d.date + "T00:00:00Z").getUTCDay()] === longRunDay;
        });
        if (target && target !== lr) {
          const tmp = { type: target.type, distance_km: target.distance_km, description: target.description };
          target.type = lr.type; target.distance_km = lr.distance_km; target.description = lr.description;
          lr.type = tmp.type; lr.distance_km = tmp.distance_km; lr.description = tmp.description;
          adjustments.push("long run moved to " + longRunDay);
        }
      }
    }

    // weekly cap: scale everything down proportionally
    const total = days.reduce((s, d) => s + d.distance_km, 0);
    if (capKm > 0 && total > capKm) {
      const f = capKm / total;
      for (const d of days) d.distance_km = Math.round(d.distance_km * f * 10) / 10;
      adjustments.push("total " + Math.round(total) + " km exceeded cap " + capKm + " km — scaled by " + Math.round(f * 100) + "%");
    }
  }

  return {
    days: days,
    rationale: String((raw && raw.rationale) || "").slice(0, 9000),
    adjustments: adjustments,
  };
}

// ── persistence ─────────────────────────────────────────────────────────

function deleteExisting(app, dates, idx) {
  // Clears only the given dates (today→end-of-week when planning the current
  // week), so already-logged earlier days of the week are preserved.
  const from = dates[0] + " 00:00:00.000Z";
  const to = dates[dates.length - 1] + " 23:59:59.000Z";
  for (const rec of app.findRecordsByFilter(
    "planned_workouts", "date >= '" + from + "' && date <= '" + to + "'", "", 50, 0
  )) {
    app.delete(rec);
  }
  for (const rec of app.findRecordsByFilter("plan_weeks", "week_idx = " + idx, "", 5, 0)) {
    app.delete(rec);
  }
}

function persist(app, idx, phase, plan) {
  const weeksCol = app.findCollectionByNameOrId("plan_weeks");
  const wk = new Record(weeksCol);
  wk.set("week_idx", idx);
  wk.set("phase", phase);
  let rationale = plan.rationale;
  if (plan.adjustments.length) {
    rationale += "\n[server adjustments: " + plan.adjustments.join("; ") + "]";
  }
  wk.set("rationale", rationale);
  app.save(wk);

  const woCol = app.findCollectionByNameOrId("planned_workouts");
  for (const d of plan.days) {
    const rec = new Record(woCol);
    rec.set("date", d.date + " 00:00:00.000Z");
    rec.set("type", d.type);
    rec.set("distance_m", Math.round(d.distance_km * 1000));
    if (d.pace_low) rec.set("target_pace_low_skm", d.pace_low);
    if (d.pace_high) rec.set("target_pace_high_skm", d.pace_high);
    rec.set("description", d.description);
    rec.set("status", "planned");
    rec.set("plan_week_id", wk.id);
    app.save(rec);
  }
  return wk.id;
}

// ── public API ──────────────────────────────────────────────────────────

// Generate (or regenerate) the week containing `startDate` (Date, UTC Monday).
// M7: defaults to THIS week and plans only TODAY → end of week, preserving any
// already-logged earlier days — so the athlete can re-plan frequently off each
// run without clobbering what's done. (The Sunday cron passes next Monday.)
function generateWeek(app, llm, persona, engine, startDate, convo) {
  const now = new Date();
  const state = engine.computeEngineState(app);
  const profile = state.profile;
  const monday = startDate || mondayOf(now); // default: the CURRENT week
  const weekDates = [];
  for (let i = 0; i < 7; i++) {
    weekDates.push(isoDay(new Date(monday.getTime() + i * 86400000)));
  }

  // Plan from today forward; earlier days of the current week stay untouched.
  const todayStr = isoDay(now);
  const genDates = weekDates.filter(function (d) { return d >= todayStr; });
  const idx = weekIdx(monday);
  if (!genDates.length) {
    return {
      week_id: null, week_idx: idx, week_start: weekDates[0],
      phase: phaseFor(null), cap_km: 0, ramp_week: null, days: [],
      rationale: "That week is already in the past — nothing to plan.", adjustments: [],
    };
  }

  let weeksToRace = null;
  if (profile && profile.race_date) {
    const race = new Date(String(profile.race_date).replace(" ", "T"));
    weeksToRace = Math.round((race.getTime() - monday.getTime()) / (7 * 86400000));
    if (weeksToRace < 0) weeksToRace = null; // race already happened
  }
  const phase = phaseFor(weeksToRace);
  // Phase 6: ramp anchored to the week being PLANNED (its Monday).
  const ramp = engine.returnRampPlan(profile, monday, state.chronic_baseline_km);
  const fullCap = weeklyCapKm(state, profile, ramp);

  // Partial (current) week: subtract km already run + run-days already used this
  // week, so the regenerated remainder still fits the weekly cap + day budget.
  let kmDone = 0, pastRunDays = 0;
  if (genDates.length < 7) {
    const runRecs = app.findRecordsByFilter(
      "runs",
      "date >= '" + weekDates[0] + " 00:00:00.000Z' && date < '" + todayStr + " 00:00:00.000Z'",
      "date", 50, 0
    );
    const dayKeys = {};
    for (const r of runRecs) {
      kmDone += (r.getFloat("distance_m") || 0) / 1000;
      dayKeys[r.getString("date").slice(0, 10)] = 1;
    }
    pastRunDays = Object.keys(dayKeys).length;
  }
  const capKm = Math.max(0, Math.round((fullCap - kmDone) * 10) / 10);
  const remMaxDays = Math.max(0, ((profile && profile.days_per_week) || 5) - pastRunDays);
  const noQuality = !!(ramp && ramp.no_quality);

  const prompt = buildPrompt(engine.forLLM(state), profile, genDates, capKm, phase, weeksToRace, ramp, convo || "");
  let parsed;
  try {
    parsed = parsePlanJSON(llm.generate("weekly", persona, prompt));
  } catch (err) {
    // A JSON-less response is a failed response, not a rail violation —
    // one retry (free-tier Gemini flakes under load), then give up loudly.
    console.log("plan JSON unusable, retrying once:", String(err));
    parsed = parsePlanJSON(llm.generate("weekly", persona, prompt));
  }
  const plan = sanitizePlan(parsed, genDates, capKm, profile, { noQuality: noQuality, maxDays: remMaxDays });

  // attach code-computed pace targets (LLM never chose these) + Phase 3 rail:
  // rewrite any time-based reps to distance.
  const zonesSec = state.vdot.available ? state.vdot.zones_sec : null;
  for (const d of plan.days) {
    const conv = distanceifyDescription(d.type, d.description, zonesSec);
    if (conv.repaired) {
      d.description = conv.description;
      plan.adjustments.push(d.date + ": " + conv.note);
    }
    const p = pacesForType(d.type, zonesSec);
    d.pace_low = p.low;
    d.pace_high = p.high;
  }

  deleteExisting(app, genDates, idx); // only today→end of week (+ the week row)
  const weekId = persist(app, idx, phase, plan);

  return {
    week_id: weekId,
    week_idx: idx,
    week_start: weekDates[0],
    phase: phase,
    cap_km: capKm,
    ramp_week: ramp ? ramp.week : null, // M7 Phase 6: null unless ramping back
    days: plan.days,
    rationale: plan.rationale,
    adjustments: plan.adjustments,
  };
}

// Mark past planned workouts done/skipped by whether a run landed that day.
// Deterministic, idempotent; runs in the morning cron.
function reconcile(app) {
  const today = isoDay(new Date()) + " 00:00:00.000Z";
  const pending = app.findRecordsByFilter(
    "planned_workouts", "status = 'planned' && date < '" + today + "'", "date", 100, 0
  );
  let done = 0, skipped = 0;
  for (const wo of pending) {
    if (wo.getString("type") === "rest") { // rest days are always "done"
      wo.set("status", "done"); app.save(wo); done++;
      continue;
    }
    const day = wo.getString("date").slice(0, 10);
    const runs = app.findRecordsByFilter(
      "runs",
      "date >= '" + day + " 00:00:00.000Z' && date <= '" + day + " 23:59:59.000Z'",
      "", 5, 0
    );
    if (runs.length > 0) {
      wo.set("status", "done");
      const run = runs[0];
      if (!run.getString("matched_workout_id")) {
        run.set("matched_workout_id", wo.id);
        app.save(run);
      }
      done++;
    } else {
      wo.set("status", "skipped");
      skipped++;
    }
    app.save(wo);
  }
  return { done: done, skipped: skipped };
}

// M5: red light → the coach pulls today's planned workout (deterministic;
// the morning message explains it). Returns what was pulled, or null.
function pullTodayIfRed(app, state) {
  if (!state.traffic_light || state.traffic_light.light !== "red") return null;
  const day = isoDay(new Date());
  const wos = app.findRecordsByFilter(
    "planned_workouts",
    "date >= '" + day + " 00:00:00.000Z' && date <= '" + day + " 23:59:59.000Z' && status = 'planned'",
    "", 5, 0
  );
  for (const wo of wos) {
    const t = wo.getString("type");
    if (t === "rest") continue;
    const km = Math.round((wo.getFloat("distance_m") / 1000) * 10) / 10;
    wo.set("status", "modified");
    wo.set("type", "rest");
    wo.set("distance_m", 0);
    wo.set("description",
      "⛔ Coach pulled this (red light): was " + t + " " + km + " km — " +
      wo.getString("description"));
    app.save(wo);
    return { was_type: t, was_km: km };
  }
  return null;
}

// ── M7 Phase 2: mid-week re-plan ────────────────────────────────────────
// Ben's real loop is per-run ("I did this, how should the plan change now?"),
// not weekly. CODE decides IF a replan is warranted and the rails it must obey;
// the LLM decides which remaining days move and how to phrase it. Quiet when
// nothing material changed — but never silent about a change it did make.

function mondayOf(now) {
  const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const back = (d.getUTCDay() + 6) % 7; // 0 Sun..6 Sat → days back to Monday
  return new Date(d.getTime() - back * 86400000);
}

const QUALITY_TYPES = { T: 1, I: 1, R: 1, MP: 1 };

// Already replanned today? One LLM-spending replan per day (cost-conscious).
function replannedToday(app, todayStr) {
  const msgs = app.findRecordsByFilter(
    "coach_messages", "kind = 'plan_change'", "-created", 5, 0
  );
  for (const m of msgs) {
    if (m.getString("created").slice(0, 10) === todayStr) return true;
  }
  return false;
}

// CODE decides IF — returns the list of human-readable trigger reasons (empty
// = no replan). Deterministic; reads only this week's plan + runs + feel.
function assessReplan(app, state, weekMonday, today, capKm, kmDone) {
  const weekStart = isoDay(weekMonday);
  const weekEnd = isoDay(new Date(weekMonday.getTime() + 6 * 86400000));
  const todayStr = isoDay(today);

  const planned = app.findRecordsByFilter(
    "planned_workouts",
    "date >= '" + weekStart + " 00:00:00.000Z' && date <= '" + weekEnd + " 23:59:59.000Z'",
    "date", 50, 0
  );
  const runs = app.findRecordsByFilter(
    "runs",
    "date >= '" + weekStart + " 00:00:00.000Z' && date <= '" + weekEnd + " 23:59:59.000Z'",
    "date", 50, 0
  );
  const plannedById = {};
  for (const p of planned) plannedById[p.id] = p;

  let futureNonRest = 0, anySkipped = false;
  for (const p of planned) {
    const d = p.getString("date").slice(0, 10);
    if (p.getString("status") === "skipped") anySkipped = true;
    if (d > todayStr && p.getString("type") !== "rest" && p.getString("status") === "planned") {
      futureNonRest++;
    }
  }

  const reasons = [];
  // (a) a skipped workout the rest of the week can still absorb
  if (anySkipped && futureNonRest >= 2) {
    reasons.push("a planned workout was skipped and " + futureNonRest + " training days remain to absorb it");
  }

  const light = state.traffic_light ? state.traffic_light.light : "green";
  for (const r of runs) {
    const p = r.getString("matched_workout_id") ? plannedById[r.getString("matched_workout_id")] : null;
    if (!p) continue;
    const planM = p.getFloat("distance_m"), runM = r.getFloat("distance_m");
    // (b) completed run deviated >25% in distance from plan
    if (planM > 0 && Math.abs(runM - planM) / planM > 0.25) {
      reasons.push(
        "a completed run was " + (runM > planM ? "longer" : "shorter") +
        " than planned by more than 25% (" + round(runM / 1000, 1) + " vs " +
        round(planM / 1000, 1) + " km)"
      );
    }
    const effort = Math.round(r.getFloat("effort") || 0);
    if (QUALITY_TYPES[p.getString("type")]) {
      // (c) quality day was maximal effort → back off the rest of the week
      if (effort === 5) {
        reasons.push("a quality session (" + p.getString("type") + ") was max effort (5/5) — likely needs more recovery");
      }
      // (d) quality day felt easy, light green, week still under cap → room to add
      if (effort >= 1 && effort <= 2 && light === "green" && kmDone < capKm) {
        reasons.push("a quality session felt easy (effort " + effort + "/5), the light is green, and the week is under its cap");
      }
    }
  }
  // dedupe
  return reasons.filter((r, i) => reasons.indexOf(r) === i);
}

function round(x, dp) {
  const f = Math.pow(10, dp || 0);
  return Math.round(x * f) / f;
}

function buildReplanPrompt(engineFacts, reasons, remaining, remainingCapKm, noQuality, raceDay) {
  return (
    "Mid-week re-plan. Today is " + new Date().toISOString().slice(0, 10) + ".\n\n" +
    "What changed (the server detected these deterministically):\n- " +
    reasons.join("\n- ") + "\n\n" +
    "Deterministic engine state (numbers pre-computed; never recompute):\n" +
    JSON.stringify(engineFacts) + "\n\n" +
    "Only these remaining days of THIS week may change (everything else is " +
    "locked — past days, today, and race day):\n" + JSON.stringify(remaining) + "\n\n" +
    "Hard rails the server enforces afterwards:\n" +
    JSON.stringify({
      remaining_week_distance_cap_km: remainingCapKm,
      easy_only: noQuality,
      race_day_immovable: raceDay || null,
    }) + "\n\n" +
    (noQuality
      ? "Easy only: remaining running days must be type E or LR — no T/I/R/MP.\n\n"
      : "") +
    "Any interval/threshold/rep work MUST be prescribed as DISTANCE reps " +
    "(\"6 × 600m\"), never time — no minutes/seconds in descriptions.\n\n" +
    "Respond with STRICT JSON only (no fences, no prose):\n" +
    '{"rationale":"1-3 sentences on what you moved and why",' +
    '"changes":[{"date":"YYYY-MM-DD","type":"E|T|I|R|MP|LR|rest","distance_km":0,"description":"..."}]}' +
    "\nInclude only days you are changing, each a date from the remaining list. " +
    "Paces are not yours — the server attaches them from the VDOT zones."
  );
}

// Apply + rail-check the LLM's proposed changes to the remaining days.
function sanitizeReplan(raw, remaining, remainingCapKm, noQuality, raceDayStr) {
  const adjustments = [];
  const allowed = {};
  for (const d of remaining) allowed[d.date] = d;

  const changes = Array.isArray(raw && raw.changes) ? raw.changes : [];
  const applied = {};
  for (const c of changes) {
    if (!c || typeof c.date !== "string") continue;
    const date = c.date.slice(0, 10);
    if (!allowed[date]) { adjustments.push(date + ": not a changeable remaining day — ignored"); continue; }
    if (raceDayStr && date === raceDayStr) { adjustments.push(date + ": race day is immovable — ignored"); continue; }
    let type = TYPES.indexOf(c.type) >= 0 ? c.type : "E";
    let km = Number(c.distance_km);
    if (!isFinite(km) || km < 0) km = 0;
    if (noQuality && QUALITY_TYPES[type]) {
      adjustments.push(date + " (" + type + ") → E (easy-only window)");
      type = "E";
    }
    if (type === "rest") km = 0;
    applied[date] = { type: type, distance_km: round(km, 1), description: String(c.description || "").slice(0, 2000) };
  }

  // remaining-week cap: scale the changed running days down if over
  if (remainingCapKm >= 0) {
    let total = 0;
    for (const date in applied) total += applied[date].distance_km;
    if (total > remainingCapKm && total > 0) {
      const f = remainingCapKm / total;
      for (const date in applied) applied[date].distance_km = round(applied[date].distance_km * f, 1);
      adjustments.push("changed days totalled " + round(total, 1) + " km over the " + remainingCapKm + " km remaining cap — scaled by " + Math.round(f * 100) + "%");
    }
  }
  return { applied: applied, rationale: String((raw && raw.rationale) || "").slice(0, 4000), adjustments: adjustments };
}

// Public entry: decide, (maybe) call the LLM, persist modified days, post a
// plan_change message. Returns a summary (replanned:false when quiet).
function replanRemainder(app, llm, persona, engine, coach, opts) {
  // opts.today (ISO date) pins "now" for the week math — a test seam so the
  // offline suite isn't at the mercy of the real weekday. Production omits it.
  const today = opts && opts.today ? new Date(String(opts.today).replace(" ", "T")) : new Date();
  const todayStr = isoDay(today);
  const force = !!(opts && opts.force);

  // The once-per-day guard keys off the REAL calendar day (messages are stamped
  // in real time) — opts.today only pins the week math for tests.
  if (!force && replannedToday(app, isoDay(new Date()))) {
    return { replanned: false, reason: "already replanned today" };
  }

  const state = engine.computeEngineState(app);
  const profile = state.profile;
  const weekMonday = mondayOf(today);
  const weekStart = isoDay(weekMonday);
  const weekEnd = isoDay(new Date(weekMonday.getTime() + 6 * 86400000));

  // km already done this week (from real runs) and this week's cap
  const runs = app.findRecordsByFilter(
    "runs",
    "date >= '" + weekStart + " 00:00:00.000Z' && date <= '" + weekEnd + " 23:59:59.000Z'",
    "date", 50, 0
  );
  let kmDone = 0;
  for (const r of runs) kmDone += (r.getFloat("distance_m") || 0) / 1000;
  kmDone = round(kmDone, 1);

  const ramp = engine.returnRampPlan(profile, weekMonday, state.chronic_baseline_km);
  const capKm = weeklyCapKm(state, profile, ramp);
  const remainingCapKm = Math.max(0, round(capKm - kmDone, 1));

  const reasons = assessReplan(app, state, weekMonday, today, capKm, kmDone);
  if (!reasons.length) {
    console.log("replan: no replan needed (" + weekStart + ")");
    return { replanned: false, reason: "no replan needed" };
  }

  // Rails for the remainder (injury is no longer a hard rail — soft signal only)
  const light = state.traffic_light ? state.traffic_light.light : "green";
  const noQuality = light === "red" || !!(ramp && ramp.no_quality);
  let raceDayStr = null;
  if (profile && profile.race_date) {
    const rd = String(profile.race_date).slice(0, 10);
    if (rd >= weekStart && rd <= weekEnd) raceDayStr = rd;
  }

  // Future, still-planned days of THIS week (only these may change)
  const plannedRecs = app.findRecordsByFilter(
    "planned_workouts",
    "date >= '" + weekStart + " 00:00:00.000Z' && date <= '" + weekEnd + " 23:59:59.000Z'",
    "date", 50, 0
  );
  const remaining = [];
  const recByDate = {};
  for (const p of plannedRecs) {
    const d = p.getString("date").slice(0, 10);
    recByDate[d] = p;
    if (d > todayStr && d !== raceDayStr && p.getString("status") === "planned") {
      remaining.push({
        date: d,
        type: p.getString("type"),
        distance_km: round((p.getFloat("distance_m") || 0) / 1000, 1),
        description: p.getString("description"),
      });
    }
  }
  if (!remaining.length) {
    console.log("replan: triggers fired but no changeable days remain (" + weekStart + ")");
    return { replanned: false, reason: "no remaining days to change", reasons: reasons };
  }

  const prompt = buildReplanPrompt(
    engine.forLLM(state), reasons, remaining, remainingCapKm, noQuality, raceDayStr
  );
  let parsed;
  try {
    parsed = parsePlanJSON(llm.generate("replan", persona, prompt));
  } catch (err) {
    console.log("replan JSON unusable, retrying once:", String(err));
    parsed = parsePlanJSON(llm.generate("replan", persona, prompt));
  }
  const result = sanitizeReplan(parsed, remaining, remainingCapKm, noQuality, raceDayStr);

  const zonesSec = state.vdot.available ? state.vdot.zones_sec : null;
  const changedDates = [];
  for (const date in result.applied) {
    const rec = recByDate[date];
    if (!rec) continue;
    const a = result.applied[date];
    const oldType = rec.getString("type");
    const oldKm = round((rec.getFloat("distance_m") || 0) / 1000, 1);
    if (a.type === oldType && a.distance_km === oldKm) continue; // no real change
    const conv = distanceifyDescription(a.type, a.description, zonesSec); // Phase 3 rail
    if (conv.repaired) { a.description = conv.description; result.adjustments.push(date + ": " + conv.note); }
    const p = pacesForType(a.type, zonesSec);
    rec.set("type", a.type);
    rec.set("distance_m", Math.round(a.distance_km * 1000));
    rec.set("target_pace_low_skm", p.low || 0);
    rec.set("target_pace_high_skm", p.high || 0);
    rec.set("status", "modified");
    rec.set("description",
      "🔄 was " + oldType + " " + oldKm + " km — " + (a.description || rec.getString("description")));
    app.save(rec);
    changedDates.push(date);
  }

  if (!changedDates.length) {
    console.log("replan: LLM proposed no net change (" + weekStart + ")");
    return { replanned: false, reason: "no net change", reasons: reasons };
  }

  let body = "Mid-week adjustment. " + result.rationale;
  if (result.adjustments.length) body += "\n[server adjustments: " + result.adjustments.join("; ") + "]";
  coach.saveCoachMessage(app, "plan_change", body, llm.provider());

  console.log("replan: changed " + changedDates.length + " day(s) — " + changedDates.join(", "));
  return {
    replanned: true,
    reasons: reasons,
    changed_dates: changedDates,
    remaining_cap_km: remainingCapKm,
    rationale: result.rationale,
    adjustments: result.adjustments,
  };
}

module.exports = {
  generateWeek: generateWeek,
  reconcile: reconcile,
  nextMonday: nextMonday,
  pullTodayIfRed: pullTodayIfRed,
  replanRemainder: replanRemainder,
  // exposed for tests
  _sanitizePlan: sanitizePlan,
  _weeklyCapKm: weeklyCapKm,
  _pacesForType: pacesForType,
};
