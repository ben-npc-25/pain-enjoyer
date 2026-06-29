import SwiftUI

/// M4 shell: four tabs over one shared model.
/// Coach (hero light + advice) · Calendar (plan vs actual) · Trends · Chat.
struct ContentView: View {
    @StateObject private var model = AppModel()
    @AppStorage("serverURL") private var serverURL = ""

    @State private var showFirstRunSettings = false
    @State private var showOnboarding = false

    var body: some View {
        TabView(selection: $model.selectedTab) {
            CoachHomeView(model: model)
                .tabItem { Label("Coach", systemImage: "figure.run") }
                .tag(AppModel.AppTab.coach)
            PlanView(model: model)
                .tabItem { Label("Plan", systemImage: "list.clipboard") }
                .tag(AppModel.AppTab.plan)
            CalendarTabView(model: model)
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(AppModel.AppTab.calendar)
            TrendsView(model: model)
                .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }
                .tag(AppModel.AppTab.trends)
            ChatView(model: model)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(AppModel.AppTab.chat)
        }
        // M6: bright, high-contrast by default (Ben's call — single-user app)
        .preferredColorScheme(.light)
        .task {
            if serverURL.isEmpty { showFirstRunSettings = true }
            else { await model.refresh() }
        }
        .onChange(of: model.needsOnboarding, initial: true) { _, needs in
            if needs { showOnboarding = true } // server reachable, no profile row
        }
        .sheet(isPresented: $showFirstRunSettings, onDismiss: {
            Task { await model.refresh() }
        }) { SettingsSheet() }
        .sheet(isPresented: $showOnboarding) {
            ProfileSheet(existing: model.profile) { p in
                Task { await model.saveProfile(p) }
            }
        }
    }
}

/// Calendar tab: month grid + manual entry + HealthKit audit + day detail.
struct CalendarTabView: View {
    @ObservedObject var model: AppModel

    @State private var showManualEntry = false
    @State private var selectedDay: DaySelection?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    CalendarView(runsByDay: model.runsByDay,
                                 plannedByDay: model.plannedByDay,
                                 raceDayKey: model.raceDayKey) { dayKey in
                        selectedDay = DaySelection(
                            dayKey: dayKey,
                            runs: model.runsByDay[dayKey] ?? [],
                            planned: model.plannedByDay[dayKey] ?? []
                        )
                    }
                    if !model.status.isEmpty {
                        Text(model.status)
                            .font(.footnote)
                            .foregroundStyle(model.status.hasPrefix("✗") ? .red : .secondary)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Calendar")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showManualEntry = true } label: { Image(systemName: "plus") }
                }
            }
            .refreshable { await model.refresh() }
            .sheet(isPresented: $showManualEntry) {
                ManualEntrySheet { date, km, min, hr in
                    Task { await model.addManualRun(date: date, distanceKm: km,
                                                    durationMin: min, avgHR: hr) }
                }
            }
            .sheet(item: $selectedDay) { sel in
                DayDetailSheet(
                    dayKey: sel.dayKey,
                    runs: sel.runs,
                    planned: sel.planned,
                    onDelete: { run in Task { await model.deleteRun(run) } },
                    onSaveNotes: { run, notes in
                        Task { await model.saveNotes(for: run, notes: notes) }
                    },
                    onSaveEffort: { run, v in
                        Task { await model.rateRunAndGetFeedback(run, effort: v) }
                    },
                    onAskCoach: { wo in
                        selectedDay = nil
                        model.openChat(prefill: String(
                            format: "About my planned %@ (%.1f km) on %@: ",
                            wo.typeLabel.lowercased(), wo.distanceKm, wo.localDayKey))
                    },
                    zones: model.zonesSec
                )
            }
        }
    }
}

/// Sheet item wrapper — arrays aren't Identifiable.
struct DaySelection: Identifiable {
    let id = UUID()
    let dayKey: String
    let runs: [RunRecord]
    let planned: [PlannedWorkout]
}

#Preview { ContentView() }
