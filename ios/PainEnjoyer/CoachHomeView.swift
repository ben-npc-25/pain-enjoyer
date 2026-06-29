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
                    coachTipCard
                    latestActivityCard
                    statsCard
                    if !model.status.isEmpty {
                        Text(model.status)
                            .font(.footnote)
                            .foregroundStyle(model.status.hasPrefix("✗") ? .red : .secondary)
                    }
                }
                .padding(.vertical)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { Wordmark() } }
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

    // MARK: latest activity (the thing you did most recently)

    @ViewBuilder
    private var latestActivityCard: some View {
        if let run = model.runs.first {
            VStack(spacing: 8) {
            NavigationLink {
                RunDetailView(run: run, zones: model.zonesSec) { r, notes in
                    Task { await model.saveNotes(for: r, notes: notes) }
                } onSaveEffort: { r, v in
                    Task { await model.rateRunAndGetFeedback(r, effort: v) }
                }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("LATEST ACTIVITY")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(run.startDate.formatted(.relative(presentation: .named)))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(String(format: "%.2f km", run.distanceKm))
                            .font(.system(size: 30, weight: .heavy, design: .rounded))
                        RunTypeChip(type: run.runClass(zones: model.zonesSec))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.bold()).foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 16) {
                        Label(run.durationString, systemImage: "stopwatch")
                        Label(run.paceString, systemImage: "speedometer")
                        if let hr = run.avg_hr, hr > 0 {
                            Label("\(Int(hr)) bpm", systemImage: "heart")
                        }
                        if let v = run.effortVDOT {
                            Label(String(format: "%.1f", v), systemImage: "bolt")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    RouteMapView(run: run, height: 150)
                    if let n = run.notes, !n.isEmpty {
                        Label(n, systemImage: "text.bubble")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .buttonStyle(.plain)
            .cardStyle()

            // M7: quick feedback on the latest run + the coach's reaction,
            // right on the card (no sheet, no navigation).
            feedbackCard(run)
            }
            .padding(.horizontal)
        }
    }

    private func feedbackCard(_ run: RunRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(run.effortRating == nil ? "HOW HARD WAS IT?" : "EFFORT")
                .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            EffortPicker(current: run.effortRating) { v in
                Task { await model.rateRunAndGetFeedback(run, effort: v) }
            }
            if let note = run.notes, !note.isEmpty {
                Label(note, systemImage: "text.bubble").font(.caption).foregroundStyle(.secondary)
            }

            // The coach reacts to this run ONLY after you've logged your effort.
            // The reaction is saved on the run (coach_note), not in the chat.
            if run.effortRating != nil {
                if model.coachOnRunBusy {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("Coach is looking at this run…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                } else if let note = run.coach_note, !note.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("COACH ON THIS RUN", systemImage: "figure.run.circle.fill")
                            .font(.caption2.weight(.bold)).foregroundStyle(Color.accentColor)
                        CoachProse(text: note, font: .subheadline).lineLimit(8)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: coach's tip for today (latest morning message)

    @ViewBuilder
    private var coachTipCard: some View {
        if let tip = model.messages.last(where: { $0.kind == "daily" && !$0.isAthlete })
            ?? model.coachMessage {
            Button { model.openChat() } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("COACH'S TIP", systemImage: "figure.run.circle.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2.bold()).foregroundStyle(.tertiary)
                    }
                    CoachProse(text: tip.content, font: .subheadline)
                        .lineLimit(5)
                }
            }
            .buttonStyle(.plain)
            .cardStyle()
            .padding(.horizontal)
        }
    }

    // MARK: personal stats — week / month / year, vs the previous period

    private enum StatsPeriod: String, CaseIterable, Identifiable {
        case week = "Week", month = "Month", year = "Year"
        var id: String { rawValue }
        var days: Int {
            switch self {
            case .week: return 7
            case .month: return 30
            case .year: return 365
            }
        }
    }

    @State private var statsPeriod: StatsPeriod = .month

    private var statsCard: some View {
        let cal = Calendar.current
        let now = Date.now
        let cutoff = cal.date(byAdding: .day, value: -statsPeriod.days, to: now)!
        let prevCutoff = cal.date(byAdding: .day, value: -2 * statsPeriod.days, to: now)!
        let recent = model.runs.filter { $0.startDate >= cutoff }
        let previous = model.runs.filter { $0.startDate >= prevCutoff && $0.startDate < cutoff }

        let km = recent.reduce(0) { $0 + $1.distanceKm }
        let prevKm = previous.reduce(0) { $0 + $1.distanceKm }
        let seconds = recent.reduce(0) { $0 + $1.duration_s }
        let pace: String = km > 0 ? {
            let spk = seconds / km
            return String(format: "%d:%02d /km", Int(spk) / 60, Int(spk) % 60)
        }() : "–"
        let hours = seconds / 3600

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("YOUR NUMBERS")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $statsPeriod) {
                    ForEach(StatsPeriod.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                statTile(String(format: "%.1f", km), "kilometres", "point.topleft.down.curvedto.point.bottomright.up")
                statTile("\(recent.count)", "runs", "figure.run")
                statTile(String(format: "%.1f h", hours), "on feet", "stopwatch")
                statTile(pace, "avg pace", "speedometer")
            }
            if prevKm > 0 || km > 0 {
                comparisonLine(km: km, prevKm: prevKm)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .padding(.horizontal)
    }

    @ViewBuilder
    private func comparisonLine(km: Double, prevKm: Double) -> some View {
        let label = "previous \(statsPeriod.rawValue.lowercased())"
        if prevKm == 0 {
            Label(String(format: "%.1f km vs nothing the %@", km, label),
                  systemImage: "arrow.up.right")
                .font(.caption).foregroundStyle(.green)
        } else {
            let delta = (km - prevKm) / prevKm * 100
            Label(String(format: "%+.0f%% vs %@ (%.1f km)", delta, label, prevKm),
                  systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.caption)
                .foregroundStyle(delta >= 0 ? .green : .orange)
        }
    }

    private func statTile(_ value: String, _ label: String, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.title3.weight(.heavy).monospacedDigit())
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
