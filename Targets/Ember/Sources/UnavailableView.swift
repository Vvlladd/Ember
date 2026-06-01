import SwiftUI
import FoundationChatKit
#if canImport(UIKit)
import UIKit
#endif

struct UnavailableView: View {
    let reason: ModelUnavailableReason

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        } actions: {
            if reason == .appleIntelligenceNotEnabled {
                Button("Open Settings", action: openSettings)
            }
        }
        .padding()
    }

    private var title: String {
        switch reason {
        case .deviceNotEligible: "Apple Intelligence Not Supported"
        case .appleIntelligenceNotEnabled: "Turn On Apple Intelligence"
        case .modelNotReady: "Preparing the Model"
        case .unknown: "Model Unavailable"
        }
    }
    private var message: String {
        switch reason {
        case .deviceNotEligible: "Ember needs an Apple-Intelligence-capable device to run the on-device model."
        case .appleIntelligenceNotEnabled: "Enable Apple Intelligence in Settings to start chatting on-device."
        case .modelNotReady: "The on-device model is downloading or not ready yet. Try again shortly."
        case .unknown: "The on-device model is unavailable right now."
        }
    }
    private var icon: String {
        switch reason {
        case .deviceNotEligible: "exclamationmark.triangle"
        case .appleIntelligenceNotEnabled: "sparkles"
        case .modelNotReady: "arrow.down.circle"
        case .unknown: "questionmark.circle"
        }
    }
    private func openSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #elseif canImport(AppKit)
        if let url = URL(string: "x-apple.systempreferences:") { NSWorkspace.shared.open(url) }
        #endif
    }
}
