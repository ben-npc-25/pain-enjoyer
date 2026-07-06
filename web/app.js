// app.js — Pain Enjoyer web planner. Same data, same server as the iOS app:
// PocketBase records API + /api/coach/* endpoints, all same-origin.

"use strict";

// ── helpers ──────────────────────────────────────────────────────────────

const $ = (sel) => document.querySelector(sel);

function pbDate(s) {
  // PB dates look like "2026-06-11 07:30:00.000Z"
  return new Date(String(s || "").replace(" ", "T"));
}
function dayKey(d) {
  // local-timezone day key — a 23:30Z run belongs to the local next day
  const y = d.getFullYear(), m = d.getMonth() + 1, dd = d.getDate();
  return `${y}-${String(m).padStart(2, "0")}-${String(dd).padStart(2, "0")}`;
}
function mondayOf(d) {
  const x = new Date(d.getFullYear(), d.getMonth(), d.getDate());
  x.setDate(x.getDate() - ((x.getDay() + 6) % 7));
  return x;
}
function dateFromKey(k) {
  const [y, m, d] = k.split("-").map(Number);
  return new Date(y, m - 1, d); // local, not UTC — keys are local day labels
}
function fmtKm(m) { return (m / 1000).toFixed(1); }
function fmtPaceSec(sec) {
  const m = Math.floor(sec / 60), s = Math.round(sec) % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
}
function fmtPace(distanceM, durationS) {
  if (!distanceM) return "–";
  return fmtPaceSec(durationS / (distanceM / 1000)) + " /km";
}
function fmtDur(totalS) {
  const t = Math.round(totalS), h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60;
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`
               : `${m}:${String(s).padStart(2, "0")}`;
}
function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}
function mdLite(s) {
  // minimal inline markdown for coach prose: bold / italic / code
  return esc(s)
    .replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>")
    .replace(/\*([^*\n]+)\*/g, "<i>$1</i>")
    .replace(/`([^`\n]+)`/g, "<code>$1</code>");
}
function toast(msg, ms = 3500) {
  const t = $("#toast");
  t.textContent = msg;
  t.classList.remove("hidden");
  clearTimeout(toast._t);
  toast._t = setTimeout(() => t.classList.add("hidden"), ms);
}

// Daniels–Gilbert single-effort VDOT (display-only, same as the iOS port).
function danielsVDOT(distanceM, durationS) {
  const t = durationS / 60, v = distanceM / t;
  const vo2 = -4.6 + 0.182258 * v + 0.000104 * v * v;
  const pct = 0.8 + 0.1894393 * Math.exp(-0.012778 * t) + 0.2989558 * Math.exp(-0.1932605 * t);
  return vo2 / pct;
}
function predictedRaceTime(distanceM, vdot) {
  let lo = 240, hi = 21600;
  for (let i = 0; i < 48; i++) {
    const mid = (lo + hi) / 2;
    if (danielsVDOT(distanceM, mid) > vdot) lo = mid; else hi = mid;
  }
  return (lo + hi) / 2;
}

const TYPE_COLORS = { E: "#16a34a", T: "#ea580c", I: "#dc2626", R: "#dc2626", MP: "#2563eb", LR: "#0d9488", rest: "#9ca3af" };
const TYPE_LABELS = { E: "Easy", T: "Threshold", I: "Intervals", R: "Repetitions", MP: "Marathon pace", LR: "Long run", rest: "Rest" };
const PHASE_COLORS = { base: "#0d9488", build: "#2563eb", peak: "#7c3aed", taper: "#ea580c", race: "#dc2626", rehab: "#9ca3af" };
const ACTIVITY_LABELS = { running: "Run", hiking: "Hike", walking: "Walk", cycling: "Ride", swimming: "Swim", strength: "Strength", yoga: "Yoga" };

function isRun(r) { const t = r.activity_type || ""; return t === "" || t === "running"; }
function activityLabel(r) {
  const t = r.activity_type || "";
  return t === "" ? "Run" : (ACTIVITY_LABELS[t] || (t[0].toUpperCase() + t.slice(1)));
}
function paceRange(w) {
  const lo = w.target_pace_low_skm, hi = w.target_pace_high_skm;
  if (!lo || !hi) return null;
  return lo === hi ? `${fmtPaceSec(lo)} /km` : `${fmtPaceSec(lo)}–${fmtPaceSec(hi)} /km`;
}

// ── state ────────────────────────────────────────────────────────────────

const S = {
  profile: null, engine: null, macro: [], planned: [], runs: [], recovery: [],
  messages: [], calMonth: null, calSelected: null, trendsRead: null,
};

// ── boot / auth ──────────────────────────────────────────────────────────

API.onUnauthorized = () => showLogin();

function showLogin() {
  $("#app").classList.add("hidden");
  $("#login").classList.remove("hidden");
}
async function showApp() {
  $("#login").classList.add("hidden");
  $("#app").classList.remove("hidden");
  API.ping().catch(() => {}); // engagement signal — same as an app open
  switchTab(window.location.hash.slice(1) || "program");
}

$("#login-btn").addEventListener("click", doLogin);
$("#login-pass").addEventListener("keydown", (e) => { if (e.key === "Enter") doLogin(); });
async function doLogin() {
  const err = $("#login-err");
  err.textContent = "";
  try {
    await API.login($("#login-email").value.trim(), $("#login-pass").value);
    await showApp();
  } catch (e) {
    err.textContent = String(e.message || e);
  }
}
$("#logout-btn").addEventListener("click", () => { API.setToken(null); showLogin(); });

// ── tabs ─────────────────────────────────────────────────────────────────

const LOADERS = { program: loadProgram, calendar: loadCalendar, trends: loadTrends, chat: loadChat };

document.querySelectorAll(".tab").forEach((b) =>
  b.addEventListener("click", () => switchTab(b.dataset.tab)));

function switchTab(name) {
  if (!LOADERS[name]) name = "program";
  window.location.hash = name; // deep-linkable tabs (bookmark /#calendar, …)
  document.querySelectorAll(".tab").forEach((b) => b.classList.toggle("active", b.dataset.tab === name));
  document.querySelectorAll(".view").forEach((v) => v.classList.toggle("hidden", v.id !== `view-${name}`));
  LOADERS[name]().catch((e) => toast(`load failed: ${e.message}`));
}

// ═══ PROGRAM ═════════════════════════════════════════════════════════════

async function loadProgram() {
  const el = $("#view-program");
  el.innerHTML = `<div class="card muted">Loading…</div>`;
  const [engine, profile, macro, planned, runs] = await Promise.all([
    API.engine(), API.profile(), API.macroWeeks(), API.planned(), API.runs(),
  ]);
  Object.assign(S, { engine, profile, macro, planned, runs });
  renderProgram();
}

function renderProgram() {
  const el = $("#view-program");
  const { engine, profile, macro } = S;
  const light = engine.traffic_light || {};
  const todayMonKey = dayKey(mondayOf(new Date()));
  const curIdx = macro.findIndex((w) => String(w.week_start).slice(0, 10) === todayMonKey);

  // hero: traffic light + week badge
  let html = `
  <div class="card hero">
    <span class="light-emoji">${esc(light.emoji || "⚪️")}</span>
    <div style="flex:1">
      <div class="light-word">${esc(light.light || "unknown")}</div>
      <ul>${(light.reasons || []).map((r) => `<li>${esc(r)}</li>`).join("")}</ul>
    </div>
    ${curIdx >= 0 ? `<span class="badge">Week ${curIdx + 1} of ${macro.length}</span>` : ""}
  </div>`;

  // race + predictions
  const raceDate = profile && profile.race_date ? pbDate(profile.race_date) : null;
  if (raceDate && !isNaN(raceDate)) {
    const days = Math.ceil((raceDate - new Date()) / 86400000);
    const vdot = engine.vdot && engine.vdot.available ? engine.vdot.value : null;
    const dists = [["5K", 5000], ["10K", 10000], ["Half", 21097], ["Full", 42195]];
    const gt = engine.goal_trajectory;
    html += `
    <div class="card">
      <h2>${esc(profile.race_name || "Race")}</h2>
      <div class="race-row">
        <span class="race-big">${days >= 0 ? days + " days" : "done"}</span>
        <span class="muted">${esc(String(profile.race_date).slice(0, 10))}${days >= 0 ? ` · ${Math.floor(days / 7)} weeks out` : ""}</span>
        ${gt && gt.available && gt.status ? `<span class="badge">${esc(gt.status.replace(/_/g, " "))}</span>` : ""}
      </div>
      ${vdot ? `
      <h3>Equivalent race times @ VDOT ${vdot.toFixed(1)}</h3>
      <div class="pred-grid">
        ${dists.map(([label, m]) => `<div class="pred"><div class="d">${label}</div><div class="t">${fmtDur(predictedRaceTime(m, vdot))}</div></div>`).join("")}
      </div>` : `<p class="muted">No VDOT anchor yet — the predictor unlocks after a solid effort.</p>`}
    </div>`;
  }

  // training block
  html += `
  <div class="card">
    <h2>Training block</h2>
    ${macro.length ? `<div class="block-chart">${blockChartSVG(macro, S.runs, curIdx)}</div>
    <div class="legend">
      ${Object.entries(PHASE_COLORS).map(([p, c]) => `<span style="--c:${c}">${p}</span>`).join("")}
      <span style="--c:#93c5fd">● actual km</span>
    </div>` : `<p class="muted">No block yet — build one from your race date.</p>`}
    <div class="actions-row" style="margin-top:12px">
      <button id="btn-macro" class="btn btn-primary">${macro.length ? "↻ Rebuild program" : "Build my program"}</button>
      <button id="btn-week" class="btn">Plan this week</button>
      <span id="program-status" class="status-line"></span>
    </div>
  </div>`;

  // this week's plan
  html += `<div class="card"><h2>This week</h2>${weekListHTML(todayMonKey)}</div>`;

  el.innerHTML = html;

  $("#btn-macro").addEventListener("click", () => programAction(async () => {
    const r = await API.macroPlan();
    toast("Program built: " + (r.summary || "ok"), 6000);
    await loadProgram();
  }));
  $("#btn-week").addEventListener("click", () => programAction(async () => {
    const r = await API.planWeek();
    toast(`Week planned (${r.phase}, cap ${r.cap_km} km)`, 6000);
    await loadProgram();
  }));
}

async function programAction(fn) {
  const st = $("#program-status");
  document.querySelectorAll("#view-program .btn").forEach((b) => (b.disabled = true));
  st.textContent = "working…";
  try { await fn(); }
  catch (e) { toast("✗ " + e.message, 6000); st.textContent = ""; }
  finally { document.querySelectorAll("#view-program .btn").forEach((b) => (b.disabled = false)); }
}

function weekListHTML(monKey) {
  const mon = dateFromKey(monKey);
  const days = [];
  for (let i = 0; i < 7; i++) {
    const d = new Date(mon.getFullYear(), mon.getMonth(), mon.getDate() + i);
    days.push(dayKey(d));
  }
  const byDay = {};
  for (const w of S.planned) {
    const k = String(w.date).slice(0, 10);
    if (days.includes(k)) (byDay[k] = byDay[k] || []).push(w);
  }
  if (!Object.keys(byDay).length) return `<p class="muted">Nothing planned this week yet.</p>`;
  return `<div class="week-list">${days.map((k) => (byDay[k] || []).map((w) => `
    <div class="week-day">
      <span class="muted" style="min-width:88px">${new Date(k + "T12:00:00").toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" })}</span>
      <span class="type-chip" style="background:${TYPE_COLORS[w.type] || "#9ca3af"}">${esc(w.type)}</span>
      <span style="flex:1">${w.distance_m ? `<b>${fmtKm(w.distance_m)} km</b> · ` : ""}${esc(w.description || TYPE_LABELS[w.type] || "")}${paceRange(w) ? ` <span class="muted">(${paceRange(w)})</span>` : ""}</span>
      <span class="muted">${esc(w.status || "planned")}</span>
    </div>`).join("")).join("")}</div>`;
}

function blockChartSVG(macro, runs, curIdx) {
  const W = Math.max(600, macro.length * 26), H = 190, pad = { l: 30, r: 10, t: 24, b: 34 };
  const maxKm = Math.max(...macro.map((w) => w.target_km || 0), 1);
  const bw = (W - pad.l - pad.r) / macro.length;
  const y = (km) => pad.t + (H - pad.t - pad.b) * (1 - km / maxKm);

  // actual running km per block week
  const actual = {};
  for (const r of runs) {
    if (!isRun(r)) continue;
    const k = dayKey(mondayOf(pbDate(r.date)));
    actual[k] = (actual[k] || 0) + r.distance_m / 1000;
  }

  let bars = "";
  macro.forEach((w, i) => {
    const km = w.target_km || 0;
    const x = pad.l + i * bw;
    const color = PHASE_COLORS[w.phase] || "#9ca3af";
    const top = y(km);
    const mark = w.milestone === "race_week" ? "🏁" : w.milestone === "final_long_run" ? "⚑" : w.milestone === "benchmark" ? "⏱" : "";
    bars += `<rect x="${(x + 2).toFixed(1)}" y="${top.toFixed(1)}" width="${(bw - 4).toFixed(1)}" height="${(H - pad.b - top).toFixed(1)}"
      rx="3" fill="${color}" opacity="${w.is_cutback ? 0.4 : 0.9}" ${i === curIdx ? 'stroke="#1c2333" stroke-width="1.5"' : ""}>
      <title>W${i + 1} ${esc(w.phase || "")}${w.is_cutback ? " (cutback)" : ""}: ${km.toFixed(0)} km target, LR ${(w.long_run_km || 0).toFixed(0)} km</title></rect>`;
    if (mark) bars += `<text x="${(x + bw / 2).toFixed(1)}" y="${(top - 6).toFixed(1)}" font-size="11" text-anchor="middle">${mark}</text>`;
    const wk = String(w.week_start).slice(0, 10);
    if (actual[wk] !== undefined) {
      bars += `<circle cx="${(x + bw / 2).toFixed(1)}" cy="${y(Math.min(actual[wk], maxKm)).toFixed(1)}" r="3.4" fill="#93c5fd" stroke="#2563eb"><title>actual ${actual[wk].toFixed(1)} km</title></circle>`;
    }
    if (i % Math.ceil(macro.length / 12) === 0) {
      bars += `<text x="${(x + bw / 2).toFixed(1)}" y="${H - 14}" font-size="9" text-anchor="middle" fill="#6b7280">${wk.slice(5)}</text>`;
    }
  });
  const grid = [0, 0.5, 1].map((f) => {
    const km = maxKm * f, yy = y(km);
    return `<line x1="${pad.l}" y1="${yy}" x2="${W - pad.r}" y2="${yy}" stroke="#e5e7eb"/>
      <text x="${pad.l - 4}" y="${(yy + 3).toFixed(1)}" font-size="9" text-anchor="end" fill="#6b7280">${km.toFixed(0)}</text>`;
  }).join("");
  return `<svg class="chart-svg" viewBox="0 0 ${W} ${H}" style="min-width:${W}px">${grid}${bars}</svg>`;
}

// ═══ CALENDAR ════════════════════════════════════════════════════════════

async function loadCalendar() {
  const [planned, runs] = await Promise.all([API.planned(), API.runs()]);
  S.planned = planned; S.runs = runs;
  if (!S.calMonth) { const n = new Date(); S.calMonth = new Date(n.getFullYear(), n.getMonth(), 1); }
  renderCalendar();
}

function renderCalendar() {
  const el = $("#view-calendar");
  const m0 = S.calMonth;
  const title = m0.toLocaleDateString(undefined, { month: "long", year: "numeric" });

  const plannedBy = {}, runsBy = {};
  for (const w of S.planned) (plannedBy[String(w.date).slice(0, 10)] = plannedBy[String(w.date).slice(0, 10)] || []).push(w);
  for (const r of S.runs) { const k = dayKey(pbDate(r.date)); (runsBy[k] = runsBy[k] || []).push(r); }

  const first = new Date(m0.getFullYear(), m0.getMonth(), 1);
  const start = new Date(first); start.setDate(1 - first.getDay()); // Sun-start grid
  const todayKey = dayKey(new Date());
  const raceKey = S.profile && S.profile.race_date ? String(S.profile.race_date).slice(0, 10) : null;

  let cells = "";
  for (let i = 0; i < 42; i++) {
    const d = new Date(start.getFullYear(), start.getMonth(), start.getDate() + i);
    const k = dayKey(d);
    const inMonth = d.getMonth() === m0.getMonth();
    const ps = plannedBy[k] || [], rs = runsBy[k] || [];
    cells += `<div class="cal-cell ${inMonth ? "" : "other"} ${k === todayKey ? "today" : ""} ${k === S.calSelected ? "selected" : ""}" data-day="${k}">
      <span class="n">${d.getDate()}</span>${raceKey === k ? " 🏁" : ""}
      ${ps.map((w) => `<div class="p ${esc(w.status || "planned")}">${esc(w.type)}${w.distance_m ? " " + fmtKm(w.distance_m) : ""}</div>`).join("")}
      ${rs.map((r) => `<div class="r">${isRun(r) ? "🏃" : "•"} ${fmtKm(r.distance_m)}k</div>`).join("")}
    </div>`;
  }

  el.innerHTML = `
  <div class="card">
    <div class="cal-head">
      <button id="cal-prev" class="btn btn-ghost">‹</button>
      <span class="title">${title}</span>
      <button id="cal-next" class="btn btn-ghost">›</button>
    </div>
    <div class="cal-grid">
      ${["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].map((d) => `<div class="cal-dow">${d}</div>`).join("")}
      ${cells}
    </div>
  </div>
  <div id="day-detail"></div>`;

  $("#cal-prev").addEventListener("click", () => { S.calMonth = new Date(m0.getFullYear(), m0.getMonth() - 1, 1); renderCalendar(); });
  $("#cal-next").addEventListener("click", () => { S.calMonth = new Date(m0.getFullYear(), m0.getMonth() + 1, 1); renderCalendar(); });
  el.querySelectorAll(".cal-cell").forEach((c) =>
    c.addEventListener("click", () => { S.calSelected = c.dataset.day; renderCalendar(); }));

  if (S.calSelected) renderDayDetail(S.calSelected, plannedBy[S.calSelected] || [], runsBy[S.calSelected] || []);
}

function renderDayDetail(k, planned, runs) {
  const el = $("#day-detail");
  const pretty = new Date(k + "T12:00:00").toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric" });
  let html = `<div class="card day-detail"><h2>${pretty}</h2>`;

  if (!planned.length && !runs.length) html += `<p class="muted">Nothing planned, nothing logged.</p>`;

  for (const w of planned) {
    html += `<div class="week-day">
      <span class="type-chip" style="background:${TYPE_COLORS[w.type] || "#9ca3af"}">${esc(w.type)}</span>
      <span style="flex:1">${w.distance_m ? `<b>${fmtKm(w.distance_m)} km</b> · ` : ""}${esc(w.description || TYPE_LABELS[w.type] || "")}${paceRange(w) ? ` <span class="muted">(${paceRange(w)})</span>` : ""}</span>
      <span class="muted">${esc(w.status || "planned")}</span>
    </div>`;
  }

  runs.forEach((r, i) => {
    html += `<h3>${esc(activityLabel(r))} — ${fmtKm(r.distance_m)} km · ${fmtDur(r.duration_s)} · ${fmtPace(r.distance_m, r.duration_s)}${r.avg_hr ? ` · ♥ ${Math.round(r.avg_hr)}` : ""}</h3>
      ${r.coach_note ? `<div class="coach-read">🗣 ${mdLite(r.coach_note)}</div>` : ""}
      <div class="effort-row" data-run="${esc(r.id)}">
        <span class="muted" style="align-self:center">Effort</span>
        ${[1, 2, 3, 4, 5].map((n) => `<button data-effort="${n}" class="${r.effort && Math.round(r.effort) === n ? "sel" : ""}">${n}</button>`).join("")}
      </div>
      <textarea id="notes-${i}" placeholder="How did it go? The coach reads this.">${esc(r.notes || "")}</textarea>
      <div class="actions-row" style="margin-top:6px"><button class="btn btn-primary" data-save-notes="${esc(r.id)}" data-ta="notes-${i}">Save notes</button></div>`;
  });
  html += `</div>`;
  el.innerHTML = html;

  el.querySelectorAll("[data-save-notes]").forEach((b) => b.addEventListener("click", async () => {
    try {
      await API.patchRun(b.dataset.saveNotes, { notes: $("#" + b.dataset.ta).value });
      toast("Notes saved");
      const run = S.runs.find((r) => r.id === b.dataset.saveNotes);
      if (run) run.notes = $("#" + b.dataset.ta).value;
    } catch (e) { toast("✗ " + e.message); }
  }));
  el.querySelectorAll(".effort-row button").forEach((b) => b.addEventListener("click", async () => {
    const id = b.closest(".effort-row").dataset.run, n = Number(b.dataset.effort);
    try {
      await API.patchRun(id, { effort: n });
      const run = S.runs.find((r) => r.id === id);
      if (run) run.effort = n;
      b.closest(".effort-row").querySelectorAll("button").forEach((x) => x.classList.toggle("sel", x === b));
      toast("Effort saved");
    } catch (e) { toast("✗ " + e.message); }
  }));
}

// ═══ TRENDS ══════════════════════════════════════════════════════════════

async function loadTrends() {
  const el = $("#view-trends");
  el.innerHTML = `<div class="card muted">Loading…</div>`;
  const [runs, recovery] = await Promise.all([API.runs(), API.recovery()]);
  S.runs = runs; S.recovery = recovery;
  renderTrends();
}

function renderTrends() {
  const el = $("#view-trends");
  const read = S.trendsRead || {};
  const readBox = (key) => read[key] ? `<div class="coach-read">🗣 ${mdLite(read[key])}</div>` : "";

  // weekly km (last 12 weeks, runs only)
  const weekKm = {};
  for (const r of S.runs) { if (isRun(r)) { const k = dayKey(mondayOf(pbDate(r.date))); weekKm[k] = (weekKm[k] || 0) + r.distance_m / 1000; } }
  const weeks = [];
  const thisMon = mondayOf(new Date());
  for (let i = 11; i >= 0; i--) {
    const d = new Date(thisMon.getFullYear(), thisMon.getMonth(), thisMon.getDate() - i * 7);
    const k = dayKey(d);
    weeks.push({ label: k.slice(5), km: weekKm[k] || 0 });
  }

  // recovery series (last 90 d, ascending)
  const cutoff = new Date(); cutoff.setDate(cutoff.getDate() - 90);
  const rec = S.recovery.filter((r) => pbDate(r.date) >= cutoff)
    .sort((a, b) => pbDate(a.date) - pbDate(b.date));
  const series = (f) => rec.filter((r) => r[f] != null && r[f] > 0).map((r) => ({ x: pbDate(r.date), y: r[f] }));

  // per-run effort VDOT (runs ≥3 km & ≥12 min, last 180 d)
  const cutoff180 = new Date(); cutoff180.setDate(cutoff180.getDate() - 180);
  const vdots = S.runs
    .filter((r) => isRun(r) && r.distance_m >= 3000 && r.duration_s >= 720 && pbDate(r.date) >= cutoff180)
    .map((r) => ({ x: pbDate(r.date), y: danielsVDOT(r.distance_m, r.duration_s) }))
    .sort((a, b) => a.x - b.x);

  el.innerHTML = `
    <div class="actions-row" style="margin-bottom:12px">
      <button id="btn-read" class="btn btn-primary">Coach's read</button>
      <span id="read-status" class="status-line"></span>
    </div>
    <div class="card"><h2>Weekly volume (km)</h2>${barChartSVG(weeks)}${readBox("volume")}</div>
    <div class="card"><h2>Effort VDOT per run</h2>${lineChartSVG(vdots, "#2563eb", { dots: true })}${readBox("fitness")}</div>
    <div class="card"><h2>HRV (SDNN ms)</h2>${lineChartSVG(series("hrv_sdnn_ms"), "#0d9488")}${readBox("hrv")}</div>
    <div class="card"><h2>Resting HR</h2>${lineChartSVG(series("resting_hr"), "#ea580c")}${readBox("resting_hr")}</div>
    <div class="card"><h2>VO₂max</h2>${lineChartSVG(series("vo2max"), "#7c3aed")}${readBox("vo2max_health")}</div>
    <div class="card"><h2>Body weight (kg)</h2>${lineChartSVG(series("body_mass_kg"), "#1c2333")}${readBox("weight")}</div>`;

  $("#btn-read").addEventListener("click", async () => {
    const st = $("#read-status");
    $("#btn-read").disabled = true; st.textContent = "asking the coach…";
    try {
      const r = await API.trendsReview();
      S.trendsRead = r.review || {};
      renderTrends();
    } catch (e) { toast("✗ " + e.message, 6000); st.textContent = ""; $("#btn-read").disabled = false; }
  });
}

function barChartSVG(items) {
  const W = 640, H = 170, pad = { l: 34, r: 8, t: 12, b: 26 };
  const max = Math.max(...items.map((i) => i.km), 1);
  const bw = (W - pad.l - pad.r) / items.length;
  const y = (v) => pad.t + (H - pad.t - pad.b) * (1 - v / max);
  let out = [0, 0.5, 1].map((f) => {
    const yy = y(max * f);
    return `<line x1="${pad.l}" y1="${yy}" x2="${W - pad.r}" y2="${yy}" stroke="#e5e7eb"/>
      <text x="${pad.l - 4}" y="${(yy + 3).toFixed(1)}" font-size="9" text-anchor="end" fill="#6b7280">${(max * f).toFixed(0)}</text>`;
  }).join("");
  items.forEach((it, i) => {
    const x = pad.l + i * bw, top = y(it.km);
    out += `<rect x="${(x + 3).toFixed(1)}" y="${top.toFixed(1)}" width="${(bw - 6).toFixed(1)}" height="${(H - pad.b - top).toFixed(1)}" rx="3" fill="#2563eb" opacity=".85"><title>${it.label}: ${it.km.toFixed(1)} km</title></rect>
      <text x="${(x + bw / 2).toFixed(1)}" y="${H - 8}" font-size="9" text-anchor="middle" fill="#6b7280">${i % 2 === 0 ? it.label : ""}</text>`;
  });
  return `<svg class="chart-svg" viewBox="0 0 ${W} ${H}">${out}</svg>`;
}

function lineChartSVG(pts, color, opts = {}) {
  if (pts.length < 2) return `<p class="muted">Not enough data yet.</p>`;
  const W = 640, H = 150, pad = { l: 38, r: 8, t: 10, b: 22 };
  const xs = pts.map((p) => p.x.getTime()), ys = pts.map((p) => p.y);
  const x0 = Math.min(...xs), x1 = Math.max(...xs);
  let y0 = Math.min(...ys), y1 = Math.max(...ys);
  if (y0 === y1) { y0 -= 1; y1 += 1; }
  const yPad = (y1 - y0) * 0.12; y0 -= yPad; y1 += yPad;
  const X = (t) => pad.l + (W - pad.l - pad.r) * ((t - x0) / (x1 - x0 || 1));
  const Y = (v) => pad.t + (H - pad.t - pad.b) * (1 - (v - y0) / (y1 - y0));
  const path = pts.map((p, i) => `${i ? "L" : "M"}${X(p.x.getTime()).toFixed(1)},${Y(p.y).toFixed(1)}`).join(" ");
  const avg = ys.reduce((a, b) => a + b, 0) / ys.length;
  const grid = [y0 + yPad, avg, y1 - yPad].map((v) =>
    `<line x1="${pad.l}" y1="${Y(v)}" x2="${W - pad.r}" y2="${Y(v)}" stroke="#e5e7eb" ${v === avg ? 'stroke-dasharray="3 3"' : ""}/>
     <text x="${pad.l - 4}" y="${(Y(v) + 3).toFixed(1)}" font-size="9" text-anchor="end" fill="#6b7280">${v.toFixed(v >= 100 ? 0 : 1)}</text>`).join("");
  const labels = [pts[0], pts[pts.length - 1]].map((p) =>
    `<text x="${X(p.x.getTime()).toFixed(1)}" y="${H - 6}" font-size="9" text-anchor="middle" fill="#6b7280">${dayKey(p.x).slice(5)}</text>`).join("");
  const dots = opts.dots ? pts.map((p) =>
    `<circle cx="${X(p.x.getTime()).toFixed(1)}" cy="${Y(p.y).toFixed(1)}" r="2.6" fill="${color}"><title>${dayKey(p.x)}: ${p.y.toFixed(1)}</title></circle>`).join("") : "";
  return `<svg class="chart-svg" viewBox="0 0 ${W} ${H}">${grid}<path d="${path}" fill="none" stroke="${color}" stroke-width="2"/>${dots}${labels}</svg>`;
}

// ═══ CHAT ════════════════════════════════════════════════════════════════

async function loadChat() {
  S.messages = await API.messages(50);
  renderChat();
}

function renderChat() {
  const log = $("#chat-log");
  // fresh-slate rule (Ben's restructure): show the last 24 h only; the full
  // history stays server-side and memory carries the context.
  const cutoff = Date.now() - 24 * 3600 * 1000;
  const msgs = S.messages
    .filter((m) => m.kind !== "weekly_review")
    .filter((m) => pbDate(m.created).getTime() >= cutoff)
    .sort((a, b) => pbDate(a.created) - pbDate(b.created));
  log.innerHTML = msgs.length
    ? msgs.map((m) => {
        const mine = m.role === "athlete";
        const kind = !mine && m.kind && m.kind !== "feedback" && m.kind !== "daily" ? `<span class="kind">${esc(m.kind.replace(/_/g, " "))}</span>` : "";
        return `<div class="msg ${mine ? "athlete" : "coach"}">${kind}${mdLite(m.content)}</div>`;
      }).join("")
    : `<div class="chat-empty">Fresh slate — the coach remembers, the log doesn't.<br>Say something, or tap ✨ for today's advice.</div>`;
  log.scrollTop = log.scrollHeight;
}

$("#chat-send").addEventListener("click", sendChat);
$("#chat-text").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); sendChat(); }
});

