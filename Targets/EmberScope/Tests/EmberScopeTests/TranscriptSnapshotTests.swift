import Foundation
import FoundationModels
import Testing
@testable import EmberScope

struct TranscriptSnapshotTests {
    let sessionID = Fixtures.sessionID

    @Test func mapsEveryEntryKindInOrder() {
        let snap = TranscriptSnapshot.make(from: Fixtures.transcript(), sessionID: sessionID, contextSize: 4096)
        #expect(snap.entries.map(\.kind) == [.instructions, .prompt, .toolCalls, .toolOutput, .response])
        #expect(snap.entries.map(\.id) == ["e-instr", "e-prompt", "e-calls", "e-out", "e-resp"])
        let instructions = snap.entries[0]
        #expect(instructions.text == "You are terse.")
        #expect(instructions.toolDefinitions.map(\.name) == ["echo"])
        let prompt = snap.entries[1]
        #expect(prompt.text == "Echo hi please")
        #expect(prompt.options == RequestOptions(temperature: 0, maximumResponseTokens: 50, samplingDescription: "greedy"))
        #expect(prompt.responseFormat == nil)
        let calls = snap.entries[2]
        #expect(calls.toolName == "echo")
        #expect(calls.text.hasPrefix("echo("))
        #expect(calls.text.contains("\"hi\""))
        #expect(calls.structuredJSON?.contains("\"text\"") == true)
        #expect(snap.entries[3].toolName == "echo")
        #expect(snap.entries[3].text == "echo: hi")
        #expect(snap.entries[4].text == "Done: hi")
        #expect(snap.entries.allSatisfy { !$0.isExact && $0.tokens > 0 })
        #expect(snap.sessionID == sessionID)
    }

    @Test func totalsAndRemaining() {
        let snap = TranscriptSnapshot.make(from: Fixtures.transcript(), sessionID: sessionID, contextSize: 100)
        let sum = snap.entries.reduce(0) { $0 + $1.tokens }
        #expect(snap.usedTokens == sum)
        #expect(snap.remainingTokens == max(0, 100 - sum))
        #expect(snap.tokens(by: .instructions) == snap.entries[0].tokens)
        #expect(snap.tokens(by: .toolCalls) + snap.tokens(by: .toolOutput) == snap.entries[2].tokens + snap.entries[3].tokens)
        #expect(snap.fraction == min(1, Double(sum) / 100))
        #expect(!snap.isExact)
    }

    @Test func toolSchemasRaiseTheInstructionsEstimate() {
        let without = TranscriptSnapshot.make(from: Fixtures.transcript(), sessionID: sessionID, contextSize: 4096)
        let with = TranscriptSnapshot.make(from: Fixtures.transcript(), sessionID: sessionID, contextSize: 4096, tools: [EchoTool()])
        #expect(with.entries[0].tokens > without.entries[0].tokens)
        #expect(with.toolsTokens != nil)
        #expect((with.toolsTokens ?? 0) > (without.toolsTokens ?? 0))
    }

    @Test func applyingExactCountsMarksEntriesExact() {
        let snap = TranscriptSnapshot.make(from: Fixtures.transcript(), sessionID: sessionID, contextSize: 4096)
        let partial = snap.applying(TokenCounts(snapshotID: snap.id, entryTokens: ["e-instr": 30, "e-prompt": 9], toolsTokens: 21))
        #expect(partial.entries[0].tokens == 30 && partial.entries[0].isExact)
        #expect(partial.entries[1].tokens == 9 && partial.entries[1].isExact)
        #expect(partial.entries[2] == snap.entries[2])
        #expect(partial.toolsTokens == 21)
        #expect(!partial.isExact)
        let all = Dictionary(uniqueKeysWithValues: snap.entries.map { ($0.id, 5) })
        let full = snap.applying(TokenCounts(snapshotID: snap.id, entryTokens: all, toolsTokens: nil))
        #expect(full.isExact)
        #expect(full.usedTokens == 25)
        #expect(full.toolsTokens == snap.toolsTokens)   // nil counts keep the previous value
    }

    @Test func redactionKeepsShapeDropsText() {
        let snap = TranscriptSnapshot.make(from: Fixtures.transcript(), sessionID: sessionID, contextSize: 4096)
        let red = snap.redacted()
        #expect(red.entries.map(\.kind) == snap.entries.map(\.kind))
        #expect(red.entries.map(\.tokens) == snap.entries.map(\.tokens))
        #expect(red.entries.allSatisfy { ScopeRedaction.isRedacted($0.text) })
        #expect(red.entries[2].structuredJSON.map(ScopeRedaction.isRedacted) == true)
        #expect(red.entries[0].toolDefinitions == snap.entries[0].toolDefinitions)
    }

    @Test func requestOptionsMirrorGenerationOptions() {
        #expect(RequestOptions(GenerationOptions()).samplingDescription == "default")
        #expect(RequestOptions(GenerationOptions(sampling: .greedy)).samplingDescription == "greedy")
        #expect(RequestOptions(GenerationOptions(sampling: .random(top: 40))).samplingDescription == "random")
        let o = RequestOptions(GenerationOptions(temperature: 0.3, maximumResponseTokens: 99))
        #expect(o.temperature == 0.3 && o.maximumResponseTokens == 99)
    }

    @Test func toolInfoEncodesSchema() {
        let info = ToolInfo(EchoTool())
        #expect(info.name == "echo")
        #expect(info.description == "Echo the text back.")
        #expect(info.includesSchemaInInstructions)
        #expect(info.parametersJSON?.contains("\"text\"") == true)
    }
}
