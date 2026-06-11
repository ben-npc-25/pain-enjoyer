import SwiftUI

// MARK: - Day detail (M3: planned vs actual + athlete notes)

struct DayDetailSheet: View {
    let dayKey: String
    let runs: [RunRecord]
    let planned: [PlannedWorkout]
    let onDelete: (RunRecord) -> Void
    let onSaveNotes: (RunRecord, String) -> Void
    var onAskCoach: ((PlannedWorkout) -> Void)? = nil
    var zones: [String: Double]? = nil
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        (runs.first?.startDate ?? planned.first?.startDate)?
            .formatted(date: .abbreviated, time: .omitted) ?? dayKey
    }

    var body: some View {
        NavigationStack {
            List {
                if !planned.isEmpty {
                    Section("Planned") {
                        ForEach(planned) { wo in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(wo.typeLabel).font(.headline)
                                    if wo.distanceKm > 0 {
                                        Text(String(format: "%.1f km", wo.distanceKm))
                                            .font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    statusBadge(wo.status ?? "planned")
                                }
                                if let pace = wo.paceRange {
                                    Label(pace, systemImage: "speedometer")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                if let d = wo.description, !d.isEmpty {
                                    Text(d).font(.subheadline).foregroundStyle(.secondary)
                                }
                                if let onAskCoach {
                                    Button {
                                        onAskCoach(wo)
                                    } label: {
                                        Label("Ask the coach about this", systemImage: "bubble.left")
                                            .font(.footnote)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if !runs.isEmpty {
                    Section(planned.isEmpty ? "Runs" : "Actual") {
                        ForEach(runs) { run in
                            NavigationLink {
                                RunDetailView(run: run, zones: zones, onSaveNotes: onSaveNotes)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(String(format: "%.2f km", run.distanceKm)).font(.title3.bold())
                                        RunTypeChip(type: run.runClass(zones: zones))
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
                                    if let n = run.notes, !n.isEmpty {
                                        Label(n, systemImage: "text.bubble")
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .swipeActions {
                                Button(role: .destructive) { onDelete(run) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func statusBadge(_ status: String) -> some View {
        Text(status)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(badgeColor(status).opacity(0.15)))
            .foregroundStyle(badgeColor(status))
    }

    private func badgeColor(_ status: String) -> Color {
        switch status {
        case "done": return .green
        case "skipped": return .red
        case "modified": return .purple
        default: return .orange
        }
    }
}

// MARK: - M3: chat with the coach (M4: lives as a tab)

struct ChatView: View {
    @ObservedObject var model: AppModel
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    /// Fresh slate each day: only the last 24 h shows. Full history stays on
    /// the server; coach_memory carries the long-term context.
    private var sessionMessages: [CoachMessage] {
        let cutoff = Date.now.addingTimeInterval(-24 * 3600)
        return model.messages.filter { msg in
            guard let created = msg.created,
                  let d = RunRecord.pbDateFormatter.date(from: created) else { return true }
            return d >= cutoff
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if sessionMessages.isEmpty && !model.chatBusy {
                                ContentUnavailableView(
                                    "Fresh slate",
                                    systemImage: "bubble.left.and.bubble.right",
                                    description: Text("Say anything — the coach still remembers what matters from before.")
                                )
                                .padding(.top, 60)
                            }
                            ForEach(sessionMessages) { msg in
                                bubble(msg)
                            }
                            if model.chatBusy {
                                HStack { ProgressView(); Text("Coach is thinking…")
                                        .font(.caption).foregroundStyle(.secondary) }
                                    .id("thinking")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: model.messages.count, initial: true) { _, _ in
                        if let last = sessionMessages.last?.id {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                    // escape hatch: drag or tap the conversation to drop the
                    // keyboard (it covers the tab bar while up)
                    .scrollDismissesKeyboard(.interactively)
                    .onTapGesture { inputFocused = false }
                }
                Divider()
                HStack(spacing: 8) {
                    TextField("Tell your coach anything…", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .focused($inputFocused)
                    Button {
                        let text = draft
                        draft = ""
                        Task { await model.sendChat(text) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || model.chatBusy)
                }
                .padding()
            }
            .navigationTitle("Coach chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // structured "what should I do today" advice, lands in the thread
                Button {
                    Task { await model.askCoach() }
                } label: {
                    if model.busy { ProgressView() }
                    else { Label("Today's advice", systemImage: "sparkles") }
                }
                .disabled(model.busy || model.chatBusy)
            }
            // M5: prefilled drafts arrive from quick actions elsewhere
            .onChange(of: model.chatPrefill, initial: true) { _, prefill in
                if !prefill.isEmpty {
                    draft = prefill
                    model.chatPrefill = ""
                    inputFocused = true
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ msg: CoachMessage) -> some View {
        HStack {
            if msg.isAthlete { Spacer(minLength: 40) }
            Group {
                if msg.isAthlete { Text(msg.content).font(.subheadline) }
                else { CoachProse(text: msg.content, font: .subheadline) }
            }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(msg.isAthlete ? Color.accentColor.opacity(0.9)
                                            : Color(.secondarySystemBackground))
                )
                .foregroundStyle(msg.isAthlete ? .white : .primary)
                .frame(maxWidth: .infinity,
                       alignment: msg.isAthlete ? .trailing : .leading)
            if !msg.isAthlete { Spacer(minLength: 40) }
        }
        .id(msg.id)
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
        let parsedReturn = Self.parsePBDate(existing?.return_to_run_date)
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
                Section {
                    Text("Your race lives in the Plan tab now — this is about you.")
                        .font(.footnote).foregroundStyle(.secondary)
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
            // race fields are edited in the Plan tab — pass through untouched
            race_name: existing?.race_name ?? "",
            race_date: existing?.race_date ?? "",
            goal_time_s: existing?.goal_time_s ?? 0,
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
