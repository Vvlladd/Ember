import Foundation
import FoundationModels
import Observation
import EmberScope

/// The whole app, minus the views: one `InspectedSession`, a list of bubbles, and the four things a
/// scenario can ask for (stream, structured turn, cancel, new session). Nothing is persisted.
///
/// Sending is allowed even when the model is unavailable — the failure path is part of what the example
/// demonstrates. On a machine without Apple Intelligence every turn ends in a `GenerationError` chain, and
/// the inspector still shows the session, the prompt, the request and the context snapshot.
@MainActor
@Observable
final class ChatModel {
    struct ChatMessage: Identifiable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
    }

    /// The one line of integration an adopter copies. Recreated by `resetSession()`, which is why it is a
    /// `var`: each new value is a new session row in the inspector, and the old one keeps its history.
    private(set) var session: InspectedSession
    private(set) var messages: [ChatMessage] = []
    private(set) var isResponding = false
    /// The raw `String(describing:)` of whatever was thrown. The inspector shows the classified version
    /// (kind, debug description, recovery suggestion, underlying chain); this banner is the app's own view.
    var errorText: String?
    private(set) var availability: SystemLanguageModel.Availability
    /// What the developer should go and look for in the console after the last scenario.
    var lookFor: String?

    /// The in-flight turn, so `cancel()` has something to cancel.
    private var turn: Task<Void, Never>?
    /// Bumped when a turn starts and again when the session is replaced. Task cancellation is cooperative,
    /// so a cancelled turn is still alive, still holding its `update` closure and still owing an
    /// `endTurn()`; everything it writes is gated on the id it captured, so it can never touch the next
    /// turn's bubble, `errorText`, `isResponding` or `turn`.
    private var turnID = 0
    /// The `cancelMidStream` scenario's poller. Stored so it dies with the session, and pinned to a turn
    /// id so it can only ever cancel the turn it was started for.
    private var canceller: Task<Void, Never>?

    static let instructions = """
        You are the assistant in a tiny demo app. Answer briefly — a couple of sentences at most unless \
        the user asks for more. Use the calculator tool for arithmetic, the clock tool for the current \
        date and time, and the flaky tool only when the user asks for it by name.
        """

    /// Fixed so the `structured` scenario and its prompt cannot drift apart. `nonisolated` because
    /// `Scenario.prompt` reads it from outside the main actor.
    nonisolated static let structuredPrompt = "Tell me about Lisbon, Portugal."

    init() {
        self.session = Self.makeSession()
        self.availability = SystemLanguageModel.default.availability
    }

    private static func makeSession() -> InspectedSession {
        EmberScope.session(tools: [CalculatorTool(), ClockTool(), FlakyTool()],
                           instructions: Self.instructions,
                           label: "example")
    }

    // MARK: Turns

    /// Streams a reply, replacing the trailing assistant bubble with each snapshot. The `String` overload
    /// is deliberate: it hands the prompt text to the inspector up front, so a failed or cancelled request
    /// still shows what was asked (a `Prompt` value only recovers its text on success).
    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        beginTurn(userText: prompt) { [session] update in
            for try await snapshot in session.streamResponse(to: prompt) {
                update(snapshot.content)
            }
        }
    }

    /// One guided-generation turn. The request's response format shows up in the console as `CityFacts`.
    func sendStructured() {
        let prompt = Self.structuredPrompt
        beginTurn(userText: prompt) { [session] update in
            let response = try await session.respond(to: prompt, generating: CityFacts.self)
            update(Self.render(response.content))
        }
    }

    /// Cancels the in-flight turn. The console records the request as cancelled, with no error row.
    func cancel() {
        turn?.cancel()
    }

    /// Sends `text`, then cancels *that* turn once its first snapshot lands. The deadline is the escape
    /// hatch for a machine with no Apple Intelligence, where no snapshot ever arrives — by then the turn
    /// has already failed and `cancel()` is a no-op, which is the honest outcome to show.
    func sendCancellingMidStream(_ text: String) {
        send(text)
        guard isResponding else { return }
        let id = turnID
        canceller?.cancel()
        canceller = Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(3)
            while let model = self, model.turnID == id, model.isResponding,
                  model.messages.last?.text.isEmpty ?? true, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let model = self, model.turnID == id else { return }
            model.cancel()
        }
    }

    /// A brand-new session: a second session row in the console, with its own instructions, tools and
    /// context snapshot. The previous one stays in the console with everything it captured.
    func resetSession() {
        cancel()
        canceller?.cancel()
        canceller = nil
        // After the cancel, so whatever is still winding down now belongs to a turn that no longer exists.
        turnID += 1
        turn = nil
        isResponding = false
        session = Self.makeSession()
        messages.removeAll()
        errorText = nil
    }

    /// Re-read availability — call it when the app comes back to the foreground, since the user may have
    /// enabled Apple Intelligence in Settings meanwhile. The console gets a fresh model-status card too.
    func refreshAvailability() {
        availability = SystemLanguageModel.default.availability
        #if DEBUG
        EmberScope.refreshModelStatus()
        #endif
    }

    func dismissError() { errorText = nil }

    // MARK: Turn plumbing

    /// Appends the user bubble plus an empty assistant bubble, runs `body`, and always ends the turn.
    /// `body` receives a callback that rewrites the trailing assistant bubble.
    private func beginTurn(userText: String,
                           _ body: @escaping @MainActor ((String) -> Void) async throws -> Void) {
        guard !isResponding else { return }
        turnID += 1
        let id = turnID
        errorText = nil
        messages.append(ChatMessage(role: .user, text: userText))
        messages.append(ChatMessage(role: .assistant, text: ""))
        isResponding = true
        turn = Task { @MainActor [weak self] in
            do {
                try await body { [weak self] text in self?.updateLastAssistantMessage(text, turn: id) }
            } catch {
                // Everything is caught: a demo that crashes teaches nothing, and the interesting part of
                // a failure is what the console made of it.
                if let self, self.turnID == id { self.errorText = String(describing: error) }
            }
            self?.endTurn(id)
        }
    }

    private func updateLastAssistantMessage(_ text: String, turn id: Int) {
        guard turnID == id, let last = messages.indices.last, messages[last].role == .assistant else { return }
        messages[last].text = text
    }

    private func endTurn(_ id: Int) {
        guard turnID == id else { return }
        if let last = messages.indices.last, messages[last].role == .assistant, messages[last].text.isEmpty {
            messages[last].text = errorText == nil ? "(no output)" : "(no output — see the error below)"
        }
        isResponding = false
        turn = nil
    }

    private static func render(_ facts: CityFacts) -> String {
        """
        \(facts.name), \(facts.country)
        Population: \(facts.population.formatted())
        \(facts.oneLineFact)
        """
    }
}
