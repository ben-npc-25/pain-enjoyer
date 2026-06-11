import Foundation
import SwiftUI

/// Central observable state: runs, coach message, sync status.
/// Keeps a tiny offline mirror (JSON file) so the calendar renders instantly
/// and survives no-network moments.
@MainActor
final class AppModel: ObservableObject {
    @Published var runs: [RunRecord] = []
    @Published var coachMessage: CoachMessage?
    @Published var status: String = ""
    @Published var busy = false

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
