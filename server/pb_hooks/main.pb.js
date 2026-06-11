/// <reference path="../pb_data/types.d.ts" />
//
// main.pb.js — M0 walking skeleton:
//   POST /api/coach/advise   phone (or test script) → facts → LLM → advice
//   cron "morning-coach"     daily message computed server-side; phone
//                            fetches it on open (free Apple account = no
//                            remote push, see PLAN.md risk #1)
//
// ⚠ PocketBase runs each handler in a FRESH JSVM — shared logic lives in
//   coach.js / llm.js / persona.js and is require()'d INSIDE every handler.

// ── POST /api/coach/advise ─────────────────────────────────────────────
// The M0 end-to-end slice. Auth required (the single app user).

routerAdd(
  "POST",
  "/api/coach/advise",
  (e) => {
    // Catch-all so failures return a real message instead of PB's generic 400
    // (single-user app — exposing the error detail to ourselves is fine).
    try {
      const llm = require(`${__hooks}/llm.js`);
      const persona = require(`${__hooks}/persona.js`).PERSONA;
      const coach = require(`${__hooks}/coach.js`);
      const engine = require(`${__hooks}/engine.js`);

      const facts = coach.latestRunFacts(e.app);
      if (!facts) {
        return e.json(400, {
          error: "no runs synced yet — push a run first, then ask the coach",
        });
      }

      // M2: deterministic engine state rides along with every advice call.
      const engineFacts = engine.forLLM(engine.computeEngineState(e.app));
      const advice = llm.generate(
        "daily",
        persona,
        coach.buildDailyPrompt(coach.profileFacts(e.app), facts, engineFacts)
      );
      coach.saveCoachMessage(e.app, "daily", advice, llm.provider());
      return e.json(200, {
        advice: advice,
        provider: llm.provider(),
        facts: facts, // returned so the app can show what the coach saw
        engine: engineFacts,
      });
    } catch (err) {
      console.log("advise failed:", String(err), err && err.stack ? String(err.stack) : "");
      return e.json(502, {
        error: String(err),
        stack: err && err.stack ? String(err.stack) : null,
      });
    }
  },
  $apis.requireAuth()
);

// ── morning coach cron ─────────────────────────────────────────────────
// NOTE: PocketBase cron runs in UTC. Default "0 22 * * *" = 06:00 HKT.
// The message is stored in coach_messages; the app shows the latest "daily"
// message on open + schedules a local notification (no APNs on free account).

cronAdd("morning-coach", $os.getenv("COACH_CRON_UTC") || "0 22 * * *", () => {
  try {
    const llm = require(`${__hooks}/llm.js`);
    const persona = require(`${__hooks}/persona.js`).PERSONA;
    const coach = require(`${__hooks}/coach.js`);
    const engine = require(`${__hooks}/engine.js`);

    const facts = coach.latestRunFacts($app);
    if (!facts) return; // nothing synced yet — stay quiet

    const engineFacts = engine.forLLM(engine.computeEngineState($app));
    const advice = llm.generate(
      "daily",
      persona,
      coach.buildDailyPrompt(coach.profileFacts($app), facts, engineFacts) +
        "\nThis is your proactive morning check-in to the athlete. If the most " +
        "recent run is more than 3 days old, don't analyze a stale run — speak " +
        "to where the athlete is right now (the traffic light and athlete " +
        "status tell you)."
    );
    coach.saveCoachMessage($app, "daily", advice, llm.provider());
    console.log("morning-coach: message stored");
  } catch (err) {
    console.log("morning-coach failed:", String(err));
  }
});

// ── GET /api/coach/engine ──────────────────────────────────────────────
// M2: the deterministic engine state (VDOT, zones, ACWR, recovery, 80/20,
// traffic light). Auth required. The app renders this; the LLM only ever
// sees the forLLM() projection embedded in prompts.

routerAdd(
  "GET",
  "/api/coach/engine",
  (e) => {
    try {
      const engine = require(`${__hooks}/engine.js`);
      const state = engine.computeEngineState(e.app);
      state.for_llm = engine.forLLM(state);
      return e.json(200, state);
    } catch (err) {
      console.log("engine failed:", String(err), err && err.stack ? String(err.stack) : "");
      return e.json(502, { error: String(err) });
    }
  },
  $apis.requireAuth()
);

// ── GET /api/coach/health ──────────────────────────────────────────────
// Unauthenticated liveness probe so the tunnel + service can be checked
// without credentials (returns no data).

routerAdd("GET", "/api/coach/health", (e) => {
  return e.json(200, { ok: true, provider: $os.getenv("LLM_PROVIDER") || "gemini" });
});
