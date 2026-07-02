import Foundation

/// Orchestrates HealthKit → server sync. Called from three places:
///  - app foreground / pull-to-refresh
///  - the HealthKit background observer (phone wakes us after a new run)
///  - the manual "Sync now" button
final class SyncEngine {
    static let shared = SyncEngine()
    private init() {}

    private let recoverySeededKey = "recovery.seeded.v1"

    /// Returns the number of newly uploaded runs.
    @discardableResult
    func syncNow() async throws -> Int {
        guard let (pb, email, pass) = PocketBaseClient.fromSettings() else {
            throw PBError.notConfigured
        }
        try await pb.authenticate(email: email, password: pass)

        let (runs, anchor) = try await HealthKitService.shared.fetchNewRuns()
        var uploaded = 0
        if !runs.isEmpty {
            // Skip runs already on the server WITHOUT a POST each (one GET), so a
            // large re-import backlog can't stall the sync. Upload newest-first
            // so today's run always lands first even if the session is short.
            let existing = Set((try? await pb.listRuns())?.compactMap(\.healthkit_uuid) ?? [])
            let fresh = runs
                .filter { $0.distance_m > 0 && !existing.contains($0.healthkit_uuid) }
                .sorted { $0.date > $1.date }
            for run in fresh {
                var r = run
                r.splits = await HealthKitService.shared.splitsForRun(uuid: run.healthkit_uuid)
                if try await pb.uploadRun(r) { uploaded += 1 }
            }
        }
        // Only advance the anchor once the whole batch is on the server —
        // a mid-batch failure means we re-fetch next time (dedupe absorbs it).
        HealthKitService.shared.commitAnchor(anchor)

        // M2: recovery metrics ride along on every sync. Failures here must
        // not break run sync — recovery is additive.
        do { try await syncRecovery(pb) }
        catch { print("recovery sync failed: \(error)") }

        return uploaded
    }

    /// Upsert daily recovery rows: 60-day backfill once, then a rolling
    /// 7-day window (HRV/sleep finalize overnight, so recent days get
    /// re-pushed; days already on the server older than 3 days are skipped).
    private func syncRecovery(_ pb: PocketBaseClient) async throws {
        let seeded = UserDefaults.standard.bool(forKey: recoverySeededKey)
        let days = seeded ? 7 : 60

        let payloads = await HealthKitService.shared.fetchRecoveryDaily(days: days)
        guard !payloads.isEmpty else { return }

        let existing = try await pb.listRecovery()
        let idByDay = Dictionary(existing.map { ($0.localDayKey, $0.id) },
                                 uniquingKeysWith: { a, _ in a })
        let recentCutoff = Calendar.current.date(byAdding: .day, value: -3, to: .now)!.localDayKey

        for p in payloads {
            let day = String(p.date.prefix(10))
            if let id = idByDay[day] {
                if day >= recentCutoff { try await pb.updateRecovery(id: id, p) }
            } else {
                try await pb.createRecovery(p)
            }
        }
        UserDefaults.standard.set(true, forKey: recoverySeededKey)
    }

    /// Background-safe variant: never throws (iOS gives us seconds, not retries).
    func syncQuietly() async {
        do {
            let n = try await syncNow()
            print("background sync: \(n) new run(s)")
        } catch {
            print("background sync failed: \(error)")
        }
    }
}
