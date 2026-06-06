import Testing
@testable import FoundationChatKit

struct SupportingTypesTests {
    @Test func availabilityEquatable() {
        #expect(ModelAvailability.available == .available)
        #expect(ModelAvailability.unavailable(.modelNotReady) != .available)
    }
    @Test func generationSettingsDefault() {
        let s = GenerationSettings()
        #expect(s.instructions == nil)
        #expect(s.temperature == nil)
        #expect(s.maximumResponseTokens == nil)
        // Auto-RAG precision: a single strong match, filtered at a higher threshold.
        #expect(s.memoryRetrievalTopK == 1)
        #expect(s.memoryRetrievalThreshold == 0.5)
    }
    @Test func chatErrorEquatable() {
        #expect(ChatError.contextOverflow == ChatError.contextOverflow)
        #expect(ChatError.refusal("no") == ChatError.refusal("no"))
    }
    @Test func toolFailedIsEquatable() {
        #expect(ChatError.toolFailed(tool: "calculator", message: "x")
                == ChatError.toolFailed(tool: "calculator", message: "x"))
        #expect(ChatError.toolFailed(tool: "a", message: nil)
                != ChatError.toolFailed(tool: "b", message: nil))
    }
    @Test func titleSeedStoresExchange() {
        let seed = TitleSeed(userText: "u", assistantText: "a")
        #expect(seed.userText == "u")
        #expect(seed.assistantText == "a")
    }
}
