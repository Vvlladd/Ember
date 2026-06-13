import SwiftUI
import FoundationChatKit

struct ComposerView: View {
    let engine: ConversationEngine
    let coordinator: ChatCoordinator
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Ember", text: $draft, axis: .vertical)
                .font(.callout)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .onSubmit(send)
                .disabled(engine.isResponding || coordinator.isProcessing)
                .padding(.vertical, 9)
                .padding(.leading, 13)
                .padding(.trailing, 2)

            actionButton
        }
        .padding(5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.separator.opacity(0.22), lineWidth: 0.5)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(.clear)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !coordinator.isProcessing
    }

    @ViewBuilder
    private var actionButton: some View {
        if engine.isResponding {
            styledActionButton(
                role: .destructive,
                systemName: "stop.fill",
                tint: .red,
                help: "Stop",
                accessibilityLabel: "Stop response",
                action: engine.cancel
            )
        } else {
            styledActionButton(
                systemName: "arrow.up",
                tint: .accentColor,
                help: "Send",
                accessibilityLabel: "Send message",
                action: send
            )
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private func styledActionButton(role: ButtonRole? = nil,
                                    systemName: String,
                                    tint: Color,
                                    help: String,
                                    accessibilityLabel: String,
                                    action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .tint(tint)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task { await coordinator.send(text) }
    }
}
