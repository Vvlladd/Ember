import Testing
import Foundation
@testable import FoundationChatKit

/// Locks the mapping of Apple's opaque on-device generation errors onto `ChatError`. Uses synthetic
/// NSErrors shaped like the real ones captured on device, so it runs without Apple Intelligence.
@MainActor
struct ErrorMappingTests {
    /// The real failure: GenerationError Code=-1 wrapping a `com.apple.tokengeneration` error in
    /// NSMultipleUnderlyingErrorsKey → mapped to the retryable `.generationInterrupted`.
    @Test func mapsTokenGenerationFailureToTransient() {
        let underlying = NSError(domain: "com.apple.tokengeneration", code: 10)
        let wrapper = NSError(domain: "FoundationModels.LanguageModelSession.GenerationError",
                              code: -1, userInfo: [NSMultipleUnderlyingErrorsKey: [underlying]])
        #expect(FoundationModelSession.map(wrapper) as? ChatError == .generationInterrupted)
    }

    /// Also detected when nested under the single-underlying-error key.
    @Test func detectsTokenGenerationViaSingleUnderlyingKey() {
        let underlying = NSError(domain: "com.apple.tokengeneration", code: 10)
        let wrapper = NSError(domain: "Outer", code: -1,
                              userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(FoundationModelSession.isTransientGenerationFailure(wrapper))
    }

    /// An unrelated error is NOT misclassified as transient and passes through untouched.
    @Test func unrelatedErrorPassesThrough() {
        let other = NSError(domain: "com.example.other", code: 42)
        #expect(FoundationModelSession.isTransientGenerationFailure(other) == false)
        #expect((FoundationModelSession.map(other) as NSError).domain == "com.example.other")
    }
}
