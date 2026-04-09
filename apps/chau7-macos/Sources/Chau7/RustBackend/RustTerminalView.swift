import AppKit
import Carbon
import Darwin
import QuartzCore
import CoreText
import Chau7Core

// MARK: - CVDisplayLink Weak Reference Box

/// Prevents use-after-free in CVDisplayLink callbacks.
/// CVDisplayLink takes a raw `UnsafeMutableRawPointer` (no ARC).
/// Using `Unmanaged.passUnretained` means the callback can access
/// a deallocated view. This box is retained by Unmanaged and holds
/// only a weak reference to the view, making the callback a safe no-op
/// after deallocation.
final class DisplayLinkWeakBox {
    weak var view: RustTerminalView?
    init(_ view: RustTerminalView) {
        self.view = view
    }
}

// MARK: - Native Rust Grid Renderer

final class RustGridView: NSView {
    struct CursorStyle {
        enum Shape {
            case block
            case underline
            case bar
        }

        var shape: Shape
        var blink: Bool
    }

    var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet { updateFontCache() }
    }

    var cellSize = CGSize(width: 8, height: 16) {
        didSet { if !metalRenderingActive { needsDisplay = true } }
    }

    var foregroundColor: NSColor = .textColor {
        didSet { if !metalRenderingActive { needsDisplay = true } }
    }

    var backgroundColor: NSColor = .textBackgroundColor {
        didSet { if !metalRenderingActive { needsDisplay = true } }
    }

    var cursorColor: NSColor = .white {
        didSet { if !metalRenderingActive { needsDisplay = true } }
    }

    var selectionColor: NSColor = .selectedTextBackgroundColor

    var cursorStyle = CursorStyle(shape: .block, blink: false) {
        didSet { if !metalRenderingActive { needsDisplay = true } }
    }

    private var cols = 0
    private var rows = 0
    private var cells: [RustCellData] = []
    private var overlayCells: [Int: RustCellData] = [:]
    /// Viewport-relative row tints (row index → tint color). Applied as a blend over cell backgrounds.
    var rowTints: [Int: NSColor] = [:] {
        didSet {
            if !metalRenderingActive, rowTints.count != oldValue.count || rowTints.keys.sorted() != oldValue.keys.sorted() {
                needsDisplay = true
            }
        }
    }

    private var cursor: (col: Int, row: Int) = (0, 0)
    private var lastCursor: (col: Int, row: Int) = (0, 0)
    private var lastBlinkPhase = true

    /// DECTCEM cursor visibility: when false, the terminal has hidden the cursor (ESC[?25l).
    /// Programs like Claude Code hide the terminal cursor and draw their own via ANSI styling.
    var cursorVisible = true {
        didSet {
            if !metalRenderingActive, oldValue != cursorVisible {
                setNeedsDisplay(cursorRect(for: cursor))
            }
        }
    }

    /// When true, Metal handles display — suppresses CPU draw() and setNeedsDisplay.
    var metalRenderingActive = false

    private var regularFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private var italicFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var boldItalicFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)

    override var acceptsFirstResponder: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        updateFontCache()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        updateFontCache()
    }

    func updateGrid(
        cells source: UnsafeMutablePointer<RustCellData>,
        cols: Int,
        rows: Int,
        cursor: (col: UInt16, row: UInt16),
        dirtyRows: Set<Int>?
    ) {
        let totalCells = cols * rows
        if self.cols != cols || self.rows != rows || cells.count != totalCells {
            self.cols = cols
            self.rows = rows
            cells = Array(repeating: RustCellData(character: 0, fg_r: 255, fg_g: 255, fg_b: 255, bg_r: 0, bg_g: 0, bg_b: 0, flags: 0, _pad: 0, link_id: 0), count: totalCells)
            // Full redraw when dimensions change.
            needsDisplay = true
        }

        let buffer = UnsafeBufferPointer(start: source, count: totalCells)
        if let dirtyRows, !dirtyRows.isEmpty {
            for row in dirtyRows {
                let rowStart = row * cols
                let rowRange = rowStart ..< (rowStart + cols)
                cells.replaceSubrange(rowRange, with: buffer[rowRange])
                setNeedsDisplay(rowRect(for: row))
            }
        } else {
            cells.replaceSubrange(0 ..< totalCells, with: buffer)
            needsDisplay = true
        }

        updateCursor(cursor)
    }

    func setOverlayCells(_ cells: [Int: RustCellData]) {
        overlayCells = cells
        needsDisplay = true
    }

    func clearOverlay() {
        guard !overlayCells.isEmpty else { return }
        overlayCells.removeAll()
        needsDisplay = true
    }

    /// Get the link_id for a cell at the given flat index. Returns 0 if out of bounds or no link.
    func linkIdAt(index: Int) -> UInt16 {
        guard index >= 0, index < cells.count else { return 0 }
        return cells[index].link_id
    }

    func updateCursor(_ cursor: (col: UInt16, row: UInt16)) {
        lastCursor = self.cursor
        self.cursor = (col: Int(cursor.col), row: Int(cursor.row))

        if lastCursor != self.cursor {
            setNeedsDisplay(cursorRect(for: lastCursor))
            setNeedsDisplay(cursorRect(for: self.cursor))
        }
    }

    func tickCursorBlink(now: CFAbsoluteTime) {
        guard cursorStyle.blink else { return }
        let phase = (Int(now * 2.0) % 2) == 0
        if phase != lastBlinkPhase {
            lastBlinkPhase = phase
            setNeedsDisplay(cursorRect(for: cursor))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // When Metal rendering is active, the GPU handles display.
        // Skip CPU rendering entirely to avoid wasting ~70% of CPU on invisible work.
        if metalRenderingActive { return }

        guard cols > 0, rows > 0, !cells.isEmpty else {
            backgroundColor.setFill()
            dirtyRect.fill()
            return
        }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.textMatrix = .identity

        // Set sRGB color space for consistent color reproduction
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
            ctx.setFillColorSpace(srgb)
            ctx.setStrokeColorSpace(srgb)
        }

        backgroundColor.setFill()
        dirtyRect.fill()

        let cellHeight = cellSize.height
        let cellWidth = cellSize.width
        // Use CTFont metrics for font dimension calculations.
        // CTFontGetDescent returns a POSITIVE value (unlike NSFont.descender which is negative).
        let ctFont = font as CTFont
        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        let lineHeight = ascent + descent + leading
        // Position baseline so text is vertically centered in the cell.
        // In macOS coords (y=0 at bottom), baseline = cell_y + descent + vertical_padding/2
        let baselineOffset = (cellHeight - lineHeight) / 2.0 + descent

        // Standard macOS coordinates: y=0 at bottom, row 0 at top of terminal
        let rowStart = max(0, Int((bounds.height - dirtyRect.maxY) / cellHeight))
        let rowEnd = min(rows - 1, Int((bounds.height - dirtyRect.minY) / cellHeight))

        if rowStart > rowEnd {
            ctx.restoreGState()
            return
        }

        // Phase 1: Fill all cell backgrounds with AA off (sharp cell edges)
        ctx.setShouldAntialias(false)
        ctx.setAllowsAntialiasing(false)
        for row in rowStart ... rowEnd {
            let y = bounds.height - CGFloat(row + 1) * cellHeight
            for col in 0 ..< cols {
                let idx = row * cols + col
                let cell = overlayCells[idx] ?? cells[idx]
                let x = CGFloat(col) * cellWidth
                let rect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)

                let (_, bg) = resolveColors(for: cell)
                let finalBg: NSColor
                if let tint = rowTints[row] {
                    finalBg = bg.blended(withFraction: tint.alphaComponent, of: tint.withAlphaComponent(1.0)) ?? bg
                } else {
                    finalBg = bg
                }
                ctx.setFillColor(finalBg.cgColor)
                ctx.fill(rect)
            }
        }

        // Phase 2: Draw all text with AA + font smoothing on (smooth glyphs)
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setShouldSubpixelQuantizeFonts(true)
        for row in rowStart ... rowEnd {
            let y = bounds.height - CGFloat(row + 1) * cellHeight
            for col in 0 ..< cols {
                let idx = row * cols + col
                let cell = overlayCells[idx] ?? cells[idx]

                guard cell.character > 0, cell.character != 0xFFFF else { continue }
                guard let scalar = UnicodeScalar(cell.character) else { continue }
                if cell.flags & RustCellFlags.hidden != 0 { continue }

                let x = CGFloat(col) * cellWidth
                let (fg, _) = resolveColors(for: cell)
                let drawFont = fontForCell(cell.flags)
                var textColor = fg
                if cell.flags & RustCellFlags.dim != 0 {
                    textColor = textColor.withAlphaComponent(0.6)
                }

                let attrs: [NSAttributedString.Key: Any] = [
                    .font: drawFont,
                    .foregroundColor: textColor
                ]
                let attrString = NSAttributedString(string: String(Character(scalar)), attributes: attrs)
                let line = CTLineCreateWithAttributedString(attrString)
                ctx.textPosition = CGPoint(x: x, y: y + baselineOffset)
                CTLineDraw(line, ctx)

                // Decorations — underline variants (stored in _pad byte)
                // 0/1=single, 2=double, 3=curl/wavy, 4=dotted, 5=dashed
                if cell.flags & RustCellFlags.underline != 0 {
                    let underlineVariant = cell._pad
                    ctx.setStrokeColor(textColor.cgColor)
                    let lineW = max(1, drawFont.underlineThickness)
                    ctx.setLineWidth(lineW)
                    let underlineY = y + baselineOffset + drawFont.underlinePosition

                    switch underlineVariant {
                    case 2: // Double underline
                        let gap = lineW * 2
                        ctx.move(to: CGPoint(x: x, y: underlineY))
                        ctx.addLine(to: CGPoint(x: x + cellWidth, y: underlineY))
                        ctx.strokePath()
                        ctx.move(to: CGPoint(x: x, y: underlineY - gap))
                        ctx.addLine(to: CGPoint(x: x + cellWidth, y: underlineY - gap))
                        ctx.strokePath()
                    case 3: // Curl/wavy underline
                        let amplitude: CGFloat = lineW * 1.5
                        let wavelength: CGFloat = cellWidth / 2.0
                        ctx.move(to: CGPoint(x: x, y: underlineY))
                        let steps = 12
                        for step in 1 ... steps {
                            let t = CGFloat(step) / CGFloat(steps)
                            let px = x + t * cellWidth
                            let py = underlineY + amplitude * sin(t * .pi * 2 * (cellWidth / wavelength))
                            ctx.addLine(to: CGPoint(x: px, y: py))
                        }
                        ctx.strokePath()
                    case 4: // Dotted underline
                        ctx.setLineDash(phase: 0, lengths: [lineW * 1.5, lineW * 1.5])
                        ctx.move(to: CGPoint(x: x, y: underlineY))
                        ctx.addLine(to: CGPoint(x: x + cellWidth, y: underlineY))
                        ctx.strokePath()
                        ctx.setLineDash(phase: 0, lengths: [])
                    case 5: // Dashed underline
                        ctx.setLineDash(phase: 0, lengths: [cellWidth * 0.3, cellWidth * 0.15])
                        ctx.move(to: CGPoint(x: x, y: underlineY))
                        ctx.addLine(to: CGPoint(x: x + cellWidth, y: underlineY))
                        ctx.strokePath()
                        ctx.setLineDash(phase: 0, lengths: [])
                    default: // Single underline (0 or 1)
                        ctx.move(to: CGPoint(x: x, y: underlineY))
                        ctx.addLine(to: CGPoint(x: x + cellWidth, y: underlineY))
                        ctx.strokePath()
                    }
                }
                if cell.flags & RustCellFlags.strikethrough != 0 {
                    ctx.setStrokeColor(textColor.cgColor)
                    ctx.setLineWidth(1)
                    let strikeY = y + baselineOffset + drawFont.xHeight / 2.0
                    ctx.move(to: CGPoint(x: x, y: strikeY))
                    ctx.addLine(to: CGPoint(x: x + cellWidth, y: strikeY))
                    ctx.strokePath()
                }
                // OSC 8 hyperlink: underline in link color
                if cell.link_id > 0, cell.flags & RustCellFlags.underline == 0 {
                    let linkColor = NSColor.linkColor.cgColor
                    ctx.setStrokeColor(linkColor)
                    ctx.setLineWidth(max(1, drawFont.underlineThickness))
                    let underlineY = y + baselineOffset + drawFont.underlinePosition
                    ctx.move(to: CGPoint(x: x, y: underlineY))
                    ctx.addLine(to: CGPoint(x: x + cellWidth, y: underlineY))
                    ctx.strokePath()
                }
            }
        }

        drawCursor(in: ctx, cellWidth: cellWidth, cellHeight: cellHeight, baselineOffset: baselineOffset)

        ctx.restoreGState()
    }

    private func drawCursor(in ctx: CGContext, cellWidth: CGFloat, cellHeight: CGFloat, baselineOffset: CGFloat) {
        // DECTCEM: don't draw cursor if the terminal has hidden it (ESC[?25l)
        guard cursorVisible else { return }

        if cursorStyle.blink, !lastBlinkPhase {
            return
        }

        guard cursor.col >= 0, cursor.col < cols, cursor.row >= 0, cursor.row < rows else { return }
        let x = CGFloat(cursor.col) * cellWidth
        // Standard macOS coordinates: y=0 at bottom, row 0 at top of terminal
        let y = bounds.height - CGFloat(cursor.row + 1) * cellHeight
        let rect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)

        switch cursorStyle.shape {
        case .block:
            ctx.setFillColor(cursorColor.cgColor)
            ctx.fill(rect)

            let idx = cursor.row * cols + cursor.col
            let cell = overlayCells[idx] ?? cells[idx]
            guard cell.character > 0, cell.character != 0xFFFF else { return }
            guard let scalar = UnicodeScalar(cell.character) else { return }
            let (_, bg) = resolveColors(for: cell)
            let drawFont = fontForCell(cell.flags)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: drawFont,
                .foregroundColor: bg
            ]
            let attrString = NSAttributedString(string: String(Character(scalar)), attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrString)
            ctx.textPosition = CGPoint(x: x, y: y + baselineOffset)
            CTLineDraw(line, ctx)
        case .underline:
            ctx.setStrokeColor(cursorColor.cgColor)
            ctx.setLineWidth(max(1, cellHeight * 0.12))
            // Standard coords: underline at bottom of cell (y is at bottom of cell)
            let underlineY = y + 1
            ctx.move(to: CGPoint(x: x, y: underlineY))
            ctx.addLine(to: CGPoint(x: x + cellWidth, y: underlineY))
            ctx.strokePath()
        case .bar:
            ctx.setFillColor(cursorColor.cgColor)
            let barWidth = max(1, cellWidth * 0.12)
            ctx.fill(CGRect(x: x, y: y, width: barWidth, height: cellHeight))
        }
    }

    private func updateFontCache() {
        regularFont = font
        let manager = NSFontManager.shared
        boldFont = manager.convert(font, toHaveTrait: .boldFontMask)
        italicFont = manager.convert(font, toHaveTrait: .italicFontMask)
        let boldItalic = manager.convert(boldFont, toHaveTrait: .italicFontMask)
        boldItalicFont = boldItalic
        if !metalRenderingActive { needsDisplay = true }
    }

    private func fontForCell(_ flags: UInt8) -> NSFont {
        let isBold = flags & RustCellFlags.bold != 0
        let isItalic = flags & RustCellFlags.italic != 0
        switch (isBold, isItalic) {
        case (true, true):
            return boldItalicFont
        case (true, false):
            return boldFont
        case (false, true):
            return italicFont
        default:
            return regularFont
        }
    }

    private func resolveColors(for cell: RustCellData) -> (NSColor, NSColor) {
        // Use deviceRed for consistent color extraction.
        // The CGContext is set to sRGB color space in draw() for consistent rendering.
        var fg = NSColor(deviceRed: CGFloat(cell.fg_r) / 255.0, green: CGFloat(cell.fg_g) / 255.0, blue: CGFloat(cell.fg_b) / 255.0, alpha: 1.0)
        var bg = NSColor(deviceRed: CGFloat(cell.bg_r) / 255.0, green: CGFloat(cell.bg_g) / 255.0, blue: CGFloat(cell.bg_b) / 255.0, alpha: 1.0)
        if cell.flags & RustCellFlags.inverse != 0 {
            swap(&fg, &bg)
        }
        return (fg, bg)
    }

    private func rowRect(for row: Int) -> CGRect {
        let cellHeight = cellSize.height
        // Standard macOS coordinates: y=0 at bottom, row 0 at top of terminal
        let y = bounds.height - CGFloat(row + 1) * cellHeight
        return CGRect(x: 0, y: y, width: bounds.width, height: cellHeight)
    }

    private func cursorRect(for cursor: (col: Int, row: Int)) -> CGRect {
        let cellHeight = cellSize.height
        let cellWidth = cellSize.width
        let x = CGFloat(cursor.col) * cellWidth
        // Standard macOS coordinates: y=0 at bottom, row 0 at top of terminal
        let y = bounds.height - CGFloat(cursor.row + 1) * cellHeight
        return CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
    }
}

