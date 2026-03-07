import SwiftUI
import AppKit

struct AnsiLogView: NSViewRepresentable {
    let lines: [String]
    let baseFont: NSFont
    let baseForeground: NSColor
    let baseBackground: NSColor

    // MARK: - Cached Fonts (Memory Optimization)

    // Fonts are expensive to create - cache them based on point size with eviction

    private static var fontCache: [CGFloat: (regular: NSFont, bold: NSFont)] = [:]
    private static var fontCacheOrder: [CGFloat] = [] // LRU tracking
    private static let fontCacheLock = NSLock()

    private static func getCachedFonts(pointSize: CGFloat) -> (regular: NSFont, bold: NSFont) {
        fontCacheLock.lock()
        defer { fontCacheLock.unlock() }

        // Check cache hit
        if let cached = fontCache[pointSize] {
            // Move to end of LRU order
            if let index = fontCacheOrder.firstIndex(of: pointSize) {
                fontCacheOrder.remove(at: index)
                fontCacheOrder.append(pointSize)
            }
            return cached
        }

        // Evict oldest if at capacity
        if fontCache.count >= AppConstants.Limits.maxFontCacheSize {
            if let oldest = fontCacheOrder.first {
                fontCache.removeValue(forKey: oldest)
                fontCacheOrder.removeFirst()
            }
        }

        // Create and cache new fonts
        let regular = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .semibold)
        fontCache[pointSize] = (regular, bold)
        fontCacheOrder.append(pointSize)

        return (regular, bold)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.drawsBackground = true
        textView.backgroundColor = baseBackground
        textView.font = baseFont
        textView.textColor = baseForeground
        textView.textContainerInset = NSSize(width: 6, height: 6)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = baseBackground
        scrollView.documentView = textView

        // Store current line count for incremental updates
        context.coordinator.lastLineCount = 0

        return scrollView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var lastLineCount = 0
        var cachedLines: [NSAttributedString] = []
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        textView.backgroundColor = baseBackground
        textView.textColor = baseForeground
        textView.textContainer?.containerSize = NSSize(
            width: nsView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        let coordinator = context.coordinator
        let fonts = Self.getCachedFonts(pointSize: baseFont.pointSize)

        // Check if we can do an incremental update
        let previousCount = coordinator.lastLineCount
        let currentCount = lines.count

        if currentCount > previousCount, previousCount > 0, coordinator.cachedLines.count == previousCount {
            // Incremental update - only render new lines
            let textStorage = textView.textStorage!

            for index in previousCount ..< currentCount {
                let line = lines[index]
                let isInput = line.hasPrefix("[INPUT]")
                let font = isInput ? fonts.bold : fonts.regular

                if index > 0 {
                    textStorage.append(NSAttributedString(string: "\n"))
                }

                let attributed = AnsiParser.attributedString(
                    for: line,
                    baseFont: font,
                    baseFg: baseForeground,
                    baseBg: baseBackground
                )
                textStorage.append(attributed)
                coordinator.cachedLines.append(attributed)
            }
        } else {
            // Full rebuild required (lines removed, replaced, or first render)
            let rendered = NSMutableAttributedString()
            coordinator.cachedLines.removeAll()
            coordinator.cachedLines.reserveCapacity(lines.count)

            for (index, line) in lines.enumerated() {
                let isInput = line.hasPrefix("[INPUT]")
                let font = isInput ? fonts.bold : fonts.regular

                let attributed = AnsiParser.attributedString(
                    for: line,
                    baseFont: font,
                    baseFg: baseForeground,
                    baseBg: baseBackground
                )
                coordinator.cachedLines.append(attributed)
                rendered.append(attributed)

                if index < lines.count - 1 {
                    rendered.append(NSAttributedString(string: "\n"))
                }
            }

            textView.textStorage?.setAttributedString(rendered)
        }

        coordinator.lastLineCount = currentCount
        textView.scrollToEndOfDocument(nil)
    }
}
