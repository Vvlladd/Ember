import SwiftUI
import FoundationChatKit

struct ChatScene: View {
    let coordinator: ChatCoordinator
    @State private var showInspector = false

    var body: some View {
        NavigationSplitView {
            ConversationListView(coordinator: coordinator)
        } detail: {
            Group {
                if let engine = coordinator.engine {
                    ChatView(engine: engine, coordinator: coordinator)
                } else {
                    ContentUnavailableView("No Conversation",
                                           systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Select a chat or start a new one."))
                }
            }
            .toolbar {
                if let engine = coordinator.engine {
                    ToolbarItem(placement: .principal) {
                        TokenGaugeView(budget: engine.budget)
                    }
                    ToolbarItem {
                        Button { showInspector.toggle() } label: {
                            Image(systemName: "sidebar.trailing")
                        }
                        .help("Show context & tokens")
                    }
                }
            }
            .inspector(isPresented: $showInspector) {
                if let engine = coordinator.engine {
                    InspectorPanel(engine: engine)
                } else {
                    Text("No conversation").foregroundStyle(.secondary)
                }
            }
        }
    }
}