final class PassthroughView: NSView {
    override var acceptsFirstResponder: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

// MARK: - Rust Terminal FFI Wrapper

/// Swift wrapper for the Rust terminal library loaded via dlopen
final class RustTerminalFFI {
    // Function types matching chau7_terminal.h
    private typealias CreateFn = @convention(c) (UInt16, UInt16, UnsafePointer<CChar>?) -> OpaquePointer?
    private typealias CreateWithEnvFn = @convention(c) (UInt16, UInt16, UnsafePointer<CChar>?, UnsafePointer<UnsafePointer<CChar>?>?, UnsafePointer<UnsafePointer<CChar>?>?, Int) -> OpaquePointer?
    private typealias DestroyFn = @convention(c) (OpaquePointer?) -> Void
    private typealias SendBytesFn = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int) -> Void
    private typealias SendTextFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void
    private typealias ResizeFn = @convention(c) (OpaquePointer?, UInt16, UInt16) -> Void
    // Use UnsafeMutableRawPointer since Swift structs aren't directly C-representable
    private typealias GetGridFn = @convention(c) (OpaquePointer?) -> UnsafeMutableRawPointer?
    private typealias FreeGridFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias ScrollPositionFn = @convention(c) (OpaquePointer?) -> Double
    private typealias ScrollToFn = @convention(c) (OpaquePointer?, Double) -> Void
    private typealias ScrollLinesFn = @convention(c) (OpaquePointer?, Int32) -> Void
    private typealias SelectionTextFn = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<CChar>?
    private typealias SelectionClearFn = @convention(c) (OpaquePointer?) -> Void
    private typealias SelectionStartFn = @convention(c) (OpaquePointer?, Int32, Int32, UInt8) -> Void
    private typealias SelectionUpdateFn = @convention(c) (OpaquePointer?, Int32, Int32) -> Void
    private typealias SelectionAllFn = @convention(c) (OpaquePointer?) -> Void
    private typealias FreeStringFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    private typealias CursorPositionFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt16>?, UnsafeMutablePointer<UInt16>?) -> Void
    private typealias PollFn = @convention(c) (OpaquePointer?, UInt32) -> Bool
    private typealias SetColorsFn = @convention(c) (OpaquePointer?, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UnsafePointer<UInt8>?) -> Void
    private typealias ClearScrollbackFn = @convention(c) (OpaquePointer?) -> Void
    // FFI types for raw output retrieval from the Rust terminal
    // Returns *mut u8 (mutable pointer) for proper memory ownership transfer
    private typealias GetLastOutputFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int>?) -> UnsafeMutablePointer<UInt8>?
    private typealias FreeOutputFn = @convention(c) (UnsafeMutablePointer<UInt8>?, Int) -> Void
    private typealias InjectOutputFn = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int) -> Void
    /// Scrollback size configuration
    private typealias SetScrollbackSizeFn = @convention(c) (OpaquePointer?, UInt32) -> Void
    /// Smart scroll support: get display offset (0 = at bottom)
    private typealias DisplayOffsetFn = @convention(c) (OpaquePointer?) -> UInt32
    /// Bracketed paste mode query (for proper paste handling in vim, zsh, etc.)
    private typealias IsBracketedPasteModeFn = @convention(c) (OpaquePointer?) -> Bool
    /// Bell event checking (for audio/visual bell feedback)
    private typealias CheckBellFn = @convention(c) (OpaquePointer?) -> Bool
    // Mouse mode query (for context menu gating and mouse reporting)
    private typealias GetMouseModeFn = @convention(c) (OpaquePointer?) -> UInt32
    private typealias IsMouseReportingActiveFn = @convention(c) (OpaquePointer?) -> Bool
    /// Application cursor mode (DECCKM) query - for arrow key sequences
    private typealias IsApplicationCursorModeFn = @convention(c) (OpaquePointer?) -> Bool
    // Debug and performance functions
    private typealias GetShellPidFn = @convention(c) (OpaquePointer?) -> UInt64
    private typealias GetDebugStateFn = @convention(c) (OpaquePointer?) -> UnsafeMutableRawPointer?
    private typealias FreeDebugStateFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias GetFullBufferTextFn = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<CChar>?
    private typealias ResetMetricsFn = @convention(c) (OpaquePointer?) -> Void
    // Terminal event functions (title, exit, PTY closed)
    private typealias GetPendingTitleFn = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<CChar>?
    private typealias GetPendingExitCodeFn = @convention(c) (OpaquePointer?) -> Int32
    private typealias IsPtyClosedFn = @convention(c) (OpaquePointer?) -> Bool
    /// Echo detection via termios (Phase 2: reliable password prompt detection)
    private typealias IsEchoDisabledFn = @convention(c) (OpaquePointer?) -> Bool

    /// Direct line text retrieval (avoids full grid snapshot per row)
    private typealias GetLineTextFn = @convention(c) (OpaquePointer?, Int32) -> UnsafeMutablePointer<CChar>?
    private typealias GetLogicalLineTextFn = @convention(c) (OpaquePointer?, Int32, UInt32, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<UInt32>?) -> UnsafeMutablePointer<CChar>?

    /// Hyperlink (OSC 8) FFI types (Phase 5)
    private typealias GetLinkUrlFn = @convention(c) (OpaquePointer?, UInt16) -> UnsafeMutablePointer<CChar>?

    // Clipboard (OSC 52) FFI types (Phase 5)
    private typealias GetPendingClipboardFn = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<CChar>?
    private typealias HasClipboardRequestFn = @convention(c) (OpaquePointer?) -> Bool
    private typealias RespondClipboardFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void

    // Shell integration (OSC 133) FFI types — opaque pointers like images API
    private typealias GetPendingShellIntegrationEventsFn = @convention(c) (OpaquePointer?) -> UnsafeMutableRawPointer?
    private typealias FreeShellIntegrationEventsFn = @convention(c) (UnsafeMutableRawPointer?) -> Void

    // Graphics protocol FFI types (Phase 4)
    private typealias GetPendingImagesFn = @convention(c) (OpaquePointer?) -> UnsafeMutableRawPointer?
    private typealias FreeImagesFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias SetImageProtocolsFn = @convention(c) (OpaquePointer?, Bool, Bool, Bool) -> Void
    private typealias HasPendingImagesFn = @convention(c) (OpaquePointer?) -> Bool

    private struct Functions {
        let create: CreateFn
        let createWithEnv: CreateWithEnvFn? // Optional - older libraries may not have this
        let destroy: DestroyFn
        let sendBytes: SendBytesFn
        let sendText: SendTextFn
        let resize: ResizeFn
        let getGrid: GetGridFn
        let freeGrid: FreeGridFn
        let scrollPosition: ScrollPositionFn
        let scrollTo: ScrollToFn
        let scrollLines: ScrollLinesFn
        let selectionText: SelectionTextFn
        let selectionClear: SelectionClearFn
        let selectionStart: SelectionStartFn? // Optional - older libraries may not have this
        let selectionUpdate: SelectionUpdateFn? // Optional - older libraries may not have this
        let selectionAll: SelectionAllFn? // Optional - older libraries may not have this
        let freeString: FreeStringFn
        let cursorPosition: CursorPositionFn
        let poll: PollFn
        let setColors: SetColorsFn? // Optional - older libraries may not have this
        let clearScrollback: ClearScrollbackFn? // Optional - older libraries may not have this
        // Raw output retrieval functions (for shell integration and output detection)
        let getLastOutput: GetLastOutputFn? // Optional - older libraries may not have this
        let freeOutput: FreeOutputFn? // Optional - older libraries may not have this
        let injectOutput: InjectOutputFn? // Optional - inject UI-only output
        /// Scrollback size configuration
        let setScrollbackSize: SetScrollbackSizeFn? // Optional - older libraries may not have this
        /// Smart scroll support
        let displayOffset: DisplayOffsetFn? // Optional - older libraries may not have this
        /// Bracketed paste mode query
        let isBracketedPasteMode: IsBracketedPasteModeFn? // Optional - older libraries may not have this
        /// Bell event checking
        let checkBell: CheckBellFn? // Optional - older libraries may not have this
        // Mouse mode query (for context menu gating)
        let getMouseMode: GetMouseModeFn? // Optional - older libraries may not have this
        let isMouseReportingActive: IsMouseReportingActiveFn? // Optional - older libraries may not have this
        /// Application cursor mode (DECCKM) query - for arrow key sequences
        let isApplicationCursorMode: IsApplicationCursorModeFn? // Optional - older libraries may not have this
        // Debug and performance functions
        let getShellPid: GetShellPidFn? // Optional - for dev server monitoring
        let getDebugState: GetDebugStateFn? // Optional - for debugging
        let freeDebugState: FreeDebugStateFn? // Optional - for debugging
        let getFullBufferText: GetFullBufferTextFn? // Optional - for debugging
        let resetMetrics: ResetMetricsFn? // Optional - for performance analysis
        // Terminal event functions (title, exit, PTY closed)
        let getPendingTitle: GetPendingTitleFn? // Optional - for terminal title updates
        let getPendingExitCode: GetPendingExitCodeFn? // Optional - for process exit detection
        let isPtyClosed: IsPtyClosedFn? // Optional - for PTY close detection
        /// Echo detection via termios (Phase 2)
        let isEchoDisabled: IsEchoDisabledFn? // Optional - for reliable password detection
        /// Direct line text retrieval (avoids full grid snapshot per row)
        let getLineTextDirect: GetLineTextFn? // Optional - direct line text without grid snapshot
        let getLogicalLineTextDirect: GetLogicalLineTextFn? // Optional - logical wrapped line text for hit-testing
        /// Hyperlink support (OSC 8 — Phase 5)
        let getLinkUrl: GetLinkUrlFn? // Optional - for OSC 8 hyperlink URL retrieval
        // Clipboard support (OSC 52 — Phase 5)
        let getPendingClipboard: GetPendingClipboardFn? // Optional - for OSC 52 clipboard store
        let hasClipboardRequest: HasClipboardRequestFn? // Optional - for OSC 52 clipboard load
        let respondClipboard: RespondClipboardFn? // Optional - for OSC 52 clipboard load response
        // Shell integration (OSC 133)
        let getPendingShellIntegrationEvents: GetPendingShellIntegrationEventsFn?
        let freeShellIntegrationEvents: FreeShellIntegrationEventsFn?
        // Graphics protocol support (Phase 4)
        let getPendingImages: GetPendingImagesFn? // Optional - for image protocol support
        let freeImages: FreeImagesFn? // Optional - for image protocol support
        let setImageProtocols: SetImageProtocolsFn? // Optional - for image protocol support
        let hasPendingImages: HasPendingImagesFn? // Optional - for image protocol support
    }

    private static let lock = NSLock()
    private static var loadAttempted = false
    private static var dylibHandle: UnsafeMutableRawPointer?
    private static var functions: Functions?

    /// Returns true if the Rust library is available
    static var isAvailable: Bool {
        Log.trace("RustTerminalFFI: Checking library availability")
        ensureLoaded()
        let available = functions != nil
        Log.trace("RustTerminalFFI: isAvailable = \(available)")
        return available
    }

    private static func ensureLoaded() {
        lock.lock()
        defer { lock.unlock() }

        if functions != nil {
            Log.trace("RustTerminalFFI: ensureLoaded - Already loaded")
            return
        }
        if loadAttempted {
            Log.trace("RustTerminalFFI: ensureLoaded - Previous attempt failed")
            return
        }
        loadAttempted = true

        Log.info("RustTerminalFFI: Starting library load")
        let candidates = libraryCandidates()
        Log.trace("RustTerminalFFI: Searching \(candidates.count) candidate paths")

        for (index, path) in candidates.enumerated() {
            Log.trace("RustTerminalFFI: Trying path \(index + 1)/\(candidates.count): \(path)")
            if let handle = dlopen(path, RTLD_NOW) {
                Log.trace("RustTerminalFFI: dlopen succeeded for: \(path)")
                dylibHandle = handle
                if let f = loadFunctions(from: handle) {
                    functions = f
                    Log.info("RustTerminalFFI: Successfully loaded library from \(path)")
                    return
                } else {
                    Log.warn("RustTerminalFFI: Library found at \(path) but missing required symbols")
                    dlclose(handle)
                    dylibHandle = nil
                }
            } else {
                // Get detailed error from dlerror
                if let errorPtr = dlerror() {
                    let errorStr = String(cString: errorPtr)
                    Log.trace("RustTerminalFFI: dlopen failed for \(path): \(errorStr)")
                } else {
                    Log.trace("RustTerminalFFI: dlopen failed for \(path) (no error details)")
                }
            }
        }
        Log.error("RustTerminalFFI: Failed to load library from any candidate path")
    }

    private static func libraryCandidates() -> [String] {
        var paths: [String] = []
        if let envPath = ProcessInfo.processInfo.environment["CHAU7_RUST_LIB_PATH"], !envPath.isEmpty {
            paths.append(envPath)
        }
        // Try chau7_terminal first (the terminal emulator lib)
        if let resourcePath = Bundle.main.path(forResource: "libchau7_terminal", ofType: "dylib") {
            paths.append(resourcePath)
        }
        if let resourceRoot = Bundle.main.resourcePath {
            paths.append("\(resourceRoot)/libchau7_terminal.dylib")
        }
        if let frameworksRoot = Bundle.main.privateFrameworksPath {
            paths.append("\(frameworksRoot)/libchau7_terminal.dylib")
        }
        // Development paths
        #if DEBUG
        let devPaths = [
            "rust/target/release/libchau7_terminal.dylib",
            "rust/target/debug/libchau7_terminal.dylib",
            "../rust/target/release/libchau7_terminal.dylib",
            "../rust/target/debug/libchau7_terminal.dylib"
        ]
        paths.append(contentsOf: devPaths)
        #endif
        return paths
    }

    private static func loadFunctions(from handle: UnsafeMutableRawPointer) -> Functions? {
        Log.trace("RustTerminalFFI: Loading symbols from library handle")

        /// Helper to load a symbol with logging
        func loadSymbol(_ name: String) -> UnsafeMutableRawPointer? {
            let sym = dlsym(handle, name)
            if sym != nil {
                Log.trace("RustTerminalFFI: ✓ Loaded symbol '\(name)'")
            } else {
                if let errorPtr = dlerror() {
                    let errorStr = String(cString: errorPtr)
                    Log.warn("RustTerminalFFI: ✗ Failed to load symbol '\(name)': \(errorStr)")
                } else {
                    Log.warn("RustTerminalFFI: ✗ Failed to load symbol '\(name)' (no error details)")
                }
            }
            return sym
        }

        guard let createSym = loadSymbol("chau7_terminal_create"),
              let destroySym = loadSymbol("chau7_terminal_destroy"),
              let sendBytesSym = loadSymbol("chau7_terminal_send_bytes"),
              let sendTextSym = loadSymbol("chau7_terminal_send_text"),
              let resizeSym = loadSymbol("chau7_terminal_resize"),
              let getGridSym = loadSymbol("chau7_terminal_get_grid"),
              let freeGridSym = loadSymbol("chau7_terminal_free_grid"),
              let scrollPositionSym = loadSymbol("chau7_terminal_scroll_position"),
              let scrollToSym = loadSymbol("chau7_terminal_scroll_to"),
              let scrollLinesSym = loadSymbol("chau7_terminal_scroll_lines"),
              let selectionTextSym = loadSymbol("chau7_terminal_selection_text"),
              let selectionClearSym = loadSymbol("chau7_terminal_selection_clear"),
              let freeStringSym = loadSymbol("chau7_terminal_free_string"),
              let cursorPositionSym = loadSymbol("chau7_terminal_cursor_position"),
              let pollSym = loadSymbol("chau7_terminal_poll")
        else {
            Log.error("RustTerminalFFI: One or more required symbols missing")
            return nil
        }

        // Optional symbols - may not be present in older library versions
        let createWithEnvSym = loadSymbol("chau7_terminal_create_with_env")
        if createWithEnvSym == nil {
            Log.info("RustTerminalFFI: createWithEnv symbol not found (optional)")
        }

        let setColorsSym = loadSymbol("chau7_terminal_set_colors")
        if setColorsSym == nil {
            Log.info("RustTerminalFFI: setColors symbol not found (optional)")
        }

        let clearScrollbackSym = loadSymbol("chau7_terminal_clear_scrollback")
        if clearScrollbackSym == nil {
            Log.info("RustTerminalFFI: clearScrollback symbol not found (optional)")
        }

        // Selection management symbols (start, update, select-all via Rust FFI)
        let selectionStartSym = loadSymbol("chau7_terminal_selection_start")
        if selectionStartSym == nil {
            Log.info("RustTerminalFFI: selectionStart symbol not found (optional)")
        }

        let selectionUpdateSym = loadSymbol("chau7_terminal_selection_update")
        if selectionUpdateSym == nil {
            Log.info("RustTerminalFFI: selectionUpdate symbol not found (optional)")
        }

        let selectionAllSym = loadSymbol("chau7_terminal_selection_all")
        if selectionAllSym == nil {
            Log.info("RustTerminalFFI: selectionAll symbol not found (optional)")
        }

        // Raw output retrieval symbols (getLastOutput / freeOutput)
        let getLastOutputSym = loadSymbol("chau7_terminal_get_last_output")
        if getLastOutputSym == nil {
            Log.info("RustTerminalFFI: getLastOutput symbol not found (optional)")
        }

        let freeOutputSym = loadSymbol("chau7_terminal_free_output")
        if freeOutputSym == nil {
            Log.info("RustTerminalFFI: freeOutput symbol not found (optional)")
        }

        let injectOutputSym = loadSymbol("chau7_terminal_inject_output")
        if injectOutputSym == nil {
            Log.info("RustTerminalFFI: inject_output symbol not found (optional)")
        }

        // Scrollback size configuration symbol
        let setScrollbackSizeSym = loadSymbol("chau7_terminal_set_scrollback_size")
        if setScrollbackSizeSym == nil {
            Log.info("RustTerminalFFI: setScrollbackSize symbol not found (optional)")
        }

        // Smart scroll support: display offset symbol
        let displayOffsetSym = loadSymbol("chau7_terminal_display_offset")
        if displayOffsetSym == nil {
            Log.info("RustTerminalFFI: displayOffset symbol not found (optional)")
        }

        // Bracketed paste mode query (for proper paste handling in vim, zsh, etc.)
        let isBracketedPasteModeSym = loadSymbol("chau7_terminal_is_bracketed_paste_mode")
        if isBracketedPasteModeSym == nil {
            Log.info("RustTerminalFFI: isBracketedPasteMode symbol not found (optional)")
        }

        // Bell event checking (for audio/visual bell feedback)
        let checkBellSym = loadSymbol("chau7_terminal_check_bell")
        if checkBellSym == nil {
            Log.info("RustTerminalFFI: checkBell symbol not found (optional)")
        }

        // Mouse mode query (for mouse reporting to TUI apps)
        let getMouseModeSym = loadSymbol("chau7_terminal_get_mouse_mode")
        if getMouseModeSym == nil {
            Log.info("RustTerminalFFI: getMouseMode symbol not found (optional)")
        }

        // Mouse reporting active check (convenience function)
        let isMouseReportingActiveSym = loadSymbol("chau7_terminal_is_mouse_reporting_active")
        if isMouseReportingActiveSym == nil {
            Log.info("RustTerminalFFI: is_mouse_reporting_active symbol not found (optional)")
        }

        // Application cursor mode (DECCKM) query - for proper arrow key sequences in vim/tmux
        let isApplicationCursorModeSym = loadSymbol("chau7_terminal_is_application_cursor_mode")
        if isApplicationCursorModeSym == nil {
            Log.info("RustTerminalFFI: is_application_cursor_mode symbol not found (optional)")
        }

        // Debug and performance functions
        let getShellPidSym = loadSymbol("chau7_terminal_get_shell_pid")
        if getShellPidSym == nil {
            Log.info("RustTerminalFFI: get_shell_pid symbol not found (optional)")
        }

        let getDebugStateSym = loadSymbol("chau7_terminal_get_debug_state")
        if getDebugStateSym == nil {
            Log.info("RustTerminalFFI: get_debug_state symbol not found (optional)")
        }

        let freeDebugStateSym = loadSymbol("chau7_terminal_free_debug_state")
        if freeDebugStateSym == nil {
            Log.info("RustTerminalFFI: free_debug_state symbol not found (optional)")
        }

        let getFullBufferTextSym = loadSymbol("chau7_terminal_get_full_buffer_text")
        if getFullBufferTextSym == nil {
            Log.info("RustTerminalFFI: get_full_buffer_text symbol not found (optional)")
        }

        let resetMetricsSym = loadSymbol("chau7_terminal_reset_metrics")
        if resetMetricsSym == nil {
            Log.info("RustTerminalFFI: reset_metrics symbol not found (optional)")
        }

        // Terminal event functions (title, exit, PTY closed)
        let getPendingTitleSym = loadSymbol("chau7_terminal_get_pending_title")
        if getPendingTitleSym == nil {
            Log.info("RustTerminalFFI: get_pending_title symbol not found (optional)")
        }

        let getPendingExitCodeSym = loadSymbol("chau7_terminal_get_pending_exit_code")
        if getPendingExitCodeSym == nil {
            Log.info("RustTerminalFFI: get_pending_exit_code symbol not found (optional)")
        }

        let isPtyClosedSym = loadSymbol("chau7_terminal_is_pty_closed")
        if isPtyClosedSym == nil {
            Log.info("RustTerminalFFI: is_pty_closed symbol not found (optional)")
        }

        // Echo detection via termios (Phase 2: reliable password prompt detection)
        let isEchoDisabledSym = loadSymbol("chau7_terminal_is_echo_disabled")
        if isEchoDisabledSym == nil {
            Log.info("RustTerminalFFI: is_echo_disabled symbol not found (optional, falling back to heuristic)")
        }

        // Direct line text retrieval (avoids full grid snapshot per row)
        let getLineTextDirectSym = loadSymbol("chau7_terminal_get_line_text")
        if getLineTextDirectSym == nil {
            Log.info("RustTerminalFFI: get_line_text symbol not found (optional, falling back to grid snapshot)")
        }

        let getLogicalLineTextDirectSym = loadSymbol("chau7_terminal_get_logical_line_text")
        if getLogicalLineTextDirectSym == nil {
            Log.info("RustTerminalFFI: get_logical_line_text symbol not found (optional, falling back to physical row hit-testing)")
        }

        // Hyperlink support (OSC 8 — Phase 5)
        let getLinkUrlSym = loadSymbol("chau7_terminal_get_link_url")
        if getLinkUrlSym == nil {
            Log.info("RustTerminalFFI: get_link_url symbol not found (optional)")
        }

        // Clipboard support (OSC 52 — Phase 5)
        let getPendingClipboardSym = loadSymbol("chau7_terminal_get_pending_clipboard")
        let hasClipboardRequestSym = loadSymbol("chau7_terminal_has_clipboard_request")
        let respondClipboardSym = loadSymbol("chau7_terminal_respond_clipboard")
        if getPendingClipboardSym == nil {
            Log.info("RustTerminalFFI: clipboard (OSC 52) symbols not found (optional)")
        }

        // Shell integration (OSC 133)
        let getPendingShellIntegrationEventsSym = loadSymbol("chau7_terminal_get_pending_shell_events")
        let freeShellIntegrationEventsSym = loadSymbol("chau7_terminal_free_shell_events")
        if getPendingShellIntegrationEventsSym == nil {
            Log.info("RustTerminalFFI: shell integration (OSC 133) symbols not found (optional)")
        }

        // Graphics protocol support (Phase 4: image protocol pre-processor)
        let getPendingImagesSym = loadSymbol("chau7_terminal_get_pending_images")
        let freeImagesSym = loadSymbol("chau7_terminal_free_images")
        let setImageProtocolsSym = loadSymbol("chau7_terminal_set_image_protocols")
        let hasPendingImagesSym = loadSymbol("chau7_terminal_has_pending_images")
        if getPendingImagesSym == nil {
            Log.info("RustTerminalFFI: graphics protocol symbols not found (optional)")
        }

        Log.info("RustTerminalFFI: All 15 required symbols loaded successfully")

        return Functions(
            create: unsafeBitCast(createSym, to: CreateFn.self),
            createWithEnv: createWithEnvSym.map { unsafeBitCast($0, to: CreateWithEnvFn.self) },
            destroy: unsafeBitCast(destroySym, to: DestroyFn.self),
            sendBytes: unsafeBitCast(sendBytesSym, to: SendBytesFn.self),
            sendText: unsafeBitCast(sendTextSym, to: SendTextFn.self),
            resize: unsafeBitCast(resizeSym, to: ResizeFn.self),
            getGrid: unsafeBitCast(getGridSym, to: GetGridFn.self),
            freeGrid: unsafeBitCast(freeGridSym, to: FreeGridFn.self),
            scrollPosition: unsafeBitCast(scrollPositionSym, to: ScrollPositionFn.self),
            scrollTo: unsafeBitCast(scrollToSym, to: ScrollToFn.self),
            scrollLines: unsafeBitCast(scrollLinesSym, to: ScrollLinesFn.self),
            selectionText: unsafeBitCast(selectionTextSym, to: SelectionTextFn.self),
            selectionClear: unsafeBitCast(selectionClearSym, to: SelectionClearFn.self),
            selectionStart: selectionStartSym.map { unsafeBitCast($0, to: SelectionStartFn.self) },
            selectionUpdate: selectionUpdateSym.map { unsafeBitCast($0, to: SelectionUpdateFn.self) },
            selectionAll: selectionAllSym.map { unsafeBitCast($0, to: SelectionAllFn.self) },
            freeString: unsafeBitCast(freeStringSym, to: FreeStringFn.self),
            cursorPosition: unsafeBitCast(cursorPositionSym, to: CursorPositionFn.self),
            poll: unsafeBitCast(pollSym, to: PollFn.self),
            setColors: setColorsSym.map { unsafeBitCast($0, to: SetColorsFn.self) },
            clearScrollback: clearScrollbackSym.map { unsafeBitCast($0, to: ClearScrollbackFn.self) },
            getLastOutput: getLastOutputSym.map { unsafeBitCast($0, to: GetLastOutputFn.self) },
            freeOutput: freeOutputSym.map { unsafeBitCast($0, to: FreeOutputFn.self) },
            injectOutput: injectOutputSym.map { unsafeBitCast($0, to: InjectOutputFn.self) },
            setScrollbackSize: setScrollbackSizeSym.map { unsafeBitCast($0, to: SetScrollbackSizeFn.self) },
            displayOffset: displayOffsetSym.map { unsafeBitCast($0, to: DisplayOffsetFn.self) },
            isBracketedPasteMode: isBracketedPasteModeSym.map { unsafeBitCast($0, to: IsBracketedPasteModeFn.self) },
            checkBell: checkBellSym.map { unsafeBitCast($0, to: CheckBellFn.self) },
            getMouseMode: getMouseModeSym.map { unsafeBitCast($0, to: GetMouseModeFn.self) },
            isMouseReportingActive: isMouseReportingActiveSym.map { unsafeBitCast($0, to: IsMouseReportingActiveFn.self) },
            isApplicationCursorMode: isApplicationCursorModeSym.map { unsafeBitCast($0, to: IsApplicationCursorModeFn.self) },
            getShellPid: getShellPidSym.map { unsafeBitCast($0, to: GetShellPidFn.self) },
            getDebugState: getDebugStateSym.map { unsafeBitCast($0, to: GetDebugStateFn.self) },
            freeDebugState: freeDebugStateSym.map { unsafeBitCast($0, to: FreeDebugStateFn.self) },
            getFullBufferText: getFullBufferTextSym.map { unsafeBitCast($0, to: GetFullBufferTextFn.self) },
            resetMetrics: resetMetricsSym.map { unsafeBitCast($0, to: ResetMetricsFn.self) },
            getPendingTitle: getPendingTitleSym.map { unsafeBitCast($0, to: GetPendingTitleFn.self) },
            getPendingExitCode: getPendingExitCodeSym.map { unsafeBitCast($0, to: GetPendingExitCodeFn.self) },
            isPtyClosed: isPtyClosedSym.map { unsafeBitCast($0, to: IsPtyClosedFn.self) },
            isEchoDisabled: isEchoDisabledSym.map { unsafeBitCast($0, to: IsEchoDisabledFn.self) },
            // Direct line text retrieval
            getLineTextDirect: getLineTextDirectSym.map { unsafeBitCast($0, to: GetLineTextFn.self) },
            getLogicalLineTextDirect: getLogicalLineTextDirectSym.map { unsafeBitCast($0, to: GetLogicalLineTextFn.self) },
            // Hyperlink support (OSC 8 — Phase 5)
            getLinkUrl: getLinkUrlSym.map { unsafeBitCast($0, to: GetLinkUrlFn.self) },
            // Clipboard support (OSC 52 — Phase 5)
            getPendingClipboard: getPendingClipboardSym.map { unsafeBitCast($0, to: GetPendingClipboardFn.self) },
            hasClipboardRequest: hasClipboardRequestSym.map { unsafeBitCast($0, to: HasClipboardRequestFn.self) },
            respondClipboard: respondClipboardSym.map { unsafeBitCast($0, to: RespondClipboardFn.self) },
            // Shell integration (OSC 133)
            getPendingShellIntegrationEvents: getPendingShellIntegrationEventsSym.map { unsafeBitCast($0, to: GetPendingShellIntegrationEventsFn.self) },
            freeShellIntegrationEvents: freeShellIntegrationEventsSym.map { unsafeBitCast($0, to: FreeShellIntegrationEventsFn.self) },
            // Graphics protocol support (Phase 4)
            getPendingImages: getPendingImagesSym.map { unsafeBitCast($0, to: GetPendingImagesFn.self) },
            freeImages: freeImagesSym.map { unsafeBitCast($0, to: FreeImagesFn.self) },
            setImageProtocols: setImageProtocolsSym.map { unsafeBitCast($0, to: SetImageProtocolsFn.self) },
            hasPendingImages: hasPendingImagesSym.map { unsafeBitCast($0, to: HasPendingImagesFn.self) }
        )
    }

    // MARK: - Instance Methods

    private let terminal: OpaquePointer
    private static var instanceCounter: UInt64 = 0
    private let instanceId: UInt64

    struct LogicalLineHit {
        let text: String
        let startRow: Int
        let clickedUTF16Offset: Int
    }

    init?(cols: UInt16, rows: UInt16, shell: String? = nil) {
        Self.instanceCounter += 1
        self.instanceId = Self.instanceCounter

        Log.info("RustTerminalFFI[\(instanceId)]: Creating terminal with cols=\(cols), rows=\(rows), shell=\(shell ?? "<default>")")

        Self.ensureLoaded()
        guard let fns = Self.functions else {
            Log.error("RustTerminalFFI[\(instanceId)]: FAILED - Library not loaded")
            return nil
        }

        let termPtr: OpaquePointer?
        if let shell = shell {
            Log.trace("RustTerminalFFI[\(instanceId)]: Using custom shell: \(shell)")
            termPtr = shell.withCString { fns.create(cols, rows, $0) }
        } else {
            Log.trace("RustTerminalFFI[\(instanceId)]: Using default shell")
            termPtr = fns.create(cols, rows, nil)
        }

        guard let ptr = termPtr else {
            Log.error("RustTerminalFFI[\(instanceId)]: FAILED - chau7_terminal_create returned nil")
            return nil
        }
        self.terminal = ptr
        Log.info("RustTerminalFFI[\(instanceId)]: SUCCESS - Terminal created")
    }

    /// Create a terminal with environment variables
    init?(cols: UInt16, rows: UInt16, shell: String?, environment: [String: String]) {
        Self.instanceCounter += 1
        self.instanceId = Self.instanceCounter

        Log.info("RustTerminalFFI[\(instanceId)]: Creating terminal with cols=\(cols), rows=\(rows), shell=\(shell ?? "<default>"), env=\(environment.count) vars")

        Self.ensureLoaded()
        guard let fns = Self.functions else {
            Log.error("RustTerminalFFI[\(instanceId)]: FAILED - Library not loaded")
            return nil
        }

        let termPtr: OpaquePointer?

        // Use createWithEnv if available and we have environment variables
        if let createWithEnv = fns.createWithEnv, !environment.isEmpty {
            Log.trace("RustTerminalFFI[\(instanceId)]: Using createWithEnv with \(environment.count) environment variables")

            // Prepare C string arrays for environment
            var keys: [UnsafePointer<CChar>?] = []
            var values: [UnsafePointer<CChar>?] = []
            var keyData: [ContiguousArray<CChar>] = []
            var valueData: [ContiguousArray<CChar>] = []

            for (key, value) in environment {
                keyData.append(ContiguousArray(key.utf8CString))
                valueData.append(ContiguousArray(value.utf8CString))
            }

            // Get pointers to the data
            for i in 0 ..< keyData.count {
                keys.append(keyData[i].withUnsafeBufferPointer { $0.baseAddress })
                values.append(valueData[i].withUnsafeBufferPointer { $0.baseAddress })
            }

            // Call with environment
            termPtr = keys.withUnsafeBufferPointer { keysPtr in
                values.withUnsafeBufferPointer { valuesPtr in
                    if let shell = shell {
                        return shell.withCString { shellPtr in
                            createWithEnv(cols, rows, shellPtr, keysPtr.baseAddress, valuesPtr.baseAddress, environment.count)
                        }
                    } else {
                        return createWithEnv(cols, rows, nil, keysPtr.baseAddress, valuesPtr.baseAddress, environment.count)
                    }
                }
            }
        } else {
            // Fall back to basic create
            Log.trace("RustTerminalFFI[\(instanceId)]: Using basic create (createWithEnv not available or no env vars)")
            if let shell = shell {
                termPtr = shell.withCString { fns.create(cols, rows, $0) }
            } else {
                termPtr = fns.create(cols, rows, nil)
            }
        }

        guard let ptr = termPtr else {
            Log.error("RustTerminalFFI[\(instanceId)]: FAILED - terminal_create returned nil")
            return nil
        }
        self.terminal = ptr
        Log.info("RustTerminalFFI[\(instanceId)]: SUCCESS - Terminal created with environment")
    }

    /// Serial queue for PTY writes. The kernel PTY buffer is finite (~64KB);
    /// when a child process stops reading stdin the buffer fills up and write()
    /// blocks. By dispatching writes to a dedicated serial queue we keep the
    /// main thread responsive — the write blocks the queue thread instead of
    /// the UI. The serial ordering guarantees bytes arrive in order.
    private let writeQueue = DispatchQueue(label: "com.chau7.pty-write", qos: .userInitiated)

    deinit {
        Log.info("RustTerminalFFI[\(instanceId)]: deinit - Destroying terminal")
        // Dispatch destruction off the current thread. The Rust Drop impl
        // sends SIGKILL and waits for the child process to exit, which can
        // block. If deinit runs on the main thread (common via SwiftUI view
        // responder cleanup on mouseMoved), this would freeze the UI.
        //
        // We dispatch onto the writeQueue to ensure all pending writes complete
        // before the terminal is destroyed. The barrier ensures ordering.
        let ptr = terminal
        let id = instanceId
        let destroyFn = Self.functions?.destroy
        writeQueue.async {
            destroyFn?(ptr)
            Log.trace("RustTerminalFFI[\(id)]: deinit - Terminal destroyed (background)")
        }
    }

    func sendBytes(_ data: Data) {
        guard let fns = Self.functions else {
            Log.warn("RustTerminalFFI[\(instanceId)]: sendBytes(Data) - Library not loaded, discarding \(data.count) bytes")
            return
        }
        Log.trace("RustTerminalFFI[\(instanceId)]: sendBytes(Data) - Sending \(data.count) bytes")
        let terminal = terminal
        let id = instanceId
        // Copy data before dispatching — the original buffer may be freed
        let copy = Data(data)
        writeQueue.async {
            copy.withUnsafeBytes { buffer in
                guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    Log.warn("RustTerminalFFI[\(id)]: sendBytes(Data) - Buffer baseAddress is nil")
                    return
                }
                fns.sendBytes(terminal, ptr, buffer.count)
            }
        }
    }

    func sendBytes(_ bytes: [UInt8]) {
        guard let fns = Self.functions else {
            Log.warn("RustTerminalFFI[\(instanceId)]: sendBytes([UInt8]) - Library not loaded, discarding \(bytes.count) bytes")
            return
        }
        Log.trace("RustTerminalFFI[\(instanceId)]: sendBytes([UInt8]) - Sending \(bytes.count) bytes")
        let terminal = terminal
        let id = instanceId
        let copy = bytes
        writeQueue.async {
            copy.withUnsafeBufferPointer { buffer in
                guard let ptr = buffer.baseAddress else {
                    Log.warn("RustTerminalFFI[\(id)]: sendBytes([UInt8]) - Buffer baseAddress is nil")
                    return
                }
                fns.sendBytes(terminal, ptr, buffer.count)
            }
        }
    }

    func sendText(_ text: String) {
        guard let fns = Self.functions else {
            Log.warn("RustTerminalFFI[\(instanceId)]: sendText - Library not loaded, discarding \(text.count) chars")
            return
        }
        Log.trace("RustTerminalFFI[\(instanceId)]: sendText - Sending \(text.count) chars")
        let terminal = terminal
        writeQueue.async {
            text.withCString { fns.sendText(terminal, $0) }
        }
    }

    func injectOutput(_ data: Data) {
        guard let fns = Self.functions else {
            Log.warn("RustTerminalFFI[\(instanceId)]: injectOutput - Library not loaded, discarding \(data.count) bytes")
            return
        }
        guard let inject = fns.injectOutput else {
            Log.warn("RustTerminalFFI[\(instanceId)]: injectOutput - Symbol not available, discarding \(data.count) bytes")
            return
        }
        Log.trace("RustTerminalFFI[\(instanceId)]: injectOutput - Injecting \(data.count) bytes")
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                Log.warn("RustTerminalFFI[\(instanceId)]: injectOutput - Buffer baseAddress is nil")
                return
            }
            inject(terminal, ptr, buffer.count)
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        Log.trace("RustTerminalFFI[\(instanceId)]: resize - Resizing to \(cols)x\(rows)")
        Self.functions?.resize(terminal, cols, rows)
    }

    func getGrid() -> (snapshot: UnsafeMutablePointer<RustGridSnapshot>, free: () -> Void)? {
        guard let fns = Self.functions else {
            Log.warn("RustTerminalFFI[\(instanceId)]: getGrid - Library not loaded")
            return nil
        }
        guard let rawGrid = fns.getGrid(terminal) else {
            Log.trace("RustTerminalFFI[\(instanceId)]: getGrid - chau7_terminal_get_grid returned nil")
            return nil
        }
        let grid = rawGrid.assumingMemoryBound(to: RustGridSnapshot.self)
        let snapshot = grid.pointee
        Log.trace("RustTerminalFFI[\(instanceId)]: getGrid - Got snapshot \(snapshot.cols)x\(snapshot.rows), scrollback=\(snapshot.scrollback_rows), offset=\(snapshot.display_offset)")
        return (grid, {
            Log.trace("RustTerminalFFI[?]: getGrid - Freeing grid snapshot")
            fns.freeGrid(rawGrid)
        })
    }

    var scrollPosition: Double {
        let pos = Self.functions?.scrollPosition(terminal) ?? 0.0
        Log.trace("RustTerminalFFI[\(instanceId)]: scrollPosition = \(pos)")
        return pos
    }

    func scrollTo(position: Double) {
        Log.trace("RustTerminalFFI[\(instanceId)]: scrollTo - position=\(position)")
        Self.functions?.scrollTo(terminal, position)
    }

    func scrollLines(_ lines: Int32) {
        Log.trace("RustTerminalFFI[\(instanceId)]: scrollLines - lines=\(lines) (\(lines > 0 ? "up" : "down"))")
        Self.functions?.scrollLines(terminal, lines)
    }

    func getSelectionText() -> String? {
        guard let fns = Self.functions else {
            Log.warn("RustTerminalFFI[\(instanceId)]: getSelectionText - Library not loaded")
            return nil
        }
        guard let ptr = fns.selectionText(terminal) else {
            Log.trace("RustTerminalFFI[\(instanceId)]: getSelectionText - No selection")
            return nil
        }
        defer { fns.freeString(ptr) }
        let text = String(cString: ptr)
        Log.trace("RustTerminalFFI[\(instanceId)]: getSelectionText - Got selection with \(text.count) chars")
        return text
    }

    /// Get text content of a specific row from the terminal grid.
    ///
    /// Uses the direct Rust FFI `chau7_terminal_get_line_text` which reads a single
    /// row from the grid with just a term lock — no grid snapshot, no color conversion,
    /// no cell buffer allocation. This is ~30× faster than the previous approach which
    /// created a full grid snapshot (with all cell colors, hyperlinks, etc.) per row.
    func getLineText(row: Int) -> String? {
        // Fast path: use the direct FFI call (available in current library)
        if let fns = Self.functions, let getLineTextFn = fns.getLineTextDirect {
            guard let ptr = getLineTextFn(terminal, Int32(row)) else { return nil }
            defer { fns.freeString(ptr) }
            return String(cString: ptr)
        }
        // Fallback: grid snapshot approach (for older library versions)
        guard let gridResult = getGrid() else { return nil }
        defer { gridResult.free() }
        let snapshot = gridResult.snapshot.pointee
        let gridCols = Int(snapshot.cols)
        let gridRows = Int(snapshot.rows)
        guard row >= 0, row < gridRows, let cellsPtr = snapshot.cells else { return nil }
        var lineText = ""
        lineText.reserveCapacity(gridCols)
        let rowOffset = row * gridCols
        for col in 0 ..< gridCols {
            let cell = cellsPtr[rowOffset + col]
            if let scalar = UnicodeScalar(cell.character), cell.character != 0 {
                lineText.append(Character(scalar))
            } else { lineText.append(" ") }
        }
        while lineText.last == " " {
            lineText.removeLast()
        }
        return lineText
    }

    func getLogicalLineHit(row: Int, column: Int) -> LogicalLineHit? {
        let clampedColumn = max(0, column)
        if let fns = Self.functions, let getLogicalLineTextFn = fns.getLogicalLineTextDirect {
            var startRow = Int32(row)
            var clickedUTF16Offset: UInt32 = 0
            guard let ptr = getLogicalLineTextFn(
                terminal,
                Int32(row),
                UInt32(clampedColumn),
                &startRow,
                &clickedUTF16Offset
            ) else {
                return nil
            }
            defer { fns.freeString(ptr) }
            return LogicalLineHit(
                text: String(cString: ptr),
                startRow: Int(startRow),
                clickedUTF16Offset: Int(clickedUTF16Offset)
            )
        }

        guard let text = getLineText(row: row) else { return nil }
        return LogicalLineHit(
            text: text,
            startRow: row,
            clickedUTF16Offset: min(clampedColumn, (text as NSString).length)
        )
    }

    func clearSelection() {
        Log.trace("RustTerminalFFI[\(instanceId)]: clearSelection")
        Self.functions?.selectionClear(terminal)
    }

    /// Start a new selection at the given position using Rust's native selection API
    /// - Parameters:
    ///   - col: Column position (0-indexed)
    ///   - row: Row position (can be negative for scrollback)
    ///   - selectionType: 0 = Simple (character), 1 = Block, 2 = Semantic (word), 3 = Lines
    func startSelection(col: Int32, row: Int32, selectionType: UInt8 = 0) {
        guard let startFn = Self.functions?.selectionStart else {
            Log.trace("RustTerminalFFI[\(instanceId)]: startSelection - Function not available")
            return
        }
        Log.trace("RustTerminalFFI[\(instanceId)]: startSelection - col=\(col), row=\(row), type=\(selectionType)")
        startFn(terminal, col, row, selectionType)
    }

    /// Update the current selection to extend to the given position
    func updateSelection(col: Int32, row: Int32) {
        guard let updateFn = Self.functions?.selectionUpdate else {
            Log.trace("RustTerminalFFI[\(instanceId)]: updateSelection - Function not available")
            return
        }
        Log.trace("RustTerminalFFI[\(instanceId)]: updateSelection - col=\(col), row=\(row)")
        updateFn(terminal, col, row)
    }

    /// Select all content (screen + scrollback) via Rust's native selection API
    func selectAll() {
        guard let selectAllFn = Self.functions?.selectionAll else {
            Log.trace("RustTerminalFFI[\(instanceId)]: selectAll - Function not available")
            return
        }
        Log.trace("RustTerminalFFI[\(instanceId)]: selectAll - Selecting all content")
        selectAllFn(terminal)
    }

    var cursorPosition: (col: UInt16, row: UInt16) {
        var col: UInt16 = 0
        var row: UInt16 = 0
        Self.functions?.cursorPosition(terminal, &col, &row)
        Log.trace("RustTerminalFFI[\(instanceId)]: cursorPosition = (\(col), \(row))")
        return (col, row)
    }

    /// Poll for PTY data. Returns true if grid changed.
    private static var pollCounter: UInt64 = 0
    private static var lastPollLogTime: CFAbsoluteTime = 0

    func poll(timeout: UInt32 = 0) -> Bool {
        let changed = Self.functions?.poll(terminal, timeout) ?? false

        // Rate-limit logging for poll (it's called 60x/second)
        Self.pollCounter += 1
        let now = CFAbsoluteTimeGetCurrent()
        let shouldLog = changed || (now - Self.lastPollLogTime > 5.0) // Log every 5s or on change

        if shouldLog {
            if changed {
                Log.trace("RustTerminalFFI[\(instanceId)]: poll - Grid CHANGED (poll #\(Self.pollCounter), timeout=\(timeout)ms)")
            } else {
                Log.trace("RustTerminalFFI[\(instanceId)]: poll - Status check (poll #\(Self.pollCounter))")
            }
            Self.lastPollLogTime = now
        }

        return changed
    }

    /// Set theme colors for rendering
    /// - Parameters:
    ///   - fg: Foreground color RGB
    ///   - bg: Background color RGB
    ///   - cursor: Cursor color RGB
    ///   - palette: 16-color ANSI palette (array of 16 RGB tuples)
    func setColors(fg: (UInt8, UInt8, UInt8), bg: (UInt8, UInt8, UInt8), cursor: (UInt8, UInt8, UInt8), palette: [(UInt8, UInt8, UInt8)]) {
        guard let setColors = Self.functions?.setColors else {
            Log.trace("RustTerminalFFI[\(instanceId)]: setColors - Function not available")
            return
        }

        // Flatten palette to array of bytes (48 bytes = 16 colors * 3 components)
        var paletteBytes: [UInt8] = []
        paletteBytes.reserveCapacity(48)
        for color in palette.prefix(16) {
            paletteBytes.append(color.0)
            paletteBytes.append(color.1)
            paletteBytes.append(color.2)
        }
        // Pad with black if palette has fewer than 16 colors
        while paletteBytes.count < 48 {
            paletteBytes.append(0)
        }

        paletteBytes.withUnsafeBufferPointer { buffer in
            setColors(terminal, fg.0, fg.1, fg.2, bg.0, bg.1, bg.2, cursor.0, cursor.1, cursor.2, buffer.baseAddress)
        }

        Log.trace("RustTerminalFFI[\(instanceId)]: setColors - fg=(\(fg.0),\(fg.1),\(fg.2)), bg=(\(bg.0),\(bg.1),\(bg.2)), cursor=(\(cursor.0),\(cursor.1),\(cursor.2))")
    }

    /// Clear the scrollback history buffer
    func clearScrollback() {
        guard let clearScrollbackFn = Self.functions?.clearScrollback else {
            Log.warn("RustTerminalFFI[\(instanceId)]: clearScrollback - Function not available")
            return
        }
        Log.info("RustTerminalFFI[\(instanceId)]: clearScrollback - Clearing scrollback history")
        clearScrollbackFn(terminal)
    }

    /// Set the scrollback buffer size (number of lines)
    func setScrollbackSize(_ lines: UInt32) {
        guard let setScrollbackSizeFn = Self.functions?.setScrollbackSize else {
            Log.warn("RustTerminalFFI[\(instanceId)]: setScrollbackSize - Function not available")
            return
        }
        Log.info("RustTerminalFFI[\(instanceId)]: setScrollbackSize - Setting scrollback to \(lines) lines")
        setScrollbackSizeFn(terminal, lines)
    }

    /// Get the current display offset (0 = at bottom, >0 = scrolled up into history)
    /// This is useful for implementing smart scroll behavior
    var displayOffset: UInt32 {
        guard let displayOffsetFn = Self.functions?.displayOffset else {
            // If function not available, assume at bottom (safest default)
            return 0
        }
        return displayOffsetFn(terminal)
    }

    /// Get raw output bytes from the last poll
    /// Returns nil if no output or function not available
    func getLastOutput() -> Data? {
        guard let getLastOutputFn = Self.functions?.getLastOutput,
              let freeOutputFn = Self.functions?.freeOutput else {
            // Function not available - this is expected for older libraries
            return nil
        }

        var len = 0
        guard let ptr = getLastOutputFn(terminal, &len), len > 0 else {
            return nil
        }

        // Copy the data before freeing
        let data = Data(bytes: ptr, count: len)

        // Free the output buffer (ptr is already mutable)
        freeOutputFn(ptr, len)

        Log.trace("RustTerminalFFI[\(instanceId)]: getLastOutput - Retrieved \(len) bytes")
        return data
    }

    /// Check if bracketed paste mode is enabled.
    /// When enabled, pasted text should be wrapped with ESC[200~ and ESC[201~.
    /// This is used by vim, zsh, readline, and other programs.
    func isBracketedPasteMode() -> Bool {
        guard let isBracketedPasteModeFn = Self.functions?.isBracketedPasteMode else {
            Log.trace("RustTerminalFFI[\(instanceId)]: isBracketedPasteMode - Function not available, returning false")
            return false
        }
        let enabled = isBracketedPasteModeFn(terminal)
        Log.trace("RustTerminalFFI[\(instanceId)]: isBracketedPasteMode = \(enabled)")
        return enabled
    }

    /// Check if a bell event has occurred since the last check.
    /// The flag is automatically cleared after reading.
    /// Returns true if bell was triggered.
    func checkBell() -> Bool {
        guard let checkBellFn = Self.functions?.checkBell else {
            // Function not available - no bell events will be reported
            return false
        }
        let bellOccurred = checkBellFn(terminal)
        if bellOccurred {
            Log.trace("RustTerminalFFI[\(instanceId)]: checkBell - Bell detected")
        }
        return bellOccurred
    }

    /// Get the current mouse mode as a bitfield.
    /// Returns a UInt32 with the following bits:
    /// - Bit 0 (0x01): MOUSE_REPORT_CLICK - Mouse mode 1000 (report button press/release)
    /// - Bit 1 (0x02): MOUSE_DRAG - Mouse mode 1002 (also report motion while button down)
    /// - Bit 2 (0x04): MOUSE_MOTION - Mouse mode 1003 (report all motion)
    /// - Bit 3 (0x08): FOCUS_IN_OUT - Focus reporting mode 1004
    /// - Bit 4 (0x10): SGR_MOUSE - Mouse mode 1006 (use SGR encoding for coordinates >223)
    func mouseMode() -> UInt32 {
        guard let getMouseModeFn = Self.functions?.getMouseMode else {
            Log.trace("RustTerminalFFI[\(instanceId)]: mouseMode - Function not available, returning 0")
            return 0
        }
        let mode = getMouseModeFn(terminal)
        Log.trace("RustTerminalFFI[\(instanceId)]: mouseMode = 0x\(String(mode, radix: 16))")
        return mode
    }

    /// Check if any mouse tracking mode is active (click, drag, or motion reporting).
    /// This is a convenience wrapper that returns true if modes 1000, 1002, or 1003 are enabled.
    func isMouseReportingActive() -> Bool {
        guard let isMouseReportingActiveFn = Self.functions?.isMouseReportingActive else {
            // If function not available, fall back to checking mouseMode directly
            let mode = mouseMode()
            return (mode & 0x07) != 0 // Bits 0-2 are mouse tracking modes
        }
        let active = isMouseReportingActiveFn(terminal)
        Log.trace("RustTerminalFFI[\(instanceId)]: isMouseReportingActive = \(active)")
        return active
    }

    /// Check if application cursor mode (DECCKM) is enabled.
    /// When enabled, arrow keys send SS3 sequences (ESC O A/B/C/D) instead of CSI (ESC [ A/B/C/D).
    /// This is typically set by vim, less, tmux, etc.
    func isApplicationCursorMode() -> Bool {
        guard let isApplicationCursorModeFn = Self.functions?.isApplicationCursorMode else {
            Log.trace("RustTerminalFFI[\(instanceId)]: isApplicationCursorMode - Function not available, returning false")
            return false
        }
        let enabled = isApplicationCursorModeFn(terminal)
        Log.trace("RustTerminalFFI[\(instanceId)]: isApplicationCursorMode = \(enabled)")
        return enabled
    }

    // MARK: - Debug and Performance Methods

    /// Get the shell process ID for dev server monitoring.
    /// Returns 0 if the function is not available or PID cannot be determined.
    func shellPid() -> pid_t {
        guard let getShellPidFn = Self.functions?.getShellPid else {
            Log.trace("RustTerminalFFI[\(instanceId)]: shellPid - Function not available")
            return 0
        }
        let pid = getShellPidFn(terminal)
        Log.trace("RustTerminalFFI[\(instanceId)]: shellPid = \(pid)")
        return pid_t(pid)
    }

    /// Debug state structure matching the Rust DebugState (u8 for bools for FFI safety)
    struct DebugState {
        let id: UInt64
        let cols: UInt16
        let rows: UInt16
        let historySize: UInt32
        let displayOffset: UInt32
        let cursorCol: UInt16
        let cursorRow: UInt16
        let bytesSent: UInt64
        let bytesReceived: UInt64
        let uptimeMs: UInt64
        let gridDirty: UInt8 // 0 = false, 1 = true
        let running: UInt8 // 0 = false, 1 = true
        let hasSelection: UInt8 // 0 = false, 1 = true
        let mouseMode: UInt32
        let bracketedPaste: UInt8 // 0 = false, 1 = true
        let appCursor: UInt8 // 0 = false, 1 = true
        let pollCount: UInt64
        let avgPollTimeUs: UInt64
        let maxPollTimeUs: UInt64
        let avgGridSnapshotTimeUs: UInt64
        let maxGridSnapshotTimeUs: UInt64
        let activityPercent: UInt8
        let idlePolls: UInt64
        let avgBatchSize: UInt64
        let dirtyRowCount: UInt32

        var description: String {
            """
            DebugState[id=\(id)]:
              Dimensions: \(cols)x\(rows)
              History: \(historySize) lines, offset=\(displayOffset)
              Cursor: (\(cursorCol), \(cursorRow))
              I/O: sent=\(bytesSent) bytes, received=\(bytesReceived) bytes
              Uptime: \(uptimeMs)ms
              State: gridDirty=\(gridDirty != 0), running=\(running != 0), hasSelection=\(hasSelection != 0)
              Modes: mouseMode=\(mouseMode), bracketedPaste=\(bracketedPaste != 0), appCursor=\(appCursor != 0)
              Perf: polls=\(pollCount), avgPoll=\(avgPollTimeUs)µs, maxPoll=\(maxPollTimeUs)µs
                    avgSnapshot=\(avgGridSnapshotTimeUs)µs, maxSnapshot=\(maxGridSnapshotTimeUs)µs
                    activity=\(activityPercent)%, idlePolls=\(idlePolls), avgBatch=\(avgBatchSize)B, dirtyRows=\(dirtyRowCount)
            """
        }
    }

    /// Get comprehensive debug state snapshot.
    func debugState() -> DebugState? {
        guard let getDebugStateFn = Self.functions?.getDebugState,
              let freeDebugStateFn = Self.functions?.freeDebugState else {
            Log.trace("RustTerminalFFI[\(instanceId)]: debugState - Function not available")
            return nil
        }

        guard let ptr = getDebugStateFn(terminal) else {
            Log.warn("RustTerminalFFI[\(instanceId)]: debugState - Rust returned null")
            return nil
        }
        defer { freeDebugStateFn(ptr) }

        // The Rust struct layout must match exactly
        let state = ptr.assumingMemoryBound(to: RustDebugState.self).pointee
        let result = DebugState(
            id: state.id,
            cols: state.cols,
            rows: state.rows,
            historySize: state.history_size,
            displayOffset: state.display_offset,
            cursorCol: state.cursor_col,
            cursorRow: state.cursor_row,
            bytesSent: state.bytes_sent,
            bytesReceived: state.bytes_received,
            uptimeMs: state.uptime_ms,
            gridDirty: state.grid_dirty,
            running: state.running,
            hasSelection: state.has_selection,
            mouseMode: state.mouse_mode,
            bracketedPaste: state.bracketed_paste,
            appCursor: state.app_cursor,
            pollCount: state.poll_count,
            avgPollTimeUs: state.avg_poll_time_us,
            maxPollTimeUs: state.max_poll_time_us,
            avgGridSnapshotTimeUs: state.avg_grid_snapshot_time_us,
            maxGridSnapshotTimeUs: state.max_grid_snapshot_time_us,
            activityPercent: state.activity_percent,
            idlePolls: state.idle_polls,
            avgBatchSize: state.avg_batch_size,
            dirtyRowCount: state.dirty_row_count
        )

        Log.trace("RustTerminalFFI[\(instanceId)]: debugState retrieved:\n\(result.description)")
        return result
    }

    /// Get the full terminal buffer text (visible + scrollback) for debugging.
    func fullBufferText() -> String? {
        guard let getFullBufferTextFn = Self.functions?.getFullBufferText,
              let freeStringFn = Self.functions?.freeString else {
            Log.trace("RustTerminalFFI[\(instanceId)]: fullBufferText - Function not available")
            return nil
        }

        guard let ptr = getFullBufferTextFn(terminal) else {
            Log.trace("RustTerminalFFI[\(instanceId)]: fullBufferText - No text returned")
            return nil
        }
        defer { freeStringFn(ptr) }

        let text = String(cString: ptr)
        Log.trace("RustTerminalFFI[\(instanceId)]: fullBufferText - \(text.count) characters")
        return text
    }

    /// Reset performance metrics.
    func resetMetrics() {
        guard let resetMetricsFn = Self.functions?.resetMetrics else {
            Log.trace("RustTerminalFFI[\(instanceId)]: resetMetrics - Function not available")
            return
        }
        resetMetricsFn(terminal)
        Log.info("RustTerminalFFI[\(instanceId)]: Performance metrics reset")
    }

    // MARK: - Terminal Event Methods

    /// Get pending terminal title change from OSC 0/1/2 escape sequences.
    /// Returns nil if no title change is pending.
    /// After calling this, the pending title is cleared.
    func getPendingTitle() -> String? {
        guard let getPendingTitleFn = Self.functions?.getPendingTitle,
              let freeStringFn = Self.functions?.freeString else {
            return nil
        }
        guard let cstr = getPendingTitleFn(terminal) else {
            return nil
        }
        defer { freeStringFn(cstr) }
        let title = String(cString: cstr)
        Log.trace("RustTerminalFFI[\(instanceId)]: getPendingTitle = \"\(title)\"")
        return title
    }

    /// Get pending child process exit code.
    /// Returns nil if the process hasn't exited, otherwise returns the exit code.
    /// After calling this, the pending exit code is cleared.
    func getPendingExitCode() -> Int32? {
        guard let getPendingExitCodeFn = Self.functions?.getPendingExitCode else {
            return nil
        }
        let code = getPendingExitCodeFn(terminal)
        if code == -1 {
            return nil // -1 means no exit code pending
        }
        Log.info("RustTerminalFFI[\(instanceId)]: getPendingExitCode = \(code)")
        return code
    }

    /// Check if the PTY has closed.
    func isPtyClosed() -> Bool {
        guard let isPtyClosedFn = Self.functions?.isPtyClosed else {
            return false
        }
        return isPtyClosedFn(terminal)
    }

    /// Check if PTY has echo disabled via termios tcgetattr.
    /// Returns true when the terminal is in password/secret input mode.
    /// Falls back to nil if the FFI function is not available (caller uses heuristic).
    func isEchoDisabledViaTermios() -> Bool? {
        guard let isEchoDisabledFn = Self.functions?.isEchoDisabled else {
            return nil // Signal to caller: FFI not available, use heuristic
        }
        return isEchoDisabledFn(terminal)
    }

    // MARK: - Hyperlink Methods (OSC 8 — Phase 5)

    /// Get the URL for a hyperlink ID from the most recent grid snapshot.
    /// Returns nil if the link_id is 0 or the function is not available.
    func getLinkUrl(linkId: UInt16) -> String? {
        guard linkId > 0,
              let getLinkUrlFn = Self.functions?.getLinkUrl,
              let freeStringFn = Self.functions?.freeString else {
            return nil
        }
        guard let cstr = getLinkUrlFn(terminal, linkId) else {
            return nil
        }
        defer { freeStringFn(cstr) }
        return String(cString: cstr)
    }

    // MARK: - Clipboard Methods (OSC 52 — Phase 5)

    /// Get pending clipboard store text from OSC 52.
    /// Returns the text the terminal wants placed on the system clipboard, or nil.
    func getPendingClipboard() -> String? {
        guard let getPendingClipboardFn = Self.functions?.getPendingClipboard,
              let freeStringFn = Self.functions?.freeString else {
            return nil
        }
        guard let cstr = getPendingClipboardFn(terminal) else {
            return nil
        }
        defer { freeStringFn(cstr) }
        let text = String(cString: cstr)
        Log.info("RustTerminalFFI[\(instanceId)]: OSC 52 clipboard store: \(text.count) chars")
        return text
    }

    /// Check if the terminal has a pending clipboard load request (OSC 52 read).
    func hasClipboardRequest() -> Bool {
        guard let hasClipboardRequestFn = Self.functions?.hasClipboardRequest else {
            return false
        }
        return hasClipboardRequestFn(terminal)
    }

    /// Respond to a pending clipboard load request with the current system clipboard text.
    func respondClipboard(text: String) {
        guard let respondClipboardFn = Self.functions?.respondClipboard else {
            return
        }
        text.withCString { cstr in
            respondClipboardFn(terminal, cstr)
        }
        Log.info("RustTerminalFFI[\(instanceId)]: OSC 52 clipboard load response: \(text.count) chars")
    }

    // MARK: - Shell Integration (OSC 133)

    /// Get pending OSC 133 shell integration events from the Rust terminal.
    func getPendingShellIntegrationEvents() -> [ShellIntegrationEvent] {
        guard let getFn = Self.functions?.getPendingShellIntegrationEvents,
              let freeFn = Self.functions?.freeShellIntegrationEvents else {
            return []
        }

        guard let rawPtr = getFn(terminal) else { return [] }
        defer { freeFn(rawPtr) }

        let array = rawPtr.assumingMemoryBound(to: RustShellEventArray.self).pointee
        let eventCount = array.count
        guard eventCount > 0, let ptr = array.events else { return [] }

        var events: [ShellIntegrationEvent] = []
        events.reserveCapacity(array.count)
        for i in 0 ..< array.count {
            let raw = ptr[i]
            switch raw.marker {
            case UInt8(ascii: "A"): events.append(.promptStart)
            case UInt8(ascii: "B"): events.append(.commandStart)
            case UInt8(ascii: "C"): events.append(.commandExecuted)
            case UInt8(ascii: "D"): events.append(.commandFinished(exitCode: raw.exit_code))
            default: break
            }
        }
        return events
    }

    // MARK: - Graphics Protocol Methods (Phase 4)

    /// C-compatible image data layout matching Rust's FFIImageData.
    /// Field order must match Rust #[repr(C)] exactly (ordered by descending alignment).
    struct FFIImageData {
        let id: UInt64
        let data: UnsafeMutablePointer<UInt8>?
        let data_len: Int
        let data_capacity: Int
        let anchor_row: Int32
        let anchor_col: UInt16
        let protocolType: UInt8 // 0=iTerm2, 1=Sixel, 2=Kitty
    }

    /// C-compatible image array layout matching Rust's FFIImageArray.
    struct FFIImageArray {
        let images: UnsafeMutablePointer<FFIImageData>?
        let count: Int
        let capacity: Int
    }

    /// Check if there are pending images from the Rust graphics interceptor.
    func hasPendingImages() -> Bool {
        guard let fn = Self.functions?.hasPendingImages else { return false }
        return fn(terminal)
    }

    /// Retrieve pending images from the Rust graphics interceptor.
    /// Returns an array of (protocol, data, anchorRow, anchorCol) tuples.
    /// Call this during pollAndSync to pick up intercepted image sequences.
    func getPendingImages() -> [(protocol: UInt8, data: Data, anchorRow: Int32, anchorCol: UInt16)]? {
        guard let getPendingFn = Self.functions?.getPendingImages,
              let freeFn = Self.functions?.freeImages else {
            return nil
        }

        guard let arrayPtr = getPendingFn(terminal) else {
            return nil // No pending images
        }
        // Ensure Rust memory is always freed, even if Data() allocation fails
        defer { freeFn(arrayPtr) }

        let array = arrayPtr.assumingMemoryBound(to: FFIImageArray.self).pointee
        guard let imagesPtr = array.images, array.count > 0 else { // swiftlint:disable:this empty_count
            return nil
        }

        var results: [(protocol: UInt8, data: Data, anchorRow: Int32, anchorCol: UInt16)] = []
        for i in 0 ..< array.count {
            let img = imagesPtr[i]
            if let dataPtr = img.data, img.data_len > 0 {
                let data = Data(bytes: dataPtr, count: img.data_len)
                results.append((
                    protocol: img.protocolType,
                    data: data,
                    anchorRow: img.anchor_row,
                    anchorCol: img.anchor_col
                ))
            }
        }

        return results.isEmpty ? nil : results
    }

    /// Configure which image protocols the Rust interceptor should handle.
    func setImageProtocols(sixel: Bool, kitty: Bool, iterm2: Bool) {
        guard let fn = Self.functions?.setImageProtocols else { return }
        fn(terminal, sixel, kitty, iterm2)
    }
}

