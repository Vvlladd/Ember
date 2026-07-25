import Foundation
import Testing
@testable import FoundationChatKit

struct RetrievalEvalTests {
    /// Deterministic harness sanity on MockEmbedder: shared-vocabulary cases must recall; the
    /// harness itself (snapshot building, roles, production thresholds) is what's under test.
    /// Vocabulary is widened beyond the original color/teal pair to cover the content words of
    /// all four keyword fixtures (pet/breed, blood/type, favorite/food) — MockEmbedder is a
    /// bag-of-words over exactly this list, so every keyword case needs its shared words present
    /// for cosine similarity to contribute (lexical overlap alone sits under the 0.35 threshold).
    @Test func harnessRecallsKeywordCaseOnMock() {
        let cases = RetrievalEval.fixtures.filter { $0.name.hasPrefix("keyword") }
        let result = RetrievalEval.recallAtK(cases: cases, embedder: MockEmbedder(vocabulary:
            ["favorite", "color", "teal", "lattes", "runs", "pet", "breed", "blood", "type", "food"]), k: 4)
        #expect(result.recall == 1.0)
    }

    // MARK: - Real-model ship gate (runs only where the dev weights exist)

    /// Stored, not computed: a computed property would construct a SECOND embedder (and a second
    /// Core ML load) for the `.enabled(if:)` check alone.
    static let gemma: GemmaTextEmbedder? = {
        guard let dir = ProcessInfo.processInfo.environment["EMBER_GEMMA_MODEL_DIR"] else { return nil }
        let base = URL(fileURLWithPath: dir)
        return GemmaTextEmbedder(modelURL: base.appendingPathComponent("EmbeddingGemma.mlpackage"),
                                 tokenizerDirectory: base.appendingPathComponent("tokenizer"))
    }()

    /// SHIP GATE (spec §6): EmbeddingGemma must beat NLEmbedding on fixture recall@4 without
    /// regressing keyword cases or firing on the negative case. If this fails, the default embedder
    /// stays NLEmbedding — do not merge a failing gate.
    @Test(.enabled(if: gemma != nil))
    func gemmaBeatsNLOnFixtures() async throws {
        let g = try #require(Self.gemma)
        // Resources load asynchronously; poll the public embed() surface rather than sleeping a
        // fixed duration — a fixed sleep can false-FAIL on a slow disk/first-run compile, and
        // proceeding into the comparison with a still-nil-embedding Gemma would silently degrade
        // it to lexical-only and produce a misleading verdict, not an honest failure.
        var ready = false
        for _ in 0..<90 {
            if g.embed("warmup", role: .document) != nil { ready = true; break }
            try await Task.sleep(for: .seconds(1))
        }
        try #require(ready, "GemmaTextEmbedder never became ready within 90s — cannot evaluate ship gate")
        let gemmaScore = RetrievalEval.recallAtK(cases: RetrievalEval.fixtures, embedder: g, k: 4)
        let nlScore = RetrievalEval.recallAtK(cases: RetrievalEval.fixtures,
                                              embedder: NLTextEmbedder(), k: 4)
        #expect(gemmaScore.recall > nlScore.recall)
        #expect(gemmaScore.recall >= 0.75,
                "Gemma must clear an absolute recall floor, not merely beat a weak baseline")
        #expect(gemmaScore.negativesClean)
        let keyword = RetrievalEval.fixtures.filter { $0.name.hasPrefix("keyword") }
        #expect(RetrievalEval.recallAtK(cases: keyword, embedder: g, k: 4).recall == 1.0)
    }
}
