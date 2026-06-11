import SwiftUI

// M6 design pass: bright, high-contrast, readable.

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
