import Foundation

// MARK: - Task Lifecycle Events

/// Represents a pending task candidate that may be confirmed or dismissed
public struct TaskCandidate: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let tabId: String
    public let sessionId: String
    public let projectPath: String
    public let suggestedName: String
    public let trigger: TaskTrigger
    public let confidence: Double
    public let gracePeriodEnd: Date
    public let createdAt: Date

    public var graceRemainingMs: Int64 {
        max(0, Int64(gracePeriodEnd.timeIntervalSinceNow * 1000))
    }

    public var isExpired: Bool {
        Date() > gracePeriodEnd
    }
}

/// Represents an active task being tracked
public struct TrackedTask: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let candidateId: String?
    public let tabId: String
    public let sessionId: String
    public let projectPath: String
    public var name: String
    public let state: TaskState
    public let startMethod: TaskStartMethod
    public let trigger: TaskTrigger
    public let startedAt: Date
    public var completedAt: Date?

    // Metrics (updated periodically)
    public var totalAPICalls: Int
    public var totalTokens: Int
    public var totalCostUSD: Double

    // v1.2: Baseline metrics
    public var baselineTotalTokens: Int
    public var tokensSaved: Int

    public var durationSeconds: Int64 {
        Int64((completedAt ?? Date()).timeIntervalSince(startedAt))
    }

    public var formattedCost: String {
        if totalCostUSD < 0.01 {
            return String(format: "$%.4f", totalCostUSD)
        }
        return String(format: "$%.2f", totalCostUSD)
    }

    public var formattedDuration: String {
        let seconds = durationSeconds
        if seconds < 60 {
            return "\(seconds)s"
        } else if seconds < 3600 {
            return "\(seconds / 60)m \(seconds % 60)s"
        } else {
            return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
        }
    }

    // v1.2: Formatted tokens saved
    public var formattedTokensSaved: String {
        if tokensSaved > 0 {
            return "+\(tokensSaved)"
        } else if tokensSaved < 0 {
            return "\(tokensSaved)"
        }
        return "0"
    }

    public var hasSavings: Bool {
        tokensSaved > 0
    }
}

/// Represents a task assessment result
public struct TaskAssessment: Codable, Equatable, Sendable {
    public let taskId: String
    public let approved: Bool
    public let note: String?
    public let totalAPICalls: Int
    public let totalTokens: Int
    public let totalCostUSD: Double
    public let tokensSaved: Int? // nil until baseline estimation is implemented
    public let durationSeconds: Int64
    public let assessedAt: Date
}

// MARK: - Enums

/// Task state in the lifecycle
public enum TaskState: String, Codable, Sendable {
    case none
    case candidate
    case active
    case completed
    case abandoned
}

/// What triggered the task creation
public enum TaskTrigger: String, Codable, Sendable {
    case manual
    case newSession = "new_session"
    case idleGap = "idle_gap"
    case repoSwitch = "repo_switch"

    public var displayName: String {
        switch self {
        case .manual: return "Manual"
        case .newSession: return "New Session"
        case .idleGap: return "Idle Gap"
        case .repoSwitch: return "Repo Switch"
        }
    }
}

/// How the task was started
public enum TaskStartMethod: String, Codable, Sendable {
    case manual
    case autoConfirmed = "auto_confirmed"
    case userConfirmed = "user_confirmed"

    public var displayName: String {
        switch self {
        case .manual: return "Manual"
        case .autoConfirmed: return "Auto-confirmed"
        case .userConfirmed: return "User-confirmed"
        }
    }
}

// MARK: - IPC Event Types

/// Base structure for v1.0 events with schema versioning
public struct ProxyEvent: Decodable {
    public let schemaVersion: String
    public let type: String
    public let tool: String
    public let origin: String
    public let timestamp: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case type
        case tool
        case origin
        case timestamp = "ts"
    }
}

/// Task candidate event data
public struct TaskCandidateEventData: Decodable {
    public let candidateId: String
    public let tabId: String
    public let sessionId: String
    public let projectPath: String
    public let suggestedName: String
    public let trigger: String
    public let confidence: Double
    public let gracePeriodSeconds: Int64

    enum CodingKeys: String, CodingKey {
        case candidateId = "candidate_id"
        case tabId = "tab_id"
        case sessionId = "session_id"
        case projectPath = "project_path"
        case suggestedName = "suggested_name"
        case trigger
        case confidence
        case gracePeriodSeconds = "grace_period_seconds"
    }
}

/// Task started event data
public struct TaskStartedEventData: Decodable {
    public let taskId: String
    public let candidateId: String?
    public let tabId: String
    public let sessionId: String
    public let projectPath: String
    public let taskName: String
    public let startMethod: String
    public let trigger: String

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case candidateId = "candidate_id"
        case tabId = "tab_id"
        case sessionId = "session_id"
        case projectPath = "project_path"
        case taskName = "task_name"
        case startMethod = "start_method"
        case trigger
    }
}

/// Task candidate dismissed event data
public struct TaskDismissedEventData: Decodable {
    public let candidateId: String
    public let tabId: String
    public let dismissMethod: String
    public let reason: String

    enum CodingKeys: String, CodingKey {
        case candidateId = "candidate_id"
        case tabId = "tab_id"
        case dismissMethod = "dismiss_method"
        case reason
    }
}

/// Task assessment event data
public struct TaskAssessmentEventData: Decodable {
    public let taskId: String
    public let tabId: String
    public let sessionId: String
    public let approved: Bool
    public let note: String?
    public let totalAPICalls: Int
    public let totalTokens: Int
    public let totalCostUSD: Double
    public let tokensSaved: Int?
    public let durationSeconds: Int64

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case tabId = "tab_id"
        case sessionId = "session_id"
        case approved
        case note
        case totalAPICalls = "total_api_calls"
        case totalTokens = "total_tokens"
        case totalCostUSD = "total_cost_usd"
        case tokensSaved = "tokens_saved"
        case durationSeconds = "duration_seconds"
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    static let taskCandidateReceived = Notification.Name("taskCandidateReceived")
    static let taskStarted = Notification.Name("taskStarted")
    static let taskCandidateDismissed = Notification.Name("taskCandidateDismissed")
    static let taskAssessmentReceived = Notification.Name("taskAssessmentReceived")
}
