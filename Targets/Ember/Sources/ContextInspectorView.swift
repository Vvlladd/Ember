import SwiftUI
import FoundationChatKit

struct ContextInspectorView: View {
    let entries: [ContextEntry]

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView("Empty Context", systemImage: "tray",
                description: Text("This shows exactly what the model sees. Send a message to populate it."))
        } else {
            List(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(label(entry.kind))
                            .font(.caption.bold())
                            .foregroundStyle(color(entry.kind))
                        if !entry.isInWindow {
                            Text("out of window")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(entry.text)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func label(_ k: ContextEntryKind) -> String {
        switch k {
        case .instructions: "INSTRUCTIONS"
        case .userPrompt: "USER"
        case .modelResponse: "ASSISTANT"
        case .toolCall: "TOOL CALL"
        case .toolOutput: "TOOL OUTPUT"
        }
    }
    private func color(_ k: ContextEntryKind) -> Color {
        switch k {
        case .instructions: .purple
        case .userPrompt: .blue
        case .modelResponse: .green
        case .toolCall, .toolOutput: .orange
        }
    }
}
