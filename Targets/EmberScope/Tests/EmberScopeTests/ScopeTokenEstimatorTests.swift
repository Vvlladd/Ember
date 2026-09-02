import Testing
@testable import EmberScope

struct ScopeTokenEstimatorTests {
    let estimator = ScopeTokenEstimator()

    @Test func emptyIsZero() { #expect(estimator.estimate("") == 0) }

    @Test func latinTextUsesThreePointFiveCharsPerToken() {
        // 7 characters → ceil(7 / 3.5) = 2
        #expect(estimator.estimate("abcdefg") == 2)
        // 8 characters → ceil(8 / 3.5) = 3
        #expect(estimator.estimate("abcdefgh") == 3)
    }

    @Test func cjkCountsOneTokenPerScalar() {
        #expect(estimator.estimate("日本語") == 3)
        // mixed: 3 CJK + 5 Latin ("hello") → 3 + ceil(5/3.5)=2 → 5
        #expect(estimator.estimate("日本語hello") == 5)
    }
}
