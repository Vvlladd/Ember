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
        let memory = MemoryStore(context: context, embedder: Self.makeEmbedder())
        _coordinator = State(initialValue: ChatCoordinator(provider: FoundationModelProvider(),
                                                           store: store, memory: memory))
    }

    var body: some Scene {
        WindowGroup {
            RootView(coordinator: coordinator)
        }
    }

    /// EmbeddingGemma when its bundled resources exist (they are gitignored dev assets, so
    /// contributor and CI builds simply lack them); NLEmbedding otherwise. The choice is logged —
    /// it decides which vector space `embedderID` tags for this run.
    private static func makeEmbedder() -> any TextEmbedder {
        let bundle = Bundle.main
        let model = bundle.url(forResource: "EmbeddingGemma", withExtension: "mlmodelc")
            ?? bundle.url(forResource: "EmbeddingGemma", withExtension: "mlpackage")
        let tokenizer = bundle.url(forResource: "tokenizer", withExtension: nil)
        if let model, let tokenizer,
           let gemma = GemmaTextEmbedder(modelURL: model, tokenizerDirectory: tokenizer) {
            return gemma
        }
        return NLTextEmbedder()
    }
}
