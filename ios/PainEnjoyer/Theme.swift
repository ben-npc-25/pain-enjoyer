import SwiftUI
import MapKit
import CoreLocation

// M6 design pass: bright, high-contrast, readable.

/// GPS route map for a run — compact (home card) or interactive (detail).
/// Fetches the HKWorkoutRoute itself; collapses to nothing (or `emptyText`)
/// when the source app wrote no route.
struct RouteMapView: View {
    let run: RunRecord
    var height: CGFloat = 170
    var interactive: Bool = false
    var emptyText: String? = nil

    @State private var route: [CLLocationCoordinate2D] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if route.count > 1 {
                Map {
                    MapPolyline(coordinates: route)
                        .stroke(Color.accentColor,
                                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    if let first = route.first {
                        Annotation("", coordinate: first) { endpoint(.green) }
                    }
                    if let last = route.last {
                        Annotation("", coordinate: last) { endpoint(.red) }
                    }
                }
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .allowsHitTesting(interactive)
            } else if loaded {
                if let emptyText {
                    HStack {
                        Image(systemName: "map")
                        Text(emptyText).font(.subheadline)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                }
                // no emptyText → collapse quietly (home card)
            } else if interactive {
                HStack { ProgressView(); Text("Loading route…")
                        .font(.subheadline).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity)
            }
        }
        .task(id: run.id) {
            route = await HealthKitService.shared.fetchRoute(workoutUUID: run.healthkit_uuid ?? "")
            loaded = true
        }
    }

    private func endpoint(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 11, height: 11)
            .overlay(Circle().stroke(.white, lineWidth: 2))
    }
}

/// Renders coach/LLM prose properly. SwiftUI's Text only parses Markdown in
/// string LITERALS — a String variable shows `**bold**` as raw asterisks,
/// which is exactly why coach messages were hard to read. inlineOnly…
/// keeps the LLM's line breaks (full parsing would collapse paragraphs).
struct CoachProse: View {
    let text: String
    var font: Font = .body

    var body: some View {
        Text(attributed)
            .font(font)
            .lineSpacing(3.5)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                           failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(text)
    }
}

/// White card on the grouped-gray canvas — soft shadow, no borders.
struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.07), radius: 10, y: 3)
            )
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardStyle()) }
}

/// The wordmark: gradient runner + rounded heavy type, replaces the plain
/// navigation title on the home tab.
struct Wordmark: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "figure.run")
                .font(.system(size: 19, weight: .heavy))
            Text("Pain Enjoyer")
                .font(.system(.title3, design: .rounded).weight(.heavy))
        }
        .foregroundStyle(
            LinearGradient(colors: [Color.accentColor, .cyan],
                           startPoint: .leading, endPoint: .trailing)
        )
    }
}

/// Run-type chip — auto-classified from pace vs the engine's VDOT zones.
struct RunTypeChip: View {
    let type: RunClass

    var body: some View {
        Text(type.label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(type.color.opacity(0.16)))
            .foregroundStyle(type.color)
    }
}

/// M8: chip for cross-training activities ("Hike", "Ride", …) — pace-vs-zone
/// classification would be nonsense there.
struct ActivityChip: View {
    let run: RunRecord

    var body: some View {
        Text(run.activityLabel)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(Color.secondary.opacity(0.16)))
            .foregroundStyle(.secondary)
    }
}
