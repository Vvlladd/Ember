import Testing
@testable import FoundationChatKit

struct TokenEstimatorTests {
    let sut = TokenEstimator()
    @Test func emptyStringIsZero() { #expect(sut.estimate("") == 0) }
    @Test func latinUsesAboutThreeAndHalfCharsPerToken() {
        let s = String(repeating: "a", count: 35)   // 35 / 3.5 = 10
        #expect(sut.estimate(s) == 10)
    }
    @Test func latinRoundsUp() { #expect(sut.estimate("12345678") == 3) }   // 8/3.5=2.28 -> 3
    @Test func cjkIsOneTokenPerCharacter() { #expect(sut.estimate("你好世界界") == 5) }
    @Test func mixedScriptCountsSeparately() { #expect(sut.estimate("你好ab") == 3) }  // 2 CJK + ceil(2/3.5)=1
}
