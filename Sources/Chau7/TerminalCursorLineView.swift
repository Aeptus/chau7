import AppKit

final class TerminalCursorLineView: NSView {
    weak var terminalView: Chau7TerminalView?
    var showsContextLines: Bool = false
    var showsInputHistory: Bool = false
    var isFocused: Bool = false
    weak var inputLineTracker: InputLineTracker?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(
        with terminalView: Chau7TerminalView,
        isFocused: Bool,
        showsContextLines: Bool,
        showsInputHistory: Bool,
        inputLineTracker: InputLineTracker?
    ) {
        self.terminalView = terminalView
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
        guard let terminalView else { return }
        let caret = terminalView.caretFrame
        guard caret.height > 0 else { return }

        let terminal = terminalView.getTerminal()
        let cursor = terminal.getCursorLocation()
        let topRow = terminal.getTopVisibleRow()
        let cursorRow = topRow + cursor.y
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
            let bottomRow = topRow + max(terminal.rows - 1, 0)
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
