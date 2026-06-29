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

    // M7 Phase 2: settling done/skipped (or a skip) may warrant a mid-week
    // re-plan of the remainder. Code decides IF; the LLM only runs if so.
    try {
      plan.replanRemainder($app, llm, persona, engine, coach, {});
    } catch (err) {
      console.log("replan failed (advice continues):", String(err));
    }

    const facts = coach.latestRunFacts($app);
    if (!facts) return; // nothing synced yet — stay quiet

    const state = engine.computeEngineState($app);

    // M5: red light → pull today's planned workout (code decides, the
    // message below explains).
    const pulled = plan.pullTodayIfRed($app, state);
    if (pulled) console.log("pulled today's " + pulled.was_type + " " + pulled.was_km + " km (red light)");

    // M5: adaptive proactivity — engagement score decides today's cadence.
    const engagement = require(`${__hooks}/engagement.js`);
    const eng = engagement.cadence($app);
    const since = coach.daysSinceLastDaily($app);
    let send =
      eng.level === "daily" ||
      since === null ||
      (eng.level === "every_2_3_days" && since >= 2) ||
      (eng.level === "weekly_digest" && since >= 7);
    if (pulled || eng.changed) send = true; // never silently pull or downshift
    if (!send) {
      console.log("morning-coach: quiet day (cadence " + eng.level + ", score " + eng.score + ")");
      return;
    }

    let notes =
      "\nThis is your proactive morning check-in to the athlete. If the most " +
      "recent run is more than 3 days old, don't analyze a stale run — speak " +
      "to where the athlete is right now (the traffic light and athlete " +
      "status tell you).";
    if (pulled) {
      notes +=
        "\nIMPORTANT: you just PULLED today's planned " + pulled.was_type + " " +
        pulled.was_km + " km because the light is red. Lead with that — " +
        "explain why plainly and give the recovery alternative.";
    }
    if (eng.changed) {
      notes +=
        "\nYour check-in cadence just changed to '" + eng.level + "' (engagement " +
        eng.score + "). Acknowledge the new rhythm briefly — make clear you're " +
        "still here and they can ping you anytime. Never ghost.";
    }

    const engineFacts = engine.forLLM(state);
    const advice = llm.generate(
      "daily",
      persona,
      coach.buildDailyPrompt(coach.profileFacts($app), facts, engineFacts) + notes
    );
    coach.saveCoachMessage($app, "daily", advice, llm.provider());
    console.log("morning-coach: message stored (cadence " + eng.level + ")");
  } catch (err) {
    console.log("morning-coach failed:", String(err));
  }
});

// ── M7 Phase 2: on-sync mid-week re-plan ───────────────────────────────
// A freshly synced run for the CURRENT week settles the plan (done/skipped)
// and may trigger a deterministic re-plan of the remainder. Historical
// backfill runs (older than this week) are ignored so a first-sync flood
// can't churn the plan. One LLM-spending replan per day (guarded in plan.js).

onRecordAfterCreateSuccess((e) => {
  try {
    const runDate = String(e.record.getString("date")).slice(0, 10);
    const now = new Date();
    const m = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
    m.setUTCDate(m.getUTCDate() - ((m.getUTCDay() + 6) % 7)); // this week's Monday
    if (runDate >= m.toISOString().slice(0, 10)) {
      const llm = require(`${__hooks}/llm.js`);
      const memory = require(`${__hooks}/memory.js`);
      const persona = require(`${__hooks}/persona.js`).PERSONA + memory.memoryBlock(e.app);
      const engine = require(`${__hooks}/engine.js`);
      const coach = require(`${__hooks}/coach.js`);
      const plan = require(`${__hooks}/plan.js`);
      plan.reconcile(e.app);
      plan.replanRemainder(e.app, llm, persona, engine, coach, {});
    }
  } catch (err) {
    console.log("on-sync replan failed (run still saved):", String(err));
  }
  e.next();
}, "runs");

// ── POST /api/coach/replan ─────────────────────────────────────────────
// M7 Phase 2: manually trigger a mid-week re-plan (the app's "re-plan now"
// and the offline test use this). ?force=1 bypasses the once-per-day guard.

routerAdd(
  "POST",
  "/api/coach/replan",
  (e) => {
    try {
      const llm = require(`${__hooks}/llm.js`);
      const memory = require(`${__hooks}/memory.js`);
      const persona = require(`${__hooks}/persona.js`).PERSONA + memory.memoryBlock(e.app);
      const engine = require(`${__hooks}/engine.js`);
      const coach = require(`${__hooks}/coach.js`);
      const plan = require(`${__hooks}/plan.js`);
      plan.reconcile(e.app);
      const force = e.request.url.query().get("force") === "1";
      const today = e.request.url.query().get("today") || null; // test seam
      return e.json(200, plan.replanRemainder(e.app, llm, persona, engine, coach, { force: force, today: today }));
    } catch (err) {
      console.log("replan failed:", String(err), err && err.stack ? String(err.stack) : "");
      return e.json(502, { error: String(err) });
    }
  },
  $apis.requireAuth()
);

// ── POST /api/coach/trends-review ──────────────────────────────────────
// M6: on-demand coach commentary for the Trends screen (kind weekly_review).

