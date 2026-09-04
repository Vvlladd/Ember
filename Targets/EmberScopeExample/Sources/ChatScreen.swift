import SwiftUI
import FoundationModels
import EmberScope

/// A deliberately plain chat: bubbles, a composer, two banners and a Scenarios menu. Everything
/// interesting happens in the console — this screen exists to drive it.
struct ChatScreen: View {
    let model: ChatModel
    @State private var draft = ""
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                banners
                transcript
                lookForFooter
                Divider()
                composer
            }
            .navigationTitle("EmberScope Example")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarContent }
        }
        .onChange(of: scenePhase) { _, phase in
            // The user may have switched away to enable Apple Intelligence; re-read on the way back.
            if phase == .active { model.refreshAvailability() }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Menu {
                ForEach(Scenario.allCases) { scenario in
                    Button {
                        scenario.run(on: model)
                    } label: {
                        Text(scenario.title)
                        Text(scenario.lookFor)      // menu subtitle
                    }
                }
            } label: {
                Label("Scenarios", systemImage: "list.bullet.rectangle")
            }
            // A scenario picked mid-turn would set the "Look for" hint and then have its send silently
            // dropped, advertising something the console does not contain.
            .disabled(model.isResponding)
            .help("Run a scenario, then open Ember Scope to see what it recorded")
        }
        if model.isResponding {
            ToolbarItem {
                Button { model.cancel() } label: { Label("Cancel", systemImage: "stop.circle") }
                    .help("Cancel the in-flight request")
            }
        }
        #if DEBUG
        // The only EmberScope surface in the screen, gated exactly like Ember's own toolbar button.
        ToolbarItem {
            Button { openScope() } label: { Label("Ember Scope", systemImage: "waveform.path.ecg") }
                .help("Ember Scope — sessions, requests, tools, tokens and errors of the on-device model")
        }
        #endif
    }

    #if DEBUG
    private func openScope() {
        #if os(macOS)
        openWindow(id: emberScopeWindowID)
        #else
        EmberScope.present()
        #endif
    }
    #endif

    // MARK: Banners

    @ViewBuilder
    private var banners: some View {
        if let availabilityMessage {
            banner(availabilityMessage, systemImage: "info.circle.fill", tint: .orange)
        }
        if let errorText = model.errorText {
            banner(errorText, systemImage: "exclamationmark.triangle.fill", tint: .red) {
                Button { model.dismissError() } label: { Label("Dismiss", systemImage: "xmark") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
            }
        }
    }

    /// `nil` when the model is available; otherwise the reason, in words.
    private var availabilityMessage: String? {
        switch model.availability {
        case .available:
            nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                "This device is not eligible for Apple Intelligence. Sending still works — every turn fails, and the console records the failure."
            case .appleIntelligenceNotEnabled:
                "Apple Intelligence is not enabled. Sending still works — every turn fails, and the console records the failure."
            case .modelNotReady:
                "The model is not ready yet (it may still be downloading). Sending still works — the console records whatever comes back."
            @unknown default:
                "The model is unavailable. Sending still works — the console records whatever comes back."
            }
        }
    }

    private func banner(_ text: String, systemImage: String, tint: Color,
                        @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.callout).textSelection(.enabled)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.messages.isEmpty {
                        ContentUnavailableView("Nothing sent yet",
                                               systemImage: "bubble.left.and.bubble.right",
                                               description: Text("Type a message, or pick one from the Scenarios menu, then open Ember Scope."))
                            .padding(.top, 40)
                    }
                    ForEach(model.messages) { message in
                        MessageBubble(message: message).id(message.id)
                    }
                    if model.isResponding {
                        ProgressView().padding(.top, 4).id(Self.progressID)
                    }
                }
                .padding()
            }
            .onChange(of: model.messages.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { scrollToBottom(proxy) }
            }
        }
    }

    /// While a turn is in flight the spinner is the bottom-most view, so that is what "the bottom" means.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if model.isResponding {
            proxy.scrollTo(Self.progressID, anchor: .bottom)
        } else if let last = model.messages.last?.id {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }

    private static let progressID = "responding"

    @ViewBuilder
    private var lookForFooter: some View {
        if let lookFor = model.lookFor {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "eye")
                Text("Look for: \(lookFor)")
                Spacer(minLength: 0)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Message", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(sendDraft)              // Return sends
                .disabled(model.isResponding)
            Button { sendDraft() } label: { Label("Send", systemImage: "arrow.up.circle.fill") }
                .labelStyle(.iconOnly)
                .disabled(model.isResponding || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
    }

    private func sendDraft() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !model.isResponding else { return }
        model.lookFor = nil
        model.send(text)
        draft = ""
    }
}

private struct MessageBubble: View {
    let message: ChatModel.ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            Text(message.text)
                .textSelection(.enabled)
                // The over-budget scenario sends ~34 KB. Rendering all of it, selectable and with an
                // animated scroll on top, makes the demo's most spectacular scenario its jankiest.
                .lineLimit(isUser ? 12 : nil)
                .truncationMode(.tail)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.14),
                            in: .rect(cornerRadius: 14))
            if !isUser { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}
