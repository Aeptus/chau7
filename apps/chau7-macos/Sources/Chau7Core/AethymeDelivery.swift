import Foundation

public enum AethymeDeliveryPolicy: String, Codable, Sendable {
    case notify
    case resume
    case reviewAndPush = "review_and_push"
}

public struct AethymeDeliveryTarget: Equatable, Sendable {
    public let tabID: String
    public let aiSessionID: String

    public init(tabID: String, aiSessionID: String) {
        self.tabID = tabID
        self.aiSessionID = aiSessionID
    }

    public init?(opaqueValue: String) {
        guard let components = URLComponents(string: opaqueValue),
              components.scheme == "chau7",
              components.host == "tab" else {
            return nil
        }
        let tabID = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let sessionID = components.queryItems?.first(where: { $0.name == "session" })?.value ?? ""
        guard !tabID.isEmpty, !sessionID.isEmpty else { return nil }
        self.init(tabID: tabID, aiSessionID: sessionID)
    }

    public var opaqueValue: String {
        var components = URLComponents()
        components.scheme = "chau7"
        components.host = "tab"
        components.path = "/\(tabID)"
        components.queryItems = [URLQueryItem(name: "session", value: aiSessionID)]
        return components.string ?? ""
    }
}

public struct AethymeDeliveryTabSnapshot: Equatable, Sendable {
    public let tabID: String
    public let aiSessionID: String?
    public let aiProvider: String?
    public let repositoryRoot: String?
    public let status: String
    public let isAtPrompt: Bool
    public let hasPendingInput: Bool

    public init(
        tabID: String,
        aiSessionID: String?,
        aiProvider: String?,
        repositoryRoot: String?,
        status: String,
        isAtPrompt: Bool,
        hasPendingInput: Bool
    ) {
        self.tabID = tabID
        self.aiSessionID = aiSessionID
        self.aiProvider = aiProvider
        self.repositoryRoot = repositoryRoot
        self.status = status
        self.isAtPrompt = isAtPrompt
        self.hasPendingInput = hasPendingInput
    }
}

public enum AethymeDeliveryReadiness: Equatable, Sendable {
    case ready
    case retry(errorCode: String)
    case failed(errorCode: String)
}

public enum AethymeDeliveryReadinessPolicy {
    public static func evaluate(
        target: AethymeDeliveryTarget,
        tab: AethymeDeliveryTabSnapshot?,
        repositoryRoot: String
    ) -> AethymeDeliveryReadiness {
        guard let tab else { return .retry(errorCode: "target_tab_missing") }
        guard tab.tabID == target.tabID else { return .failed(errorCode: "target_tab_mismatch") }
        guard tab.aiSessionID == target.aiSessionID else {
            return .failed(errorCode: "target_session_mismatch")
        }
        guard canonicalPath(tab.repositoryRoot) == canonicalPath(repositoryRoot) else {
            return .failed(errorCode: "target_repository_mismatch")
        }
        guard let provider = tab.aiProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
              !provider.isEmpty else {
            return .retry(errorCode: "target_agent_unavailable")
        }
        guard tab.status == "idle" || tab.status == "done" else {
            return .retry(errorCode: "target_tab_busy")
        }
        guard tab.isAtPrompt else { return .retry(errorCode: "target_not_at_prompt") }
        guard !tab.hasPendingInput else { return .retry(errorCode: "target_has_pending_input") }
        return .ready
    }

    private static func canonicalPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

public struct AethymePullRequestWatch: Codable, Sendable {
    public let id: Int64
    public let status: String
    public let nextPollAt: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case nextPollAt = "next_poll_at"
    }
}

public struct AethymeDeliveryClaimReport: Codable, Sendable {
    public let adapter: String
    public let worker: String
    public let delivery: AethymeDeliveryEnvelope?
}

public struct AethymeDeliveryEnvelope: Codable, Sendable {
    public let item: AethymeDeliveryOutboxItem
    public let subscription: AethymeDeliverySubscription
    public let watch: AethymeDeliveryWatch
    public let batch: AethymeDeliveryBatch
    public let prompt: String
}

public struct AethymeDeliveryOutboxItem: Codable, Sendable {
    public let id: Int64
    public let generation: Int64
}

public struct AethymeDeliverySubscription: Codable, Sendable {
    public let id: Int64
    public let target: String
    public let policy: AethymeDeliveryPolicy
}

public struct AethymeDeliveryWatch: Codable, Sendable {
    public let id: Int64
    public let canonicalRepository: String
    public let prNumber: Int64
    public let headSHA: String

    enum CodingKeys: String, CodingKey {
        case id
        case canonicalRepository = "canonical_repository"
        case prNumber = "pr_number"
        case headSHA = "head_sha"
    }
}

public struct AethymeDeliveryBatch: Codable, Sendable {
    public let id: Int64
    public let headSHA: String

    enum CodingKeys: String, CodingKey {
        case id
        case headSHA = "head_sha"
    }
}

public enum AethymeDeliveryCommand {
    public static func listWatches() -> [String] {
        ["broker", "watch", "pr", "list", "--json"]
    }

    public static func pollWatch(id: Int64) -> [String] {
        ["broker", "watch", "pr", "poll", "--id", String(id), "--json"]
    }

    public static func claim(worker: String, seconds: Int = 120) -> [String] {
        [
            "broker", "deliveries", "claim", "--adapter", "chau7",
            "--worker", worker, "--seconds", String(seconds), "--json"
        ]
    }

    public static func complete(
        id: Int64,
        worker: String,
        generation: Int64,
        outcome: String,
        errorCode: String? = nil
    ) -> [String] {
        var arguments = [
            "broker", "deliveries", "complete", "--id", String(id),
            "--worker", worker, "--generation", String(generation),
            "--outcome", outcome
        ]
        if let errorCode {
            arguments.append(contentsOf: ["--error-code", errorCode])
        }
        arguments.append("--json")
        return arguments
    }
}
