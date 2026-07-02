/// <reference path="../pb_data/types.d.ts" />
//
// M7: let the athlete drive two things the plan rails previously owned alone —
//  - run_days: which weekdays he runs (comma-separated full names, e.g.
//    "Monday,Wednesday,Thursday,Saturday"). The planner runs exactly these and
//    rests the others, instead of picking days from a bare count.
//  - weekly_target_km: his desired weekly volume. Raises the cap (bounded by a
//    safety ceiling in plan.js) so he can push harder than the engine's default
//    without talking past a hard rail in chat.

migrate(
  (app) => {
    const col = app.findCollectionByNameOrId("athlete_profile");
    col.fields.add(new TextField({ name: "run_days", max: 120 }));
    col.fields.add(new NumberField({ name: "weekly_target_km", min: 0, max: 300 }));
    app.save(col);
  },
  (app) => {
    const col = app.findCollectionByNameOrId("athlete_profile");
    ["run_days", "weekly_target_km"].forEach((n) => {
      try { col.fields.removeByName(n); } catch (_) { /* already gone */ }
    });
    app.save(col);
  }
);
