import Testing
import FoundationModels
@testable import FoundationChatKit

@Suite struct UtilityGenerationOptionsTests {
    @Test func titleOptionsAreLengthCapped() {
        let options = UtilityGenerationOptions.title
        #expect(options.maximumResponseTokens == 24)
    }

    @Test func extractionOptionsAreLengthCapped() {
        let options = UtilityGenerationOptions.extraction
        #expect(options.maximumResponseTokens == 256)
    }

    @Test func summaryOptionsAreLengthCapped() {
        let options = UtilityGenerationOptions.summary
        #expect(options.maximumResponseTokens == 320)
    }

    @Test func allUtilityOptionsAreDeterministic() {
        // Deterministic == temperature 0 (greedy is also requested at construction).
        #expect(UtilityGenerationOptions.title.temperature == 0)
        #expect(UtilityGenerationOptions.extraction.temperature == 0)
        #expect(UtilityGenerationOptions.summary.temperature == 0)
    }
}
