import Testing
@testable import FoundationChatKit

struct MockEmbedderTests {
    @Test func overlappingScoresHigherThanUnrelated() {
        let e = MockEmbedder()
        let q = e.embed("planning a trip to paris")!
        let related = e.embed("paris trip ideas")!
        let unrelated = e.embed("debugging swift code")!
        #expect(Vector.cosineSimilarity(q, related) > Vector.cosineSimilarity(q, unrelated))
    }
    @Test func noKnownWordsIsNil() { #expect(MockEmbedder().embed("zzz qqq") == nil) }
}
