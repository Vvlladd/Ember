import SwiftUI
import SwiftData
import FoundationChatKit
import os

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
    /// it decides which vector space `embedderID` tags for this run, so a silent fallback would
    /// look identical to a working Gemma run until retrieval quality quietly differed.
    private static func makeEmbedder() -> any TextEmbedder {
        let bundle = Bundle.main
        // Verified layout (see Project.swift): Xcode compiles the .mlpackage into
        // `EmbeddingGemma.mlmodelc` at the resources ROOT, and `tokenizer/` is copied as a folder
        // reference alongside it. The `Models` subdirectory lookups are a cheap secondary probe in
        // case a future bundling change nests them instead; `.mlpackage` covers it being copied
        // uncompiled (GemmaTextEmbedder compiles at runtime when handed one).
        let model = bundle.url(forResource: "EmbeddingGemma", withExtension: "mlmodelc")
            ?? bundle.url(forResource: "EmbeddingGemma", withExtension: "mlmodelc", subdirectory: "Models")
            ?? bundle.url(forResource: "EmbeddingGemma", withExtension: "mlpackage")
            ?? bundle.url(forResource: "EmbeddingGemma", withExtension: "mlpackage", subdirectory: "Models")
        let tokenizer = bundle.url(forResource: "tokenizer", withExtension: nil)
            ?? bundle.url(forResource: "tokenizer", withExtension: nil, subdirectory: "Models")

        guard let model, let tokenizer else {
            let missing = [model == nil ? "EmbeddingGemma.mlmodelc/.mlpackage" : nil,
                           tokenizer == nil ? "tokenizer/" : nil].compactMap { $0 }.joined(separator: " + ")
            EmberLog.embed.notice("makeEmbedder: NLEmbedding fallback — not bundled: \(missing, privacy: .public)")
            return NLTextEmbedder()
        }
        guard let gemma = GemmaTextEmbedder(modelURL: model, tokenizerDirectory: tokenizer) else {
            EmberLog.embed.error("makeEmbedder: NLEmbedding fallback — GemmaTextEmbedder init failed for \(model.lastPathComponent, privacy: .public)")
            return NLTextEmbedder()
        }
        EmberLog.embed.info("makeEmbedder: EmbeddingGemma chosen (\(model.lastPathComponent, privacy: .public))")
        return gemma
    }
}
