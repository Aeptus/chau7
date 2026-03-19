import CoreText
import SwiftUI
import UIKit

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
                RemoteTerminalTextFallbackView(
                    outputText: client.outputText,
                    strippedOutputText: client.strippedOutputText,
                    renderANSI: renderANSI
                )
            }
        }
        .onAppear {
            client.terminalRenderer.setActiveTab(client.activeTabID, fallbackText: client.outputText)
        }
        .onChange(of: client.activeTabID) { _, tabID in
            client.terminalRenderer.setActiveTab(tabID, fallbackText: client.outputText)
        }
        .onChange(of: client.outputText) { _, text in
            client.terminalRenderer.updateActiveFallbackText(text)
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

private struct RemoteTerminalTextFallbackView: View {
    let outputText: String
    let strippedOutputText: String
    let renderANSI: Bool

    var body: some View {
        RemoteTerminalTextView(text: renderANSI ? outputText : strippedOutputText)
    }
}

struct RemoteTerminalTextView: View {
    let text: String

    var body: some View {
        RemoteTerminalTextViewRepresentable(text: boundedTranscript(text))
            .background(Color.black)
    }

    private func boundedTranscript(_ text: String) -> String {
        let maxCharacters = 250_000
        guard text.utf8.count > maxCharacters else { return text }
        let tail = String(text.suffix(maxCharacters))
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

        let lineHeight = regularFont.lineHeight
        let baselineOffset = (cellSize.height - lineHeight) / 2

        context.setAllowsAntialiasing(false)
        context.setShouldAntialias(false)
        for row in 0 ..< rows {
            let y = CGFloat(row) * cellSize.height
            for col in 0 ..< cols {
                let idx = row * cols + col
                guard idx < renderState.cells.count else { continue }
                let cell = renderState.cells[idx]
                let colors = resolvedColors(for: cell)
                colors.background.setFill()
                UIRectFill(CGRect(
                    x: CGFloat(col) * cellSize.width,
                    y: y,
                    width: cellSize.width,
                    height: cellSize.height
                ))
            }
        }

        if renderState.cursorVisible,
           renderState.cursorRow >= 0, renderState.cursorRow < rows,
           renderState.cursorCol >= 0, renderState.cursorCol < cols {
            UIColor.white.withAlphaComponent(0.28).setFill()
            UIRectFill(CGRect(
                x: CGFloat(renderState.cursorCol) * cellSize.width,
                y: CGFloat(renderState.cursorRow) * cellSize.height,
                width: cellSize.width,
                height: cellSize.height
            ))
        }

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        for row in 0 ..< rows {
            let y = CGFloat(row) * cellSize.height
            for col in 0 ..< cols {
                let idx = row * cols + col
                guard idx < renderState.cells.count else { continue }
                let cell = renderState.cells[idx]
                if cell.flags & rustCellFlagHidden != 0 {
                    continue
                }
                guard let scalar = UnicodeScalar(cell.character), scalar.value != 0, scalar != " " else { continue }

                let colors = resolvedColors(for: cell)
                let font = resolvedFont(for: cell)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: colors.foreground
                ]
                let origin = CGPoint(
                    x: CGFloat(col) * cellSize.width,
                    y: y + baselineOffset
                )
                NSString(string: String(scalar)).draw(at: origin, withAttributes: attributes)

                if cell.flags & rustCellFlagUnderline != 0 {
                    colors.foreground.setStroke()
                    let underlineY = y + cellSize.height - 2
                    let path = UIBezierPath()
                    path.lineWidth = 1
                    path.move(to: CGPoint(x: CGFloat(col) * cellSize.width, y: underlineY))
                    path.addLine(to: CGPoint(x: CGFloat(col + 1) * cellSize.width, y: underlineY))
                    path.stroke()
                }

                if cell.flags & rustCellFlagStrikethrough != 0 {
                    colors.foreground.setStroke()
                    let strikeY = y + (cellSize.height / 2)
                    let path = UIBezierPath()
                    path.lineWidth = 1
                    path.move(to: CGPoint(x: CGFloat(col) * cellSize.width, y: strikeY))
                    path.addLine(to: CGPoint(x: CGFloat(col + 1) * cellSize.width, y: strikeY))
                    path.stroke()
                }
            }
        }
    }

    private func italicVariant(for font: UIFont) -> UIFont? {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits([.traitItalic]) else { return nil }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    private func resolvedFont(for cell: RustCellData) -> UIFont {
        let bold = cell.flags & rustCellFlagBold != 0
        let italic = cell.flags & rustCellFlagItalic != 0
        switch (bold, italic) {
        case (true, true):
            return boldItalicFont
        case (true, false):
            return boldFont
        case (false, true):
            return italicFont
        case (false, false):
            return regularFont
        }
    }

    private func resolvedColors(for cell: RustCellData) -> (foreground: UIColor, background: UIColor) {
        let foreground = UIColor(
            red: CGFloat(cell.fg_r) / 255,
            green: CGFloat(cell.fg_g) / 255,
            blue: CGFloat(cell.fg_b) / 255,
            alpha: cell.flags & rustCellFlagDim != 0 ? 0.7 : 1.0
        )
        let background = UIColor(
            red: CGFloat(cell.bg_r) / 255,
            green: CGFloat(cell.bg_g) / 255,
            blue: CGFloat(cell.bg_b) / 255,
            alpha: 1.0
        )
        if cell.flags & rustCellFlagInverse != 0 {
            return (background, foreground)
        }
        return (foreground, background)
    }
}
