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
function weeklyCapKm(state, profile) {
  if (profile && profile.injured) return 0;
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

function buildPrompt(engineFacts, profile, weekDates, capKm, phase, weeksToRace) {
  const constraints = {
    week_dates: weekDates,
    training_phase: phase,
    weeks_to_race: weeksToRace === null ? "no race set" : weeksToRace,
    weekly_distance_cap_km: capKm,
    days_per_week_max: (profile && profile.days_per_week) || 5,
    long_run_day: (profile && profile.long_run_day) || "Sunday",
    athlete_injured: !!(profile && profile.injured),
  };
  return (
    "Plan next week's training. Today is " + new Date().toISOString().slice(0, 10) + ".\n\n" +
    "Deterministic engine state (all numbers pre-computed; do not recompute):\n" +
    JSON.stringify(engineFacts) + "\n\n" +
    "Hard constraints (the server enforces these mechanically afterwards — " +
    "violations get clamped, so plan inside them):\n" +
    JSON.stringify(constraints) + "\n\n" +
    "If athlete_injured is true: every day must be type \"rest\" with distance 0 — " +
    "use the descriptions for rehab/cross-training/mobility guidance instead.\n\n" +
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
function sanitizePlan(raw, weekDates, capKm, profile) {
  const adjustments = [];
  const injured = !!(profile && profile.injured);
  const maxDays = (profile && profile.days_per_week) || 5;
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

  if (injured) {
    if (days.some((d) => d.type !== "rest" || d.distance_km > 0)) {
      adjustments.push("athlete injured — all days forced to rest");
    }
    days = days.map((d) => ({
      date: d.date,
      type: "rest",
      distance_km: 0,
      description: d.description || "Rest / rehab day.",
    }));
  } else {
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

function deleteExisting(app, weekDates, idx) {
  const from = weekDates[0] + " 00:00:00.000Z";
  const to = weekDates[6] + " 23:59:59.000Z";
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

// Generate (or regenerate) the week starting `startDate` (Date, UTC Monday;
// defaults to next Monday). Returns a summary for the API response.
function generateWeek(app, llm, persona, engine, startDate) {
  const state = engine.computeEngineState(app);
  const profile = state.profile;
  const monday = startDate || nextMonday(new Date());
  const weekDates = [];
  for (let i = 0; i < 7; i++) {
    const d = new Date(monday.getTime() + i * 86400000);
    weekDates.push(isoDay(d));
  }

  let weeksToRace = null;
  if (profile && profile.race_date) {
    const race = new Date(String(profile.race_date).replace(" ", "T"));
    weeksToRace = Math.round((race.getTime() - monday.getTime()) / (7 * 86400000));
    if (weeksToRace < 0) weeksToRace = null; // race already happened
  }
  const phase = phaseFor(weeksToRace);
  const capKm = weeklyCapKm(state, profile);

  const raw = llm.generate(
    "weekly",
    persona,
    buildPrompt(engine.forLLM(state), profile, weekDates, capKm, phase, weeksToRace)
  );
  const plan = sanitizePlan(parsePlanJSON(raw), weekDates, capKm, profile);

  // attach code-computed pace targets (LLM never chose these)
  const zonesSec = state.vdot.available ? state.vdot.zones_sec : null;
  for (const d of plan.days) {
    const p = pacesForType(d.type, zonesSec);
    d.pace_low = p.low;
    d.pace_high = p.high;
  }

  const idx = weekIdx(monday);
  deleteExisting(app, weekDates, idx);
  const weekId = persist(app, idx, phase, plan);

  return {
    week_id: weekId,
    week_idx: idx,
    week_start: weekDates[0],
    phase: phase,
    cap_km: capKm,
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

module.exports = {
  generateWeek: generateWeek,
  reconcile: reconcile,
  nextMonday: nextMonday,
  // exposed for tests
  _sanitizePlan: sanitizePlan,
  _weeklyCapKm: weeklyCapKm,
  _pacesForType: pacesForType,
};
