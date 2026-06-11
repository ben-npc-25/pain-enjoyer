import SwiftUI

/// M4: what the coach believes about you — transparent and correctable.
/// Facts come from nightly chat distillation; swipe to delete anything wrong.
struct MemoryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.memory) { fact in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(fact.fact).font(.subheadline)
                        HStack(spacing: 8) {
                            ProgressView(value: min(max(fact.confidence ?? 0.5, 0), 1))
                                .tint(.accentColor)
                                .frame(width: 70)
                            Text(String(format: "%.0f%%", (fact.confidence ?? 0.5) * 100))
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            if let src = fact.learned_from, !src.isEmpty {
                                Text(src).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { offsets in
                    let facts = offsets.map { model.memory[$0] }
                    Task { for f in facts { await model.deleteMemory(f) } }
                }
            }
            .overlay {
                if model.memory.isEmpty {
                    ContentUnavailableView(
                        "Nothing remembered yet",
                        systemImage: "brain.head.profile",
                        description: Text("Chat with the coach — each night it distills durable facts from the conversation. Or tap Distill now.")
                    )
                }
            }
            .navigationTitle("Coach memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.distillNow() }
                    } label: {
                        Label("Distill now", systemImage: "sparkles")
                    }
                    .disabled(model.busy)
                }
            }
            .task { await model.loadMemory() }
        }
    }
}