async function sendChat() {
  const ta = $("#chat-text");
  const text = ta.value.trim();
  if (!text) return;
  ta.value = "";
  S.messages.unshift({ id: "tmp", content: text, role: "athlete", created: new Date().toISOString() });
  renderChat();
  $("#chat-send").disabled = true;
  try {
    const r = await API.chat(text);
    S.messages.unshift({ id: "tmp2", content: r.reply, role: "coach", kind: "feedback", created: new Date().toISOString() });
    renderChat();
  } catch (e) { toast("✗ " + e.message, 6000); }
  finally { $("#chat-send").disabled = false; ta.focus(); }
}

$("#chat-advise").addEventListener("click", async () => {
  $("#chat-advise").disabled = true;
  toast("Asking the coach…", 2000);
  try {
    const r = await API.advise();
    S.messages.unshift({ id: "tmpA", content: r.advice, role: "coach", kind: "daily", created: new Date().toISOString() });
    renderChat();
  } catch (e) { toast("✗ " + e.message, 6000); }
  finally { $("#chat-advise").disabled = false; }
});

// ═══ PROFILE ═════════════════════════════════════════════════════════════

$("#profile-btn").addEventListener("click", async () => {
  try { S.profile = await API.profile(); } catch (e) { toast("✗ " + e.message); return; }
  const f = $("#profile-form");
  const p = S.profile || {};
  f.race_name.value = p.race_name || "";
  f.race_date.value = p.race_date ? String(p.race_date).slice(0, 10) : "";
  f.goal_time.value = p.goal_time_s ? fmtDur(p.goal_time_s) : "";
  f.days_per_week.value = p.days_per_week || "";
  f.long_run_day.value = p.long_run_day || "";
  f.weekly_target_km.value = p.weekly_target_km || "";
  f.hr_max.value = p.hr_max || "";
  f.injured.checked = !!p.injured;
  f.injury_note.value = p.injury_note || "";
  f.return_to_run_date.value = p.return_to_run_date ? String(p.return_to_run_date).slice(0, 10) : "";
  const days = (p.run_days || "").split(",").map((s) => s.trim());
  f.querySelectorAll('input[name="rd"]').forEach((c) => (c.checked = days.includes(c.value)));
  $("#profile-status").textContent = "";
  $("#profile-modal").classList.remove("hidden");
});

