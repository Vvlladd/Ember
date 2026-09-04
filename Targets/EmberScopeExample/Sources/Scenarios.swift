import Foundation

/// One button per inspector path worth seeing. Each scenario names what the developer should go and look
/// for in the console afterwards, so the demo is self-explaining rather than a wall of prompts.
///
/// On a machine without Apple Intelligence every scenario ends in a classified `GenerationError` instead of
/// a reply — and that is still a useful run: the session, its tools, the prompt, the request and the context
/// snapshot are all recorded, and the Errors tab shows the full underlying chain.
enum Scenario: CaseIterable, Identifiable {
    case calculator
    case clock
    case longAnswer
    case cancelMidStream
    case structured
    case toolFailure
    case overBudget
    case newSession

    var id: Self { self }

    var title: String {
        switch self {
        case .calculator: "Calculator tool"
        case .clock: "Clock tool"
        case .longAnswer: "Long streamed answer"
        case .cancelMidStream: "Cancel mid-stream"
        case .structured: "Structured output"
        case .toolFailure: "Tool failure"
        case .overBudget: "Over budget"
        case .newSession: "New session"
        }
    }

    /// The text sent to the model. `nil` for `newSession`, which sends nothing — it replaces the session.
    var prompt: String? {
        switch self {
        case .calculator: "What is 4892 * 1773? Use the calculator."
        case .clock: "What time is it right now? Use the clock tool."
        case .longAnswer, .cancelMidStream: Self.longPrompt
        case .structured: ChatModel.structuredPrompt
        case .toolFailure: "Call the flaky tool with the input 'demo'."
        case .overBudget: Self.overBudgetPrompt
        case .newSession: nil
        }
    }

    /// One sentence: what this scenario puts in the console.
    var lookFor: String {
        switch self {
        case .calculator:
            "A calculator tool call under the request in Session detail, with its arguments, result and duration."
        case .clock:
            "A clock tool call under the request, and the clock's call count and mean duration in the Tools tab."
        case .longAnswer:
            "The request's chunk count and time-to-first-token, and the context-window bar growing in Session detail."
        case .cancelMidStream:
            "A request whose status is cancelled — and no error row for it."
        case .structured:
            "A request whose response format is CityFacts, with the guided-generation schema alongside it."
        case .toolFailure:
            "Two rows in the Errors tab: the flaky tool's own failure, and the request error that carries it."
        case .overBudget:
            "A context snapshot over budget (the bar turns red) and an exceededContextWindowSize error."
        case .newSession:
            "A second session row labelled example; the first one keeps everything it captured."
        }
    }

    @MainActor
    func run(on model: ChatModel) {
        model.lookFor = lookFor
        switch self {
        case .newSession:
            model.resetSession()
            model.lookFor = lookFor      // resetSession clears the screen, so restate the hint
        case .structured:
            model.sendStructured()
        case .cancelMidStream:
            // The poller lives on the model, which owns the turn it is allowed to cancel.
            model.sendCancellingMidStream(Self.longPrompt)
        default:
            if let prompt { model.send(prompt) }
        }
    }

    static let longPrompt =
        "Explain how an on-device language model manages a 4,096-token context window, in five short paragraphs."

    /// ~6,000 words — comfortably past a 4,096-token window, so the context snapshot goes over budget.
    static let overBudgetPrompt: String = {
        let paragraph = """
            The context window is the fixed budget of tokens a language model can attend to at once, and \
            everything the model knows about this conversation has to fit inside it: the instructions, the \
            tool definitions, every earlier turn, and the reply it is about to write.
            """
        let wordsPerParagraph = paragraph.split(whereSeparator: \.isWhitespace).count
        let repeats = max(1, Int((6_000.0 / Double(wordsPerParagraph)).rounded(.up)))
        return "Summarise these notes in one sentence.\n\n"
            + Array(repeating: paragraph, count: repeats).joined(separator: " ")
    }()
}
