import SwiftUI

/// Stacked usage bar by entry kind against `contextSize`, plus the used / remaining caption.
struct ContextWindowBar: View {
    let snapshot: TranscriptSnapshot
    var compact = false

    private var segments: [(ScopeEntry.Kind, Int)] {
        ScopeEntry.Kind.allCases.map { ($0, snapshot.tokens(by: $0)) }.filter { $0.1 > 0 }
    }

    /// An overflowing transcript is exactly what the inspector exists to show: normalize by whichever is
    /// larger — the window, or what is in it — so the segments never paint past the track.
    private var scale: Int { max(1, snapshot.contextSize, snapshot.usedTokens) }
    /// Drives the red caption. `fraction` cannot: it clamps at 1, and reads 0 when `contextSize` is unknown.
    private var isOverBudget: Bool { snapshot.usedTokens > snapshot.contextSize }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(segments, id: \.0) { kind, tokens in
                        Rectangle()
                            .fill(ScopeStyle.color(kind))
                            .frame(width: max(1, geo.size.width * CGFloat(tokens) / CGFloat(scale)))
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
                        .foregroundStyle(isOverBudget ? ScopeStyle.error : ScopeStyle.color(fraction: snapshot.fraction))
                    // "0 remaining" reads like a coincidence; "N over" is the fact.
                    Text(isOverBudget
                         ? "· \(ScopeFormatting.tokens(snapshot.usedTokens - snapshot.contextSize)) over"
                         : "· \(ScopeFormatting.tokens(snapshot.remainingTokens)) remaining")
                    Spacer()
                    Text(snapshot.isExact ? "exact" : "estimated")
                        .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                .font(.callout)
                legend
            }
        }
        // The bar is a picture of a number: VoiceOver would otherwise read a stack of unlabelled
        // rectangles (compact mode has no caption at all).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context window")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(isOverBudget ? "Over budget by \(snapshot.usedTokens - snapshot.contextSize) tokens" : "")
    }

    private var accessibilityValue: String {
        let counts = snapshot.isExact ? "" : ", estimated"
        return "\(snapshot.usedTokens) of \(snapshot.contextSize) tokens used\(counts)"
    }

    /// A five-kind transcript plus the tool-definition note overflows any single-line `HStack`, so the
    /// legend wraps instead.
    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)],
                  alignment: .leading, spacing: 4) {
            ForEach(segments, id: \.0) { kind, tokens in
                Label {
                    Text("\(ScopeStyle.label(kind).capitalized) \(ScopeFormatting.tokens(tokens))").monospacedDigit()
                } icon: {
                    Circle().fill(ScopeStyle.color(kind)).frame(width: 8, height: 8)
                }
            }
            if let tools = snapshot.toolsTokens {
                Text(snapshot.toolSchemasIncluded
                     ? "tool definitions ≈ \(ScopeFormatting.tokens(tools)) (inside instructions)"
                     : "tool definitions ≥ \(ScopeFormatting.tokens(tools)) (inside instructions; schemas unavailable)")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}
