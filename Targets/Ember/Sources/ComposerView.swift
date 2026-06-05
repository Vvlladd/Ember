import SwiftUI
import FoundationChatKit

struct ComposerView: View {
    let engine: ConversationEngine
    let coordinator: ChatCoordinator
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Ember…", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
                .disabled(engine.isResponding || coordinator.isProcessing)
            if engine.isResponding {
                Button(role: .destructive, action: engine.cancel) {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .help("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coordinator.isProcessing)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding()
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task { await coordinator.send(text) }
    }
}
