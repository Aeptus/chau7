import CoreText
import SwiftUI
import UIKit

/// Dual-path terminal renderer: text-based UITextView (default) or experimental
/// grid canvas with per-cell color, bold/italic/underline, cursor, and scrollback.
/// The canvas batches background fills by color run and caches UIColor/text
/// attributes to avoid per-cell allocations.
struct RemoteTerminalRendererView: View {
    let client: RemoteClient
    @AppStorage(AppSettings.renderANSIKey) private var renderANSI = AppSettings.renderANSIDefault

    var body: some View {
        Group {
            if client.terminalRenderer.isAvailable, client.terminalRenderer.renderState != nil {
                GeometryReader { proxy in
                    let renderState = client.terminalRenderer.renderState
                    RemoteTerminalRendererRepresentable(
                        store: client.terminalRenderer,
                        renderState: renderState,
                        availableSize: proxy.size
                    )
                    .background(Color.black)
                }
            } else {
                RemoteTerminalTextView(
                    text: renderANSI ? client.outputText : client.strippedOutputText
                )
            }
        }
        .onAppear {
            client.terminalRenderer.setActiveTab(client.activeTabID, fallbackText: client.outputText)
        }
    }
}

private struct RemoteTerminalRendererRepresentable: UIViewRepresentable {
    let store: RemoteTerminalRendererStore
    let renderState: RemoteTerminalRenderState?
    let availableSize: CGSize

    func makeUIView(context: Context) -> RemoteTerminalViewportView {
        let view = RemoteTerminalViewportView()
        view.update(store: store, renderState: renderState, availableSize: availableSize)
        return view
    }

    func updateUIView(_ uiView: RemoteTerminalViewportView, context: Context) {
        uiView.update(store: store, renderState: renderState, availableSize: availableSize)
    }
}

struct RemoteTerminalTextView: View {
    let text: String

    var body: some View {
        RemoteTerminalTextViewRepresentable(text: boundedTranscript(text))
            .background(Color.black)
    }

    private func boundedTranscript(_ text: String) -> String {
        let maxBytes = 250_000
        let utf8Bytes = Array(text.utf8)
        guard utf8Bytes.count > maxBytes else { return text }
        let tail = String(decoding: utf8Bytes.suffix(maxBytes), as: UTF8.self)
        if let firstNewline = tail.firstIndex(of: "\n") {
            return String(tail[tail.index(after: firstNewline)...])
        }
        return tail
    }
}

private struct RemoteTerminalTextViewRepresentable: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .black
        textView.textColor = .systemGreen
        textView.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.showsVerticalScrollIndicator = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.textContainer.lineFragmentPadding = 0
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.autocorrectionType = .no
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let wasNearBottom = textView.isNearBottom
        if textView.text != text {
            textView.text = text
        }
        if wasNearBottom {
            textView.scrollRangeToVisible(NSRange(location: max(text.utf16.count - 1, 0), length: 1))
        }
    }
}

private extension UITextView {
    var isNearBottom: Bool {
        let visibleHeight = bounds.height - adjustedContentInset.top - adjustedContentInset.bottom
        let remaining = contentSize.height - contentOffset.y - visibleHeight
        return remaining <= 80
    }
}

