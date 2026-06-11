// engagement.js — M5 adaptive proactivity. require()'d module (fresh-JSVM rule).
//
// Deterministic spine, as always: a 14-day engagement score computed from
// data we already store — chat responses vs coach check-ins (coach_messages),
// workout completion (planned_workouts statuses), and app opens (the one
// client-only signal, reported via POST /api/coach/ping into `engagement`).
// The score maps to a cadence level; the LLM only narrates changes.

function isoDay(d) {
  return d.toISOString().slice(0, 10);
}

function pbDay(dayKey) {
  return dayKey + " 00:00:00.000Z";
}

function cutoffStr(days) {
  return new Date(Date.now() - days * 86400000)
    .toISOString().replace("T", " ").replace(/\.\d{3}Z$/, ".000Z");
}

// App-open ping: upsert today's engagement row, bump opens.
function ping(app) {
  const today = isoDay(new Date());
  const col = app.findCollectionByNameOrId("engagement");
  const rows = app.findRecordsByFilter(
    "engagement", "date >= '" + pbDay(today) + "'", "", 1, 0
  );
  const rec = rows.length ? rows[0] : new Record(col);
  if (!rows.length) rec.set("date", pbDay(today));
  const opens = (rec.getFloat("opens") || 0) + 1;
  rec.set("opens", opens);
  app.save(rec);
  return { date: today, opens: opens };
}

// 14-day engagement score ∈ [0,1] from three signals, each optional:
//  - response rate: days the athlete chatted ÷ days the coach checked in
//  - completion rate: non-rest planned workouts done ÷ (done + skipped)
//  - open rate: days the app was opened ÷ 14
function score(app) {
  const cutoff = cutoffStr(14);

  const msgs = app.findRecordsByFilter(
    "coach_messages", "created >= '" + cutoff + "'", "created", 500, 0
  );
  const coachDays = {}, athleteDays = {};
  for (const m of msgs) {
    const day = m.getString("created").slice(0, 10);
    if (m.getString("role") === "athlete") athleteDays[day] = true;
    else if (m.getString("kind") === "daily") coachDays[day] = true;
  }
  const coachDayKeys = Object.keys(coachDays);
  let responded = 0;
  for (const d of coachDayKeys) if (athleteDays[d]) responded++;
  const responseRate = coachDayKeys.length ? responded / coachDayKeys.length : null;

  const today = isoDay(new Date());
  const workouts = app.findRecordsByFilter(
    "planned_workouts",
    "date >= '" + cutoff + "' && date < '" + pbDay(today) + "' && type != 'rest'",
    "", 100, 0
  );
  let done = 0, skipped = 0;
  for (const w of workouts) {
    const s = w.getString("status");
    if (s === "done") done++;
    else if (s === "skipped") skipped++;
  }
  const completionRate = done + skipped > 0 ? done / (done + skipped) : null;

  const openRows = app.findRecordsByFilter(
    "engagement", "date >= '" + cutoff + "' && opens > 0", "", 50, 0
  );
  const openRate = openRows.length / 14;

  const parts = [];
  if (responseRate !== null) parts.push(responseRate);
  if (completionRate !== null) parts.push(completionRate);
  parts.push(openRate);
  const s = parts.reduce(function (a, b) { return a + b; }, 0) / parts.length;

  return {
    score: Math.round(s * 100) / 100,
    response_rate: responseRate,
    completion_rate: completionRate,
    open_rate: Math.round(openRate * 100) / 100,
  };
}

function levelForScore(s) {
  if (s >= 0.55) return "daily";
  if (s >= 0.25) return "every_2_3_days";
  return "weekly_digest";
}

// Compute level (race week forces daily), persist a change to the profile,
// report whether it changed so the coach can acknowledge the shift.
function cadence(app) {
  const eng = score(app);
  let level = levelForScore(eng.score);
  let raceWeek = false;

  const profs = app.findRecordsByFilter("athlete_profile", "id != ''", "-created", 1, 0);
  const prof = profs.length ? profs[0] : null;
  if (prof) {
    const rd = prof.getString("race_date");
    if (rd) {
      const days = (new Date(String(rd).replace(" ", "T")).getTime() - Date.now()) / 86400000;
      if (days >= 0 && days <= 14) { level = "daily"; raceWeek = true; }
    }
  }

  let changed = false;
  if (prof) {
    const prev = prof.getString("proactivity_level") || "daily";
    if (prev !== level) {
      prof.set("proactivity_level", level);
      app.save(prof);
      changed = true;
    }
  }

  eng.level = level;
  eng.changed = changed;
  eng.race_week = raceWeek;
  return eng;
}

module.exports = {
  ping: ping,
  score: score,
  cadence: cadence,
};
