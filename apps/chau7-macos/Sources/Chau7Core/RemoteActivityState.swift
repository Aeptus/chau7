import Foundation

public enum RemoteActivityStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case idle
    case running
    case approvalRequired = "approval_required"
    case waitingInput
    case completed
    case failed
}

public struct RemoteActivityApproval: Codable, Equatable, Sendable, Hashable {
    public let requestID: String
    public let command: String
    public let flaggedCommand: String

    public init(requestID: String, command: String, flaggedCommand: String) {
        self.requestID = requestID
        self.command = command
        self.flaggedCommand = flaggedCommand
    }

    public var displayCommand: String {
        let trimmedFlagged = flaggedCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFlagged.isEmpty {
            return trimmedFlagged
        }
        return command
    }
}

public struct RemoteActivityCandidate: Equatable, Sendable {
    public let activityID: String
    public let tabID: UInt32
    public let tabTitle: String
    public let toolName: String
    public let projectName: String?
    public let sessionID: String?
    public let status: RemoteActivityStatus
    public let detail: String?
    public let logoAssetName: String?
    public let tabColorName: String?
    public let isSelected: Bool
    public let updatedAt: Date
    public let startedAt: Date?
    public let approval: RemoteActivityApproval?

    public init(
        activityID: String,
        tabID: UInt32,
        tabTitle: String,
        toolName: String,
        projectName: String? = nil,
        sessionID: String? = nil,
        status: RemoteActivityStatus,
        detail: String? = nil,
        logoAssetName: String? = nil,
        tabColorName: String? = nil,
        isSelected: Bool,
        updatedAt: Date,
        startedAt: Date? = nil,
        approval: RemoteActivityApproval? = nil
    ) {
        self.activityID = activityID
        self.tabID = tabID
        self.tabTitle = tabTitle
        self.toolName = toolName
        self.projectName = projectName
        self.sessionID = sessionID
        self.status = status
        self.detail = detail
        self.logoAssetName = logoAssetName
        self.tabColorName = tabColorName
        self.isSelected = isSelected
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.approval = approval
    }
}

public struct RemoteActivityState: Codable, Equatable, Sendable, Hashable {
    public let activityID: String
    public let tabID: UInt32
    public let tabTitle: String
    public let toolName: String
    public let projectName: String?
    public let sessionID: String?
    public let status: RemoteActivityStatus
    public let headline: String
    public let detail: String?
    public let logoAssetName: String?
    public let tabColorName: String?
    public let isSelectedTab: Bool
    public let startedAt: Date?
    public let updatedAt: Date
    public let approval: RemoteActivityApproval?

    public init(
        activityID: String,
        tabID: UInt32,
        tabTitle: String,
        toolName: String,
        projectName: String? = nil,
        sessionID: String? = nil,
        status: RemoteActivityStatus,
        headline: String,
        detail: String? = nil,
        logoAssetName: String? = nil,
        tabColorName: String? = nil,
        isSelectedTab: Bool,
        startedAt: Date? = nil,
        updatedAt: Date,
        approval: RemoteActivityApproval? = nil
    ) {
        self.activityID = activityID
        self.tabID = tabID
        self.tabTitle = tabTitle
        self.toolName = toolName
        self.projectName = projectName
        self.sessionID = sessionID
        self.status = status
        self.headline = headline
        self.detail = detail
        self.logoAssetName = logoAssetName
        self.tabColorName = tabColorName
        self.isSelectedTab = isSelectedTab
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.approval = approval
    }

    enum CodingKeys: String, CodingKey {
        case activityID = "activity_id"
        case tabID = "tab_id"
        case tabTitle = "tab_title"
        case toolName = "tool_name"
        case projectName = "project_name"
        case sessionID = "session_id"
        case status
        case headline
        case detail
        case logoAssetName = "logo_asset_name"
        case tabColorName = "tab_color_name"
        case isSelectedTab = "is_selected_tab"
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case approval
    }
}

public enum RemoteActivityProjection {
    public static func project(from candidates: [RemoteActivityCandidate]) -> RemoteActivityState? {
        let eligible = candidates.filter { $0.status != .idle }
        guard let best = eligible.max(by: isLowerPriority) else {
            return nil
        }

        let headline = headline(for: best)
        let detail = normalizedDetail(for: best)

        return RemoteActivityState(
            activityID: best.activityID,
            tabID: best.tabID,
            tabTitle: best.tabTitle,
            toolName: best.toolName,
            projectName: best.projectName,
            sessionID: best.sessionID,
            status: best.status,
            headline: headline,
            detail: detail,
            logoAssetName: best.logoAssetName,
            tabColorName: best.tabColorName,
            isSelectedTab: best.isSelected,
            startedAt: best.startedAt,
            updatedAt: best.updatedAt,
            approval: best.approval
        )
    }

    private static func isLowerPriority(_ lhs: RemoteActivityCandidate, _ rhs: RemoteActivityCandidate) -> Bool {
        if priority(for: lhs.status) != priority(for: rhs.status) {
            return priority(for: lhs.status) < priority(for: rhs.status)
        }
        if lhs.isSelected != rhs.isSelected {
            return !lhs.isSelected && rhs.isSelected
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt < rhs.updatedAt
        }
        return lhs.tabID < rhs.tabID
    }

    private static func priority(for status: RemoteActivityStatus) -> Int {
        switch status {
        case .approvalRequired:
            return 5
        case .waitingInput:
            return 4
        case .failed:
            return 3
        case .running:
            return 2
        case .completed:
            return 1
        case .idle:
            return 0
        }
    }

    private static func headline(for candidate: RemoteActivityCandidate) -> String {
        switch candidate.status {
        case .approvalRequired:
            return "Approval required"
        case .waitingInput:
            return "\(candidate.toolName) needs input"
        case .failed:
            return "\(candidate.toolName) failed"
        case .running:
            return "\(candidate.toolName) is active"
        case .completed:
            return "\(candidate.toolName) finished"
        case .idle:
            return candidate.toolName
        }
    }

    private static func normalizedDetail(for candidate: RemoteActivityCandidate) -> String? {
        if let approval = candidate.approval {
            let display = approval.displayCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            if !display.isEmpty {
                return display
            }
        }

        let trimmed = candidate.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }

        let project = candidate.projectName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return project.isEmpty ? nil : project
    }
}
