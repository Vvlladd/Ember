import Foundation
import FoundationModels

/// A tool the model calls to deliberately persist a curated fact about the user. Pure and Sendable:
/// it only appends to a `MemoryWriteBuffer`; the coordinator drains and persists after the turn so
/// the fact becomes retrievable (auto-RAG + searchMemory) in future conversations.
public struct SaveMemoryTool: Tool {
    public let name = "saveMemory"
    public let description = "Remember an important fact about the user for future conversations."

    @Generable
    public struct Arguments {
        @Guide(description: "The fact to remember, as one short sentence")
        public var fact: String
        public init(fact: String) { self.fact = fact }
    }

    private let buffer: MemoryWriteBuffer
    public init(buffer: MemoryWriteBuffer) { self.buffer = buffer }

    public func call(arguments: Arguments) async throws -> String {
        await buffer.add(arguments.fact)
        return "Saved."
    }
}
