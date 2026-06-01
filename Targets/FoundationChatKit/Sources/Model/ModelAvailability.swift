import Foundation

public enum ModelUnavailableReason: Sendable, Equatable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unknown
}

public enum ModelAvailability: Sendable, Equatable {
    case available
    case unavailable(ModelUnavailableReason)
}
