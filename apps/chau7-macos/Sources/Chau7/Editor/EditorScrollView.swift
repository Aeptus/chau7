import AppKit

// MARK: - Editor Scroll View

/// Custom scroll view that hosts the editor text view with a line number gutter.
class EditorScrollView: NSScrollView {
    let editorTextView: NSTextView
    private var lineNumberView: LineNumberGutterView?

    override init(frame: NSRect) {
        let textView = NSTextView(frame: .zero)
        self.editorTextView = textView
        super.init(frame: frame)

        // Configure scroll view
        self.documentView = textView
        self.hasVerticalScroller = true
        self.hasHorizontalScroller = true
        self.autohidesScrollers = true

        // Configure text container
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Sets up the line number gutter as a vertical ruler on the scroll view.
    func setupLineNumberGutter() {
        let gutter = LineNumberGutterView(textView: editorTextView, scrollView: self)
        self.lineNumberView = gutter
        self.verticalRulerView = gutter
        self.hasVerticalRuler = true
        self.rulersVisible = true
    }
}

// MARK: - Line Number Gutter View

/// Draws line numbers in the editor gutter as a vertical ruler view.
class LineNumberGutterView: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        self.ruleThickness = 40
        self.clientView = textView

        // Observe text changes to redraw line numbers
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange),
            name: NSText.didChangeNotification,
            object: textView
        )

        // Observe scroll changes to redraw visible line numbers
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func textDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    @objc private func boundsDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return }

        // Draw gutter background
        let gutterRect = NSRect(x: 0, y: 0, width: ruleThickness, height: bounds.height)
        NSColor.controlBackgroundColor.setFill()
        gutterRect.fill()

        // Draw separator line
        NSColor.separatorColor.setStroke()
        let separatorPath = NSBezierPath()
        separatorPath.move(to: NSPoint(x: ruleThickness - 0.5, y: 0))
        separatorPath.line(to: NSPoint(x: ruleThickness - 0.5, y: bounds.height))
        separatorPath.lineWidth = 0.5
        separatorPath.stroke()

        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: textView.visibleRect,
            in: textContainer
        )
        let visibleCharRange = layoutManager.characterRange(
            forGlyphRange: visibleGlyphRange,
            actualGlyphRange: nil
        )

        let text = textView.string as NSString
        var lineNumber = 1

        // Count lines before visible range
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: visibleCharRange.location),
            options: [.byLines, .substringNotRequired]
        ) { _, _, _, _ in
            lineNumber += 1
        }

        // Draw line numbers for visible range
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        text.enumerateSubstrings(
            in: visibleCharRange,
            options: [.byLines, .substringNotRequired]
        ) { _, substringRange, _, _ in
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: substringRange,
                actualCharacterRange: nil
            )
            let lineRect = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            )

            let numStr = "\(lineNumber)" as NSString
            let size = numStr.size(withAttributes: attrs)
            let x = self.ruleThickness - size.width - 4
            let y = lineRect.origin.y
                + (lineRect.height - size.height) / 2
                + textView.textContainerOrigin.y
                - self.convert(.zero, from: textView).y

            numStr.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            lineNumber += 1
        }
    }
}
