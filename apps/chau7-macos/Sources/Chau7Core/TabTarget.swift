import Foundation

/// Encapsulates the routing parameters needed to resolve which tab an event targets.
/// Replaces the `(tool, directory, tabID)` tuple that was repeated across protocol
/// methods, adapters, and call sites in the notification pipeline.
public struct TabTarget: Equatable, Sendable {
    public let tool: String
    public let directory: String?
    public let tabID: UUID?
    /// AI session ID (e.g. Claude session ID) for disambiguation when multiple
    /// tabs run the same tool in the same directory. Matched against
    /// `TerminalSessionModel.effectiveAISessionId`.
    public let sessionID: String?

    public init(tool: String, directory: String? = nil, tabID: UUID? = nil, sessionID: String? = nil) {
        self.tool = tool
        self.directory = directory
        self.tabID = tabID
        self.sessionID = sessionID
    }
}
