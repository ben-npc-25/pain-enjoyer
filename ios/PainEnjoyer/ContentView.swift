import SwiftUI

/// M1 home screen: calendar + coach card. Sheets for settings / manual entry /
/// day detail / HealthKit audit.
struct ContentView: View {
    @StateObject private var model = AppModel()
    @AppStorage("serverURL") private var serverURL = ""

    @State private var showSettings = false
    @State private var showManualEntry = false
    @State private var showAudit = false
    @State private var selectedDay: DaySelection?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    CalendarView(runsByDay: model.runsByDay) { dayRuns in
                        selectedDay = DaySelection(runs: dayRuns)
                    }

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
                    Button { showManualEntry = true } label: { Image(systemName: "plus") }
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .refreshable { await model.refresh() }
            .task {
                if serverURL.isEmpty { showSettings = true }
                else { await model.refresh() }
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                Task { await model.refresh() }
            }) { SettingsSheet() }
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
