import Foundation

public struct TokenEstimator: Sendable {
    public init() {}

    public func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjkCount = 0
        var otherCount = 0
        for scalar in text.unicodeScalars {
            if Self.isCJK(scalar) { cjkCount += 1 } else { otherCount += 1 }
        }
        let latinTokens = otherCount == 0 ? 0 : Int((Double(otherCount) / 3.5).rounded(.up))
        return cjkCount + latinTokens
    }

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x4E00...0x9FFF, 0x3040...0x30FF, 0xAC00...0xD7AF, 0x3400...0x4DBF:
            return true
        default:
            return false
        }
    }
}