private final class RemoteTerminalViewportView: UIView, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let scrollContentView = UIView()
    private let canvasView = RemoteTerminalCanvasView()
    private var store: RemoteTerminalRendererStore?
    private var renderState: RemoteTerminalRenderState?
    private var availableSize: CGSize = .zero
    private var cellSize = RemoteTerminalFontMetrics.cellSize()
    private var viewportCols = 0
    private var viewportRows = 0
    private var isSyncingScroll = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        scrollView.delegate = self
        scrollView.backgroundColor = .clear
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true
        addSubview(scrollView)

        scrollContentView.backgroundColor = .clear
        scrollView.addSubview(scrollContentView)

        canvasView.isUserInteractionEnabled = false
        canvasView.backgroundColor = .black
        addSubview(canvasView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        canvasView.frame = bounds
        recalculateViewport()
        syncScrollPosition(force: false)
    }

    func update(store: RemoteTerminalRendererStore, renderState: RemoteTerminalRenderState?, availableSize: CGSize) {
        self.store = store
        self.renderState = renderState
        self.availableSize = availableSize
        canvasView.renderState = renderState
        recalculateViewport()
        syncScrollPosition(force: false)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isSyncingScroll, let store, let renderState else { return }
        let maxOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let distanceFromBottom = max(0, maxOffset - scrollView.contentOffset.y)
        let desiredDisplayOffset = Int(round(distanceFromBottom / cellSize.height))
        let clamped = min(max(desiredDisplayOffset, 0), renderState.scrollbackRows)
        store.scrollActive(to: clamped)
    }

    private func recalculateViewport() {
        guard let store else { return }
        let width = max(availableSize.width, bounds.width)
        let height = max(availableSize.height, bounds.height)
        guard width > 0, height > 0 else { return }

        let newCols = max(1, Int(floor(width / max(cellSize.width, 1))))
        let newRows = max(1, Int(floor(height / max(cellSize.height, 1))))
        guard newCols != viewportCols || newRows != viewportRows else { return }

        viewportCols = newCols
        viewportRows = newRows
        store.setViewport(cols: newCols, rows: newRows)
    }

    private func syncScrollPosition(force: Bool) {
        guard let renderState else {
            scrollContentView.frame = CGRect(origin: .zero, size: bounds.size)
            scrollView.contentSize = bounds.size
            return
        }

        let contentHeight = max(bounds.height, CGFloat(max(renderState.totalRows, renderState.rows)) * cellSize.height)
        scrollContentView.frame = CGRect(x: 0, y: 0, width: max(bounds.width, 1), height: contentHeight)
        scrollView.contentSize = scrollContentView.frame.size

        let maxOffset = max(0, contentHeight - bounds.height)
        let targetOffsetY = max(0, maxOffset - CGFloat(renderState.displayOffset) * cellSize.height)

        if force || abs(scrollView.contentOffset.y - targetOffsetY) > (cellSize.height / 2) {
            isSyncingScroll = true
            scrollView.setContentOffset(CGPoint(x: 0, y: targetOffsetY), animated: false)
            isSyncingScroll = false
        }
    }
}

private final class RemoteTerminalCanvasView: UIView {
    var renderState: RemoteTerminalRenderState? {
        didSet { setNeedsDisplay() }
    }

    private let regularFont = RemoteTerminalFontMetrics.baseFont
    private lazy var boldFont = UIFont.monospacedSystemFont(ofSize: regularFont.pointSize, weight: .bold)
    private lazy var italicFont = italicVariant(for: regularFont) ?? regularFont
    private lazy var boldItalicFont = italicVariant(for: boldFont) ?? boldFont
    private let cellSize = RemoteTerminalFontMetrics.cellSize()
    private var colorCache = TerminalColorCache()

    override func draw(_ rect: CGRect) {
        guard let renderState else {
            UIColor.black.setFill()
            UIBezierPath(rect: bounds).fill()
            return
        }

        guard let context = UIGraphicsGetCurrentContext() else { return }
        UIColor.black.setFill()
        context.fill(bounds)

        let rows = renderState.rows
        let cols = renderState.cols
        guard rows > 0, cols > 0 else { return }

        let cellW = cellSize.width
        let cellH = cellSize.height
        let lineHeight = regularFont.lineHeight
        let baselineOffset = (cellH - lineHeight) / 2

        // Background pass: batch consecutive cells with same bg color into single fills
        context.setAllowsAntialiasing(false)
        context.setShouldAntialias(false)
        for row in 0 ..< rows {
            let rowStartIndex = row * cols
            guard rowStartIndex < renderState.cells.count else { break }
            let y = CGFloat(row) * cellH
            var runStart = 0
            var runColorKey = colorCache.backgroundKey(for: renderState.cells[rowStartIndex])
            for col in 1 ..< cols {
                let idx = row * cols + col
                guard idx < renderState.cells.count else { break }
                let key = colorCache.backgroundKey(for: renderState.cells[idx])
                if key != runColorKey {
                    fillBackgroundRun(context: context, row: row, startCol: runStart, endCol: col, colorKey: runColorKey, y: y, cellW: cellW, cellH: cellH)
                    runStart = col
                    runColorKey = key
                }
            }
            fillBackgroundRun(context: context, row: row, startCol: runStart, endCol: cols, colorKey: runColorKey, y: y, cellW: cellW, cellH: cellH)
        }

        if renderState.cursorVisible,
           renderState.cursorRow >= 0, renderState.cursorRow < rows,
           renderState.cursorCol >= 0, renderState.cursorCol < cols {
            UIColor.white.withAlphaComponent(0.28).setFill()
            UIRectFill(CGRect(
                x: CGFloat(renderState.cursorCol) * cellW,
                y: CGFloat(renderState.cursorRow) * cellH,
                width: cellW,
                height: cellH
            ))
        }

        // Text pass
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        for row in 0 ..< rows {
            let y = CGFloat(row) * cellH
            for col in 0 ..< cols {
                let idx = row * cols + col
                guard idx < renderState.cells.count else { continue }
                let cell = renderState.cells[idx]
                if cell.flags & rustCellFlagHidden != 0 { continue }
                guard let scalar = UnicodeScalar(cell.character), scalar.value != 0, scalar != " " else { continue }

                let fgKey = colorCache.foregroundKey(for: cell)
                let fg = colorCache.foreground(forKey: fgKey)
                let font = resolvedFont(for: cell)
                let str = String(scalar) as NSString
                str.draw(
                    at: CGPoint(x: CGFloat(col) * cellW, y: y + baselineOffset),
                    withAttributes: colorCache.textAttributes(font: font, colorKey: fgKey, color: fg)
                )

                let x = CGFloat(col) * cellW
                if cell.flags & rustCellFlagUnderline != 0 {
                    fg.setStroke()
                    context.setLineWidth(1)
                    context.move(to: CGPoint(x: x, y: y + cellH - 2))
                    context.addLine(to: CGPoint(x: x + cellW, y: y + cellH - 2))
                    context.strokePath()
                }
                if cell.flags & rustCellFlagStrikethrough != 0 {
                    fg.setStroke()
                    context.setLineWidth(1)
                    context.move(to: CGPoint(x: x, y: y + cellH / 2))
                    context.addLine(to: CGPoint(x: x + cellW, y: y + cellH / 2))
                    context.strokePath()
                }
            }
        }
    }

