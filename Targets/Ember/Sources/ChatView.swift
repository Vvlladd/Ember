import SwiftUI
import FoundationChatKit

struct ChatView: View {
    let engine: ConversationEngine
    let coordinator: ChatCoordinator

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(engine.messages) { message in
                            MessageBubble(message: message).id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: engine.messages.last?.text) {
                    if let last = engine.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            if let error = engine.lastError {
                ErrorBanner(error: error)
            }
            Divider()
            ComposerView(engine: engine, coordinator: coordinator)
        }
    }
}
