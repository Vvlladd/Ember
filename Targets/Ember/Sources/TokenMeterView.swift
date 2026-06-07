import SwiftUI
import FoundationChatKit

struct TokenMeterView: View {
    let budget: TokenBudgetSnapshot
    var reservedReplyTokens: Int = 0
    var breakdown: TokenBreakdown? = nil

    var body: some View {
        List {
            Section {
                Gauge(value: budget.fraction) {
                    Text("Context window")
                } currentValueLabel: {
                    Text("\(budget.usedTokens) / \(budget.maxTokens)").monospacedDigit()
                }
                .tint(meterColor)
                Text("\(budget.remaining) tokens remaining" + (budget.isExact ? "" : " · estimated"))
                    .font(.caption).foregroundStyle(.secondary)
                if reservedReplyTokens > 0 {
                    Text("Reserved for reply: \(reservedReplyTokens)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if budget.zone != .green {
                    Label(zoneMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(budget.zone == .red ? .red : .orange)
                }
            }
            if let breakdown {
                Section("Where tokens go") {
                    breakdownRow("Instructions", breakdown.instructions)
                    breakdownRow("Tools", breakdown.tools)
                    breakdownRow("History", breakdown.history)
                    breakdownRow("Retrieved memory", breakdown.retrievedMemory)
                    breakdownRow("Reserved for reply", breakdown.replyReserve)
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

    private func breakdownRow(_ label: String, _ tokens: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(tokens)").monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private var zoneMessage: String {
        budget.zone == .red
            ? "Approaching the limit — older turns compact automatically."
            : "Context is filling up."
    }

    /// 4-tier gauge color derived from the pure FoundationChatKit bucket.
    /// The warning banner above intentionally keeps the 3-tier budget.zone threshold
    /// (coarser, only warns near the limit). The gauge uses the finer 4-tier tint.
    private var meterColor: Color {
        switch TokenMeterColor.for(fraction: budget.fraction) {
        case .green: return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .red: return .red
        }
    }
}
