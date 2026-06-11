import Foundation

/// Minimal PocketBase REST client — only what M0 needs.
/// (No official Swift SDK; this stays small on purpose.)
struct AdviceResponse: Codable {
    var advice: String
    var provider: String
}

enum PBError: LocalizedError {
    case http(Int, String)
    var errorDescription: String? {
        if case let .http(code, body) = self { return "Server error \(code): \(body)" }
        return nil
    }
}

final class PocketBaseClient {
    private let baseURL: URL
    private var token: String?

    init(baseURL: URL) { self.baseURL = baseURL }

    private func request(_ path: String, method: String = "POST", body: Encodable? = nil) async throws -> Data {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = method
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

    func authenticate(email: String, password: String) async throws {
        struct Auth: Encodable { let identity: String, password: String }
        struct AuthResp: Decodable { let token: String }
        let data = try await request("/api/collections/users/auth-with-password",
                                     body: Auth(identity: email, password: password))
        token = try JSONDecoder().decode(AuthResp.self, from: data).token
    }

    /// Push a run. A 400 from the unique healthkit_uuid index means "already
    /// synced" — treated as success so re-taps are harmless.
    func uploadRun(_ run: RunPayload) async throws {
        do { _ = try await request("/api/collections/runs/records", body: run) }
        catch PBError.http(400, let body) where body.contains("healthkit_uuid") {
            // duplicate — fine
        }
    }

    func askCoach() async throws -> AdviceResponse {
        let data = try await request("/api/coach/advise")
        return try JSONDecoder().decode(AdviceResponse.self, from: data)
    }
}

/// Type-erasing wrapper so `request` can take any Encodable.
private struct AnyEncodable: Encodable {
    private let encodeFn: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encodeFn = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}
