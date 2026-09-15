import Foundation

public enum MetalFullRefreshPolicy {
    /// Incremental Metal instance reuse is fast, but if a near-full-grid redraw
    /// slips through with an incomplete dirty-row set, stale cells can survive
    /// and mix with fresh content. The Rust delta snapshot is authoritative for
    /// every live view, including a visible window that is not key/main, so the
    /// interaction state must not turn every frame into a full-grid rebuild.
    /// First presentation, resize, theme changes, and other lifecycle changes
    /// already set `alreadyFullRefresh` explicitly.
    public static func shouldForceFullRefresh(
        rowCount: Int,
        dirtyRowCount: Int,
        alreadyFullRefresh: Bool,
        inScrollStorm: Bool,
        isInteractive _: Bool,
        allowsLivePresentation _: Bool
    ) -> Bool {
        guard rowCount > 0 else { return alreadyFullRefresh }
        if alreadyFullRefresh || inScrollStorm {
            return true
        }

        return dirtyRowCount * 100 >= rowCount * 85
    }
}
