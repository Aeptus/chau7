import AppKit

// MARK: - Terminal Cursor Line View

final class TerminalCursorLineView: NSView {
    /// Terminal view reference - uses unified TerminalViewLike protocol
    private weak var _terminalView: (any TerminalViewLike)?
    var showsContextLines: Bool = false
    var showsInputHistory: Bool = false
    var isFocused: Bool = false
    weak var inputLineTracker: InputLineTracker?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Update with RustTerminalView
    func update(
        with terminalView: RustTerminalView,
        isFocused: Bool,
        showsContextLines: Bool,
        showsInputHistory: Bool,
        inputLineTracker: InputLineTracker?
    ) {
        updateInternal(
            with: terminalView,
            isFocused: isFocused,
            showsContextLines: showsContextLines,
            showsInputHistory: showsInputHistory,
            inputLineTracker: inputLineTracker
        )
    }

    /// Internal update method that works with any TerminalViewLike
    private func updateInternal(
        with terminalView: any TerminalViewLike,
        isFocused: Bool,
        showsContextLines: Bool,
        showsInputHistory: Bool,
        inputLineTracker: InputLineTracker?
    ) {
        self._terminalView = terminalView
        self.isFocused = isFocused
        self.showsContextLines = showsContextLines
        self.showsInputHistory = showsInputHistory
        self.inputLineTracker = inputLineTracker

        if frame != terminalView.bounds {
            frame = terminalView.bounds
        }
        isHidden = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let terminalView = _terminalView else { return }
        let caret = terminalView.caretFrame
        guard caret.height > 0 else { return }

        guard let rustView = terminalView as? RustTerminalView else { return }
        let topRow = rustView.renderTopVisibleRow
        let cursorRow = topRow + rustView.renderCursorRow
        let totalRows = rustView.renderRows
        let lineHeight = caret.height
        let baseY = caret.origin.y
        let width = terminalView.bounds.width

        let baseAlpha: CGFloat = isFocused ? 0.10 : 0.06
        let highlight = highlightColor(alpha: baseAlpha)

        var rows: [(Int, NSColor)] = [(cursorRow, highlight)]
        if showsContextLines {
            rows.append((cursorRow - 1, highlight))
            rows.append((cursorRow + 1, highlight))
        }
        if showsInputHistory, let tracker = inputLineTracker {
            let bottomRow = topRow + max(totalRows - 1, 0)
            for row in tracker.visibleRows(top: topRow, bottom: bottomRow) {
                if row == cursorRow {
                    continue
                }
                rows.append((row, highlight))
            }
        }

        for (row, color) in rows {
            let delta = row - cursorRow
            let y = baseY - (CGFloat(delta) * lineHeight)
            let rect = CGRect(x: 0, y: y, width: width, height: lineHeight)
            if rect.maxY < 0 || rect.minY > bounds.height {
                continue
            }
            color.setFill()
            rect.fill()
        }
    }

    private func highlightColor(alpha: CGFloat) -> NSColor {
        let match = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        let isDark = match == .darkAqua
        let base = isDark ? NSColor.white : NSColor.black
        return base.withAlphaComponent(alpha)
    }
}
