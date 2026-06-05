import Testing
import Foundation
@testable import FoundationChatKit

@MainActor
struct CancellationTests {
    @Test func cancellationMidStreamKeepsPartial() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["partial", "partial full"]
        provider.session.scriptedError = CancellationError()
        provider.session.errorAfter = 1
        let engine = ConversationEngine(provider: provider, now: { Date(timeIntervalSince1970: 0) })
        await engine.send("hi")
        #expect(engine.isResponding == false)
        #expect(engine.lastError == nil)
        let assistant = engine.messages.last(where: { $0.role == .assistant })
        #expect(assistant?.text == "partial")
        #expect(assistant?.isStreaming == false)
    }
}
