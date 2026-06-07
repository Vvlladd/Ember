import Testing
@testable import FoundationChatKit

@Suite struct ConversationSummaryTests {
    @Test func rendersAllSectionsWhenPresent() {
        let s = ConversationSummary(
            summary: "Discussed a December trip to Lisbon.",
            keyTopics: ["Lisbon", "packing"],
            userPreferences: ["User prefers boutique hotels"])
        let out = s.render()
        #expect(out.contains("Discussed a December trip to Lisbon."))
        #expect(out.contains("Lisbon"))
        #expect(out.contains("packing"))
        #expect(out.contains("User prefers boutique hotels"))
    }

    @Test func rendersSummaryOnlyWhenTopicsAndPrefsEmpty() {
        let s = ConversationSummary(summary: "Short chat.", keyTopics: [], userPreferences: [])
        #expect(s.render() == "Short chat.")
    }

    @Test func renderTrimsAndDropsEmptyEntries() {
        let s = ConversationSummary(
            summary: "  Trip talk.  ",
            keyTopics: ["Lisbon", "  ", ""],
            userPreferences: ["  "])
        let out = s.render()
        #expect(out.hasPrefix("Trip talk."))
        #expect(out.contains("Lisbon"))
        #expect(!out.contains("Preferences"))   // all prefs blank → section omitted
    }

    @Test func isEmptyWhenNothingMeaningful() {
        #expect(ConversationSummary(summary: "   ", keyTopics: [], userPreferences: []).isEmpty)
        #expect(!ConversationSummary(summary: "x", keyTopics: [], userPreferences: []).isEmpty)
    }
}
