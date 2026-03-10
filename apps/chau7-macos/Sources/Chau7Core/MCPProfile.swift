import Foundation

// MARK: - Approval Result

/// Three-option result from the MCP command approval dialog.
public enum MCPApprovalResult: String, Codable, Sendable {
    case denied
    case allowedOnce
    case alwaysAllow
}

// MARK: - Tab Context

/// Snapshot of terminal state used to match MCP profiles at command-check time.
public struct MCPTabContext: Sendable {
    public let directory: String?
    public let gitBranch: String?
    public let sshHost: String?
    public let processes: [String]?
    public let environment: [String: String]?

    public init(
        directory: String? = nil,
        gitBranch: String? = nil,
        sshHost: String? = nil,
        processes: [String]? = nil,
        environment: [String: String]? = nil
    ) {
        self.directory = directory
        self.gitBranch = gitBranch
        self.sshHost = sshHost
        self.processes = processes
        self.environment = environment
    }
}

// MARK: - MCP Profile

/// A scoped set of MCP permission rules that activates when its trigger matches
/// the current terminal context. Profiles override global MCP permission settings
/// for commands executed in matching tabs.
public struct MCPProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var isEnabled: Bool
    public var trigger: ProfileSwitchTrigger
    public var permissionMode: MCPPermissionMode
    public var allowedCommands: [String]
    public var blockedCommands: [String]
    public var priority: Int

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        trigger: ProfileSwitchTrigger,
        permissionMode: MCPPermissionMode = .askUnlisted,
        allowedCommands: [String] = [],
        blockedCommands: [String] = [],
        priority: Int = 0
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.permissionMode = permissionMode
        self.allowedCommands = allowedCommands
        self.blockedCommands = blockedCommands
        self.priority = priority
    }
}

// MARK: - Profile Matching

extension MCPProfile {
    /// Check if this profile's trigger matches the given tab context.
    public func matches(context: MCPTabContext) -> Bool {
        guard isEnabled else { return false }
        // Reuse ProfileSwitchRule's matching logic via a temporary rule
        let rule = ProfileSwitchRule(
            name: name,
            trigger: trigger,
            profileName: "",
            priority: priority
        )
        return rule.matches(
            directory: context.directory,
            gitBranch: context.gitBranch,
            sshHost: context.sshHost,
            processes: context.processes,
            environment: context.environment
        )
    }
}

public extension [MCPProfile] {
    /// Find the best matching profile for a tab context.
    /// Returns the highest-priority enabled profile whose trigger matches,
    /// or nil if no profile matches.
    func bestMatch(for context: MCPTabContext) -> MCPProfile? {
        self.filter { $0.matches(context: context) }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.name < rhs.name
            }
            .first
    }
}
