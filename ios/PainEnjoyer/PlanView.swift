import SwiftUI

/// M6: the training plan as a first-class tab — race countdown, equivalent
/// race times from the engine's VDOT, and the upcoming weeks day by day.
struct PlanView: View {
    @ObservedObject var model: AppModel
    @State private var showRaceSheet = false

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
                    trajectoryCard
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
                    else { Label("Update plan", systemImage: "calendar.badge.plus") }
                }
                .disabled(model.busy)
            }
            .refreshable { await model.refresh() }
            .sheet(isPresented: $showRaceSheet) {
                RaceSheet(profile: model.profile) { updated in
                    Task { await model.saveProfile(updated) }
                }
            }
        }
    }

    // MARK: M7 Phase 5 — goal trajectory (required vs projected VDOT)

    @ViewBuilder
    private var trajectoryCard: some View {
        if let gt = model.engine?.goal_trajectory, gt.available,
           let req = gt.required_vdot, let cur = gt.current_vdot,
           let proj = gt.projected_vdot, let trend = gt.trend_per_month,
           let status = gt.status {
            let color: Color = status == "on_track" ? .green
                             : status == "off_track" ? .red : .orange
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("GOAL TRAJECTORY", systemImage: "target")
                        .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(status.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(color.opacity(0.2)))
                        .foregroundStyle(color)
                }
                Text(String(format: "Needs VDOT %.1f — currently %.1f, trending %+.1f/mo", req, cur, trend))
                    .font(.subheadline)
                Text(String(format: "Projected %.1f by race day", proj))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }

    // MARK: race countdown

    @ViewBuilder
    private var raceCard: some View {
        Button { showRaceSheet = true } label: {
            if let profile = model.profile,
               let name = profile.race_name, !name.isEmpty,
               let key = model.raceDayKey,
               let raceDate = RunRecord.pbDateFormatter.date(from: (profile.race_date ?? "")) {
                let days = max(0, Calendar.current.dateComponents([.day], from: .now, to: raceDate).day ?? 0)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("🏁").font(.system(size: 34))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name)
                                .font(.title3.weight(.heavy))
                            Text(raceDate.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                                .font(.caption).opacity(0.85)
                        }
                        Spacer()
                        Image(systemName: "pencil.circle.fill").font(.title3).opacity(0.8)
                    }
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Text("\(days)")
                            .font(.system(size: 56, weight: .black, design: .rounded))
                        VStack(alignment: .leading, spacing: 0) {
                            Text("days to go").font(.subheadline.weight(.semibold))
                            Text("\(days / 7) weeks").font(.caption).opacity(0.85)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            if let goal = profile.goal_time_s, goal > 0 {
                                Text(Self.hms(goal))
                                    .font(.title3.weight(.heavy).monospacedDigit())
                                Text("goal").font(.caption2).opacity(0.85)
                            }
                            if let phase = model.planWeeks.first?.phase, !phase.isEmpty {
                                Text(phase.uppercased())
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(.white.opacity(0.22)))
                            }
                        }
                    }
                    let _ = key // silences unused warning; key guards parse validity
                }
                .foregroundStyle(.white)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 22)
                        .fill(LinearGradient(colors: [Color.accentColor, .cyan],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: Color.accentColor.opacity(0.35), radius: 12, y: 4)
                )
            } else {
                VStack(spacing: 8) {
                    Text("🏁").font(.system(size: 34))
                    Text("Set your race").font(.headline)
                    Text("Name, date, and a goal time — the plan and countdown build around it.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(Color.accentColor.opacity(0.5),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                        .background(RoundedRectangle(cornerRadius: 22).fill(Color(.systemBackground)))
                )
            }
        }
        .buttonStyle(.plain)
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
                Text("Tap “Update plan” and the coach builds the rest of this week inside your VDOT zones and load cap.")
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


// MARK: - Race editor (lives in Plan, not the athlete profile)

struct RaceSheet: View {
    let profile: AthleteProfile?
    var onSave: (AthleteProfile) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var date: Date
    @State private var goal: String

    init(profile: AthleteProfile?, onSave: @escaping (AthleteProfile) -> Void) {
        self.profile = profile
        self.onSave = onSave
        _name = State(initialValue: profile?.race_name ?? "")
        let parsed = (profile?.race_date).flatMap {
            $0.isEmpty ? nil : RunRecord.pbDateFormatter.date(from: $0)
        }
        _date = State(initialValue: parsed ?? Date().addingTimeInterval(120 * 86400))
        _goal = State(initialValue: Self.formatGoal(profile?.goal_time_s))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Race") {
                    TextField("Race name", text: $name)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Goal time (e.g. 3:59 or 3:59:30)", text: $goal)
                        .keyboardType(.numbersAndPunctuation)
                }
                if !(profile?.race_name ?? "").isEmpty {
                    Section {
                        Button("Remove race", role: .destructive) {
                            onSave(merged(name: "", dateStr: "", goalS: 0))
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Your race")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(merged(name: name,
                                      dateStr: date.localDayKey + "T00:00:00.000Z",
                                      goalS: Self.parseGoal(goal)))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// Race fields change; everything else passes through untouched.
    private func merged(name: String, dateStr: String, goalS: Double) -> AthleteProfile {
        AthleteProfile(
            id: profile?.id,
            race_name: name,
            race_date: dateStr,
            goal_time_s: goalS,
            methodology: profile?.methodology?.isEmpty == false ? profile?.methodology : "hybrid_vdot_8020",
            days_per_week: profile?.days_per_week ?? 4,
            long_run_day: profile?.long_run_day ?? "Sunday",
            run_days: profile?.run_days ?? "",
            weekly_target_km: profile?.weekly_target_km ?? 0,
            injured: profile?.injured ?? false,
            injury_note: profile?.injury_note ?? "",
            return_to_run_date: profile?.return_to_run_date ?? "",
            hr_max: profile?.hr_max ?? 0
        )
    }

    private static func parseGoal(_ s: String) -> Double {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 2: return parts[0] * 3600 + parts[1] * 60
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return 0
        }
    }

    private static func formatGoal(_ s: Double?) -> String {
        guard let s, s > 0 else { return "" }
        let t = Int(s)
        return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }
}
