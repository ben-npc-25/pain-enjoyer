import SwiftUI

// MARK: - Day detail

struct DayDetailSheet: View {
    let runs: [RunRecord]
    let onDelete: (RunRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(runs) { run in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(String(format: "%.2f km", run.distanceKm)).font(.title3.bold())
                            Spacer()
                            Text(run.source_app ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 16) {
                            Label(run.durationString, systemImage: "stopwatch")
                            Label(run.paceString, systemImage: "speedometer")
                            if let hr = run.avg_hr, hr > 0 {
                                Label("\(Int(hr)) bpm", systemImage: "heart")
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        if let elev = run.elevation_gain_m, elev > 0 {
                            Label("\(Int(elev)) m elevation", systemImage: "mountain.2")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .swipeActions {
                        Button(role: .destructive) { onDelete(run) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(runs.first?.startDate.formatted(date: .abbreviated, time: .omitted) ?? "Runs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Manual entry

struct ManualEntrySheet: View {
    var onSave: (Date, Double, Double, Double?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var distanceKm = ""
    @State private var durationMin = ""
    @State private var avgHR = ""

    private var valid: Bool {
        (Double(distanceKm) ?? 0) > 0 && (Double(durationMin) ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date & time", selection: $date)
                TextField("Distance (km)", text: $distanceKm).keyboardType(.decimalPad)
                TextField("Duration (minutes)", text: $durationMin).keyboardType(.decimalPad)
                TextField("Avg heart rate (optional)", text: $avgHR).keyboardType(.numberPad)
            }
            .navigationTitle("Add run manually")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(date, Double(distanceKm) ?? 0, Double(durationMin) ?? 0, Double(avgHR))
                        dismiss()
                    }
                    .disabled(!valid)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @AppStorage("serverURL") private var serverURL = ""
    @AppStorage("email") private var email = ""
    @AppStorage("password") private var password = "" // POC — Keychain later
    @Environment(\.dismiss) private var dismiss
    @State private var testResult = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://coach.bennpc.uk", text: $serverURL)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never).keyboardType(.emailAddress)
                    SecureField("Password", text: $password)
                }
                Section {
                    Button("Test connection") {
                        Task {
                            do {
                                guard let url = URL(string: serverURL) else {
                                    testResult = "✗ invalid URL"; return
                                }
                                let pb = PocketBaseClient(baseURL: url)
                                try await pb.authenticate(email: email, password: password)
                                _ = try await pb.health()
                                testResult = "✓ connected & authenticated"
                            } catch {
                                testResult = "✗ \(error.localizedDescription)"
                            }
                        }
                    }
                } footer: {
                    Text(testResult)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

// MARK: - HealthKit field audit

struct AuditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var report = "Running audit…"

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(report)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("HealthKit audit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { ShareLink(item: report) }
            }
            .task {
                try? await HealthKitService.shared.requestAuthorization()
                report = await HealthKitService.shared.auditReport()
            }
        }
    }
}
