import Testing
import Foundation
@testable import FoundationChatKit

@MainActor
struct MemorySearchToolTests {
    private func snapshot() -> [MemoryRecord] {
        let e = MockEmbedder()
        return [
            MemoryRecord(messageID: UUID(), conversationID: UUID(), conversationTitle: "Trip",
                         role: .user, text: "trip to paris", vector: e.embed("trip to paris")!),
            MemoryRecord(messageID: UUID(), conversationID: UUID(), conversationTitle: "Code",
                         role: .assistant, text: "debugging swift code", vector: e.embed("debugging swift code")!),
        ]
    }
    @Test func returnsRankedSnippet() async throws {
        let tool = MemorySearchTool(embedder: MockEmbedder(), snapshot: snapshot())
        let result = try await tool.call(arguments: .init(query: "paris trip"))
        #expect(result.contains("trip to paris"))
        #expect(result.contains("Trip"))
    }
    @Test func noMatchReturnsFallback() async throws {
        let tool = MemorySearchTool(embedder: MockEmbedder(), snapshot: snapshot())
        let result = try await tool.call(arguments: .init(query: "music dog weather"))
        #expect(result == "No relevant earlier context found.")
    }
    @Test func excludedNotReturned() async throws {
        let snap = snapshot()
        let tool = MemorySearchTool(embedder: MockEmbedder(), snapshot: snap,
                                    excludedIDs: Set([snap[0].messageID]))
        let result = try await tool.call(arguments: .init(query: "paris trip"))
        #expect(!result.contains("trip to paris"))
    }
}
