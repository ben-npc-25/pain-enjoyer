import Foundation

/// Orchestrates HealthKit → server sync. Called from three places:
///  - app foreground / pull-to-refresh
///  - the HealthKit background observer (phone wakes us after a new run)
///  - the manual "Sync now" button
final class SyncEngine {
    static let shared = SyncEngine()
    private init() {}

    /// Returns the number of newly uploaded runs.
    @discardableResult
    func syncNow() async throws -> Int {
        guard let (pb, email, pass) = PocketBaseClient.fromSettings() else {
            throw PBError.notConfigured
        }
        try await pb.authenticate(email: email, password: pass)

        let (runs, anchor) = try await HealthKitService.shared.fetchNewRuns()
        guard !runs.isEmpty else {
            HealthKitService.shared.commitAnchor(anchor)
            return 0
        }

        var uploaded = 0
        for run in runs where run.distance_m > 0 {
            if try await pb.uploadRun(run) { uploaded += 1 }
        }
        // Only advance the anchor once the whole batch is on the server —
        // a mid-batch failure means we re-fetch next time (dedupe absorbs it).
        HealthKitService.shared.commitAnchor(anchor)
        return uploaded
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
