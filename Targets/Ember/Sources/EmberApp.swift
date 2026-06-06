import SwiftUI
import SwiftData
import FoundationChatKit

@main
struct EmberApp: App {
    @State private var coordinator: ChatCoordinator

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Conversation.self, Message.self, MemoryNote.self)
        } catch {
            fatalError("Could not create the Ember data store: \(error)")
        }
        let context = ModelContext(container)
        let store = ConversationStore(context: context)
        let memory = MemoryStore(context: context, embedder: NLTextEmbedder())
        _coordinator = State(initialValue: ChatCoordinator(provider: FoundationModelProvider(),
                                                           store: store, memory: memory))
    }

    var body: some Scene {
        WindowGroup {
            RootView(coordinator: coordinator)
        }
    }
}
