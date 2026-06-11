// memory.js — M4 "the coach knows you". require()'d module (fresh-JSVM rule).
//
// Durable athlete facts distilled from the chat thread by a cheap LLM call,
// stored in coach_memory, and injected as a stable block after the persona in
// every prompt. The LLM proposes facts; CODE owns persistence: upsert only —
// nothing is ever auto-deleted (a hallucinated omission must not erase
// memory; deletion is the athlete's swipe in the app).

var DISTILL_SYSTEM =
  "You maintain a running coach's long-term memory about one athlete. " +
  "From the conversation, extract durable, coaching-relevant facts: " +
  "preferences (tone, data vs pep talk), injuries with dates, constraints, " +
  "goals, behavioral patterns. NOT transient states ('tired today'), NOT " +
  "training metrics the system already computes (VDOT, load, paces). " +
  "Output STRICT JSON only: {\"facts\":[{\"id\":null,\"fact\":\"...\"," +
  "\"confidence\":0.8}]} — at most 15 facts, each ≤200 chars. Reuse an " +
  "existing fact's id to update or reinforce it; use null id for new facts; " +
  "omit existing facts that are simply unchanged.";

function isoDay(d) {
  return d.toISOString().slice(0, 10);
}

function parseJSONLoose(text) {
  let t = String(text).trim();
  const fence = t.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (fence) t = fence[1].trim();
  const start = t.indexOf("{");
  const end = t.lastIndexOf("}");
  if (start === -1 || end <= start) throw new Error("distill returned no JSON object");
  return JSON.parse(t.slice(start, end + 1));
}

function listFacts(app, limit) {
  return app.findRecordsByFilter(
    "coach_memory", "id != ''", "-confidence,-last_reinforced", limit || 50, 0
  );
}

// The stable-ish prompt block (PLAN.md: persona prefix + memory block).
// Empty string when there's nothing yet — pre-M4 behavior unchanged.
function memoryBlock(app) {
  const facts = listFacts(app, 12);
  if (!facts.length) return "";
  let block = "\n\nWhat you know about this athlete (long-term memory, most confident first):\n";
  for (const f of facts) {
    block += "- " + f.getString("fact") + "\n";
  }
  return block;
}

// Distill recent conversation into memory. One cheap LLM call; skips (free)
// when the athlete hasn't said anything new in the window.
function distill(app, llm) {
  const cutoff = new Date(Date.now() - 48 * 3600000)
    .toISOString().replace("T", " ").replace(/\.\d{3}Z$/, ".000Z");

  const athleteSpoke = app.findRecordsByFilter(
    "coach_messages", "role = 'athlete' && created >= '" + cutoff + "'", "-created", 1, 0
  );
  if (!athleteSpoke.length) return { skipped: true, reason: "no athlete messages in 48h" };

  const msgs = app.findRecordsByFilter(
    "coach_messages", "created >= '" + cutoff + "'", "created", 30, 0
  );
  let convo = "";
  for (const m of msgs) {
    convo += (m.getString("role") === "athlete" ? "Athlete: " : "Coach: ") +
      m.getString("content").slice(0, 500) + "\n";
  }

  const existing = listFacts(app, 50);
  let known = "";
  for (const f of existing) {
    known += f.id + " · " + (f.getFloat("confidence") || 0.5) + " · " + f.getString("fact") + "\n";
  }

  const prompt =
    "Today is " + isoDay(new Date()) + ".\n\n" +
    "Existing memory (id · confidence · fact):\n" + (known || "(empty)\n") +
    "\nConversation from the last 48 hours:\n" + convo +
    "\nReturn the JSON now.";

  let parsed;
  try {
    parsed = parseJSONLoose(llm.generate("distill", DISTILL_SYSTEM, prompt));
  } catch (err) {
    console.log("distill JSON unusable, retrying once:", String(err));
    parsed = parseJSONLoose(llm.generate("distill", DISTILL_SYSTEM, prompt));
  }
  const facts = Array.isArray(parsed.facts) ? parsed.facts.slice(0, 15) : [];

  const byId = {};
  for (const f of existing) byId[f.id] = f;
  const col = app.findCollectionByNameOrId("coach_memory");
  const today = isoDay(new Date());
  let created = 0, updated = 0;

  for (const f of facts) {
    const fact = String((f && f.fact) || "").trim().slice(0, 500);
    if (!fact) continue;
    let conf = Number(f.confidence);
    if (!isFinite(conf)) conf = 0.5;
    conf = Math.max(0, Math.min(1, conf));

    if (f.id && byId[f.id]) {
      const rec = byId[f.id];
      rec.set("fact", fact);
      rec.set("confidence", conf);
      rec.set("last_reinforced", today + " 00:00:00.000Z");
      app.save(rec);
      updated++;
    } else if (existing.length + created < 40) { // hard cap on total memory
      const rec = new Record(col);
      rec.set("fact", fact);
      rec.set("confidence", conf);
      rec.set("learned_from", "chat " + today);
      rec.set("last_reinforced", today + " 00:00:00.000Z");
      app.save(rec);
      created++;
    }
  }
  return { skipped: false, created: created, updated: updated, total: existing.length + created };
}

module.exports = {
  memoryBlock: memoryBlock,
  distill: distill,
};
