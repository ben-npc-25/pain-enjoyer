/// <reference path="../pb_data/types.d.ts" />
//
// Initial schema — the 8 collections from PLAN.md §6.
// PocketBase ≥ 0.23 migration API. Applied automatically on `pocketbase serve`.
//
// All collections are gated to authenticated users (single-user POC: the one
// app user created by setup-pi.sh). Relations are plain text IDs for now —
// promoted to real relation fields in M3 when plan-vs-actual matching lands.

const AUTH_RULE = '@request.auth.id != ""';

// Shared helpers — every collection gets auth-only CRUD rules + timestamps.
function timestamps() {
  return [
    { name: "created", type: "autodate", onCreate: true },
    { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
  ];
}

function baseCollection(name, fields, indexes) {
  return new Collection({
    type: "base",
    name: name,
    listRule: AUTH_RULE,
    viewRule: AUTH_RULE,
    createRule: AUTH_RULE,
    updateRule: AUTH_RULE,
    deleteRule: AUTH_RULE,
    fields: fields.concat(timestamps()),
    indexes: indexes || [],
  });
}

migrate(
  (app) => {
    // ── athlete_profile (singleton row) ────────────────────────────────
    app.save(
      baseCollection("athlete_profile", [
        { name: "race_name", type: "text" },
        { name: "race_date", type: "date" },
        { name: "goal_time_s", type: "number" },
        {
          name: "methodology",
          type: "select",
          maxSelect: 1,
          values: ["hybrid_vdot_8020", "daniels", "hansons", "freeflow"],
        },
        { name: "days_per_week", type: "number" },
        { name: "long_run_day", type: "text" },
        { name: "personality_json", type: "json", maxSize: 1048576 },
        {
          name: "proactivity_level",
          type: "select",
          maxSelect: 1,
          values: ["daily", "every_2_3_days", "weekly_digest"],
        },
      ])
    );

    // ── runs (actuals, synced from HealthKit) ──────────────────────────
    app.save(
      baseCollection(
        "runs",
        [
          { name: "date", type: "date", required: true },
          { name: "distance_m", type: "number", required: true },
          { name: "duration_s", type: "number", required: true },
          { name: "avg_hr", type: "number" },
          { name: "max_hr", type: "number" },
          { name: "cadence_spm", type: "number" },
          { name: "elevation_gain_m", type: "number" },
          { name: "splits", type: "json", maxSize: 1048576 },
          { name: "source_app", type: "text" },
          { name: "healthkit_uuid", type: "text" },
          { name: "matched_workout_id", type: "text" },
        ],
        [
          // Dedupe: background delivery + manual sync can both push the same workout.
          "CREATE UNIQUE INDEX idx_runs_hk_uuid ON runs (healthkit_uuid) WHERE healthkit_uuid != ''",
          "CREATE INDEX idx_runs_date ON runs (date)",
        ]
      )
    );

    // ── recovery_daily (HRV / RHR / sleep — push-pull inputs) ──────────
    app.save(
      baseCollection(
        "recovery_daily",
        [
          { name: "date", type: "date", required: true },
          { name: "hrv_sdnn_ms", type: "number" },
          { name: "resting_hr", type: "number" },
          { name: "sleep_hours", type: "number" },
          { name: "vo2max", type: "number" },
        ],
        ["CREATE UNIQUE INDEX idx_recovery_date ON recovery_daily (date)"]
      )
    );

    // ── plan_weeks ─────────────────────────────────────────────────────
    app.save(
      baseCollection("plan_weeks", [
        { name: "week_idx", type: "number", required: true },
        {
          name: "phase",
          type: "select",
          maxSelect: 1,
          values: ["base", "build", "peak", "taper"],
        },
        { name: "rationale", type: "text", max: 10000 },
      ])
    );

    // ── planned_workouts ───────────────────────────────────────────────
    app.save(
      baseCollection(
        "planned_workouts",
        [
          { name: "date", type: "date", required: true },
          {
            name: "type",
            type: "select",
            maxSelect: 1,
            values: ["E", "T", "I", "R", "MP", "LR", "rest"],
          },
          { name: "distance_m", type: "number" },
          { name: "target_pace_low_skm", type: "number" }, // sec per km
          { name: "target_pace_high_skm", type: "number" },
          { name: "description", type: "text", max: 5000 },
          {
            name: "status",
            type: "select",
            maxSelect: 1,
            values: ["planned", "done", "skipped", "modified"],
          },
          { name: "plan_week_id", type: "text" },
        ],
        ["CREATE INDEX idx_planned_date ON planned_workouts (date)"]
      )
    );

    // ── coach_messages ─────────────────────────────────────────────────
    app.save(
      baseCollection("coach_messages", [
        {
          name: "role",
          type: "select",
          maxSelect: 1,
          values: ["coach", "athlete"],
        },
        {
          name: "kind",
          type: "select",
          maxSelect: 1,
          values: ["daily", "weekly_review", "plan_change", "feedback", "checkin_question"],
        },
        { name: "content", type: "text", max: 20000, required: true },
        { name: "provider", type: "text" }, // which LLM produced it (audit)
      ])
    );

    // ── coach_memory (the "knows you" layer) ───────────────────────────
    app.save(
      baseCollection("coach_memory", [
        { name: "fact", type: "text", max: 2000, required: true },
        { name: "confidence", type: "number" }, // 0..1
        { name: "learned_from", type: "text" },
        { name: "last_reinforced", type: "date" },
      ])
    );

    // ── engagement (adaptive proactivity signal) ───────────────────────
    app.save(
      baseCollection(
        "engagement",
        [
          { name: "date", type: "date", required: true },
          { name: "opens", type: "number" },
          { name: "checkin_responded", type: "bool" },
          { name: "workout_completed", type: "bool" },
        ],
        ["CREATE UNIQUE INDEX idx_engagement_date ON engagement (date)"]
      )
    );
  },
  (app) => {
    // down — drop everything (order doesn't matter, no real relations yet)
    const names = [
      "athlete_profile",
      "runs",
      "recovery_daily",
      "plan_weeks",
      "planned_workouts",
      "coach_messages",
      "coach_memory",
      "engagement",
    ];
    for (const n of names) {
      try {
        app.delete(app.findCollectionByNameOrId(n));
      } catch (_) {
        /* already gone */
      }
    }
  }
);
