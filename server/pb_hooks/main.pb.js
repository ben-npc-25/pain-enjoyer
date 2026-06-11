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
      const memory = require(`${__hooks}/memory.js`);
      const persona = require(`${__hooks}/persona.js`).PERSONA + memory.memoryBlock(e.app);
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
    const memory = require(`${__hooks}/memory.js`);
    const coach = require(`${__hooks}/coach.js`);
    const engine = require(`${__hooks}/engine.js`);
    const plan = require(`${__hooks}/plan.js`);

    // M4: distill yesterday's conversation into memory BEFORE advising, so
    // this morning's message already knows what was said.
    try {
      const d = memory.distill($app, llm);
      if (!d.skipped) console.log("memory: +" + d.created + " ~" + d.updated);
    } catch (err) {
      console.log("memory distill failed (advice continues):", String(err));
    }
    const persona = require(`${__hooks}/persona.js`).PERSONA + memory.memoryBlock($app);

    // M3: settle yesterday's plan first (done/skipped) so today's advice
    // reflects reality, not intentions.
    const rec = plan.reconcile($app);
    if (rec.done || rec.skipped) {
      console.log("reconcile: " + rec.done + " done, " + rec.skipped + " skipped");
    }

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

// ── POST /api/coach/chat ───────────────────────────────────────────────
// M3: two-way conversation. Athlete message + coach reply both land in
// coach_messages (role athlete|coach) — M4's coach_memory distills from here.

routerAdd(
  "POST",
  "/api/coach/chat",
  (e) => {
    try {
      const llm = require(`${__hooks}/llm.js`);
      const memory = require(`${__hooks}/memory.js`);
      const persona = require(`${__hooks}/persona.js`).PERSONA + memory.memoryBlock(e.app);
      const coach = require(`${__hooks}/coach.js`);
      const engine = require(`${__hooks}/engine.js`);

      const body = e.requestInfo().body;
      const message = String((body && body.message) || "").trim();
      if (!message) return e.json(400, { error: "message is required" });
      if (message.length > 2000) return e.json(400, { error: "message too long (2000 max)" });

      // history BEFORE saving the new message (it goes in the prompt itself)
      const history = coach.recentMessages(e.app, 10);
      coach.saveAthleteMessage(e.app, message);

      const reply = llm.generate(
        "daily",
        persona,
        coach.buildChatPrompt(
          coach.profileFacts(e.app),
          engine.forLLM(engine.computeEngineState(e.app)),
          history,
          coach.latestRunFacts(e.app),
          message
        )
      );
      coach.saveCoachMessage(e.app, "feedback", reply, llm.provider());
      return e.json(200, { reply: reply, provider: llm.provider() });
    } catch (err) {
      console.log("chat failed:", String(err));
      return e.json(502, { error: String(err) });
    }
  },
  $apis.requireAuth()
);

// ── POST /api/coach/plan-week ──────────────────────────────────────────
// M3: generate (or regenerate) next week's plan. Optional ?start=YYYY-MM-DD
// (a Monday) to target a specific week. Code owns the rails; LLM the words.

routerAdd(
  "POST",
  "/api/coach/plan-week",
  (e) => {
    try {
      const llm = require(`${__hooks}/llm.js`);
      const memory = require(`${__hooks}/memory.js`);
      const persona = require(`${__hooks}/persona.js`).PERSONA + memory.memoryBlock(e.app);
      const engine = require(`${__hooks}/engine.js`);
      const plan = require(`${__hooks}/plan.js`);

      let start = null;
      const q = e.request.url.query().get("start");
      if (q) {
        start = new Date(q + "T00:00:00Z");
        if (isNaN(start.getTime())) return e.json(400, { error: "bad start date" });
      }
      plan.reconcile(e.app); // settle the past before planning the future
      const result = plan.generateWeek(e.app, llm, persona, engine, start);
      return e.json(200, result);
    } catch (err) {
      console.log("plan-week failed:", String(err), err && err.stack ? String(err.stack) : "");
      return e.json(502, { error: String(err) });
    }
  },
  $apis.requireAuth()
);

// ── weekly plan cron ───────────────────────────────────────────────────
// Sunday 10:00 UTC (= Sunday evening HKT): plan the week that starts Monday.
// Skips quietly when there's no training history at all.

cronAdd("weekly-plan", $os.getenv("COACH_PLAN_CRON_UTC") || "0 10 * * 0", () => {
  try {
    const llm = require(`${__hooks}/llm.js`);
    const memory = require(`${__hooks}/memory.js`);
    const persona = require(`${__hooks}/persona.js`).PERSONA + memory.memoryBlock($app);
    const engine = require(`${__hooks}/engine.js`);
    const plan = require(`${__hooks}/plan.js`);
    const coach = require(`${__hooks}/coach.js`);

    if (!coach.latestRunFacts($app)) return;
    const result = plan.generateWeek($app, llm, persona, engine, null);
    coach.saveCoachMessage(
      $app, "plan_change",
      "New week planned (" + result.phase + ", " + result.week_start + "): " + result.rationale,
      llm.provider()
    );
    console.log("weekly-plan: generated", result.week_start);
  } catch (err) {
    console.log("weekly-plan failed:", String(err));
  }
});

// ── POST /api/coach/distill ────────────────────────────────────────────
// M4: manually trigger memory distillation (the morning cron also does it).
// Returns what changed so the app's Memory screen can refresh meaningfully.

routerAdd(
  "POST",
  "/api/coach/distill",
  (e) => {
    try {
      const llm = require(`${__hooks}/llm.js`);
      const memory = require(`${__hooks}/memory.js`);
      return e.json(200, memory.distill(e.app, llm));
    } catch (err) {
      console.log("distill failed:", String(err));
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
