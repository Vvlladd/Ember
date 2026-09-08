import Foundation
import SwiftUI
import Testing
@testable import EmberScope

struct ScopeStyleTests {
    private func end(_ status: RequestStatus) -> ScopePayload {
        .requestFinished(RequestEnd(requestID: Fixtures.requestID, status: status, duration: .milliseconds(703),
                                    timeToFirstToken: nil, chunkCount: 0, output: nil, outputChars: 0,
                                    appendedEntryCount: 0, resolvedPrompt: nil))
    }
    private func toolEnd(_ status: ToolCallStatus) -> ScopePayload {
        .toolCallFinished(ToolCallEnd(callID: Fixtures.callID, toolName: "echo", status: status,
                                      duration: .milliseconds(4), output: nil))
    }

    /// Ruling (final review A9, found on the iPad simulator): the Timeline showed a green checkmark
    /// next to "Request failed · 703 ms" because the glyph ignored the status.
    @Test func terminalEventGlyphsFollowTheStatus() {
        #expect(ScopeStyle.icon(for: end(.succeeded)) == (name: "checkmark.circle", color: .green))
        #expect(ScopeStyle.icon(for: end(.failed(errorID: Fixtures.errorRecord.id))) == (name: "xmark.octagon", color: .red))
        #expect(ScopeStyle.icon(for: end(.cancelled)) == (name: "slash.circle", color: .secondary))
        #expect(ScopeStyle.icon(for: toolEnd(.succeeded)) == (name: "checkmark.circle", color: .green))
        #expect(ScopeStyle.icon(for: toolEnd(.failed(errorID: Fixtures.errorRecord.id))) == (name: "xmark.octagon", color: .red))
        // A started tool call is still the wrench: only the terminal event carries an outcome.
        #expect(ScopeStyle.icon(for: .toolCallStarted(ToolCallStart(callID: Fixtures.callID, toolName: "echo",
                                                                    arguments: "{}"))).name == "wrench.and.screwdriver")
    }

    @Test func titlesAndSubtitlesMatchTheStatus() {
        #expect(ScopeEventSummary.title(for: end(.succeeded)).hasPrefix("Request finished"))
        #expect(ScopeEventSummary.title(for: end(.failed(errorID: Fixtures.errorRecord.id))).hasPrefix("Request failed"))
        #expect(ScopeEventSummary.title(for: end(.cancelled)) == "Request cancelled")
        #expect(ScopeEventSummary.title(for: .note("compacted")) == "compacted")
        #expect(ScopeEventSummary.subtitle(for: .requestStarted(Fixtures.requestStart)) == "Hello there")
        #expect(ScopeEventSummary.subtitle(for: .prewarm) == nil)
        // ScopeStyle forwards to the Core renderer, so the timeline and the fold agree.
        #expect(ScopeStyle.title(for: .prewarm) == ScopeEventSummary.title(for: .prewarm))
        #expect(ScopeStyle.subtitle(for: .error(Fixtures.errorRecord)) == Fixtures.errorRecord.message)
    }
}
