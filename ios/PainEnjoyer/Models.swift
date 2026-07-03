import Foundation
import SwiftUI

// MARK: - Wire models (match the PocketBase `runs` schema)

/// One kilometre of a run (or the trailing partial), reconstructed from the
/// per-sample HealthKit distance + heart-rate series. Feeds the M7 Phase 4
/// durability score (late-run pace decay / HR drift). avg_hr is nil when the
/// source app wrote no heart-rate samples.
struct RunSplit: Codable, Hashable {
    // All Double?: PocketBase stores numbers as float64 and may serialize them
    // as int or float — decoding to Int is brittle ("isn't in the correct
    // format"). Doubles accept either.
    var km: Double?
    var distance_m: Double?
    var duration_s: Double?
    var avg_hr: Double?
}

/// Payload the phone sends when uploading a run.
struct RunPayload: Codable {
    var date: String
    var distance_m: Double
    var duration_s: Double
    var avg_hr: Double?
    var max_hr: Double? // M9.2: observed peak HR — calibrates HRmax server-side
    var elevation_gain_m: Double?
    var source_app: String
    var healthkit_uuid: String
    var activity_type: String = "running" // M8: hikes/rides/… sync too
    var splits: [RunSplit]? = nil // M7 Phase 4: per-km splits when the data supports it
}

/// A run record as stored on the server.
struct RunRecord: Codable, Identifiable, Hashable {
    var id: String
    var date: String
    var distance_m: Double
    var duration_s: Double
    var avg_hr: Double?
    var max_hr: Double? // M9.2: observed peak HR (may be absent on old rows)
    var elevation_gain_m: Double?
    var source_app: String?
    var notes: String? // M3: athlete's subjective note, feeds the coach
    var effort: Double? // M7 Phase 1: perceived effort/RPE 1–5; Double tolerates PB int-or-float
    var coach_note: String? // M7: the coach's reaction to THIS run (not in chat)
    var splits: [RunSplit]? // M7 Phase 4: per-km splits (may be absent/empty)
    var healthkit_uuid: String? // M6: route lookup for the map
    var activity_type: String? // M8: ""/"running" = run; else "hiking", "cycling", …

    /// True for real runs and pre-M8 rows (which are all runs).
    var isRun: Bool {
        let t = activity_type ?? ""
        return t.isEmpty || t == "running"
    }

    /// "Run" / "Hike" / "Ride" / … for cards and detail titles.
    var activityLabel: String {
        switch activity_type ?? "" {
        case "", "running": return "Run"
        case "hiking": return "Hike"
        case "walking": return "Walk"
        case "cycling": return "Ride"
        case "swimming": return "Swim"
        case "strength": return "Strength"
        case "yoga": return "Yoga"
        default: return (activity_type ?? "activity").capitalized
        }
    }

    /// 1–5 if the athlete rated this run's effort, else nil (PB stores unrated as 0).
    var effortRating: Int? {
        guard let e = effort, e >= 1 else { return nil }
        return Int(e.rounded())
    }

    // PB dates look like "2026-06-11 07:30:00.000Z"
    static let pbDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var startDate: Date { Self.pbDateFormatter.date(from: date) ?? .distantPast }

    /// Local-timezone day key ("2026-06-11") — a 23:30Z run belongs to the
    /// *local* next day on the calendar.
    var localDayKey: String { startDate.localDayKey }

    var distanceKm: Double { distance_m / 1000 }

    /// "5:47 /km" — formatted deterministically, same rule as the server.
    var paceString: String {
        guard distance_m > 0 else { return "–" }
        let secPerKm = duration_s / (distance_m / 1000)
        let m = Int(secPerKm) / 60
        let s = Int(secPerKm.rounded()) % 60
        return String(format: "%d:%02d /km", m, s)
    }

