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

    /// Full refresh: HealthKit → server → local mirror (+ latest coach message).
    func refresh(syncHealth: Bool = true) async {
        busy = true; defer { busy = false }
        do {
            if syncHealth {
                status = "Reading Health…"
                try await HealthKitService.shared.requestAuthorization()
                let n = try await SyncEngine.shared.syncNow()
                if n > 0 { status = "Synced \(n) new run\(n == 1 ? "" : "s")" }
            }
            status = status.isEmpty ? "Loading…" : status
            let pb = try await client()
            runs = try await pb.listRuns()
            coachMessage = try? await pb.latestCoachMessage()
            engine = try? await pb.engineState()
            if let p = try? await pb.listPlanned() { planned = p }
            if let m = try? await pb.listMessages() { messages = m }
            if let r = try? await pb.listRecoveryFull() { recovery = r }
            do {
                profile = try await pb.getProfile() // nil = no row → onboarding
                profileLoaded = true
            } catch { /* unreachable/odd response — don't trigger onboarding */ }
            saveCache()
            if status == "Loading…" || status == "Reading Health…" { status = "" }
        } catch {
            status = "✗ \(error.localizedDescription)"
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
            status = "Coach is planning next week…"
            let pb = try await client()
            let week = try await pb.generateWeek()
            planned = (try? await pb.listPlanned()) ?? planned
            status = "Planned week of \(week.week_start) (\(week.phase), cap \(Int(week.cap_km)) km)"
            haptic()
        } catch {
            status = "✗ \(error.localizedDescription)"
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

    func saveProfile(_ p: AthleteProfile) async {
        busy = true; defer { busy = false }
        do {
            let pb = try await client()
            try await pb.saveProfile(p)
            profile = try await pb.getProfile()
            profileLoaded = true
            engine = try? await pb.engineState() // injury flag changes the light
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
