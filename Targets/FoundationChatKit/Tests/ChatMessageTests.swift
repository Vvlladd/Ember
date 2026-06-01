import Testing
import Foundation
@testable import FoundationChatKit

struct ChatMessageTests {
    @Test func userMessageDefaults() {
        let fixed = Date(timeIntervalSince1970: 100)
        let m = ChatMessage(role: .user, text: "hi", createdAt: fixed)
        #expect(m.role == .user)
        #expect(m.text == "hi")
        #expect(m.isStreaming == false)
        #expect(m.createdAt == fixed)
    }

    @Test func streamingFlagAndReplaceText() {
        var m = ChatMessage(role: .assistant, text: "", createdAt: .init(timeIntervalSince1970: 0), isStreaming: true)
        m.text = "Hello"
        m.text = "Hello world"
        #expect(m.text == "Hello world")
        #expect(m.isStreaming)
    }
}