// MARK: - Rust Debug State Layout

/// C-compatible layout matching Rust's DebugState struct.
/// This must match the Rust struct exactly in size and alignment.
/// Note: Uses UInt8 for booleans (0=false, 1=true) for FFI safety.
struct RustDebugState {
    let id: UInt64
    let cols: UInt16
    let rows: UInt16
    let history_size: UInt32
    let display_offset: UInt32
    let cursor_col: UInt16
    let cursor_row: UInt16
    let bytes_sent: UInt64
    let bytes_received: UInt64
    let uptime_ms: UInt64
    let grid_dirty: UInt8
    let running: UInt8
    let has_selection: UInt8
    let mouse_mode: UInt32
    let bracketed_paste: UInt8
    let app_cursor: UInt8
    let poll_count: UInt64
    let avg_poll_time_us: UInt64
    let max_poll_time_us: UInt64
    let avg_grid_snapshot_time_us: UInt64
    let max_grid_snapshot_time_us: UInt64
    let activity_percent: UInt8
    let idle_polls: UInt64
    let avg_batch_size: UInt64
    let dirty_row_count: UInt32
}

// MARK: - RustTerminalView

/// A terminal view that uses Rust for terminal emulation and a native grid renderer.
///
/// This hybrid approach provides:
/// - Portable terminal logic (Rust/alacritty_terminal)
/// - Native grid renderer for text output
///
/// Architecture:
/// - Rust owns: PTY, terminal state machine, scrollback, selection
/// - Native renderer provides: grid-based text rendering
/// - This view bridges them: polls Rust at 60fps, feeds the native renderer
final class RustTerminalView: NSView {