routerAdd(
  "POST",
  "/api/coach/trends-review",
  (e) => {
    try {
      const llm = require(`${__hooks}/llm.js`);
      const memory = require(`${__hooks}/memory.js`);
      const persona = require(`${__hooks}/persona.js`).PERSONA + memory.memoryBlock(e.app);
      const coach = require(`${__hooks}/coach.js`);
      const engine = require(`${__hooks}/engine.js`);

      const engineFacts = engine.forLLM(engine.computeEngineState(e.app));
      const trends = engine.trendFacts(e.app);
      const prompt =
        "Today is " + new Date().toISOString().slice(0, 10) + ".\n\n" +
        "Training engine — deterministic state (quote numbers verbatim, never recompute): " +
        JSON.stringify(engineFacts) +
        "\n\nTrend summaries (pre-computed): " + JSON.stringify(trends) +
        "\n\nThe athlete is reading their trend charts. Respond with STRICT JSON " +
        "only (no fences, no prose around it):\n" +
        '{"volume":"…","hrv":"…","resting_hr":"…","vo2max_health":"…","fitness":"…"}\n' +
        "Each value: 1–2 plain sentences interpreting that specific chart for " +
        "this athlete. vo2max_health should read the VO2max + recovery picture " +
        "as a personal-health signal. No greetings, no headings.";

      let parsed;
      try {
        parsed = llm.parseJSONLoose(llm.generate("trends", persona, prompt));
      } catch (err) {
        console.log("trends JSON unusable, retrying once:", String(err));
        parsed = llm.parseJSONLoose(llm.generate("trends", persona, prompt));
      }
      const clean = {};
      ["volume", "hrv", "resting_hr", "vo2max_health", "fitness"].forEach(function (k) {
        if (parsed && typeof parsed[k] === "string") clean[k] = parsed[k].slice(0, 600);
      });
      coach.saveCoachMessage(e.app, "weekly_review", JSON.stringify(clean), llm.provider());
      return e.json(200, { review: clean, provider: llm.provider() });
    } catch (err) {
      console.log("trends-review failed:", String(err));
      return e.json(502, { error: String(err) });
    }
  },
  $apis.requireAuth()
);

// ── POST /api/coach/ping · GET /api/coach/engagement ──────────────────
// M5: the app reports opens (the one signal only the client knows); the
// engagement endpoint exposes the score/cadence for transparency + tests.

routerAdd(
  "POST",
  "/api/coach/ping",
  (e) => {
    try {
      const engagement = require(`${__hooks}/engagement.js`);
      return e.json(200, engagement.ping(e.app));
    } catch (err) {
      console.log("ping failed:", String(err));
      return e.json(502, { error: String(err) });
    }
  },
  $apis.requireAuth()
);

routerAdd(
  "GET",
  "/api/coach/engagement",
  (e) => {
    try {
      const engagement = require(`${__hooks}/engagement.js`);
      return e.json(200, engagement.score(e.app));
    } catch (err) {
      console.log("engagement failed:", String(err));
      return e.json(502, { error: String(err) });
    }
  },
  $apis.requireAuth()
);

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

// ── POST /api/coach/run-feedback ───────────────────────────────────────
// M7: the coach reacts to the most recent run and the reply is saved ON that
// run (runs.coach_note) — NOT posted to coach_messages, so it never lands in
// the chat thread. The logged effort rides into the prompt, so the reaction
// reflects how hard the athlete said it was.

routerAdd(
  "POST",
  "/api/coach/run-feedback",
  (e) => {
    try {
      const llm = require(`${__hooks}/llm.js`);
      const memory = require(`${__hooks}/memory.js`);
      const persona = require(`${__hooks}/persona.js`).PERSONA + memory.memoryBlock(e.app);
      const coach = require(`${__hooks}/coach.js`);
      const engine = require(`${__hooks}/engine.js`);

      const facts = coach.latestRunFacts(e.app);
      if (!facts) return e.json(400, { error: "no runs synced yet" });

      const engineFacts = engine.forLLM(engine.computeEngineState(e.app));
      const prompt =
        coach.buildDailyPrompt(coach.profileFacts(e.app), facts, engineFacts) +
        "\n\nThis is a PRIVATE note saved on THIS run (not a chat message). React " +
        "to how this run went, weighing the effort the athlete logged. Keep it to " +
        "2-3 sentences, specific to this run — no greeting, no sign-off.";
      const note = llm.generate("daily", persona, prompt);

      const runs = e.app.findRecordsByFilter("runs", "id != ''", "-date", 1, 0);
      if (runs.length) {
        runs[0].set("coach_note", note);
        e.app.save(runs[0]);
      }
      return e.json(200, { coach_note: note });
    } catch (err) {
      console.log("run-feedback failed:", String(err), err && err.stack ? String(err.stack) : "");
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
      const coach = require(`${__hooks}/coach.js`);
      const engine = require(`${__hooks}/engine.js`);
      const plan = require(`${__hooks}/plan.js`);

      // M7: feed what the athlete told the coach straight into the plan prompt
      // so "tell the coach, then hit Plan" actually changes the plan. Durable
      // facts still accrue via the daily distill cron + the memory block below.
      const persona = require(`${__hooks}/persona.js`).PERSONA + memory.memoryBlock(e.app);
      const convo = coach.conversationText(e.app, 8);

      let start = null;
      const q = e.request.url.query().get("start");
      if (q) {
        start = new Date(q + "T00:00:00Z");
        if (isNaN(start.getTime())) return e.json(400, { error: "bad start date" });
      }
      plan.reconcile(e.app); // settle the past before planning the future
      const result = plan.generateWeek(e.app, llm, persona, engine, start, convo);
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
    // Sunday cron plans the UPCOMING week (generateWeek now defaults to the
    // current week, so pass next Monday explicitly).
    const result = plan.generateWeek($app, llm, persona, engine, plan.nextMonday(new Date()), coach.conversationText($app, 8));
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
