// api.js — same-origin PocketBase client, mirroring the iOS PocketBaseClient.
// Auth token lives in localStorage; a 401 anywhere kicks back to the login view.

"use strict";

const API = {
  token: localStorage.getItem("pe.token") || null,
  onUnauthorized: null, // set by app.js

  async req(path, { method = "GET", body = null, query = null } = {}) {
    const url = new URL(path, window.location.origin);
    if (query) {
      for (const [k, v] of Object.entries(query)) {
        if (v !== null && v !== undefined) url.searchParams.set(k, v);
      }
    }
    const headers = { "Content-Type": "application/json" };
    if (this.token) headers["Authorization"] = this.token;
    const res = await fetch(url, {
      method,
      headers,
      body: body ? JSON.stringify(body) : null,
    });
    if (res.status === 401) {
      this.setToken(null);
      if (this.onUnauthorized) this.onUnauthorized();
      throw new Error("signed out — please sign in again");
    }
    const text = await res.text();
    let data = null;
    try { data = text ? JSON.parse(text) : null; } catch (_) { /* non-JSON body */ }
    if (!res.ok) {
      const msg = (data && (data.error || data.message)) || `HTTP ${res.status}`;
      throw new Error(msg);
    }
    return data;
  },

  setToken(t) {
    this.token = t;
    if (t) localStorage.setItem("pe.token", t);
    else localStorage.removeItem("pe.token");
  },

  async login(email, password) {
    const d = await this.req("/api/collections/users/auth-with-password", {
      method: "POST",
      body: { identity: email, password },
    });
    this.setToken(d.token);
    return d;
  },

  list(collection, query) {
    return this.req(`/api/collections/${collection}/records`, { query });
  },

  // ── collections (shapes match Models.swift) ──
  async runs(perPage = 500) {
    return (await this.list("runs", { perPage, sort: "-date" })).items;
  },
  async planned(perPage = 500) {
    return (await this.list("planned_workouts", { perPage, sort: "date" })).items;
  },
  async macroWeeks() {
    return (await this.list("macro_weeks", { perPage: 200, sort: "week_idx" })).items;
  },
  async messages(perPage = 50) {
    return (await this.list("coach_messages", { perPage, sort: "-created" })).items;
  },
  async recovery(perPage = 400) {
    return (await this.list("recovery_daily", { perPage, sort: "-date" })).items;
  },
  async profile() {
    const items = (await this.list("athlete_profile", { perPage: 1 })).items;
    return items.length ? items[0] : null;
  },
  saveProfile(p) {
    return p.id
      ? this.req(`/api/collections/athlete_profile/records/${p.id}`, { method: "PATCH", body: p })
      : this.req("/api/collections/athlete_profile/records", { method: "POST", body: p });
  },
  patchRun(id, fields) {
    return this.req(`/api/collections/runs/records/${id}`, { method: "PATCH", body: fields });
  },

  // ── coach endpoints ──
  engine() { return this.req("/api/coach/engine"); },
  ping() { return this.req("/api/coach/ping", { method: "POST" }); },
  chat(message) { return this.req("/api/coach/chat", { method: "POST", body: { message } }); },
  advise() { return this.req("/api/coach/advise", { method: "POST" }); },
  macroPlan() { return this.req("/api/coach/macro-plan", { method: "POST" }); },
  planWeek() { return this.req("/api/coach/plan-week", { method: "POST" }); },
  trendsReview() { return this.req("/api/coach/trends-review", { method: "POST" }); },
};