    // MARK: - Public Interface

    /// Callback when PTY output is received
    var onOutput: ((Data) -> Void)?

    /// Callback when user input is sent
    var onInput: ((String) -> Void)?

    /// Callback before user-originated text is sent to the PTY.
    var shouldAcceptUserText: ((String) -> Bool)?

    /// Callback when buffer content changes
    var onBufferChanged: (() -> Void)?

    /// Callback when scroll position changes
    var onScrollChanged: (() -> Void)?

    /// Callback when scrollback is cleared
    var onScrollbackCleared: (() -> Void)?

    /// Callback for file path clicks (path, line, column)
    var onFilePathClicked: ((String, Int?, Int?) -> Void)?

    /// Callback when terminal title changes (OSC 0/1/2)
    var onTitleChanged: ((String) -> Void)?

    /// Callback when shell process terminates
    var onProcessTerminated: ((Int32?) -> Void)?

    /// Callback when current directory changes (OSC 7)
    var onDirectoryChanged: ((String) -> Void)?

    /// Callback when shell integration reports the current git branch
    /// (via OSC 9;chau7;branch=NAME). Fires on every prompt in a git repo.
    var onBranchChanged: ((String) -> Void)?

    /// Callback when OSC 133 shell integration events arrive (prompt/command lifecycle)
    var onShellIntegrationEvent: ((ShellIntegrationEvent) -> Void)?

