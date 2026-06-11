import Foundation
import HealthKit

/// M0: read the single most-recent running workout.
/// M1 grows this into HKObserverQuery + enableBackgroundDelivery + anchored
/// incremental sync (see PLAN.md milestones).
struct RunPayload: Codable {
    var date: String
    var distance_m: Double
    var duration_s: Double
    var avg_hr: Double?
    var elevation_gain_m: Double?
    var source_app: String
    var healthkit_uuid: String
}

enum HealthKitError: LocalizedError {
    case unavailable, noRuns
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Health data is not available on this device."
        case .noRuns: return "No running workouts found in Health."
        }
    }
}

final class HealthKitService {
    private let store = HKHealthStore()

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

    /// Fetch the most recent running workout, mapped to the server's runs schema.
    func fetchLatestRun() async throws -> RunPayload {
        let predicate = HKQuery.predicateForWorkouts(with: .running)
        let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: predicate,
                limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: (samples as? [HKWorkout]) ?? []) }
            }
            store.execute(q)
        }
        guard let w = workouts.first else { throw HealthKitError.noRuns }

        let distance = w.statistics(for: HKQuantityType(.distanceWalkingRunning))?
            .sumQuantity()?.doubleValue(for: .meter()) ?? 0
        let avgHR = w.statistics(for: HKQuantityType(.heartRate))?
            .averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))

        let iso = ISO8601DateFormatter()
        return RunPayload(
            date: iso.string(from: w.startDate),
            distance_m: distance,
            duration_s: w.duration,
            avg_hr: avgHR,
            elevation_gain_m: nil, // M1: from workout metadata / route
            source_app: w.sourceRevision.source.name, // "Runkeeper", "Apple Watch", …
            healthkit_uuid: w.uuid.uuidString
        )
    }
}
