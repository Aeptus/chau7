/// Bounded focus recovery for terminals attached asynchronously by SwiftUI.
/// A retry must still belong to the selected pane; activation alone is not
/// permission to reclaim focus from an editor or another tab.
public enum TerminalFocusRequestPolicy {
    public enum Action: Equatable {
        case focus
        case retry
        case cancel
    }

    public static let retryLimit = 120
    public static let retryDelay = 0.05

    public static func action(
        isCurrentRequest: Bool,
        ownsFocus: Bool,
        responderChangedToEditor: Bool,
        isInteractive: Bool,
        appIsActive: Bool,
        isKeyWindow: Bool,
        isOnActiveSpace: Bool,
        viewIsAttached: Bool,
        attempt: Int
    ) -> Action {
        guard isCurrentRequest, ownsFocus, !responderChangedToEditor else { return .cancel }
        if isInteractive, appIsActive, isKeyWindow, isOnActiveSpace, viewIsAttached {
            return .focus
        }
        return attempt < retryLimit ? .retry : .cancel
    }
}
