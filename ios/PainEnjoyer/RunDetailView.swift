import SwiftUI
import MapKit

/// M6: a run, full size — type chip, big stats, the GPS route when the
/// source app wrote one, and the athlete's note.
struct RunDetailView: View {
    let run: RunRecord
    let zones: [String: Double]?
    let onSaveNotes: (RunRecord, String) -> Void
    var onSaveEffort: ((RunRecord, Int) -> Void)? = nil // M7 Phase 1

    @State private var noteDraft: String?
    @State private var effortDraft: Int?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                statsGrid
                mapCard
                effortCard
                notesCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(run.startDate.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if run.isRun {
                    RunTypeChip(type: run.runClass(zones: zones))
                } else {
                    ActivityChip(run: run) // M8: hikes/rides sync too
                }
                Spacer()
                Text(run.source_app ?? "").font(.caption).foregroundStyle(.tertiary)
            }
            Text(String(format: "%.2f km", run.distanceKm))
                .font(.system(size: 44, weight: .heavy, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var statsGrid: some View {
        HStack(spacing: 0) {
            stat("Time", run.durationString)
            stat("Pace", run.paceString)
            if let hr = run.avg_hr, hr > 0 { stat("Avg HR", "\(Int(hr)) bpm") }
            if let v = run.effortVDOT { stat("Effort", String(format: "%.1f", v)) }
            if let e = run.elevation_gain_m, e > 0 { stat("Climb", "\(Int(e)) m") }
        }
        .cardStyle()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity)
    }

    private var mapCard: some View {
        RouteMapView(run: run, height: 260, interactive: true,
                     emptyText: run.source_app == "manual"
                        ? "Manual entry — no GPS route."
                        : "No GPS route in Health for this run.")
            .cardStyle()
    }

    // M7 Phase 1: perceived effort — the one field HealthKit can't capture.
    // The coach's reaction is saved on the run (coach_note), shown here too.
    private var effortCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How hard was it?").font(.headline)
            EffortPicker(current: effortDraft ?? run.effortRating) { v in
                effortDraft = v
                onSaveEffort?(run, v)
            }
            if let note = run.coach_note, !note.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Coach on this run", systemImage: "figure.run.circle.fill")
                        .font(.caption.weight(.bold)).foregroundStyle(Color.accentColor)
                    Text(note).font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes for the coach").font(.headline)
            TextField("Anything to note for the coach?", text: Binding(
                get: { noteDraft ?? run.notes ?? "" },
                set: { noteDraft = $0 }
            ), axis: .vertical)
            .lineLimit(2...5)
            .textFieldStyle(.roundedBorder)
            if let draft = noteDraft, draft != (run.notes ?? "") {
                Button("Save note") { onSaveNotes(run, draft) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

/// M7 Phase 1: a 5-segment perceived-effort rating (1 very easy … 5 max).
/// Presentational — the parent owns the selected value and persists on pick.
struct EffortPicker: View {
    let current: Int?
    let onPick: (Int) -> Void

    private static let labels = ["Very easy", "Easy", "Moderate", "Hard", "Max"]
    private static let colors: [Color] = [.mint, .green, .yellow, .orange, .red]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(1...5, id: \.self) { v in
                let on = current == v
                Button { onPick(v) } label: {
                    VStack(spacing: 4) {
                        Text("\(v)").font(.headline.monospacedDigit())
                        Text(Self.labels[v - 1]).font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(on ? Self.colors[v - 1].opacity(0.30)
                                     : Color(.tertiarySystemFill))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(on ? Self.colors[v - 1] : .clear, lineWidth: 2)
                    )
                    .foregroundStyle(on ? .primary : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
