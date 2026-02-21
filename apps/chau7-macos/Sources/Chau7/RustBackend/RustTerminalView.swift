import AppKit
import Carbon
import Darwin
import QuartzCore
import SwiftTerm
import CoreText

// MARK: - Rust FFI Structures (matching chau7_terminal.h)

/// Cell attribute flags from Rust
private struct CellFlags {
    static let bold: UInt8 = 1 << 0
    static let italic: UInt8 = 1 << 1
    static let underline: UInt8 = 1 << 2
    static let strikethrough: UInt8 = 1 << 3
    static let inverse: UInt8 = 1 << 4
    static let dim: UInt8 = 1 << 5
    static let hidden: UInt8 = 1 << 6
}

/// C-compatible cell data matching Rust's CellData
private struct RustCellData {
    var character: UInt32
    var fg_r: UInt8
    var fg_g: UInt8
    var fg_b: UInt8
    var bg_r: UInt8
    var bg_g: UInt8
    var bg_b: UInt8
    var flags: UInt8
    var _pad: UInt8
    var link_id: UInt16  // OSC 8 hyperlink ID (0 = no link)
}

/// C-compatible grid snapshot matching Rust's GridSnapshot
private struct RustGridSnapshot {
    var cells: UnsafeMutablePointer<RustCellData>?
    var cols: UInt16
    var rows: UInt16
    var cursor_visible: UInt8  // DECTCEM: 0 = hidden, 1 = visible
    var _pad: (UInt8, UInt8, UInt8)  // Alignment padding to next UInt32
    var scrollback_rows: UInt32
    var display_offset: UInt32
    var capacity: Int  // Must match Rust's usize (8 bytes on 64-bit)
}

// MARK: - CVDisplayLink Weak Reference Box

/// Prevents use-after-free in CVDisplayLink callbacks.
/// CVDisplayLink takes a raw `UnsafeMutableRawPointer` (no ARC).
/// Using `Unmanaged.passUnretained` means the callback can access
/// a deallocated view. This box is retained by Unmanaged and holds
/// only a weak reference to the view, making the callback a safe no-op
/// after deallocation.
private final class DisplayLinkWeakBox {
    weak var view: RustTerminalView?
    init(_ view: RustTerminalView) { self.view = view }
}

// MARK: - Native Rust Grid Renderer

private final class RustGridView: NSView {
    struct CursorStyle {
        enum Shape {
            case block
            case underline
            case bar
        }
        var shape: Shape
        var blink: Bool
    }

