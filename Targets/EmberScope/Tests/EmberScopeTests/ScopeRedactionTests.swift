import Testing
@testable import EmberScope

struct ScopeRedactionTests {
    @Test func placeholderCarriesLength() {
        let p = ScopeRedaction.placeholder(forCharacterCount: 42)
        #expect(p == "«redacted · 42 chars»")
        #expect(ScopeRedaction.isRedacted(p))
        #expect(!ScopeRedaction.isRedacted("hello"))
    }

    @Test func redactedPayloadKeepsMetadataDropsContent() {
        let start = ScopePayload.requestStarted(Fixtures.requestStart).redacted()
        guard case .requestStarted(let r) = start else { Issue.record("wrong case"); return }
        #expect(r.prompt == ScopeRedaction.placeholder(forCharacterCount: 11))
        #expect(r.kind == .stream)
        #expect(r.options == Fixtures.requestStart.options)

        let end = ScopePayload.requestFinished(Fixtures.requestEnd).redacted()
        guard case .requestFinished(let e) = end else { Issue.record("wrong case"); return }
        #expect(e.output == ScopeRedaction.placeholder(forCharacterCount: 3))
        #expect(e.chunkCount == 12)

        let created = ScopePayload.sessionCreated(Fixtures.sessionInfo).redacted()
        guard case .sessionCreated(let s) = created else { Issue.record("wrong case"); return }
        #expect(s.instructions == ScopeRedaction.placeholder(forCharacterCount: 14))
        #expect(s.tools == Fixtures.sessionInfo.tools)   // developer content stays

        let tool = ScopePayload.toolCallStarted(ToolCallStart(callID: Fixtures.callID, toolName: "echo", arguments: "{\"text\":\"hi\"}")).redacted()
        guard case .toolCallStarted(let t) = tool else { Issue.record("wrong case"); return }
        #expect(ScopeRedaction.isRedacted(t.arguments))
        #expect(t.toolName == "echo")
    }

    @Test func nonContentPayloadsAreUnchanged() {
        #expect(ScopePayload.prewarm.redacted() == .prewarm)
        #expect(ScopePayload.note("n").redacted() == .note("n"))
    }

    /// Ruling (Task 2 review): Apple's and tool authors' error messages can quote prompt text, so a
    /// metadata-only inspector redacts the four free-form strings but keeps every structured field.
    @Test func errorDiagnosticsAreRedactedButStructureIsKept() {
        guard case .error(let e) = ScopePayload.error(Fixtures.errorRecord).redacted() else { Issue.record("wrong case"); return }
        #expect(e.id == Fixtures.errorRecord.id && e.kind == .rateLimited && e.isRetryable)
        #expect(e.requestID == Fixtures.requestID && e.underlyingChain == Fixtures.errorRecord.underlyingChain)
        #expect(e.message == ScopeRedaction.placeholder(forCharacterCount: 12))
        #expect(e.debugDescription.map(ScopeRedaction.isRedacted) == true)
        #expect(e.recoverySuggestion.map(ScopeRedaction.isRedacted) == true)
        #expect(e.failureReason == nil)
    }
}
