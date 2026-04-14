import Foundation

public struct TabExecutionReadinessSnapshot: Sendable, Equatable {
    public let shellLoading: Bool
    public let isAtPrompt: Bool
    public let hasView: Bool
    public let status: String

    public init(
        shellLoading: Bool,
        isAtPrompt: Bool,
        hasView: Bool,
        status: String
    ) {
        self.shellLoading = shellLoading
        self.isAtPrompt = isAtPrompt
        self.hasView = hasView
        self.status = status
    }
}

public struct TabExecutionReadiness: Sendable, Equatable {
    public enum Reason: String, Sendable {
        case ready
        case exited
        case shellLoading = "shell_loading"
        case viewUnattached = "view_unattached"
        case notAtPrompt = "not_at_prompt"
    }

    public let isReady: Bool
    public let reason: Reason

    public init(isReady: Bool, reason: Reason) {
        self.isReady = isReady
        self.reason = reason
    }

    public static func evaluate(snapshot: TabExecutionReadinessSnapshot) -> TabExecutionReadiness {
        let normalizedStatus = snapshot.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedStatus == "exited" {
            return TabExecutionReadiness(isReady: false, reason: .exited)
        }
        if snapshot.shellLoading {
            return TabExecutionReadiness(isReady: false, reason: .shellLoading)
        }
        if !snapshot.hasView {
            return TabExecutionReadiness(isReady: false, reason: .viewUnattached)
        }
        if !snapshot.isAtPrompt {
            return TabExecutionReadiness(isReady: false, reason: .notAtPrompt)
        }
        return TabExecutionReadiness(isReady: true, reason: .ready)
    }
}
