import Foundation
import os

/// Central diagnostic logging for the memory / RAG pipeline.
///
/// Use `os.Logger` (Unified Logging) so logs are visible in Console.app and `log stream` while the
/// app runs on device or simulator — no debugger attach required. Values are interpolated with
/// `privacy: .public` ON PURPOSE here: this is opt-in debugging instrumentation and the whole point
/// is to see *what* memory is retrieved / extracted / dropped. It logs short user-derived strings
/// (queries, saved facts, hit text); keep that in mind on a privacy-first app and gate or remove
/// this layer before shipping if that is a concern.
///
/// Filter in Console / terminal by subsystem:
///   log stream --predicate 'subsystem == "com.ember.FoundationChatKit"' --info --debug
public enum EmberLog {
    public static let subsystem = "com.ember.FoundationChatKit"

    /// Embedder lifecycle (is `NLEmbedding` even available on this device?).
    public static let embed = Logger(subsystem: subsystem, category: "Embed")
    /// Snapshot building + note persistence + de-dup decisions.
    public static let memory = Logger(subsystem: subsystem, category: "Memory")
    /// Per-turn retrieve-before-generate (query, hits, scores vs threshold).
    public static let retrieval = Logger(subsystem: subsystem, category: "Retrieval")
    /// Post-turn automatic fact extraction.
    public static let extraction = Logger(subsystem: subsystem, category: "Extraction")
    /// Turn lifecycle + errors surfaced to the user.
    public static let turn = Logger(subsystem: subsystem, category: "Turn")
}
