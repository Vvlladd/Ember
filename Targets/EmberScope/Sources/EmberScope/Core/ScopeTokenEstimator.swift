import Foundation

/// Synchronous token estimate used until exact counts arrive: ⌈non-CJK scalars / 3.5⌉ + one token
/// per CJK scalar. Same heuristic Ember uses for its live gauge.
public struct ScopeTokenEstimator: Sendable {
    public init() {}

    public func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if Self.isCJK(scalar) { cjk += 1 } else { other += 1 }
        }
        let latinTokens = other == 0 ? 0 : Int((Double(other) / 3.5).rounded(.up))
        return cjk + latinTokens
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3040...0x30FF, 0xAC00...0xD7AF, 0x3400...0x4DBF: return true
        default: return false
        }
    }
}
