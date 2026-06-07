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
        // Auto-RAG recall: surface several memories (notes prioritized) so a durable fact isn't
        // buried under near-identical past questions; still filtered at a precision threshold.
        #expect(s.memoryRetrievalTopK == 4)
        // Threshold raised to 0.35 in Plan 10 WS2 so durable notes aren't lost.
        #expect(s.memoryRetrievalThreshold == 0.35)
        // Plan 9: proactive auto-extraction of salient user facts is on by default.
        #expect(s.autoExtractMemories == true)
    }
    @Test func generationSettingsInjectionDefaults() {
        let s = GenerationSettings()
        #expect(s.memoryInjectionMaxHits == 3)
        #expect(s.memoryInjectionMaxCharsPerHit == 240)
        #expect(s.memoryRetrievalThreshold == 0.35)
    }
    @Test func generationSettingsInjectionCustom() {
        let s = GenerationSettings(memoryRetrievalThreshold: 0.5,
                                   memoryInjectionMaxHits: 1,
                                   memoryInjectionMaxCharsPerHit: 120)
        #expect(s.memoryInjectionMaxHits == 1)
        #expect(s.memoryInjectionMaxCharsPerHit == 120)
        #expect(s.memoryRetrievalThreshold == 0.5)
    }
    @Test func generationSettingsHybridLexicalWeightDefault() {
        #expect(GenerationSettings().hybridLexicalWeight == 0.5)
    }

    @Test func generationSettingsHybridLexicalWeightCustom() {
        #expect(GenerationSettings(hybridLexicalWeight: 0.3).hybridLexicalWeight == 0.3)
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
