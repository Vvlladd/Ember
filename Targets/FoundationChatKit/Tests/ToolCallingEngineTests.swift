import Testing
import Foundation
@testable import FoundationChatKit

@MainActor
struct ToolCallingEngineTests {
    @Test func providerReceivesTools() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["ok"]
        let tools = Toolbox.defaultTools()
        let engine = ConversationEngine(provider: provider, tools: tools,
                                        now: { Date(timeIntervalSince1970: 0) })
        _ = engine
        #expect(provider.recordedTools.map(\.name) == tools.map(\.name))
    }

    @Test func surfacesScriptedToolCallAndOutputInOrder() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["42"]
        provider.session.scriptedToolInteractions = [(call: "calculator({\"expression\":\"6*7\"})", output: "42")]
        let engine = ConversationEngine(provider: provider, tools: Toolbox.defaultTools(),
                                        now: { Date(timeIntervalSince1970: 0) })
        await engine.send("what is 6*7")
        let kinds = engine.contextEntries.map(\.kind)
        #expect(kinds == [.userPrompt, .toolCall, .toolOutput, .modelResponse])
    }

    @Test func budgetIncludesToolLines() async {
        let provider = MockModelProvider()
        provider.session.scriptedSnapshots = ["ok"]
        let engine = ConversationEngine(provider: provider, tools: Toolbox.defaultTools(),
                                        now: { Date(timeIntervalSince1970: 0) })
        await engine.send("hi")
        #expect(engine.budget.lines.contains { $0.label.hasPrefix("Tool: ") })
    }
}
