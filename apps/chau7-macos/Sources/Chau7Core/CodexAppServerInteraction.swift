import Foundation

public struct CodexAppServerInteraction: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case userInput
        case approval
    }

    public enum Phase: String, Codable, Sendable {
        case requested
        case resolved
    }

    public let requestID: String
    public let kind: Kind?
    public let phase: Phase
    public let threadID: String?
    public let turnID: String?
    public let prompt: CodexFeedbackPrompt?

    public init(
        requestID: String,
        kind: Kind?,
        phase: Phase,
        threadID: String? = nil,
        turnID: String? = nil,
        prompt: CodexFeedbackPrompt? = nil
    ) {
        self.requestID = requestID
        self.kind = kind
        self.phase = phase
        self.threadID = threadID
        self.turnID = turnID
        self.prompt = prompt
    }
}

public enum CodexAppServerInteractionParser {
    public static func parse(line: String) -> CodexAppServerInteraction? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = nonEmptyString(root["method"]) else {
            return nil
        }
        let params = root["params"] as? [String: Any] ?? [:]

        if method == "tool/requestUserInput" {
            guard let requestID = rpcID(root["id"]),
                  let questions = params["questions"] as? [[String: Any]],
                  let prompt = CodexFeedbackPromptParser.parse(
                      questions: questions,
                      callID: requestID
                  ) else {
                return nil
            }
            return CodexAppServerInteraction(
                requestID: requestID,
                kind: .userInput,
                phase: .requested,
                threadID: nonEmptyString(params["threadId"]),
                turnID: nonEmptyString(params["turnId"]),
                prompt: prompt
            )
        }

        if method.lowercased().contains("requestapproval") {
            guard let requestID = rpcID(root["id"]) else { return nil }
            return CodexAppServerInteraction(
                requestID: requestID,
                kind: .approval,
                phase: .requested,
                threadID: nonEmptyString(params["threadId"]),
                turnID: nonEmptyString(params["turnId"])
            )
        }

        if method == "serverRequest/resolved" {
            guard let requestID = rpcID(params["requestId"]) else { return nil }
            return CodexAppServerInteraction(
                requestID: requestID,
                kind: nil,
                phase: .resolved,
                threadID: nonEmptyString(params["threadId"]),
                turnID: nonEmptyString(params["turnId"])
            )
        }

        return nil
    }

    private static func rpcID(_ value: Any?) -> String? {
        if let value = nonEmptyString(value) { return value }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct CodexAppServerInteractionTracker: Sendable {
    public struct Outcome: Equatable, Sendable {
        public let interaction: CodexAppServerInteraction
        public let resolvedKind: CodexAppServerInteraction.Kind?
        public let pendingKinds: Set<CodexAppServerInteraction.Kind>
    }

    private var pendingByRequestID: [String: CodexAppServerInteraction.Kind] = [:]

    public init() {}

    public mutating func consume(_ interaction: CodexAppServerInteraction) -> Outcome {
        var resolvedKind: CodexAppServerInteraction.Kind?
        switch interaction.phase {
        case .requested:
            if let kind = interaction.kind {
                pendingByRequestID[interaction.requestID] = kind
            }
        case .resolved:
            resolvedKind = pendingByRequestID.removeValue(forKey: interaction.requestID)
        }
        return Outcome(
            interaction: interaction,
            resolvedKind: resolvedKind,
            pendingKinds: Set(pendingByRequestID.values)
        )
    }
}
