import Foundation
import HealthKit
import CoreLocation

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
    /// Initial import window — bounds the very first sync (and re-import). A
    /// year so the engine can anchor fitness to the athlete's best effort, not
    /// just recent runs (the engine's VDOT reference also looks back a year).
    private let seedDays = 365

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
            // M6: GPS route for the run-detail map
            HKSeriesType.workoutRoute(),
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

    /// Drop the saved anchor so the next sync re-imports the full window. The
    /// server's unique index on healthkit_uuid makes re-uploads a safe no-op for
    /// runs already stored. Used by "re-import all history".
    func resetAnchor() { UserDefaults.standard.removeObject(forKey: anchorKey) }

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
        var runs: [RunPayload] = []
        for w in samples.compactMap({ $0 as? HKWorkout }) {
            var p = payload(from: w)
            p.splits = await fetchSplits(for: w) // M7 Phase 4 (empty when data is too coarse)
            runs.append(p)
        }
        return (runs, newAnchor)
    }

    /// M7 Phase 4: reconstruct per-kilometre splits from the workout's
    /// per-sample distance + heart-rate series. Returns [] when the source app
    /// only wrote an aggregate (no per-sample distance) — the engine then
    /// degrades gracefully rather than inventing numbers.
    func fetchSplits(for workout: HKWorkout) async -> [RunSplit] {
        let pred = HKQuery.predicateForObjects(from: workout)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]

        func samples(_ type: HKQuantityType) async -> [HKQuantitySample] {
            (try? await withCheckedThrowingContinuation { cont in
                let q = HKSampleQuery(sampleType: type, predicate: pred,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, s, error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume(returning: (s as? [HKQuantitySample]) ?? []) }
                }
                store.execute(q)
            }) ?? []
        }

        let distSamples = await samples(HKQuantityType(.distanceWalkingRunning))
        guard !distSamples.isEmpty else { return [] }
        let hrSamples = await samples(HKQuantityType(.heartRate))

        let bpm = HKUnit.count().unitDivided(by: .minute())
        func avgHR(_ start: Date, _ end: Date) -> Double? {
            let vals = hrSamples
                .filter { $0.startDate >= start && $0.startDate < end }
                .map { $0.quantity.doubleValue(for: bpm) }
            guard !vals.isEmpty else { return nil }
            return ((vals.reduce(0, +) / Double(vals.count)) * 10).rounded() / 10
        }

        let meter = HKUnit.meter()
        var splits: [RunSplit] = []
        var kmIndex = 1
        var distInKm = 0.0              // metres accumulated in the current km
        var splitStart = workout.startDate

        for s in distSamples {
            let d = s.quantity.doubleValue(for: meter)
            if d <= 0 { continue }
            let segDur = s.endDate.timeIntervalSince(s.startDate)
            var consumed = 0.0
            // one sample may straddle one or more km boundaries — interpolate
            // the crossing time assuming distance accrues linearly in-sample.
            while distInKm + (d - consumed) >= 1000.0 {
                let need = 1000.0 - distInKm
                let frac = (consumed + need) / d
                let crossTime = s.startDate.addingTimeInterval(segDur * frac)
                splits.append(RunSplit(km: Double(kmIndex), distance_m: 1000,
                                       duration_s: crossTime.timeIntervalSince(splitStart),
                                       avg_hr: avgHR(splitStart, crossTime)))
                consumed += need
                distInKm = 0
                splitStart = crossTime
                kmIndex += 1
            }
            distInKm += (d - consumed)
        }
        // trailing partial km (ignore sub-100 m GPS dribble)
        if distInKm >= 100 {
            splits.append(RunSplit(km: Double(kmIndex), distance_m: (distInKm).rounded(),
                                   duration_s: workout.endDate.timeIntervalSince(splitStart),
                                   avg_hr: avgHR(splitStart, workout.endDate)))
        }
        return splits
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

    // MARK: M2 — daily recovery metrics (HRV / RHR / sleep / VO2max)

    /// One row per local day for the last `days` days, ready for
    /// `recovery_daily`. Days with no metrics at all are dropped.
    func fetchRecoveryDaily(days: Int) async -> [RecoveryPayload] {
        async let hrv = dailyAverage(.heartRateVariabilitySDNN,
                                     unit: .secondUnit(with: .milli), days: days)
        async let rhr = dailyAverage(.restingHeartRate,
                                     unit: HKUnit.count().unitDivided(by: .minute()), days: days)
        async let sleep = dailySleepHours(days: days)
        async let vo2 = dailyLatestVo2Max(days: days)
        let (hrvByDay, rhrByDay, sleepByDay, vo2ByDay) = await (hrv, rhr, sleep, vo2)

        var dayKeys = Set(hrvByDay.keys)
        dayKeys.formUnion(rhrByDay.keys)
        dayKeys.formUnion(sleepByDay.keys)
        dayKeys.formUnion(vo2ByDay.keys)

        return dayKeys.sorted().map { day in
            RecoveryPayload(
                date: day + "T00:00:00.000Z",
                hrv_sdnn_ms: hrvByDay[day],
                resting_hr: rhrByDay[day],
                sleep_hours: sleepByDay[day].map { ($0 * 10).rounded() / 10 },
                vo2max: vo2ByDay[day]
            )
        }.filter(\.hasAnyMetric)
    }

    /// Per-local-day discrete average of a quantity type.
    private func dailyAverage(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                              days: Int) async -> [String: Double] {
        let cal = Calendar.current
        let now = Date()
        let start = cal.startOfDay(for: cal.date(byAdding: .day, value: -(days - 1), to: now)!)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: [])
        let query = HKStatisticsCollectionQuery(
            quantityType: HKQuantityType(id),
            quantitySamplePredicate: predicate,
            options: .discreteAverage,
            anchorDate: cal.startOfDay(for: now),
            intervalComponents: DateComponents(day: 1)
        )
        return await withCheckedContinuation { cont in
            query.initialResultsHandler = { _, collection, _ in
                var out: [String: Double] = [:]
                collection?.enumerateStatistics(from: start, to: now) { stat, _ in
                    if let v = stat.averageQuantity()?.doubleValue(for: unit) {
                        out[stat.startDate.localDayKey] = (v * 10).rounded() / 10
                    }
                }
                cont.resume(returning: out)
            }
            store.execute(query)
        }
    }

    /// Sleep hours per local day, attributed to the WAKE day (sample end).
    /// Overlapping samples from multiple sources are union-merged so a watch
    /// and phone both logging the same night don't double it.
    private func dailySleepHours(days: Int) async -> [String: Double] {
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: now)!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: [])
        let samples: [HKCategorySample] = (try? await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis),
                                  predicate: predicate, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { _, s, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: (s as? [HKCategorySample]) ?? []) }
            }
            store.execute(q)
        }) ?? []

        let asleepValues = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
        var intervalsByDay: [String: [(start: Date, end: Date)]] = [:]
        for s in samples where asleepValues.contains(s.value) {
            intervalsByDay[s.endDate.localDayKey, default: []].append((s.startDate, s.endDate))
        }

        var out: [String: Double] = [:]
        for (day, intervals) in intervalsByDay {
            var merged: [(start: Date, end: Date)] = []
            for iv in intervals.sorted(by: { $0.start < $1.start }) {
                if let last = merged.last, iv.start <= last.end {
                    if iv.end > last.end { merged[merged.count - 1].end = iv.end }
                } else {
                    merged.append(iv)
                }
            }
            let seconds = merged.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
            if seconds > 0 { out[day] = seconds / 3600 }
        }
        return out
    }

    /// Latest VO2max reading per local day.
    private func dailyLatestVo2Max(days: Int) async -> [String: Double] {
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: now)!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: [])
        let samples: [HKQuantitySample] = (try? await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: HKQuantityType(.vo2Max),
                                  predicate: predicate, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
                                                                     ascending: true)]) { _, s, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: (s as? [HKQuantitySample]) ?? []) }
            }
            store.execute(q)
        }) ?? []

        let unit = HKUnit.literUnit(with: .milli)
            .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        var out: [String: Double] = [:]
        for s in samples { // ascending → last write per day wins
            out[s.startDate.localDayKey] = (s.quantity.doubleValue(for: unit) * 10).rounded() / 10
        }
        return out
    }

    // MARK: M6 — GPS route for a synced run

    /// Route coordinates for the workout with this HealthKit UUID, or empty
    /// if the source app never wrote one (manual entries never have routes).
    func fetchRoute(workoutUUID: String) async -> [CLLocationCoordinate2D] {
        guard let uuid = UUID(uuidString: workoutUUID) else { return [] }

        let workouts: [HKWorkout] = (try? await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: .workoutType(),
                                  predicate: HKQuery.predicateForObject(with: uuid),
                                  limit: 1, sortDescriptors: nil) { _, s, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: (s as? [HKWorkout]) ?? []) }
            }
            store.execute(q)
        }) ?? []
        guard let workout = workouts.first else { return [] }

        let routes: [HKWorkoutRoute] = (try? await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(),
                                  predicate: HKQuery.predicateForObjects(from: workout),
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, s, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: (s as? [HKWorkoutRoute]) ?? []) }
            }
            store.execute(q)
        }) ?? []
        guard let route = routes.first else { return [] }

        return await withCheckedContinuation { cont in
            var coords: [CLLocationCoordinate2D] = []
            let q = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if error != nil { cont.resume(returning: coords); return }
                coords.append(contentsOf: (locations ?? []).map(\.coordinate))
                if done { cont.resume(returning: coords) }
            }
            store.execute(q)
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
            // M7 Phase 4: how many per-km splits we can reconstruct, and whether
            // they carry HR — the empirical coverage check the engine relies on.
            let sp = await fetchSplits(for: w)
            let spHR = sp.contains { $0.avg_hr != nil }
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            lines.append(
                "\(df.string(from: w.startDate))  src=\(w.sourceRevision.source.name)"
                + "  dist=\(dist.map { String(format: "%.2fkm", $0 / 1000) } ?? "✗")"
                + "  hr=\(hr ? "✓" : "✗")"
                + "  elev=\(elev ? "✓" : "✗")"
                + "  splits=\(sp.count)\(sp.isEmpty ? "" : (spHR ? "(+hr)" : "(no hr)"))"
                + (indoor ? "  [indoor]" : "")
            )
        }
        let bySource = Dictionary(grouping: workouts) { $0.sourceRevision.source.name }
        lines.append("")
        lines.append("Sources: " + bySource.map { "\($0.key) ×\($0.value.count)" }.joined(separator: ", "))
        return lines.joined(separator: "\n")
    }
}
