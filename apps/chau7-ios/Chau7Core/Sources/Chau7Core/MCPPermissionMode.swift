import Foundation

/// Controls how MCP commands are filtered when not explicitly allowed or blocked.
public enum MCPPermissionMode: String, CaseIterable, Codable, Sendable {
    case allowAll = "allow_all"
    case allowlist
    case askUnlisted = "ask_unlisted"
    /// Allow execution but log/audit the command for review.
    case auditOnly = "audit_only"

    public var displayName: String {
        switch self {
        case .allowAll: return "Allow All"
        case .allowlist: return "Allowlist Only"
        case .askUnlisted: return "Ask for Unlisted"
        case .auditOnly: return "Audit Only"
        }
    }
}
