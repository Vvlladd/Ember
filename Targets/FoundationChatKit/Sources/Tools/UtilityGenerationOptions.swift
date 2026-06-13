import FoundationModels

/// Deterministic, length-capped `GenerationOptions` for Ember's single-shot utility sessions
/// (title, fact extraction, summary). These run off the chat hot path and want stable,
/// reproducible output — never creative sampling.
///
/// Determinism: the sessions request `.greedy` sampling (verified API: a `static let` on
/// `GenerationOptions.SamplingMode`) for true argmax decoding, AND set `temperature: 0` so the
/// intent is explicit and portable even if a future overlay treats greedy differently.
/// Length: `maximumResponseTokens` keeps each utility reply tight (Apple warns against
/// over-capping, so values leave headroom for the structured payloads these produce).
enum UtilityGenerationOptions {
    /// 3–5 word title — very tight cap.
    static let title = GenerationOptions(sampling: .greedy, temperature: 0, maximumResponseTokens: 24)
    /// Up to ~5 short third-person facts — small cap.
    static let extraction = GenerationOptions(sampling: .greedy, temperature: 0, maximumResponseTokens: 256)
    /// A few-sentence recap — modest cap.
    static let summary = GenerationOptions(sampling: .greedy, temperature: 0, maximumResponseTokens: 320)
}
