import SwiftUI

/// Stacked usage bar by entry kind against `contextSize`, plus the used / remaining caption.
struct ContextWindowBar: View {
    let snapshot: TranscriptSnapshot
    var compact = false

    private var segments: [(ScopeEntry.Kind, Int)] {
        ScopeEntry.Kind.allCases.map { ($0, snapshot.tokens(by: $0)) }.filter { $0.1 > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(segments, id: \.0) { kind, tokens in
                        Rectangle()
                            .fill(ScopeStyle.color(kind))
                            .frame(width: max(1, geo.size.width * CGFloat(tokens) / CGFloat(max(1, snapshot.contextSize))))
                    }
                    Spacer(minLength: 0)
                }
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
            }
            .frame(height: compact ? 6 : 12)
            if !compact {
                HStack {
                    Text("\(ScopeFormatting.tokens(snapshot.usedTokens)) / \(ScopeFormatting.tokens(snapshot.contextSize))")
                        .monospacedDigit().bold()
                        .foregroundStyle(ScopeStyle.color(fraction: snapshot.fraction))
                    Text("· \(ScopeFormatting.tokens(snapshot.remainingTokens)) remaining")
                    Spacer()
                    Text(snapshot.isExact ? "exact" : "estimated")
                        .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                .font(.callout)
                legend
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(segments, id: \.0) { kind, tokens in
                Label {
                    Text("\(ScopeStyle.label(kind).capitalized) \(ScopeFormatting.tokens(tokens))").monospacedDigit()
                } icon: {
                    Circle().fill(ScopeStyle.color(kind)).frame(width: 8, height: 8)
                }
            }
            if let tools = snapshot.toolsTokens {
                Text("· tool definitions ≈ \(ScopeFormatting.tokens(tools)) (inside instructions)")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}
