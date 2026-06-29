import Foundation

enum PBError: LocalizedError {
    case http(Int, String)
    case notConfigured
    var errorDescription: String? {
        switch self {
        case let .http(code, body): return "Server error \(code): \(body.prefix(200))"
        case .notConfigured: return "Server not configured — open Settings."
        }
    }
}

/// Minimal PocketBase REST client.
final class PocketBaseClient {
    private let baseURL: URL
    private var token: String?

    init(baseURL: URL) { self.baseURL = baseURL }

    /// Build a client from the stored settings (used by background sync too).
    static func fromSettings() -> (client: PocketBaseClient, email: String, password: String)? {
        let d = UserDefaults.standard
        guard let urlStr = d.string(forKey: "serverURL"), let url = URL(string: urlStr),
              let email = d.string(forKey: "email"), !email.isEmpty,
              let pass = d.string(forKey: "password"), !pass.isEmpty
        else { return nil }
        return (PocketBaseClient(baseURL: url), email, pass)
    }

    // MARK: core request

    @discardableResult
    private func request(_ path: String, method: String = "POST",
                         query: [URLQueryItem] = [], body: Encodable? = nil) async throws -> Data {
        var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 120 // LLM calls can take a while
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue(token, forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try JSONEncoder().encode(AnyEncodable(body)) }

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw PBError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private struct ListResponse<T: Codable>: Codable { let items: [T] }

    // MARK: API

    func authenticate(email: String, password: String) async throws {
        struct Auth: Encodable { let identity: String, password: String }
        struct AuthResp: Decodable { let token: String }
        let data = try await request("/api/collections/users/auth-with-password",
                                     body: Auth(identity: email, password: password))
        token = try JSONDecoder().decode(AuthResp.self, from: data).token
    }

    func health() async throws -> Bool {
        struct H: Decodable { let ok: Bool }
        let data = try await request("/api/coach/health", method: "GET")
        return try JSONDecoder().decode(H.self, from: data).ok
    }

    /// Upload a run; a duplicate (unique healthkit_uuid) counts as success.
    /// Returns true if it was a NEW record.
    @discardableResult
    func uploadRun(_ run: RunPayload) async throws -> Bool {
        do {
            try await request("/api/collections/runs/records", body: run)
            return true
        } catch PBError.http(400, let body) where body.contains("healthkit_uuid") {
            return false // already synced — fine
        }
    }

    /// All runs (single-user POC: one page of 500 covers ~2 years).
    func listRuns() async throws -> [RunRecord] {
        let data = try await request("/api/collections/runs/records", method: "GET",
                                     query: [.init(name: "perPage", value: "500"),
                                             .init(name: "sort", value: "-date")])
        return try JSONDecoder().decode(ListResponse<RunRecord>.self, from: data).items
    }

    func latestCoachMessage() async throws -> CoachMessage? {
        let data = try await request("/api/collections/coach_messages/records", method: "GET",
                                     query: [.init(name: "perPage", value: "1"),
                                             .init(name: "sort", value: "-created"),
                                             .init(name: "filter", value: "(role='coach')")])
        return try JSONDecoder().decode(ListResponse<CoachMessage>.self, from: data).items.first
    }

    func askCoach() async throws -> AdviceResponse {
        let data = try await request("/api/coach/advise")
        return try JSONDecoder().decode(AdviceResponse.self, from: data)
    }

    func deleteRun(id: String) async throws {
        try await request("/api/collections/runs/records/\(id)", method: "DELETE")
    }

    // MARK: M2 — engine, profile, recovery

    func engineState() async throws -> EngineState {
        let data = try await request("/api/coach/engine", method: "GET")
        return try JSONDecoder().decode(EngineState.self, from: data)
    }

    /// The singleton profile row, or nil if onboarding hasn't happened yet.
    func getProfile() async throws -> AthleteProfile? {
        let data = try await request("/api/collections/athlete_profile/records", method: "GET",
                                     query: [.init(name: "perPage", value: "1"),
                                             .init(name: "sort", value: "-created")])
        return try JSONDecoder().decode(ListResponse<AthleteProfile>.self, from: data).items.first
    }

    /// Create-or-update keyed on the record id (single row).
    func saveProfile(_ p: AthleteProfile) async throws {
        if let id = p.id, !id.isEmpty {
            try await request("/api/collections/athlete_profile/records/\(id)",
                              method: "PATCH", body: p)
        } else {
            try await request("/api/collections/athlete_profile/records", body: p)
        }
    }

    /// Existing recovery rows (id + date) so sync can upsert by day.
    func listRecovery(perPage: Int = 100) async throws -> [RecoveryRecord] {
        let data = try await request("/api/collections/recovery_daily/records", method: "GET",
                                     query: [.init(name: "perPage", value: String(perPage)),
                                             .init(name: "sort", value: "-date"),
                                             .init(name: "fields", value: "id,date")])
        return try JSONDecoder().decode(ListResponse<RecoveryRecord>.self, from: data).items
    }

    func createRecovery(_ r: RecoveryPayload) async throws {
        try await request("/api/collections/recovery_daily/records", body: r)
    }

    func updateRecovery(id: String, _ r: RecoveryPayload) async throws {
        try await request("/api/collections/recovery_daily/records/\(id)", method: "PATCH", body: r)
    }

    // MARK: M3 — plan, chat, run notes

    func listPlanned() async throws -> [PlannedWorkout] {
        let data = try await request("/api/collections/planned_workouts/records", method: "GET",
                                     query: [.init(name: "perPage", value: "500"),
                                             .init(name: "sort", value: "-date")])
        return try JSONDecoder().decode(ListResponse<PlannedWorkout>.self, from: data).items
    }

    func generateWeek() async throws -> GeneratedWeek {
        let data = try await request("/api/coach/plan-week")
        return try JSONDecoder().decode(GeneratedWeek.self, from: data)
    }

    func chat(message: String) async throws -> ChatResponse {
        struct Msg: Encodable { let message: String }
        let data = try await request("/api/coach/chat", body: Msg(message: message))
        return try JSONDecoder().decode(ChatResponse.self, from: data)
    }

    /// Conversation, oldest first.
    func listMessages(limit: Int = 50) async throws -> [CoachMessage] {
        let data = try await request("/api/collections/coach_messages/records", method: "GET",
                                     query: [.init(name: "perPage", value: String(limit)),
                                             .init(name: "sort", value: "-created")])
        return try JSONDecoder().decode(ListResponse<CoachMessage>.self, from: data).items.reversed()
    }

    func updateRunNotes(id: String, notes: String) async throws {
        struct Notes: Encodable { let notes: String }
        try await request("/api/collections/runs/records/\(id)", method: "PATCH",
                          body: Notes(notes: notes))
    }

    /// M7 Phase 1: persist the athlete's per-run effort (RPE 1–5).
    func updateRunEffort(id: String, effort: Int) async throws {
        struct Effort: Encodable { let effort: Int }
        try await request("/api/collections/runs/records/\(id)", method: "PATCH",
                          body: Effort(effort: effort))
    }

    /// M7: ask the coach to react to the latest run. The reply is saved on the
    /// run server-side (coach_note) and returned — it does NOT enter the chat.
    func runFeedback() async throws -> String {
        struct R: Decodable { let coach_note: String }
        let data = try await request("/api/coach/run-feedback")
        return try JSONDecoder().decode(R.self, from: data).coach_note
    }

    // MARK: M6 — plan weeks + trends review

    func listPlanWeeks() async throws -> [PlanWeek] {
        let data = try await request("/api/collections/plan_weeks/records", method: "GET",
                                     query: [.init(name: "perPage", value: "6"),
                                             .init(name: "sort", value: "-week_idx")])
        return try JSONDecoder().decode(ListResponse<PlanWeek>.self, from: data).items
    }

    func trendsReview() async throws -> String {
        struct R: Decodable { let review: String }
        let data = try await request("/api/coach/trends-review")
        return try JSONDecoder().decode(R.self, from: data).review
    }

    /// M5: app-open ping — feeds the engagement score on the server.
    @discardableResult
    func ping() async throws -> Data {
        try await request("/api/coach/ping")
    }

    // MARK: M4 — memory + recovery series

    func listMemory() async throws -> [MemoryFact] {
        let data = try await request("/api/collections/coach_memory/records", method: "GET",
                                     query: [.init(name: "perPage", value: "50"),
                                             .init(name: "sort", value: "-confidence,-last_reinforced")])
        return try JSONDecoder().decode(ListResponse<MemoryFact>.self, from: data).items
    }

    func deleteMemory(id: String) async throws {
        try await request("/api/collections/coach_memory/records/\(id)", method: "DELETE")
    }

    func distillNow() async throws -> DistillResult {
        let data = try await request("/api/coach/distill")
        return try JSONDecoder().decode(DistillResult.self, from: data)
    }

    /// Full recovery rows for the Trends charts, newest first.
    func listRecoveryFull(perPage: Int = 90) async throws -> [RecoveryFull] {
        let data = try await request("/api/collections/recovery_daily/records", method: "GET",
                                     query: [.init(name: "perPage", value: String(perPage)),
                                             .init(name: "sort", value: "-date")])
        return try JSONDecoder().decode(ListResponse<RecoveryFull>.self, from: data).items
    }
}

/// Type-erasing wrapper so `request` can take any Encodable.
private struct AnyEncodable: Encodable {
    private let encodeFn: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encodeFn = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}
