/// <reference path="../pb_data/types.d.ts" />
//
// M10: health-coach layer — body weight rides along the daily recovery sync.
// The key personalizer for fueling opinions (carbs/kg, protein/kg) and a
// health trend in its own right. Nullable; days without a weigh-in stay null.

migrate(
  (app) => {
    const col = app.findCollectionByNameOrId("recovery_daily");
    col.fields.add(new NumberField({ name: "body_mass_kg" }));
    app.save(col);
  },
  (app) => {
    const col = app.findCollectionByNameOrId("recovery_daily");
    try {
      col.fields.removeByName("body_mass_kg");
    } catch (_) {
      /* already gone */
    }
    app.save(col);
  }
);
