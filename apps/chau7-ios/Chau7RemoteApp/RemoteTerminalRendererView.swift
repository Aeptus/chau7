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
    @AppStorage("terminal_show_render_diagnostics") private var showsRenderDiagnostics = false

    private var colorScheme: TerminalColorScheme {
        client.terminalRenderer.colorScheme
    }

    var body: some View {
        // The viewport is declared unconditionally from this GeometryReader,
        // and that declaration is the ONLY thing that tells the store the grid
        // dimensions. The store cannot build a playback — and therefore cannot
        // publish a `renderState` — until it has been told the viewport, so
        // gating the declaration behind `renderState != nil` deadlocked the
        // renderer: it could never start, and because `.replay` mode
        // deliberately does not feed the plain-text output store, the text
        // fallback then rendered a permanently empty terminal.
        GeometryReader { proxy in
            Group {
                if client.terminalRenderer.isAvailable,
                   let renderState = client.terminalRenderer.renderState {
                    RemoteTerminalRendererRepresentable(
                        store: client.terminalRenderer,
                        renderState: renderState,
                        displayState: client.terminalRenderer.displayState,
                        isAlternateScreenActive: client.terminalRenderer.isActiveAlternateScreen,
                        frameTrace: client.terminalRenderer.publishedTrace,
                        availableSize: proxy.size,
                        colorScheme: colorScheme,
                        fontSize: CGFloat(terminalFontSize),
                        showsDiagnostics: showsRenderDiagnostics
                    )
                    .background(Color(colorScheme.backgroundUIColor))
                } else {
                    RemoteTerminalTextView(
                        text: renderANSI ? client.outputText : client.strippedOutputText,
                        fontSize: CGFloat(terminalFontSize),
                        colorScheme: colorScheme
                    )
                }
            }
            .onAppear {
                RemoteTerminalViewportDeclaration.declare(
                    proxy.size,
                    fontSize: CGFloat(terminalFontSize),
                    on: client.terminalRenderer
                )
            }
            .onChange(of: proxy.size) { _, newSize in
                RemoteTerminalViewportDeclaration.declare(
                    newSize,
                    fontSize: CGFloat(terminalFontSize),
                    on: client.terminalRenderer
                )
            }
            .onChange(of: terminalFontSize) { _, newSize in
                // A new text size changes the cell metrics, so the engine must
                // be re-sized to the grid the canvas will now paint.
                RemoteTerminalViewportDeclaration.declare(
                    proxy.size,
                    fontSize: CGFloat(newSize),
                    on: client.terminalRenderer
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
                    client.terminalRenderer.scrollActive(toNormalized: 0)
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
    let displayState: RemoteTerminalDisplayState?
    let isAlternateScreenActive: Bool
    let frameTrace: RemoteTerminalFrameTrace?
    let availableSize: CGSize
    let colorScheme: TerminalColorScheme
    let fontSize: CGFloat
    let showsDiagnostics: Bool

    func makeUIView(context: Context) -> RemoteTerminalViewportView {
        let view = RemoteTerminalViewportView()
        view.update(
            store: store,
            renderState: renderState,
            displayState: displayState,
            isAlternateScreenActive: isAlternateScreenActive,
            frameTrace: frameTrace,
            availableSize: availableSize,
            colorScheme: colorScheme,
            fontSize: fontSize,
            showsDiagnostics: showsDiagnostics
        )
        return view
    }

    func updateUIView(_ uiView: RemoteTerminalViewportView, context: Context) {
        uiView.update(
            store: store,
            renderState: renderState,
            displayState: displayState,
            isAlternateScreenActive: isAlternateScreenActive,
            frameTrace: frameTrace,
            availableSize: availableSize,
            colorScheme: colorScheme,
            fontSize: fontSize,
            showsDiagnostics: showsDiagnostics
        )
    }
}

/// Declares the terminal grid dimensions to the render store from a laid-out
/// view. It is mounted unconditionally — including while the rich renderer is
/// still waiting for its first `renderState` — because the store cannot build a
/// playback (and therefore cannot publish a `renderState`) until it has been
/// told the viewport size. Gating this on `renderState != nil` creates an
/// unbreakable circular dependency and the terminal never renders.
///
/// The cell size is measured for the *same font the canvas draws with*
/// (`RemoteTerminalFontMetrics.metrics(for:)`), so the grid the engine is sized
/// to always matches the glyphs painted into it — including when the user
/// changes the Text Size setting. The arithmetic itself lives in
/// `RemoteTerminalViewportGeometry` so it is unit testable without the UIKit
/// font stack.
enum RemoteTerminalViewportDeclaration {
    static func declare(
        _ size: CGSize,
        fontSize: CGFloat,
        on store: RemoteTerminalRendererStore
    ) {
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let cell = RemoteTerminalFontMetrics.metrics(for: font).cellSize
        guard let viewport = RemoteTerminalViewportGeometry.gridSize(available: size, cell: cell) else { return }
        store.setViewport(cols: viewport.cols, rows: viewport.rows)
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
    private var displayState: RemoteTerminalDisplayState?
    private var isAlternateScreenActive = false
    private var lastSyncedAlternateScreenActive: Bool?
    private var availableSize: CGSize = .zero
    /// Cell geometry comes straight from the canvas so the grid we size the
    /// engine to, the cells it paints, and the scroll math all agree — and so
    /// they follow the user's Text Size setting together.
    private var cellSize: CGSize { canvasView.metrics.cellSize }
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
        insertSubview(canvasView, belowSubview: scrollView)
        clipsToBounds = true
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
        displayState: RemoteTerminalDisplayState?,
        isAlternateScreenActive: Bool,
        frameTrace: RemoteTerminalFrameTrace?,
        availableSize: CGSize,
        colorScheme: TerminalColorScheme,
        fontSize: CGFloat,
        showsDiagnostics: Bool = false
    ) {
        self.store = store
        self.renderState = renderState
        self.displayState = displayState
        self.isAlternateScreenActive = isAlternateScreenActive
        self.availableSize = availableSize
        let bg = colorScheme.backgroundUIColor
        if backgroundColor != bg { backgroundColor = bg }
        if canvasView.backgroundColor != bg { canvasView.backgroundColor = bg }
        canvasView.colorScheme = colorScheme
        canvasView.showsDiagnostics = showsDiagnostics
        canvasView.isAlternateScreenActive = isAlternateScreenActive
        // A new text size changes the cell metrics, so the grid must be
        // recomputed (cols/rows) before the next frame.
        if canvasView.fontSize != fontSize {
            canvasView.fontSize = fontSize
            viewportCols = 0
            viewportRows = 0
        }
        var updatedTrace = frameTrace
        updatedTrace?.viewUpdatedAt = Date()
        canvasView.update(
            renderState: renderState,
            displayState: displayState,
            frameTrace: updatedTrace
        )
        canvasView.onFrameDrawn = { [weak store] trace in
            store?.recordCanvasDrawn(trace)
        }
        recalculateViewport()
        syncScrollPosition(force: false)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if isAlternateScreenActive {
            canvasView.contentOffset = scrollView.contentOffset
            return
        }
        guard let store, let renderState else { return }
        guard RemoteTerminalScrollPolicy.shouldForwardUserScroll(
            isSynchronizing: isSyncingScroll,
            isTracking: scrollView.isTracking,
            isDragging: scrollView.isDragging,
            isDecelerating: scrollView.isDecelerating
        ) else { return }
        let displayCols = max(1, Int((bounds.width / max(cellSize.width, 1)).rounded(.down)))
        let chunks = RemoteTerminalWrapGeometry.chunksPerRow(sourceCols: renderState.cols, displayCols: displayCols)
        let fraction = RemoteTerminalScrollPolicy.normalizedOffset(
            contentHeight: Double(scrollView.contentSize.height),
            viewportHeight: Double(scrollView.bounds.height),
            contentOffsetY: Double(scrollView.contentOffset.y),
            cellHeight: Double(cellSize.height),
            scrollbackRows: renderState.scrollbackRows,
            chunksPerRow: chunks
        )
        store.scrollActive(toNormalized: fraction)
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

        scrollView.showsHorizontalScrollIndicator = isAlternateScreenActive
        scrollView.alwaysBounceHorizontal = isAlternateScreenActive

        guard let renderState else {
            scrollContentView.frame = CGRect(origin: .zero, size: bounds.size)
            scrollView.contentSize = bounds.size
            canvasView.frame = bounds
            return
        }

        let alternateScreenModeChanged = lastSyncedAlternateScreenActive != isAlternateScreenActive
        let maySynchronize = RemoteTerminalScrollPolicy.shouldSynchronizePosition(
            force: force || alternateScreenModeChanged,
            isTracking: scrollView.isTracking,
            isDragging: scrollView.isDragging,
            isDecelerating: scrollView.isDecelerating
        )
        if isAlternateScreenActive {
            let contentSize = RemoteTerminalViewportGeometry.alternateScreenContentSize(
                cols: renderState.cols,
                rows: renderState.rows,
                cell: cellSize,
                viewport: bounds.size
            ) ?? bounds.size
            scrollContentView.frame = CGRect(origin: .zero, size: contentSize)
            scrollView.contentSize = contentSize
            let maxX = max(0, contentSize.width - bounds.width)
            let maxY = max(0, contentSize.height - bounds.height)
            let targetOffset = alternateScreenModeChanged
                ? CGPoint.zero
                : CGPoint(
                    x: min(max(scrollView.contentOffset.x, 0), maxX),
                    y: min(max(scrollView.contentOffset.y, 0), maxY)
                )
            if maySynchronize && (force || alternateScreenModeChanged
                || abs(scrollView.contentOffset.x - targetOffset.x) > 1
                || abs(scrollView.contentOffset.y - targetOffset.y) > 1) {
                scrollView.setContentOffset(targetOffset, animated: false)
            }
            // A viewport-sized layer avoids allocating/rasterizing the whole TUI.
            // Translate drawing instead of moving a source-grid-sized UIView.
            canvasView.frame = bounds
            canvasView.contentOffset = scrollView.contentOffset
            canvasView.setNeedsDisplay()
            lastSyncedAlternateScreenActive = true
            return
        }

        lastSyncedAlternateScreenActive = false
        canvasView.frame = bounds
        canvasView.contentOffset = .zero

        // Content height is measured in phone-width rows, which is what the canvas
        // paints: the engine holds the wider source grid, so its own row count
        // understates the visible height once rows are re-wrapped.
        let displayCols = max(1, Int((bounds.width / max(cellSize.width, 1)).rounded(.down)))
        let chunksPerRow = RemoteTerminalWrapGeometry.chunksPerRow(sourceCols: renderState.cols, displayCols: displayCols)
        let displayRows = RemoteTerminalWrapGeometry.displayRowCount(sourceRows: renderState.totalRows, chunksPerRow: chunksPerRow)
        let contentHeight = max(bounds.height, CGFloat(displayRows) * cellSize.height)
        scrollContentView.frame = CGRect(x: 0, y: 0, width: max(bounds.width, 1), height: contentHeight)
        scrollView.contentSize = scrollContentView.frame.size

        let maxOffset = max(0, contentHeight - bounds.height)
        let targetOffsetY = max(0, maxOffset - CGFloat(renderState.displayOffset * chunksPerRow) * cellSize.height)

        if maySynchronize && (force
            || abs(scrollView.contentOffset.x) > 1
            || abs(scrollView.contentOffset.y - targetOffsetY) > (cellSize.height / 2)) {
            scrollView.setContentOffset(CGPoint(x: 0, y: targetOffsetY), animated: false)
        }
    }
}

private final class RemoteTerminalCanvasView: UIView {
    var isAlternateScreenActive = false
    var contentOffset: CGPoint = .zero {
        didSet {
            if contentOffset != oldValue { setNeedsDisplay() }
        }
    }
    private var renderState: RemoteTerminalRenderState?
    /// Engine-folded rows, when the grid is wider than the phone. Painting these
    /// removes the per-frame source-to-display index remap and the fold the
    /// canvas used to do itself.
    private var displayState: RemoteTerminalDisplayState?
    private var frameTrace: RemoteTerminalFrameTrace?
    private var lastDrawnTraceIdentity: RemoteTerminalFrameIdentity?
    var onFrameDrawn: ((RemoteTerminalFrameTrace) -> Void)?

    func update(
        renderState: RemoteTerminalRenderState?,
        displayState: RemoteTerminalDisplayState?,
        frameTrace: RemoteTerminalFrameTrace?
    ) {
        self.renderState = renderState
        self.displayState = displayState
        self.frameTrace = frameTrace
        setNeedsDisplay()
    }

    var colorScheme: TerminalColorScheme = .default {
        didSet {
            guard colorScheme.signature != oldValue.signature else { return }
            setNeedsDisplay()
        }
    }

    /// Rendered text size, driven by the user's Text Size setting. Changing it
    /// rebuilds the fonts and the cell metrics together so the grid the engine
    /// is sized to always matches the glyphs that are painted into it.
    var fontSize: CGFloat = RemoteTerminalFontMetrics.baseFont.pointSize {
        didSet {
            let clamped = min(max(fontSize, 6), 40)
            guard abs(clamped - oldValue) > 0.01 else { return }
            fontSize = clamped
            rebuildFontResources()
            setNeedsDisplay()
        }
    }

    private(set) var regularFont = RemoteTerminalFontMetrics.baseFont
    private(set) var boldFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private(set) var italicFont: UIFont = RemoteTerminalFontMetrics.baseFont
    private(set) var boldItalicFont: UIFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private(set) var metrics = RemoteTerminalFontMetrics.metrics(for: RemoteTerminalFontMetrics.baseFont)
    private var colorCache = TerminalColorCache()

    private func rebuildFontResources() {
        let size = fontSize
        regularFont = .monospacedSystemFont(ofSize: size, weight: .regular)
        boldFont = .monospacedSystemFont(ofSize: size, weight: .bold)
        italicFont = italicVariant(for: regularFont) ?? regularFont
        boldItalicFont = italicVariant(for: boldFont) ?? boldFont
        metrics = RemoteTerminalFontMetrics.metrics(for: regularFont)
        colorCache = TerminalColorCache()
    }

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

        let sourceRows = renderState.rows
        let sourceCols = renderState.cols
        guard sourceRows > 0, sourceCols > 0 else { return }

        let cellW = metrics.cellWidth
        let cellH = metrics.cellHeight
        // Baseline derived from the same font as the cell, not from
        // `UIFont.lineHeight` (a different metric than the CTFont line box the
        // cell is built from, which produced a negative offset and stacked
        // every line into the row above it).
        let baselineOffset = metrics.baselineOffset

        // The engine holds the source grid (Mac PTY width); this canvas holds
        // phone-width rows. Each source row is re-wrapped across as many
        // phone-width rows as it needs, so the content reads top-to-bottom on a
        // narrow screen instead of being clipped.
        let displayCols = isAlternateScreenActive
            ? sourceCols
            : max(1, Int((bounds.width / cellW).rounded(.down)))
        let visibleRect = rect.intersection(bounds).offsetBy(dx: contentOffset.x, dy: contentOffset.y)
        context.translateBy(x: -contentOffset.x, y: -contentOffset.y)

        // Preferred path: the engine already folded the grid to the phone's
        // width, joining soft-wrapped rows, so painting is a blit — no
        // source-to-display index remap and no per-cell fold decision.
        if let displayState, displayState.displayCols == displayCols, displayState.displayRows > 0 {
            drawFolded(
                displayState,
                context: context,
                cellW: cellW,
                cellH: cellH,
                baselineOffset: baselineOffset,
                backgroundColorKey: backgroundColorKey,
                visibleRect: visibleRect
            )
            if showsDiagnostics {
                drawFoldedDiagnostics(context: context, display: displayState, cellW: cellW, cellH: cellH)
            }
            return
        }

        // Fallback: the engine did not fold (1:1 grid, or the export failed), so
        // the canvas folds physical rows itself. Less correct across soft wraps,
        // which is why this is now the backup rather than the only path.
        let chunksPerRow = RemoteTerminalWrapGeometry.chunksPerRow(sourceCols: sourceCols, displayCols: displayCols)
        let displayRows = RemoteTerminalWrapGeometry.displayRowCount(sourceRows: sourceRows, chunksPerRow: chunksPerRow)

        let visibleRows = RemoteTerminalScrollPolicy.visibleRows(
            totalRows: displayRows, cellHeight: Double(cellH),
            minY: Double(visibleRect.minY), maxY: Double(visibleRect.maxY)
        )

        // Background pass: batch consecutive cells with same bg color into single fills
        context.setAllowsAntialiasing(false)
        context.setShouldAntialias(false)
        for displayRow in visibleRows {
            guard let slice = RemoteTerminalWrapGeometry.sourceSlice(
                displayRow: displayRow,
                sourceCols: sourceCols,
                sourceRows: sourceRows,
                chunksPerRow: chunksPerRow,
                displayCols: displayCols
            ) else { break }
            let rowStartIndex = slice.sourceRow * sourceCols + slice.firstCol
            guard rowStartIndex < renderState.cells.count else { continue }
            let y = CGFloat(displayRow) * cellH
            var runStart = 0
            var runColorKey = colorCache.backgroundKey(for: renderState.cells[rowStartIndex])
            for offset in 1 ..< slice.colCount {
                let idx = rowStartIndex + offset
                guard idx < renderState.cells.count else { break }
                let key = colorCache.backgroundKey(for: renderState.cells[idx])
                if key != runColorKey {
                    fillBackgroundRun(context: context, row: displayRow, startCol: runStart, endCol: offset, colorKey: runColorKey, skipColorKey: backgroundColorKey, y: y, cellW: cellW, cellH: cellH)
                    runStart = offset
                    runColorKey = key
                }
            }
            fillBackgroundRun(context: context, row: displayRow, startCol: runStart, endCol: slice.colCount, colorKey: runColorKey, skipColorKey: backgroundColorKey, y: y, cellW: cellW, cellH: cellH)
        }

        if renderState.cursorVisible,
           renderState.cursorRow >= 0, renderState.cursorRow < sourceRows,
           renderState.cursorCol >= 0, renderState.cursorCol < sourceCols,
           chunksPerRow > 0 {
            // The cursor cell can land in any phone-width chunk of its source
            // row, so place the highlight there rather than assuming column 0.
            let cursorDisplayRow = renderState.cursorRow * chunksPerRow + renderState.cursorCol / displayCols
            let cursorDisplayCol = renderState.cursorCol % displayCols
            colorScheme.cursorUIColor.withAlphaComponent(0.28).setFill()
            UIRectFill(CGRect(
                x: CGFloat(cursorDisplayCol) * cellW,
                y: CGFloat(cursorDisplayRow) * cellH,
                width: cellW,
                height: cellH
            ))
        }

        // Text pass
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        var decodedCells = 0
        var softWrappedRows = 0
        if showsDiagnostics {
            for sourceRow in 0 ..< sourceRows where isSoftWrappedRow(sourceRow, sourceCols: sourceCols, state: renderState) {
                softWrappedRows += 1
            }
        }

        for displayRow in visibleRows {
            guard let slice = RemoteTerminalWrapGeometry.sourceSlice(
                displayRow: displayRow,
                sourceCols: sourceCols,
                sourceRows: sourceRows,
                chunksPerRow: chunksPerRow,
                displayCols: displayCols
            ) else { break }
            let rowStartIndex = slice.sourceRow * sourceCols + slice.firstCol
            let y = CGFloat(displayRow) * cellH
            for offset in 0 ..< slice.colCount {
                let idx = rowStartIndex + offset
                guard idx < renderState.cells.count else { break }
                let cell = renderState.cells[idx]
                if cell.flags & rustCellFlagHidden != 0 { continue }
                if cell.continuation != 0 { continue }
                let clusterStr = renderState.clusterString(for: cell)
                decodedCells += 1
                if clusterStr.isEmpty || clusterStr == " " { continue }

                let fgKey = colorCache.foregroundKey(for: cell)
                let fg = colorCache.foreground(forKey: fgKey)
                let font = resolvedFont(for: cell)
                let str = clusterStr as NSString
                str.draw(
                    at: CGPoint(x: CGFloat(offset) * cellW, y: y + baselineOffset),
                    withAttributes: colorCache.textAttributes(font: font, colorKey: fgKey, color: fg)
                )

                let x = CGFloat(offset) * cellW
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

        diagnostics = RemoteTerminalRenderDiagnostics(
            sourceCols: sourceCols,
            sourceRows: sourceRows,
            displayCols: displayCols,
            displayRows: displayRows,
            scrollbackRows: renderState.scrollbackRows,
            decodedCells: decodedCells,
            drawMilliseconds: 0,
            softWrappedRows: softWrappedRows
        )
        if showsDiagnostics {
            drawDiagnostics(context: context, sourceCols: sourceCols, chunksPerRow: chunksPerRow, cellH: cellH, cellW: cellW)
        }
    }

    /// Paints the fold seams and a readout of the numbers behind them. The seams
    /// mark where a source row had to be split across phone-width rows, which is
    /// where a TUI's layout breaks; the readout says whether the engine is
    /// ingesting at the Mac's width or silently at the phone's.
    private func drawDiagnostics(
        context: CGContext,
        sourceCols: Int,
        chunksPerRow: Int,
        cellH: CGFloat,
        cellW: CGFloat
    ) {
        guard let state = renderState else { return }
        let seam = UIColor.systemOrange.withAlphaComponent(0.55)
        seam.setStroke()
        context.setLineWidth(1)
        guard chunksPerRow > 1 else {
            // Nothing is being re-composed; still worth saying so.
            drawReadout(context: context, text: "1:1  src \(sourceCols)x\(state.rows)  no fold", cellW: cellW, cellH: cellH)
            return
        }
        for sourceRow in 0 ..< state.rows where isSoftWrappedRow(sourceRow, sourceCols: sourceCols, state: state) {
            let y = CGFloat((sourceRow + 1) * chunksPerRow) * cellH
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: bounds.width, y: y))
        }
        context.strokePath()
        drawReadout(
            context: context,
            text: "src \(sourceCols)x\(state.rows) → \(diagnostics.displayCols)x\(diagnostics.displayRows)  fold x\(chunksPerRow)  softwrap \(diagnostics.softWrappedRows)  decodes \(diagnostics.decodedCells)",
            cellW: cellW,
            cellH: cellH
        )
    }

    private func drawReadout(context: CGContext, text: String, cellW: CGFloat, cellH: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: max(9, cellH * 0.6), weight: .semibold),
            .foregroundColor: UIColor.systemYellow
        ]
        (text as NSString).draw(at: CGPoint(x: 4, y: 4), withAttributes: attributes)
    }

    /// Diagnostics overlay. Off by default; toggled from Settings so a wrong
    /// render can be explained on the device instead of guessed at from code.
    var showsDiagnostics = false {
        didSet {
            guard showsDiagnostics != oldValue else { return }
            setNeedsDisplay()
        }
    }
    private(set) var diagnostics = RemoteTerminalRenderDiagnostics()

    /// Paint engine-folded rows. The layout is already decided, so this walks
    /// display rows and, within each, paints runs of same-foreground cells —
    /// there is no per-cell index arithmetic to remap.
    private func drawFolded(
        _ display: RemoteTerminalDisplayState,
        context: CGContext,
        cellW: CGFloat,
        cellH: CGFloat,
        baselineOffset: CGFloat,
        backgroundColorKey: UInt32,
        visibleRect: CGRect
    ) {
        let visibleRows = RemoteTerminalScrollPolicy.visibleRows(
            totalRows: display.displayRows, cellHeight: Double(cellH),
            minY: Double(visibleRect.minY), maxY: Double(visibleRect.maxY)
        )
        context.setAllowsAntialiasing(false)
        context.setShouldAntialias(false)
        for row in visibleRows {
            guard let range = display.range(forRow: row), !range.isEmpty else { continue }
            let y = CGFloat(row) * cellH
            var runStart = 0
            var runKey = colorCache.backgroundKey(for: display.cells[range.lowerBound])
            for offset in 1 ..< range.count {
                let key = colorCache.backgroundKey(for: display.cells[range.lowerBound + offset])
                if key != runKey {
                    fillFoldedRun(
                        display: display, context: context, range: range, start: runStart, end: offset,
                        y: y, cellW: cellW, cellH: cellH, colorKey: runKey, skipKey: backgroundColorKey
                    )
                    runStart = offset
                    runKey = key
                }
            }
            fillFoldedRun(
                display: display, context: context, range: range, start: runStart, end: range.count,
                y: y, cellW: cellW, cellH: cellH, colorKey: runKey, skipKey: backgroundColorKey
            )
        }

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        for row in visibleRows {
            guard let range = display.range(forRow: row), !range.isEmpty else { continue }
            let y = CGFloat(row) * cellH
            for index in range {
                let cell = display.cells[index]
                if cell.flags & rustCellFlagHidden != 0 { continue }
                if cell.continuation != 0 { continue }
                let cluster = display.clusterString(for: cell)
                if cluster.isEmpty || cluster == " " { continue }
                let column = index - range.lowerBound
                let x = CGFloat(column) * cellW
                let fgKey = colorCache.foregroundKey(for: cell)
                let fg = colorCache.foreground(forKey: fgKey)
                (cluster as NSString).draw(
                    at: CGPoint(x: x, y: y + baselineOffset),
                    withAttributes: colorCache.textAttributes(font: resolvedFont(for: cell), colorKey: fgKey, color: fg)
                )
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

    private func fillFoldedRun(
        display: RemoteTerminalDisplayState,
        context: CGContext,
        range: Range<Int>,
        start: Int,
        end: Int,
        y: CGFloat,
        cellW: CGFloat,
        cellH: CGFloat,
        colorKey: UInt32,
        skipKey: UInt32
    ) {
        guard colorKey != skipKey, end > start else { return }
        colorCache.background(forKey: colorKey).setFill()
        UIRectFill(CGRect(
            x: CGFloat(start) * cellW,
            y: y,
            width: CGFloat(end - start) * cellW,
            height: cellH
        ))
    }

    private func drawFoldedDiagnostics(
        context: CGContext,
        display: RemoteTerminalDisplayState,
        cellW: CGFloat,
        cellH: CGFloat
    ) {
        let state = renderState
        let text = "src \(state?.cols ?? 0)x\(state?.rows ?? 0) → \(display.displayCols)x\(display.displayRows)  engine-folded"
        drawReadout(context: context, text: text, cellW: cellW, cellH: cellH)
    }

    /// Whether a source row soft-wraps from the row above. The engine sets the
    /// flag on the row's first cell (bit 7 of the cell flags), so a row that
    /// begins a new logical line — because a newline was emitted — is false.
    private func isSoftWrappedRow(_ row: Int, sourceCols: Int, state: RemoteTerminalRenderState) -> Bool {
        guard row > 0, sourceCols > 0 else { return false }
        let index = row * sourceCols
        guard index < state.cells.count else { return false }
        return state.cells[index].flags & rustCellFlagWrapped != 0
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
