// llm.js — provider-agnostic LLM interface (loaded via require() from *.pb.js hooks).
//
//   generate(tier, persona, prompt) → string
//
//   tier:    "daily" | "weekly" — picks the model tier (matters on Claude:
//            Haiku for daily check-ins, Sonnet for weekly plan generation).
//   persona: the coach system prompt. MUST stay byte-stable across calls —
//            no dates, metrics, or per-request content in here. Volatile
//            content belongs in `prompt`. This keeps the persona a cacheable
//            prefix the day we enable Anthropic prompt caching.
//   prompt:  the per-request content (today's date, computed facts, question).
//
// Provider is switched by env LLM_PROVIDER: "gemini" (default, free tier for
// dev) | "claude" (real training block). The flip is config-only by design —
// see PLAN.md "AI" decision row.

function geminiCall(model, key, persona, prompt) {
  const res = $http.send({
    url:
      "https://generativelanguage.googleapis.com/v1beta/models/" +
      model +
      ":generateContent",
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-goog-api-key": key,
    },
    body: JSON.stringify({
      system_instruction: { parts: [{ text: persona }] },
      contents: [{ role: "user", parts: [{ text: prompt }] }],
      generationConfig: {
        // 2.5-flash is a thinking model: thoughts consume output tokens, and
        // a 7-day JSON plan at 1024 came back truncated/JSON-less. Thinking
        // off + roomy cap = reliable structured output on the free tier.
        maxOutputTokens: 4096,
        thinkingConfig: { thinkingBudget: 0 },
      },
    }),
    timeout: 120,
  });

  if (res.statusCode !== 200) {
    const e = new Error("Gemini(" + model + ") HTTP " + res.statusCode + ": " + res.raw);
    e.statusCode = res.statusCode;
    throw e;
  }
  const cand = (res.json.candidates || [])[0];
  if (!cand || !cand.content || !cand.content.parts) {
    throw new Error("Gemini(" + model + "): empty response: " + res.raw);
  }
  return cand.content.parts.map((p) => p.text || "").join("");
}

function geminiGenerate(persona, prompt) {
  const key = $os.getenv("GEMINI_API_KEY");
  if (!key) throw new Error("GEMINI_API_KEY is not set");
  const model = $os.getenv("GEMINI_MODEL") || "gemini-2.5-flash";
  const fallback = $os.getenv("GEMINI_MODEL_FALLBACK") || "gemini-2.5-flash-lite";

  // The free tier intermittently sheds load (429/503 "high demand").
  // Retry the primary model, then fall back to the less-contended lite model.
  // (No sleep available in PocketBase's JSVM — HTTP latency spaces attempts.)
  const attempts = [model, model, fallback];
  let lastErr = null;
  for (const m of attempts) {
    try {
      return geminiCall(m, key, persona, prompt);
    } catch (err) {
      lastErr = err;
      const sc = err && err.statusCode;
      if (sc !== 429 && sc !== 500 && sc !== 503) throw err; // non-transient
      console.log("gemini transient " + sc + " on " + m + ", trying next");
    }
  }
  throw lastErr;
}

function claudeGenerate(tier, persona, prompt) {
  const key = $os.getenv("ANTHROPIC_API_KEY");
  if (!key) throw new Error("ANTHROPIC_API_KEY is not set");
  // Two-tier design: cheap fast model for daily check-ins, stronger model for
  // the weekly plan and mid-week re-plan (both judgment-heavy).
  const model =
    tier === "weekly" || tier === "replan"
      ? $os.getenv("CLAUDE_MODEL_WEEKLY") || "claude-sonnet-4-6"
      : $os.getenv("CLAUDE_MODEL_DAILY") || "claude-haiku-4-5";

  // Raw HTTP: PocketBase's JS hooks runtime (goja) has no Anthropic SDK.
  const res = $http.send({
    url: "https://api.anthropic.com/v1/messages",
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": key,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: model,
      max_tokens: 1024,
      system: persona,
      messages: [{ role: "user", content: prompt }],
    }),
    timeout: 120,
  });

  if (res.statusCode !== 200) {
    throw new Error("Claude HTTP " + res.statusCode + ": " + res.raw);
  }
  if (res.json.stop_reason === "refusal") {
    throw new Error("Claude refused the request (stop_reason=refusal)");
  }
  const blocks = res.json.content || [];
  for (const b of blocks) {
    if (b.type === "text") return b.text;
  }
  throw new Error(
    "Claude: no text block (stop_reason=" + res.json.stop_reason + ")"
  );
}

// Test-only provider: returns canned text from env, per tier
// (LLM_MOCK_RESPONSE_WEEKLY / _DAILY / _DISTILL / …). Lets the local smoke
// test exercise plan/chat/memory handlers with zero network and zero keys.
function mockGenerate(tier) {
  const specific = $os.getenv("LLM_MOCK_RESPONSE_" + String(tier).toUpperCase());
  return specific || $os.getenv("LLM_MOCK_RESPONSE") || "mock response";
}

// Fence/prose-tolerant JSON extraction for structured LLM responses.
function parseJSONLoose(text) {
  let t = String(text).trim();
  const fence = t.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (fence) t = fence[1].trim();
  const start = t.indexOf("{");
  const end = t.lastIndexOf("}");
  if (start === -1 || end <= start) throw new Error("LLM returned no JSON object");
  return JSON.parse(t.slice(start, end + 1));
}

module.exports = {
  parseJSONLoose: parseJSONLoose,
  provider: () => $os.getenv("LLM_PROVIDER") || "gemini",
  generate: function (tier, persona, prompt) {
    // Opt-in prompt logging (LLM_LOG_PROMPT=1) — lets the offline smoke test
    // assert that facts like per-run feel actually reach the model.
    if ($os.getenv("LLM_LOG_PROMPT")) {
      console.log("LLM PROMPT[" + tier + "]: " + String(prompt));
    }
    const p = $os.getenv("LLM_PROVIDER") || "gemini";
    if (p === "claude") return claudeGenerate(tier, persona, prompt);
    if (p === "gemini") return geminiGenerate(persona, prompt);
    if (p === "mock") return mockGenerate(tier);
    throw new Error("unknown LLM_PROVIDER: " + p);
  },
};
