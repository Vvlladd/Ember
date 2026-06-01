import SwiftUI
import FoundationChatKit

struct TokenMeterView: View {
    let budget: TokenBudgetSnapshot

    var body: some View {
        List {
            Section {
                Gauge(value: budget.fraction) {
                    Text("Context window")
                } currentValueLabel: {
                    Text("\(budget.usedTokens) / \(budget.maxTokens)").monospacedDigit()
                }
                .tint(color)
                Text("\(budget.remaining) tokens remaining" + (budget.isExact ? "" : " · estimated"))
                    .font(.caption).foregroundStyle(.secondary)
                if budget.zone != .green {
                    Label(zoneMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(budget.zone == .red ? .red : .orange)
                }
            }
            Section("Breakdown") {
                ForEach(budget.lines) { line in
                    HStack {
                        Text(line.label)
                        Spacer()
                        Text("\(line.tokens)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var zoneMessage: String {
        budget.zone == .red
            ? "Approaching the limit — older turns compact automatically."
            : "Context is filling up."
    }
    private var color: Color {
        switch budget.zone { case .green: .green; case .amber: .orange; case .red: .red }
    }
}