    /// Callback when shell produces no PTY output within the startup timeout
    var onShellStartupSlow: (() -> Void)?

    /// Current working directory
    var currentDirectory: String = RuntimeIsolation.homePath()

    /// Command history navigation
    var tabIdentifier = ""
    var isAtPrompt: (() -> Bool)?

    /// Shell process ID (for dev server monitoring)
    var shellPid: pid_t {
        rustTerminal?.shellPid() ?? 0
    }

    /// Cursor line highlight support
    weak var cursorLineView: TerminalCursorLineView?
    let inputLineTracker = InputLineTracker(maxEntries: FeatureSettings.shared.scrollbackLines)
    var highlightContextLines = false
    var highlightInputHistory = false
    var isCursorLineHighlightEnabled = false

    /// Provider for dangerous row tints (absolute row range → tint map).
    /// Set during view setup to avoid coupling to session model directly.
    var dangerousRowTintsProvider: ((Int, Int) -> [Int: NSColor])?

    /// Whether to enable mouse reporting to the PTY
    var allowMouseReporting = false

    /// Whether to notify of update changes (for suspended state)
    var notifyUpdateChanges = true {
        didSet {
            guard notifyUpdateChanges != oldValue else { return }
            let mode = notifyUpdateChanges ? "live-render" : "drain-only"
            Log.info("RustTerminalView[\(viewId)]: notifyUpdateChanges -> \(mode)")
            if notifyUpdateChanges {
                // Tab became active: resume full-speed CVDisplayLink, stop slow drain
                resumeDisplayLink()
            } else {
                // Tab suspended: pause CVDisplayLink, start slow PTY drain
                pauseDisplayLink()
            }
        }
    }