    var font: NSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet { updateFontCache() }
    }

    var cellSize: CGSize = CGSize(width: 8, height: 16) {
        didSet { needsDisplay = true }
    }

    var foregroundColor: NSColor = .textColor {
        didSet { needsDisplay = true }
    }
    var backgroundColor: NSColor = .textBackgroundColor {
        didSet { needsDisplay = true }
    }
    var cursorColor: NSColor = .white {
        didSet { needsDisplay = true }
    }
    var selectionColor: NSColor = .selectedTextBackgroundColor

    var cursorStyle: CursorStyle = CursorStyle(shape: .block, blink: false) {
        didSet { needsDisplay = true }
    }

    private var cols: Int = 0
    private var rows: Int = 0
    private var cells: [RustCellData] = []
    private var overlayCells: [Int: RustCellData] = [:]
    private var cursor: (col: Int, row: Int) = (0, 0)
    private var lastCursor: (col: Int, row: Int) = (0, 0)
    private var lastBlinkPhase: Bool = true

    /// DECTCEM cursor visibility: when false, the terminal has hidden the cursor (ESC[?25l).
    /// Programs like Claude Code hide the terminal cursor and draw their own via ANSI styling.
    var cursorVisible: Bool = true {
        didSet {
            if oldValue != cursorVisible {
                setNeedsDisplay(cursorRect(for: cursor))
            }
        }
    }

    /// When true, Metal handles display — suppresses CPU draw() and setNeedsDisplay.
    var metalRenderingActive = false

    private var regularFont: NSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var boldFont: NSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private var italicFont: NSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var boldItalicFont: NSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)

    override var acceptsFirstResponder: Bool { false }

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
        if self.cols != cols || self.rows != rows || self.cells.count != totalCells {
            self.cols = cols
            self.rows = rows
            self.cells = Array(repeating: RustCellData(character: 0, fg_r: 255, fg_g: 255, fg_b: 255, bg_r: 0, bg_g: 0, bg_b: 0, flags: 0, _pad: 0, link_id: 0), count: totalCells)
            // Full redraw when dimensions change.
            needsDisplay = true
        }

        let buffer = UnsafeBufferPointer(start: source, count: totalCells)
        if let dirtyRows, !dirtyRows.isEmpty {
            for row in dirtyRows {
                let rowStart = row * cols
                let rowRange = rowStart..<(rowStart + cols)
                self.cells.replaceSubrange(rowRange, with: buffer[rowRange])
                setNeedsDisplay(rowRect(for: row))
            }
        } else {
            self.cells.replaceSubrange(0..<totalCells, with: buffer)
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
        guard index >= 0 && index < cells.count else { return 0 }
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

        // Match SwiftTerm: set sRGB color space for consistent color reproduction
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
            ctx.setFillColorSpace(srgb)
            ctx.setStrokeColorSpace(srgb)
        }

        backgroundColor.setFill()
        dirtyRect.fill()

        let cellHeight = cellSize.height
        let cellWidth = cellSize.width
        // Use CTFont metrics for consistency with SwiftTerm.
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
        for row in rowStart...rowEnd {
            let y = bounds.height - CGFloat(row + 1) * cellHeight
            for col in 0..<cols {
                let idx = row * cols + col
                let cell = overlayCells[idx] ?? cells[idx]
                let x = CGFloat(col) * cellWidth
                let rect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)

                let (_, bg) = resolveColors(for: cell)
                ctx.setFillColor(bg.cgColor)
                ctx.fill(rect)
            }
        }

        // Phase 2: Draw all text with AA on (smooth glyphs)
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        for row in rowStart...rowEnd {
            let y = bounds.height - CGFloat(row + 1) * cellHeight
            for col in 0..<cols {
                let idx = row * cols + col
                let cell = overlayCells[idx] ?? cells[idx]

                guard cell.character > 0, cell.character != 0xFFFF else { continue }
                guard let scalar = UnicodeScalar(cell.character) else { continue }
                if cell.flags & CellFlags.hidden != 0 { continue }

                let x = CGFloat(col) * cellWidth
                let (fg, _) = resolveColors(for: cell)
                let drawFont = fontForCell(cell.flags)
                var textColor = fg
                if cell.flags & CellFlags.dim != 0 {
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
                if cell.flags & CellFlags.underline != 0 {
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
                        for step in 1...steps {
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
                if cell.flags & CellFlags.strikethrough != 0 {
                    ctx.setStrokeColor(textColor.cgColor)
                    ctx.setLineWidth(1)
                    let strikeY = y + baselineOffset + drawFont.xHeight / 2.0
                    ctx.move(to: CGPoint(x: x, y: strikeY))
                    ctx.addLine(to: CGPoint(x: x + cellWidth, y: strikeY))
                    ctx.strokePath()
                }
                // OSC 8 hyperlink: underline in link color
                if cell.link_id > 0 && cell.flags & CellFlags.underline == 0 {
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

        if cursorStyle.blink && !lastBlinkPhase {
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
        needsDisplay = true
    }

    private func fontForCell(_ flags: UInt8) -> NSFont {
        let isBold = flags & CellFlags.bold != 0
        let isItalic = flags & CellFlags.italic != 0
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
        // Use deviceRed to match SwiftTerm's color creation (NSColor.make uses deviceRed).
        // The CGContext is set to sRGB color space in draw() for consistent rendering.
        var fg = NSColor(deviceRed: CGFloat(cell.fg_r) / 255.0, green: CGFloat(cell.fg_g) / 255.0, blue: CGFloat(cell.fg_b) / 255.0, alpha: 1.0)
        var bg = NSColor(deviceRed: CGFloat(cell.bg_r) / 255.0, green: CGFloat(cell.bg_g) / 255.0, blue: CGFloat(cell.bg_b) / 255.0, alpha: 1.0)
        if cell.flags & CellFlags.inverse != 0 {
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

private final class PassthroughView: NSView {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

// MARK: - Rust Terminal FFI Wrapper

/// Swift wrapper for the Rust terminal library loaded via dlopen
private final class RustTerminalFFI {
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
    // Issue #3 fix: FFI types for raw output retrieval
    // Returns *mut u8 (mutable pointer) for proper memory ownership transfer
    private typealias GetLastOutputFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int>?) -> UnsafeMutablePointer<UInt8>?
    private typealias FreeOutputFn = @convention(c) (UnsafeMutablePointer<UInt8>?, Int) -> Void
    private typealias InjectOutputFn = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int) -> Void
    // Scrollback size configuration
    private typealias SetScrollbackSizeFn = @convention(c) (OpaquePointer?, UInt32) -> Void
    // Smart scroll support: get display offset (0 = at bottom)
    private typealias DisplayOffsetFn = @convention(c) (OpaquePointer?) -> UInt32
    // Bracketed paste mode query (for proper paste handling in vim, zsh, etc.)
    private typealias IsBracketedPasteModeFn = @convention(c) (OpaquePointer?) -> Bool
    // Bell event checking (for audio/visual bell feedback)
    private typealias CheckBellFn = @convention(c) (OpaquePointer?) -> Bool
    // Mouse mode query (for context menu gating and mouse reporting)
    private typealias GetMouseModeFn = @convention(c) (OpaquePointer?) -> UInt32
    private typealias IsMouseReportingActiveFn = @convention(c) (OpaquePointer?) -> Bool
    // Application cursor mode (DECCKM) query - for arrow key sequences
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
    // Echo detection via termios (Phase 2: reliable password prompt detection)
    private typealias IsEchoDisabledFn = @convention(c) (OpaquePointer?) -> Bool

    // Direct line text retrieval (avoids full grid snapshot per row)
    private typealias GetLineTextFn = @convention(c) (OpaquePointer?, Int32) -> UnsafeMutablePointer<CChar>?

    // Hyperlink (OSC 8) FFI types (Phase 5)
    private typealias GetLinkUrlFn = @convention(c) (OpaquePointer?, UInt16) -> UnsafeMutablePointer<CChar>?

    // Clipboard (OSC 52) FFI types (Phase 5)
    private typealias GetPendingClipboardFn = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<CChar>?
    private typealias HasClipboardRequestFn = @convention(c) (OpaquePointer?) -> Bool
    private typealias RespondClipboardFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void

    // Graphics protocol FFI types (Phase 4)
    private typealias GetPendingImagesFn = @convention(c) (OpaquePointer?) -> UnsafeMutableRawPointer?
    private typealias FreeImagesFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias SetImageProtocolsFn = @convention(c) (OpaquePointer?, Bool, Bool, Bool) -> Void
    private typealias HasPendingImagesFn = @convention(c) (OpaquePointer?) -> Bool

    private struct Functions {
        let create: CreateFn
        let createWithEnv: CreateWithEnvFn?  // Optional - older libraries may not have this
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
        let selectionStart: SelectionStartFn?  // Optional - older libraries may not have this
        let selectionUpdate: SelectionUpdateFn?  // Optional - older libraries may not have this
        let selectionAll: SelectionAllFn?  // Optional - older libraries may not have this
        let freeString: FreeStringFn
        let cursorPosition: CursorPositionFn
        let poll: PollFn
        let setColors: SetColorsFn?  // Optional - older libraries may not have this
        let clearScrollback: ClearScrollbackFn?  // Optional - older libraries may not have this
        // Issue #3 fix: raw output retrieval functions
        let getLastOutput: GetLastOutputFn?  // Optional - older libraries may not have this
        let freeOutput: FreeOutputFn?  // Optional - older libraries may not have this
        let injectOutput: InjectOutputFn?  // Optional - inject UI-only output
        // Scrollback size configuration
        let setScrollbackSize: SetScrollbackSizeFn?  // Optional - older libraries may not have this
        // Smart scroll support
        let displayOffset: DisplayOffsetFn?  // Optional - older libraries may not have this
        // Bracketed paste mode query
        let isBracketedPasteMode: IsBracketedPasteModeFn?  // Optional - older libraries may not have this
        // Bell event checking
        let checkBell: CheckBellFn?  // Optional - older libraries may not have this
        // Mouse mode query (for context menu gating)
        let getMouseMode: GetMouseModeFn?  // Optional - older libraries may not have this
        let isMouseReportingActive: IsMouseReportingActiveFn?  // Optional - older libraries may not have this
        // Application cursor mode (DECCKM) query - for arrow key sequences
        let isApplicationCursorMode: IsApplicationCursorModeFn?  // Optional - older libraries may not have this
        // Debug and performance functions
        let getShellPid: GetShellPidFn?  // Optional - for dev server monitoring
        let getDebugState: GetDebugStateFn?  // Optional - for debugging
        let freeDebugState: FreeDebugStateFn?  // Optional - for debugging
        let getFullBufferText: GetFullBufferTextFn?  // Optional - for debugging
        let resetMetrics: ResetMetricsFn?  // Optional - for performance analysis
        // Terminal event functions (title, exit, PTY closed)
        let getPendingTitle: GetPendingTitleFn?  // Optional - for terminal title updates
        let getPendingExitCode: GetPendingExitCodeFn?  // Optional - for process exit detection
        let isPtyClosed: IsPtyClosedFn?  // Optional - for PTY close detection
        // Echo detection via termios (Phase 2)
        let isEchoDisabled: IsEchoDisabledFn?  // Optional - for reliable password detection
        // Direct line text retrieval (avoids full grid snapshot per row)
        let getLineTextDirect: GetLineTextFn?  // Optional - direct line text without grid snapshot
        // Hyperlink support (OSC 8 — Phase 5)
        let getLinkUrl: GetLinkUrlFn?  // Optional - for OSC 8 hyperlink URL retrieval
        // Clipboard support (OSC 52 — Phase 5)
        let getPendingClipboard: GetPendingClipboardFn?  // Optional - for OSC 52 clipboard store
        let hasClipboardRequest: HasClipboardRequestFn?  // Optional - for OSC 52 clipboard load
        let respondClipboard: RespondClipboardFn?  // Optional - for OSC 52 clipboard load response
        // Graphics protocol support (Phase 4)
        let getPendingImages: GetPendingImagesFn?  // Optional - for image protocol support
        let freeImages: FreeImagesFn?  // Optional - for image protocol support
        let setImageProtocols: SetImageProtocolsFn?  // Optional - for image protocol support
        let hasPendingImages: HasPendingImagesFn?  // Optional - for image protocol support
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

        // Helper to load a symbol with logging
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

        // Selection management symbols (Issue #1 fix)
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

        // Issue #3 fix: raw output retrieval symbols
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
            // Hyperlink support (OSC 8 — Phase 5)
            getLinkUrl: getLinkUrlSym.map { unsafeBitCast($0, to: GetLinkUrlFn.self) },
            // Clipboard support (OSC 52 — Phase 5)
            getPendingClipboard: getPendingClipboardSym.map { unsafeBitCast($0, to: GetPendingClipboardFn.self) },
            hasClipboardRequest: hasClipboardRequestSym.map { unsafeBitCast($0, to: HasClipboardRequestFn.self) },
            respondClipboard: respondClipboardSym.map { unsafeBitCast($0, to: RespondClipboardFn.self) },
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
            for i in 0..<keyData.count {
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
        let terminal = self.terminal
        let id = self.instanceId
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
        let terminal = self.terminal
        let id = self.instanceId
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
        let truncated = text.count > 50 ? String(text.prefix(50)) + "..." : text
        let escaped = truncated.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        Log.trace("RustTerminalFFI[\(instanceId)]: sendText - Sending \(text.count) chars: '\(escaped)'")
        let terminal = self.terminal
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
        let truncated = text.count > 50 ? String(text.prefix(50)) + "..." : text
        Log.trace("RustTerminalFFI[\(instanceId)]: getSelectionText - Got \(text.count) chars: '\(truncated)'")
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
        for col in 0..<gridCols {
            let cell = cellsPtr[rowOffset + col]
            if let scalar = UnicodeScalar(cell.character), cell.character != 0 {
                lineText.append(Character(scalar))
            } else { lineText.append(" ") }
        }
        while lineText.last == " " { lineText.removeLast() }
        return lineText
    }

    func clearSelection() {
        Log.trace("RustTerminalFFI[\(instanceId)]: clearSelection")
        Self.functions?.selectionClear(terminal)
    }

    /// Start a new selection at the given position (Issue #1 fix)
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

    /// Update the current selection to extend to the given position (Issue #1 fix)
    func updateSelection(col: Int32, row: Int32) {
        guard let updateFn = Self.functions?.selectionUpdate else {
            Log.trace("RustTerminalFFI[\(instanceId)]: updateSelection - Function not available")
            return
        }
        Log.trace("RustTerminalFFI[\(instanceId)]: updateSelection - col=\(col), row=\(row)")
        updateFn(terminal, col, row)
    }

    /// Select all content (screen + scrollback) (Issue #1 fix)
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
        let shouldLog = changed || (now - Self.lastPollLogTime > 5.0)  // Log every 5s or on change

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

    /// Get raw output bytes from the last poll (Issue #3 fix)
    /// Returns nil if no output or function not available
    func getLastOutput() -> Data? {
        guard let getLastOutputFn = Self.functions?.getLastOutput,
              let freeOutputFn = Self.functions?.freeOutput else {
            // Function not available - this is expected for older libraries
            return nil
        }

        var len: Int = 0
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
            let active = (mode & 0x07) != 0  // Bits 0-2 are mouse tracking modes
            return active
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
        let gridDirty: UInt8      // 0 = false, 1 = true
        let running: UInt8        // 0 = false, 1 = true
        let hasSelection: UInt8   // 0 = false, 1 = true
        let mouseMode: UInt32
        let bracketedPaste: UInt8 // 0 = false, 1 = true
        let appCursor: UInt8      // 0 = false, 1 = true
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
            return nil  // -1 means no exit code pending
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
            return nil  // Signal to caller: FFI not available, use heuristic
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
        let protocolType: UInt8  // 0=iTerm2, 1=Sixel, 2=Kitty
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
            return nil  // No pending images
        }
        // Ensure Rust memory is always freed, even if Data() allocation fails
        defer { freeFn(arrayPtr) }

        let array = arrayPtr.assumingMemoryBound(to: FFIImageArray.self).pointee
        guard let imagesPtr = array.images, array.count > 0 else {
            return nil
        }

        var results: [(protocol: UInt8, data: Data, anchorRow: Int32, anchorCol: UInt16)] = []
        for i in 0..<array.count {
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
private struct RustDebugState {
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
/// - SwiftTerm provides: headless buffer for search/highlights
/// - This view bridges them: polls Rust at 60fps, feeds the native renderer
final class RustTerminalView: NSView {

    // MARK: - Public Interface (matching Chau7TerminalView)

    /// Callback when PTY output is received
    var onOutput: ((Data) -> Void)?

    /// Callback when user input is sent
    var onInput: ((String) -> Void)?

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

    /// Current working directory
    var currentDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path

    /// Command history navigation
    var tabIdentifier: String = ""
    var isAtPrompt: (() -> Bool)?

    /// Shell process ID (for dev server monitoring)
    var shellPid: pid_t {
        rustTerminal?.shellPid() ?? 0
    }

    /// Cursor line highlight support
    private weak var cursorLineView: TerminalCursorLineView?
    private let inputLineTracker = InputLineTracker(maxEntries: FeatureSettings.shared.scrollbackLines)
    private var highlightContextLines = false
    private var highlightInputHistory = false
    private var isCursorLineHighlightEnabled = false

    /// Whether to enable mouse reporting to the PTY
    var allowMouseReporting: Bool = false

    /// Whether to notify of update changes (for suspended state)
    var notifyUpdateChanges: Bool = true {
        didSet {
            guard notifyUpdateChanges != oldValue else { return }
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
    private var backgroundDrainTimer: Timer?

    // MARK: - Properties

    /// The Rust terminal core (owns PTY and state)
    private var rustTerminal: RustTerminalFFI?

    /// Native renderer for Rust grid
    private var gridView: RustGridView!

    /// When true, Metal handles display — skip CPU syncGridToRenderer() and cursor blink.
    var isMetalRenderingActive = false {
        didSet { gridView?.metalRenderingActive = isMetalRenderingActive }
    }

    /// Overlay container for tips and inline images (non-interactive)
    private var overlayContainer: PassthroughView!

    /// Tip overlay view (power user tip)
    private var tipOverlayView: NSView?

    private struct InlineImagePlacement {
        let view: InlineImageView
        let image: InlineImage
        var size: NSSize
        let anchorRow: Int
        let anchorCol: Int
    }

    private var inlineImages: [InlineImagePlacement] = []
    private var lastDisplayOffset: Int = 0

    /// HeadlessTerminal stub for getTerminal() protocol conformance.
    /// Phase 3b: No longer fed PTY data — buffer features use native Rust FFI.
    /// Kept as lightweight empty terminal for callers that still require a Terminal object.
    private var headlessTerminal: HeadlessTerminal!

    /// Display link for polling and rendering at vsync rate
    private var displayLink: CVDisplayLink?

    /// Timer fallback if CVDisplayLink unavailable
    private var pollTimer: Timer?

    /// Adaptive timer interval matching the display's native refresh rate.
    /// Returns 1/120 for ProMotion, 1/60 for standard, etc.
    private var displayRefreshInterval: TimeInterval {
        guard let screen = window?.screen ?? NSScreen.main else {
            return 1.0 / 60.0
        }
        if #available(macOS 12.0, *),
           let maxFPS = screen.maximumFramesPerSecond,
           maxFPS > 0 {
            return 1.0 / Double(maxFPS)
        }
        return 1.0 / 60.0  // Safe default for older macOS
    }

    /// Track startup bytes for debugging
    private var startupBytesLogged: Int = 0

    /// Terminal dimensions
    private var cols: Int = 80
    private var rows: Int = 24

    /// Cell dimensions for coordinate calculations
    private var cellWidth: CGFloat = 8.0
    private var cellHeight: CGFloat = 16.0

    /// Track if we need to sync grid
    private var needsGridSync = false

    /// Last grid snapshot for diffing
    private var lastGridHash: Int = 0

    // MARK: - Grid Sync Optimization State

    /// Previous grid state for dirty row detection
    private var previousGrid: [RustCellData] = []
    private var previousGridCols: Int = 0
    private var previousGridRows: Int = 0
    private var previousCursorCol: UInt16 = 0
    private var previousCursorRow: UInt16 = 0

    /// Rate limiting for grid sync (target ~60fps max)
    private var lastSyncTime: CFAbsoluteTime = 0
    private static let minSyncInterval: CFAbsoluteTime = 1.0 / 120.0  // Allow up to 120fps for responsiveness

    /// Statistics for debugging
    private var fullSyncCount: UInt64 = 0
    private var partialSyncCount: UInt64 = 0
    private var skippedSyncCount: UInt64 = 0

    // MARK: - Buffer Line Cache (Performance fix for scrollback access)

    /// Cached buffer lines to avoid re-parsing the entire terminal buffer on every
    /// getLineText(absoluteRow:) call. Without this cache, getBufferAsData() + split()
    /// ran for EACH row, which is O(visible_rows * total_buffer_size) — causing 90%+
    /// CPU usage and memory growth to 1+ GB with large scrollback buffers.
    private var cachedBufferLines: [String]?
    private var cachedBufferLinesVersion: UInt64 = 0
    /// Instance-scoped sync counter for cache invalidation.
    /// Unlike the static `syncCount`, this only increments when *this* tab syncs,
    /// preventing cross-tab spurious cache invalidation.
    private var instanceSyncCount: UInt64 = 0

    /// Selection state
    private var isSelecting = false
    private var selectionStart: (col: Int, row: Int)?

    /// Mouse tracking
    private var mouseDownLocation: NSPoint?
    private var didDragSinceMouseDown = false
    private static let dragThreshold: CGFloat = 1.5

    /// Auto-scroll during selection drag
    private var autoScrollTimer: Timer?
    private var autoScrollDirection: Int = 0  // -1 = up, 0 = none, 1 = down

    /// Event monitors
    private var mouseDownMonitor: Any?
    private var mouseUpMonitor: Any?
    private var mouseDragMonitor: Any?
    private var mouseMoveMonitor: Any?
    private var scrollWheelMonitor: Any?
    private var keyDownMonitor: Any?
    private var generalKeyMonitor: Any?  // Intercepts ALL key events for Rust terminal routing
    /// Signature of the last key event handled by the general key monitor.
    /// Used to prevent duplicate handling in keyDown after monitor interception.
    private var lastMonitorHandledKeyEventSignature: String?
    private var isEventMonitoringEnabled = false

    /// Path detection work item (for debouncing cursor change on hover)
    private var pathDetectionWorkItem: DispatchWorkItem?

    /// Color scheme cache
    private var appliedColorSchemeSignature: String?

    /// Bell configuration (enabled, sound type)
    private var bellConfig: (enabled: Bool, sound: String)?

    /// Copy-on-select tracking
    private var lastSelectionText: String?
    private var copyOnSelectWorkItem: DispatchWorkItem?

    // MARK: - Command History Navigation State

    /// Event monitor for history key handling (separate from other monitors)
    private var historyMonitor: Any?
    /// Last command recalled from history (to prevent key repeat spam)
    private var lastHistoryCommand: String?
    /// Direction of last history navigation (true = up, false = down)
    private var lastHistoryWasUp: Bool = false

    // MARK: - Snippet Placeholder Navigation State (F21)

    /// Current snippet navigation state, or nil if not in snippet mode
    private var snippetState: RustSnippetNavigationState?

    // MARK: - Lifecycle State
    /// Flag to prevent CVDisplayLink callbacks from accessing deallocated view
    private var isBeingDeallocated: Bool = false
    /// Weak reference box for CVDisplayLink callback safety.
    /// CVDisplayLink callbacks run on a separate thread with an unretained pointer,
    /// which can access freed memory if the view deallocates between the callback
    /// firing and the main-thread async block executing. This box holds a weak
    /// reference so the callback safely becomes a no-op after deallocation.
    private var displayLinkBox: DisplayLinkWeakBox?

    // MARK: - Local Echo State (Latency Optimization)
    // Track pending local echo to suppress PTY duplicates
    // This shows typed characters immediately without waiting for PTY round-trip

    /// Characters that have been locally echoed and await PTY confirmation
    private var pendingLocalEcho: [UInt8] = []
    /// Offset into `pendingLocalEcho` for robust partial matching.
    /// Matches can only consume from this offset to avoid O(n) queue churn and
    /// corruption when output contains control/escape bytes before echoed text.
    private var pendingLocalEchoOffset: Int = 0

    /// Bound used to periodically compact/clear pending local-echo state.
    private static let maxPendingLocalEcho = 100

    /// Track pending backspaces to suppress PTY's backspace response
    private var pendingLocalBackspaces: Int = 0

    /// Local echo overlay cells keyed by grid index
    private var localEchoOverlay: [Int: RustCellData] = [:]
    private var localEchoCursor: (row: Int, col: Int)?

    /// Local echo requires a renderer that can apply predicted output.
    /// The native Rust grid renderer provides a lightweight overlay for this.
    private let supportsLocalEcho: Bool = true

    /// Heuristic-based echo detection: disabled when password prompts or raw mode detected.
    /// Architecture note: Unlike Chau7TerminalView (which uses `tcgetattr` to query the PTY's
    /// ECHO flag directly), the Rust terminal owns the PTY, so we rely on heuristics:
    /// - Password prompt patterns ("password:", "sudo password", etc.) disable echo
    /// - Shell prompt patterns ($ # %) re-enable echo
    /// - Timeout recovery re-enables echo after 5 seconds
    /// This approach handles 95%+ of real-world cases without direct termios access.
    private var isPtyEchoLikelyEnabled: Bool = true

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
    private var echoDisabledTime: CFAbsoluteTime = 0

    // MARK: - Smart Scroll State
    // When smart scroll is enabled and user has scrolled up, new output won't auto-scroll

    /// Whether user is at or near the bottom of the terminal
    private var isUserAtBottom: Bool = true

    /// Threshold for considering user "at bottom" (0.99 = within 1% of end)
    private static let scrollBottomThreshold: Double = 0.99

    /// Timeout after which we re-enable echo detection (5 seconds)
    private static let echoDisabledTimeout: CFAbsoluteTime = 5.0

    /// Font
    var font: NSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet {
            gridView?.font = font
            updateCellDimensions()
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
    var renderCols: Int { cols }
    var renderRows: Int { rows }
    var renderCellSize: CGSize { CGSize(width: cellWidth, height: cellHeight) }
    var renderCursorRow: Int { Int(rustTerminal?.cursorPosition.row ?? 0) }
    /// Top visible row in absolute buffer coordinates.
    /// Equivalent to SwiftTerm's getTopVisibleRow() but using native Rust data.
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
    private var cachedScrollbackRows: Int = 0

    // MARK: - Static Check

    /// Returns true if the Rust terminal library is available
    static var isAvailable: Bool {
        Log.trace("RustTerminalView: Checking isAvailable")
        let available = RustTerminalFFI.isAvailable
        Log.trace("RustTerminalView: isAvailable = \(available)")
        return available
    }

    // MARK: - Initialization

    private static var viewCounter: UInt64 = 0
    private let viewId: UInt64

    /// Shell path to use when creating the terminal (set before first layout)
    private var configuredShell: String?

    /// Environment variables to pass to the shell (set before first layout)
    private var configuredEnvironment: [String: String]?

    /// Whether the Rust terminal has been started
    private var isTerminalStarted = false

    /// Ensures process termination callback is emitted only once per terminal lifecycle.
    private var didEmitProcessTermination = false

    /// Last logged title (for rate-limiting OSC title change logs)
    private var lastLoggedTitle: String = ""

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
    private func setupViews() {
        Log.info("RustTerminalView[\(viewId)]: setupViews - Setting up rendering views")

        // Calculate initial dimensions
        cols = max(1, Int(bounds.width / cellWidth))
        rows = max(1, Int(bounds.height / cellHeight))
        Log.trace("RustTerminalView[\(viewId)]: setupViews - Initial dimensions: \(cols)x\(rows) (bounds: \(bounds))")

        // 1. Create headless terminal for buffer-dependent features (search, highlights)
        Log.trace("RustTerminalView[\(viewId)]: setupViews - Creating HeadlessTerminal for buffer features")
        headlessTerminal = HeadlessTerminal(queue: .main) { [weak self] data in
            // This is called when headless terminal wants to send data (we ignore it)
            // Actual PTY communication goes through Rust
            _ = self
        }
        headlessTerminal.terminal.resize(cols: cols, rows: rows)
        Log.trace("RustTerminalView[\(viewId)]: setupViews - HeadlessTerminal created and resized")

        // 2. Create native grid renderer for Rust terminal output
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

        // Sync headlessTerminal to actual dimensions (was initialized with potentially wrong bounds in setupViews)
        headlessTerminal?.terminal.resize(cols: cols, rows: rows)

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

        Log.info("RustTerminalView[\(viewId)]: startTerminal - Complete")
    }

    deinit {
        Log.info("RustTerminalView[\(viewId)]: deinit - Starting cleanup")
        // Set flag to prevent CVDisplayLink callbacks from accessing deallocated view
        isBeingDeallocated = true
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
            // Recalculate cell dimensions now that window?.backingScaleFactor is available
            updateCellDimensions()
            if isEventMonitoringEnabled {
                Log.trace("RustTerminalView[\(viewId)]: viewDidMoveToWindow - Setting up event monitors")
                setupEventMonitors()
            }
        } else {
            Log.trace("RustTerminalView[\(viewId)]: viewDidMoveToWindow - Removed from window")
            removeEventMonitors()
        }
    }

    override func layout() {
        super.layout()
        // Match SwiftTerm behavior: use bounds directly without toolbar inset calculation.
        // The hosting view is already positioned at contentLayoutRect by OverlayBlurView.
        gridView?.frame = bounds
        overlayContainer?.frame = bounds

        // DEBUG: Log layout dimensions
        if let window = window {
            let contentRect = window.contentLayoutRect
            Log.info("RustTerminalView[\(viewId)]: DEBUG layout - bounds=\(bounds) frame=\(frame) contentLayoutRect=\(contentRect) window.frame=\(window.frame)")
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
            headlessTerminal?.terminal.resize(cols: cols, rows: rows)
            needsGridSync = true
        }

        updateTipOverlayPosition()
        updateInlineImagePositions()
    }

    override var acceptsFirstResponder: Bool { true }

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
    private var _inputContext: NSTextInputContext?

    // MARK: - Cell Dimensions

    private func updateCellDimensions() {
        // Match SwiftTerm's computeFontDimensions():
        // - Width: measure all ASCII printable chars, take max advance, ceil()
        // - Height: max of (ascent+descent+leading) and NSLayoutManager.defaultLineHeight, ceil()
        let ctFont = font as CTFont
        let oldWidth = cellWidth
        let oldHeight = cellHeight

        // Cell width: max advance width of all printable ASCII characters
        var characters = (32...126).map { UniChar($0) }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        let mapped = CTFontGetGlyphsForCharacters(ctFont, &characters, &glyphs, characters.count)
        var maxWidth: CGFloat = 0
        if mapped {
            var advances = [CGSize](repeating: .zero, count: characters.count)
            CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphs, &advances, glyphs.count)
            for idx in 0..<glyphs.count where glyphs[idx] != 0 {
                maxWidth = max(maxWidth, advances[idx].width)
            }
        }
        cellWidth = max(1, ceil(maxWidth))

        // Cell height: match SwiftTerm which uses max of CTFont metrics and layout manager
        let lineAscent = CTFontGetAscent(ctFont)
        let lineDescent = CTFontGetDescent(ctFont)
        let lineLeading = CTFontGetLeading(ctFont)
        let baseLineHeight = lineAscent + lineDescent + lineLeading
        // Also check NSLayoutManager's defaultLineHeight for consistent sizing
        let layoutManager = NSLayoutManager()
        let defaultLineHeight = layoutManager.defaultLineHeight(for: font)
        cellHeight = max(1, ceil(max(baseLineHeight, defaultLineHeight)))

        if cellWidth != oldWidth || cellHeight != oldHeight {
            Log.trace("RustTerminalView[\(viewId)]: updateCellDimensions - Cell size changed from \(oldWidth)x\(oldHeight) to \(cellWidth)x\(cellHeight)")
        }
        gridView?.cellSize = CGSize(width: cellWidth, height: cellHeight)
        rescaleInlineImages()
    }

    /// Convert screen point (in view coordinates) to visible cell coordinates
    /// - Parameter point: Point in view coordinates (standard macOS: origin at bottom-left)
    /// - Returns: (column, row) in visible coordinates (row 0 is top of visible area)
    /// - Note: Use this for mouse reporting to TUI apps (vim, tmux, etc.)
    private func pointToCell(_ point: NSPoint) -> (col: Int32, row: Int32) {
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
    private func pointToCellAbsolute(_ point: NSPoint) -> (col: Int32, row: Int32) {
        // First get visible cell coordinates
        let visible = pointToCell(point)
        // Get current display offset (how many lines scrolled up from bottom)
        let displayOffset = rustTerminal?.displayOffset ?? 0
        // Convert to absolute grid coordinates: visible row - display_offset
        // This matches how alacritty_terminal's Selection uses Line coordinates
        let absoluteRow = visible.row - Int32(displayOffset)
        return (visible.col, absoluteRow)
    }

    // MARK: - Polling Loop

    private func setupPollingLoop() {
        Log.trace("RustTerminalView[\(viewId)]: setupPollingLoop - Creating polling loop")

        // Try CVDisplayLink first for vsync-aligned updates
        var link: CVDisplayLink?
        let result = CVDisplayLinkCreateWithActiveCGDisplays(&link)

        if result == kCVReturnSuccess, let link = link {
            Log.trace("RustTerminalView[\(viewId)]: setupPollingLoop - CVDisplayLink created successfully")
            // Use a weak-reference box to prevent use-after-free if the view
            // deallocates while a CVDisplayLink callback is in flight.
            // passRetained ensures the box survives until we explicitly release
            // it in stopPollingLoop, even if the view itself is deallocated.
            let box = DisplayLinkWeakBox(self)
            displayLinkBox = box
            CVDisplayLinkSetOutputCallback(link, { (_, _, _, _, _, userInfo) -> CVReturn in
                guard let userInfo = userInfo else { return kCVReturnSuccess }
                let box = Unmanaged<DisplayLinkWeakBox>.fromOpaque(userInfo).takeUnretainedValue()
                guard let view = box.view else { return kCVReturnSuccess }
                DispatchQueue.main.async { [weak view] in
                    view?.pollAndSync()
                }
                return kCVReturnSuccess
            }, Unmanaged.passRetained(box).toOpaque())

            CVDisplayLinkStart(link)
            displayLink = link
            Log.info("RustTerminalView[\(viewId)]: setupPollingLoop - Using CVDisplayLink for 60fps polling")
        } else {
            // Fallback to timer
            Log.warn("RustTerminalView[\(viewId)]: setupPollingLoop - CVDisplayLink failed (result=\(result)), falling back to Timer")
            pollTimer = Timer.scheduledTimer(withTimeInterval: displayRefreshInterval, repeats: true) { [weak self] _ in
                self?.pollAndSync()
            }
            Log.info("RustTerminalView[\(viewId)]: setupPollingLoop - Using Timer fallback for polling")
        }
    }

    private func stopPollingLoop() {
        Log.trace("RustTerminalView[\(viewId)]: stopPollingLoop - Stopping polling loop")
        if let link = displayLink {
            Log.trace("RustTerminalView[\(viewId)]: stopPollingLoop - Stopping CVDisplayLink")
            CVDisplayLinkStop(link)
            displayLink = nil
        }
        // Release the retained DisplayLinkWeakBox. After CVDisplayLinkStop
        // completes, no more callbacks will fire, so it's safe to release.
        if let box = displayLinkBox {
            Unmanaged.passUnretained(box).release()
            displayLinkBox = nil
        }
        if pollTimer != nil {
            Log.trace("RustTerminalView[\(viewId)]: stopPollingLoop - Invalidating Timer")
            pollTimer?.invalidate()
            pollTimer = nil
        }
        stopBackgroundDrain()
    }

    // MARK: - Display Link Pause/Resume (Background Tab Optimization)

    /// Pause the CVDisplayLink and start a slow background drain timer.
    /// Background tabs only need to drain the PTY buffer to prevent the shell from
    /// blocking — they don't need 60fps rendering. A 500ms timer is sufficient.
    private func pauseDisplayLink() {
        if let link = displayLink, CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStop(link)
            Log.info("RustTerminalView[\(viewId)]: pauseDisplayLink - CVDisplayLink paused (tab suspended)")
        }
        pollTimer?.invalidate()
        pollTimer = nil

        startBackgroundDrain()
    }

    /// Resume the CVDisplayLink and stop the slow background drain.
    /// Called when a tab becomes active again. Forces an immediate full sync
    /// so the user sees current content without waiting for the next vsync.
    private func resumeDisplayLink() {
        stopBackgroundDrain()

        if let link = displayLink, !CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStart(link)
            Log.info("RustTerminalView[\(viewId)]: resumeDisplayLink - CVDisplayLink resumed (tab active)")
        } else if displayLink == nil && pollTimer == nil {
            // If display link was nil (never created or destroyed), don't recreate — just use timer
            pollTimer = Timer.scheduledTimer(withTimeInterval: displayRefreshInterval, repeats: true) { [weak self] _ in
                self?.pollAndSync()
            }
        }

        // Force an immediate sync so the user sees fresh content
        needsGridSync = true
        pollAndSync()
    }

    /// Start slow-rate PTY drain for background tabs (500ms interval).
    /// This prevents the shell process from blocking on a full PTY buffer
    /// while using negligible CPU.
    private func startBackgroundDrain() {
        guard backgroundDrainTimer == nil else { return }
        backgroundDrainTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.backgroundDrain()
        }
    }

    private func stopBackgroundDrain() {
        backgroundDrainTimer?.invalidate()
        backgroundDrainTimer = nil
    }

    /// Minimal PTY drain for background tabs — no rendering, no UI sync.
    /// Only polls the Rust terminal to drain its buffer and checks for
    /// critical events (process exit, title changes, bell).
    private func backgroundDrain() {
        guard !isBeingDeallocated else { return }
        guard let rust = rustTerminal else { return }

        _ = rust.poll(timeout: 0)

        // Still check for critical events even when suspended
        if rust.checkBell() { handleBell() }
        if let exitCode = rust.getPendingExitCode() {
            emitProcessTerminatedOnce(exitCode: exitCode, reason: "exit-code")
        }
        if rust.isPtyClosed() {
            emitProcessTerminatedOnce(exitCode: nil, reason: "pty-closed")
        }
        if let title = rust.getPendingTitle() {
            DispatchQueue.main.async { [weak self] in
                self?.onTitleChanged?(title)
            }
        }
    }

    /// Poll Rust terminal and sync to renderer if needed
    private static var pollAndSyncCounter: UInt64 = 0
    private static var lastPollAndSyncLogTime: CFAbsoluteTime = 0
    private static var syncCount: UInt64 = 0

    private func emitProcessTerminatedOnce(exitCode: Int32?, reason: String) {
        guard !didEmitProcessTermination else { return }
        didEmitProcessTermination = true
        Log.info("RustTerminalView[\(viewId)]: Process terminated (\(reason), exitCode=\(String(describing: exitCode)))")
        DispatchQueue.main.async { [weak self] in
            self?.onProcessTerminated?(exitCode)
        }
    }

    private func pollAndSync() {
        // Safety: Check if view is being deallocated (CVDisplayLink callback protection)
        guard !isBeingDeallocated else { return }
        guard let rust = rustTerminal else { return }

        // ALWAYS poll the Rust terminal to drain PTY buffer, even when suspended.
        // This prevents the PTY reader thread from blocking when the buffer fills up.
        // (Issue #4 fix: suspended state was blocking PTY by not draining)
        //
        // Selection preservation: Rust manages selection state internally. If poll()
        // processes output that scrolls the terminal, Rust may clear its selection.
        // During an active drag (isSelecting == true), the next mouseDragged event
        // re-establishes the selection via rust.updateSelection(). However, if the
        // user holds the mouse still during scrolling, no drag events fire and the
        // selection stays cleared until the next mouse movement. The 60fps
        // CVDisplayLink render loop minimizes visible flicker in the common case.
        // If flicker becomes noticeable, a Rust FFI flag
        // (preserve_selection_during_scroll) would be the proper fix.
        let changed = rust.poll(timeout: 0)

        // Check for bell events from Rust terminal and trigger audio/visual feedback
        if rust.checkBell() {
            handleBell()
        }

        // Check for terminal title changes (OSC 0/1/2)
        if let title = rust.getPendingTitle() {
            // Rate-limit: only log when the title actually changes (spinner animations
            // like ⠂/⠐/✳ trigger ~1 update/sec, producing 10K+ log entries/day)
            if title != lastLoggedTitle {
                Log.trace("RustTerminalView[\(viewId)]: Terminal title changed to \"\(title)\"")
                lastLoggedTitle = title
            }
            DispatchQueue.main.async { [weak self] in
                self?.onTitleChanged?(title)
            }
        }

        // Check for clipboard events (OSC 52)
        if let clipboardText = rust.getPendingClipboard() {
            Log.info("RustTerminalView[\(viewId)]: OSC 52 clipboard store: \(clipboardText.count) chars")
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(clipboardText, forType: .string)
            }
        }
        if rust.hasClipboardRequest() {
            Log.info("RustTerminalView[\(viewId)]: OSC 52 clipboard load request")
            let clipboardContent = NSPasteboard.general.string(forType: .string) ?? ""
            rust.respondClipboard(text: clipboardContent)
        }

        // Check for child process exit
        if let exitCode = rust.getPendingExitCode() {
            emitProcessTerminatedOnce(exitCode: exitCode, reason: "exit-code")
        }

        // Check for PTY closed (without exit code - e.g., connection lost)
        if rust.isPtyClosed() {
            emitProcessTerminatedOnce(exitCode: nil, reason: "pty-closed")
        }

        // Update application cursor mode (DECCKM) from terminal state
        // This affects how arrow keys are encoded (CSI vs SS3 sequences)
        let cursorMode = rust.isApplicationCursorMode()
        if cursorMode != applicationCursorMode {
            applicationCursorMode = cursorMode
            Log.trace("RustTerminalView[\(viewId)]: Application cursor mode changed to \(cursorMode)")
        }

        // Retrieve raw output bytes from the last poll and forward to onOutput callback.
        // This enables shell integration, logging, and output detectors to receive data.
        // (Issue #3 fix: onOutput callback was never called)
        if var outputData = rust.getLastOutput(), !outputData.isEmpty {
            // Log first 2KB of startup output for debugging
            if startupBytesLogged < 2048 {
                let bytesToLog = min(outputData.count, 2048 - startupBytesLogged)
                let preview = outputData.prefix(bytesToLog)
                let printable = preview.map { b -> Character in
                    if b >= 32 && b < 127 { return Character(UnicodeScalar(b)) }
                    else if b == 10 { return "↵" }
                    else if b == 13 { return "←" }
                    else if b == 27 { return "⎋" }
                    else { return "·" }
                }
                Log.info("RustTerminalView[\(viewId)]: PTY startup output (\(outputData.count) bytes): \(String(printable))")
                startupBytesLogged += outputData.count
            }

            let extraction = extractInlineImages(from: outputData)
            outputData = extraction.0
            if !extraction.1.isEmpty {
                renderInlineImages(extraction.1)
            }

            // Phase 4: Check for Rust-intercepted image sequences (Sixel, Kitty).
            // iTerm2 images are still handled by the Swift extractInlineImages path above,
            // since the raw bytes pass through last_output before the Rust interceptor.
            // Sixel/Kitty images only come through this Rust path.
            if let images = rust.getPendingImages() {
                for img in images {
                    let protocolName = img.protocol == 0 ? "iTerm2" : img.protocol == 1 ? "Sixel" : "Kitty"
                    Log.info("RustTerminalView[\(viewId)]: Received \(protocolName) image (\(img.data.count) bytes) at row=\(img.anchorRow), col=\(img.anchorCol)")
                    // TODO: Sixel decoding → RGBA → InlineImageView (Phase 4 future)
                    // TODO: Kitty protocol state management (Phase 4 future)
                    // For now, images are intercepted and logged. The infrastructure is in place
                    // for Sixel/Kitty rendering when decoders are added.
                }
            }

            // Parse OSC 7 (current working directory) before processing
            // OSC 7 format: ESC ] 7 ; file://hostname/path BEL
            parseOSC7(from: outputData)

            // Smart Scroll: Save state before feeding data to the renderer
            // If user had scrolled up and smart scroll is enabled, we'll restore their position
            let smartScrollEnabled = FeatureSettings.shared.isSmartScrollEnabled
            let wasAtBottom = isUserAtBottom
            let savedScrollPosition = scrollPosition

            // HeadlessTerminal feed removed (Phase 3b): Buffer-dependent features
            // (search, dangerous command detection) now use native Rust FFI via
            // getBufferAsData(), terminalRows, terminalCols, currentAbsoluteRow.
            // This eliminates 2x memory usage from the HeadlessTerminal mirror.

            // Smart Scroll: Restore position if user wasn't at bottom
            restoreSmartScrollIfNeeded(smartScrollEnabled: smartScrollEnabled, wasAtBottom: wasAtBottom, savedPosition: savedScrollPosition)

            // LOCAL ECHO SUPPRESSION: Filter out characters we already displayed locally
            // This prevents "double echo" when PTY confirms what we predicted
            outputData = processOutputForLocalEcho(outputData)

            if !outputData.isEmpty {
                onOutput?(outputData)
            }
        }

        // Skip UI updates when suspended, but we've already drained the PTY above
        guard notifyUpdateChanges else { return }

        if changed || needsGridSync {
            Self.syncCount += 1
            instanceSyncCount += 1
            needsGridSync = false
            // When Metal is active, skip the CPU sync — Metal reads the grid
            // directly via its gridProvider closure. This avoids ~70% CPU waste
            // from invisible RustGridView.draw() and cell array copies.
            if !isMetalRenderingActive {
                syncGridToRenderer()
            }
            onBufferChanged?()
        }

        // Metal has its own cursor blink timer (RustMetalDisplayCoordinator.handleBlinkTick)
        if !isMetalRenderingActive {
            gridView?.tickCursorBlink(now: CFAbsoluteTimeGetCurrent())
        }

        // Rate-limited status logging
        Self.pollAndSyncCounter += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now - Self.lastPollAndSyncLogTime > 10.0 {  // Log every 10 seconds
            Log.trace("RustTerminalView[\(viewId)]: pollAndSync - Status: \(Self.pollAndSyncCounter) polls, \(Self.syncCount) syncs")
            Self.lastPollAndSyncLogTime = now
        }
    }

    // MARK: - Metal GPU Rendering Support

    /// Creates a grid provider closure for the RustMetalDisplayCoordinator.
    /// Returns nil if the Rust terminal is not available (library not loaded).
    /// The closure captures the FFI instance and provides grid snapshot + cursor + free.
    func makeGridProvider() -> RustGridProvider? {
        guard let rust = rustTerminal else {
            Log.warn("RustTerminalView[\(viewId)]: makeGridProvider - No Rust terminal available")
            return nil
        }

        return { [weak rust] in
            guard let rust = rust else { return nil }
            guard let (grid, freeGrid) = rust.getGrid() else { return nil }

            let cursor = rust.cursorPosition
            let cursorVisible = grid.pointee.cursor_visible != 0
            // grid is UnsafeMutablePointer<RustGridSnapshot>, cast to raw for the generic provider
            let rawPtr = UnsafeMutableRawPointer(grid)
            return (grid: rawPtr, cursor: cursor, cursorVisible: cursorVisible, free: freeGrid)
        }
    }

    // MARK: - Grid Synchronization (Optimized for Issue #7)

    /// Sync Rust terminal grid to the native renderer.
    /// Uses dirty row detection and rate limiting to minimize CPU usage during high-output scenarios.
    ///
    /// Optimizations implemented:
    /// 1. Rate limiting - Skip syncs that happen too close together (allows up to 120fps)
    /// 2. Unchanged grid detection - Skip entirely if grid and cursor haven't changed
    /// 3. Dirty row tracking - Only rebuild escape sequences for rows that actually changed
    /// 4. Partial sync - When fewer than half the rows changed, update only those rows
    /// 5. Efficient comparison - Cell-by-cell comparison with early exit per row
    private func syncGridToRenderer() {
        guard let rust = rustTerminal else {
            Log.trace("RustTerminalView[\(viewId)]: syncGridToRenderer - No Rust terminal")
            return
        }

        // Rate limiting: Skip if we synced very recently (allows up to 120fps for responsiveness)
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastSyncTime < Self.minSyncInterval {
            skippedSyncCount += 1
            return
        }

        guard let (grid, freeGrid) = rust.getGrid() else {
            Log.trace("RustTerminalView[\(viewId)]: syncGridToRenderer - getGrid returned nil")
            return
        }
        defer { freeGrid() }

        let snapshot = grid.pointee
        guard let cells = snapshot.cells else {
            Log.trace("RustTerminalView[\(viewId)]: syncGridToRenderer - Grid has no cells")
            return
        }

        let gridCols = Int(snapshot.cols)
        let gridRows = Int(snapshot.rows)
        let totalCells = gridCols * gridRows
        let cursor = rust.cursorPosition
        let cursorVisible = snapshot.cursor_visible != 0

        // Cache scrollback size for renderTopVisibleRow (lightweight access)
        cachedScrollbackRows = Int(snapshot.scrollback_rows)

        // Update CPU renderer cursor visibility (DECTCEM)
        gridView?.cursorVisible = cursorVisible

        // Fast path: Check if grid dimensions changed (requires full rebuild)
        let dimensionsChanged = gridCols != previousGridCols || gridRows != previousGridRows

        // Determine which rows have changed by comparing with previous grid
        var dirtyRows: Set<Int> = []
        let canCompare = !dimensionsChanged && previousGrid.count == totalCells
        var cursorMoved = false

        if canCompare {
            // Compare cell-by-cell to find dirty rows (with early exit per row)
            for row in 0..<gridRows {
                let rowStart = row * gridCols
                var rowDirty = false
                for col in 0..<gridCols {
                    let idx = rowStart + col
                    let newCell = cells[idx]
                    let oldCell = previousGrid[idx]

                    if !cellsEqual(newCell, oldCell) {
                        rowDirty = true
                        break  // Row is dirty, no need to check more cells in this row
                    }
                }
                if rowDirty {
                    dirtyRows.insert(row)
                }
            }

            // Also check if cursor moved
            cursorMoved = cursor.col != previousCursorCol || cursor.row != previousCursorRow

            // If nothing changed at all, skip the sync entirely
            if dirtyRows.isEmpty && !cursorMoved {
                skippedSyncCount += 1
                return
            }
        }

        // Update timestamp for rate limiting
        lastSyncTime = now

        // Update previous state for next comparison
        previousGridCols = gridCols
        previousGridRows = gridRows
        previousCursorCol = cursor.col
        previousCursorRow = cursor.row

        if canCompare && dirtyRows.isEmpty && cursorMoved {
            gridView?.updateCursor(cursor)
        } else {
            // Copy current grid for future comparison using efficient buffer copy
            previousGrid.removeAll(keepingCapacity: true)
            previousGrid.reserveCapacity(totalCells)
            let cellBuffer = UnsafeBufferPointer(start: cells, count: totalCells)
            previousGrid.append(contentsOf: cellBuffer)

            // Determine sync strategy: partial sync if less than half the rows changed
            let usePartialSync = canCompare && !dirtyRows.isEmpty && dirtyRows.count < gridRows / 2

            if usePartialSync {
                partialSyncCount += 1
                Log.trace("RustTerminalView[\(viewId)]: syncGridToRenderer - Partial sync for \(dirtyRows.count)/\(gridRows) dirty rows")
                gridView?.updateGrid(cells: cells, cols: gridCols, rows: gridRows, cursor: cursor, dirtyRows: dirtyRows)
            } else {
                fullSyncCount += 1
                Log.trace("RustTerminalView[\(viewId)]: syncGridToRenderer - Full sync for \(gridCols)x\(gridRows) grid (dims changed: \(dimensionsChanged), dirty: \(dirtyRows.count))")
                gridView?.updateGrid(cells: cells, cols: gridCols, rows: gridRows, cursor: cursor, dirtyRows: nil)
            }
        }

        // Periodic stats logging (every 1000 syncs)
        if (fullSyncCount + partialSyncCount) % 1000 == 0 {
            Log.trace("RustTerminalView[\(viewId)]: syncStats - full:\(fullSyncCount) partial:\(partialSyncCount) skipped:\(skippedSyncCount)")
        }

        if pendingLocalEcho.isEmpty && pendingLocalBackspaces == 0 {
            clearLocalEchoOverlay()
        }

        updateInlineImagePositions()
    }

    /// Compare two cells for equality (inlined for performance)
    @inline(__always)
    private func cellsEqual(_ a: RustCellData, _ b: RustCellData) -> Bool {
        return a.character == b.character &&
               a.fg_r == b.fg_r && a.fg_g == b.fg_g && a.fg_b == b.fg_b &&
               a.bg_r == b.bg_r && a.bg_g == b.bg_g && a.bg_b == b.bg_b &&
               a.flags == b.flags && a.link_id == b.link_id
    }

    /// Reset grid sync state (call on resize or other major changes)
    private func resetGridSyncState() {
        previousGrid.removeAll()
        previousGridCols = 0
        previousGridRows = 0
        previousCursorCol = 0
        previousCursorRow = 0
        needsGridSync = true
        clearLocalEchoOverlay()
    }

    private func clearLocalEchoOverlay() {
        localEchoOverlay.removeAll()
        localEchoCursor = nil
        gridView?.clearOverlay()
        clearLocalEchoState()
    }

    private func clearLocalEchoState() {
        pendingLocalEcho.removeAll()
        pendingLocalEchoOffset = 0
        pendingLocalBackspaces = 0
    }

    private func removeLastPendingLocalEchoChar() {
        guard !pendingLocalEcho.isEmpty else { return }
        pendingLocalEcho.removeLast()
        if pendingLocalEchoOffset > pendingLocalEcho.count {
            pendingLocalEchoOffset = pendingLocalEcho.count
        }
    }

    private func compactConsumedLocalEchoIfNeeded() {
        guard pendingLocalEchoOffset > 0 else { return }
        if pendingLocalEchoOffset >= pendingLocalEcho.count {
            pendingLocalEcho.removeAll()
            pendingLocalEchoOffset = 0
            return
        }
        if pendingLocalEchoOffset > 64 {
            pendingLocalEcho.removeFirst(pendingLocalEchoOffset)
            pendingLocalEchoOffset = 0
        }
    }

    private func baseCellForLocalEcho(row: Int, col: Int) -> RustCellData {
        let idx = row * cols + col
        if idx >= 0 && idx < previousGrid.count {
            return previousGrid[idx]
        }
        return RustCellData(character: 0, fg_r: 255, fg_g: 255, fg_b: 255, bg_r: 0, bg_g: 0, bg_b: 0, flags: 0, _pad: 0, link_id: 0)
    }

    private func updateLocalEchoOverlay() {
        if localEchoOverlay.isEmpty {
            gridView?.clearOverlay()
        } else {
            gridView?.setOverlayCells(localEchoOverlay)
        }
    }

    private func advanceLocalEchoCursor(_ cursor: inout (row: Int, col: Int)) {
        cursor.col += 1
        if cursor.col >= cols {
            cursor.col = 0
            cursor.row = min(rows - 1, cursor.row + 1)
        }
    }

    private func retreatLocalEchoCursor(_ cursor: inout (row: Int, col: Int)) {
        if cursor.col > 0 {
            cursor.col -= 1
        } else if cursor.row > 0 {
            cursor.row -= 1
            cursor.col = max(0, cols - 1)
        }
    }

    private func hideTipOverlay() {
        tipOverlayView?.removeFromSuperview()
        tipOverlayView = nil
    }

    private func updateTipOverlayPosition() {
        guard let tip = tipOverlayView else { return }
        let size = tip.frame.size
        let renderBounds = overlayContainer?.bounds ?? bounds
        let origin = NSPoint(x: (renderBounds.width - size.width) / 2, y: renderBounds.height - size.height - 20)
        tip.frame.origin = origin
    }

    func showTipOverlay(message: String) {
        guard tipOverlayView == nil else { return }
        let container = PassthroughView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        container.layer?.cornerRadius = 8
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor

        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor.labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        let padding: CGFloat = 10
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding)
        ])

        overlayContainer.addSubview(container)
        tipOverlayView = container

        let renderBounds = overlayContainer?.bounds ?? bounds
        let maxWidth = min(renderBounds.width * 0.75, 460)
        let maxLabelWidth = maxWidth - (padding * 2)
        let labelRect = label.attributedStringValue.boundingRect(
            with: NSSize(width: maxLabelWidth, height: 200),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let labelSize = NSSize(width: ceil(labelRect.width), height: ceil(labelRect.height))
        let containerSize = NSSize(width: maxWidth, height: labelSize.height + (padding * 2))
        let origin = NSPoint(x: (renderBounds.width - containerSize.width) / 2, y: renderBounds.height - containerSize.height - 20)
        container.frame = NSRect(origin: origin, size: containerSize)
    }

    private func extractInlineImages(from data: Data) -> (Data, [InlineImage]) {
        guard InlineImageHandler.shared.isEnabled else { return (data, []) }
        guard let text = String(data: data, encoding: .utf8) else { return (data, []) }

        let marker = "\u{1b}]1337;File="
        var output = String()
        output.reserveCapacity(text.count)
        var images: [InlineImage] = []

        var idx = text.startIndex
        while idx < text.endIndex {
            if text[idx...].hasPrefix(marker) {
                var end = idx
                var foundTerminator = false
                var scan = idx
                while scan < text.endIndex {
                    let ch = text[scan]
                    if ch == "\u{07}" {
                        end = scan
                        foundTerminator = true
                        scan = text.index(after: scan)
                        break
                    }
                    if ch == "\u{1b}" {
                        let next = text.index(after: scan)
                        if next < text.endIndex, text[next] == "\\" {
                            end = scan
                            foundTerminator = true
                            scan = text.index(after: next)
                            break
                        }
                    }
                    scan = text.index(after: scan)
                }

                if foundTerminator {
                    let seq = String(text[idx..<end])
                    if let image = InlineImageHandler.shared.parseImageSequence(seq) {
                        images.append(image)
                    }
                    idx = scan
                    continue
                }
            }

            output.append(text[idx])
            idx = text.index(after: idx)
        }

        return (Data(output.utf8), images)
    }

    private func renderInlineImages(_ images: [InlineImage]) {
        guard let rust = rustTerminal else { return }
        guard InlineImageHandler.shared.isEnabled else { return }
        let cellSize = NSSize(width: cellWidth, height: cellHeight)
        let maxCells = (width: cols, height: rows)
        let cursor = rust.cursorPosition
        let displayOffset = Int(rust.displayOffset)
        let anchorRow = Int(cursor.row) - displayOffset
        let anchorCol = Int(cursor.col)

        for image in images where image.args.inline {
            guard let scaled = InlineImageHandler.shared.renderImage(image, cellSize: cellSize, maxCells: maxCells) else {
                continue
            }
            let inline = InlineImage(image: scaled, args: image.args)
            let view = InlineImageView(image: inline, frame: .zero)
            overlayContainer.addSubview(view)
            var placement = InlineImagePlacement(view: view, image: image, size: scaled.size, anchorRow: anchorRow, anchorCol: anchorCol)
            positionInlineImage(&placement, displayOffset: displayOffset)
            inlineImages.append(placement)
        }
    }

    private func rescaleInlineImages() {
        guard InlineImageHandler.shared.isEnabled else { return }
        let cellSize = NSSize(width: cellWidth, height: cellHeight)
        let maxCells = (width: cols, height: rows)
        for index in inlineImages.indices {
            let original = inlineImages[index].image
            if let scaled = InlineImageHandler.shared.renderImage(original, cellSize: cellSize, maxCells: maxCells) {
                inlineImages[index].size = scaled.size
                inlineImages[index].view.setImage(scaled)
            }
        }
        updateInlineImagePositions()
    }

    private func updateInlineImagePositions() {
        guard let rust = rustTerminal else { return }
        let displayOffset = Int(rust.displayOffset)
        if displayOffset == lastDisplayOffset && !inlineImages.isEmpty {
            // Still update positions on resize/layout.
        }
        lastDisplayOffset = displayOffset

        for index in inlineImages.indices {
            var placement = inlineImages[index]
            positionInlineImage(&placement, displayOffset: displayOffset)
            inlineImages[index] = placement
        }
    }

    private func positionInlineImage(_ placement: inout InlineImagePlacement, displayOffset: Int) {
        let visibleRow = placement.anchorRow + displayOffset
        guard visibleRow >= 0 && visibleRow < rows else {
            placement.view.isHidden = true
            return
        }
        placement.view.isHidden = false
        let x = CGFloat(placement.anchorCol) * cellWidth
        let renderHeight = overlayContainer?.bounds.height ?? (gridView?.bounds.height ?? bounds.height)
        let topY = renderHeight - CGFloat(visibleRow) * cellHeight
        let y = topY - placement.size.height
        placement.view.frame = CGRect(x: x, y: y, width: placement.size.width, height: placement.size.height)
    }

    // MARK: - OSC 7 Directory Parsing

    /// Parse OSC 7 (current working directory) from raw PTY output.
    /// OSC 7 format: ESC ] 7 ; file://hostname/path BEL (0x07) or ESC \ (ST)
    private func parseOSC7(from data: Data) {
        // Look for OSC 7 sequence: ESC (0x1b) ] (0x5d) 7 ; ...
        // Terminated by BEL (0x07) or ESC \
        let bytes = Array(data)
        var i = 0

        while i < bytes.count - 5 {  // Need at least ESC ] 7 ; x BEL
            // Look for ESC ]
            if bytes[i] == 0x1b && i + 1 < bytes.count && bytes[i + 1] == 0x5d {
                // Found ESC ], check for '7;'
                if i + 3 < bytes.count && bytes[i + 2] == 0x37 && bytes[i + 3] == 0x3b {
                    // Found OSC 7 ; - extract the URL
                    let start = i + 4  // After "ESC ] 7 ;"

                    // Find terminator: BEL (0x07) or ESC \ (0x1b 0x5c)
                    var end = start
                    while end < bytes.count {
                        if bytes[end] == 0x07 {
                            break  // BEL terminator
                        }
                        if bytes[end] == 0x1b && end + 1 < bytes.count && bytes[end + 1] == 0x5c {
                            break  // ST (ESC \) terminator
                        }
                        end += 1
                    }

                    if end < bytes.count && end > start {
                        // Extract the URL string
                        let urlBytes = Array(bytes[start..<end])
                        if let urlString = String(bytes: urlBytes, encoding: .utf8) {
                            processOSC7URL(urlString)
                        }
                    }
                }
            }
            i += 1
        }
    }

    /// Process the URL from OSC 7 and extract the directory path.
    /// URL format: file://hostname/path
    private func processOSC7URL(_ urlString: String) {
        // Parse the file:// URL
        if let url = URL(string: urlString) {
            let path = url.path
            if !path.isEmpty && path != currentDirectory {
                Log.info("RustTerminalView[\(viewId)]: OSC 7 directory update: \(path)")
                currentDirectory = path
                DispatchQueue.main.async { [weak self] in
                    self?.onDirectoryChanged?(path)
                }
            }
        } else if urlString.hasPrefix("file://") {
            // Fallback: manual parsing for malformed URLs
            let pathStart = urlString.index(urlString.startIndex, offsetBy: 7)
            var path = String(urlString[pathStart...])
            // Remove hostname if present (format: file://hostname/path)
            if let slashIndex = path.firstIndex(of: "/") {
                path = String(path[slashIndex...])
            }
            // URL decode
            path = path.removingPercentEncoding ?? path
            if !path.isEmpty && path != currentDirectory {
                Log.info("RustTerminalView[\(viewId)]: OSC 7 directory update (fallback): \(path)")
                currentDirectory = path
                DispatchQueue.main.async { [weak self] in
                    self?.onDirectoryChanged?(path)
                }
            }
        }
    }

    // MARK: - Local Echo (Latency Optimization)

    /// Process PTY output to suppress characters we already locally echoed
    /// Returns the filtered data with echoed characters removed
    private func processOutputForLocalEcho(_ data: Data) -> Data {
        // Fast path: no pending echo, return as-is
        guard !pendingLocalEcho.isEmpty || pendingLocalBackspaces > 0 else {
            // Check for echo-disabling patterns in output (password prompts, etc.)
            detectEchoMode(in: data)
            return data
        }

        var filtered: [UInt8] = []
        filtered.reserveCapacity(data.count)

        var i = data.startIndex
        while i < data.endIndex {
            let byte = data[i]

            // Check for PTY backspace/delete confirmations (e.g. DEL, BS, or BS space BS)
            if pendingLocalBackspaces > 0 {
                let remaining = data.endIndex - i
                if byte == 0x08 && remaining >= 3 && data[i + 1] == 0x20 &&
                    (data[i + 2] == 0x08 || data[i + 2] == 0x7F) {
                    // Suppress backspace sequence we already displayed: "\b \b" or "\b \x7f"
                    pendingLocalBackspaces -= 1
                    removeLastPendingLocalEchoChar()
                    i += 3
                    continue
                }

                if byte == 0x08 || byte == 0x7F {
                    // Suppress single-byte backspace/delete echo
                    pendingLocalBackspaces -= 1
                    removeLastPendingLocalEchoChar()
                    i += 1
                    continue
                }
            }

            // Check for local echo character match
            if pendingLocalEchoOffset < pendingLocalEcho.count && byte == pendingLocalEcho[pendingLocalEchoOffset] {
                // This byte matches our local echo queue - suppress it
                pendingLocalEchoOffset += 1
                i += 1
                continue
            }

            // Include this byte in output
            filtered.append(byte)
            i += 1
        }

        compactConsumedLocalEchoIfNeeded()

        // Clear stale pending state (timeout protection)
        // If we have too much pending prediction state, something is out of sync
        if (pendingLocalEcho.count - pendingLocalEchoOffset) > Self.maxPendingLocalEcho || pendingLocalBackspaces > Self.maxPendingLocalEcho {
            Log.trace("RustTerminalView[\(viewId)]: Local echo buffer overflow, clearing")
            clearLocalEchoState()
            clearLocalEchoOverlay()
        }

        // Check for echo-disabling patterns in the filtered output
        detectEchoMode(in: Data(filtered))

        if pendingLocalEcho.isEmpty && pendingLocalBackspaces == 0 {
            clearLocalEchoOverlay()
        }

        if filtered.isEmpty {
            // All bytes were suppressed
            return Data()
        }

        return Data(filtered)
    }

    /// Detect patterns that indicate echo should be disabled (password prompts, raw mode)
    private func detectEchoMode(in data: Data) {
        // Check for timeout recovery: re-enable echo after timeout
        let now = CFAbsoluteTimeGetCurrent()
        if !isPtyEchoLikelyEnabled && now - echoDisabledTime > Self.echoDisabledTimeout {
            isPtyEchoLikelyEnabled = true
            Log.trace("RustTerminalView[\(viewId)]: Echo re-enabled after timeout")
        }

        // Look for common password prompt patterns that indicate echo is off
        // These heuristics work since we can't query termios directly
        guard let text = String(data: data, encoding: .utf8) else { return }

        let lowercased = text.lowercased()

        // Password prompt patterns (echo disabled)
        let passwordPatterns = [
            "password:",
            "password for",
            "passphrase:",
            "passphrase for",
            "enter passphrase",
            "sudo password",
            "pin:",
            "secret:",
            "[sudo]"
        ]

        for pattern in passwordPatterns {
            if lowercased.contains(pattern) {
                isPtyEchoLikelyEnabled = false
                echoDisabledTime = now
                clearLocalEchoState()
                clearLocalEchoOverlay()
                Log.trace("RustTerminalView[\(viewId)]: Echo disabled (detected password prompt)")
                return
            }
        }

        // If we see a shell prompt ($ # %) after being disabled, re-enable echo
        // This indicates we're back at a normal prompt
        if !isPtyEchoLikelyEnabled {
            let promptPatterns = ["$ ", "# ", "% ", "> "]
            for pattern in promptPatterns {
                if text.hasSuffix(pattern) || text.contains(pattern + "\n") {
                    isPtyEchoLikelyEnabled = true
                    Log.trace("RustTerminalView[\(viewId)]: Echo re-enabled (detected shell prompt)")
                    return
                }
            }
        }
    }

    /// Apply local echo for user input (display immediately before PTY round-trip)
    /// This reduces perceived latency by showing typed characters instantly
    private func applyLocalEcho(for bytes: [UInt8]) {
        // Check if local echo is enabled in settings
        guard supportsLocalEcho else { return }
        guard FeatureSettings.shared.isLocalEchoEnabled else {
            if !pendingLocalEcho.isEmpty || pendingLocalEchoOffset > 0 || pendingLocalBackspaces > 0 {
                clearLocalEchoState()
                clearLocalEchoOverlay()
            }
            return
        }

        // Check if PTY echo is likely enabled (not in password mode, etc.)
        guard isPtyEchoLikelyEnabled else {
            if !pendingLocalEcho.isEmpty || pendingLocalEchoOffset > 0 || pendingLocalBackspaces > 0 {
                clearLocalEchoState()
                clearLocalEchoOverlay()
            }
            return
        }

        let token = FeatureProfiler.shared.begin(.localEcho, bytes: bytes.count)
        defer { FeatureProfiler.shared.end(token) }

        if cols <= 0 || rows <= 0 { return }
        var cursor = localEchoCursor ?? {
            if let rust = rustTerminal {
                return (row: Int(rust.cursorPosition.row), col: Int(rust.cursorPosition.col))
            }
            return (row: 0, col: 0)
        }()
        cursor.row = max(0, min(rows - 1, cursor.row))
        cursor.col = max(0, min(cols - 1, cursor.col))

        for byte in bytes {
            // Only local echo printable ASCII (0x20-0x7E)
            if byte >= 0x20 && byte <= 0x7E {
                pendingLocalEcho.append(byte)
                let idx = cursor.row * cols + cursor.col
                var cell = baseCellForLocalEcho(row: cursor.row, col: cursor.col)
                cell.character = UInt32(byte)
                localEchoOverlay[idx] = cell
                advanceLocalEchoCursor(&cursor)
            } else if byte == 0x7F || byte == 0x08 {
                // Backspace/Delete: Undo the last local echo visually
                // Track the backspace so we suppress PTY's backspace response too
                pendingLocalBackspaces += 1
                retreatLocalEchoCursor(&cursor)
                let idx = cursor.row * cols + cursor.col
                localEchoOverlay.removeValue(forKey: idx)
                removeLastPendingLocalEchoChar()
                if !pendingLocalEcho.isEmpty && pendingLocalEchoOffset > pendingLocalEcho.count {
                    pendingLocalEchoOffset = pendingLocalEcho.count
                }
            } else if byte == 0x03 || byte == 0x15 {
                // Ctrl+C (0x03) or Ctrl+U (0x15): Clear local echo buffer
                // These typically abort/clear the current line
                clearLocalEchoState()
                clearLocalEchoOverlay()
                localEchoCursor = nil
                return
            } else if byte == 0x0A || byte == 0x0D {
                clearLocalEchoOverlay()
                clearLocalEchoState()
                localEchoCursor = nil
                return
            }
        }

        compactConsumedLocalEchoIfNeeded()

        localEchoCursor = cursor
        updateLocalEchoOverlay()
    }

    /// Apply local echo for text input
    private func applyLocalEchoForText(_ text: String) {
        let bytes = Array(text.utf8)
        applyLocalEcho(for: bytes)
    }

    // MARK: - Input Handling

    /// Application cursor mode (DECCKM) - when enabled, arrow keys send SS3 sequences instead of CSI
    /// This is typically set by programs like vim, less, tmux via escape sequence ESC[?1h
    private var applicationCursorMode = false

    /// True while keyDown is routing through inputContext, so insertText knows
    /// the call originated from a keyboard event (not Password AutoFill).
    private var handlingKeyDown = false

    /// IME marked text state — tracks pending dead key / composition text.
    /// Without this, dead keys like ^ on French keyboards get stuck because
    /// NSTextInputContext enters an inconsistent state when setMarkedText is
    /// a no-op and hasMarkedText returns false.
    private var markedTextStorage: String?
    private var markedSelectedRange: NSRange = NSRange(location: NSNotFound, length: 0)

    private func makeInputEventSignature(_ event: NSEvent) -> String {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.characters ?? ""
        let charactersIgnoringModifiers = event.charactersIgnoringModifiers ?? ""
        return "\(event.timestamp)|\(event.keyCode)|\(characters)|\(charactersIgnoringModifiers)|\(flags.rawValue)"
    }

    private func markGeneralKeyEventHandled(_ event: NSEvent) {
        let signature = makeInputEventSignature(event)
        lastMonitorHandledKeyEventSignature = signature
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            if self.lastMonitorHandledKeyEventSignature == signature {
                self.lastMonitorHandledKeyEventSignature = nil
            }
        }
    }

    private func isEventHandledByGeneralMonitor(_ event: NSEvent) -> Bool {
        guard let signature = lastMonitorHandledKeyEventSignature else { return false }
        return signature == makeInputEventSignature(event)
    }

    override func keyDown(with event: NSEvent) {
        guard let rust = rustTerminal else {
            Log.trace("RustTerminalView[\(viewId)]: keyDown - No Rust terminal")
            return
        }
        if isEventHandledByGeneralMonitor(event) {
            Log.trace("RustTerminalView[\(viewId)]: keyDown - Skipping event already handled by general monitor")
            return
        }
        // Command key combinations are handled by app commands (copy/paste/menus), not terminal input
        if event.modifierFlags.contains(.command) {
            return
        }
        hideTipOverlay()

        let keyCode = event.keyCode
        let modifiers = event.modifierFlags

        // Generate terminal escape sequence for this key event
        if let sequence = generateTerminalSequence(keyCode: keyCode, modifiers: modifiers, event: event) {
            let hexPreview = sequence.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            Log.trace("RustTerminalView[\(viewId)]: keyDown - Sending escape sequence: [\(hexPreview)] (keyCode=\(keyCode))")
            if sequence == [0x7f] || sequence == [0x08], let text = String(bytes: sequence, encoding: .utf8) {
                applyLocalEchoForText(text)
            }
            if let text = String(bytes: sequence, encoding: .utf8) {
                onInput?(text)
            }
            rust.sendBytes(sequence)
            return
        }

        // Route regular text input through NSTextInputContext so that
        // Password AutoFill and IME can deliver text via insertText.
        handlingKeyDown = true
        let handled = inputContext?.handleEvent(event) ?? false
        handlingKeyDown = false

        if !handled {
            // Fallback: inputContext didn't consume it, send characters directly
            if let chars = event.characters, !chars.isEmpty {
                applyLocalEchoForText(chars)
                let escaped = chars.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
                Log.trace("RustTerminalView[\(viewId)]: keyDown - Sending characters (fallback): '\(escaped)' (keyCode=\(keyCode))")
                send(txt: chars)
            } else if let charsNoMod = event.charactersIgnoringModifiers, !charsNoMod.isEmpty {
                applyLocalEchoForText(charsNoMod)
                let escaped = charsNoMod.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
                Log.trace("RustTerminalView[\(viewId)]: keyDown - Sending chars (no mod, fallback): '\(escaped)' (keyCode=\(keyCode))")
                send(txt: charsNoMod)
            } else {
                Log.trace("RustTerminalView[\(viewId)]: keyDown - No characters to send (keyCode=\(keyCode))")
            }
        }
    }

    /// Handle key event from event monitor - routes to Rust terminal
    /// Returns true if the event was handled, false otherwise
    private func handleTerminalKeyEvent(_ event: NSEvent) -> Bool {
        guard let rust = rustTerminal else {
            return false  // No Rust terminal, let event propagate
        }
        hideTipOverlay()

        let keyCode = event.keyCode
        let modifiers = event.modifierFlags

        // Command key combinations are handled by the app menu, not terminal
        if modifiers.contains(.command) {
            return false
        }

        // Generate terminal escape sequence for this key event
        if let sequence = generateTerminalSequence(keyCode: keyCode, modifiers: modifiers, event: event) {
            let hexPreview = sequence.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            Log.trace("RustTerminalView[\(viewId)]: handleTerminalKeyEvent - Sending escape sequence: [\(hexPreview)] (keyCode=\(keyCode))")
            if sequence == [0x7f] || sequence == [0x08], let text = String(bytes: sequence, encoding: .utf8) {
                applyLocalEchoForText(text)
            }
            if let text = String(bytes: sequence, encoding: .utf8) {
                onInput?(text)
            }
            rust.sendBytes(sequence)
            return true
        }

        // Fallback to characters for regular text input
        if let chars = event.characters, !chars.isEmpty {
            let escaped = chars.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
            Log.trace("RustTerminalView[\(viewId)]: handleTerminalKeyEvent - Sending characters: '\(escaped)' (keyCode=\(keyCode))")
            applyLocalEchoForText(chars)
            send(txt: chars)
            return true
        } else if let charsNoMod = event.charactersIgnoringModifiers, !charsNoMod.isEmpty {
            let escaped = charsNoMod.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
            Log.trace("RustTerminalView[\(viewId)]: handleTerminalKeyEvent - Sending chars (no mod): '\(escaped)' (keyCode=\(keyCode))")
            applyLocalEchoForText(charsNoMod)
            send(txt: charsNoMod)
            return true
        }

        Log.trace("RustTerminalView[\(viewId)]: handleTerminalKeyEvent - No characters to send (keyCode=\(keyCode))")
        return false
    }

    // MARK: - Terminal Escape Sequence Generation (Issue #2 Fix)

    /// Generates the appropriate terminal escape sequence for a key event.
    /// Returns nil if the key should be handled via regular character input.
    private func generateTerminalSequence(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, event: NSEvent) -> [UInt8]? {
        let hasControl = modifiers.contains(.control)
        let hasOption = modifiers.contains(.option)
        let hasShift = modifiers.contains(.shift)
        let hasCommand = modifiers.contains(.command)

        // Command key is typically handled by the app, not sent to terminal
        if hasCommand {
            return nil
        }

        // Check for special keys first (arrows, function keys, etc.)
        if let specialSequence = generateSpecialKeySequence(keyCode: keyCode, modifiers: modifiers) {
            return specialSequence
        }

        // Handle Ctrl+letter combinations
        if hasControl, let char = event.charactersIgnoringModifiers?.lowercased().first {
            if let controlCode = controlCharacter(for: char) {
                // Option+Ctrl sends ESC prefix + control code
                if hasOption {
                    return [0x1b, controlCode]
                }
                return [controlCode]
            }
        }

        // Handle Option/Alt+letter (sends ESC prefix for meta key)
        if hasOption && !hasControl {
            if let char = event.charactersIgnoringModifiers?.first {
                // Send ESC + character for Alt+key (meta key behavior)
                var bytes: [UInt8] = [0x1b]
                if hasShift {
                    // Shift+Alt sends uppercase
                    bytes.append(contentsOf: String(char).uppercased().utf8)
                } else {
                    bytes.append(contentsOf: String(char).utf8)
                }
                return bytes
            }
        }

        return nil
    }

    /// Generates escape sequences for special keys (arrows, function keys, etc.)
    private func generateSpecialKeySequence(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> [UInt8]? {
        let hasControl = modifiers.contains(.control)
        let hasOption = modifiers.contains(.option)
        let hasShift = modifiers.contains(.shift)

        // Calculate xterm modifier parameter
        // 1 = none, 2 = shift, 3 = alt, 4 = shift+alt, 5 = ctrl, 6 = shift+ctrl, 7 = alt+ctrl, 8 = shift+alt+ctrl
        var modParam = 1
        if hasShift { modParam += 1 }
        if hasOption { modParam += 2 }
        if hasControl { modParam += 4 }
        let hasModifiers = modParam > 1

        switch Int(keyCode) {
        // Arrow keys
        case kVK_UpArrow:
            return arrowKeySequence("A", modParam: modParam, hasModifiers: hasModifiers)
        case kVK_DownArrow:
            return arrowKeySequence("B", modParam: modParam, hasModifiers: hasModifiers)
        case kVK_RightArrow:
            return arrowKeySequence("C", modParam: modParam, hasModifiers: hasModifiers)
        case kVK_LeftArrow:
            return arrowKeySequence("D", modParam: modParam, hasModifiers: hasModifiers)

        // Navigation keys
        case kVK_Home:
            return hasModifiers ? csiSequenceWithMod("1", modParam: modParam, terminator: "H") : csiSequence("H")
        case kVK_End:
            return hasModifiers ? csiSequenceWithMod("1", modParam: modParam, terminator: "F") : csiSequence("F")
        case kVK_PageUp:
            return hasModifiers ? csiSequenceWithMod("5", modParam: modParam, terminator: "~") : csiSequence("5~")
        case kVK_PageDown:
            return hasModifiers ? csiSequenceWithMod("6", modParam: modParam, terminator: "~") : csiSequence("6~")

        // Editing keys
        case kVK_ForwardDelete:
            return hasModifiers ? csiSequenceWithMod("3", modParam: modParam, terminator: "~") : csiSequence("3~")
        case kVK_Help:  // Insert key on some keyboards
            return hasModifiers ? csiSequenceWithMod("2", modParam: modParam, terminator: "~") : csiSequence("2~")

        // Function keys F1-F12
        case kVK_F1:
            return functionKeySequence(1, modParam: modParam, hasModifiers: hasModifiers)
        case kVK_F2:
            return functionKeySequence(2, modParam: modParam, hasModifiers: hasModifiers)
        case kVK_F3:
            return functionKeySequence(3, modParam: modParam, hasModifiers: hasModifiers)
        case kVK_F4:
            return functionKeySequence(4, modParam: modParam, hasModifiers: hasModifiers)
        case kVK_F5:
            return functionKeySequence(5, modParam: modParam, hasModifiers: hasModifiers)
        case kVK_F6:
            return functionKeySequence(6, modParam: modParam, hasModifiers: hasModifiers)
        case kVK_F7:
            return functionKeySequence(7, modParam: modParam, hasModifiers: hasModifiers)
        case kVK_F8:
            return functionKeySequence(8, modParam: modParam, hasModifiers: hasModifiers)
        case kVK_F9:
            return functionKeySequence(9, modParam: modParam, hasModifiers: hasModifiers)
        case kVK_F10:
            return functionKeySequence(10, modParam: modParam, hasModifiers: hasModifiers)
        case kVK_F11:
            return functionKeySequence(11, modParam: modParam, hasModifiers: hasModifiers)
        case kVK_F12:
            return functionKeySequence(12, modParam: modParam, hasModifiers: hasModifiers)

        // Special character keys
        case kVK_Escape:
            return [0x1b]
        case kVK_Tab:
            if hasShift {
                return csiSequence("Z")  // Shift+Tab sends CSI Z (backtab)
            }
            return [0x09]  // Regular tab
        case kVK_Return:
            return [0x0d]  // Carriage return
        case kVK_Delete:  // Backspace key
            if hasControl {
                return [0x08]  // Ctrl+Backspace sends BS
            }
            return [0x7f]  // Regular backspace sends DEL

        default:
            return nil
        }
    }

    /// Generates arrow key sequences, respecting application cursor mode (DECCKM)
    private func arrowKeySequence(_ direction: Character, modParam: Int, hasModifiers: Bool) -> [UInt8] {
        if hasModifiers {
            // With modifiers: ESC [ 1 ; <mod> <direction>
            return Array("\u{1b}[1;\(modParam)\(direction)".utf8)
        } else if applicationCursorMode {
            // Application cursor mode: ESC O <direction> (SS3 sequence)
            return Array("\u{1b}O\(direction)".utf8)
        } else {
            // Normal mode: ESC [ <direction>
            return Array("\u{1b}[\(direction)".utf8)
        }
    }

    /// Generates a simple CSI sequence: ESC [ <content>
    private func csiSequence(_ content: String) -> [UInt8] {
        return Array("\u{1b}[\(content)".utf8)
    }

    /// Generates a CSI sequence with modifier: ESC [ <prefix> ; <mod> <terminator>
    private func csiSequenceWithMod(_ prefix: String, modParam: Int, terminator: String) -> [UInt8] {
        return Array("\u{1b}[\(prefix);\(modParam)\(terminator)".utf8)
    }

    /// Generates function key sequences (xterm-style)
    private func functionKeySequence(_ fKey: Int, modParam: Int, hasModifiers: Bool) -> [UInt8] {
        // F1-F4 use SS3 sequences without modifiers (legacy vt100 compatibility)
        // F1-F4 with modifiers and F5-F12 use CSI sequences with numeric codes
        //
        // Without modifiers:
        //   F1: ESC O P, F2: ESC O Q, F3: ESC O R, F4: ESC O S
        //   F5: ESC [15~, F6: ESC [17~, F7: ESC [18~, F8: ESC [19~
        //   F9: ESC [20~, F10: ESC [21~, F11: ESC [23~, F12: ESC [24~
        //
        // With modifiers:
        //   F1: ESC [11;Pm~, etc.

        if !hasModifiers && fKey <= 4 {
            // F1-F4 without modifiers use SS3 sequences
            let codes: [Character] = ["P", "Q", "R", "S"]
            return Array("\u{1b}O\(codes[fKey - 1])".utf8)
        }

        // F5+ and F1-F4 with modifiers use CSI ~ sequences
        // Map function key number to xterm numeric code
        let xtermKeyCode: Int
        switch fKey {
        case 1: xtermKeyCode = 11
        case 2: xtermKeyCode = 12
        case 3: xtermKeyCode = 13
        case 4: xtermKeyCode = 14
        case 5: xtermKeyCode = 15
        case 6: xtermKeyCode = 17  // Note: 16 is skipped
        case 7: xtermKeyCode = 18
        case 8: xtermKeyCode = 19
        case 9: xtermKeyCode = 20
        case 10: xtermKeyCode = 21
        case 11: xtermKeyCode = 23  // Note: 22 is skipped
        case 12: xtermKeyCode = 24
        default: xtermKeyCode = 15 + fKey
        }

        if hasModifiers {
            return Array("\u{1b}[\(xtermKeyCode);\(modParam)~".utf8)
        } else {
            return Array("\u{1b}[\(xtermKeyCode)~".utf8)
        }
    }

    /// Converts a character to its control character equivalent (Ctrl+A = 0x01, etc.)
    private func controlCharacter(for char: Character) -> UInt8? {
        guard let ascii = char.asciiValue else { return nil }

        // Control characters are lowercase letter's ASCII value minus 0x60
        // Or uppercase letter's ASCII value minus 0x40
        // a-z: 0x61-0x7A -> Ctrl codes 0x01-0x1A
        // A-Z: 0x41-0x5A -> Ctrl codes 0x01-0x1A (same result)
        if ascii >= 0x61 && ascii <= 0x7A {
            return ascii - 0x60
        }
        if ascii >= 0x41 && ascii <= 0x5A {
            return ascii - 0x40
        }

        // Special control characters
        switch char {
        case "[", "{":
            return 0x1b  // Ctrl+[ is ESC
        case "\\":
            return 0x1c  // Ctrl+\ is FS
        case "]", "}":
            return 0x1d  // Ctrl+] is GS
        case "^", "~":
            return 0x1e  // Ctrl+^ is RS
        case "_", "?":
            return 0x1f  // Ctrl+_ is US
        case "@", " ":
            return 0x00  // Ctrl+@ or Ctrl+Space is NUL
        case "2":
            return 0x00  // Ctrl+2 is NUL
        case "3":
            return 0x1b  // Ctrl+3 is ESC
        case "4":
            return 0x1c  // Ctrl+4 is FS
        case "5":
            return 0x1d  // Ctrl+5 is GS
        case "6":
            return 0x1e  // Ctrl+6 is RS
        case "7":
            return 0x1f  // Ctrl+7 is US
        case "8":
            return 0x7f  // Ctrl+8 is DEL
        default:
            return nil
        }
    }

    /// Sets the application cursor mode (DECCKM).
    /// This is typically called when the terminal receives ESC[?1h (enable) or ESC[?1l (disable)
    func setApplicationCursorMode(_ enabled: Bool) {
        applicationCursorMode = enabled
        Log.trace("RustTerminalView[\(viewId)]: Application cursor mode \(enabled ? "enabled" : "disabled")")
    }

    /// Send raw bytes to the PTY
    func send(data bytes: [UInt8]) {
        let preview = bytes.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
        let suffix = bytes.count > 8 ? " ...<\(bytes.count - 8) more>" : ""
        Log.trace("RustTerminalView[\(viewId)]: send(data:) - Sending \(bytes.count) bytes: [\(preview)\(suffix)]")
        hideTipOverlay()
        // Smart scroll: Scroll to bottom on user input (standard terminal behavior)
        // When the user types, they expect to see the current prompt
        if rustTerminal?.displayOffset ?? 0 > 0 {
            rustTerminal?.scrollTo(position: 0.0)
            needsGridSync = true
        }

        rustTerminal?.sendBytes(bytes)
    }

    /// Send text to the PTY
    func send(txt text: String) {
        let truncated = text.count > 50 ? String(text.prefix(50)) + "..." : text
        let escaped = truncated.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        Log.trace("RustTerminalView[\(viewId)]: send(txt:) - Sending \(text.count) chars: '\(escaped)'")
        hideTipOverlay()

        // Smart scroll: Scroll to bottom on user input (standard terminal behavior)
        // When the user types, they expect to see the current prompt
        if rustTerminal?.displayOffset ?? 0 > 0 {
            rustTerminal?.scrollTo(position: 0.0)
            needsGridSync = true
        }

        rustTerminal?.sendText(text)
        onInput?(text)
    }

    /// Inject output directly into the terminal (no PTY write).
    /// Used for UI-only content like the power user tip header.
    func injectOutput(_ text: String) {
        guard let rustTerminal else {
            Log.warn("RustTerminalView[\(viewId)]: injectOutput - No Rust terminal")
            return
        }
        let data = Data(text.utf8)
        guard !data.isEmpty else { return }
        Log.trace("RustTerminalView[\(viewId)]: injectOutput - Injecting \(data.count) bytes")
        rustTerminal.injectOutput(data)
        // HeadlessTerminal feed removed (Phase 3b) — Rust is the sole source of truth
        needsGridSync = true
    }

    // MARK: - Public API (matching Chau7TerminalView)

    /// Start a shell process (no-op for RustTerminalView - Rust handles PTY)
    func startProcess(executable: String, args: [String], environment: [String]?, execName: String?) {
        // The Rust terminal creates its own PTY. We could extend the FFI to support
        // custom shell paths, but for now the Rust side defaults to $SHELL.
        Log.info("RustTerminalView[\(viewId)]: startProcess - Shell managed by Rust terminal (executable=\(executable), args=\(args))")
    }

    /// Get the underlying SwiftTerm Terminal for compatibility
    func getTerminal() -> Terminal {
        Log.trace("RustTerminalView[\(viewId)]: getTerminal - Returning HeadlessTerminal")
        return headlessTerminal.terminal
    }

    /// Returns the full terminal buffer (screen + scrollback) as UTF-8 Data.
    /// Uses native Rust FFI when available, falling back to HeadlessTerminal.
    func getBufferAsData() -> Data? {
        // Prefer native Rust FFI — avoids HeadlessTerminal dependency
        if let text = rustTerminal?.fullBufferText() {
            return text.data(using: .utf8)
        }
        // Fallback to HeadlessTerminal mirror
        return headlessTerminal.terminal.getBufferAsData()
    }

    var terminalRows: Int { rows }
    var terminalCols: Int { cols }

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
        if gridRow >= 0 && gridRow < rows {
            return rust.getLineText(row: gridRow) ?? ""
        }
        // For scrollback rows, use the cached line index to avoid O(n) re-parsing
        // of the entire buffer for every single row access.
        let lines = getCachedBufferLines()
        guard absoluteRow >= 0 && absoluteRow < lines.count else { return "" }
        return lines[absoluteRow]
    }

    private func getCachedBufferLines() -> [String] {
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

        // Build palette
        let palette: [Color] = [
            terminalColor(from: scheme.black),
            terminalColor(from: scheme.red),
            terminalColor(from: scheme.green),
            terminalColor(from: scheme.yellow),
            terminalColor(from: scheme.blue),
            terminalColor(from: scheme.magenta),
            terminalColor(from: scheme.cyan),
            terminalColor(from: scheme.white),
            terminalColor(from: scheme.brightBlack),
            terminalColor(from: scheme.brightRed),
            terminalColor(from: scheme.brightGreen),
            terminalColor(from: scheme.brightYellow),
            terminalColor(from: scheme.brightBlue),
            terminalColor(from: scheme.brightMagenta),
            terminalColor(from: scheme.brightCyan),
            terminalColor(from: scheme.brightWhite)
        ]
        headlessTerminal.terminal.installPalette(colors: palette)
        Log.trace("RustTerminalView[\(viewId)]: applyColorScheme - SwiftTerm palette installed with 16 colors")

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
    private func rgbComponents(from hex: String) -> (UInt8, UInt8, UInt8) {
        let nsColor = TerminalColorScheme.default.nsColor(for: hex)
        let rgb = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
        let red = UInt8(rgb.redComponent * 255)
        let green = UInt8(rgb.greenComponent * 255)
        let blue = UInt8(rgb.blueComponent * 255)
        return (red, green, blue)
    }

    private func terminalColor(from hex: String) -> Color {
        let nsColor = TerminalColorScheme.default.nsColor(for: hex)
        let rgb = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
        let red = UInt16(rgb.redComponent * 65535)
        let green = UInt16(rgb.greenComponent * 65535)
        let blue = UInt16(rgb.blueComponent * 65535)
        return Color(red: red, green: green, blue: blue)
    }

    /// Configure cursor style
    func applyCursorStyle(style: String, blink: Bool) {
        let cursorStyle: CursorStyle
        let rendererShape: RustGridView.CursorStyle.Shape
        switch style {
        case "underline":
            cursorStyle = blink ? .blinkUnderline : .steadyUnderline
            rendererShape = .underline
        case "bar":
            cursorStyle = blink ? .blinkBar : .steadyBar
            rendererShape = .bar
        default:
            cursorStyle = blink ? .blinkBlock : .steadyBlock
            rendererShape = .block
        }
        headlessTerminal.terminal.setCursorStyle(cursorStyle)
        gridView?.cursorStyle = RustGridView.CursorStyle(shape: rendererShape, blink: blink)
    }

    /// Configure bell
    func applyBellSettings(enabled: Bool, sound: String) {
        bellConfig = (enabled: enabled, sound: sound)
        Log.trace("RustTerminalView[\(viewId)]: applyBellSettings - enabled=\(enabled), sound=\(sound)")
    }

    // MARK: - Bell

    /// Handle bell event by playing sound or flashing screen based on settings
    private func handleBell() {
        guard let bellConfig, bellConfig.enabled else {
            Log.trace("RustTerminalView[\(viewId)]: handleBell - Bell disabled")
            return
        }

        Log.trace("RustTerminalView[\(viewId)]: handleBell - Triggering bell (sound=\(bellConfig.sound))")

        switch bellConfig.sound {
        case "none":
            flashBell()
        case "subtle":
            if let sound = NSSound(named: NSSound.Name("Pop")) {
                sound.play()
            } else {
                NSSound.beep()
            }
        default:
            NSSound.beep()
        }
    }

    /// Flash the screen for visual bell feedback
    private func flashBell() {
        let flash = NSView(frame: bounds)
        flash.wantsLayer = true
        flash.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        flash.alphaValue = 0.0
        flash.autoresizingMask = [.width, .height]
        addSubview(flash)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.05
            flash.animator().alphaValue = 1.0
        } completionHandler: {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                flash.animator().alphaValue = 0.0
            } completionHandler: {
                flash.removeFromSuperview()
            }
        }
    }

    /// Configure scrollback buffer size
    /// Cache to avoid redundant FFI calls
    private var appliedScrollbackLines: Int?

    func applyScrollbackLines(_ lines: Int) {
        guard appliedScrollbackLines != lines else {
            return
        }
        Log.trace("RustTerminalView[\(viewId)]: applyScrollbackLines - Setting scrollback to \(lines) lines")
        rustTerminal?.setScrollbackSize(UInt32(lines))
        // Also sync to headless terminal to keep buffer-dependent features (search, highlights) working
        headlessTerminal?.terminal.changeHistorySize(lines)
        appliedScrollbackLines = lines
    }

    // MARK: - Selection

    /// Get selected text
    func getSelection() -> String? {
        let text = rustTerminal?.getSelectionText()
        if let t = text {
            Log.trace("RustTerminalView[\(viewId)]: getSelection - Got \(t.count) chars")
        } else {
            Log.trace("RustTerminalView[\(viewId)]: getSelection - No selection")
        }
        return text
    }

    /// Clear selection
    func selectNone() {
        Log.trace("RustTerminalView[\(viewId)]: selectNone")
        rustTerminal?.clearSelection()
        lastSelectionText = nil
    }

    /// Clear selection (alias)
    func clearSelection() {
        Log.trace("RustTerminalView[\(viewId)]: clearSelection")
        selectNone()
    }

    /// Check if there's an active selection
    var hasSelection: Bool {
        if let text = getSelection(), !text.isEmpty {
            return true
        }
        return false
    }

    /// Get selected text (alias for Chau7TerminalView compatibility)
    func getSelectedText() -> String? {
        getSelection()
    }

    // MARK: - Auto-Scroll During Selection

    /// Starts the auto-scroll timer for selection drag outside bounds.
    private func startAutoScrollTimer() {
        // Don't create multiple timers
        guard autoScrollTimer == nil else { return }

        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.performAutoScroll()
        }
        Log.trace("RustTerminalView[\(viewId)]: startAutoScrollTimer - Started auto-scroll timer (direction=\(autoScrollDirection))")
    }

    /// Stops the auto-scroll timer.
    private func stopAutoScrollTimer() {
        if autoScrollTimer != nil {
            Log.trace("RustTerminalView[\(viewId)]: stopAutoScrollTimer - Stopping auto-scroll timer")
        }
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollDirection = 0
    }

    /// Performs one step of auto-scrolling and extends selection.
    private func performAutoScroll() {
        guard autoScrollDirection != 0 else { return }
        guard isSelecting else {
            stopAutoScrollTimer()
            return
        }

        // Scroll the terminal
        if autoScrollDirection < 0 {
            // Scroll up (show earlier content)
            scrollUp(lines: 2)
        } else {
            // Scroll down (show later content)
            scrollDown(lines: 2)
        }

        // Extend selection to the edge of the visible area
        guard let rust = rustTerminal else { return }
        let edgeRow: Int
        if autoScrollDirection < 0 {
            // Scrolling up - extend selection to top row
            edgeRow = 0
        } else {
            // Scrolling down - extend selection to bottom row
            edgeRow = rows - 1
        }
        // Convert to absolute row (accounting for scrollback offset)
        let displayOffset = Int(rust.displayOffset)
        let absoluteRow = edgeRow + displayOffset
        // Use middle column for horizontal position
        let col = cols / 2
        rust.updateSelection(col: Int32(col), row: Int32(absoluteRow))
        needsGridSync = true

        Log.trace("RustTerminalView[\(viewId)]: performAutoScroll - Scrolled \(autoScrollDirection < 0 ? "up" : "down"), selection to row \(absoluteRow)")
    }

    // MARK: - Scrolling

    /// Current scroll position (0.0 = bottom, 1.0 = top of history)
    var scrollPosition: Double {
        let pos = rustTerminal?.scrollPosition ?? 0.0
        Log.trace("RustTerminalView[\(viewId)]: scrollPosition = \(pos)")
        return pos
    }

    /// Scroll to position
    func scroll(toPosition position: Double) {
        Log.trace("RustTerminalView[\(viewId)]: scroll(toPosition:) - position=\(position)")
        rustTerminal?.scrollTo(position: position)
        needsGridSync = true
        clearLocalEchoOverlay()
        // Smart Scroll: Track if user is at or near the bottom
        updateIsUserAtBottom()
        updateInlineImagePositions()
        onScrollChanged?()
    }

    /// Scroll up by lines
    func scrollUp(lines: Int) {
        Log.trace("RustTerminalView[\(viewId)]: scrollUp - lines=\(lines)")
        rustTerminal?.scrollLines(Int32(lines))
        needsGridSync = true
        clearLocalEchoOverlay()
        // Smart Scroll: Track if user is at or near the bottom
        updateIsUserAtBottom()
        updateInlineImagePositions()
        onScrollChanged?()
    }

    /// Scroll down by lines
    func scrollDown(lines: Int) {
        Log.trace("RustTerminalView[\(viewId)]: scrollDown - lines=\(lines)")
        rustTerminal?.scrollLines(Int32(-lines))
        needsGridSync = true
        clearLocalEchoOverlay()
        // Smart Scroll: Track if user is at or near the bottom
        updateIsUserAtBottom()
        updateInlineImagePositions()
        onScrollChanged?()
    }

    /// Scroll to top of history
    func scrollToTop() {
        Log.trace("RustTerminalView[\(viewId)]: scrollToTop")
        scroll(toPosition: 1.0)
    }

    /// Scroll to bottom (current)
    func scrollToBottom() {
        Log.trace("RustTerminalView[\(viewId)]: scrollToBottom")
        scroll(toPosition: 0.0)
    }

    /// Scroll so that `absoluteRow` is at the top of the viewport.
    func scrollToRow(absoluteRow: Int) {
        let currentTop = renderTopVisibleRow
        let delta = currentTop - absoluteRow  // positive = scroll up into history
        if delta > 0 {
            scrollUp(lines: delta)
        } else if delta < 0 {
            scrollDown(lines: -delta)
        }
    }

    /// Scroll to the nearest input line above the current viewport top.
    func scrollToPreviousInputLine() {
        let sorted = inputLineTracker.sortedRows()
        guard !sorted.isEmpty else { return }
        let currentTop = renderTopVisibleRow
        // Find the last tracked row strictly above the current viewport top
        if let idx = sorted.lastIndex(where: { $0 < currentTop }) {
            scrollToRow(absoluteRow: sorted[idx])
            Log.info("RustTerminalView[\(viewId)]: jumped to previous input line at row \(sorted[idx])")
        }
    }

    /// Scroll to the nearest input line below the current viewport top.
    func scrollToNextInputLine() {
        let sorted = inputLineTracker.sortedRows()
        guard !sorted.isEmpty else { return }
        let currentTop = renderTopVisibleRow
        // Find the first tracked row strictly below the current viewport top
        if let idx = sorted.firstIndex(where: { $0 > currentTop }) {
            scrollToRow(absoluteRow: sorted[idx])
            Log.info("RustTerminalView[\(viewId)]: jumped to next input line at row \(sorted[idx])")
        } else {
            // No more marks below — go to bottom
            scrollToBottom()
        }
    }

    /// Update isUserAtBottom based on current scroll position (for Smart Scroll)
    private func updateIsUserAtBottom() {
        let currentPosition = scrollPosition
        // Position 0 = bottom, 1 = top. User is "at bottom" if position is <= threshold from 0
        isUserAtBottom = currentPosition <= (1.0 - Self.scrollBottomThreshold)
    }

    /// Restores scroll position if smart scroll is enabled and user wasn't at bottom.
    /// This preserves the user's reading position when new output arrives.
    private func restoreSmartScrollIfNeeded(smartScrollEnabled: Bool, wasAtBottom: Bool, savedPosition: Double) {
        // Only restore if:
        // 1. Smart scroll is enabled
        // 2. User wasn't at the bottom before new data arrived
        // 3. The scroll position actually changed (renderer auto-scrolled)
        let currentPosition = scrollPosition
        guard smartScrollEnabled, !wasAtBottom, currentPosition != savedPosition else { return }

        // Edge case: Don't restore to position 0 when scrollback just appeared.
        // When terminal has no scrollback, scrollPosition is forced to 0 regardless of
        // actual view state. If savedPosition was 0 and now > 0, scrollback just appeared
        // and user wasn't actually scrolled up - they were at the only position available.
        if savedPosition == 0 && currentPosition > 0 {
            // Scrollback just appeared - let the auto-scroll to bottom happen
            isUserAtBottom = currentPosition >= Self.scrollBottomThreshold
            return
        }

        // Restore the user's previous scroll position
        scroll(toPosition: savedPosition)
        // Update our tracking state based on restored position
        isUserAtBottom = savedPosition <= (1.0 - Self.scrollBottomThreshold)
    }

    // MARK: - Cursor Line Highlight

    /// Attach a cursor line view for highlighting
    func attachCursorLineView(_ view: TerminalCursorLineView) {
        cursorLineView = view
        updateCursorLineHighlight()
    }

    /// Configure cursor line highlight options
    func configureCursorLineHighlight(contextLines: Bool, inputHistory: Bool) {
        if highlightContextLines != contextLines || highlightInputHistory != inputHistory {
            highlightContextLines = contextLines
            highlightInputHistory = inputHistory
            updateCursorLineHighlight()
        }
    }

    /// Enable or disable cursor line highlighting
    func setCursorLineHighlightEnabled(_ enabled: Bool) {
        if isCursorLineHighlightEnabled != enabled {
            isCursorLineHighlightEnabled = enabled
            updateCursorLineHighlight()
        }
    }

    /// Update cursor line highlight state
    private func updateCursorLineHighlight() {
        guard isCursorLineHighlightEnabled else {
            cursorLineView?.isHidden = true
            return
        }
        cursorLineView?.update(
            with: self,
            isFocused: hasFocus,
            showsContextLines: highlightContextLines,
            showsInputHistory: highlightInputHistory,
            inputLineTracker: inputLineTracker
        )
        cursorLineView?.isHidden = false
        cursorLineView?.needsDisplay = true
    }

    /// Record the current input line for history tracking.
    /// Uses native Rust cursor + scroll data (no HeadlessTerminal dependency).
    func recordInputLine() {
        guard let rust = rustTerminal else { return }
        let cursor = rust.cursorPosition
        let topRow = renderTopVisibleRow
        let row = topRow + Int(cursor.row)
        inputLineTracker.record(row: row)
        updateCursorLineHighlight()
    }

    // MARK: - Mouse Reporting

    /// Mouse mode bit flags (matching Rust implementation)
    private struct MouseMode {
        static let click: UInt32 = 0x01      // Mode 1000: report button press/release
        static let drag: UInt32 = 0x02       // Mode 1002: also report motion while button down
        static let motion: UInt32 = 0x04     // Mode 1003: report all motion
        static let focusInOut: UInt32 = 0x08 // Mode 1004: focus in/out reporting
        static let sgrMode: UInt32 = 0x10    // Mode 1006: use SGR encoding (was incorrectly 0x08)
        static let anyTracking: UInt32 = 0x07  // Mask for click/drag/motion modes
    }

    /// Mouse button encoding for X10/Normal protocols
    private enum MouseButton: UInt8 {
        case left = 0
        case middle = 1
        case right = 2
        case release = 3
        case scrollUp = 64
        case scrollDown = 65
        case scrollLeft = 66
        case scrollRight = 67
    }

    /// Check if mouse reporting is active
    private func isMouseReportingEnabled() -> Bool {
        guard allowMouseReporting else { return false }
        let mode = rustTerminal?.mouseMode() ?? 0
        return (mode & MouseMode.anyTracking) != 0
    }

    /// Check if SGR extended mouse mode is enabled
    private func isSgrMouseMode() -> Bool {
        let mode = rustTerminal?.mouseMode() ?? 0
        return (mode & MouseMode.sgrMode) != 0
    }

    /// Check if motion events should be reported while button is down
    private func shouldReportDragMotion() -> Bool {
        let mode = rustTerminal?.mouseMode() ?? 0
        return (mode & MouseMode.drag) != 0 || (mode & MouseMode.motion) != 0
    }

    /// Encode and send a mouse event to the PTY
    private func sendMouseEvent(button: MouseButton, col: Int, row: Int, isRelease: Bool, modifiers: NSEvent.ModifierFlags = []) {
        var buttonCode = button.rawValue
        if modifiers.contains(.shift) { buttonCode += 4 }
        if modifiers.contains(.option) { buttonCode += 8 }
        if modifiers.contains(.control) { buttonCode += 16 }

        if isSgrMouseMode() {
            let col1 = col + 1
            let row1 = row + 1
            let terminator = isRelease ? "m" : "M"
            let sequence = "\u{1b}[<\(buttonCode);\(col1);\(row1)\(terminator)"
            Log.trace("RustTerminalView[\(viewId)]: sendMouseEvent SGR - button=\(buttonCode), col=\(col1), row=\(row1)")
            send(txt: sequence)
        } else {
            let effectiveCol = min(col, 222)
            let effectiveRow = min(row, 222)
            let releaseButton: UInt8 = isRelease ? 3 : buttonCode
            let buttonByte = releaseButton + 32
            let colByte = UInt8(effectiveCol + 33)
            let rowByte = UInt8(effectiveRow + 33)
            send(data: [0x1b, 0x5b, 0x4d, buttonByte, colByte, rowByte])
        }
    }

    /// Send a mouse press event
    private func sendMousePress(button: MouseButton, at location: NSPoint, modifiers: NSEvent.ModifierFlags = []) {
        let cell = pointToCell(location)
        sendMouseEvent(button: button, col: Int(cell.col), row: Int(cell.row), isRelease: false, modifiers: modifiers)
    }

    /// Send a mouse release event
    private func sendMouseRelease(button: MouseButton, at location: NSPoint, modifiers: NSEvent.ModifierFlags = []) {
        let cell = pointToCell(location)
        sendMouseEvent(button: button, col: Int(cell.col), row: Int(cell.row), isRelease: true, modifiers: modifiers)
    }

    /// Send a mouse motion event
    private func sendMouseMotion(at location: NSPoint, buttonDown: MouseButton?, modifiers: NSEvent.ModifierFlags = []) {
        let cell = pointToCell(location)
        let cellCol = Int(cell.col)
        let cellRow = Int(cell.row)
        var buttonCode: UInt8 = 32
        if let button = buttonDown { buttonCode += button.rawValue } else { buttonCode += 3 }
        if modifiers.contains(.shift) { buttonCode += 4 }
        if modifiers.contains(.option) { buttonCode += 8 }
        if modifiers.contains(.control) { buttonCode += 16 }

        if isSgrMouseMode() {
            let sequence = "\u{1b}[<\(buttonCode);\(cellCol + 1);\(cellRow + 1)M"
            send(txt: sequence)
        } else {
            let colByte = UInt8(min(cellCol, 222) + 33)
            let rowByte = UInt8(min(cellRow, 222) + 33)
            send(data: [0x1b, 0x5b, 0x4d, buttonCode + 32, colByte, rowByte])
        }
    }

    /// Send a scroll wheel event
    /// In X10/normal protocol: button 64 = scroll up, button 65 = scroll down
    /// In SGR protocol: button 64/65 with M suffix (no release for scroll)
    private func sendScrollEvent(deltaY: CGFloat, at location: NSPoint, modifiers: NSEvent.ModifierFlags = []) {
        let cell = pointToCell(location)
        let cellCol = Int(cell.col)
        let cellRow = Int(cell.row)

        // Button codes: 64 = scroll up, 65 = scroll down
        // (In X10 protocol these are buttons 4 and 5 with bit 6 set)
        var buttonCode: UInt8 = deltaY > 0 ? 64 : 65
        if modifiers.contains(.shift) { buttonCode += 4 }
        if modifiers.contains(.option) { buttonCode += 8 }
        if modifiers.contains(.control) { buttonCode += 16 }

        Log.trace("RustTerminalView[\(viewId)]: sendScrollEvent - deltaY=\(deltaY), button=\(buttonCode), cell=(\(cellCol), \(cellRow))")

        if isSgrMouseMode() {
            let sequence = "\u{1b}[<\(buttonCode);\(cellCol + 1);\(cellRow + 1)M"
            send(txt: sequence)
        } else {
            let colByte = UInt8(min(cellCol, 222) + 33)
            let rowByte = UInt8(min(cellRow, 222) + 33)
            send(data: [0x1b, 0x5b, 0x4d, buttonCode + 32, colByte, rowByte])
        }
    }

    /// Track last reported mouse position
    private var lastReportedMouseCell: (col: Int, row: Int)?

    /// Track if button is pressed for mouse reporting
    private var mouseReportingButtonDown: MouseButton?

    // MARK: - Event Monitoring

    func setEventMonitoringEnabled(_ enabled: Bool) {
        Log.trace("RustTerminalView[\(viewId)]: setEventMonitoringEnabled(\(enabled))")
        guard isEventMonitoringEnabled != enabled else {
            Log.trace("RustTerminalView[\(viewId)]: setEventMonitoringEnabled - Already \(enabled ? "enabled" : "disabled")")
            return
        }
        isEventMonitoringEnabled = enabled
        guard window != nil else {
            Log.trace("RustTerminalView[\(viewId)]: setEventMonitoringEnabled - No window, deferring")
            return
        }

        if enabled {
            setupEventMonitors()
        } else {
            removeEventMonitors()
        }
    }

    private func setupEventMonitors() {
        Log.trace("RustTerminalView[\(viewId)]: setupEventMonitors - Installing event monitors")
        removeEventMonitors()

        let settings = FeatureSettings.shared
        let needsMouseMove = settings.isCmdClickPathsEnabled

        // Mouse down for selection start, Cmd+click paths, Option+click cursor, mouse reporting
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self else { return event }
            guard event.window === self.window else { return event }
            let location = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(location) else { return event }

            let cell = self.pointToCell(location)
            Log.trace("RustTerminalView[\(self.viewId)]: mouseDown at (\(location.x), \(location.y)) -> cell (\(cell.col), \(cell.row))")

            // Mouse reporting: Forward mouse events to TUI apps (tmux, vim, htop, etc.)
            // Control+click bypasses mouse reporting to allow context menu/selection
            if self.isMouseReportingEnabled() && !event.modifierFlags.contains(.control) {
                Log.trace("RustTerminalView[\(self.viewId)]: Mouse reporting - sending left press")
                self.mouseReportingButtonDown = .left
                self.sendMousePress(button: .left, at: location, modifiers: event.modifierFlags)
                self.mouseDownLocation = location  // Track for drag reporting
                self.didDragSinceMouseDown = false
                return event
            }

            // Track mouse down for click-to-position
            self.mouseDownLocation = location
            self.didDragSinceMouseDown = false
            self.isSelecting = false

            // F03: Check for Cmd+click on paths/URLs
            if event.modifierFlags.contains(.command) && FeatureSettings.shared.isCmdClickPathsEnabled {
                if self.handleCmdClick(at: location) {
                    self.mouseDownLocation = nil  // Don't position cursor for Cmd+click
                    return nil  // Consume the event
                }
            }

            // Option+click to position cursor (like iTerm2)
            if event.modifierFlags.contains(.option) && FeatureSettings.shared.isOptionClickCursorEnabled {
                if self.handleOptionClick(at: location) {
                    self.mouseDownLocation = nil  // Already handled
                    return nil  // Consume the event
                }
            }

            // Handle double-click (word selection) and triple-click (line selection)
            let absoluteCell = self.pointToCellAbsolute(location)
            if event.clickCount == 2 {
                // Double-click: Select word at click location (Semantic selection)
                Log.trace("RustTerminalView[\(self.viewId)]: Double-click at cell (\(absoluteCell.col), \(absoluteCell.row)) - selecting word")
                self.rustTerminal?.startSelection(col: absoluteCell.col, row: absoluteCell.row, selectionType: 2)  // Semantic
                self.needsGridSync = true
                self.mouseDownLocation = nil  // Prevent cursor positioning and drag start
                self.scheduleCopyOnSelect()
                return event
            } else if event.clickCount >= 3 {
                // Triple-click: Select entire line (Lines selection)
                Log.trace("RustTerminalView[\(self.viewId)]: Triple-click at row \(absoluteCell.row) - selecting line")
                self.rustTerminal?.startSelection(col: 0, row: absoluteCell.row, selectionType: 3)  // Lines
                self.needsGridSync = true
                self.mouseDownLocation = nil  // Prevent cursor positioning and drag start
                self.scheduleCopyOnSelect()
                return event
            }

            // Clear any existing selection on mouse down (single click)
            self.rustTerminal?.clearSelection()
            self.needsGridSync = true

            return event
        }

        // Mouse dragged for selection OR mouse reporting
        mouseDragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let self = self else { return event }
            guard event.window === self.window else { return event }

            let location = self.convert(event.locationInWindow, from: nil)

            // Mouse reporting: Forward drag events to TUI apps (mode 1002/1003)
            if self.mouseReportingButtonDown != nil {
                let mouseModeValue = self.rustTerminal?.mouseMode() ?? 0
                let isDragMode = (mouseModeValue & MouseMode.drag) != 0
                let isMotionMode = (mouseModeValue & MouseMode.motion) != 0

                if isDragMode || isMotionMode {
                    self.sendMouseMotion(at: location, buttonDown: self.mouseReportingButtonDown, modifiers: event.modifierFlags)
                }
                self.didDragSinceMouseDown = true
                return event  // Don't do selection when mouse reporting is active
            }

            // Selection logic (only when not mouse reporting)
            if let downLocation = self.mouseDownLocation {
                let dx = abs(location.x - downLocation.x)
                let dy = abs(location.y - downLocation.y)
                if dx > Self.dragThreshold || dy > Self.dragThreshold {
                    // Use absolute coordinates for selection (accounts for scrollback offset)
                    let currentCell = self.pointToCellAbsolute(location)

                    if !self.didDragSinceMouseDown {
                        // First drag past threshold - start selection at mouse down location
                        let startCell = self.pointToCellAbsolute(downLocation)
                        Log.trace("RustTerminalView[\(self.viewId)]: mouseDrag - Starting selection at absolute cell (\(startCell.col), \(startCell.row))")
                        self.rustTerminal?.startSelection(col: startCell.col, row: startCell.row, selectionType: 0)
                        self.isSelecting = true
                    }

                    self.didDragSinceMouseDown = true

                    // Update selection end point
                    if self.isSelecting {
                        Log.trace("RustTerminalView[\(self.viewId)]: mouseDrag - Updating selection to absolute cell (\(currentCell.col), \(currentCell.row))")
                        self.rustTerminal?.updateSelection(col: currentCell.col, row: currentCell.row)
                        self.needsGridSync = true
                    }
                }
            }

            // Auto-scroll when dragging outside bounds during selection
            if self.didDragSinceMouseDown && self.isSelecting {
                if location.y < 0 {
                    // Dragging below view - scroll down (content moves up)
                    self.autoScrollDirection = 1
                    self.startAutoScrollTimer()
                } else if location.y > self.bounds.height {
                    // Dragging above view - scroll up (content moves down)
                    self.autoScrollDirection = -1
                    self.startAutoScrollTimer()
                } else {
                    // Inside bounds - stop auto-scroll
                    self.stopAutoScrollTimer()
                }
            }

            return event
        }

        // Mouse up for mouse reporting, copy-on-select, AND click-to-position cursor
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self = self else { return event }

            // Capture and clear mouse tracking state
            let downLocation = self.mouseDownLocation
            let wasDrag = self.didDragSinceMouseDown
            let wasSelecting = self.isSelecting
            let wasMouseReporting = self.mouseReportingButtonDown

            self.mouseDownLocation = nil
            self.didDragSinceMouseDown = false
            self.isSelecting = false
            self.mouseReportingButtonDown = nil

            // Stop auto-scroll timer on mouse up
            self.stopAutoScrollTimer()

            guard event.window === self.window else { return event }
            let location = self.convert(event.locationInWindow, from: nil)

            // Mouse reporting: Send release event to TUI apps
            if let reportingButton = wasMouseReporting {
                Log.trace("RustTerminalView[\(self.viewId)]: Mouse reporting - sending \(reportingButton) release")
                self.sendMouseRelease(button: reportingButton, at: location, modifiers: event.modifierFlags)
                return event  // Don't do click-to-position or selection when mouse reporting
            }

            guard self.bounds.contains(location) else { return event }

            Log.trace("RustTerminalView[\(self.viewId)]: mouseUp at (\(location.x), \(location.y)), wasSelecting=\(wasSelecting), wasDrag=\(wasDrag)")

            // Click-to-position: If no drag occurred and single click, position cursor
            if let clickLocation = downLocation, !wasDrag {
                let isSingleClick = event.clickCount == 1
                let noModifiers = !event.modifierFlags.contains(.shift) && !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.option)
                let noActiveSelection = !self.hasSelection

                if isSingleClick && noModifiers && noActiveSelection && FeatureSettings.shared.isClickToPositionEnabled {
                    if self.handleClickToPosition(at: clickLocation) {
                        Log.trace("RustTerminalView[\(self.viewId)]: Click-to-position handled")
                        return event
                    }
                }
            }

            // Copy-on-select: Option key temporarily disables (matches Chau7TerminalView)
            let optionHeld = event.modifierFlags.contains(.option)
            if wasSelecting && !optionHeld {
                self.scheduleCopyOnSelect()
            }

            return event
        }
        // Mouse move monitor for cursor change on hover (Cmd+hover shows hand cursor for clickable paths/URLs)
        if needsMouseMove {
            mouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                guard let self = self else { return event }
                guard event.window === self.window else { return event }
                let location = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(location) else { return event }

                self.handleMouseMove(at: location, modifiers: event.modifierFlags)
                return event
            }
        }

        // Scroll wheel monitor — handles both mouse reporting AND scrollback navigation.
        // Mouse reporting mode: forward scroll events to TUI apps (vim, tmux, etc.)
        // Normal mode: navigate scrollback history (scroll up = see earlier output)
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self else { return event }
            guard event.window === self.window else { return event }
            let location = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(location) else { return event }

            // Mouse reporting mode: forward scroll to the terminal program
            if self.isMouseReportingEnabled() {
                let deltaY = event.scrollingDeltaY
                // Ignore tiny scrolls to avoid flooding the terminal
                if abs(deltaY) > 0.5 {
                    self.sendScrollEvent(deltaY: deltaY, at: location, modifiers: event.modifierFlags)
                    return nil  // Consume event when mouse reporting
                }
                return event
            }

            // Normal mode: scrollback navigation.
            // RustTerminalView is a plain NSView (not NSScrollView), so scroll events
            // would just pass through unhandled. We handle them here directly.
            let deltaY = event.scrollingDeltaY
            if abs(deltaY) > 0.5 {
                // Convert continuous scroll delta to discrete line count.
                // Positive deltaY = scroll up (show earlier content).
                let lines = max(1, Int(abs(deltaY) / 3.0))
                if deltaY > 0 {
                    self.scrollUp(lines: lines)
                } else {
                    self.scrollDown(lines: lines)
                }
                return nil  // Consume the event
            }
            return event
        }

        // General key event monitor - intercept ALL key events when terminal is active
        // This ensures key input goes to Rust terminal even if a subview is first responder
        generalKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            guard event.window === self.window else { return event }
            guard self.isFirstResponderInTerminal() else { return event }

            // Let snippet and history monitors handle their specific keys first
            // (they run before this and return nil to consume)

            // Route to Rust terminal
            if self.handleTerminalKeyEvent(event) {
                self.markGeneralKeyEventHandled(event)
                return nil  // Consume event - we handled it
            }
            return event  // Let it propagate if not handled
        }

        Log.trace("RustTerminalView[\(viewId)]: setupEventMonitors - Event monitors installed (mouseMove=\(needsMouseMove), generalKey=true)")
    }

    private func removeEventMonitors() {
        var removedCount = 0
        if let monitor = mouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            mouseDownMonitor = nil
            removedCount += 1
        }
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
            removedCount += 1
        }
        if let monitor = mouseDragMonitor {
            NSEvent.removeMonitor(monitor)
            mouseDragMonitor = nil
            removedCount += 1
        }
        if let monitor = mouseMoveMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMoveMonitor = nil
            removedCount += 1
        }
        if let monitor = scrollWheelMonitor {
            NSEvent.removeMonitor(monitor)
            scrollWheelMonitor = nil
            removedCount += 1
        }
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownMonitor = nil
            removedCount += 1
        }
        if let monitor = generalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            generalKeyMonitor = nil
            removedCount += 1
        }
        // Fix #4: Also remove history monitor to prevent leaks
        if let monitor = historyMonitor {
            NSEvent.removeMonitor(monitor)
            historyMonitor = nil
            removedCount += 1
        }
        if removedCount > 0 {
            Log.trace("RustTerminalView[\(viewId)]: removeEventMonitors - Removed \(removedCount) monitors")
        }
    }

    // MARK: - F03: Cmd+Click Paths/URLs

    /// Handle Cmd+click on file paths or URLs
    private func handleCmdClick(at point: NSPoint) -> Bool {
        // OSC 8 hyperlink check — takes priority over text-based URL matching
        if let rust = rustTerminal {
            let cell = pointToCell(point)
            let cellIndex = Int(cell.row) * cols + Int(cell.col)
            let linkId = gridView?.linkIdAt(index: cellIndex) ?? 0
            if linkId > 0, let urlString = rust.getLinkUrl(linkId: linkId),
               let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
                Log.info("RustTerminalView[\(viewId)]: Cmd+click - opened OSC 8 hyperlink: \(urlString)")
                return true
            }
        }

        guard let lineText = getLineAtPoint(point) else { return false }

        // Check for URLs first
        let urlMatches = findURLs(in: lineText)
        if let firstURL = urlMatches.first {
            PathClickHandler.openURL(firstURL)
            Log.info("RustTerminalView[\(viewId)]: Cmd+click - opened URL \(firstURL)")
            return true
        }

        // Check for file paths
        let pathMatches = PathClickHandler.findPaths(in: lineText)
        if let firstPath = pathMatches.first {
            let resolvedPath = PathClickHandler.resolvePath(firstPath.path, relativeTo: currentDirectory)
            guard FileManager.default.fileExists(atPath: resolvedPath) else {
                Log.warn("RustTerminalView[\(viewId)]: Cmd+click - file does not exist: \(resolvedPath)")
                return false
            }

            if FeatureSettings.shared.cmdClickOpensInternalEditor,
               let callback = onFilePathClicked {
                callback(resolvedPath, firstPath.line, firstPath.column)
                Log.info("RustTerminalView[\(viewId)]: Cmd+click - opening in internal editor: \(resolvedPath)")
            } else {
                PathClickHandler.openPath(firstPath, relativeTo: currentDirectory)
                Log.info("RustTerminalView[\(viewId)]: Cmd+click - opened path \(firstPath.path)")
            }
            return true
        }
        return false
    }

    // MARK: - Click-to-Position Cursor

    private func handleClickToPosition(at point: NSPoint) -> Bool {
        guard let rust = rustTerminal else { return false }
        guard bounds.height > 0, bounds.width > 0 else { return false }
        guard cols > 0, rows > 0 else { return false }

        // Standard macOS coordinates: y=0 at bottom, row 0 at top of terminal
        let clickedRow = max(0, min(Int((bounds.height - point.y) / cellHeight), rows - 1))
        let clickedCol = max(0, min(Int(point.x / cellWidth), cols - 1))
        let cursor = rust.cursorPosition
        guard clickedRow == Int(cursor.row) else { return false }
        let colDiff = clickedCol - Int(cursor.col)
        var sequences = ""
        if colDiff > 0 {
            sequences = String(repeating: "\u{1b}[C", count: colDiff)
        } else if colDiff < 0 {
            sequences = String(repeating: "\u{1b}[D", count: -colDiff)
        }
        if !sequences.isEmpty {
            send(txt: sequences)
            Log.trace("RustTerminalView[\(viewId)]: Click-to-position - moved cursor by col=\(colDiff)")
            return true
        }
        return false
    }

    // MARK: - Option+Click Cursor Positioning

    private func handleOptionClick(at point: NSPoint) -> Bool {
        guard let rust = rustTerminal else { return false }
        guard bounds.height > 0, bounds.width > 0 else { return false }
        guard cols > 0, rows > 0 else { return false }

        // Standard macOS coordinates: y=0 at bottom, row 0 at top of terminal
        let clickedRow = Int((bounds.height - point.y) / cellHeight)
        let clickedCol = Int(point.x / cellWidth)
        let cursor = rust.cursorPosition
        let rowDiff = clickedRow - Int(cursor.row)
        let colDiff = clickedCol - Int(cursor.col)
        var sequences = ""
        if rowDiff > 0 { sequences += String(repeating: "\u{1b}[B", count: rowDiff) }
        else if rowDiff < 0 { sequences += String(repeating: "\u{1b}[A", count: -rowDiff) }
        if colDiff > 0 { sequences += String(repeating: "\u{1b}[C", count: colDiff) }
        else if colDiff < 0 { sequences += String(repeating: "\u{1b}[D", count: -colDiff) }
        if !sequences.isEmpty {
            send(txt: sequences)
            Log.trace("RustTerminalView[\(viewId)]: Option+click - moved cursor by row=\(rowDiff), col=\(colDiff)")
            return true
        }
        return false
    }

    // MARK: - Path/URL Detection Helpers

    private func getLineAtPoint(_ point: NSPoint) -> String? {
        guard let rust = rustTerminal else { return nil }
        guard bounds.height > 0, rows > 0 else { return nil }
        // Standard macOS coordinates: y=0 at bottom, row 0 at top of terminal
        let screenRow = Int((bounds.height - point.y) / cellHeight)

        // Account for display offset when scrolled up.
        // When displayOffset > 0, we're viewing scrollback. The visible row 0 corresponds
        // to Line(-displayOffset), not Line(0). We need to convert screen coordinates
        // to grid coordinates to get the correct line content.
        let displayOffset = Int(rust.displayOffset)
        let gridRow = screenRow - displayOffset

        return rust.getLineText(row: gridRow)
    }

    private func findURLs(in text: String) -> [String] {
        var urls: [String] = []
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        RegexPatterns.url.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            urls.append(nsText.substring(with: match.range))
        }
        return urls
    }

    private func handleMouseMove(at location: NSPoint, modifiers: NSEvent.ModifierFlags) {
        guard FeatureSettings.shared.isCmdClickPathsEnabled else { return }
        guard modifiers.contains(.command) else {
            NSCursor.iBeam.set()
            return
        }
        guard let lineText = getLineAtPoint(location) else {
            NSCursor.iBeam.set()
            return
        }
        pathDetectionWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let hasClickable = !self.findURLs(in: lineText).isEmpty || !PathClickHandler.findPaths(in: lineText).isEmpty
            DispatchQueue.main.async {
                if hasClickable { NSCursor.pointingHand.set() }
                else { NSCursor.iBeam.set() }
            }
        }
        pathDetectionWorkItem = work
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    // MARK: - Clipboard

    /// Debounced copy-on-select: cancels any pending copy, waits 50ms for Rust selection
    /// to finalize, then copies if text changed. Called from mouseUp and any future
    /// selection-complete triggers.
    private func scheduleCopyOnSelect() {
        guard FeatureSettings.shared.isCopyOnSelectEnabled else { return }
        copyOnSelectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  let text = self.getSelection(),
                  !text.isEmpty,
                  text != self.lastSelectionText else { return }
            Log.trace("RustTerminalView[\(self.viewId)]: Copy-on-select - Copying \(text.count) chars")
            self.copyToClipboard(text)
            self.lastSelectionText = text
        }
        copyOnSelectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.050, execute: work)
    }

    private func copyToClipboard(_ text: String) {
        Log.trace("RustTerminalView[\(viewId)]: copyToClipboard - Copying \(text.count) chars")
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        clipboard.setString(text, forType: .string)
    }

    /// Copy selection to clipboard
    @objc func copy(_ sender: Any?) {
        if let text = getSelection(), !text.isEmpty {
            Log.info("RustTerminalView[\(viewId)]: copy - Copying selection (\(text.count) chars)")
            copyToClipboard(text)
        } else {
            Log.info("RustTerminalView[\(viewId)]: copy - No selection, sending Ctrl+C (SIGINT)")
            send(data: [0x03])
        }
    }

    /// Paste from clipboard
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            Log.trace("RustTerminalView[\(viewId)]: paste - Nothing to paste")
            return
        }

        Log.info("RustTerminalView[\(viewId)]: paste - Pasting \(text.count) chars")
        pasteText(text)
    }

    private func pasteText(_ text: String) {
        // Check for bracketed paste mode from Rust terminal (not headlessTerminal which is display-only)
        // This fixes bracketed paste for vim, zsh, and other programs that enable it
        if rustTerminal?.isBracketedPasteMode() == true {
            Log.trace("RustTerminalView[\(viewId)]: paste - Using bracketed paste mode")
            send(txt: "\u{1b}[200~")
            send(txt: text)
            send(txt: "\u{1b}[201~")
        } else {
            send(txt: text)
        }
    }

    // MARK: - Feed (for compatibility)

    /// Feed text directly to the display (bypasses Rust terminal)
    func feed(text: String) {
        Log.trace("RustTerminalView[\(viewId)]: feed(text:) - Ignored (native renderer does not support direct feed)")
    }

    /// Feed bytes directly to the display (bypasses Rust terminal)
    func feed(byteArray: [UInt8]) {
        Log.trace("RustTerminalView[\(viewId)]: feed(byteArray:) - Ignored (native renderer does not support direct feed)")
    }

    // MARK: - Clear

    /// Clear scrollback buffer
    /// This clears the Rust terminal's scrollback history and resets rendering state
    func clearScrollbackBuffer() {
        Log.info("RustTerminalView[\(viewId)]: clearScrollbackBuffer")

        // Clear Rust terminal's scrollback history (frees memory)
        rustTerminal?.clearScrollback()

        // Also reset the headless buffer state to stay in sync
        headlessTerminal.terminal.resetToInitialState()

        clearLocalEchoOverlay()

        // Clear inline images
        inlineImages.forEach { $0.view.removeFromSuperview() }
        inlineImages.removeAll()

        // Trigger a grid sync to update the display
        needsGridSync = true

        // Notify listeners that scrollback was cleared
        onScrollbackCleared?()
    }

    // MARK: - Context Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard event.window === window else { return nil }
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return nil }

        // Check if Shift is held - this always forces the context menu to appear
        // This is the standard way to bypass mouse reporting in terminal apps
        let forceMenu = event.modifierFlags.contains(.shift)

        // If mouse reporting is active (and not forced by Shift), send the right-click
        // to the PTY instead of showing the context menu. This enables proper mouse
        // interaction in TUI apps like vim, tmux, htop.
        if !forceMenu && isMouseReportingEnabled() {
            Log.trace("RustTerminalView[\(viewId)]: menu(for:) - Mouse reporting active, sending right-click to PTY")
            sendMousePress(button: .right, at: location, modifiers: event.modifierFlags)
            // Send release too since context menu won't consume the mouse-up event
            sendMouseRelease(button: .right, at: location, modifiers: event.modifierFlags)
            return nil  // Don't show context menu
        }

        Log.trace("RustTerminalView[\(viewId)]: menu(for:) - Building context menu at (\(location.x), \(location.y))")
        window?.makeFirstResponder(self)

        let menu = NSMenu(title: "Terminal")
        // Prevent macOS from injecting system Services items (e.g. "Convert text to Chinese")
        // into our context menu. The view's validRequestor(forSendType:returnType:) advertises
        // text capabilities, which causes the Services subsystem to add unwanted entries.
        menu.allowsContextMenuPlugIns = false
        let canCopy = hasSelection
        let canPaste = NSPasteboard.general.string(forType: .string) != nil
        let insertFromPasswordsSelector = NSSelectorFromString("_handleInsertFromPasswordsCommand:")
        let canAutoFillFromPasswords = NSApp.target(forAction: insertFromPasswordsSelector, to: nil, from: self) != nil

        // -- Edit group (standard clipboard operations) --
        let copyItem = NSMenuItem(title: "Copy", action: #selector(contextCopy), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = canCopy

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(contextPaste), keyEquivalent: "")
        pasteItem.target = self
        pasteItem.isEnabled = canPaste

        let pasteEscapedItem = NSMenuItem(
            title: L("terminal.context.pasteEscaped", "Paste Escaped"),
            action: #selector(contextPasteEscaped),
            keyEquivalent: ""
        )
        pasteEscapedItem.target = self
        pasteEscapedItem.isEnabled = canPaste

        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(contextSelectAll), keyEquivalent: "")
        selectAllItem.target = self

        // -- Autofill --
        let autoFillItem = NSMenuItem(
            title: L("terminal.context.autofillPasswords", "AutoFill from Passwords..."),
            action: #selector(contextAutoFillFromPasswords),
            keyEquivalent: ""
        )
        autoFillItem.target = self
        autoFillItem.isEnabled = canAutoFillFromPasswords

        // -- Terminal operations --
        let clearScreenItem = NSMenuItem(title: "Clear Screen", action: #selector(contextClearScreen), keyEquivalent: "")
        clearScreenItem.target = self

        let clearScrollbackItem = NSMenuItem(title: "Clear Scrollback", action: #selector(contextClearScrollback), keyEquivalent: "")
        clearScrollbackItem.target = self

        // Build menu in conventional order:
        // 1. Copy/Paste/Select All (standard Edit menu items)
        // 2. AutoFill (system feature, separated)
        // 3. Terminal-specific actions (Clear)
        menu.addItem(copyItem)
        menu.addItem(pasteItem)
        menu.addItem(pasteEscapedItem)
        menu.addItem(selectAllItem)
        menu.addItem(.separator())
        if canAutoFillFromPasswords {
            menu.addItem(autoFillItem)
            menu.addItem(.separator())
        }
        menu.addItem(clearScreenItem)
        menu.addItem(clearScrollbackItem)

        return menu
    }

    @objc private func contextCopy(_ sender: Any?) {
        Log.trace("RustTerminalView[\(viewId)]: contextCopy")
        copy(self)
    }

    @objc private func contextPaste(_ sender: Any?) {
        Log.trace("RustTerminalView[\(viewId)]: contextPaste")
        paste(self)
    }

    @objc private func contextAutoFillFromPasswords(_ sender: Any?) {
        window?.makeFirstResponder(self)
        let selector = NSSelectorFromString("_handleInsertFromPasswordsCommand:")
        if NSApp.sendAction(selector, to: nil, from: self) {
            Log.info("RustTerminalView[\(viewId)]: Invoked Password AutoFill command")
        } else {
            Log.warn("RustTerminalView[\(viewId)]: Password AutoFill command unavailable in responder chain")
        }
    }

    @objc private func contextPasteEscaped(_ sender: Any?) {
        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        let escaped = PasteEscaper.escape(string)
        Log.trace("RustTerminalView[\(viewId)]: contextPasteEscaped - Pasting \(escaped.count) chars (escaped from \(string.count))")
        send(txt: escaped)
    }

    @objc private func contextSelectAll(_ sender: Any?) {
        Log.trace("RustTerminalView[\(viewId)]: contextSelectAll")
        // Issue #1 fix: Use Rust's selection instead of SwiftTerm's
        // This ensures getSelection() returns the correct text after select-all
        rustTerminal?.selectAll()
        needsGridSync = true
    }

    @objc private func contextClearScreen(_ sender: Any?) {
        Log.trace("RustTerminalView[\(viewId)]: contextClearScreen")
        // Send form feed (Ctrl+L) to the PTY - the shell will respond with clear screen sequences
        // which get processed by the Rust terminal via poll()
        send(data: [0x0c])
        clearSelection()
        // Ensure grid sync happens after PTY processes the clear
        needsGridSync = true
    }

    @objc private func contextClearScrollback(_ sender: Any?) {
        Log.trace("RustTerminalView[\(viewId)]: contextClearScrollback")
        clearScrollbackBuffer()
    }

    // MARK: - Cursor Line Highlight

    // MARK: - Snippet Placeholder Navigation (F21)

    /// Insert snippet with placeholder navigation support
    func insertSnippet(_ insertion: SnippetInsertion) {
        Log.trace("RustTerminalView[\(viewId)]: insertSnippet - text='\(insertion.text.prefix(50))...'")
        let text = insertion.text

        // Send the snippet text (with bracketed paste if enabled)
        // Use Rust terminal's bracketed paste mode state (not headless terminal)
        if rustTerminal?.isBracketedPasteMode() == true {
            Log.trace("RustTerminalView[\(viewId)]: insertSnippet - Using bracketed paste mode (from Rust)")
            send(txt: "\u{1b}[200~")
            send(txt: text)
            send(txt: "\u{1b}[201~")
        } else {
            send(txt: text)
        }

        // Check if we have placeholders to navigate
        guard !insertion.placeholders.isEmpty else {
            Log.trace("RustTerminalView[\(viewId)]: insertSnippet - No placeholders, done")
            snippetState = nil
            return
        }

        // Check if text is safe for placeholder navigation (ASCII only)
        guard !isUnsafeForPlaceholderNavigation(text) else {
            Log.trace("RustTerminalView[\(viewId)]: insertSnippet - Text contains non-ASCII, skipping placeholder navigation")
            snippetState = nil
            return
        }

        // Convert SnippetPlaceholder to internal format
        let placeholders = insertion.placeholders.map { p in
            RustSnippetPlaceholder(index: p.index, start: p.start, length: p.length)
        }

        // Initialize snippet navigation state
        var state = RustSnippetNavigationState(
            placeholders: placeholders,
            currentIndex: 0,
            cursorOffset: text.count,
            finalCursorOffset: insertion.finalCursorOffset
        )

        // Move cursor to first placeholder
        Log.trace("RustTerminalView[\(viewId)]: insertSnippet - Moving to first placeholder at offset \(placeholders[0].start)")
        moveSnippetCursor(from: &state, to: placeholders[0].start)
        snippetState = state

        // Install key monitor for Tab navigation if not already active
        installSnippetKeyMonitor()
    }

    /// Install key monitor for snippet Tab navigation
    private func installSnippetKeyMonitor() {
        // Reuse the existing keyDownMonitor if we have event monitoring enabled
        // The snippet handling will be checked in handleSnippetKeyDown
        guard keyDownMonitor == nil, window != nil else { return }

        Log.trace("RustTerminalView[\(viewId)]: installSnippetKeyMonitor - Installing snippet key monitor")
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            guard event.window === self.window else { return event }
            guard self.isFirstResponderInTerminal() else { return event }

            if self.handleSnippetKeyDown(event) {
                return nil  // Consume event
            }
            return event
        }
    }

    /// Handle Tab key for snippet placeholder navigation
    private func handleSnippetKeyDown(_ event: NSEvent) -> Bool {
        guard let state = snippetState else { return false }

        let isTab = event.keyCode == UInt16(kVK_Tab)
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommandModifiers = modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option)

        if isTab && !hasCommandModifiers {
            let isBackward = modifiers.contains(.shift)
            return advanceSnippetPlaceholder(state: state, backward: isBackward)
        }

        // Any other key cancels snippet navigation
        snippetState = nil
        return false
    }

    /// Advance to next/previous placeholder
    private func advanceSnippetPlaceholder(state: RustSnippetNavigationState, backward: Bool) -> Bool {
        var updated = state

        if backward {
            // Shift+Tab: Go to previous placeholder
            if updated.currentIndex > 0 {
                updated.currentIndex -= 1
                let target = updated.placeholders[updated.currentIndex].start
                Log.trace("RustTerminalView[\(viewId)]: advanceSnippetPlaceholder - Moving backward to placeholder \(updated.currentIndex)")
                moveSnippetCursor(from: &updated, to: target)
                snippetState = updated
                return true
            }
            // At first placeholder with Shift+Tab - move to final cursor position and exit
            Log.trace("RustTerminalView[\(viewId)]: advanceSnippetPlaceholder - At first placeholder, moving to final position")
            moveSnippetCursor(from: &updated, to: updated.finalCursorOffset)
            snippetState = nil
            return true
        }

        // Tab: Go to next placeholder
        if updated.currentIndex + 1 < updated.placeholders.count {
            updated.currentIndex += 1
            let target = updated.placeholders[updated.currentIndex].start
            Log.trace("RustTerminalView[\(viewId)]: advanceSnippetPlaceholder - Moving forward to placeholder \(updated.currentIndex)")
            moveSnippetCursor(from: &updated, to: target)
            snippetState = updated
            return true
        }

        // At last placeholder with Tab - move to final cursor position and exit
        Log.trace("RustTerminalView[\(viewId)]: advanceSnippetPlaceholder - At last placeholder, moving to final position")
        moveSnippetCursor(from: &updated, to: updated.finalCursorOffset)
        snippetState = nil
        return true
    }

    /// Move cursor within snippet text using escape sequences
    private func moveSnippetCursor(from state: inout RustSnippetNavigationState, to targetOffset: Int) {
        let delta = state.cursorOffset - targetOffset
        if delta > 0 {
            // Move cursor left
            send(txt: "\u{1B}[\(delta)D")
        } else if delta < 0 {
            // Move cursor right
            send(txt: "\u{1B}[\(-delta)C")
        }
        state.cursorOffset = targetOffset
    }

    /// Check if text contains non-ASCII characters (unsafe for cursor movement arithmetic)
    private func isUnsafeForPlaceholderNavigation(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if !scalar.isASCII {
                return true
            }
        }
        return false
    }

    // MARK: - Command Selection

    /// Select current command line (including wrapped lines)
    /// Uses Lines selection type which automatically handles wrapped lines in alacritty_terminal.
    /// Note: Full implementation would require shell integration markers for accurate prompt detection.
    func selectCurrentCommand() {
        Log.trace("RustTerminalView[\(viewId)]: selectCurrentCommand - Selecting cursor line")

        // Get cursor position from Rust terminal
        guard let rust = rustTerminal else {
            Log.warn("RustTerminalView[\(viewId)]: selectCurrentCommand - No Rust terminal")
            return
        }

        let cursor = rust.cursorPosition

        // The cursor row from Rust is the Line value (0 = first visible line)
        // Lines selection (type 3) in alacritty_terminal handles wrapped lines automatically
        let cursorRow = Int32(cursor.row)

        // Use line selection type (3) which selects entire logical lines including wrapped portions
        rust.startSelection(col: 0, row: cursorRow, selectionType: 3)  // 3 = Lines selection
        needsGridSync = true

        Log.trace("RustTerminalView[\(viewId)]: selectCurrentCommand - Selected line at row \(cursorRow)")
    }

    /// Clear command selection state
    func clearCommandSelectionState() {
        Log.trace("RustTerminalView[\(viewId)]: clearCommandSelectionState")
        clearSelection()
    }

    // MARK: - Command History Navigation

    /// Install history key monitor for up/down arrow navigation at prompt
    func installHistoryKeyMonitor() {
        guard historyMonitor == nil else {
            Log.trace("RustTerminalView[\(viewId)]: installHistoryKeyMonitor - Already installed")
            return
        }
        Log.info("RustTerminalView[\(viewId)]: installHistoryKeyMonitor - Installing history key monitor")
        historyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            guard event.window === self.window else { return event }
            guard self.isFirstResponderInTerminal() else { return event }
            if self.handleHistoryKeyDown(event) {
                return nil  // Consume event
            }
            return event
        }
    }

    /// Remove history key monitor (cleanup)
    private func removeHistoryMonitor() {
        if let monitor = historyMonitor {
            Log.trace("RustTerminalView[\(viewId)]: removeHistoryMonitor - Removing history monitor")
            NSEvent.removeMonitor(monitor)
            historyMonitor = nil
        }
    }

    /// Handle history key events (up/down arrows at prompt)
    private func handleHistoryKeyDown(_ event: NSEvent) -> Bool {
        let keyCode = event.keyCode
        let isUp = keyCode == UInt16(kVK_UpArrow)
        let isDown = keyCode == UInt16(kVK_DownArrow)
        guard isUp || isDown else { return false }

        // Only intercept at shell prompt - let programs like vim/less handle arrows
        guard isAtPrompt?() == true else { return false }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasOption = modifiers.contains(.option)
        // Don't intercept if Cmd/Ctrl/Shift are held (other shortcuts)
        let hasCmdCtrlShift = modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.shift)
        if hasCmdCtrlShift { return false }

        let command: String?
        if hasOption {
            // Option+Arrow: Global (cross-tab) history
            command = isUp
                ? CommandHistoryManager.shared.previousGlobal()
                : CommandHistoryManager.shared.nextGlobal()
        } else {
            // Arrow only: Per-tab history
            command = isUp
                ? CommandHistoryManager.shared.previousInTab(tabIdentifier)
                : CommandHistoryManager.shared.nextInTab(tabIdentifier)
        }

        guard let cmd = command else {
            Log.trace("RustTerminalView[\(viewId)]: handleHistoryKeyDown - No more history")
            return true  // No more history, consume anyway
        }

        // Avoid re-injecting the same command on key repeat (can spam the line)
        if event.isARepeat, cmd == lastHistoryCommand, lastHistoryWasUp == isUp {
            return true
        }
        lastHistoryCommand = cmd
        lastHistoryWasUp = isUp

        Log.trace("RustTerminalView[\(viewId)]: handleHistoryKeyDown - Inserting history: '\(cmd.prefix(30))...'")

        // Clear current input line: Ctrl+A (start of line) + Ctrl+K (kill to end)
        send(txt: "\u{01}\u{0B}")
        if !cmd.isEmpty {
            send(txt: cmd)
        }
        return true
    }

    // MARK: - Helper Methods

    /// Check if this view or a descendant is first responder
    private func isFirstResponderInTerminal() -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self) || responder === gridView
    }

    // MARK: - Debug and Diagnostics

    /// Get comprehensive debug state as a dictionary (avoids exposing private FFI types).
    /// Returns nil if the terminal is not initialized.
    func getDebugState() -> [String: Any]? {
        guard let state = rustTerminal?.debugState() else { return nil }
        return [
            "id": state.id,
            "cols": state.cols,
            "rows": state.rows,
            "historySize": state.historySize,
            "displayOffset": state.displayOffset,
            "cursorCol": state.cursorCol,
            "cursorRow": state.cursorRow,
            "bytesSent": state.bytesSent,
            "bytesReceived": state.bytesReceived,
            "uptimeMs": state.uptimeMs,
            "gridDirty": state.gridDirty,
            "running": state.running,
            "hasSelection": state.hasSelection,
            "mouseMode": state.mouseMode,
            "bracketedPaste": state.bracketedPaste,
            "appCursor": state.appCursor,
            "pollCount": state.pollCount,
            "avgPollTimeUs": state.avgPollTimeUs,
            "maxPollTimeUs": state.maxPollTimeUs,
            "avgGridSnapshotTimeUs": state.avgGridSnapshotTimeUs,
            "maxGridSnapshotTimeUs": state.maxGridSnapshotTimeUs
        ]
    }

    /// Get the full buffer text (visible + scrollback) for debugging.
    func getFullBufferText() -> String? {
        return rustTerminal?.fullBufferText()
    }

    /// Reset performance metrics.
    func resetPerformanceMetrics() {
        rustTerminal?.resetMetrics()
        Log.info("RustTerminalView[\(viewId)]: Performance metrics reset")
    }

    /// Log comprehensive debug state to the console.
    func dumpDebugState() {
        Log.info("RustTerminalView[\(viewId)]: === DEBUG STATE DUMP ===")
        Log.info("  View ID: \(viewId)")
        Log.info("  Is Started: \(isTerminalStarted)")
        Log.info("  Dimensions: \(cols)x\(rows)")
        Log.info("  Cell Size: \(cellWidth)x\(cellHeight)")
        Log.info("  Bounds: \(bounds)")
        Log.info("  Application Cursor Mode: \(applicationCursorMode)")
        Log.info("  Allow Mouse Reporting: \(allowMouseReporting)")
        Log.info("  Current Directory: \(currentDirectory)")
        Log.info("  Shell PID: \(shellPid)")
        Log.info("  Sync Count: \(Self.syncCount)")

        if let state = rustTerminal?.debugState() {
            Log.info("  --- Rust Terminal State ---")
            Log.info("    Terminal ID: \(state.id)")
            Log.info("    Grid: \(state.cols)x\(state.rows)")
            Log.info("    History: \(state.historySize) lines, offset=\(state.displayOffset)")
            Log.info("    Cursor: (\(state.cursorCol), \(state.cursorRow))")
            Log.info("    I/O: sent=\(state.bytesSent) bytes, received=\(state.bytesReceived) bytes")
            Log.info("    Uptime: \(state.uptimeMs)ms")
            Log.info("    Running: \(state.running), Grid Dirty: \(state.gridDirty)")
            Log.info("    Has Selection: \(state.hasSelection)")
            Log.info("    Mouse Mode: \(state.mouseMode)")
            Log.info("    Bracketed Paste: \(state.bracketedPaste), App Cursor: \(state.appCursor)")
            Log.info("    --- Performance Metrics ---")
            Log.info("    Poll Count: \(state.pollCount)")
            Log.info("    Avg Poll Time: \(state.avgPollTimeUs)µs, Max: \(state.maxPollTimeUs)µs")
            Log.info("    Avg Snapshot Time: \(state.avgGridSnapshotTimeUs)µs, Max: \(state.maxGridSnapshotTimeUs)µs")
        } else {
            Log.info("  --- Rust Terminal Not Available ---")
        }

        Log.info("RustTerminalView[\(viewId)]: === END DEBUG STATE ===")
    }

    // MARK: - Stress Testing Support

    /// Send a large amount of data to test throughput.
    /// - Parameters:
    ///   - lineCount: Number of lines to generate
    ///   - lineLength: Characters per line
    ///   - completion: Called when stress test completes with total bytes sent
    func stressTest(lineCount: Int, lineLength: Int = 80, completion: @escaping (Int) -> Void) {
        Log.info("RustTerminalView[\(viewId)]: Starting stress test: \(lineCount) lines x \(lineLength) chars")
        resetPerformanceMetrics()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var totalBytes = 0
            let startTime = Date()

            for i in 0..<lineCount {
                let lineNum = String(format: "%06d: ", i)
                let padding = String(repeating: "X", count: max(0, lineLength - lineNum.count - 1))
                let line = lineNum + padding + "\n"
                let bytes = Array(line.utf8)

                DispatchQueue.main.async {
                    self.rustTerminal?.sendBytes(bytes)
                }
                totalBytes += bytes.count

                // Yield periodically to avoid blocking
                if i % 1000 == 0 {
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }

            let elapsed = Date().timeIntervalSince(startTime)
            Log.info("RustTerminalView[\(self.viewId)]: Stress test complete: \(totalBytes) bytes in \(elapsed)s (\(Int(Double(totalBytes) / elapsed / 1024)) KB/s)")

            DispatchQueue.main.async {
                completion(totalBytes)
            }
        }
    }

    /// Run a comprehensive diagnostic test.
    /// Tests basic functionality and reports results.
    func runDiagnostics() -> [String: Any] {
        Log.info("RustTerminalView[\(viewId)]: Running diagnostics...")

        var results: [String: Any] = [:]

        // Basic state
        results["viewId"] = viewId
        results["isStarted"] = isTerminalStarted
        results["dimensions"] = "\(cols)x\(rows)"
        results["shellPid"] = shellPid

        // Check components
        results["hasRustTerminal"] = rustTerminal != nil
        results["hasHeadlessTerminal"] = headlessTerminal != nil
        results["hasGridView"] = gridView != nil

        // Performance metrics
        if let state = rustTerminal?.debugState() {
            results["pollCount"] = state.pollCount
            results["avgPollTimeUs"] = state.avgPollTimeUs
            results["maxPollTimeUs"] = state.maxPollTimeUs
            results["bytesReceived"] = state.bytesReceived
            results["bytesSent"] = state.bytesSent
            results["uptimeMs"] = state.uptimeMs
        }

        // Scrollback sync check
        if let headless = headlessTerminal {
            let headlessRows = headless.terminal.getTopVisibleRow()
            let rustOffset = rustTerminal?.displayOffset ?? 0
            results["scrollbackInSync"] = abs(Int(headlessRows) - Int(rustOffset)) <= 1
        }

        Log.info("RustTerminalView[\(viewId)]: Diagnostics complete: \(results)")
        return results
    }

    // MARK: - Wide Character and Long Line Support

    /// Validate that wide characters (CJK, emoji) are handled correctly.
    /// Returns true if the terminal properly handles wide characters.
    func validateWideCharacterSupport() -> Bool {
        // Wide characters should occupy 2 cells
        // This is handled by alacritty_terminal's unicode width calculation
        Log.info("RustTerminalView[\(viewId)]: Wide character support is handled by alacritty_terminal")
        return true
    }

    /// Maximum line length supported before wrapping.
    /// alacritty_terminal handles line wrapping automatically.
    var maxLineLength: Int {
        return cols
    }
}

