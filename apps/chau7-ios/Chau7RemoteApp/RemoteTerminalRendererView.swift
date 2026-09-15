import Chau7Core
import CoreText
import SwiftUI
import UIKit

/// iOS (UIKit/SwiftUI) color conversion for the shared `TerminalColorScheme`.
/// Mirrors the macOS `NSColor` extension; the pure-data struct lives in `Chau7Core`.
extension TerminalColorScheme {
    func uiColor(_ hex: String) -> UIColor {
        guard let rgb = ColorParsing.parseHex(hex) else { return .black }
        return UIColor(red: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
    }

    var backgroundUIColor: UIColor { uiColor(background) }
    var foregroundUIColor: UIColor { uiColor(foreground) }
    var cursorUIColor: UIColor { uiColor(cursor) }

    /// Packed `0xRRGGBB` key matching `TerminalColorCache.backgroundKey`, so the
    /// canvas can cheaply skip cells whose background equals the scheme default.
    var backgroundColorKey: UInt32 {
        let (r, g, b) = backgroundRGB888
        return UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
    }
}

/// Dual-path terminal renderer: text-based UITextView (default) or experimental
/// grid canvas with per-cell color, bold/italic/underline, cursor, and scrollback.
/// The canvas batches background fills by color run and caches UIColor/text
/// attributes to avoid per-cell allocations.
struct RemoteTerminalRendererView: View {
    let client: RemoteClient
    @AppStorage(AppSettings.renderANSIKey) private var renderANSI = AppSettings.renderANSIDefault
    @AppStorage(AppSettings.terminalFontSizeKey) private var terminalFontSize = AppSettings.terminalFontSizeDefault
    @AppStorage(AppSettings.colorSchemeNameKey) private var colorSchemeName = AppSettings.colorSchemeNameDefault

    private var colorScheme: TerminalColorScheme {
        AppSettings.colorScheme(named: colorSchemeName)
    }

    var body: some View {
        Group {
            if client.terminalRenderer.isAvailable, client.terminalRenderer.renderState != nil {
                GeometryReader { proxy in
                    let renderState = client.terminalRenderer.renderState
                    RemoteTerminalRendererRepresentable(
                        store: client.terminalRenderer,
                        renderState: renderState,
                        frameTrace: client.terminalRenderer.publishedTrace,
                        availableSize: proxy.size,
                        colorScheme: colorScheme
                    )
                    .background(Color(colorScheme.backgroundUIColor))
                }
            } else {
                RemoteTerminalTextView(
                    text: renderANSI ? client.outputText : client.strippedOutputText,
                    fontSize: CGFloat(terminalFontSize),
                    colorScheme: colorScheme
                )
            }
        }
        .onAppear {
            client.terminalRenderer.setActiveTab(client.activeTabID)
        }
        .onChange(of: client.activeTabID) { _, newTabID in
            client.terminalRenderer.setActiveTab(newTabID)
        }
        .overlay(alignment: .bottomTrailing) {
            if isAwayFromBottom {
                Button {
                    client.terminalRenderer.scrollActive(to: 0)
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor, in: Circle())
                        .shadow(radius: 4, y: 2)
                }
                .accessibilityLabel("Jump to latest output")
                .padding(.trailing, 14)
                .padding(.bottom, 14)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isAwayFromBottom)
    }

    private var isAwayFromBottom: Bool {
        (client.terminalRenderer.renderState?.displayOffset ?? 0) > 0
    }
}

private struct RemoteTerminalRendererRepresentable: UIViewRepresentable {
    let store: RemoteTerminalRendererStore
    let renderState: RemoteTerminalRenderState?
    let frameTrace: RemoteTerminalFrameTrace?
    let availableSize: CGSize
    let colorScheme: TerminalColorScheme

    func makeUIView(context: Context) -> RemoteTerminalViewportView {
        let view = RemoteTerminalViewportView()
        view.update(
            store: store,
            renderState: renderState,
            frameTrace: frameTrace,
            availableSize: availableSize,
            colorScheme: colorScheme
        )
        return view
    }

    func updateUIView(_ uiView: RemoteTerminalViewportView, context: Context) {
        uiView.update(
            store: store,
            renderState: renderState,
            frameTrace: frameTrace,
            availableSize: availableSize,
            colorScheme: colorScheme
        )
    }
}

struct RemoteTerminalTextView: View {
    let text: String
    var fontSize: CGFloat
    var colorScheme: TerminalColorScheme
    @Binding var isAwayFromBottom: Bool
    var scrollToBottomToken: Int