    /// Slow PTY drain timer for background tabs (prevents shell blocking)
    var backgroundDrainTimer: Timer?

    // MARK: - Properties

    /// The Rust terminal core (owns PTY and state)
    var rustTerminal: RustTerminalFFI?

    /// Native renderer for Rust grid
    var gridView: RustGridView!

    /// When true, Metal handles display — skip CPU syncGridToRenderer() and cursor blink.
    var isMetalRenderingActive = false {
        didSet { gridView?.metalRenderingActive = isMetalRenderingActive }
    }

    /// Overlay container for tips and inline images (non-interactive)
    var overlayContainer: PassthroughView!

    /// Tip overlay view (power user tip)
    var tipOverlayView: NSView?

    struct InlineImagePlacement {
        let view: InlineImageView
        let image: InlineImage
        var size: NSSize
        let anchorRow: Int
        let anchorCol: Int
    }

    var inlineImages: [InlineImagePlacement] = []
    var lastDisplayOffset = 0

    /// Display link for polling and rendering at vsync rate
    var displayLink: CVDisplayLink?

    /// Timer fallback if CVDisplayLink unavailable
    var pollTimer: Timer?

    /// Adaptive timer interval matching the display's native refresh rate.
    /// Returns 1/120 for ProMotion, 1/60 for standard, etc.
    var displayRefreshInterval: TimeInterval {
        guard let screen = window?.screen ?? NSScreen.main else {
            return 1.0 / 60.0
        }
        if #available(macOS 12.0, *),
           let maxFPS = screen.maximumFramesPerSecond,
           maxFPS > 0 {
            return 1.0 / Double(maxFPS)
        }
        return 1.0 / 60.0 // Safe default for older macOS
    }

    /// Track startup bytes for debugging
    var startupBytesLogged = 0
    var recentMissingCmdClickPaths: [String: Date] = [:]
    let missingCmdClickWarningCooldown: TimeInterval = 5

    /// One-shot timer that fires onShellStartupSlow if no PTY output arrives
    var shellStartupTimeoutWork: DispatchWorkItem?

    /// Terminal dimensions
    var cols = 80
    var rows = 24

    /// Cell dimensions for coordinate calculations
    var cellWidth: CGFloat = 8.0
    var cellHeight: CGFloat = 16.0

    /// Track if we need to sync grid
    var needsGridSync = false

    /// Last grid snapshot for diffing
    var lastGridHash = 0

