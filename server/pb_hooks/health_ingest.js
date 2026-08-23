// health_ingest.js — M12: HealthKit → server WITHOUT a native app.
//
// Why this exists: the custom iOS app needs a free-account provisioning
// profile re-minted every 7 days from a Mac with a live Xcode Apple ID. Ben's
// work Mac is Jamf-managed (exwzd.jamfcloud.com) with a policy literally named
// "Find AppleID signedin users" running every ~15 min; it removes the Xcode
// account within days, and refresh-app.sh failed 108 times in a row on
// "No Accounts". The web planner in pb_public already has full UI parity, so
// the ONLY thing the native app still did uniquely was read HealthKit. An
// off-the-shelf App Store exporter (Health Auto Export and friends) can POST
// HealthKit data to a REST endpoint on a schedule — no signing, no 7-day
// expiry, no Mac in the loop at all.
//
// This module maps that exporter's JSON onto the SAME rows the phone wrote,
// preserving every semantic the engine depends on:
//   - runs.healthkit_uuid is the dedupe key, so re-posts are idempotent and
//     rows the old app wrote are never duplicated
//   - runs.date is a true instant; recovery_daily.date is a LOCAL DAY LABEL
//     ("YYYY-MM-DD 00:00:00.000Z") — engine.js groups on that day string
//   - sleep is attributed to the WAKE day, matching HealthKitService.swift
//     (`s.endDate.localDayKey`), so old and new rows stay consistent
//   - zero-distance sessions are skipped: distance_m/duration_s are `required`
//     in the schema and PocketBase rejects 0 (the iOS app filtered these too,
//     which is why strength/yoga never actually landed)
//   - activity_type keeps the M8 vocabulary (running/hiking/walking/cycling/
//     swimming/strength/yoga) — running math still filters on it
//
// Tolerant by design: field names and units drift between exporter versions,
// so every value goes through an alias + unit normaliser, and anything
// unmappable is COUNTED AND REPORTED in the response rather than throwing.
// A silent partial import would be worse than a loud one.
//
// ⚠ Fresh-JSVM rule: this is a require()'d module, never a top-level function.

const LB_TO_KG = 0.45359237;
const MI_TO_M = 1609.344;
const YD_TO_M = 0.9144;
const ST_TO_KG = 6.35029318;

// ── name normalisation ─────────────────────────────────────────────────
// "Heart Rate Variability" / "heart_rate_variability" / "heartRateVariability"
// all have to land on the same key.
function normName(s) {
  return String(s === null || s === undefined ? "" : s)
    .replace(/([a-z0-9])([A-Z])/g, "$1_$2") // camelCase → camel_Case
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
}

const METRIC_FIELD = {
  heart_rate_variability: "hrv_sdnn_ms",
  heart_rate_variability_sdnn: "hrv_sdnn_ms",
  hrv: "hrv_sdnn_ms",
  hrv_sdnn: "hrv_sdnn_ms",
  resting_heart_rate: "resting_hr",
  resting_hr: "resting_hr",
  sleep_analysis: "sleep_hours",
  sleep: "sleep_hours",
  sleep_hours: "sleep_hours",
  vo2_max: "vo2max",
  vo2max: "vo2max",
  v_o2_max: "vo2max",
  weight_body_mass: "body_mass_kg",
  body_mass: "body_mass_kg",
  weight: "body_mass_kg",
  body_weight: "body_mass_kg",
  // self-mappings: the flat Shortcuts shape names the target fields directly
  hrv_sdnn_ms: "hrv_sdnn_ms",
  body_mass_kg: "body_mass_kg",
};

// The flat shape an Apple Shortcut can build with ONE Dictionary action:
//   {"date":"2026-08-22","hrv":45.2,"rhr":48,"sleep":7.1,"vo2max":51.4,"weight":70}
// Health Auto Export costs a subscription after its trial, so this is the
// free path — Shortcuts is on every iPhone. Weight is kg and sleep is hours
// here (no units field); the exporter path is the one that converts lb/ms.
const FLAT_METRIC_KEYS = {
  hrv: "hrv_sdnn_ms",
  hrv_sdnn_ms: "hrv_sdnn_ms",
  heart_rate_variability: "hrv_sdnn_ms",
  rhr: "resting_hr",
  resting_hr: "resting_hr",
  resting_heart_rate: "resting_hr",
  sleep: "sleep_hours",
  sleep_hours: "sleep_hours",
  vo2max: "vo2max",
  vo2_max: "vo2max",
  weight: "body_mass_kg",
  weight_kg: "body_mass_kg",
  body_mass_kg: "body_mass_kg",
};

