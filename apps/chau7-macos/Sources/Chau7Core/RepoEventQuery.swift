import Foundation

/// Shared filtering contract for repository events across MCP and scripting.
public struct RepoEventQuery: Sendable {
    public static let maxLimit = 50
    public let limit: Int
    public let tabID: String?
    private let eventTypes: Set<String>
    private let tool: String?
    private let producer: String?
    private let sessionID: String?

    public init(limit: Int, tabID: String? = nil, eventTypes: [String]? = nil, tool: String? = nil, producer: String? = nil, sessionID: String? = nil) {
        self.limit = max(1, min(limit, Self.maxLimit))
        self.tabID = tabID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.eventTypes = Set((eventTypes ?? []).map { $0.lowercased() }.filter { !$0.isEmpty })
        self.tool = tool?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.producer = producer?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func matches(_ event: AIEvent, resolvedTabID: String?) -> Bool {
        if let tabID, event.tabID == nil || resolvedTabID != tabID { return false }
        if !eventTypes.isEmpty, !eventTypes.contains(event.type.lowercased()) { return false }
        if let tool, event.tool.lowercased() != tool { return false }
        if let producer, event.producer?.lowercased() != producer { return false }
        if let sessionID, event.sessionID != sessionID { return false }
        return true
    }
}
