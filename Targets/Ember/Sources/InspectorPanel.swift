import SwiftUI
import FoundationChatKit

struct InspectorPanel: View {
    let engine: ConversationEngine
    @State private var tab: Tab = .context

    enum Tab: String, CaseIterable, Identifiable {
        case context = "Context", tokens = "Tokens"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()
            Divider()
            switch tab {
            case .context: ContextInspectorView(entries: engine.contextEntries)
            case .tokens: TokenMeterView(budget: engine.budget, reservedReplyTokens: engine.reservedReplyTokens)
            }
        }
    }
}
