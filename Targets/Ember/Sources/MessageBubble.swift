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
            row(trailing: true, background: Color.accentColor.opacity(0.18))
        case .assistant:
            row(trailing: false, background: Color.secondary.opacity(0.12))
        }
    }

    private func row(trailing: Bool, background: Color) -> some View {
        HStack {
            if trailing { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 6) {
                Text(.init(message.text.isEmpty ? "…" : message.text))
                    .textSelection(.enabled)
                if message.isStreaming {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(10)
            .background(background, in: RoundedRectangle(cornerRadius: 14))
            if !trailing { Spacer(minLength: 48) }
        }
    }
}
