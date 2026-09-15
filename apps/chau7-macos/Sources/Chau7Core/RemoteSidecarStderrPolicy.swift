import Foundation

public enum RemoteSidecarStderrDisposition: Equatable, Sendable {
    case suppress
    case info
    case warning
}

/// Converts the Go helper's stderr transport into operational severity.
/// Go's standard logger writes every message to stderr, including successful
/// lifecycle transitions, so the file descriptor alone cannot imply failure.
public enum RemoteSidecarStderrPolicy {
    public static func disposition(for rawLine: String) -> RemoteSidecarStderrDisposition {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return .suppress }

        if line.contains("MallocStackLogging: can't turn off malloc stack logging because it was not enabled") {
            return .suppress
        }

        let informationalFragments = [
            "relay disconnected, reconnecting in",
            "ipc disconnected, reconnecting in",
            "ipc connected: replayed",
            "ipc read: shutting down"
        ]
        if informationalFragments.contains(where: line.contains) {
            return .info
        }

        return .warning
    }
}
