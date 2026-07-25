import Foundation
@testable import FoundationChatKit

/// One golden retrieval case: for `query`, searching `corpus` must surface `expected` in the top k.
/// `expected == nil` means a NEGATIVE case: nothing in the corpus is relevant and no hit should
/// clear the production threshold. `conversationCorpus` is embedded as `.conversation` snippets
/// (vs. `.note` for `corpus`) — question-trap cases use it to hold the near-identical past
/// question, so `preferNotes` ranking is actually exercised the way it is in production (durable
/// `MemoryNote`s outrank raw conversation history).
struct RetrievalEvalCase: Sendable {
    let name: String
    let query: String
    let corpus: [String]
    let expected: String?
    let conversationCorpus: [String]

    // Explicit init (not the synthesized memberwise one): a defaulted stored property is dropped
    // from the synthesized init's parameter list entirely rather than made overridable, so callers
    // that need to pass `conversationCorpus` would otherwise hit "extra argument in call".
    init(name: String, query: String, corpus: [String], expected: String?,
         conversationCorpus: [String] = []) {
        self.name = name
        self.query = query
        self.corpus = corpus
        self.expected = expected
        self.conversationCorpus = conversationCorpus
    }
}

enum RetrievalEval {
    /// Fraction of non-negative cases whose expected text lands in the top `k` — plus a hard pass
    /// bool for negatives. Uses the PRODUCTION search path and defaults (hybrid, threshold 0.35,
    /// lexicalWeight 0.5) so numbers reflect real behavior.
    static func recallAtK(cases: [RetrievalEvalCase], embedder: any TextEmbedder, k: Int)
        -> (recall: Double, negativesClean: Bool) {
        var hits = 0, positives = 0, negativesClean = true
        for c in cases {
            let notes = c.corpus.map { text in
                MemoryRecord(messageID: UUID(), conversationID: UUID(), conversationTitle: "eval",
                             role: .user, text: text,
                             vector: embedder.embed(text, role: .document) ?? [], source: .note)
            }
            let conversationSnippets = c.conversationCorpus.map { text in
                MemoryRecord(messageID: UUID(), conversationID: UUID(), conversationTitle: "eval",
                             role: .user, text: text,
                             vector: embedder.embed(text, role: .document) ?? [], source: .conversation)
            }
            let snapshot = notes + conversationSnippets
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

    /// Golden fixtures: 16 positives across four categories (lexical-miss / question-trap /
    /// paraphrase / keyword), ~4 each, spanning varied domains (travel, food/allergies, work,
    /// family, pets, preferences, health, scheduling), plus 4 negatives. The first five preserve
    /// the exact regression texts from the original fixture set (documented NLEmbedding failures
    /// from the Plan-9 device debugging + the keyword baseline + the Mongolia negative).
    static let fixtures: [RetrievalEvalCase] = [
        // MARK: - lexical-miss (query and expected share NO content words)
        .init(name: "lexical-miss: packing→Lisbon trip",
              query: "what should I pack?",
              corpus: ["I'm planning a trip to Lisbon in September",
                       "favorite editor is Xcode", "has a golden retriever named Rex"],
              expected: "I'm planning a trip to Lisbon in September"),
        .init(name: "lexical-miss: restaurant caution→shellfish allergy",
              query: "is it risky for me to eat at seafood restaurants?",
              corpus: ["severely allergic to shellfish and peanuts",
                       "enjoys hiking on weekends", "prefers aisle seats on flights"],
              expected: "severely allergic to shellfish and peanuts"),
        .init(name: "lexical-miss: afternoon childcare→daughter pickup",
              query: "who takes care of the kids in the afternoon?",
              corpus: ["daughter gets out of school at three and needs a ride",
                       "drinks oat-milk lattes", "works remotely on Fridays"],
              expected: "daughter gets out of school at three and needs a ride"),
        .init(name: "lexical-miss: midweek availability→dentist appointment",
              query: "what's going on for me midweek?",
              corpus: ["has a dentist appointment at 2pm on Wednesday",
                       "likes jazz music", "collects vinyl records"],
              expected: "has a dentist appointment at 2pm on Wednesday"),

        // MARK: - question-trap (durable fact must beat a near-identical past question)
        .init(name: "question-trap: fact must beat near-identical past question",
              query: "Where do I want to travel this summer?",
              corpus: ["wants to travel to Ghent and Lisbon",
                       "prefers window seats on flights"],
              expected: "wants to travel to Ghent and Lisbon",
              conversationCorpus: ["Where do I want to travel this year?"]),
        .init(name: "question-trap: job fact must beat past job question",
              query: "What's my job right now?",
              corpus: ["works as a backend engineer at a logistics company",
                       "prefers standing desks"],
              expected: "works as a backend engineer at a logistics company",
              conversationCorpus: ["What was my job before this one?"]),
        .init(name: "question-trap: pet fact must beat past pet-naming question",
              query: "What's my pet's name?",
              corpus: ["has a tabby cat named Biscuit",
                       "enjoys pottery classes"],
              expected: "has a tabby cat named Biscuit",
              conversationCorpus: ["What's a cute name for a pet?"]),
        .init(name: "question-trap: health fact must beat past family-health question",
              query: "What health condition do I have?",
              corpus: ["was diagnosed with mild asthma last year",
                       "practices yoga on Sundays"],
              expected: "was diagnosed with mild asthma last year",
              conversationCorpus: ["What health conditions run in my family?"]),

        // MARK: - paraphrase (semantically related, wording differs)
        .init(name: "paraphrase: job",
              query: "what do I do for work?",
              corpus: ["works as an iOS developer at a small startup",
                       "allergic to peanuts", "sister is called Maria"],
              expected: "works as an iOS developer at a small startup"),
        .init(name: "paraphrase: immediate family",
              query: "who's in my immediate family?",
              corpus: ["has two younger brothers and a sister",
                       "enjoys rock climbing", "commutes by bike"],
              expected: "has two younger brothers and a sister"),
        .init(name: "paraphrase: music taste",
              query: "what kind of music do I like?",
              corpus: ["big fan of 90s hip-hop and jazz",
                       "vegetarian for five years", "graduated from NYU"],
              expected: "big fan of 90s hip-hop and jazz"),
        .init(name: "paraphrase: workout schedule",
              query: "when do I usually work out?",
              corpus: ["goes to the gym every morning before work",
                       "owns an electric car", "studying for a certification exam"],
              expected: "goes to the gym every morning before work"),

        // MARK: - keyword (query shares obvious words with the expected text)
        .init(name: "keyword: direct recall still works",
              query: "what's my favorite color?",
              corpus: ["favorite color is teal", "drinks oat-milk lattes",
                       "runs 5k on Tuesdays"],
              expected: "favorite color is teal"),
        .init(name: "keyword: pet breed",
              query: "what's my pet's breed?",
              corpus: ["pet breed is a golden retriever", "collects stamps",
                       "bikes to work daily"],
              expected: "pet breed is a golden retriever"),
        .init(name: "keyword: blood type",
              query: "what's my blood type?",
              corpus: ["blood type is O negative", "enjoys chess on weekends",
                       "recently started a book club"],
              expected: "blood type is O negative"),
        .init(name: "keyword: favorite food",
              query: "what's my favorite food?",
              corpus: ["favorite food is homemade lasagna", "practices piano twice a week",
                       "volunteers at an animal shelter"],
              expected: "favorite food is homemade lasagna"),

        // MARK: - negatives (nothing in the corpus is relevant; no hit should clear threshold)
        .init(name: "negative: capital of Mongolia",
              query: "what's the capital of Mongolia?",
              corpus: ["favorite color is teal", "has a golden retriever named Rex"],
              expected: nil),
        .init(name: "negative: stock market question",
              query: "how is the stock market doing today?",
              corpus: ["enjoys pottery classes", "vegetarian for five years"],
              expected: nil),
        .init(name: "negative: unrelated trivia",
              query: "what year did the Berlin Wall fall?",
              corpus: ["collects vinyl records", "bikes to work daily"],
              expected: nil),
        .init(name: "negative: unrelated cooking question",
              query: "how long should I boil an egg?",
              corpus: ["owns an electric car", "commutes by bike"],
              expected: nil),
    ]
}
