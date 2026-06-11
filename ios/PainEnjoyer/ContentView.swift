import SwiftUI

/// M1 home screen: calendar + coach card. Sheets for settings / manual entry /
/// day detail / HealthKit audit.
struct ContentView: View {
    @StateObject private var model = AppModel()
    @AppStorage("serverURL") private var serverURL = ""

    @State private var showSettings = false
    @State private var showManualEntry = false
    @State private var showAudit = false
    @State private var showProfile = false
    @State private var showEngineDetail = false
    @State private var selectedDay: DaySelection?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    CalendarView(runsByDay: model.runsByDay) { dayRuns in
                        selectedDay = DaySelection(runs: dayRuns)
                    }

                    engineCard

                    coachCard

                    if !model.status.isEmpty {
                        Text(model.status)
                            .font(.footnote)
                            .foregroundStyle(model.status.hasPrefix("✗") ? .red : .secondary)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Pain Enjoyer 🏃")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showAudit = true } label: { Image(systemName: "waveform.path.ecg") }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showProfile = true } label: { Image(systemName: "person.crop.circle") }
                    Button { showManualEntry = true } label: { Image(systemName: "plus") }
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .refreshable { await model.refresh() }
            .task {
                if serverURL.isEmpty { showSettings = true }
                else { await model.refresh() }
            }
            .onChange(of: model.needsOnboarding, initial: true) { _, needs in
                if needs { showProfile = true } // first run after M2: no profile row yet
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                Task { await model.refresh() }
            }) { SettingsSheet() }
            .sheet(isPresented: $showProfile) {
                ProfileSheet(existing: model.profile) { p in
                    Task { await model.saveProfile(p) }
                }
            }
            .sheet(isPresented: $showEngineDetail) {
                if let eng = model.engine { EngineDetailSheet(engine: eng) }
            }
            .sheet(isPresented: $showManualEntry) {
                ManualEntrySheet { date, km, min, hr in
                    Task { await model.addManualRun(date: date, distanceKm: km,
                                                    durationMin: min, avgHR: hr) }
                }
            }
            .sheet(isPresented: $showAudit) { AuditSheet() }
            .sheet(item: $selectedDay) { sel in
                DayDetailSheet(runs: sel.runs) { run in
                    Task { await model.deleteRun(run) }
                }
            }
        }
    }

    /// M2: traffic light + VDOT at a glance; tap for the full engine state.
    @ViewBuilder
    private var engineCard: some View {
        if let eng = model.engine {
            Button { showEngineDetail = true } label: {
                HStack(spacing: 12) {
                    Text(eng.traffic_light.emoji).font(.system(size: 34))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(eng.traffic_light.light.capitalized).font(.headline)
                            if let v = eng.vdot.value {
                                Text(String(format: "· VDOT %.1f", v))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Text(eng.traffic_light.reasons.first ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.bold()).foregroundStyle(.tertiary)
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.secondarySystemBackground)))
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
        }
    }

    private var coachCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Coach", systemImage: "figure.run.circle.fill")
                    .font(.headline)
                Spacer()
                if let p = model.coachMessage?.provider {
                    Text(p).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if let msg = model.coachMessage {
                Text(msg.content).font(.subheadline)
            } else {
                Text("No advice yet — sync a run and ask.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button {
                Task { await model.askCoach() }
            } label: {
                if model.busy { ProgressView().frame(maxWidth: .infinity) }
                else { Text("Ask the coach").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
        .padding(.horizontal)
    }
}

/// Sheet item wrapper — arrays aren't Identifiable.
struct DaySelection: Identifiable {
    let id = UUID()
    let runs: [RunRecord]
}

#Preview { ContentView() }
