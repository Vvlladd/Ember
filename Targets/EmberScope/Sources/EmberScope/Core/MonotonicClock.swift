import Foundation

/// Process-local monotonic time as a `Duration` since first use — easy to inject and to compare.
enum MonotonicClock {
    private static let origin = ContinuousClock.now
    static func now() -> Duration { ContinuousClock.now - origin }
}
