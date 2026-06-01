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
    }
    @Test func chatErrorEquatable() {
        #expect(ChatError.contextOverflow == ChatError.contextOverflow)
        #expect(ChatError.refusal("no") == ChatError.refusal("no"))
    }
}
