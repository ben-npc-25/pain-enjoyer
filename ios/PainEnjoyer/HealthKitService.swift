import Foundation
import HealthKit

enum HealthKitError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Health data is not available on this device."
        }
    }
}

/// M1 HealthKit layer:
///  - anchored incremental fetch (only workouts we haven't synced yet)
///  - background delivery (new run on the watch → app wakes → syncs)
///  - field audit (what does each source app actually write?)
///
/// Singleton: the background observer must outlive any view.
final class HealthKitService {
    static let shared = HealthKitService()
    private let store = HKHealthStore()
    private let anchorKey = "hk.workouts.anchor.v1"
    /// Initial import window — bounds the very first sync (calendar + future VDOT).
    private let seedDays = 180

    private init() {}

    // MARK: Authorization

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthKitError.unavailable }
        let read: Set<HKObjectType> = [
            .workoutType(),
            HKQuantityType(.heartRate),
            HKQuantityType(.distanceWalkingRunning),
            // M2 recovery metrics — request now so we only prompt once:
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.vo2Max),
            HKCategoryType(.sleepAnalysis),
        ]
        try await store.requestAuthorization(toShare: [], read: read)
    }

    // MARK: Anchored incremental fetch

    private var runningPredicate: NSPredicate {
        let running = HKQuery.predicateForWorkouts(with: .running)
        let since = Calendar.current.date(byAdding: .day, value: -seedDays, to: .now)!
        let window = HKQuery.predicateForSamples(withStart: since, end: nil, options: [])
        return NSCompoundPredicate(andPredicateWithSubpredicates: [running, window])
    }

    private func loadAnchor() -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: anchorKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    /// Persist the anchor — call ONLY after the server accepted the batch,
    /// otherwise a failed upload would permanently skip those workouts.
    func commitAnchor(_ anchor: HKQueryAnchor?) {
        guard let anchor,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        else { return }
        UserDefaults.standard.set(data, forKey: anchorKey)
    }

    /// New running workouts since the last committed anchor.
    func fetchNewRuns() async throws -> (runs: [RunPayload], anchor: HKQueryAnchor?) {
        let (samples, newAnchor): ([HKSample], HKQueryAnchor?) =
            try await withCheckedThrowingContinuation { cont in
                let q = HKAnchoredObjectQuery(
                    type: .workoutType(),
                    predicate: runningPredicate,
                    anchor: loadAnchor(),
                    limit: HKObjectQueryNoLimit
                ) { _, added, _, anchor, error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume(returning: (added ?? [], anchor)) }
                }
                store.execute(q)
            }
        let runs = samples.compactMap { $0 as? HKWorkout }.map(payload(from:))
        return (runs, newAnchor)
    }

    private func payload(from w: HKWorkout) -> RunPayload {
        let distance = w.statistics(for: HKQuantityType(.distanceWalkingRunning))?
            .sumQuantity()?.doubleValue(for: .meter()) ?? 0
        let avgHR = w.statistics(for: HKQuantityType(.heartRate))?
            .averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        let elevation = (w.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?
            .doubleValue(for: .meter())

        return RunPayload(
            date: ISO8601DateFormatter().string(from: w.startDate),
            distance_m: distance,
            duration_s: w.duration,
            avg_hr: avgHR,
            elevation_gain_m: elevation,
            source_app: w.sourceRevision.source.name,
            healthkit_uuid: w.uuid.uuidString
        )
    }

    // MARK: Background delivery

    /// Register at every app launch. When any app writes a running workout to
    /// Health, iOS wakes us briefly; we sync and call the completion handler.
    func registerBackgroundSync() {
        let type = HKObjectType.workoutType()
        let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
            if error != nil { completion(); return }
            Task {
                await SyncEngine.shared.syncQuietly()
                completion()
            }
        }
        store.execute(query)
        store.enableBackgroundDelivery(for: type, frequency: .immediate) { ok, err in
            if let err { print("background delivery failed: \(err)") }
            else { print("background delivery enabled: \(ok)") }
        }
    }

    // MARK: Field audit (M1 deliverable — what does Runkeeper actually write?)

    /// Human-readable report of the last `limit` workouts: which fields each
    /// source app populated. Paste the output back into the dev chat.
    func auditReport(limit: Int = 15) async -> String {
        let workouts: [HKWorkout] = (try? await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: HKQuery.predicateForWorkouts(with: .running),
                limit: limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: (samples as? [HKWorkout]) ?? []) }
            }
            store.execute(q)
        }) ?? []

        guard !workouts.isEmpty else { return "No running workouts found in Health." }

        var lines = ["HealthKit field audit — last \(workouts.count) runs", ""]
        for w in workouts {
            let dist = w.statistics(for: HKQuantityType(.distanceWalkingRunning))?
                .sumQuantity()?.doubleValue(for: .meter())
            let hr = w.statistics(for: HKQuantityType(.heartRate))?
                .averageQuantity() != nil
            let elev = w.metadata?[HKMetadataKeyElevationAscended] != nil
            let indoor = (w.metadata?[HKMetadataKeyIndoorWorkout] as? Bool) ?? false
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            lines.append(
                "\(df.string(from: w.startDate))  src=\(w.sourceRevision.source.name)"
                + "  dist=\(dist.map { String(format: "%.2fkm", $0 / 1000) } ?? "✗")"
                + "  hr=\(hr ? "✓" : "✗")"
                + "  elev=\(elev ? "✓" : "✗")"
                + (indoor ? "  [indoor]" : "")
            )
        }
        let bySource = Dictionary(grouping: workouts) { $0.sourceRevision.source.name }
        lines.append("")
        lines.append("Sources: " + bySource.map { "\($0.key) ×\($0.value.count)" }.joined(separator: ", "))
        return lines.joined(separator: "\n")
    }
}
