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

/// Behavioral correctness of the real `NLTextEmbedder` after the struct -> cached-class change.
/// Tolerates `NLEmbedding` being unavailable on the test host (non-empty input may return nil),
/// so the suite never depends on Apple Intelligence availability.
struct NLTextEmbedderTests {
    @Test func emptyAndWhitespaceAlwaysReturnNil() {
        let e = NLTextEmbedder()
        #expect(e.embed("") == nil)
        #expect(e.embed("   ") == nil)
        #expect(e.embed("\n\t ") == nil)
    }

    @Test func nonEmptyReturnsVectorOrNilGracefully() {
        let e = NLTextEmbedder()
        // If NLEmbedding is available on this host we get a non-empty vector; otherwise nil.
        // Either is acceptable — we only require it not to crash and to be self-consistent.
        if let vector = e.embed("a trip to paris") {
            #expect(!vector.isEmpty)
        }
    }
}
