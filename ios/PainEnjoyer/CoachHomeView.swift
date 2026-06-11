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
                    latestActivityCard
                    monthStatsCard
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
            NavigationLink {
                RunDetailView(run: run, zones: model.zonesSec) { r, notes in
                    Task { await model.saveNotes(for: r, notes: notes) }
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
            .padding(.horizontal)
        }
    }

    // MARK: 30-day personal stats

    private var monthStatsCard: some View {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now)!
        let recent = model.runs.filter { $0.startDate >= cutoff }
        let km = recent.reduce(0) { $0 + $1.distanceKm }
        let seconds = recent.reduce(0) { $0 + $1.duration_s }
        let pace: String = km > 0 ? {
            let spk = seconds / km
            return String(format: "%d:%02d /km", Int(spk) / 60, Int(spk) % 60)
        }() : "–"
        let hours = seconds / 3600

        return VStack(alignment: .leading, spacing: 12) {
            Text("LAST 30 DAYS")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                statTile(String(format: "%.1f", km), "kilometres", "point.topleft.down.curvedto.point.bottomright.up")
                statTile("\(recent.count)", "runs", "figure.run")
                statTile(String(format: "%.1f h", hours), "on feet", "stopwatch")
                statTile(pace, "avg pace", "speedometer")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .padding(.horizontal)
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
