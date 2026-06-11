import SwiftUI

/// M0 screen: connect → sync latest run → show the coach's advice.
/// The calendar UI replaces this as the home screen in M1.
struct ContentView: View {
    @AppStorage("serverURL") private var serverURL = ""
    @AppStorage("email") private var email = ""
    @AppStorage("password") private var password = "" // POC only — Keychain in M1

    @State private var status = "Not connected"
    @State private var advice: String?
    @State private var provider: String?
    @State private var busy = false

    private let health = HealthKitService()

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://pi.tailnet.ts.net", text: $serverURL)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never).keyboardType(.emailAddress)
                    SecureField("Password", text: $password)
                }

                Section {
                    Button {
                        Task { await syncAndAdvise() }
                    } label: {
                        if busy { ProgressView() } else { Text("Sync latest run → Coach 🏃") }
                    }
                    .disabled(busy || serverURL.isEmpty || email.isEmpty || password.isEmpty)
                } footer: {
                    Text(status)
                }

                if let advice {
                    Section("Coach says\(provider.map { " (\($0))" } ?? "")") {
                        Text(advice)
                    }
                }
            }
            .navigationTitle("Pain Enjoyer")
        }
    }

    private func syncAndAdvise() async {
        busy = true
        defer { busy = false }
        do {
            guard let url = URL(string: serverURL) else {
                status = "Invalid server URL"; return
            }
            status = "Requesting Health access…"
            try await health.requestAuthorization()

            status = "Reading latest run from Health…"
            let run = try await health.fetchLatestRun()

            status = "Connecting to the Pi…"
            let pb = PocketBaseClient(baseURL: url)
            try await pb.authenticate(email: email, password: password)

            status = "Uploading run (\(String(format: "%.1f", run.distance_m / 1000)) km)…"
            try await pb.uploadRun(run)

            status = "Coach is thinking…"
            let resp = try await pb.askCoach()
            advice = resp.advice
            provider = resp.provider
            status = "Done — synced from \(run.source_app)."
        } catch {
            status = "✗ \(error.localizedDescription)"
        }
    }
}

#Preview { ContentView() }
