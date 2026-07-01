// backup.js — one-way export of the run log to a Google Sheet (the durable,
// human-readable safety net Ben trusts). require()'d from main.pb.js.
//
// The app/Pi pushes; the sheet is never read back — no two-way conflicts. The
// destination is a Google Apps Script web app (see scripts/sheet-backup.gs);
// configure BACKUP_SHEET_URL + BACKUP_SHEET_SECRET in the Pi env.

function fmtDur(s) {
  s = Math.round(s || 0);
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  const pad = (n) => (n < 10 ? "0" : "") + n;
  return h > 0 ? h + ":" + pad(m) + ":" + pad(sec) : m + ":" + pad(sec);
}

function fmtPace(secPerKm) {
  const m = Math.floor(secPerKm / 60), s = Math.round(secPerKm % 60);
  return (s === 60 ? m + 1 + ":00" : m + ":" + (s < 10 ? "0" : "") + s) + "/km";
}

function pushToSheet(app) {
  const url = $os.getenv("BACKUP_SHEET_URL");
  if (!url) return { skipped: true, reason: "BACKUP_SHEET_URL not configured" };
  const secret = $os.getenv("BACKUP_SHEET_SECRET") || "";

  const recs = app.findRecordsByFilter("runs", "id != ''", "-date", 2000, 0);
  const rows = [];
  for (const r of recs) {
    const distM = r.getFloat("distance_m"), durS = r.getFloat("duration_s");
    rows.push({
      date: String(r.getString("date")).slice(0, 10),
      distance_km: distM ? Math.round((distM / 1000) * 100) / 100 : "",
      duration: durS ? fmtDur(durS) : "",
      pace: distM > 0 && durS > 0 ? fmtPace(durS / (distM / 1000)) : "",
      avg_hr: r.getFloat("avg_hr") || "",
      effort: r.getFloat("effort") || "",
      source: r.getString("source_app") || "",
      notes: r.getString("notes") || "",
      coach_note: r.getString("coach_note") || "",
    });
  }

  const res = $http.send({
    url: url,
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ secret: secret, runs: rows }),
    timeout: 60,
  });
  if (res.statusCode !== 200) {
    throw new Error("sheet backup HTTP " + res.statusCode + ": " + res.raw);
  }
  return { backed_up: rows.length };
}

module.exports = { pushToSheet: pushToSheet };