$("#profile-cancel").addEventListener("click", () => $("#profile-modal").classList.add("hidden"));

$("#profile-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const f = e.target;
  const goalParts = f.goal_time.value.trim().split(":").map(Number);
  let goal = 0;
  if (goalParts.length === 3 && goalParts.every((n) => !isNaN(n))) goal = goalParts[0] * 3600 + goalParts[1] * 60 + goalParts[2];
  else if (goalParts.length === 2 && goalParts.every((n) => !isNaN(n))) goal = goalParts[0] * 60 + goalParts[1];
  const body = {
    id: S.profile ? S.profile.id : undefined,
    race_name: f.race_name.value.trim(),
    race_date: f.race_date.value ? f.race_date.value + "T00:00:00.000Z" : "",
    goal_time_s: goal,
    days_per_week: Number(f.days_per_week.value) || 0,
    long_run_day: f.long_run_day.value,
    run_days: [...f.querySelectorAll('input[name="rd"]:checked')].map((c) => c.value).join(","),
    weekly_target_km: Number(f.weekly_target_km.value) || 0,
    hr_max: Number(f.hr_max.value) || 0,
    injured: f.injured.checked,
    injury_note: f.injury_note.value.trim(),
    return_to_run_date: f.return_to_run_date.value ? f.return_to_run_date.value + "T00:00:00.000Z" : "",
  };
  $("#profile-status").textContent = "saving…";
  try {
    await API.saveProfile(body);
    $("#profile-modal").classList.add("hidden");
    toast("Profile saved — block re-anchors automatically");
    if (!$("#view-program").classList.contains("hidden")) loadProgram();
  } catch (err) {
    $("#profile-status").textContent = "✗ " + err.message;
  }
});

// ── go ───────────────────────────────────────────────────────────────────

(async function boot() {
  if (!API.token) return showLogin();
  try {
    await API.ping(); // cheapest authenticated call — validates the token
    $("#login").classList.add("hidden");
    $("#app").classList.remove("hidden");
    switchTab(window.location.hash.slice(1) || "program");
  } catch (_) {
    showLogin();
  }
})();
