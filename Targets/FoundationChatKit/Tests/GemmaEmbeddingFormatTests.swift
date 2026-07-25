import Foundation
import Testing
@testable import FoundationChatKit

struct GemmaEmbeddingFormatTests {
    @Test func documentPrompt() {
        #expect(GemmaEmbeddingFormat.prompt("I moved to Lisbon", role: .document)
                == "title: none | text: I moved to Lisbon")
    }

    @Test func queryPrompt() {
        #expect(GemmaEmbeddingFormat.prompt("where do I live", role: .query)
                == "task: search result | query: where do I live")
    }

    @Test func truncateKeepsPrefixAndRenormalizes() {
        let v: [Float] = [3, 4, 100, 100]           // untruncated norm dominated by the tail
        let out = GemmaEmbeddingFormat.truncateAndNormalize(v, to: 2)
        #expect(out.count == 2)
        #expect(abs(out[0] - 0.6) < 1e-5)           // 3/5
        #expect(abs(out[1] - 0.8) < 1e-5)           // 4/5
    }

    @Test func zeroVectorDoesNotDivideByZero() {
        #expect(GemmaEmbeddingFormat.truncateAndNormalize([0, 0, 0], to: 2) == [0, 0])
    }
}
