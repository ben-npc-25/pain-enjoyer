import SwiftUI

/// M4 home tab: hero traffic light, this week at a glance, latest coach word.
struct CoachHomeView: View {
    @ObservedObject var model: AppModel

    @State private var showProfile = false
    @State private var showSettings = false
    @State private var showMemory = false
    @State private var showEngineDetail = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    heroCard
                    weekStrip
                    coachCard
                    if !model.status.isEmpty {
                        Text(model.status)
                            .font(.footnote)
                            .foregroundStyle(model.status.hasPrefix("✗") ? .red : .secondary)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Pain Enjoyer")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showMemory = true } label: { Image(systemName: "brain.head.profile") }
                    Button { showProfile = true } label: { Image(systemName: "person.crop.circle") }
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .refreshable { await model.refresh() }
            .sheet(isPresented: $showProfile) {
                ProfileSheet(existing: model.profile) { p in
                    Task { await model.saveProfile(p) }
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                Task { await model.refresh() }
            }) { SettingsSheet() }
            .sheet(isPresented: $showMemory) { MemoryView(model: model) }
            .sheet(isPresented: $showEngineDetail) {
                if let eng = model.engine { EngineDetailSheet(engine: eng) }
            }
        }
    }

    // MARK: hero — the traffic light IS the brand

    private var lightColor: Color {
        switch model.engine?.traffic_light.light {
        case "red": return .red
        case "yellow": return .orange
        case "green": return .green
        default: return .gray
        }
    }

    private var heroCard: some View {
        Button { if model.engine != nil { showEngineDetail = true } } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Text(model.engine?.traffic_light.emoji ?? "⚪️")
                        .font(.system(size: 52))
                        .shadow(color: lightColor.opacity(0.6), radius: 14)
                    VStack(alignment: .leading, spacing: 3) {
                        Text((model.engine?.traffic_light.light ?? "no data").uppercased())
                            .font(.title2.weight(.heavy))
                            .foregroundStyle(.primary)
                        if let v = model.engine?.vdot.value {
                            Text(String(format: "VDOT %.1f", v))
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Capsule().fill(.thinMaterial))
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.bold()).foregroundStyle(.secondary)
                }
                if let reason = model.engine?.traffic_light.reasons.first {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(LinearGradient(
                        colors: [lightColor.opacity(0.42), lightColor.opacity(0.10)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(lightColor.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    // MARK: this week at a glance

    private var weekDays: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
    }

    private var weekStrip: some View {
        HStack(spacing: 6) {
            ForEach(weekDays, id: \.self) { day in
                let key = day.localDayKey
                let plan = model.plannedByDay[key]?.first
                let ran = !(model.runsByDay[key]?.isEmpty ?? true)
                VStack(spacing: 4) {
                    Text(day.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Group {
                        if key == model.raceDayKey {
                            Text("🏁").font(.system(size: 13))
                        } else if ran {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.accentColor)
                        } else if let plan {
                            Text(plan.isRest ? "–" : plan.type)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(plan.isRest ? Color.secondary : plan.statusColor)
                        } else {
                            Text("·").font(.system(size: 12)).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(height: 16)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Calendar.current.isDateInToday(day)
                              ? Color.accentColor.opacity(0.12) : Color(.secondarySystemBackground))
                )
            }
        }
        .padding(.horizontal)
    }

    // MARK: coach card

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
                Text("No advice yet — pull to refresh, then ask.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    Task { await model.askCoach() }
                } label: {
                    if model.busy { ProgressView().frame(maxWidth: .infinity) }
                    else { Text("Ask the coach").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy)

                Button {
                    Task { await model.generatePlan() }
                } label: {
                    Label("Plan week", systemImage: "calendar.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.busy)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
        .padding(.horizontal)
    }
}
