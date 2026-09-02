import SwiftUI
import FoundationChatKit
import EmberScope

struct ChatScene: View {
    let coordinator: ChatCoordinator
    @State private var showInspector = false
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

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
                #if DEBUG
                ToolbarItem {
                    Button { openScope() } label: { Image(systemName: "waveform.path.ecg") }
                        .help("Ember Scope — sessions, tools, tokens and errors of the on-device model")
                }
                #endif
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

    private func openScope() {
        #if os(macOS)
        openWindow(id: emberScopeWindowID)
        #else
        EmberScope.present()
        #endif
    }
}