    // MARK: - Grid Sync Optimization State

    /// Previous grid state for dirty row detection
    var previousGrid: [RustCellData] = []
    var previousGridCols = 0
    var previousGridRows = 0
    var previousCursorCol: UInt16 = 0
    var previousCursorRow: UInt16 = 0

    /// Rate limiting for grid sync (target ~60fps max)
    var lastSyncTime: CFAbsoluteTime = 0
    static let minSyncInterval: CFAbsoluteTime = 1.0 / 120.0 // Allow up to 120fps for responsiveness

    /// Statistics for debugging
    var fullSyncCount: UInt64 = 0
    var partialSyncCount: UInt64 = 0
    var skippedSyncCount: UInt64 = 0

    // MARK: - Buffer Line Cache (Performance fix for scrollback access)

    /// Cached buffer lines to avoid re-parsing the entire terminal buffer on every
    /// getLineText(absoluteRow:) call. Without this cache, getBufferAsData() + split()
    /// ran for EACH row, which is O(visible_rows * total_buffer_size) — causing 90%+
    /// CPU usage and memory growth to 1+ GB with large scrollback buffers.
    var cachedBufferLines: [String]?
    var cachedBufferLinesVersion: UInt64 = 0
    /// Instance-scoped sync counter for cache invalidation.
    /// Unlike the static `syncCount`, this only increments when *this* tab syncs,
    /// preventing cross-tab spurious cache invalidation.
    var instanceSyncCount: UInt64 = 0

    /// Selection state
    var isSelecting = false
    var selectionStart: (col: Int, row: Int)?

    /// Mouse tracking
    var mouseDownLocation: NSPoint?
    var didDragSinceMouseDown = false
    static let dragThreshold: CGFloat = 1.5

    /// Auto-scroll during selection drag
    var autoScrollTimer: Timer?
    var autoScrollDirection = 0 // -1 = up, 0 = none, 1 = down
    var autoScrollDistance: CGFloat = 0 // Distance outside bounds (for speed scaling)

    /// Event monitors
    var mouseDownMonitor: Any?
    var mouseUpMonitor: Any?
    var mouseDragMonitor: Any?
    var mouseMoveMonitor: Any?
    var scrollWheelMonitor: Any?
    var keyDownMonitor: Any?
    var generalKeyMonitor: Any? // Intercepts ALL key events for Rust terminal routing
    /// Signature of the last key event handled by the general key monitor.
    /// Used to prevent duplicate handling in keyDown after monitor interception.
    var lastMonitorHandledKeyEventSignature: String?
    var isEventMonitoringEnabled = false

    /// Path detection work item (for debouncing cursor change on hover)
    var pathDetectionWorkItem: DispatchWorkItem?

    /// Color scheme cache
    var appliedColorSchemeSignature: String?

    /// Bell configuration (enabled, sound type)
    var bellConfig: (enabled: Bool, sound: String)?

    /// Copy-on-select tracking
    var lastSelectionText: String?
    var copyOnSelectWorkItem: DispatchWorkItem?

    // MARK: - Command History Navigation State

    /// Event monitor for history key handling (separate from other monitors)
    var historyMonitor: Any?
    /// Last command recalled from history (to prevent key repeat spam)
    var lastHistoryCommand: String?
    /// Direction of last history navigation (true = up, false = down)
    var lastHistoryWasUp = false

    // MARK: - Snippet Placeholder Navigation State (F21)

    /// Current snippet navigation state, or nil if not in snippet mode
    var snippetState: RustSnippetNavigationState?

    // MARK: - Lifecycle State

    /// Flag to prevent CVDisplayLink callbacks from accessing deallocated view
    var isBeingDeallocated = false
    /// Weak reference box for CVDisplayLink callback safety.
    /// CVDisplayLink callbacks run on a separate thread with an unretained pointer,
    /// which can access freed memory if the view deallocates between the callback
    /// firing and the main-thread async block executing. This box holds a weak
    /// reference so the callback safely becomes a no-op after deallocation.
    var displayLinkBox: DisplayLinkWeakBox?

    // MARK: - Local Echo State (Latency Optimization)

    // Track pending local echo to suppress PTY duplicates
    // This shows typed characters immediately without waiting for PTY round-trip

    /// Characters that have been locally echoed and await PTY confirmation
    var pendingLocalEcho: [UInt8] = []
    /// Offset into `pendingLocalEcho` for robust partial matching.
    /// Matches can only consume from this offset to avoid O(n) queue churn and
    /// corruption when output contains control/escape bytes before echoed text.
    var pendingLocalEchoOffset = 0

    /// Bound used to periodically compact/clear pending local-echo state.
    static let maxPendingLocalEcho = 100

    /// Track pending backspaces to suppress PTY's backspace response
    var pendingLocalBackspaces = 0

    /// Local echo overlay cells keyed by grid index
    var localEchoOverlay: [Int: RustCellData] = [:]
    var localEchoCursor: (row: Int, col: Int)?

    /// Local echo requires a renderer that can apply predicted output.
    /// The native Rust grid renderer provides a lightweight overlay for this.
    let supportsLocalEcho = true

    /// Heuristic-based echo detection: disabled when password prompts or raw mode detected.
    /// The Rust terminal owns the PTY, so we rely on heuristics:
    /// - Password prompt patterns ("password:", "sudo password", etc.) disable echo
    /// - Shell prompt patterns ($ # %) re-enable echo
    /// - Timeout recovery re-enables echo after 5 seconds
    /// This approach handles 95%+ of real-world cases without direct termios access.
    var isPtyEchoLikelyEnabled = true

    /// Returns true when the PTY echo is likely disabled (password prompt detected).
    /// Exposes the heuristic echo state for history filtering.
    var isPtyEchoDisabled: Bool {
        // Primary: Use reliable termios-based detection via Rust FFI (100% accurate)
        if let termiosResult = rustTerminal?.isEchoDisabledViaTermios() {
            return termiosResult
        }
        // Fallback: Heuristic-based detection (older libraries without FFI support)
        return !isPtyEchoLikelyEnabled
    }

    /// Timestamp when echo was last disabled (for timeout recovery)
    var echoDisabledTime: CFAbsoluteTime = 0

    // MARK: - Input State (stored properties for extension files)

    /// Application cursor mode (DECCKM) - when enabled, arrow keys send SS3 sequences instead of CSI
    /// This is typically set by programs like vim, less, tmux via escape sequence ESC[?1h
    var applicationCursorMode = false

    /// True while keyDown is routing through inputContext, so insertText knows
    /// the call originated from a keyboard event (not Password AutoFill).
    var handlingKeyDown = false

    /// IME marked text state — tracks pending dead key / composition text.
    /// Without this, dead keys like ^ on French keyboards get stuck because
    /// NSTextInputContext enters an inconsistent state when setMarkedText is
    /// a no-op and hasMarkedText returns false.
    var markedTextStorage: String?
    var markedSelectedRange = NSRange(location: NSNotFound, length: 0)

    // MARK: - Mouse Reporting State (stored properties for extension files)

    /// Track last reported mouse position
    var lastReportedMouseCell: (col: Int, row: Int)?

    /// Track if button is pressed for mouse reporting
    var mouseReportingButtonDown: MouseButton?

    // MARK: - Scrollback Cache (stored property for extension files)

    /// Cache to avoid redundant FFI calls
    var appliedScrollbackLines: Int?

    // MARK: - Smart Scroll State

    // When smart scroll is enabled and user has scrolled up, new output won't auto-scroll

    /// Whether user is at or near the bottom of the terminal
    var isUserAtBottom = true

    /// Threshold for considering user "at bottom" (0.99 = within 1% of end)
    static let scrollBottomThreshold = 0.99

    /// Timeout after which we re-enable echo detection (5 seconds)
    static let echoDisabledTimeout: CFAbsoluteTime = 5.0

