import Foundation

// MARK: - Wire models (match the PocketBase `runs` schema)

/// Payload the phone sends when uploading a run.
struct RunPayload: Codable {
    var date: String
    var distance_m: Double
    var duration_s: Double
    var avg_hr: Double?
    var elevation_gain_m: Double?
    var source_app: String
    var healthkit_uuid: String
}

/// A run record as stored on the server.
struct RunRecord: Codable, Identifiable, Hashable {
    var id: String
    var date: String
    var distance_m: Double
    var duration_s: Double
    var avg_hr: Double?
    var elevation_gain_m: Double?
    var source_app: String?

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
