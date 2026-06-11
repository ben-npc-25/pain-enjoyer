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

// MARK: - M2: athlete profile (onboarding + editing)

struct ProfileSheet: View {
    let existing: AthleteProfile?
    var onSave: (AthleteProfile) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var raceName: String
    @State private var hasRace: Bool
    @State private var raceDate: Date
    @State private var goalTime: String
    @State private var daysPerWeek: Int
    @State private var longRunDay: String
    @State private var injured: Bool
    @State private var injuryNote: String
    @State private var hasReturnDate: Bool
    @State private var returnDate: Date
    @State private var hrMax: String

    private static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday",
                                   "Friday", "Saturday", "Sunday"]

    init(existing: AthleteProfile?, onSave: @escaping (AthleteProfile) -> Void) {
        self.existing = existing
        self.onSave = onSave
        let parsedRace = Self.parsePBDate(existing?.race_date)
        let parsedReturn = Self.parsePBDate(existing?.return_to_run_date)
        _raceName = State(initialValue: existing?.race_name ?? "")
        _hasRace = State(initialValue: parsedRace != nil)
        _raceDate = State(initialValue: parsedRace ?? Date().addingTimeInterval(180 * 86400))
        _goalTime = State(initialValue: Self.formatGoal(existing?.goal_time_s))
        _daysPerWeek = State(initialValue: Int(existing?.days_per_week ?? 4))
        _longRunDay = State(initialValue: (existing?.long_run_day).flatMap {
            Self.weekdays.contains($0) ? $0 : nil } ?? "Sunday")
        _injured = State(initialValue: existing?.injured ?? false)
        _injuryNote = State(initialValue: existing?.injury_note ?? "")
        _hasReturnDate = State(initialValue: parsedReturn != nil)
        _returnDate = State(initialValue: parsedReturn ?? Date().addingTimeInterval(30 * 86400))
        _hrMax = State(initialValue: (existing?.hr_max).map { $0 > 0 ? String(Int($0)) : "" } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Race goal") {
                    Toggle("Training for a race", isOn: $hasRace)
                    if hasRace {
                        TextField("Race name", text: $raceName)
                        DatePicker("Race date", selection: $raceDate, displayedComponents: .date)
                        TextField("Goal time (e.g. 3:59 or 3:59:30)", text: $goalTime)
                            .keyboardType(.numbersAndPunctuation)
                    }
                }
                Section("Training constraints") {
                    Stepper("Days per week: \(daysPerWeek)", value: $daysPerWeek, in: 1...7)
                    Picker("Long run day", selection: $longRunDay) {
                        ForEach(Self.weekdays, id: \.self) { Text($0) }
                    }
                    TextField("Max heart rate (optional)", text: $hrMax)
                        .keyboardType(.numberPad)
                }
                Section {
                    Toggle("Currently injured", isOn: $injured)
                    if injured {
                        TextField("What's injured?", text: $injuryNote)
                        Toggle("Target return date", isOn: $hasReturnDate)
                        if hasReturnDate {
                            DatePicker("Return to running", selection: $returnDate,
                                       displayedComponents: .date)
                        }
                    }
                } header: {
                    Text("Injury")
                } footer: {
                    Text(injured
                         ? "The engine holds the traffic light at 🔴 until you clear this."
                         : "Flip this if you get hurt — the coach adapts immediately.")
                }
            }
            .navigationTitle(existing == nil ? "Welcome — set up your coach" : "Athlete profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(buildProfile()); dismiss() }
                }
            }
        }
    }

    private func buildProfile() -> AthleteProfile {
        // Explicit empties (not nil): JSONEncoder drops nil keys, and PATCH
        // must be able to CLEAR a field (e.g. injury healed, race cancelled).
        AthleteProfile(
            id: existing?.id,
            race_name: hasRace ? raceName : "",
            race_date: hasRace ? Self.pbDay(raceDate) : "",
            goal_time_s: hasRace ? Self.parseGoal(goalTime) : 0,
            methodology: existing?.methodology?.isEmpty == false
                ? existing?.methodology : "hybrid_vdot_8020",
            days_per_week: Double(daysPerWeek),
            long_run_day: longRunDay,
            injured: injured,
            injury_note: injured ? injuryNote : "",
            return_to_run_date: (injured && hasReturnDate) ? Self.pbDay(returnDate) : "",
            hr_max: Double(hrMax) ?? 0
        )
    }

    // MARK: date/time helpers

    private static func parsePBDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return RunRecord.pbDateFormatter.date(from: s)
    }

    private static func pbDay(_ d: Date) -> String { d.localDayKey + "T00:00:00.000Z" }

    private static func parseGoal(_ s: String) -> Double {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 2: return parts[0] * 3600 + parts[1] * 60          // H:MM
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2] // H:MM:SS
        default: return 0
        }
    }

    private static func formatGoal(_ s: Double?) -> String {
        guard let s, s > 0 else { return "" }
        let t = Int(s)
        return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }
}

// MARK: - M2: engine detail (what the coach sees)

struct EngineDetailSheet: View {
    let engine: EngineState
    @Environment(\.dismiss) private var dismiss

    private static let zoneOrder = [("easy", "Easy"), ("marathon", "Marathon"),
                                    ("threshold", "Threshold"), ("interval", "Interval"),
                                    ("repetition", "Repetition")]
    private static let factOrder = ["athlete_status", "race_goal", "current_vdot",
                                    "training_load", "recovery", "intensity_8020", "history"]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(engine.traffic_light.reasons, id: \.self) { r in
                        Label(r, systemImage: "circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                } header: {
                    Text("\(engine.traffic_light.emoji) \(engine.traffic_light.light.capitalized) — why")
                }

                if let zones = engine.vdot.zones {
                    Section("Pace zones" + (engine.vdot.value.map { String(format: " (VDOT %.1f)", $0) } ?? "")) {
                        ForEach(Self.zoneOrder, id: \.0) { key, label in
                            if let pace = zones[key] {
                                HStack {
                                    Text(label)
                                    Spacer()
                                    Text(pace).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                    }
                }

                if let facts = engine.for_llm {
                    Section("Engine facts (what the coach sees)") {
                        ForEach(Self.factOrder, id: \.self) { key in
                            if let v = facts[key] {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(key.replacingOccurrences(of: "_", with: " ").capitalized)
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(v).font(.subheadline)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Training engine")
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
