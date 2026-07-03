/// <reference path="../pb_data/types.d.ts" />
//
// M8: cross-training visibility. The runs collection gains `activity_type`
// ("running", "hiking", "walking", "cycling", "swimming", "strength", …).
// Empty = running (every pre-M8 row was a run). Non-running rows are evidence
// the athlete is active — they feed the coach's facts but are excluded from
// all running math (VDOT / ACWR / 80-20 / plan reconcile) by filter.

migrate(
  (app) => {
    const col = app.findCollectionByNameOrId("runs");
    col.fields.add(new TextField({ name: "activity_type", max: 40 }));
    app.save(col);
  },
  (app) => {
    const col = app.findCollectionByNameOrId("runs");
    try {
      col.fields.removeByName("activity_type");
    } catch (_) {
      /* already gone */
    }
    app.save(col);
  }
);
