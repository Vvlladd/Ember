import Foundation
import FoundationModels

/// A tool that returns the current date and time, optionally for a specific time zone.
/// The clock is injected so output is deterministic in tests.
public struct DateTimeTool: Tool {
    public let name = "currentDateTime"
    public let description = "Get the current date and time, optionally for a specific time zone."

    @Generable
    public struct Arguments {
        @Guide(description: "An IANA time zone like America/New_York. Omit for device local time.")
        public var timeZone: String?
        public init(timeZone: String? = nil) { self.timeZone = timeZone }
    }

    private let now: @Sendable () -> Date
    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    public func call(arguments: Arguments) async throws -> String {
        var zone = TimeZone.current
        var note = ""
        if let id = arguments.timeZone, !id.isEmpty {
            if let tz = TimeZone(identifier: id) {
                zone = tz
            } else {
                note = " (unknown time zone '\(id)', showing device local time)"
            }
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        formatter.timeZone = zone
        return formatter.string(from: now()) + note
    }
}
