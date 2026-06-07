import Foundation
import FoundationModels

/// Structured compaction summary (Plan 10 WS4). Produced by the model in a throwaway session
/// and rendered deterministically into the recap. `userPreferences` are additionally harvested
/// into durable notes by ContextCompactor so they survive future compactions.
@Generable(description: "A structured recap of earlier conversation for context compaction.")
public struct ConversationSummary: Sendable, Equatable {
    @Guide(description: "A brief factual summary of the earlier conversation in 1-3 sentences, preserving names, facts, and decisions.")
    public var summary: String

    @Guide(description: "Up to 5 short key topics discussed.", .maximumCount(5))
    public var keyTopics: [String]

    @Guide(description: "Up to 5 durable USER preferences or stable personal facts, in the third person. Empty if none.", .maximumCount(5))
    public var userPreferences: [String]

    public init(summary: String, keyTopics: [String], userPreferences: [String]) {
        self.summary = summary
        self.keyTopics = keyTopics
        self.userPreferences = userPreferences
    }

    /// Non-empty entries only, trimmed.
    var cleanTopics: [String] { keyTopics.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    var cleanPreferences: [String] { userPreferences.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    var cleanSummary: String { summary.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var isEmpty: Bool {
        cleanSummary.isEmpty && cleanTopics.isEmpty && cleanPreferences.isEmpty
    }

    /// Deterministic recap text. Sections are appended only when non-empty.
    public func render() -> String {
        var parts: [String] = []
        if !cleanSummary.isEmpty { parts.append(cleanSummary) }
        if !cleanTopics.isEmpty { parts.append("Topics: \(cleanTopics.joined(separator: ", "))") }
        if !cleanPreferences.isEmpty {
            parts.append("Preferences: \(cleanPreferences.joined(separator: "; "))")
        }
        return parts.joined(separator: "\n")
    }
}
