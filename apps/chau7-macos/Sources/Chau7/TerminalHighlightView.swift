import AppKit
import SwiftTerm

final class TerminalHighlightView: NSView {
    weak var terminalView: Chau7TerminalView?
    weak var session: TerminalSessionModel?

    // Cached visible matches to avoid recomputation on every draw (Issue #14 fix)
    private var cachedVisibleMatches: [TerminalSessionModel.SearchMatch] = []
    private var cachedYDisp: Int = -1
    private var cachedRows: Int = -1
    private var cachedMatchCount: Int = -1

    // Cached font metrics to avoid recalculating on every draw (Latency optimization)
    private var cachedCellWidth: CGFloat = 0
    private var cachedFont: NSFont?

    // Display batching to coalesce multiple needsDisplay calls (Latency optimization)
    private var displayScheduled = false

    override var isFlipped: Bool { true }

    /// Schedules a display update, coalescing multiple calls within the same frame.
    /// This prevents excessive scheduling during rapid buffer updates.
    func scheduleDisplay() {
        guard !displayScheduled else { return }
        displayScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.displayScheduled = false
            self.needsDisplay = true
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let terminalView, let session else { return }
        let terminal = terminalView.getTerminal()
        let rows = terminal.rows
        let cols = terminal.cols
        if rows <= 0 || cols <= 0 { return }

        // Use cached font metrics to avoid recalculating on every draw (Latency optimization)
        let font = terminalView.font
        let cellWidth: CGFloat
        if cachedFont !== font {
            cachedFont = font
            let sampleChar: NSString = "M"
            cachedCellWidth = sampleChar.size(withAttributes: [.font: font]).width
        }
        cellWidth = cachedCellWidth
        let cellHeight = terminalView.bounds.height / CGFloat(rows)

        let yDisp = terminal.buffer.yDisp

        // Update cache if needed (Issue #14 fix - performance optimization)
        let allMatches = session.searchMatches
        if cachedYDisp != yDisp || cachedRows != rows || cachedMatchCount != allMatches.count {
            updateVisibleMatchesCache(
                allMatches: allMatches,
                yDisp: yDisp,
                rows: rows
            )
        }

        guard !cachedVisibleMatches.isEmpty else { return }

        let highlightColor = NSColor.systemYellow.withAlphaComponent(0.28)
        let activeColor = NSColor.systemOrange.withAlphaComponent(0.45)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Draw all visible matches
        context.setFillColor(highlightColor.cgColor)
        for match in cachedVisibleMatches {
            let visibleRow = match.row - yDisp
            let col = max(0, min(match.col, cols - 1))
            let length = max(1, min(match.length, cols - col))
            let x = CGFloat(col) * cellWidth
            let y = CGFloat(visibleRow) * cellHeight
            let rect = NSRect(x: x, y: y, width: CGFloat(length) * cellWidth, height: cellHeight)
            context.fill(rect.insetBy(dx: 0.5, dy: 0.5))
        }

        // Draw active match with different color
        if let active = session.currentMatch() {
            let visibleRow = active.row - yDisp
            if visibleRow >= 0 && visibleRow < rows {
                let col = max(0, min(active.col, cols - 1))
                let length = max(1, min(active.length, cols - col))
                let x = CGFloat(col) * cellWidth
                let y = CGFloat(visibleRow) * cellHeight
                let rect = NSRect(x: x, y: y, width: CGFloat(length) * cellWidth, height: cellHeight)
                context.setFillColor(activeColor.cgColor)
                context.fill(rect.insetBy(dx: 0.5, dy: 0.5))
            }
        }
    }

    /// Updates the cache of visible matches based on current scroll position.
    /// This avoids filtering the full match list on every draw call.
    private func updateVisibleMatchesCache(
        allMatches: [TerminalSessionModel.SearchMatch],
        yDisp: Int,
        rows: Int
    ) {
        cachedYDisp = yDisp
        cachedRows = rows
        cachedMatchCount = allMatches.count

        // Filter to only visible matches (within current viewport)
        // Limit to 300 for performance
        var visible: [TerminalSessionModel.SearchMatch] = []
        visible.reserveCapacity(min(300, allMatches.count))

        for match in allMatches {
            let visibleRow = match.row - yDisp
            if visibleRow >= 0 && visibleRow < rows {
                visible.append(match)
                if visible.count >= 300 {
                    break
                }
            }
        }

        cachedVisibleMatches = visible
    }

    /// Invalidates the match cache, forcing recomputation on next draw.
    func invalidateCache() {
        cachedYDisp = -1
        cachedRows = -1
        cachedMatchCount = -1
        cachedVisibleMatches = []
    }

    /// Invalidates the font metrics cache (call when font changes).
    func invalidateFontCache() {
        cachedFont = nil
        cachedCellWidth = 0
    }
}
