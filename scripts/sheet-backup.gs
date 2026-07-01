// sheet-backup.gs — one-way backup of the Pain Enjoyer run log into this sheet.
//
// SETUP (once):
//   1. Open your Google Sheet → Extensions → Apps Script.
//   2. Paste this file in, Save.
//   3. Project Settings (gear) → Script properties → add:
//        BACKUP_SECRET = <a long random string>
//   4. Deploy → New deployment → type "Web app":
//        Execute as: Me   ·   Who has access: Anyone
//      Copy the resulting /exec URL.
//   5. On the Pi, set in the service env and restart:
//        BACKUP_SHEET_URL=<the /exec URL>
//        BACKUP_SHEET_SECRET=<the same random string>
//
// The app/Pi POSTs the full log here; this rewrites the "App Backup" tab. It
// never reads back, so there are no two-way conflicts — your other tabs are
// untouched.

function doPost(e) {
  var out = function (obj) {
    return ContentService.createTextOutput(JSON.stringify(obj))
      .setMimeType(ContentService.MimeType.JSON);
  };
  try {
    var body = JSON.parse((e && e.postData && e.postData.contents) || "{}");
    var secret = PropertiesService.getScriptProperties().getProperty("BACKUP_SECRET");
    if (!secret || body.secret !== secret) return out({ ok: false, error: "bad secret" });

    var rows = body.runs || [];
    var ss = SpreadsheetApp.getActiveSpreadsheet();
    var sh = ss.getSheetByName("App Backup") || ss.insertSheet("App Backup");
    sh.clearContents();

    var headers = ["Date", "Distance (km)", "Duration", "Pace", "Avg HR", "Effort", "Source", "Notes", "Coach note"];
    var values = [headers];
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i];
      values.push([r.date, r.distance_km, r.duration, r.pace, r.avg_hr, r.effort, r.source, r.notes, r.coach_note]);
    }
    sh.getRange(1, 1, values.length, headers.length).setValues(values);
    sh.getRange(1, 1, 1, headers.length).setFontWeight("bold");
    sh.getRange("J1").setValue("Last backup: " + new Date());
    return out({ ok: true, rows: rows.length });
  } catch (err) {
    return out({ ok: false, error: String(err) });
  }
}