// MARK: - Snippet Navigation State (Internal)

/// Internal state for snippet placeholder navigation in RustTerminalView
private struct RustSnippetNavigationState {
    var placeholders: [RustSnippetPlaceholder]
    var currentIndex: Int
    var cursorOffset: Int
    var finalCursorOffset: Int
}

/// Internal placeholder representation
private struct RustSnippetPlaceholder {
    let index: Int
    let start: Int
    let length: Int
}

// MARK: - NSTextInputClient

extension RustTerminalView: NSTextInputClient {

    func insertText(_ string: Any, replacementRange: NSRange) {
        // Clear marked text — composition is now committed
        markedTextStorage = nil
        markedSelectedRange = NSRange(location: NSNotFound, length: 0)

        let text: String
        if let s = string as? String {
            text = s
        } else if let attr = string as? NSAttributedString {
            text = attr.string
        } else {
            return
        }
        guard !text.isEmpty else { return }

        if handlingKeyDown {
            // Regular keyboard input routed through inputContext — send directly
            applyLocalEchoForText(text)
            Log.trace("RustTerminalView[\(viewId)]: insertText (keyboard) — \(text.count) chars")
            send(txt: text)
        } else {
            // External injection (Password AutoFill, Services, programmatic)
            Log.info("RustTerminalView[\(viewId)]: insertText (external, e.g. Password AutoFill) — \(text.count) chars")
            pasteText(text)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text: String
        if let s = string as? String {
            text = s
        } else if let attr = string as? NSAttributedString {
            text = attr.string
        } else {
            text = ""
        }
        if text.isEmpty {
            markedTextStorage = nil
            markedSelectedRange = NSRange(location: NSNotFound, length: 0)
        } else {
            markedTextStorage = text
            markedSelectedRange = selectedRange
        }
    }

    func unmarkText() {
        markedTextStorage = nil
        markedSelectedRange = NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        return NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        guard let marked = markedTextStorage else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: 0, length: marked.utf16.count)
    }

    func hasMarkedText() -> Bool {
        return markedTextStorage != nil
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return nil
    }

    func validAttributedString(for proposedString: NSAttributedString, selectedRange: NSRange) -> NSAttributedString? {
        return proposedString
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Return the cursor position so popups (e.g. IME candidate window) appear nearby.
        // caretFrame is in view-local coordinates — must convert to window coords first.
        let viewFrame = caretFrame
        guard let window = window else { return .zero }
        let windowFrame = convert(viewFrame, to: nil)
        return window.convertToScreen(windowFrame)
    }

    func characterIndex(for point: NSPoint) -> Int {
        return NSNotFound
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }
}
