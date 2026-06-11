/// <reference path="../pb_data/types.d.ts" />
//
// M3: athlete notes on a run ("felt heavy", "ankle twinged at km 4").
// Subjective context is LLM territory (PLAN.md §1) — the engine never reads
// this; chat and daily-advice prompts do.

migrate(
  (app) => {
    const col = app.findCollectionByNameOrId("runs");
    col.fields.add(new TextField({ name: "notes", max: 2000 }));
    app.save(col);
  },
  (app) => {
    const col = app.findCollectionByNameOrId("runs");
    try {
      col.fields.removeByName("notes");
    } catch (_) {
      /* already gone */
    }
    app.save(col);
  }
);