    init(
        text: String,
        fontSize: CGFloat = CGFloat(AppSettings.terminalFontSizeDefault),
        colorScheme: TerminalColorScheme = AppSettings.currentColorScheme,
        isAwayFromBottom: Binding<Bool> = .constant(false),
        scrollToBottomToken: Int = 0
    ) {
        self.text = text
        self.fontSize = fontSize
        self.colorScheme = colorScheme
        self._isAwayFromBottom = isAwayFromBottom
        self.scrollToBottomToken = scrollToBottomToken
    }

    var body: some View {
        RemoteTerminalTextViewRepresentable(
            text: boundedTranscript(text),
            fontSize: fontSize,
            colorScheme: colorScheme,
            isAwayFromBottom: $isAwayFromBottom,
            scrollToBottomToken: scrollToBottomToken
        )
        .background(Color(colorScheme.backgroundUIColor))
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
    let fontSize: CGFloat
    let colorScheme: TerminalColorScheme
    @Binding var isAwayFromBottom: Bool
    let scrollToBottomToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = colorScheme.backgroundUIColor
        textView.textColor = colorScheme.foregroundUIColor
        textView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.showsVerticalScrollIndicator = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.textContainer.lineFragmentPadding = 0
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.autocorrectionType = .no
        textView.delegate = context.coordinator
        textView.accessibilityLabel = "Terminal output"
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self

        if abs((textView.font?.pointSize ?? fontSize) - fontSize) > 0.5 {
            textView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }

        let bg = colorScheme.backgroundUIColor
        let fg = colorScheme.foregroundUIColor
        if textView.backgroundColor != bg { textView.backgroundColor = bg }
        if textView.textColor != fg { textView.textColor = fg }

        let wasNearBottom = textView.isNearBottom
        if textView.text != text {
            textView.text = text
        }

        let forceScroll = context.coordinator.lastScrollToken != scrollToBottomToken
        context.coordinator.lastScrollToken = scrollToBottomToken

        if wasNearBottom || forceScroll {
            textView.scrollRangeToVisible(NSRange(location: max(text.utf16.count - 1, 0), length: 1))
        }
        context.coordinator.updateAwayState(textView)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RemoteTerminalTextViewRepresentable
        var lastScrollToken: Int

        init(_ parent: RemoteTerminalTextViewRepresentable) {
            self.parent = parent
            self.lastScrollToken = parent.scrollToBottomToken
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let textView = scrollView as? UITextView else { return }
            updateAwayState(textView)
        }

        func updateAwayState(_ textView: UITextView) {
            let away = !textView.isNearBottom && textView.contentSize.height > textView.bounds.height
            guard parent.isAwayFromBottom != away else { return }
            DispatchQueue.main.async { [parent] in
                parent.isAwayFromBottom = away
            }
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
        backgroundColor = TerminalColorScheme.default.backgroundUIColor

        scrollView.delegate = self
        scrollView.backgroundColor = .clear
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true
        addSubview(scrollView)

        scrollContentView.backgroundColor = .clear
        scrollView.addSubview(scrollContentView)

        canvasView.isUserInteractionEnabled = false
        canvasView.backgroundColor = TerminalColorScheme.default.backgroundUIColor
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

    func update(
        store: RemoteTerminalRendererStore,
        renderState: RemoteTerminalRenderState?,
        frameTrace: RemoteTerminalFrameTrace?,
        availableSize: CGSize,
        colorScheme: TerminalColorScheme
    ) {
        self.store = store
        self.renderState = renderState
        self.availableSize = availableSize
        let bg = colorScheme.backgroundUIColor
        if backgroundColor != bg { backgroundColor = bg }
        if canvasView.backgroundColor != bg { canvasView.backgroundColor = bg }
        canvasView.colorScheme = colorScheme
        var updatedTrace = frameTrace
        updatedTrace?.viewUpdatedAt = Date()
        canvasView.update(renderState: renderState, frameTrace: updatedTrace)
        canvasView.onFrameDrawn = { [weak store] trace in
            store?.recordCanvasDrawn(trace)
        }
        recalculateViewport()
        syncScrollPosition(force: false)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let store, let renderState else { return }
        guard RemoteTerminalScrollPolicy.shouldForwardUserScroll(
            isSynchronizing: isSyncingScroll,
            isTracking: scrollView.isTracking,
            isDragging: scrollView.isDragging,
            isDecelerating: scrollView.isDecelerating
        ) else { return }
        let displayOffset = RemoteTerminalScrollPolicy.displayOffset(
            contentHeight: Double(scrollView.contentSize.height),
            viewportHeight: Double(scrollView.bounds.height),
            contentOffsetY: Double(scrollView.contentOffset.y),
            cellHeight: Double(cellSize.height),
            scrollbackRows: renderState.scrollbackRows
        )
        store.scrollActive(to: displayOffset)
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
        isSyncingScroll = true
        defer { isSyncingScroll = false }

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
            scrollView.setContentOffset(CGPoint(x: 0, y: targetOffsetY), animated: false)
        }
    }
}

private final class RemoteTerminalCanvasView: UIView {
    private var renderState: RemoteTerminalRenderState?
    private var frameTrace: RemoteTerminalFrameTrace?
    private var lastDrawnTraceIdentity: RemoteTerminalFrameIdentity?
    var onFrameDrawn: ((RemoteTerminalFrameTrace) -> Void)?

