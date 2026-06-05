import Testing
import Foundation
@testable import FoundationChatKit

@MainActor
struct ContextCompactorTests {
    private func entries(_ n: Int) -> [ContextEntry] {
        (0..<n).map { ContextEntry(kind: $0 % 2 == 0 ? .userPrompt : .modelResponse, text: "msg\($0)") }
    }
    @Test func summarizesOlderKeepsRecent() async {
        let p = MockModelProvider(); p.summarizeResult = "RECAP"
        let result = await ContextCompactor.compact(entries(10), keepingRecent: 4, using: p)
        #expect(result.count == 5)                       // 1 recap + 4 recent
        #expect(result.first?.kind == .instructions)
        #expect(result.first?.text.contains("RECAP") == true)
        #expect(result.last?.text == "msg9")
    }
    @Test func fallsBackToCondenseWhenSummaryNil() async {
        let p = MockModelProvider(); p.summarizeResult = nil
        let input = entries(10)
        let result = await ContextCompactor.compact(input, keepingRecent: 4, using: p)
        #expect(result == OverflowRecovery.condense(input))
    }
    @Test func shortInputUnchanged() async {
        let p = MockModelProvider(); p.summarizeResult = "RECAP"
        let input = entries(3)
        #expect(await ContextCompactor.compact(input, keepingRecent: 4, using: p) == input)
    }
}
