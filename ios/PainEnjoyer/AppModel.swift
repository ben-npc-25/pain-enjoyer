import Foundation
import SwiftUI
import UIKit

/// Central observable state: runs, coach message, sync status.
/// Keeps a tiny offline mirror (JSON file) so the calendar renders instantly
/// and survives no-network moments.
@MainActor
final class AppModel: ObservableObject {
    @Published var runs: [RunRecord] = []
    @Published var coachMessage: CoachMessage?
    @Published var status: String = ""
    @Published var busy = false

    // M2: deterministic engine state + athlete profile
    @Published var engine: EngineState?
    @Published var coachOnRunBusy = false // M7: coach reacting to a just-rated run
    @Published var profile: AthleteProfile?
    /// True once a profile fetch SUCCEEDED — distinguishes "no profile yet"
    /// (→ onboarding) from "couldn't reach the server".
    @Published var profileLoaded = false

    // M3: plan + conversation
    @Published var planned: [PlannedWorkout] = []
    @Published var messages: [CoachMessage] = []
    @Published var chatBusy = false

    // M4: memory + recovery series (Trends)
    @Published var memory: [MemoryFact] = []
    @Published var recovery: [RecoveryFull] = []

    // M6: plan weeks (rationale/phase) for the Plan tab
    @Published var planWeeks: [PlanWeek] = []

    // M9: the macro training block — the program from today to race day
    @Published var macro: [MacroWeek] = []

    var zonesSec: [String: Double]? { engine?.vdot.zones_sec }

    func trendsReview() async {
        busy = true; defer { busy = false }
        do {
            status = "Coach is reading your charts…"
            let pb = try await client()
            _ = try await pb.trendsReview()
            messages = (try? await pb.listMessages()) ?? messages
            status = ""
            haptic()
        } catch {
            status = "✗ \(error.localizedDescription)"
        }
    }

    // M5: tab routing + chat prefill (quick check-ins, "ask about workout")
    enum AppTab: Hashable { case coach, plan, calendar, trends, chat }
    // M9: the program is the product — the app opens on it.
    @Published var selectedTab: AppTab = .plan
    @Published var chatPrefill = ""

    func openChat(prefill: String = "") {
        chatPrefill = prefill
        selectedTab = .chat
    }

    /// One-tap check-in: jump to chat and send immediately.
    func quickCheckin(_ text: String) {
        selectedTab = .chat
        Task { await sendChat(text) }
    }

    func haptic(_ success: Bool = true) {
        UINotificationFeedbackGenerator().notificationOccurred(success ? .success : .error)
    }

    var needsOnboarding: Bool { profileLoaded && profile == nil }

    var plannedByDay: [String: [PlannedWorkout]] {
        Dictionary(grouping: planned) { $0.localDayKey }
    }

    /// "2026-10-08" from the profile's race_date — calendar shows 🏁 there.
    var raceDayKey: String? {
        guard let rd = profile?.race_date, rd.count >= 10 else { return nil }
        return String(rd.prefix(10))
    }

    /// Runs grouped by local-day key ("2026-06-11") — what the calendar consumes.
    var runsByDay: [String: [RunRecord]] {
        Dictionary(grouping: runs) { $0.localDayKey }
    }