// How repeated points inside one day collapse. Mirrors the iOS queries:
// discrete average for HRV/RHR, latest reading for VO₂max/weight, and one
// merged total for sleep.
const METRIC_MODE = {
  hrv_sdnn_ms: "mean",
  resting_hr: "mean",
  sleep_hours: "max",
  vo2max: "last",
  body_mass_kg: "last",
};

const ACTIVITY = {
  running: "running",
  run: "running",
  treadmill: "running",
  hiking: "hiking",
  hike: "hiking",
  walking: "walking",
  walk: "walking",
  cycling: "cycling",
  cycle: "cycling",
  biking: "cycling",
  bike: "cycling",
  swimming: "swimming",
  swim: "swimming",
  strength: "strength",
  strength_training: "strength",
  functional_strength_training: "strength",
  traditional_strength_training: "strength",
  yoga: "yoga",
};

// Longest-first so "outdoor_running" doesn't match on "run" before "running",
// and "cycling" wins over "cycle".
const ACTIVITY_HINTS = [
  "functional_strength_training",
  "traditional_strength_training",
  "strength_training",
  "running",
  "treadmill",
  "hiking",
  "walking",
  "cycling",
  "swimming",
  "strength",
  "biking",
  "yoga",
  "run",
  "hike",
  "walk",
  "cycle",
  "swim",
  "bike",
];

function activityFromName(name) {
  const n = normName(name);
  if (!n) return "other";
  if (ACTIVITY[n]) return ACTIVITY[n];
  for (const hint of ACTIVITY_HINTS) {
    if (n.indexOf(hint) !== -1) return ACTIVITY[hint];
  }
  return n;
}

// ── timestamps ─────────────────────────────────────────────────────────
// Exporter stamps look like "2026-08-20 07:12:03 +0800"; ISO8601 and
// date-only also turn up. Parsed by hand on purpose — Goja only guarantees
// ISO parsing, and a wrong Date() here would silently shift days.
//
// Returns { ms, day } where `day` is the LOCAL calendar day exactly as
// written (that's what recovery_daily keys on) and `ms` is the UTC instant.
function parseStamp(s) {
  if (s === null || s === undefined) return null;
  const str = String(s).trim();
  const m = str.match(
    /^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2}))?(?:\.(\d{1,9}))?)?\s*(Z|z|[+-]\d{2}:?\d{2})?$/
  );
  if (!m) return null;
  const Y = +m[1], Mo = +m[2], D = +m[3];
  if (Mo < 1 || Mo > 12 || D < 1 || D > 31) return null;
  const frac = m[7] ? +(m[7] + "000").slice(0, 3) : 0;
  let ms = Date.UTC(Y, Mo - 1, D, +(m[4] || 0), +(m[5] || 0), +(m[6] || 0), frac);
  const tz = m[8];
  if (tz && tz !== "Z" && tz !== "z") {
    const sign = tz[0] === "-" ? -1 : 1;
    const digits = tz.slice(1).replace(":", "");
    ms -= sign * (parseInt(digits.slice(0, 2), 10) * 60 + parseInt(digits.slice(2), 10)) * 60000;
  }
  return { ms: ms, day: m[1] + "-" + m[2] + "-" + m[3] };
}

function pbDay(day) {
  return day + " 00:00:00.000Z";
}

function isoInstant(ms) {
  return new Date(ms).toISOString();
}

function round1(v) {
  return v === null || v === undefined ? null : Math.round(v * 10) / 10;
}

// ── values + units ─────────────────────────────────────────────────────
// Exporters send either a bare number or {qty, units}.
function num(v) {
  if (v === null || v === undefined) return null;
  if (typeof v === "number") return isFinite(v) ? v : null;
  if (typeof v === "object") {
    if (v.qty !== undefined) return num(v.qty);
    if (v.value !== undefined) return num(v.value);
    return null;
  }
  const f = parseFloat(v);
  return isFinite(f) ? f : null;
}

