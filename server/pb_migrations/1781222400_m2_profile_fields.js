/// <reference path="../pb_data/types.d.ts" />
//
// M2: athlete_profile gains injury tracking + HRmax.
//  - injured / injury_note / return_to_run_date: the engine must respect the
//    human state (injured → 🔴 regardless of how good HRV looks).
//  - hr_max: anchors the 80/20 easy/hard HR threshold. Optional — when unset
//    the engine estimates from observed history and labels it as an estimate.

migrate(
  (app) => {
    const col = app.findCollectionByNameOrId("athlete_profile");
    col.fields.add(new BoolField({ name: "injured" }));
    col.fields.add(new TextField({ name: "injury_note", max: 2000 }));
    col.fields.add(new DateField({ name: "return_to_run_date" }));
    col.fields.add(new NumberField({ name: "hr_max" }));
    app.save(col);
  },
  (app) => {
    const col = app.findCollectionByNameOrId("athlete_profile");
    ["injured", "injury_note", "return_to_run_date", "hr_max"].forEach((n) => {
      try {
        col.fields.removeByName(n);
      } catch (_) {
        /* already gone */
      }
    });
    app.save(col);
  }
);
