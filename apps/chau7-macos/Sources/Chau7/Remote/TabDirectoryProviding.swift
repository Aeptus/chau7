import Foundation

/// The MCP/tab side of the Remote↔MCP boundary, as seen from
/// `RemoteControlManager`. Consumer-owned seam so the Remote layer depends on
/// this abstraction instead of dereferencing `TerminalControlService.shared`.
/// Implemented by `TerminalControlService` (backed by its
/// `WindowModelRegistry`); tests can substitute a fake.
///
/// Members are nonisolated but thread-safe, matching the implementer:
/// `RemoteControlManager` calls them from the main actor.
protocol TabDirectoryProviding: AnyObject {
    /// Every registered overlay window model, in stable window order.
    var allOverlayModels: [OverlayTabsModel] { get }

    /// Clears any persistent notification style for the tab across all
    /// windows. Returns true if a window handled the clear.
    @discardableResult
    func clearPersistentNotificationStyleAcrossWindows(tabID: UUID) -> Bool

    /// Resolves an in-flight MCP approval request with the remote decision.
    func resolveApproval(requestID: String, approved: Bool)
}
