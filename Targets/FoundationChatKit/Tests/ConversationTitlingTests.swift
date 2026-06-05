import Testing
import Foundation
@testable import FoundationChatKit

@MainActor
struct ConversationTitlingTests {
    @Test func mockProviderReturnsScriptedTitle() async {
        let provider = MockModelProvider()
        provider.titleResult = "Weekend Trip Planning"
        let title = await provider.generateTitle(
            forFirstExchange: TitleSeed(userText: "help me plan a trip", assistantText: "Sure!"))
        #expect(title == "Weekend Trip Planning")
    }
    @Test func mockProviderNilByDefault() async {
        let provider = MockModelProvider()
        let title = await provider.generateTitle(
            forFirstExchange: TitleSeed(userText: "hi", assistantText: "hello"))
        #expect(title == nil)
    }
}
