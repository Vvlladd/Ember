import Foundation
import Testing
@testable import FoundationChatKit

struct RetrievalEvalTests {
    /// Deterministic harness sanity on MockEmbedder: shared-vocabulary cases must recall; the
    /// harness itself (snapshot building, roles, production thresholds) is what's under test.
    @Test func harnessRecallsKeywordCaseOnMock() {
        let cases = RetrievalEval.fixtures.filter { $0.name.hasPrefix("keyword") }
        let result = RetrievalEval.recallAtK(cases: cases, embedder: MockEmbedder(vocabulary:
            ["favorite", "color", "teal", "lattes", "runs"]), k: 4)
        #expect(result.recall == 1.0)
    }

    // MARK: - Real-model ship gate (runs only where the dev weights exist)

    static var gemma: GemmaTextEmbedder? {
        guard let dir = ProcessInfo.processInfo.environment["EMBER_GEMMA_MODEL_DIR"] else { return nil }
        let base = URL(fileURLWithPath: dir)
        return GemmaTextEmbedder(modelURL: base.appendingPathComponent("EmbeddingGemma.mlpackage"),
                                 tokenizerDirectory: base.appendingPathComponent("tokenizer"))
    }

    /// SHIP GATE (spec §6): EmbeddingGemma must beat NLEmbedding on fixture recall@4 without
    /// regressing keyword cases or firing on the negative case. If this fails, the default embedder
    /// stays NLEmbedding — do not merge a failing gate.
    @Test(.enabled(if: gemma != nil))
    func gemmaBeatsNLOnFixtures() async throws {
        let g = try #require(Self.gemma)
        try await Task.sleep(for: .seconds(15))   // async resource load; generous for CI-less dev runs
        let gemmaScore = RetrievalEval.recallAtK(cases: RetrievalEval.fixtures, embedder: g, k: 4)
        let nlScore = RetrievalEval.recallAtK(cases: RetrievalEval.fixtures,
                                              embedder: NLTextEmbedder(), k: 4)
        #expect(gemmaScore.recall > nlScore.recall)
        #expect(gemmaScore.negativesClean)
        let keyword = RetrievalEval.fixtures.filter { $0.name.hasPrefix("keyword") }
        #expect(RetrievalEval.recallAtK(cases: keyword, embedder: g, k: 4).recall == 1.0)
    }
}