    private func fillBackgroundRun(context: CGContext, row: Int, startCol: Int, endCol: Int, colorKey: UInt32, y: CGFloat, cellW: CGFloat, cellH: CGFloat) {
        guard colorKey != 0 else { return } // Skip black (already cleared)
        colorCache.background(forKey: colorKey).setFill()
        UIRectFill(CGRect(
            x: CGFloat(startCol) * cellW,
            y: y,
            width: CGFloat(endCol - startCol) * cellW,
            height: cellH
        ))
    }

    private func italicVariant(for font: UIFont) -> UIFont? {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits([.traitItalic]) else { return nil }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    private func resolvedFont(for cell: RustCellData) -> UIFont {
        let bold = cell.flags & rustCellFlagBold != 0
        let italic = cell.flags & rustCellFlagItalic != 0
        switch (bold, italic) {
        case (true, true):   return boldItalicFont
        case (true, false):  return boldFont
        case (false, true):  return italicFont
        case (false, false): return regularFont
        }
    }
}

/// Caches UIColor and text attribute dictionaries to avoid per-cell allocations during draw.
private struct TerminalColorCache {
    private var fgCache: [UInt32: UIColor] = [:]
    private var bgCache: [UInt32: UIColor] = [:]
    private var attrCache: [AttrKey: [NSAttributedString.Key: Any]] = [:]

    private struct AttrKey: Hashable {
        let fontID: ObjectIdentifier
        let colorKey: UInt32
    }

    func foregroundKey(for cell: RustCellData) -> UInt32 {
        let inv = cell.flags & rustCellFlagInverse != 0
        let r = inv ? cell.bg_r : cell.fg_r
        let g = inv ? cell.bg_g : cell.fg_g
        let b = inv ? cell.bg_b : cell.fg_b
        let dim = cell.flags & rustCellFlagDim != 0
        return UInt32(r) << 24 | UInt32(g) << 16 | UInt32(b) << 8 | (dim ? 1 : 0)
    }

    mutating func foreground(forKey key: UInt32) -> UIColor {
        if let cached = fgCache[key] { return cached }
        let r = UInt8((key >> 24) & 0xFF)
        let g = UInt8((key >> 16) & 0xFF)
        let b = UInt8((key >> 8) & 0xFF)
        let dim = key & 0x1 == 1
        let color = UIColor(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: dim ? 0.7 : 1.0
        )
        fgCache[key] = color
        return color
    }

    func backgroundKey(for cell: RustCellData) -> UInt32 {
        let inv = cell.flags & rustCellFlagInverse != 0
        let r = inv ? cell.fg_r : cell.bg_r
        let g = inv ? cell.fg_g : cell.bg_g
        let b = inv ? cell.fg_b : cell.bg_b
        return UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
    }

    mutating func background(forKey key: UInt32) -> UIColor {
        if let cached = bgCache[key] { return cached }
        let color = UIColor(
            red: CGFloat((key >> 16) & 0xFF) / 255,
            green: CGFloat((key >> 8) & 0xFF) / 255,
            blue: CGFloat(key & 0xFF) / 255,
            alpha: 1.0
        )
        bgCache[key] = color
        return color
    }

    mutating func textAttributes(font: UIFont, colorKey: UInt32, color: UIColor) -> [NSAttributedString.Key: Any] {
        let key = AttrKey(
            fontID: ObjectIdentifier(font),
            colorKey: colorKey
        )
        if let cached = attrCache[key] { return cached }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        attrCache[key] = attrs
        return attrs
    }
}
