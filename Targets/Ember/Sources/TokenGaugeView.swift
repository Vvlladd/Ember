import SwiftUI
import FoundationChatKit

struct TokenGaugeView: View {
    let budget: TokenBudgetSnapshot

    var body: some View {
        HStack(spacing: 6) {
            Gauge(value: budget.fraction) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(color)
                .frame(width: 90)
            Text("\(budget.usedTokens)/\(budget.maxTokens)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help("\(budget.remaining) tokens remaining" + (budget.isExact ? "" : " (estimated)"))
    }

    private var color: Color {
        switch budget.zone { case .green: .green; case .amber: .orange; case .red: .red }
    }
}
