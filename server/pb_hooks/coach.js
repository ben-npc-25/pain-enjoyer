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
  // Deterministic spine: pace is computed HERE, never by the LLM (PLAN.md §1).
  const paceMinKm = distKm > 0 ? durS / 60 / distKm : 0;

  return {
    date: run.getString("date"),
    distance_km: Math.round(distKm * 100) / 100,
    duration_min: Math.round((durS / 60) * 10) / 10,
    avg_pace_min_per_km: Math.round(paceMinKm * 100) / 100,
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

function buildDailyPrompt(profile, facts) {
  // Volatile content (date, metrics) lives here — NOT in the persona prefix.
  return (
    "Today is " +
    new Date().toISOString().slice(0, 10) +
    ".\n\nAthlete profile: " +
    JSON.stringify(profile || { note: "no profile set up yet" }) +
    "\n\nMost recent run — computed facts (use ONLY these numbers): " +
    JSON.stringify(facts) +
    "\n\nGive the athlete short, specific coaching feedback on this run."
  );
}

module.exports = {
  latestRunFacts,
  profileFacts,
  saveCoachMessage,
  buildDailyPrompt,
};
