import Foundation

/// Logging hook for diagnostics emitted from Chau7Core. The Core module
/// cannot depend on the Chau7 app target (where the full `Log` enum and
/// rotating file sink live), so it exposes injectable closures that the
/// Chau7 app wires at startup. When Core is used in isolation (tests,
/// CLIs) the defaults are no-ops — no stdout spam from a unit test run.
public enum Chau7CoreLog {
    /// Warn-level diagnostics (schema drift, silent-drop candidates).
    /// Chau7 overrides this in its app init to forward to `Log.warn`.
    ///
    /// `nonisolated(unsafe)` is precise here: the stored type is already
    /// `@Sendable`, so concurrent *reads* are safe. The only mutation is the
    /// one-time override during app startup, which happens before Core is used
    /// from any other thread.
    public nonisolated(unsafe) static var warn: @Sendable (_ message: String) -> Void = { _ in }

    /// Error-level diagnostics (explicit failures that the caller handled
    /// by returning nil or throwing but wants surfaced in logs).
    /// See the note on `warn` for the annotation.
    public nonisolated(unsafe) static var error: @Sendable (_ message: String) -> Void = { _ in }
}
