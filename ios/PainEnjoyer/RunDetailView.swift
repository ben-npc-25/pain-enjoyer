import SwiftUI
import MapKit

/// M6: a run, full size — type chip, big stats, the GPS route when the
/// source app wrote one, and the athlete's note.
struct RunDetailView: View {
    let run: RunRecord
    let zones: [String: Double]?
    let onSaveNotes: (RunRecord, String) -> Void

    @State private var route: [CLLocationCoordinate2D] = []
    @State private var routeLoaded = false
    @State private var noteDraft: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                statsGrid
                mapCard
                notesCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(run.startDate.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            route = await HealthKitService.shared.fetchRoute(workoutUUID: run.healthkit_uuid ?? "")
            routeLoaded = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                RunTypeChip(type: run.runClass(zones: zones))
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

    @ViewBuilder
    private var mapCard: some View {
        if route.count > 1 {
            Map {
                MapPolyline(coordinates: route)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                if let first = route.first {
                    Annotation("", coordinate: first) {
                        Circle().fill(.green).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
                if let last = route.last {
                    Annotation("", coordinate: last) {
                        Circle().fill(.red).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.07), radius: 10, y: 3)
        } else if routeLoaded {
            HStack {
                Image(systemName: "map")
                Text(run.source_app == "manual"
                     ? "Manual entry — no GPS route."
                     : "No GPS route in Health for this run.")
                    .font(.subheadline)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .cardStyle()
        } else {
            HStack { ProgressView(); Text("Loading route…").font(.subheadline).foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity)
                .cardStyle()
        }
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes for the coach").font(.headline)
            TextField("How did it feel?", text: Binding(
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
