/// <reference path="../pb_data/types.d.ts" />
//
// M9: macro_weeks — the goal-anchored training block, one row per week from
// generation day to race week. Deterministic output of macro.js; the weekly
// generator (plan.js) caps itself to these targets and the app charts the
// whole arc. Regenerating the block wipes and rewrites all rows.

const AUTH_RULE = '@request.auth.id != ""';

migrate(
  (app) => {
    app.save(
      new Collection({
        type: "base",
        name: "macro_weeks",
        listRule: AUTH_RULE,
        viewRule: AUTH_RULE,
        createRule: AUTH_RULE,
        updateRule: AUTH_RULE,
        deleteRule: AUTH_RULE,
        fields: [
          { name: "week_idx", type: "number", required: true },
          { name: "week_start", type: "date", required: true },
          {
            name: "phase",
            type: "select",
            maxSelect: 1,
            values: ["base", "build", "peak", "taper"],
          },
          { name: "target_km", type: "number" },
          { name: "long_run_km", type: "number" },
          { name: "quality_sessions", type: "number" },
          { name: "is_cutback", type: "bool" },
          { name: "milestone", type: "text", max: 40 }, // "", final_long_run, race_week
          { name: "created", type: "autodate", onCreate: true },
          { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
        ],
        indexes: [
          "CREATE UNIQUE INDEX idx_macro_week_idx ON macro_weeks (week_idx)",
          "CREATE INDEX idx_macro_week_start ON macro_weeks (week_start)",
        ],
      })
    );
  },
  (app) => {
    try {
      app.delete(app.findCollectionByNameOrId("macro_weeks"));
    } catch (_) {
      /* already gone */
    }
  }
);
