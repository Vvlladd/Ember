import Foundation

/// EmberScope — an in-app inspector for Apple Foundation Models.
///
/// The facade is a namespace; all mutable state lives in `recorder` (thread-safe) and `store` (main actor).
public enum EmberScope {
    /// The process-wide event log every wrapper records into by default.
    public static let recorder = ScopeRecorder()
}
