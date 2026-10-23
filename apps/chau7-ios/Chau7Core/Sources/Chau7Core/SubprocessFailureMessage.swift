#if os(macOS)
import Foundation

/// Turns a `SubprocessRunner.Result` into a user-facing failure string.
///
/// Extracted from `RemoteAgentBinaryProvider`, which previously merged a
/// child's stdout and stderr into a single `Pipe` and therefore had a single
/// merged text to report. `SubprocessRunner.capture` keeps the streams
/// separate, so reconstructing the merged text — and the precedence between
/// "timed out", "could not launch", and "exited non-zero" — is real logic that
/// deserves to be pure and tested rather than buried in a view-adjacent type.
public enum SubprocessFailureMessage {
    /// Returns `nil` when the command completed successfully, otherwise a
    /// message suitable for display.
    ///
    /// - Parameters:
    ///   - result: The capture result, or `nil` when the process never launched.
    ///   - notLaunchedMessage: Message for a `nil` result.
    ///   - timedOutMessage: Message for a deadline trip.
    ///   - missingToolMessage: Message for a failure with no diagnostic output.
    public static func describe(
        _ result: SubprocessRunner.Result?,
        notLaunchedMessage: String,
        timedOutMessage: String,
        missingToolMessage: String
    ) -> String? {
        guard let result else { return notLaunchedMessage }

        if result.timedOut { return timedOutMessage }
        if result.completed, result.status == 0 { return nil }

        let combined = mergedOutput(result)

        // A read failure is checked BEFORE the empty-output case, and this
        // ordering is deliberate. "We could not read the child's output" and
        // "the child produced no output" are different diagnoses, and the
        // second is the shape of a missing toolchain. Reporting the former as
        // the latter sends the reader down the wrong path entirely. An earlier
        // revision checked emptiness first and did exactly that.
        if result.readFailed {
            return "Failed to read command output: \(combined.isEmpty ? missingToolMessage : combined)"
        }
        if result.outputLimitExceeded {
            // The diagnostic text is itself truncated, so say so rather than
            // presenting a partial error as a complete one.
            return "Output was too large to report fully: \(combined)"
        }
        if combined.isEmpty { return missingToolMessage }
        return "Command failed: \(combined)"
    }

    /// stdout and stderr were historically delivered through one pipe, so the
    /// diagnostic text is re-joined with streams in that order and blanks
    /// dropped. Both halves are trimmed so a trailing newline never leaks into
    /// the message.
    public static func mergedOutput(_ result: SubprocessRunner.Result) -> String {
        [result.stdout, result.stderr]
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
#endif
