import Foundation
@testable import FoundationChatKit

/// One golden retrieval case: for `query`, searching `corpus` must surface `expected` in the top k.
/// `expected == nil` means a NEGATIVE case: nothing in the corpus is relevant and no hit should
/// clear the production threshold.
struct RetrievalEvalCase: Sendable {
    let name: String
    let query: String
    let corpus: [String]
    let expected: String?
}

enum RetrievalEval {
    /// Fraction of non-negative cases whose expected text lands in the top `k` — plus a hard pass
    /// bool for negatives. Uses the PRODUCTION search path and defaults (hybrid, threshold 0.35,
    /// lexicalWeight 0.5) so numbers reflect real behavior.
    static func recallAtK(cases: [RetrievalEvalCase], embedder: any TextEmbedder, k: Int)
        -> (recall: Double, negativesClean: Bool) {
        var hits = 0, positives = 0, negativesClean = true
        for c in cases {
            let snapshot = c.corpus.enumerated().map { i, text in
                MemoryRecord(messageID: UUID(), conversationID: UUID(), conversationTitle: "eval",
                             role: .user, text: text,
                             vector: embedder.embed(text, role: .document) ?? [], source: .note)
            }
            let qv = embedder.embed(c.query, role: .query) ?? []
            let results = MemoryStore.search(snapshot, query: c.query, queryVector: qv,
                                             topK: k, threshold: 0.35, lexicalWeight: 0.5,
                                             preferNotes: true)
            if let expected = c.expected {
                positives += 1
                if results.contains(where: { $0.record.text == expected }) { hits += 1 }
            } else if !results.isEmpty {
                negativesClean = false
            }
        }
        return (positives == 0 ? 0 : Double(hits) / Double(positives), negativesClean)
    }

    /// Golden fixtures. The first two encode the documented NLEmbedding failures (lexical-miss and
    /// the question-vs-question trap from the Plan-9 device debugging); keyword cases guard against
    /// regressing what lexical overlap already handles.
    static let fixtures: [RetrievalEvalCase] = [
        .init(name: "lexical-miss: packing→Lisbon trip",
              query: "what should I pack?",
              corpus: ["I'm planning a trip to Lisbon in September",
                       "favorite editor is Xcode", "has a golden retriever named Rex"],
              expected: "I'm planning a trip to Lisbon in September"),
        .init(name: "question-trap: fact must beat near-identical past question",
              query: "Where do I want to travel this summer?",
              corpus: ["Where do I want to travel this year?",
                       "wants to travel to Ghent and Lisbon",
                       "prefers window seats on flights"],
              expected: "wants to travel to Ghent and Lisbon"),
        .init(name: "paraphrase: job",
              query: "what do I do for work?",
              corpus: ["works as an iOS developer at a small startup",
                       "allergic to peanuts", "sister is called Maria"],
              expected: "works as an iOS developer at a small startup"),
        .init(name: "keyword: direct recall still works",
              query: "what's my favorite color?",
              corpus: ["favorite color is teal", "drinks oat-milk lattes",
                       "runs 5k on Tuesdays"],
              expected: "favorite color is teal"),
        .init(name: "negative: nothing relevant",
              query: "what's the capital of Mongolia?",
              corpus: ["favorite color is teal", "has a golden retriever named Rex"],
              expected: nil),
    ]
}