    private var cacheURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "runs-cache.json")
    }

    init() { loadCache() }

    // MARK: offline mirror

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode([RunRecord].self, from: data) else { return }
        runs = cached
    }

    private func saveCache() {
        if let data = try? JSONEncoder().encode(runs) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    // MARK: actions

    private func client() async throws -> PocketBaseClient {
        guard let (pb, email, pass) = PocketBaseClient.fromSettings() else {
            throw PBError.notConfigured
        }
        try await pb.authenticate(email: email, password: pass)
        return pb
    }

    /// Full refresh. READ the server first so your saved data always shows —
    /// even if a HealthKit sync is slow (e.g. a big re-import). The sync runs
    /// AFTER, in the background, so it can never blank the screen again.
    ///
    /// SwiftUI's .refreshable cancels its task as soon as the spinner
    /// dismisses or the view re-renders — that cancellation used to abort the
    /// in-flight fetches and leave "✗ cancelled" on screen. The real work runs
    /// in an unstructured task (immune to the gesture's cancellation).
    func refresh(syncHealth: Bool = true) async {
        let work = Task { await self.performRefresh(syncHealth: syncHealth) }
        await work.value
    }

    private func performRefresh(syncHealth: Bool) async {
        busy = true; defer { busy = false }
        do {
            status = status.isEmpty ? "Loading…" : status
            let pb = try await client()
            _ = try? await pb.ping() // M5: opens feed the engagement score

            // independent fetches run concurrently — one round-trip of latency
            // instead of seven (the Pi is far away through the tunnel)
            async let runsReq = pb.listRuns()
            async let msgReq = pb.latestCoachMessage()
            async let engineReq = pb.engineState()
            async let plannedReq = pb.listPlanned()
            async let messagesReq = pb.listMessages()
            async let recoveryReq = pb.listRecoveryFull()
            async let weeksReq = pb.listPlanWeeks()
            async let macroReq = pb.listMacro()
            async let profileReq = pb.getProfile()

            runs = try await runsReq
            coachMessage = try? await msgReq
            engine = try? await engineReq
            if let p = try? await plannedReq { planned = p }
            if let m = try? await messagesReq { messages = m }
            if let r = try? await recoveryReq { recovery = r }
            if let w = try? await weeksReq { planWeeks = w }
            if let m = try? await macroReq { macro = m }
            do {
                profile = try await profileReq // nil = no row → onboarding
                profileLoaded = true
            } catch { /* unreachable/odd response — don't trigger onboarding */ }
            saveCache()
            if status == "Loading…" { status = "" }
        } catch is CancellationError {
            if status == "Loading…" { status = "" } // a cancelled pull is not an error
        } catch let e as URLError where e.code == .cancelled {
            if status == "Loading…" { status = "" }
        } catch {
            status = "✗ \(error.localizedDescription)"
        }
        // HealthKit sync happens AFTER the read, in the background — a slow or
        // stuck sync can no longer hide the log that's already on screen.
        if syncHealth { Task { await self.syncHealthInBackground() } }
    }

    private func syncHealthInBackground() async {
        do {
            try await HealthKitService.shared.requestAuthorization()
            let n = try await SyncEngine.shared.syncNow()
            guard n > 0 else { return }
            let pb = try await client()
            runs = (try? await pb.listRuns()) ?? runs
            engine = (try? await pb.engineState()) ?? engine
            recovery = (try? await pb.listRecoveryFull()) ?? recovery
            saveCache()
            status = "Synced \(n) new run\(n == 1 ? "" : "s")"
            haptic()
        } catch {
            // Never blank the screen on a sync failure — the read already ran.
            if status.isEmpty { status = "Showing saved data (sync will retry)" }
        }
    }

    func askCoach() async {
        busy = true; defer { busy = false }
        do {
            status = "Coach is thinking…"
            let pb = try await client()
            let resp = try await pb.askCoach()
            coachMessage = CoachMessage(id: UUID().uuidString, content: resp.advice,
                                        kind: "daily", provider: resp.provider, created: nil)
            messages = (try? await pb.listMessages()) ?? messages // shows in chat
            status = ""
        } catch {
            status = "✗ \(error.localizedDescription)"
        }
    }

    func addManualRun(date: Date, distanceKm: Double, durationMin: Double, avgHR: Double?) async {
        busy = true; defer { busy = false }
        do {
            let run = RunPayload(
                date: ISO8601DateFormatter().string(from: date),
                distance_m: distanceKm * 1000,
                duration_s: durationMin * 60,
                avg_hr: avgHR,
                elevation_gain_m: nil,
                source_app: "manual",
                healthkit_uuid: "manual-\(UUID().uuidString)"
            )
            let pb = try await client()
            try await pb.uploadRun(run)
            await refresh(syncHealth: false)
            status = "Run added"
        } catch {
            status = "✗ \(error.localizedDescription)"
        }
    }

    // MARK: M4 actions

    func loadMemory() async {
        do {
            let pb = try await client()
            memory = try await pb.listMemory()
        } catch {
            status = "✗ \(error.localizedDescription)"
        }
    }

    func distillNow() async {
        busy = true; defer { busy = false }
        do {
            status = "Distilling conversation into memory…"
            let pb = try await client()
            let r = try await pb.distillNow()
            memory = (try? await pb.listMemory()) ?? memory
            status = r.skipped == true
                ? "Nothing new to remember (no recent chat)"
                : "Memory updated: \(r.created ?? 0) new, \(r.updated ?? 0) reinforced"
            haptic()
        } catch {
            status = "✗ \(error.localizedDescription)"
            haptic(false)
        }
    }

    func deleteMemory(_ fact: MemoryFact) async {
        do {
            let pb = try await client()
            try await pb.deleteMemory(id: fact.id)
            memory.removeAll { $0.id == fact.id }
        } catch {
            status = "✗ \(error.localizedDescription)"
        }
    }

    // MARK: M3 actions

    func sendChat(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chatBusy = true; defer { chatBusy = false }
        // optimistic append so the bubble shows while the coach thinks
        messages.append(CoachMessage(id: "local-\(UUID().uuidString)", content: trimmed,
                                     kind: "feedback", provider: nil, created: nil, role: "athlete"))
        do {
            let pb = try await client()
            _ = try await pb.chat(message: trimmed)
            messages = (try? await pb.listMessages()) ?? messages
            haptic()
        } catch {
            status = "✗ \(error.localizedDescription)"
            haptic(false)
        }
    }

    func generatePlan() async {
        busy = true; defer { busy = false }
        do {
            status = "Coach is updating your plan…"
            let pb = try await client()
            let week = try await pb.generateWeek()
            // Refetch everything the update touches, so the change is VISIBLE
            // (the old code left the rationale card stale — "nothing happened").
            planned = (try? await pb.listPlanned()) ?? planned
            planWeeks = (try? await pb.listPlanWeeks()) ?? planWeeks
            engine = (try? await pb.engineState()) ?? engine
            let why = week.rationale.isEmpty ? "" : " — \(week.rationale.prefix(140))"
            status = "Plan updated: \(week.phase), \(Int(week.cap_km)) km cap, rest of this week\(why)"
            haptic()
        } catch {
            status = "✗ Plan update failed — \(error.localizedDescription)"
        }
    }

    func saveNotes(for run: RunRecord, notes: String) async {
        do {
            let pb = try await client()
            try await pb.updateRunNotes(id: run.id, notes: notes)
            if let i = runs.firstIndex(where: { $0.id == run.id }) {
                runs[i].notes = notes
            }
            saveCache()
            status = "Note saved"
            haptic()
        } catch {
            status = "✗ \(error.localizedDescription)"
        }
    }

    /// M7 Phase 1: save the per-run effort (RPE 1–5) — optimistic local update.
    func saveEffort(for run: RunRecord, effort: Int) async {
        do {
            let pb = try await client()
            try await pb.updateRunEffort(id: run.id, effort: effort)
            if let i = runs.firstIndex(where: { $0.id == run.id }) {
                runs[i].effort = Double(effort)
            }
            saveCache()
            status = "Effort saved"
            haptic()
        } catch {
            status = "✗ \(error.localizedDescription)"
        }
    }

    /// M7: rate the run's effort, then get the coach's reaction SAVED ON THE RUN
    /// (not posted to chat). The effort rides into the prompt, so the note
    /// reflects the feedback just given; it persists in runs[i].coach_note.
    func rateRunAndGetFeedback(_ run: RunRecord, effort: Int) async {
        await saveEffort(for: run, effort: effort)
        coachOnRunBusy = true; defer { coachOnRunBusy = false }
        do {
            let pb = try await client()
            let note = try await pb.runFeedback()
            if let i = runs.firstIndex(where: { $0.id == run.id }) {
                runs[i].coach_note = note
            }
            saveCache()
            haptic()
        } catch {
            status = "✗ \(error.localizedDescription)"
        }
    }

    /// M9: (re)build the goal-anchored training block. Deterministic server
    /// math — instant, no LLM.
    func buildMacroPlan() async {
        busy = true; defer { busy = false }
        do {
            status = "Building your program…"
            let pb = try await client()
            try await pb.buildMacroPlan()
            macro = (try? await pb.listMacro()) ?? macro
            messages = (try? await pb.listMessages()) ?? messages
            status = macro.isEmpty ? "" : "Program built — \(macro.count) weeks to race day"
            haptic()
        } catch {
            status = "✗ \(error.localizedDescription)"
        }
    }

    func saveProfile(_ p: AthleteProfile) async {
        busy = true; defer { busy = false }
        do {
            let pb = try await client()
            try await pb.saveProfile(p)
            profile = try await pb.getProfile()
            profileLoaded = true
            engine = try? await pb.engineState() // injury flag changes the light
            macro = (try? await pb.listMacro()) ?? macro // M9: race change re-anchors the block
            status = "Profile saved"
            haptic()
        } catch {
            status = "✗ \(error.localizedDescription)"
        }
    }

    func deleteRun(_ run: RunRecord) async {
        do {
            let pb = try await client()
            try await pb.deleteRun(id: run.id)
            runs.removeAll { $0.id == run.id }
            saveCache()
        } catch {
            status = "✗ \(error.localizedDescription)"
        }
    }
}
