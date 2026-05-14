import Foundation

public enum MetalFullRefreshPolicy {
    /// Incremental Metal instance reuse is fast, but if a near-full-grid redraw
    /// slips through with an incomplete dirty-row set, stale cells can survive
    /// and mix with fresh content. That risk is highest during scroll storms
    /// and while a tab is visible but noninteractive in a background window.
    public static func shouldForceFullRefresh(
        rowCount: Int,
        dirtyRowCount: Int,
        alreadyFullRefresh: Bool,
        inScrollStorm: Bool,
        isInteractive: Bool,
        allowsLivePresentation: Bool
    ) -> Bool {
        guard rowCount > 0 else { return alreadyFullRefresh }
        if alreadyFullRefresh || inScrollStorm {
            return true
        }

        if allowsLivePresentation, !isInteractive {
            return true
        }

        return dirtyRowCount * 100 >= rowCount * 85
    }
}
