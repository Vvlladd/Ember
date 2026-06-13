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

    @Test func conversationTitleClampsToFiveWords() {
        let long = "A Very Long Title That Goes On And On Forever"
        #expect(ConversationTitler.clampTitle(long) == "A Very Long Title That")
    }

    @Test func conversationTitleTrimsAndKeepsShortTitles() {
        #expect(ConversationTitler.clampTitle("  Lisbon Trip Plans  ") == "Lisbon Trip Plans")
    }

    @Test func conversationTitleEmptyStaysEmpty() {
        #expect(ConversationTitler.clampTitle("   ") == "")
    }
}
