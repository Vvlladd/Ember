import SwiftUI
import FoundationChatKit

struct ErrorBanner: View {
    let error: ChatError

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.orange.opacity(0.12))
    }

    private var message: String {
        switch error {
        case .guardrailViolation: "That request can't be handled. Try rephrasing."
        case .rateLimited: "The model is busy. Try again in a moment."
        case .generationInterrupted: "The on-device model hit a temporary error. Please try again."
        case .refusal(let r): r ?? "The model declined to answer that."
        case .modelUnavailable: "The on-device model is unavailable."
        case .decodingFailure: "The response couldn't be read. Try again."
        case .cancelled: "Stopped."
        case .toolFailed(let tool, _): "The '\(tool)' tool failed. Try rephrasing."
        case .contextOverflow: "Context was full and has been compacted."
        case .unknown(let m): "Something went wrong: \(m)"
        }
    }
}