function unitsOf(v, fallback) {
  if (v && typeof v === "object" && v.units !== undefined) return normName(v.units);
  return normName(fallback);
}

// defaultUnit matters: the exporter's distance default is km, but elevation
// is already metres. Guessing wrong would be a 1000× error, so callers say.
function toMeters(v, units, defaultUnit) {
  const q = num(v);
  if (q === null) return null;
  const u = unitsOf(v, units) || normName(defaultUnit);
  if (u === "km" || u === "kilometers" || u === "kilometres") return q * 1000;
  if (u === "mi" || u === "mile" || u === "miles") return q * MI_TO_M;
  if (u === "yd" || u === "yard" || u === "yards") return q * YD_TO_M;
  if (u === "ft" || u === "feet" || u === "foot") return q * 0.3048;
  if (u === "cm") return q / 100;
  return q; // m / metres / unknown-but-declared-default
}

function toKg(v, units) {
  const q = num(v);
  if (q === null) return null;
  const u = unitsOf(v, units);
  if (u === "lb" || u === "lbs" || u === "pound" || u === "pounds") return q * LB_TO_KG;
  if (u === "g" || u === "gram" || u === "grams") return q / 1000;
  if (u === "st" || u === "stone" || u === "stones") return q * ST_TO_KG;
  return q; // kg
}

function toMsHrv(v, units) {
  const q = num(v);
  if (q === null) return null;
  const u = unitsOf(v, units);
  if (u === "s" || u === "sec" || u === "secs" || u === "seconds") return q * 1000;
  return q; // ms
}

// Hours is the exporter's sleep unit; a value that can only be minutes is
// rescued rather than written as a 400-hour night.
function toHours(v) {
  const q = num(v);
  if (q === null || q <= 0) return null;
  return q > 24 ? q / 60 : q;
}

// Total *asleep* hours for one night. inBed/awake are deliberately excluded.
function sleepHoursFrom(entry) {
  if (!entry || typeof entry !== "object") return toHours(entry);

  const direct =
    entry.totalSleep !== undefined ? entry.totalSleep
    : entry.total_sleep !== undefined ? entry.total_sleep
    : entry.asleep !== undefined ? entry.asleep
    : entry.sleep_hours !== undefined ? entry.sleep_hours
    : undefined;
  let h = direct !== undefined ? toHours(direct) : null;
  if (h !== null) return h;

  // Staged payloads: sum the asleep stages. `core` and `light` are the same
  // stage under different schema versions — take one, never both, or a night
  // doubles.
  const core = entry.core !== undefined ? entry.core : entry.light;
  let sum = 0, seen = false;
  for (const v of [entry.deep, core, entry.rem, entry.asleep_unspecified]) {
    const hv = toHours(v);
    if (hv !== null) { sum += hv; seen = true; }
  }
  if (seen) return sum;

  return toHours(entry.qty !== undefined ? entry.qty : entry.value);
}

// Average + peak HR for a workout. Newer exporters send avgHeartRate/
// maxHeartRate objects; older ones only a heartRateData series of
// {date, Min, Avg, Max} buckets.
function heartRateFrom(w) {
  let avg = num(w.avgHeartRate !== undefined ? w.avgHeartRate : w.averageHeartRate);
  let max = num(w.maxHeartRate !== undefined ? w.maxHeartRate : w.peakHeartRate);

  const series = w.heartRateData || w.heart_rate_data || w.heartRate;
  if (Array.isArray(series) && series.length) {
    let sum = 0, n = 0, mx = null;
    for (const p of series) {
      const a = num(p.Avg !== undefined ? p.Avg : (p.avg !== undefined ? p.avg : p.qty));
      if (a !== null) { sum += a; n++; }
      const m = num(p.Max !== undefined ? p.Max : p.max);
      if (m !== null && (mx === null || m > mx)) mx = m;
    }
    // NOTE: an unweighted mean of the exporter's buckets — close to, but not
    // identical to, HealthKit's own average. Good enough for 80/20 and VDOT;
    // the peak (which calibrates HRmax) is exact.
    if (avg === null && n > 0) avg = sum / n;
    if (max === null && mx !== null) max = mx;
  }
  return { avg: avg, max: max };
}

