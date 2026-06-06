import Foundation
import FoundationModels

/// A tool the model calls to recall relevant context from past conversations. Pure and Sendable:
/// it searches an immutable snapshot handed in at construction, so it needs no actor hop.
public struct MemorySearchTool: Tool {
    public let name = "searchMemory"
    public let description = "Search the user's past conversations for context relevant to the query."

    @Generable
    public struct Arguments {
        @Guide(description: "What to recall, as a short search query")
        public var query: String
        public init(query: String) { self.query = query }
    }

    private let embedder: any TextEmbedder
    private let snapshot: [MemoryRecord]
    private let excludedIDs: Set<UUID>

    public init(embedder: any TextEmbedder, snapshot: [MemoryRecord], excludedIDs: Set<UUID> = []) {
        self.embedder = embedder
        self.snapshot = snapshot
        self.excludedIDs = excludedIDs
    }

    public func call(arguments: Arguments) async throws -> String {
        guard let queryVector = embedder.embed(arguments.query) else {
            return "No relevant earlier context found."
        }
        let hits = MemoryStore.search(snapshot, queryVector: queryVector, excludingMessageIDs: excludedIDs)
        guard !hits.isEmpty else { return "No relevant earlier context found." }
        return hits.map { MemoryContextBlock.formatHit($0) }.joined(separator: "\n")
    }
}
