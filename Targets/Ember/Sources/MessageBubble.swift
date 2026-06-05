import SwiftUI
import FoundationChatKit

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .systemNotice:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        case .user:
            row(trailing: true, background: Color.accentColor.opacity(0.18)) {
                Text(message.text.isEmpty ? "…" : message.text).textSelection(.enabled)
            }
        case .assistant:
            row(trailing: false, background: Color.secondary.opacity(0.12)) {
                if message.text.isEmpty { Text("…") } else { MarkdownText(text: message.text) }
            }
        }
    }

    private func row<Content: View>(trailing: Bool, background: Color,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack {
            if trailing { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 6) {
                content()
                if message.isStreaming { ProgressView().controlSize(.small) }
            }
            .padding(10)
            .background(background, in: RoundedRectangle(cornerRadius: 14))
            if !trailing { Spacer(minLength: 48) }
        }
    }
}
