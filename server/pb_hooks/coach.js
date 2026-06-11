// coach.js — shared coach logic, require()'d from handlers in main.pb.js.
//
// NOTE: this MUST be a module (not inline functions in main.pb.js):
// PocketBase executes routerAdd/cronAdd handlers in fresh JSVM instances,
// so file-level functions in *.pb.js are not in scope at request time.

function latestRunFacts(app) {
  const runs = app.findRecordsByFilter("runs", "id != ''", "-date", 1, 0);
  if (runs.length === 0) return null;
  const run = runs[0];

  const distM = run.getFloat("distance_m");
  const durS = run.getFloat("duration_s");
  const distKm = distM / 1000;
  // Deterministic spine: pace is computed AND formatted here — handing the
  // LLM a decimal once produced "5:79/km" in testing. Numbers never leave
  // the server unformatted (PLAN.md §1).
  const paceSecPerKm = distKm > 0 ? durS / distKm : 0;
  const paceMin = Math.floor(paceSecPerKm / 60);
  const paceSec = Math.round(paceSecPerKm % 60);
  const pace =
    paceSecPerKm > 0
      ? paceMin + ":" + (paceSec < 10 ? "0" : "") + paceSec + " min/km"
      : null;

  return {
    date: run.getString("date"),
    distance_km: Math.round(distKm * 100) / 100,
    duration_min: Math.round((durS / 60) * 10) / 10,
    avg_pace: pace, // pre-formatted "5:47 min/km" — the only pace the LLM sees
    avg_hr: run.getFloat("avg_hr") || null,
    elevation_gain_m: run.getFloat("elevation_gain_m") || null,
    source_app: run.getString("source_app") || null,
  };
}

function profileFacts(app) {
  const profs = app.findRecordsByFilter(
    "athlete_profile",
    "id != ''",
    "-created",
    1,
    0
  );
  if (profs.length === 0) return null;
  const p = profs[0];
  return {
    race_name: p.getString("race_name") || null,
    race_date: p.getString("race_date") || null,
    goal_time_s: p.getFloat("goal_time_s") || null,
    methodology: p.getString("methodology") || "hybrid_vdot_8020",
    days_per_week: p.getFloat("days_per_week") || null,
  };
}

function saveCoachMessage(app, kind, content, provider) {
  const col = app.findCollectionByNameOrId("coach_messages");
  const rec = new Record(col);
  rec.set("role", "coach");
  rec.set("kind", kind);
  rec.set("content", content);
  rec.set("provider", provider);
  app.save(rec);
}

function buildDailyPrompt(profile, facts, engineFacts) {
  // Volatile content (date, metrics) lives here — NOT in the persona prefix.
  // engineFacts is engine.forLLM() output: every value pre-formatted (M2).
  let p =
    "Today is " +
    new Date().toISOString().slice(0, 10) +
    ".\n\nAthlete profile: " +
    JSON.stringify(profile || { note: "no profile set up yet" }) +
    "\n\nMost recent run — computed facts (use ONLY these numbers): " +
    JSON.stringify(facts);
  if (engineFacts) {
    p +=
      "\n\nTraining engine — deterministic state computed from the full " +
      "history (quote these verbatim; never recompute): " +
      JSON.stringify(engineFacts) +
      "\n\nLead with what the traffic light means for today, then anything " +
      "specific worth saying about the recent run or trends.";
  } else {
    p += "\n\nGive the athlete short, specific coaching feedback on this run.";
  }
  return p;
}

module.exports = {
  latestRunFacts,
  profileFacts,
  saveCoachMessage,
  buildDailyPrompt,
};
