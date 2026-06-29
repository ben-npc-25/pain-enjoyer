/// <reference path="../pb_data/types.d.ts" />
//
// M7: the coach's reaction to a specific run lives ON the run (coach_note),
// not in the chat thread. The athlete logs effort → the coach reacts → the
// note is saved here and shown on that activity. Chat stays for conversation;
// you reference an activity there if you want to talk about it.

migrate(
  (app) => {
    const col = app.findCollectionByNameOrId("runs");
    col.fields.add(new TextField({ name: "coach_note", max: 4000 }));
    app.save(col);
  },
  (app) => {
    const col = app.findCollectionByNameOrId("runs");
    try {
      col.fields.removeByName("coach_note");
    } catch (_) {
      /* already gone */
    }
    app.save(col);
  }
);
