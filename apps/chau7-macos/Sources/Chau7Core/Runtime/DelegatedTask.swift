import Foundation

/// Session-scoped delegated-task description.
public struct DelegatedTaskDescriptor: Codable, Equatable, Sendable {
    public let purpose: String?
    public let parentSessionID: String?
    public let parentRunID: String?
    public let metadata: [String: String]
    public let resultSchema: JSONValue?

    public init(
        purpose: String? = nil,
        parentSessionID: String? = nil,
        parentRunID: String? = nil,
        metadata: [String: String] = [:],
        resultSchema: JSONValue? = nil
    ) {
        self.purpose = purpose
        self.parentSessionID = parentSessionID
        self.parentRunID = parentRunID
        self.metadata = metadata
        self.resultSchema = resultSchema
    }
}

/// Runtime policy applied to delegated sessions.
///
/// Only limits owned by Chau7 itself are enforceable. Filesystem and network
/// fields are advisory today and must be paired with backend-specific sandboxing
/// to become hard guarantees.
public struct RuntimeDelegationPolicy: Codable, Equatable, Sendable {
    public let maxTurns: Int?
    public let maxDurationMs: Int?
    public let allowChildDelegation: Bool
    public let maxDelegationDepth: Int
    public let allowedTools: [String]
    public let blockedTools: [String]
    public let allowNetwork: Bool?
    public let allowFileWrites: Bool?

    public init(
        maxTurns: Int? = nil,
        maxDurationMs: Int? = nil,
        allowChildDelegation: Bool = true,
        maxDelegationDepth: Int = 4,
        allowedTools: [String] = [],
        blockedTools: [String] = [],
        allowNetwork: Bool? = nil,
        allowFileWrites: Bool? = nil
    ) {
        self.maxTurns = maxTurns
        self.maxDurationMs = maxDurationMs
        self.allowChildDelegation = allowChildDelegation
        self.maxDelegationDepth = max(0, maxDelegationDepth)
        self.allowedTools = allowedTools
        self.blockedTools = blockedTools
        self.allowNetwork = allowNetwork
        self.allowFileWrites = allowFileWrites
    }

    public func validateStart(turnCount: Int, elapsedMs: Int, delegationDepth: Int) -> String? {
        if delegationDepth > maxDelegationDepth {
            return "Delegation depth \(delegationDepth) exceeds max_delegation_depth \(maxDelegationDepth)."
        }
        if let maxTurns, turnCount > maxTurns {
            return "Session exceeded max_turns \(maxTurns)."
        }
        if let maxDurationMs, elapsedMs > maxDurationMs {
            return "Session exceeded max_duration_ms \(maxDurationMs)."
        }
        return nil
    }

    public func validateChildCreation(childDelegationDepth: Int) -> String? {
        if !allowChildDelegation {
            return "Session policy disallows child delegation."
        }
        if childDelegationDepth > maxDelegationDepth {
            return "Child delegation depth \(childDelegationDepth) exceeds max_delegation_depth \(maxDelegationDepth)."
        }
        return nil
    }

    public func validateTool(_ tool: String) -> String? {
        let normalized = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return nil }
        let normalizedBlocked = Set(blockedTools.map { $0.lowercased() })
        if normalizedBlocked.contains(normalized) {
            return "Tool '\(tool)' is blocked by session policy."
        }
        let normalizedAllowed = Set(allowedTools.map { $0.lowercased() })
        if !normalizedAllowed.isEmpty, !normalizedAllowed.contains(normalized) {
            return "Tool '\(tool)' is not in the session allowlist."
        }
        return nil
    }

    public var foundationValue: [String: Any] {
        var result: [String: Any] = [
            "allow_child_delegation": allowChildDelegation,
            "max_delegation_depth": maxDelegationDepth,
            "allowed_tools": allowedTools,
            "blocked_tools": blockedTools
        ]
        if let maxTurns {
            result["max_turns"] = maxTurns
        }
        if let maxDurationMs {
            result["max_duration_ms"] = maxDurationMs
        }
        if let allowNetwork {
            result["allow_network"] = allowNetwork
        }
        if let allowFileWrites {
            result["allow_file_writes"] = allowFileWrites
        }
        return result
    }
}

public enum RuntimeTurnResultStatus: String, Codable, Sendable {
    case available
    case invalid
    case missing
}

public struct RuntimeTurnResult: Codable, Equatable, Sendable {
    public let sessionID: String
    public let turnID: String
    public let status: RuntimeTurnResultStatus
    public let source: String
    public let capturedAt: Date
    public let schema: JSONValue?
    public let value: JSONValue?
    public let validationErrors: [String]
    public let rawText: String?

    public init(
        sessionID: String,
        turnID: String,
        status: RuntimeTurnResultStatus,
        source: String,
        capturedAt: Date = Date(),
        schema: JSONValue? = nil,
        value: JSONValue? = nil,
        validationErrors: [String] = [],
        rawText: String? = nil
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.status = status
        self.source = source
        self.capturedAt = capturedAt
        self.schema = schema
        self.value = value
        self.validationErrors = validationErrors
        self.rawText = rawText
    }
}
