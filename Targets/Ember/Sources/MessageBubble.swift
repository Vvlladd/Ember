import SwiftUI
import FoundationChatKit

struct MessageBubble: View {
    @Environment(\.layoutDirection) private var layoutDirection
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .systemNotice:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        case .user:
            row(trailing: true, background: Color.accentColor.opacity(0.18)) {
                Text(message.text.isEmpty ? "…" : message.text).textSelection(.enabled)
            }
        case .assistant:
            row(
                trailing: false,
                background: Color.secondary.opacity(0.12),
                showsProgress: !(message.isStreaming && message.text.isEmpty)
            ) {
                if message.isStreaming && message.text.isEmpty {
                    TypingIndicator()
                } else if message.text.isEmpty {
                    Text("…")
                } else {
                    MarkdownText(text: message.text)
                }
            }
        }
    }

    private func row<Content: View>(trailing: Bool, background: Color,
                                    showsProgress: Bool = true,
                                    @ViewBuilder content: () -> Content) -> some View {
        let tailSide = tailSide(forTrailing: trailing)

        return HStack {
            if tailSide == .right { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 6) {
                content()
                if message.isStreaming && showsProgress { ProgressView().controlSize(.small) }
            }
            .padding(.vertical, 10)
            .padding(.leading, tailSide == .left ? 20 : 12)
            .padding(.trailing, tailSide == .right ? 20 : 12)
            .background(background, in: ChatBubbleShape(tailSide: tailSide))
            if tailSide == .left { Spacer(minLength: 48) }
        }
    }

    private func tailSide(forTrailing trailing: Bool) -> ChatBubbleTailSide {
        trailing == (layoutDirection == .leftToRight) ? .right : .left
    }
}

private enum ChatBubbleTailSide {
    case left
    case right
}

private struct ChatBubbleShape: Shape {
    let tailSide: ChatBubbleTailSide

    func path(in rect: CGRect) -> Path {
        let tailWidth = min(5, rect.width * 0.06)
        let bubbleRect = tailSide == .right
            ? CGRect(x: rect.minX, y: rect.minY, width: rect.width - tailWidth, height: rect.height)
            : CGRect(x: rect.minX + tailWidth, y: rect.minY, width: rect.width - tailWidth, height: rect.height)
        let radius = min(18, bubbleRect.height / 2)
        let tailHeight = min(6, bubbleRect.height * 0.18)
        let tailStartY = bubbleRect.maxY - tailHeight
        let tailReturnOffset = min(radius * 0.32, 5)

        var path = Path()
        if tailSide == .right {
            path.move(to: CGPoint(x: bubbleRect.minX + radius, y: bubbleRect.minY))
            path.addLine(to: CGPoint(x: bubbleRect.maxX - radius, y: bubbleRect.minY))
            path.addQuadCurve(to: CGPoint(x: bubbleRect.maxX, y: bubbleRect.minY + radius),
                              control: CGPoint(x: bubbleRect.maxX, y: bubbleRect.minY))
            path.addLine(to: CGPoint(x: bubbleRect.maxX, y: tailStartY))
            path.addCurve(to: CGPoint(x: rect.maxX - 1, y: bubbleRect.maxY - 1),
                          control1: CGPoint(x: bubbleRect.maxX + tailWidth * 0.45, y: tailStartY + 1),
                          control2: CGPoint(x: rect.maxX - 1, y: bubbleRect.maxY - 5))
            path.addCurve(to: CGPoint(x: bubbleRect.maxX - tailReturnOffset, y: bubbleRect.maxY),
                          control1: CGPoint(x: rect.maxX - 2, y: bubbleRect.maxY + 1),
                          control2: CGPoint(x: bubbleRect.maxX - 2, y: bubbleRect.maxY))
            path.addLine(to: CGPoint(x: bubbleRect.minX + radius, y: bubbleRect.maxY))
            path.addQuadCurve(to: CGPoint(x: bubbleRect.minX, y: bubbleRect.maxY - radius),
                              control: CGPoint(x: bubbleRect.minX, y: bubbleRect.maxY))
            path.addLine(to: CGPoint(x: bubbleRect.minX, y: bubbleRect.minY + radius))
            path.addQuadCurve(to: CGPoint(x: bubbleRect.minX + radius, y: bubbleRect.minY),
                              control: CGPoint(x: bubbleRect.minX, y: bubbleRect.minY))
        } else {
            path.move(to: CGPoint(x: bubbleRect.minX + radius, y: bubbleRect.minY))
            path.addLine(to: CGPoint(x: bubbleRect.maxX - radius, y: bubbleRect.minY))
            path.addQuadCurve(to: CGPoint(x: bubbleRect.maxX, y: bubbleRect.minY + radius),
                              control: CGPoint(x: bubbleRect.maxX, y: bubbleRect.minY))
            path.addLine(to: CGPoint(x: bubbleRect.maxX, y: bubbleRect.maxY - radius))
            path.addQuadCurve(to: CGPoint(x: bubbleRect.maxX - radius, y: bubbleRect.maxY),
                              control: CGPoint(x: bubbleRect.maxX, y: bubbleRect.maxY))
            path.addLine(to: CGPoint(x: bubbleRect.minX + tailReturnOffset, y: bubbleRect.maxY))
            path.addCurve(to: CGPoint(x: rect.minX + 1, y: bubbleRect.maxY - 1),
                          control1: CGPoint(x: bubbleRect.minX + 2, y: bubbleRect.maxY),
                          control2: CGPoint(x: rect.minX + 2, y: bubbleRect.maxY + 1))
            path.addCurve(to: CGPoint(x: bubbleRect.minX, y: tailStartY),
                          control1: CGPoint(x: rect.minX + 1, y: bubbleRect.maxY - 5),
                          control2: CGPoint(x: bubbleRect.minX - tailWidth * 0.45, y: tailStartY + 1))
            path.addLine(to: CGPoint(x: bubbleRect.minX, y: bubbleRect.minY + radius))
            path.addQuadCurve(to: CGPoint(x: bubbleRect.minX + radius, y: bubbleRect.minY),
                              control: CGPoint(x: bubbleRect.minX, y: bubbleRect.minY))
        }
        path.closeSubpath()

        return path
    }
}

private struct TypingIndicator: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 5, height: 5)
                    .scaleEffect(isAnimating ? 1 : 0.72)
                    .opacity(isAnimating ? 1 : 0.35)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.16),
                        value: isAnimating
                    )
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Assistant is typing")
        .accessibilityValue("In progress")
        .onAppear {
            isAnimating = true
        }
    }
}
