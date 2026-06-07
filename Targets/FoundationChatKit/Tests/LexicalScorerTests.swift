import Testing
@testable import FoundationChatKit

@Suite struct LexicalScorerTests {
    @Test func identicalTextScoresHigh() {
        let s = LexicalScorer.score(query: "trip to Lisbon", text: "trip to Lisbon")
        #expect(s > 0.9)
    }

    @Test func noOverlapScoresZero() {
        let s = LexicalScorer.score(query: "quantum physics", text: "banana smoothie recipe")
        #expect(s == 0)
    }

    @Test func partialOverlapScoresBetween() {
        let s = LexicalScorer.score(query: "what should I pack for Lisbon",
                                    text: "planning a Lisbon trip")
        #expect(s > 0)
        #expect(s < 1)
    }

    @Test func stopwordsAreIgnored() {
        // "the","a","to","of" must not inflate the score; both sides reduce to {trip, city}.
        let withStops = LexicalScorer.score(query: "the trip to the city",
                                            text: "a trip of a city")
        let bare = LexicalScorer.score(query: "trip city", text: "trip city")
        #expect(withStops == bare)
    }

    @Test func caseInsensitive() {
        #expect(LexicalScorer.score(query: "LISBON Trip", text: "lisbon TRIP") > 0.9)
    }

    @Test func deterministicAcrossCalls() {
        let a = LexicalScorer.score(query: "user likes hiking", text: "the user enjoys hiking trips")
        let b = LexicalScorer.score(query: "user likes hiking", text: "the user enjoys hiking trips")
        #expect(a == b)
    }

    @Test func emptyInputsScoreZero() {
        #expect(LexicalScorer.score(query: "", text: "anything") == 0)
        #expect(LexicalScorer.score(query: "anything", text: "") == 0)
    }

    @Test func punctuationAndPluralsToleratedRoughly() {
        let s = LexicalScorer.score(query: "Lisbon!", text: "Lisbon, Portugal")
        #expect(s > 0)
    }
}