    func update(
        renderState: RemoteTerminalRenderState?,
        frameTrace: RemoteTerminalFrameTrace?
    ) {
        self.renderState = renderState
        self.frameTrace = frameTrace
        setNeedsDisplay()
    }

    var colorScheme: TerminalColorScheme = .default {
        didSet {
            guard colorScheme.signature != oldValue.signature else { return }
            setNeedsDisplay()
        }
    }

    private let regularFont = RemoteTerminalFontMetrics.baseFont
    private lazy var boldFont = UIFont.monospacedSystemFont(ofSize: regularFont.pointSize, weight: .bold)
    private lazy var italicFont = italicVariant(for: regularFont) ?? regularFont
    private lazy var boldItalicFont = italicVariant(for: boldFont) ?? boldFont
    private let cellSize = RemoteTerminalFontMetrics.cellSize()
    private var colorCache = TerminalColorCache()

    override func draw(_ rect: CGRect) {
        let schemeBackground = colorScheme.backgroundUIColor
        guard let renderState else {
            schemeBackground.setFill()
            UIBezierPath(rect: bounds).fill()
            return
        }

        guard let context = UIGraphicsGetCurrentContext() else { return }
        defer { acknowledgeDrawnFrame() }
        schemeBackground.setFill()
        context.fill(bounds)
        let backgroundColorKey = colorScheme.backgroundColorKey

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
                    fillBackgroundRun(context: context, row: row, startCol: runStart, endCol: col, colorKey: runColorKey, skipColorKey: backgroundColorKey, y: y, cellW: cellW, cellH: cellH)
                    runStart = col
                    runColorKey = key
                }
            }
            fillBackgroundRun(context: context, row: row, startCol: runStart, endCol: cols, colorKey: runColorKey, skipColorKey: backgroundColorKey, y: y, cellW: cellW, cellH: cellH)
        }

        if renderState.cursorVisible,
           renderState.cursorRow >= 0, renderState.cursorRow < rows,
           renderState.cursorCol >= 0, renderState.cursorCol < cols {
            colorScheme.cursorUIColor.withAlphaComponent(0.28).setFill()
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
                if cell.continuation != 0 { continue }
                let clusterStr = renderState.clusterString(for: cell)
                if clusterStr.isEmpty || clusterStr == " " { continue }

                let fgKey = colorCache.foregroundKey(for: cell)
                let fg = colorCache.foreground(forKey: fgKey)
                let font = resolvedFont(for: cell)
                let str = clusterStr as NSString
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

    private func acknowledgeDrawnFrame() {
        guard var trace = frameTrace,
              trace.identity != lastDrawnTraceIdentity else { return }
        trace.canvasDrawnAt = Date()
        lastDrawnTraceIdentity = trace.identity
        onFrameDrawn?(trace)
    }

    private func fillBackgroundRun(context: CGContext, row: Int, startCol: Int, endCol: Int, colorKey: UInt32, skipColorKey: UInt32, y: CGFloat, cellW: CGFloat, cellH: CGFloat) {
        guard colorKey != skipColorKey else { return } // Skip scheme background (already cleared)
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
