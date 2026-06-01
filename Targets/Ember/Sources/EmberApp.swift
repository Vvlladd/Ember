import SwiftUI
import SwiftData
import FoundationChatKit

@main
struct EmberApp: App {
    @State private var coordinator: ChatCoordinator

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Conversation.self, Message.self)
        } catch {
            fatalError("Could not create the Ember data store: \(error)")
        }
        let store = ConversationStore(context: ModelContext(container))
        _coordinator = State(initialValue: ChatCoordinator(provider: FoundationModelProvider(), store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView(coordinator: coordinator)
        }
    }
}
