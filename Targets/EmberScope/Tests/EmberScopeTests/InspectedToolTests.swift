import Foundation
import FoundationModels
import Testing
@testable import EmberScope

struct InspectedToolTests {
    private func activeRecorder() -> ScopeRecorder {
        ScopeRecorder(configuration: ScopeConfiguration(isEnabled: true), isRecording: true)
    }

    @Test func forwardsMetadata() throws {
        let tool = InspectedTool(EchoTool(), sessionID: nil, recorder: activeRecorder())
        #expect(tool.name == "echo")
        #expect(tool.description == "Echo the text back.")
        #expect(tool.includesSchemaInInstructions == EchoTool().includesSchemaInInstructions)
        // `GenerationSchema.encode(to:)` writes its keys in a nondeterministic order — even two encodes of
        // the *same* value differ — so canonicalise with `.sortedKeys` before comparing bytes.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let a = try encoder.encode(tool.parameters)
        let b = try encoder.encode(EchoTool().parameters)
        #expect(a == b)
    }

    @Test func recordsSuccessfulCall() async throws {
        let r = activeRecorder()
        let tool = InspectedTool(EchoTool(), sessionID: Fixtures.sessionID, recorder: r)
        let out = try await tool.call(arguments: .init(text: "hi"))
        #expect(out == "echo: hi")
        let events = r.snapshot()
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.sessionID == Fixtures.sessionID })
        guard case .toolCallStarted(let start) = events[0].payload else { Issue.record("expected start"); return }
        #expect(start.toolName == "echo")
        #expect(start.arguments.contains("\"text\"") && start.arguments.contains("hi"))
        guard case .toolCallFinished(let end) = events[1].payload else { Issue.record("expected end"); return }
        #expect(end.callID == start.callID)
        #expect(end.status == .succeeded)
        #expect(end.output == "echo: hi")
        #expect(end.duration >= .zero)
    }

    @Test func recordsFailureAndRethrows() async {
        let r = activeRecorder()
        var base = EchoTool(); base.shouldThrow = true
        let tool = InspectedTool(base, sessionID: Fixtures.sessionID, recorder: r)
        await #expect(throws: EchoError.self) { try await tool.call(arguments: .init(text: "x")) }
        let events = r.snapshot()
        #expect(events.count == 3)
        guard case .toolCallStarted(let start) = events[0].payload,
              case .error(let error) = events[1].payload,
              case .toolCallFinished(let end) = events[2].payload else { Issue.record("unexpected shape"); return }
        #expect(error.kind == .toolCallFailed)
        #expect(error.toolName == "echo")
        #expect(error.toolCallID == start.callID)
        #expect(end.status == .failed(errorID: error.id))
        #expect(end.output == nil)
    }

    @Test func passesThroughWhenRecorderInactive() async throws {
        let r = ScopeRecorder(configuration: ScopeConfiguration(isEnabled: true), isRecording: false)
        let tool = InspectedTool(EchoTool(), recorder: r)
        #expect(try await tool.call(arguments: .init(text: "quiet")) == "echo: quiet")
        #expect(r.snapshot().isEmpty)
    }

    @Test func wrapPreservesOrderAndNeverDoubleWraps() {
        let r = activeRecorder()
        let tools: [any Tool] = [EchoTool(), EchoTool()]
        let wrapped = EmberScope.wrap(tools, sessionID: Fixtures.sessionID, recorder: r)
        #expect(wrapped.map(\.name) == ["echo", "echo"])
        #expect(wrapped.allSatisfy { $0 is any InspectedToolMarker })
        let twice = EmberScope.wrap(wrapped, recorder: r)
        #expect(twice.count == 2)
        #expect(twice[0] is InspectedTool<EchoTool>)
    }

    @Test func inspectedSugarAndSharedRecorder() {
        let tool = EchoTool().inspected(sessionID: Fixtures.sessionID)
        #expect(tool.name == "echo")
        #expect(tool.sessionID == Fixtures.sessionID)
    }

    /// Ruling (final review B8): a tool wrapped BEFORE the session existed was returned untouched, so
    /// `EmberScope.session(tools: [MyTool().inspected()])` recorded its calls with `sessionID: nil`.
    @Test func aPreWrappedToolIsReboundToTheSessionItJoins() async throws {
        let r = activeRecorder()
        let session = InspectedSession(tools: [EchoTool().inspected(recorder: r)], label: "rebound",
                                       recorder: r, counter: MockTokenCounter(supportsExactCounts: false))
        let tool = try #require(session.tools.first as? InspectedTool<EchoTool>)
        #expect(tool.sessionID == session.id)
        _ = try await tool.call(arguments: .init(text: "hi"))
        let toolEvents = r.snapshot().filter {
            if case .toolCallStarted = $0.payload { return true }
            if case .toolCallFinished = $0.payload { return true }
            return false
        }
        #expect(toolEvents.count == 2)
        #expect(toolEvents.allSatisfy { $0.sessionID == session.id })
        // Re-binding to the SAME id is a no-op (no needless copy).
        let same = EmberScope.wrap(session.tools, sessionID: session.id, recorder: r)
        #expect((same.first as? InspectedTool<EchoTool>)?.sessionID == session.id)
    }
}
