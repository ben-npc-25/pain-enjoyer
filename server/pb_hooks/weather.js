// weather.js — M11: deterministic weather facts for planning. Free open-meteo
// API, no key, zero LLM cost; the forecast string rides into the weekly-plan
// and pre-plan-check-in prompts so the coach plans AROUND weather (early
// starts in heat, hydration cues, moving the long run off a storm day) —
// never cancels for it.
//
// Location: WEATHER_LAT / WEATHER_LON / WEATHER_LABEL in .env (defaults to
// Hong Kong). WEATHER_MODE=off disables fetching entirely (tests, offline).
// Any failure returns null and planning proceeds without weather.
//
// MUST stay a require()'d module (fresh-JSVM rule).

const CODES = {
  0: "clear", 1: "mostly clear", 2: "partly cloudy", 3: "overcast",
  45: "fog", 48: "fog",
  51: "drizzle", 53: "drizzle", 55: "drizzle",
  61: "light rain", 63: "rain", 65: "heavy rain",
  66: "freezing rain", 67: "freezing rain",
  71: "snow", 73: "snow", 75: "heavy snow", 77: "snow",
  80: "showers", 81: "showers", 82: "heavy showers",
  85: "snow showers", 86: "snow showers",
  95: "thunderstorms", 96: "thunderstorms with hail", 99: "thunderstorms with hail",
};

// Compact one-line forecast for `days` days starting at startIso (YYYY-MM-DD),
// e.g. "Hong Kong — 2026-07-14: 27–32°C, rain 80%, thunderstorms; …".
// Returns null when disabled, out of the API's range, or on any error.
function weekForecast(startIso, days) {
  if (($os.getenv("WEATHER_MODE") || "") === "off") return null;
  const lat = $os.getenv("WEATHER_LAT") || "22.3193";
  const lon = $os.getenv("WEATHER_LON") || "114.1694";
  const label = $os.getenv("WEATHER_LABEL") || "Hong Kong";
  try {
    const endIso = new Date(
      new Date(startIso + "T00:00:00Z").getTime() + (Math.max(1, days) - 1) * 86400000
    ).toISOString().slice(0, 10);
    const res = $http.send({
      url:
        "https://api.open-meteo.com/v1/forecast?latitude=" + lat + "&longitude=" + lon +
        "&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code" +
        "&timezone=auto&start_date=" + startIso + "&end_date=" + endIso,
      method: "GET",
      timeout: 8,
    });
    if (res.statusCode !== 200) return null;
    const body = res.json || JSON.parse(res.raw);
    const d = body && body.daily;
    if (!d || !d.time || !d.time.length) return null;
    const parts = [];
    for (let i = 0; i < d.time.length; i++) {
      parts.push(
        d.time[i] + ": " +
        Math.round(d.temperature_2m_min[i]) + "–" + Math.round(d.temperature_2m_max[i]) + "°C" +
        (d.precipitation_probability_max[i] != null ? ", rain " + d.precipitation_probability_max[i] + "%" : "") +
        (CODES[d.weather_code[i]] ? ", " + CODES[d.weather_code[i]] : "")
      );
    }
    return label + " — " + parts.join("; ");
  } catch (err) {
    console.log("weather fetch failed (planning continues without it):", String(err));
    return null;
  }
}

module.exports = { weekForecast: weekForecast };