    /// Font
    var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet {
            if !isMetalRenderingActive {
                gridView?.font = font
            }
            updateCellDimensions()
            if isMetalRenderingActive {
                gridView?.layer?.contents = nil
            }
            needsLayout = true
        }
    }

    /// Whether the view currently has keyboard focus
    var hasFocus: Bool {
        return window?.firstResponder === self || window?.firstResponder === gridView
    }

    /// Frame of the cursor caret in view coordinates
    /// Computed from terminal cursor position and cell dimensions.
    /// Note: NSView uses bottom-left origin, but terminals use top-left (row 0 = top).
    /// We flip the Y coordinate so row 0 is at the top of the view.
    var caretFrame: CGRect {
        // Use bounds.height consistently (same as RustGridView.drawCursor)
        let renderHeight = bounds.height
        guard let rust = rustTerminal else {
            return CGRect(x: 0, y: renderHeight - cellHeight, width: cellWidth, height: cellHeight)
        }
        let cursor = rust.cursorPosition
        let x = CGFloat(cursor.col) * cellWidth
        let y = renderHeight - CGFloat(cursor.row + 1) * cellHeight
        return CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
    }

    /// Renderer grid dimensions (visible viewport)
    var renderCols: Int {
        cols
    }

    var renderRows: Int {
        rows
    }

    var renderCellSize: CGSize {
        CGSize(width: cellWidth, height: cellHeight)
    }

    var renderCursorRow: Int {
        Int(rustTerminal?.cursorPosition.row ?? 0)
    }

    /// Top visible row in absolute buffer coordinates.
    /// Top visible row using native Rust data.
    /// When at bottom (displayOffset=0), this equals the history size.
    /// When scrolled up, it equals historySize - displayOffset.
    var renderTopVisibleRow: Int {
        guard let rust = rustTerminal else { return 0 }
        let offset = Int(rust.displayOffset)
        return cachedScrollbackRows - offset
    }

    /// Cached scrollback row count from the last grid snapshot.
    /// Updated every sync cycle in syncGridToRenderer() — lightweight access
    /// without fetching a full grid snapshot just for history size.
    var cachedScrollbackRows = 0

    // MARK: - Static Check

    /// Returns true if the Rust terminal library is available
    static var isAvailable: Bool {
        Log.trace("RustTerminalView: Checking isAvailable")
        let available = RustTerminalFFI.isAvailable
        Log.trace("RustTerminalView: isAvailable = \(available)")
        return available
    }

    // MARK: - Initialization

    static var viewCounter: UInt64 = 0
    let viewId: UInt64

    /// Shell path to use when creating the terminal (set before first layout)
    var configuredShell: String?

    /// Environment variables to pass to the shell (set before first layout)
    var configuredEnvironment: [String: String]?

    /// Whether the Rust terminal has been started
    var isTerminalStarted = false

    /// Ensures process termination callback is emitted only once per terminal lifecycle.
    var didEmitProcessTermination = false

    /// Last logged title (for rate-limiting OSC title change logs)
    var lastLoggedTitle = ""

    override init(frame frameRect: NSRect) {
        Self.viewCounter += 1
        self.viewId = Self.viewCounter
        super.init(frame: frameRect)
        Log.info("RustTerminalView[\(viewId)]: init(frame:) - frame=\(frameRect)")
        setupViews()
    }

    required init?(coder: NSCoder) {
        Self.viewCounter += 1
        self.viewId = Self.viewCounter
        super.init(coder: coder)
        Log.info("RustTerminalView[\(viewId)]: init(coder:)")
        setupViews()
    }

    /// Configure shell before terminal starts. Must be called before first layout.
    func configureShell(_ shell: String) {
        guard !isTerminalStarted else {
            Log.warn("RustTerminalView[\(viewId)]: configureShell called after terminal started, ignoring")
            return
        }
        configuredShell = shell
        Log.info("RustTerminalView[\(viewId)]: Shell configured: \(shell)")
    }

    /// Configure environment variables before terminal starts. Must be called before first layout.
    func configureEnvironment(_ environment: [String: String]) {
        guard !isTerminalStarted else {
            Log.warn("RustTerminalView[\(viewId)]: configureEnvironment called after terminal started, ignoring")
            return
        }
        configuredEnvironment = environment
        Log.info("RustTerminalView[\(viewId)]: Environment configured with \(environment.count) variables")
    }

    /// Set up rendering views (deferred terminal creation)
    func setupViews() {
        Log.info("RustTerminalView[\(viewId)]: setupViews - Setting up rendering views")

        // Calculate initial dimensions
        cols = max(1, Int(bounds.width / cellWidth))
        rows = max(1, Int(bounds.height / cellHeight))
        Log.trace("RustTerminalView[\(viewId)]: setupViews - Initial dimensions: \(cols)x\(rows) (bounds: \(bounds))")

        // Create native grid renderer for Rust terminal output
        Log.trace("RustTerminalView[\(viewId)]: setupViews - Creating RustGridView for rendering")
        gridView = RustGridView(frame: bounds)
        gridView.autoresizingMask = [.width, .height]
        gridView.font = font
        gridView.cellSize = CGSize(width: cellWidth, height: cellHeight)
        addSubview(gridView)
        Log.trace("RustTerminalView[\(viewId)]: setupViews - RustGridView added as subview")

        overlayContainer = PassthroughView(frame: bounds)
        overlayContainer.autoresizingMask = [.width, .height]
        addSubview(overlayContainer)
        Log.trace("RustTerminalView[\(viewId)]: setupViews - Overlay container added")

        // 3. Update cell dimensions based on font
        updateCellDimensions()

        registerDragTypes()
        Log.info("RustTerminalView[\(viewId)]: setupViews - Views setup complete (terminal not yet started)")
    }

    /// Start the Rust terminal with the configured shell. Called after first layout.
    func startTerminal(initialOutput: String? = nil) {
        guard !isTerminalStarted else {
            Log.trace("RustTerminalView[\(viewId)]: startTerminal - Already started")
            return
        }
        isTerminalStarted = true
        didEmitProcessTermination = false

        // Recalculate dimensions with actual bounds
        cols = max(1, Int(bounds.width / cellWidth))
        rows = max(1, Int(bounds.height / cellHeight))
        Log.info("RustTerminalView[\(viewId)]: startTerminal - Starting with \(cols)x\(rows), shell=\(configuredShell ?? "<default>")")

        // Create Rust terminal (owns PTY and state)
        // Use environment-aware init if environment was configured, otherwise use basic init
        if let env = configuredEnvironment {
            Log.info("RustTerminalView[\(viewId)]: startTerminal - Creating with \(env.count) environment variables")
            rustTerminal = RustTerminalFFI(cols: UInt16(cols), rows: UInt16(rows), shell: configuredShell, environment: env)
        } else {
            rustTerminal = RustTerminalFFI(cols: UInt16(cols), rows: UInt16(rows), shell: configuredShell)
        }

        if rustTerminal == nil {
            Log.warn("RustTerminalView[\(viewId)]: startTerminal - Failed to create Rust terminal")
        } else {
            Log.info("RustTerminalView[\(viewId)]: startTerminal - Rust terminal created successfully")

            // Phase 4: Configure image protocol interceptor based on user settings.
            // iTerm2 is enabled by default (matches FeatureSettings.isInlineImagesEnabled).
            // Sixel/Kitty are gated by SixelKittyBridge toggles.
            let iterm2Enabled = FeatureSettings.shared.isInlineImagesEnabled
            let sixelEnabled = SixelKittyBridge.shared.isSixelEnabled
            let kittyEnabled = SixelKittyBridge.shared.isKittyGraphicsEnabled
            rustTerminal?.setImageProtocols(sixel: sixelEnabled, kitty: kittyEnabled, iterm2: iterm2Enabled)
            Log.info("RustTerminalView[\(viewId)]: Image protocols configured - iTerm2=\(iterm2Enabled), Sixel=\(sixelEnabled), Kitty=\(kittyEnabled)")
        }

        if let initialOutput, !initialOutput.isEmpty {
            injectOutput(initialOutput)
        }

        // Force an initial grid sync on the next poll cycle.
        // Without this, the first pollAndSync() finds poll()==false (no PTY data yet)
        // and needsGridSync==false, so syncGridToRenderer() never runs and the screen
        // stays blank until a resize or PTY data arrives.
        needsGridSync = true

        // Start polling loop now that terminal exists
        setupPollingLoop()

        // Schedule a one-shot timeout: if no PTY output arrives within 5 seconds,
        // notify the UI so it can show a "shell initializing" indicator.
        let work = DispatchWorkItem { [weak self] in
            guard let self, startupBytesLogged == 0 else { return }
            Log.warn("RustTerminalView[\(viewId)]: No PTY output after 5s — shell may be hung")
            onShellStartupSlow?() // Already on main queue
        }
        shellStartupTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)

        Log.info("RustTerminalView[\(viewId)]: startTerminal - Complete")
    }

    deinit {
        Log.info("RustTerminalView[\(viewId)]: deinit - Starting cleanup")
        // Set flag to prevent CVDisplayLink callbacks from accessing deallocated view
        isBeingDeallocated = true
        shellStartupTimeoutWork?.cancel()
        stopPollingLoop()
        stopAutoScrollTimer()
        removeEventMonitors()
        Log.trace("RustTerminalView[\(viewId)]: deinit - Cleanup complete")
    }

    // MARK: - View Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window != nil {
            Log.trace("RustTerminalView[\(viewId)]: viewDidMoveToWindow - Added to window")
            updateCellDimensions()
            if isEventMonitoringEnabled {
                Log.trace("RustTerminalView[\(viewId)]: viewDidMoveToWindow - Setting up event monitors")
                setupEventMonitors()
            }
            // Re-configure Metal atlas with correct backingScaleFactor now that window is available
            if isMetalRenderingActive,
               let container = superview as? RustTerminalContainerView {
                container.rustMetalCoordinator?.fontChanged()
            }
        } else {
            Log.trace("RustTerminalView[\(viewId)]: viewDidMoveToWindow - Removed from window")
            removeEventMonitors()
        }
    }

    override func layout() {
        super.layout()
        // Use bounds directly without toolbar inset calculation.
        // The hosting view is already positioned at contentLayoutRect by OverlayBlurView.
        gridView?.frame = bounds
        overlayContainer?.frame = bounds

        // DEBUG: Log layout dimensions
        if let window = window {
            let contentRect = window.contentLayoutRect
            Log.trace("RustTerminalView[\(viewId)]: layout - bounds=\(bounds) frame=\(frame) contentLayoutRect=\(contentRect) window.frame=\(window.frame)")
        }

        // Update dimensions and resize Rust terminal
        updateCellDimensions()
        let newCols = max(1, Int(bounds.width / cellWidth))
        let newRows = max(1, Int(bounds.height / cellHeight))

        if newCols != cols || newRows != rows {
            Log.trace("RustTerminalView[\(viewId)]: layout - Resizing from \(cols)x\(rows) to \(newCols)x\(newRows)")
            cols = newCols
            rows = newRows
            rustTerminal?.resize(cols: UInt16(cols), rows: UInt16(rows))
            needsGridSync = true
        }

        updateTipOverlayPosition()
        updateInlineImagePositions()
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        Log.trace("RustTerminalView[\(viewId)]: becomeFirstResponder")
        return true
    }

    override func resignFirstResponder() -> Bool {
        Log.trace("RustTerminalView[\(viewId)]: resignFirstResponder")
        // Clear any pending IME composition to prevent dead key state from
        // leaking across tab switches (e.g. ^ on French keyboards).
        if markedTextStorage != nil {
            markedTextStorage = nil
            markedSelectedRange = NSRange(location: NSNotFound, length: 0)
            inputContext?.discardMarkedText()
        }
        return super.resignFirstResponder()
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == .string {
            if let selection = getSelection(), !selection.isEmpty {
                Log.trace("RustTerminalView[\(viewId)]: validRequestor sendType=string → self (has selection)")
                return self
            }
        }
        if returnType == .string {
            Log.trace("RustTerminalView[\(viewId)]: validRequestor returnType=string → self")
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    @objc(writeSelectionToPasteboard:types:)
    func writeSelectionToPasteboard(_ pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard types.contains(.string), let selection = getSelection(), !selection.isEmpty else {
            return false
        }
        pboard.clearContents()
        return pboard.setString(selection, forType: .string)
    }

    @objc(readSelectionFromPasteboard:)
    func readSelectionFromPasteboard(_ pboard: NSPasteboard) -> Bool {
        guard let text = pboard.string(forType: .string), !text.isEmpty else {
            Log.info("RustTerminalView[\(viewId)]: readSelectionFromPasteboard — empty or nil text")
            return false
        }
        Log.info("RustTerminalView[\(viewId)]: readSelectionFromPasteboard — received \(text.count) chars, pasting")
        pasteText(text)
        return true
    }

    // MARK: - NSTextInputClient (Password AutoFill + IME support)

    //
    // macOS Password AutoFill injects credentials via the text input system,
    // calling insertText(_:replacementRange:) on the first responder.
    // Without NSTextInputClient conformance, the credential is silently dropped.

    override var inputContext: NSTextInputContext? {
        // Return a real input context so macOS routes text input here
        if _inputContext == nil {
            _inputContext = NSTextInputContext(client: self)
        }
        return _inputContext
    }

    var _inputContext: NSTextInputContext?

    // MARK: - Cell Dimensions

    func updateCellDimensions() {
        let oldWidth = cellWidth
        let oldHeight = cellHeight
        let cs = TerminalFont.cellSize(for: font)
        cellWidth = cs.width
        cellHeight = cs.height
        if cellWidth != oldWidth || cellHeight != oldHeight {
            Log.trace("RustTerminalView[\(viewId)]: updateCellDimensions - Cell size changed from \(oldWidth)x\(oldHeight) to \(cellWidth)x\(cellHeight)")
        }
        gridView?.cellSize = cs
        rescaleInlineImages()
    }

    /// Convert screen point (in view coordinates) to visible cell coordinates
    /// - Parameter point: Point in view coordinates (standard macOS: origin at bottom-left)
    /// - Returns: (column, row) in visible coordinates (row 0 is top of visible area)
    /// - Note: Use this for mouse reporting to TUI apps (vim, tmux, etc.)
    func pointToCell(_ point: NSPoint) -> (col: Int32, row: Int32) {
        // Standard macOS coordinates: y=0 at bottom
        // High y = top of view = row 0
        let col = Int32(max(0, min(point.x / cellWidth, CGFloat(cols - 1))))
        let row = Int32(max(0, min((bounds.height - point.y) / cellHeight, CGFloat(rows - 1))))
        return (col, row)
    }

    /// Convert screen point to absolute grid coordinates for alacritty_terminal selection
    /// - Parameter point: Point in view coordinates (origin at bottom-left)
    /// - Returns: (column, row) in absolute grid coordinates accounting for display_offset
    /// - Note: Use this for selection operations which need absolute grid coordinates
    ///         When scrolled up by display_offset, visible row 0 corresponds to Line(-display_offset)
    func pointToCellAbsolute(_ point: NSPoint) -> (col: Int32, row: Int32) {
        // First get visible cell coordinates
        let visible = pointToCell(point)
        // Get current display offset (how many lines scrolled up from bottom)
        let displayOffset = rustTerminal?.displayOffset ?? 0
        // Convert to absolute grid coordinates: visible row - display_offset
        // This matches how alacritty_terminal's Selection uses Line coordinates
        let absoluteRow = visible.row - Int32(displayOffset)
        return (visible.col, absoluteRow)
    }

    // MARK: - Public API

    /// Start a shell process (no-op for RustTerminalView - Rust handles PTY)
    func startProcess(executable: String, args: [String], environment: [String]?, execName: String?) {
        // The Rust terminal creates its own PTY. We could extend the FFI to support
        // custom shell paths, but for now the Rust side defaults to $SHELL.
        Log.info("RustTerminalView[\(viewId)]: startProcess - Shell managed by Rust terminal (executable=\(executable), args=\(args))")
    }

    /// Returns the full terminal buffer (screen + scrollback) as UTF-8 Data.
    func getBufferAsData() -> Data? {
        guard let text = rustTerminal?.fullBufferText() else { return nil }
        return text.data(using: .utf8)
    }

    func captureRemoteGridSnapshotPayload() -> Data? {
        guard let rust = rustTerminal,
              let gridResult = rust.getGrid() else {
            return nil
        }
        defer { gridResult.free() }

        let snapshot = gridResult.snapshot.pointee
        let cellCount = Int(snapshot.cols) * Int(snapshot.rows)
        guard cellCount > 0, let cells = snapshot.cells else {
            return nil
        }

        let cellBytes = Data(
            bytes: cells,
            count: cellCount * MemoryLayout<RustCellData>.stride
        )
        let cursor = rust.cursorPosition
        let payload = RemoteTerminalGridSnapshot(
            cols: snapshot.cols,
            rows: snapshot.rows,
            cursorCol: cursor.col,
            cursorRow: cursor.row,
            cursorVisible: snapshot.cursor_visible != 0,
            scrollbackRows: snapshot.scrollback_rows,
            displayOffset: snapshot.display_offset,
            cells: cellBytes
        )
        return payload.encode()
    }

    var terminalRows: Int {
        rows
    }

    var terminalCols: Int {
        cols
    }

    /// Current cursor row in absolute buffer coordinates.
    /// Uses native Rust data: topVisibleRow (history - displayOffset) + cursor.row
    var currentAbsoluteRow: Int {
        guard let rust = rustTerminal else { return 0 }
        let cursor = rust.cursorPosition
        return renderTopVisibleRow + Int(cursor.row)
    }

    /// Get the text of a specific row in absolute buffer coordinates.
    /// Converts to Rust grid coordinates (where negative = scrollback, 0 = top of viewport).
    func getLineText(absoluteRow: Int) -> String {
        guard let rust = rustTerminal else { return "" }
        // Convert absolute row to Rust grid coordinates:
        // gridRow = absoluteRow - historySize
        // (e.g., row 0 → -historySize, row historySize → 0)
        let gridRow = absoluteRow - cachedScrollbackRows
        // Use the grid snapshot-based getLineText for visible rows (0..<rows)
        // For scrollback rows (negative), we need the FFI approach.
        // The FFI getLineText reads from grid snapshot (visible only, 0-indexed).
        // For rows outside the visible viewport, fall back to cached buffer lines.
        if gridRow >= 0, gridRow < rows {
            return rust.getLineText(row: gridRow) ?? ""
        }
        // For scrollback rows, use the cached line index to avoid O(n) re-parsing
        // of the entire buffer for every single row access.
        let lines = getCachedBufferLines()
        guard absoluteRow >= 0, absoluteRow < lines.count else { return "" }
        return lines[absoluteRow]
    }

    func getCachedBufferLines() -> [String] {
        let currentVersion = instanceSyncCount
        if let cached = cachedBufferLines, cachedBufferLinesVersion == currentVersion {
            return cached
        }
        guard let data = getBufferAsData() else {
            cachedBufferLines = []
            cachedBufferLinesVersion = currentVersion
            return []
        }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        cachedBufferLines = lines
        cachedBufferLinesVersion = currentVersion
        return lines
    }

    /// Configure colors
    func applyColorScheme(_ scheme: TerminalColorScheme) {
        let signature = scheme.signature
        guard appliedColorSchemeSignature != signature else {
            Log.trace("RustTerminalView[\(viewId)]: applyColorScheme - Scheme already applied (signature=\(signature))")
            return
        }
        Log.trace("RustTerminalView[\(viewId)]: applyColorScheme - Applying new scheme (signature=\(signature))")
        appliedColorSchemeSignature = signature

        gridView?.backgroundColor = scheme.nsColor(for: scheme.background)
        gridView?.foregroundColor = scheme.nsColor(for: scheme.foreground)
        gridView?.cursorColor = scheme.nsColor(for: scheme.cursor)
        gridView?.selectionColor = scheme.nsColor(for: scheme.selection)

        // Apply colors to Rust terminal for correct grid rendering
        // This fixes issues #6, #8, and #10: color_to_rgb() now uses theme colors
        let fgRGB = rgbComponents(from: scheme.foreground)
        let bgRGB = rgbComponents(from: scheme.background)
        let cursorRGB = rgbComponents(from: scheme.cursor)

        let rustPalette: [(UInt8, UInt8, UInt8)] = [
            rgbComponents(from: scheme.black),
            rgbComponents(from: scheme.red),
            rgbComponents(from: scheme.green),
            rgbComponents(from: scheme.yellow),
            rgbComponents(from: scheme.blue),
            rgbComponents(from: scheme.magenta),
            rgbComponents(from: scheme.cyan),
            rgbComponents(from: scheme.white),
            rgbComponents(from: scheme.brightBlack),
            rgbComponents(from: scheme.brightRed),
            rgbComponents(from: scheme.brightGreen),
            rgbComponents(from: scheme.brightYellow),
            rgbComponents(from: scheme.brightBlue),
            rgbComponents(from: scheme.brightMagenta),
            rgbComponents(from: scheme.brightCyan),
            rgbComponents(from: scheme.brightWhite)
        ]

        rustTerminal?.setColors(fg: fgRGB, bg: bgRGB, cursor: cursorRGB, palette: rustPalette)
        Log.trace("RustTerminalView[\(viewId)]: applyColorScheme - Rust terminal colors set")

        // Trigger a grid sync to apply the new colors
        needsGridSync = true
    }

    /// Convert hex color string to RGB components (0-255)
    func rgbComponents(from hex: String) -> (UInt8, UInt8, UInt8) {
        let nsColor = TerminalColorScheme.default.nsColor(for: hex)
        let rgb = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
        let red = UInt8(rgb.redComponent * 255)
        let green = UInt8(rgb.greenComponent * 255)
        let blue = UInt8(rgb.blueComponent * 255)
        return (red, green, blue)
    }

    /// Configure cursor style
    func applyCursorStyle(style: String, blink: Bool) {
        let rendererShape: RustGridView.CursorStyle.Shape
        switch style {
        case "underline":
            rendererShape = .underline
        case "bar":
            rendererShape = .bar
        default:
            rendererShape = .block
        }
        gridView?.cursorStyle = RustGridView.CursorStyle(shape: rendererShape, blink: blink)
    }

    /// Configure bell
    func applyBellSettings(enabled: Bool, sound: String) {
        bellConfig = (enabled: enabled, sound: sound)
        Log.trace("RustTerminalView[\(viewId)]: applyBellSettings - enabled=\(enabled), sound=\(sound)")
    }

}
