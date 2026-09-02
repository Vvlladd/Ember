import Foundation

/// Display formatting shared by the UI and the Markdown export. Pure.
///
/// Every helper is deliberately locale-independent: an export is a bug report that gets pasted into
/// an issue, so it must read the same on every machine. The `FormatStyle` values used here are
/// `Sendable` structs, so no shared formatter state crosses concurrency domains (a cached
/// `static let ISO8601DateFormatter` is a non-`Sendable` global — a warning here and an error in a
/// Swift 6 host).
public enum ScopeFormatting {
    public static func duration(_ d: Duration) -> String {
        let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        if seconds >= 1 { return String(format: "%.2f s", seconds) }
        let ms = seconds * 1_000
        if ms >= 10 { return String(format: "%.0f ms", ms) }
        return String(format: "%.1f ms", ms)
    }

    /// Grouped token count, e.g. `4,096`. Pinned to `en_US` rather than the user's locale so exports
    /// are stable; `en_US_POSIX` is not an option — its number pattern carries no grouping at all
    /// (it renders `4096`).
    public static func tokens(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    /// ISO-8601 in UTC, to the second: `2023-11-14T22:13:20Z`.
    public static func timestamp(_ date: Date) -> String { date.formatted(.iso8601) }

    public static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    /// Single-line preview: collapses whitespace, truncates with an ellipsis.
    public static func preview(_ text: String, max: Int = 80) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard collapsed.count > max else { return collapsed }
        // `prefix` traps on a negative length, and `max` is caller-supplied.
        return String(collapsed.prefix(Swift.max(0, max - 1))) + "…"
    }
}
