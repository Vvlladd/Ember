import SwiftUI

struct ModelStatusCard: View {
    let status: ModelStatus?

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
                Text("Call EmberScope.start() at launch, or refresh now.").font(.caption).foregroundStyle(.secondary)
                Button("Refresh model status") { EmberScope.refreshModelStatus() }
            }
        }
    }
}