// ── workout → runs row ─────────────────────────────────────────────────
function mapWorkout(w) {
  if (!w || typeof w !== "object") return null;
  const start = parseStamp(w.start !== undefined ? w.start : (w.startDate !== undefined ? w.startDate : w.date));
  if (!start) return null;
  const end = parseStamp(w.end !== undefined ? w.end : w.endDate);

  // Prefer end−start: it's unambiguous. Exporter versions disagree on whether
  // `duration` is seconds or minutes, so that's only the fallback.
  let duration_s = null;
  if (end && end.ms > start.ms) duration_s = (end.ms - start.ms) / 1000;
  // A Shortcut hands us seconds outright — unambiguous, so it wins over the
  // end−start estimate only when the latter is unavailable.
  if (duration_s === null) duration_s = num(w.duration_s);
  if (duration_s === null) {
    const d = num(w.duration);
    // 300 is the split: <300 can only sensibly be minutes (a logged session
    // is never 4 minutes), ≥300 can only sensibly be seconds.
    if (d !== null && d > 0) duration_s = d >= 300 ? d : d * 60;
  }

  const activity = activityFromName(
    w.activity !== undefined ? w.activity
      : (w.name !== undefined ? w.name
        : (w.workoutActivityType !== undefined ? w.workoutActivityType : w.type))
  );

  // distance_m / avg_hr / max_hr / elevation_gain_m are the flat (Shortcuts)
  // spellings: already in the units the schema wants, so no conversion.
  let distance_m = num(w.distance_m);
  if (distance_m === null) {
    distance_m = toMeters(w.distance !== undefined ? w.distance : w.totalDistance, null, "km");
  }

  const hr = heartRateFrom(w);
  if (hr.avg === null) hr.avg = num(w.avg_hr);
  if (hr.max === null) hr.max = num(w.max_hr);

  let elevation = num(w.elevation_gain_m);
  if (elevation === null) {
    elevation = toMeters(
      w.elevationUp !== undefined ? w.elevationUp : (w.elevation_up !== undefined ? w.elevation_up : w.elevationAscended),
      null,
      "m"
    );
  }

  // Stable dedupe key. The exporter's workout id IS the HealthKit UUID, so
  // runs the old native app already uploaded are recognised, not duplicated.
  // Without one, synthesise from the start instant so re-posts still dedupe.
  let uuid = String(
    w.id !== undefined ? w.id : (w.uuid !== undefined ? w.uuid : (w.healthkit_uuid !== undefined ? w.healthkit_uuid : ""))
  ).trim();
  if (!uuid) uuid = "hae-" + start.ms + "-" + activity;

  return {
    date: isoInstant(start.ms),
    distance_m: distance_m === null ? 0 : Math.round(distance_m),
    duration_s: duration_s === null ? 0 : Math.round(duration_s),
    avg_hr: round1(hr.avg),
    max_hr: round1(hr.max),
    elevation_gain_m: elevation === null ? null : round1(elevation),
    source_app: String(w.source || "Health Auto Export"),
    healthkit_uuid: uuid,
    activity_type: activity,
  };
}

// ── metrics → recovery_daily rows ──────────────────────────────────────
function mapMetrics(metrics, report) {
  const acc = {}; // day → field → accumulator

  for (const m of metrics) {
    if (!m || typeof m !== "object") continue;
    const key = normName(m.name);
    const field = METRIC_FIELD[key];
    if (!field) {
      // Not an error — the exporter happily sends steps, energy, etc. Report
      // them so a renamed metric is visible instead of silently dropped.
      if (key && report.ignored_metrics.indexOf(key) === -1) report.ignored_metrics.push(key);
      continue;
    }
    const data = Array.isArray(m.data) ? m.data : [];
    for (const p of data) {
      if (p === null || p === undefined) continue;
      let stamp = parseStamp(
        typeof p === "object" ? (p.date !== undefined ? p.date : p.startDate) : null
      );
      let value;

      if (field === "sleep_hours") {
        // Wake-day attribution, exactly as HealthKitService.swift does it.
        const endStamp = parseStamp(
          p.sleepEnd !== undefined ? p.sleepEnd
            : (p.sleep_end !== undefined ? p.sleep_end : p.endDate)
        );
        if (endStamp) stamp = endStamp;
        value = sleepHoursFrom(p);
      } else if (field === "body_mass_kg") {
        value = toKg(typeof p === "object" && p.qty !== undefined ? p.qty : p, m.units);
      } else if (field === "hrv_sdnn_ms") {
        value = toMsHrv(typeof p === "object" && p.qty !== undefined ? p.qty : p, m.units);
      } else {
        value = num(typeof p === "object" && p.qty !== undefined ? p.qty : p);
      }

      if (!stamp || value === null) continue;

      if (!acc[stamp.day]) acc[stamp.day] = {};
      const slot = acc[stamp.day][field] || (acc[stamp.day][field] = { sum: 0, n: 0, max: null, last: null, lastMs: -Infinity });
      slot.sum += value;
      slot.n += 1;
      if (slot.max === null || value > slot.max) slot.max = value;
      if (stamp.ms >= slot.lastMs) { slot.last = value; slot.lastMs = stamp.ms; }
    }
  }

  const out = {};
  for (const day of Object.keys(acc)) {
    const row = {};
    for (const field of Object.keys(acc[day])) {
      const s = acc[day][field];
      const mode = METRIC_MODE[field];
      const v = mode === "mean" ? s.sum / s.n : mode === "max" ? s.max : s.last;
      row[field] = round1(v);
    }
    out[day] = row;
  }
  return out;
}

