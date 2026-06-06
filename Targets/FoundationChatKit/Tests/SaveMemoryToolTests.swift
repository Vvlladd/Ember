import Testing
import Foundation
@testable import FoundationChatKit

struct SaveMemoryToolTests {
    @Test func callBuffersFactAndReturnsConfirmation() async throws {
        let buffer = MemoryWriteBuffer()
        let tool = SaveMemoryTool(buffer: buffer)
        let result = try await tool.call(arguments: .init(fact: "likes lisbon"))
        #expect(result == "Saved.")
        let drained = await buffer.drain()
        #expect(drained == ["likes lisbon"])
    }

    @Test func drainClearsBuffer() async throws {
        let buffer = MemoryWriteBuffer()
        await buffer.add("a")
        let first = await buffer.drain()
        #expect(first == ["a"])
        let second = await buffer.drain()
        #expect(second == [])
    }
}