    var durationString: String {
        let total = Int(duration_s)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

struct CoachMessage: Codable, Identifiable {
    var id: String
    var content: String
    var kind: String?
    var provider: String?
    var created: String?
    var role: String? // "coach" | "athlete" (M3 chat)

    var isAthlete: Bool { role == "athlete" }
}

// MARK: - M3: planned workouts, chat, plan generation

struct PlannedWorkout: Codable, Identifiable, Hashable {
    var id: String
    var date: String
    var type: String
    var distance_m: Double?
    var target_pace_low_skm: Double?
    var target_pace_high_skm: Double?
    var description: String?
    var status: String?
    var plan_week_id: String?

    var startDate: Date { RunRecord.pbDateFormatter.date(from: date) ?? .distantPast }
    var localDayKey: String { String(date.prefix(10)) } // stored at UTC midnight = day label
    var distanceKm: Double { (distance_m ?? 0) / 1000 }
    var isRest: Bool { type == "rest" }

    var typeLabel: String {
        switch type {
        case "E": return "Easy"
        case "T": return "Threshold"
        case "I": return "Intervals"
        case "R": return "Repetitions"
        case "MP": return "Marathon pace"
        case "LR": return "Long run"
        default: return "Rest"
        }
    }

    /// "4:25–4:35 /km" from the code-assigned zone targets.
    var paceRange: String? {
        func fmt(_ s: Double) -> String { "\(Int(s) / 60):" + String(format: "%02d", Int(s) % 60) }
        guard let lo = target_pace_low_skm, lo > 0,
              let hi = target_pace_high_skm, hi > 0 else { return nil }
        return lo == hi ? "\(fmt(lo)) /km" : "\(fmt(lo))–\(fmt(hi)) /km"
    }
}

struct ChatResponse: Codable {
    var reply: String
    var provider: String
}

// MARK: - M4: memory, recovery series, effort score

/// One durable fact the coach holds about the athlete (coach_memory row).
struct MemoryFact: Codable, Identifiable {
    var id: String
    var fact: String
    var confidence: Double?
    var learned_from: String?
    var last_reinforced: String?
}

struct DistillResult: Codable {
    var skipped: Bool?
    var created: Int?
    var updated: Int?
}

/// Full recovery_daily row — feeds the Trends charts.
struct RecoveryFull: Codable, Identifiable {
    var id: String
    var date: String
    var hrv_sdnn_ms: Double?
    var resting_hr: Double?
    var sleep_hours: Double?
    var vo2max: Double?
    var body_mass_kg: Double? // M10

    var day: Date { RunRecord.pbDateFormatter.date(from: date) ?? .distantPast }
}

/// Daniels–Gilbert single-effort VDOT — display-only math (the coaching VDOT
/// comes from the server engine, never from here).
func danielsVDOT(distanceM: Double, durationS: Double) -> Double {
    let t = durationS / 60
    let v = distanceM / t
    let vo2 = -4.6 + 0.182258 * v + 0.000104 * v * v
    let pct = 0.8 + 0.1894393 * exp(-0.012778 * t) + 0.2989558 * exp(-0.1932605 * t)
    return vo2 / pct
}

/// Equivalent race time at a given VDOT (bisection — monotonic in time).
func predictedRaceTime(distanceM: Double, vdot: Double) -> TimeInterval {
    var lo = 240.0, hi = 21600.0
    for _ in 0..<48 {
        let mid = (lo + hi) / 2
        if danielsVDOT(distanceM: distanceM, durationS: mid) > vdot { lo = mid }
        else { hi = mid }
    }
    return (lo + hi) / 2
}

/// Display classification of a run, from pace vs the engine's zone targets.
enum RunClass {
    case easy, long, steady, tempo, speed, unknown

    var label: String {
        switch self {
        case .easy: return "EASY"
        case .long: return "LONG RUN"
        case .steady: return "STEADY"
        case .tempo: return "TEMPO"
        case .speed: return "SPEED"
        case .unknown: return "RUN"
        }
    }

    var color: Color {
        switch self {
        case .easy: return .green
        case .long: return .teal
        case .steady: return .blue
        case .tempo: return .orange
        case .speed: return .red
        case .unknown: return .gray
        }
    }
}

extension RunRecord {
    var effortVDOT: Double? {
        // VDOT is a running metric — a 3 km hike would chart as absurd fitness.
        guard isRun, distance_m >= 3000, duration_s >= 720 else { return nil }
        return danielsVDOT(distanceM: distance_m, durationS: duration_s)
    }

    /// Heuristic display label: long by distance/duration first, then pace
    /// vs the engine's zone targets (sec/km).
    func runClass(zones: [String: Double]?) -> RunClass {
        guard distance_m > 0, duration_s > 0 else { return .unknown }
        if distance_m >= 12000 || duration_s >= 4800 { return .long }
        let secPerKm = duration_s / (distance_m / 1000)
        guard let z = zones,
              let interval = z["interval"], let threshold = z["threshold"],
              let marathon = z["marathon"], let easyHigh = z["easy_high"]
        else { return .unknown }
        if secPerKm <= interval * 1.02 { return .speed }
        if secPerKm <= threshold * 1.03 { return .tempo }
        if secPerKm <= marathon * 1.03 { return .steady }
        if secPerKm >= easyHigh * 0.95 { return .easy }
        return .steady
    }
}

/// plan_weeks row — phase + the coach's rationale for the week.
// MARK: - M9: the macro training block (one row per week, today → race week)

struct MacroWeek: Codable, Identifiable, Hashable {
    var id: String
    var week_idx: Double
    var week_start: String
    var phase: String?
    var target_km: Double?
    var long_run_km: Double?
    var quality_sessions: Double?
    var is_cutback: Bool?
    var milestone: String? // "", "final_long_run", "race_week"

    var startDate: Date { RunRecord.pbDateFormatter.date(from: week_start) ?? .distantPast }
    var localDayKey: String { String(week_start.prefix(10)) }
    var targetKm: Double { target_km ?? 0 }
    var isFinalLongRun: Bool { milestone == "final_long_run" }
    var isRaceWeek: Bool { milestone == "race_week" }
    var isBenchmark: Bool { milestone == "benchmark" } // M9.2: re-anchor effort
}

struct PlanWeek: Codable, Identifiable {
    var id: String
    var week_idx: Double?
    var phase: String?
    var rationale: String?
}

extension PlannedWorkout {
    /// Shared status color: future-orange, done-green, skipped-red.
    var statusColor: Color {
        switch status {
        case "done": return .green
        case "skipped": return .red
        default: return .orange
        }
    }
}

struct GeneratedWeek: Codable {
    var week_start: String
    var phase: String
    var cap_km: Double
    var rationale: String
}

// MARK: - M2: recovery, profile, engine

/// One day of recovery metrics pushed to `recovery_daily`.
struct RecoveryPayload: Codable {
    var date: String // "yyyy-MM-ddT00:00:00.000Z" (local day label)
    var hrv_sdnn_ms: Double?
    var resting_hr: Double?
    var sleep_hours: Double?
    var vo2max: Double?
    var body_mass_kg: Double? // M10: weight — personalizes fueling opinions

    var hasAnyMetric: Bool {
        hrv_sdnn_ms != nil || resting_hr != nil || sleep_hours != nil
            || vo2max != nil || body_mass_kg != nil
    }
}

struct RecoveryRecord: Codable, Identifiable {
    var id: String
    var date: String
    var localDayKey: String {
        (RunRecord.pbDateFormatter.date(from: date) ?? .distantPast).localDayKey
    }
}

/// The singleton athlete profile row (PB returns "" for unset dates/strings).
struct AthleteProfile: Codable {
    var id: String?
    var race_name: String?
    var race_date: String?
    var goal_time_s: Double?
    var methodology: String?
    var days_per_week: Double?
    var long_run_day: String?
    var run_days: String? // M7: "Monday,Wednesday,…" — the days you run
    var weekly_target_km: Double? // M7: your desired weekly volume (caps safely)
    var injured: Bool?
    var injury_note: String?
    var return_to_run_date: String?
    var hr_max: Double?
}

/// Subset of GET /api/coach/engine the app renders. `for_llm` is the
/// pre-formatted string projection — schema-stable by design, so the UI
/// leans on it instead of chasing the engine's raw shape.
struct EngineState: Codable {
    struct TrafficLight: Codable {
        var light: String
        var emoji: String
        var reasons: [String]
    }
    struct Vdot: Codable {
        var available: Bool
        var value: Double?
        var zones: [String: String]?
        var zones_sec: [String: Double]? // raw sec/km — run classification
    }
    struct GoalTrajectory: Codable { // M7 Phase 5
        var available: Bool
        var required_vdot: Double?
        var current_vdot: Double?
        var trend_per_month: Double?
        var projected_vdot: Double?
        var weeks_to_race: Double? // Double: tolerate int-or-float serialization
        var status: String? // on_track | borderline | off_track
    }
    var traffic_light: TrafficLight
    var vdot: Vdot
    var goal_trajectory: GoalTrajectory? // M7 Phase 5
    var for_llm: [String: String]?
}

struct AdviceResponse: Codable {
    var advice: String
    var provider: String
}

// MARK: - Helpers

extension Date {
    var localDayKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: self)
    }
}
