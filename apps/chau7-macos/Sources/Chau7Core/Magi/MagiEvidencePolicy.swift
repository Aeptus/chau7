import Foundation

public struct MagiCollectorCommandReview: Equatable, Sendable {
    public var actionable: [MagiCollectorCommand]
    public var skipReasons: [String: String]

    public init(
        actionable: [MagiCollectorCommand],
        skipReasons: [String: String]
    ) {
        self.actionable = actionable
        self.skipReasons = skipReasons
    }
}

public enum MagiEvidencePolicyEvaluator {
    public static func reviewCollectorCommands(
        _ commands: [MagiCollectorCommand],
        webAccessAllowed: Bool
    ) -> MagiCollectorCommandReview {
        var actionable: [MagiCollectorCommand] = []
        var skipReasons: [String: String] = [:]

        for command in commands {
            if command.collectorKind == .unsupported {
                skipReasons[command.id] = "skipped: unsupported collector"
            } else if command.usesWeb, !webAccessAllowed {
                skipReasons[command.id] = "skipped: web disabled"
            } else {
                actionable.append(command)
            }
        }

        return MagiCollectorCommandReview(
            actionable: actionable,
            skipReasons: skipReasons
        )
    }

    public static func requestStatus(
        commandCount: Int,
        actionableCount: Int,
        policy: MagiEvidenceApprovalPolicy,
        userApproved: Bool? = nil
    ) -> MagiEvidenceRequestStatus? {
        guard commandCount > 0, actionableCount > 0 else {
            return .skipped
        }

        switch policy {
        case .ask:
            guard let userApproved else { return nil }
            return userApproved ? .approved : .denied
        case .autoDeny:
            return .denied
        case .preapproved:
            return .approved
        }
    }
}
