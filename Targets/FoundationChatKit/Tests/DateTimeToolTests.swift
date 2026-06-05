import Testing
import Foundation
@testable import FoundationChatKit

struct DateTimeToolTests {
    func toolAtEpoch() -> DateTimeTool {
        DateTimeTool(now: { Date(timeIntervalSince1970: 0) })
    }

    @Test func formatsForExplicitTimeZone() async throws {
        let result = try await toolAtEpoch().call(arguments: .init(timeZone: "UTC"))
        #expect(result.contains("1970"))
    }
    @Test func defaultsToDeviceLocal() async throws {
        let result = try await toolAtEpoch().call(arguments: .init(timeZone: nil))
        #expect(result.contains("19")) // year present
    }
    @Test func unknownTimeZoneFallsBackWithNote() async throws {
        let result = try await toolAtEpoch().call(arguments: .init(timeZone: "Not/AZone"))
        #expect(result.contains("unknown time zone"))
    }
    @Test func metadata() {
        #expect(toolAtEpoch().name == "currentDateTime")
    }
}
