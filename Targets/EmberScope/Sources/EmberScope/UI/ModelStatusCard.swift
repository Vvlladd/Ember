import SwiftUI

struct ModelStatusCard: View {
    let status: ModelStatus?
    /// `EmberScope.isEnabled` at the last refresh: a disabled inspector cannot capture anything, so
    /// the refresh button would be a lie rather than a no-op.
    var isEnabled: Bool = true
    /// Refreshing while paused records nothing, so the button starts recording first.
    var isRecording: Bool = true

    var body: some View {
        if let status {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle().fill(status.isAvailable ? Color.green : Color.orange).frame(width: 10, height: 10)
                    Text(status.availability).font(.headline)
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                    GridRow { Text("Context size").foregroundStyle(.secondary); Text(ScopeFormatting.tokens(status.contextSize) + " tokens").monospacedDigit() }
                    GridRow { Text("Exact token counts").foregroundStyle(.secondary); Text(status.supportsExactTokenCounts ? "supported (26.4+; needs Apple Intelligence)" : "not supported (needs 26.4+)") }
                    GridRow { Text("Languages").foregroundStyle(.secondary); Text("\(status.supportedLanguageCount)").monospacedDigit() }
                    GridRow { Text("OS").foregroundStyle(.secondary); Text(status.osVersion) }
                }
                .font(.callout)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("Model status not captured", systemImage: "cpu")
                Text(caption).font(.caption).foregroundStyle(.secondary)
                Button(isRecording ? "Refresh model status" : "Start recording & capture status", action: refresh)
                    .disabled(!isEnabled)
            }
        }
    }

    private var caption: String {
        if !isEnabled {
            return "EmberScope is disabled in this build (ScopeConfiguration.isEnabled is false), so nothing can be captured."
        }
        return isRecording
            ? "Call EmberScope.start() at launch, or refresh now."
            : "Recording is paused, so a refresh would record nothing — this starts it first."
    }

    /// A refresh while paused used to be a silent no-op: `refreshModelStatus` records an event, and the
    /// recorder drops every event while `isRecording` is false.
    private func refresh() {
        if !isRecording { EmberScope.start() }
        EmberScope.refreshModelStatus()
    }
}
