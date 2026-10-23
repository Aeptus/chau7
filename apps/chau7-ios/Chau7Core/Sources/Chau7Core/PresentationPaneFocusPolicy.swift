/// Resolves which terminal pane should keep owning tab-level presentation when
/// split-pane focus moves into a non-terminal side pane.
public enum PresentationPaneFocusPolicy {
    /// Prefer the focused terminal, otherwise keep the previous presentation
    /// terminal if it still exists, otherwise fall back to the first terminal.
    public static func selectedTerminalPaneID<PaneID: Hashable>(
        focusedPaneID: PaneID,
        terminalPaneIDs: [PaneID],
        previousPresentationPaneID: PaneID?
    ) -> PaneID? {
        if terminalPaneIDs.contains(focusedPaneID) {
            return focusedPaneID
        }
        if let previousPresentationPaneID,
           terminalPaneIDs.contains(previousPresentationPaneID) {
            return previousPresentationPaneID
        }
        return terminalPaneIDs.first
    }
}
