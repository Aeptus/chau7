import Foundation

/// Encapsulates the routing parameters needed to resolve which tab an event targets.
/// Replaces the `(tool, directory, tabID)` tuple that was repeated across protocol
/// methods, adapters, and call sites in the notification pipeline.
public struct TabTarget: Equatable, Sendable {
    public let tool: String
    public let directory: String?
    public let tabID: UUID?

    public init(tool: String, directory: String? = nil, tabID: UUID? = nil) {
        self.tool = tool
        self.directory = directory
        self.tabID = tabID
    }
}
