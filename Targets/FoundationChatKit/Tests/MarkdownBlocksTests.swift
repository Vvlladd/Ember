import Testing
@testable import FoundationChatKit

struct MarkdownBlocksTests {
    @Test func plainProse() {
        #expect(MarkdownBlocks.parse("hello world") == [.prose("hello world")])
    }
    @Test func singleCodeBlock() {
        #expect(MarkdownBlocks.parse("```swift\nlet x = 1\n```")
                == [.code(language: "swift", code: "let x = 1")])
    }
    @Test func proseCodeProse() {
        #expect(MarkdownBlocks.parse("before\n```\ncode\n```\nafter")
                == [.prose("before"), .code(language: nil, code: "code"), .prose("after")])
    }
    @Test func unterminatedFenceBecomesCode() {
        #expect(MarkdownBlocks.parse("intro\n```python\nx = 1")
                == [.prose("intro"), .code(language: "python", code: "x = 1")])
    }
}
