import Foundation
import FoundationModels
import Testing
@testable import EmberScope

struct ScopeErrorClassifierTests {
    typealias GenerationError = LanguageModelSession.GenerationError
    private func ctx(_ s: String = "ctx") -> GenerationError.Context { .init(debugDescription: s) }

    @Test func mapsEveryGenerationErrorCase() {
        let cases: [(GenerationError, ScopeErrorRecord.Kind, Bool)] = [
            (.exceededContextWindowSize(ctx()), .exceededContextWindowSize, false),
            (.assetsUnavailable(ctx()), .assetsUnavailable, false),
            (.guardrailViolation(ctx()), .guardrailViolation, false),
            (.unsupportedGuide(ctx()), .unsupportedGuide, false),
            (.unsupportedLanguageOrLocale(ctx()), .unsupportedLanguageOrLocale, false),
            (.decodingFailure(ctx()), .decodingFailure, false),
            (.rateLimited(ctx()), .rateLimited, true),
            (.concurrentRequests(ctx()), .concurrentRequests, true),
            (.refusal(.init(transcriptEntries: []), ctx("refused")), .refusal, false),
        ]
        for (error, kind, retryable) in cases {
            let record = ScopeErrorClassifier.classify(error, requestID: Fixtures.requestID)
            #expect(record.kind == kind, "\(error)")
            #expect(record.isRetryable == retryable, "\(error)")
            #expect(record.requestID == Fixtures.requestID)
            #expect(record.debugDescription != nil)
            #expect(!record.message.isEmpty)
        }
        let refusal = ScopeErrorClassifier.classify(GenerationError.refusal(.init(transcriptEntries: []), ctx("refused")))
        #expect(refusal.debugDescription == "refused")
    }

    @Test func mapsToolCallError() {
        let error = LanguageModelSession.ToolCallError(tool: EchoTool(), underlyingError: EchoError.boom)
        let record = ScopeErrorClassifier.classify(error, requestID: Fixtures.requestID)
        #expect(record.kind == .toolCallFailed)
        #expect(record.toolName == "echo")
        #expect(record.debugDescription?.contains("boom") == true)
        #expect(!record.isRetryable)
    }

    @Test func mapsCancellation() {
        let record = ScopeErrorClassifier.classify(CancellationError())
        #expect(record.kind == .cancelled)
        #expect(!record.isRetryable)
    }

    @Test func detectsTransientTokenGenerationFailureInChain() {
        let underlying = NSError(domain: "com.apple.tokengeneration", code: 10)
        let wrapper = NSError(domain: "FoundationModels.LanguageModelSession.GenerationError", code: -1,
                              userInfo: [NSMultipleUnderlyingErrorsKey: [underlying]])
        let record = ScopeErrorClassifier.classify(wrapper)
        #expect(record.kind == .transientGeneration)
        #expect(record.isRetryable)
        #expect(record.underlyingChain == ["com.apple.tokengeneration(10)"])

        let single = NSError(domain: "Outer", code: 1, userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(ScopeErrorClassifier.isTransientGenerationFailure(single))
        #expect(ScopeErrorClassifier.classify(underlying).kind == .transientGeneration)
    }

    @Test func mapsModelManagerFailureToAssetsUnavailable() {
        // Shape observed on a Mac without Apple Intelligence: GenerationError Code=-1 → ModelManagerError 1026.
        let mm = NSError(domain: "ModelManagerServices.ModelManagerError", code: 1026)
        let wrapper = NSError(domain: "FoundationModels.LanguageModelSession.GenerationError", code: -1,
                              userInfo: [NSMultipleUnderlyingErrorsKey: [mm]])
        let record = ScopeErrorClassifier.classify(wrapper)
        #expect(record.kind == .assetsUnavailable)
        #expect(record.underlyingChain == ["ModelManagerServices.ModelManagerError(1026)"])
        // Own-domain form, and a look-alike domain must NOT match.
        #expect(ScopeErrorClassifier.classify(mm).kind == .assetsUnavailable)
        #expect(ScopeErrorClassifier.classify(NSError(domain: "ModelManagerServices.ModelManagerErrorX", code: 1)).kind == .unknown)
    }

    @Test func unknownErrorsPassThroughWithDescription() {
        let record = ScopeErrorClassifier.classify(NSError(domain: "com.example", code: 42), toolCallID: Fixtures.callID, toolName: "echo")
        #expect(record.kind == .unknown)
        #expect(record.toolCallID == Fixtures.callID)
        #expect(record.toolName == "echo")
        #expect(record.message.contains("com.example"))
        #expect(record.underlyingChain.isEmpty)
    }

    @Test func kindsHaveTitles() {
        for kind in ScopeErrorRecord.Kind.allCases { #expect(!kind.title.isEmpty) }
        #expect(ScopeErrorRecord.Kind.rateLimited.isRetryable)
        #expect(!ScopeErrorRecord.Kind.refusal.isRetryable)
    }
}
