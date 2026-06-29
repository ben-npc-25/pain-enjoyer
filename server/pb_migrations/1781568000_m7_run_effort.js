/// <reference path="../pb_data/types.d.ts" />
//
// M7 Phase 1: per-run "effort" — the subjective field HealthKit can't capture,
// captured as perceived effort / RPE (the third part of Ben's natural log:
// distance, pace, how hard it was). 1–5 (1 = very easy … 5 = max effort),
// nullable. Distinct from `notes` (free text). Unset / 0 = no rating.

migrate(
  (app) => {
    const col = app.findCollectionByNameOrId("runs");
    col.fields.add(new NumberField({ name: "effort", min: 0, max: 5 }));
    app.save(col);
  },
  (app) => {
    const col = app.findCollectionByNameOrId("runs");
    try {
      col.fields.removeByName("effort");
    } catch (_) {
      /* already gone */
    }
    app.save(col);
  }
);
