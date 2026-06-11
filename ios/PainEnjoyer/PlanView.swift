import SwiftUI

/// M6: the training plan as a first-class tab — race countdown, equivalent
/// race times from the engine's VDOT, and the upcoming weeks day by day.
struct PlanView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !model.status.isEmpty {
                        Text(model.status)
                            .font(.footnote.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(model.status.hasPrefix("✗") ? .red : .secondary)
                    }
                    raceCard
                    if let vdot = model.engine?.vdot.value { predictorCard(vdot) }
                    weeksSection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Plan")
            .toolbar {
                Button {
                    Task { await model.generatePlan() }
                } label: {
                    if model.busy { ProgressView() }
                    else { Label("Plan next week", systemImage: "calendar.badge.plus") }
                }
                .disabled(model.busy)
            }
            .refreshable { await model.refresh() }
        }
    }

    // MARK: race countdown

    @ViewBuilder
    private var raceCard: some View {
        if let profile = model.profile,
           let name = profile.race_name, !name.isEmpty,
           let key = model.raceDayKey,
           let raceDate = RunRecord.pbDateFormatter.date(from: (profile.race_date ?? "")) {
            let days = max(0, Calendar.current.dateComponents([.day], from: .now, to: raceDate).day ?? 0)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("🏁").font(.system(size: 30))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.headline)
                        Text(key).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let phase = model.planWeeks.first?.phase, !phase.isEmpty {
                        Text(phase.uppercased())
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(days)").font(.system(size: 40, weight: .heavy, design: .rounded))
                    Text("days · \(days / 7) weeks to go")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if let goal = profile.goal_time_s, goal > 0 {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("goal").font(.caption2).foregroundStyle(.tertiary)
                            Text(Self.hms(goal)).font(.headline.monospacedDigit())
                        }
                    }
                }
            }
            .cardStyle()
        } else {
            HStack {
                Text("No race set — add one in your profile and the plan gets a target.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
            .cardStyle()
        }
    }

    // MARK: equivalent race times

    private static let raceDistances: [(String, Double)] =
        [("5K", 5000), ("10K", 10000), ("Half", 21097.5), ("Marathon", 42195)]

    private func predictorCard(_ vdot: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("What your fitness is worth").font(.headline)
                Spacer()
                Text(String(format: "VDOT %.1f", vdot))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                ForEach(Self.raceDistances, id: \.0) { name, meters in
                    VStack(spacing: 3) {
                        Text(name).font(.caption2).foregroundStyle(.secondary)
                        Text(Self.hms(predictedRaceTime(distanceM: meters, vdot: vdot)))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Text("Equivalent race times at your current fitness — assumes full, healthy training for the distance.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .cardStyle()
    }

    // MARK: upcoming weeks

    private var upcomingWeeks: [(monday: Date, days: [PlannedWorkout])] {
        var cal = Calendar(identifier: .iso8601) // Monday weeks, like the server
        cal.timeZone = .current
        guard let thisWeek = cal.dateInterval(of: .weekOfYear, for: .now)?.start else { return [] }
        let groups = Dictionary(grouping: model.planned) { wo in
            cal.dateInterval(of: .weekOfYear, for: wo.startDate)?.start ?? .distantPast
        }
        return groups.keys
            .filter { $0 >= thisWeek }
            .sorted()
            .map { ($0, (groups[$0] ?? []).sorted { $0.date < $1.date }) }
    }

    @ViewBuilder
    private var weeksSection: some View {
        let weeks = upcomingWeeks
        if weeks.isEmpty {
            VStack(spacing: 8) {
                Text("No plan yet").font(.headline)
                Text("Tap “Plan next week” and the coach builds one inside your VDOT zones and load cap.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .cardStyle()
        } else {
            ForEach(weeks, id: \.monday) { week in
                weekCard(week.monday, week.days)
            }
        }
    }

    private func weekCard(_ monday: Date, _ days: [PlannedWorkout]) -> some View {
        let weekRow = model.planWeeks.first { pw in days.first?.plan_week_id == pw.id }
        let totalKm = days.reduce(0) { $0 + $1.distanceKm }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Week of \(monday.formatted(.dateTime.day().month(.abbreviated)))")
                    .font(.headline)
                Spacer()
                if totalKm > 0 {
                    Text(String(format: "%.0f km", totalKm))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            if let rationale = weekRow?.rationale, !rationale.isEmpty {
                CoachProse(text: rationale, font: .subheadline)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(days) { day in
                    dayRow(day)
                    if day.id != days.last?.id { Divider() }
                }
            }
        }
        .cardStyle()
    }

    private func dayRow(_ wo: PlannedWorkout) -> some View {
        let isToday = wo.localDayKey == Date.now.localDayKey
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text(wo.startDate.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.subheadline.weight(isToday ? .heavy : .regular))
                    .frame(width: 44, alignment: .leading)
                    .foregroundStyle(isToday ? Color.accentColor : .primary)
                if wo.isRest {
                    Text("Rest").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text(wo.typeLabel).font(.subheadline.weight(.medium))
                    if wo.distanceKm > 0 {
                        Text(String(format: "%.1f km", wo.distanceKm))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let pace = wo.paceRange {
                        Text(pace).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                statusIcon(wo.status ?? "planned")
            }
            if let d = wo.description, !d.isEmpty {
                Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    .padding(.leading, 54)
            }
            HStack {
                Spacer()
                Button {
                    model.openChat(prefill: String(
                        format: "About my planned %@ (%.1f km) on %@: ",
                        wo.typeLabel.lowercased(), wo.distanceKm, wo.localDayKey))
                } label: {
                    Label("Ask coach", systemImage: "bubble.left")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func statusIcon(_ status: String) -> some View {
        switch status {
        case "done": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "skipped": Image(systemName: "xmark.circle").foregroundStyle(.red)
        case "modified": Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default: Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        }
    }

    private static func hms(_ seconds: Double) -> String {
        let t = Int(seconds)
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }
}