// ── auth ───────────────────────────────────────────────────────────────
// The poster is an off-the-shelf iOS app, so it can only attach a static
// header or query string — no PocketBase login flow. Accept the shared
// secret from whichever slot the exporter build supports.
function tokenFrom(info) {
  const h = (info && info.headers) || {};
  const q = (info && info.query) || {};
  // PocketBase lowercases header names and turns "-" into "_".
  const candidates = [
    h.x_ingest_token, h["x-ingest-token"],
    h.x_health_token, h["x-health-token"],
    q.token, q.key,
  ];
  const auth = h.authorization || h.Authorization;
  if (auth) candidates.push(String(auth).replace(/^Bearer\s+/i, ""));
  for (const c of candidates) {
    if (c !== undefined && c !== null && String(c).length > 0) return String(c);
  }
  return "";
}

// Length-checked, full-scan compare — no early return on first mismatch.
function tokenMatches(want, got) {
  const a = String(want || ""), b = String(got || "");
  if (a.length < 16) return false; // refuse to be guarded by a trivial secret
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// ── the endpoint's body of work ────────────────────────────────────────
function pickArray(body, key) {
  if (!body || typeof body !== "object") return [];
  const containers = [body.data, body, body.payload];
  for (const c of containers) {
    if (c && typeof c === "object" && Array.isArray(c[key])) return c[key];
  }
  return [];
}

// Flat daily recovery row → exporter-shaped metric entries, so everything
// downstream (day grouping, wake-day sleep, upsert) stays on one code path.
function flatToMetrics(body) {
  const out = [];
  if (!body || typeof body !== "object") return out;
  const date = body.date !== undefined ? body.date : body.day;
  if (date === undefined || date === null) return out;

  for (const key of Object.keys(body)) {
    const field = FLAT_METRIC_KEYS[normName(key)];
    if (!field) continue;
    const v = num(body[key]);
    if (v === null) continue;
    // hrv is declared in ms and weight in kg here — see FLAT_METRIC_KEYS.
    out.push({ name: field, units: field === "hrv_sdnn_ms" ? "ms" : "", data: [{ date: date, qty: v }] });
  }
  return out;
}

// Accepts three shapes, so a paid exporter and a free Shortcut can both post:
//   ① {"data":{"workouts":[…],"metrics":[…]}}   the exporter's REST payload
//   ② {"date":"…","hrv":45,"rhr":48,…}          one flat day (Shortcuts)
//   ③ {"workout":{…}} or a bare flat workout    one session (Shortcuts loop)
function normalizePayload(body) {
  const workouts = pickArray(body, "workouts").slice();
  const metrics = pickArray(body, "metrics").slice();
  const d = body && typeof body === "object" ? body : {};

  const single =
    d.workout && typeof d.workout === "object" ? d.workout
      : (d.activity !== undefined && (d.start !== undefined || d.date !== undefined)) ? d
        : null;
  if (single) workouts.push(single);

  for (const m of flatToMetrics(d)) metrics.push(m);

  return { workouts: workouts, metrics: metrics };
}

function ingest(app, body) {
  const normalized = normalizePayload(body);
  const workouts = normalized.workouts;
  const metrics = normalized.metrics;

  const report = {
    runs_created: 0,
    runs_duplicate: 0,
    runs_unusable: 0,
    recovery_created: 0,
    recovery_updated: 0,
    days_seen: 0,
    ignored_metrics: [],
  };

  if (!workouts.length && !metrics.length) {
    report.warning = "no workouts and no metrics found in the payload";
    return report;
  }

  // ── runs ──
  if (workouts.length) {
    // One read, then dedupe in memory — the same trick the iOS app used so a
    // large first-import backlog can't stall on a POST per workout.
    const seen = {};
    const rows = app.findRecordsByFilter("runs", "id != ''", "-date", 5000, 0);
    for (const r of rows) {
      const u = r.getString("healthkit_uuid");
      if (u) seen[u] = true;
    }

    const col = app.findCollectionByNameOrId("runs");
    // Oldest-first so a truncated import leaves a contiguous history.
    const mapped = [];
    for (const w of workouts) {
      const p = mapWorkout(w);
      if (!p) { report.runs_unusable++; continue; }
      mapped.push(p);
    }
    mapped.sort(function (a, b) { return a.date < b.date ? -1 : a.date > b.date ? 1 : 0; });

    for (const p of mapped) {
      // distance_m and duration_s are `required` in the schema and PocketBase
      // rejects 0 — that's why strength/yoga never landed from the phone
      // either. Skip rather than fail the whole batch.
      if (!(p.distance_m > 0) || !(p.duration_s > 0)) { report.runs_unusable++; continue; }
      if (seen[p.healthkit_uuid]) { report.runs_duplicate++; continue; }

      const rec = new Record(col);
      rec.set("date", p.date);
      rec.set("distance_m", p.distance_m);
      rec.set("duration_s", p.duration_s);
      if (p.avg_hr !== null) rec.set("avg_hr", p.avg_hr);
      if (p.max_hr !== null) rec.set("max_hr", p.max_hr);
      if (p.elevation_gain_m !== null) rec.set("elevation_gain_m", p.elevation_gain_m);
      rec.set("source_app", p.source_app);
      rec.set("healthkit_uuid", p.healthkit_uuid);
      rec.set("activity_type", p.activity_type);
      app.save(rec);

      seen[p.healthkit_uuid] = true;
      report.runs_created++;
    }
  }

  // ── recovery_daily ──
  const byDay = mapMetrics(metrics, report);
  const days = Object.keys(byDay).sort();
  report.days_seen = days.length;

  if (days.length) {
    const col = app.findCollectionByNameOrId("recovery_daily");
    const existing = {};
    const rows = app.findRecordsByFilter("recovery_daily", "id != ''", "-date", 2000, 0);
    for (const r of rows) existing[r.getString("date").slice(0, 10)] = r;

    const FIELDS = ["hrv_sdnn_ms", "resting_hr", "sleep_hours", "vo2max", "body_mass_kg"];
    for (const day of days) {
      const vals = byDay[day];
      const row = existing[day];
      const rec = row || new Record(col);
      if (!row) rec.set("date", pbDay(day));

      // Upsert only the fields actually present: HRV finalises overnight and
      // weight arrives on its own schedule, so a partial post must never null
      // out a value the phone (or an earlier post) already recorded.
      let touched = false;
      for (const f of FIELDS) {
        if (vals[f] !== undefined && vals[f] !== null) { rec.set(f, vals[f]); touched = true; }
      }
      if (!touched) continue;

      app.save(rec);
      if (row) report.recovery_updated++; else report.recovery_created++;
    }
  }

  return report;
}

module.exports = {
  ingest: ingest,
  tokenFrom: tokenFrom,
  tokenMatches: tokenMatches,
  // exported for scripts/test-health-ingest-local.sh
  normName: normName,
  parseStamp: parseStamp,
  activityFromName: activityFromName,
  toMeters: toMeters,
  toKg: toKg,
  toMsHrv: toMsHrv,
  toHours: toHours,
  sleepHoursFrom: sleepHoursFrom,
  heartRateFrom: heartRateFrom,
  mapWorkout: mapWorkout,
  mapMetrics: mapMetrics,
  flatToMetrics: flatToMetrics,
  normalizePayload: normalizePayload,
};
