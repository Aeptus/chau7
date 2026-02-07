// MARK: - SwiftTerm to Metal Bridge
// Converts SwiftTerm's Terminal cell data into TerminalCell structs
// for GPU rendering via the TripleBufferedTerminal.

import Foundation
import SwiftTerm
import AppKit
import simd

/// Bridges SwiftTerm's Terminal to the Metal rendering pipeline.
/// Reads cell data from SwiftTerm, resolves colors to SIMD4<Float>,
/// and writes TerminalCell structs into the TripleBufferedTerminal.
final class SwiftTermBridge {

    // MARK: - Properties

    /// The terminal view we read cell data and colors from
    private weak var terminalView: Chau7TerminalView?

    /// Cached 256-color palette as SIMD4<Float> (avoids NSColor conversion per cell)
    private var cachedPalette: [SIMD4<Float>] = []

    /// Default foreground/background as SIMD4<Float>
    private var defaultFg: SIMD4<Float> = SIMD4(1, 1, 1, 1)
    private var defaultBg: SIMD4<Float> = SIMD4(0, 0, 0, 1)

    /// Whether the palette cache needs rebuilding
    private var paletteNeedsUpdate = true

    // MARK: - Init

    init(terminalView: Chau7TerminalView) {
        self.terminalView = terminalView
        rebuildPalette()
    }

    // MARK: - Palette

    /// Rebuilds the SIMD color palette from the terminal view's current colors.
    /// Call this when the color scheme changes.
    func rebuildPalette() {
        guard let view = terminalView else { return }

        // Cache default colors from the public API
        defaultFg = nsColorToSIMD(view.nativeForegroundColor)
        defaultBg = nsColorToSIMD(view.nativeBackgroundColor)

        // Build the 256-color ANSI palette.
        // Colors 0-15: Read from the current TerminalColorScheme
        // Colors 16-231: Standard 6x6x6 color cube
        // Colors 232-255: Grayscale ramp
        let scheme = FeatureSettings.shared.currentColorScheme
        let base16: [SIMD4<Float>] = [
            hexToSIMD(scheme.black),
            hexToSIMD(scheme.red),
            hexToSIMD(scheme.green),
            hexToSIMD(scheme.yellow),
            hexToSIMD(scheme.blue),
            hexToSIMD(scheme.magenta),
            hexToSIMD(scheme.cyan),
            hexToSIMD(scheme.white),
            hexToSIMD(scheme.brightBlack),
            hexToSIMD(scheme.brightRed),
            hexToSIMD(scheme.brightGreen),
            hexToSIMD(scheme.brightYellow),
            hexToSIMD(scheme.brightBlue),
            hexToSIMD(scheme.brightMagenta),
            hexToSIMD(scheme.brightCyan),
            hexToSIMD(scheme.brightWhite),
        ]

        var palette = [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 1), count: 256)

        // 0-15: base colors
        for i in 0..<16 {
            palette[i] = base16[i]
        }

        // 16-231: 6x6x6 color cube
        for r in 0..<6 {
            for g in 0..<6 {
                for b in 0..<6 {
                    let idx = 16 + r * 36 + g * 6 + b
                    let rv = r == 0 ? 0.0 : (Float(r) * 40.0 + 55.0) / 255.0
                    let gv = g == 0 ? 0.0 : (Float(g) * 40.0 + 55.0) / 255.0
                    let bv = b == 0 ? 0.0 : (Float(b) * 40.0 + 55.0) / 255.0
                    palette[idx] = SIMD4(rv, gv, bv, 1.0)
                }
            }
        }

        // 232-255: grayscale ramp
        for i in 0..<24 {
            let v = (Float(i) * 10.0 + 8.0) / 255.0
            palette[232 + i] = SIMD4(v, v, v, 1.0)
        }

        cachedPalette = palette
        paletteNeedsUpdate = false
    }

    /// Marks palette as needing update (call on color scheme change)
    func invalidatePalette() {
        paletteNeedsUpdate = true
    }

    // MARK: - Sync

    /// Syncs the visible terminal state into the triple buffer.
    /// Returns the number of dirty rows synced.
    @discardableResult
    func syncToTripleBuffer(_ buffer: TripleBufferedTerminal) -> Int {
        guard let view = terminalView else { return 0 }

        if paletteNeedsUpdate {
            rebuildPalette()
        }

        let terminal = view.getTerminal()
        let rows = terminal.rows
        let cols = terminal.cols
        var dirtyCount = 0

        for row in 0..<rows {
            guard let line = terminal.getLine(row: row) else { continue }
            let cellCount = min(cols, line.count)

            for col in 0..<cellCount {
                let charData = line[col]
                let cell = convertCell(charData)
                buffer.setCell(row: row, col: col, cell)
            }

            // Fill remaining columns with spaces (if line is shorter than cols)
            if cellCount < cols {
                let spaceCell = TerminalCell(
                    character: 0x20,
                    foreground: defaultFg,
                    background: defaultBg,
                    flags: 0
                )
                for col in cellCount..<cols {
                    buffer.setCell(row: row, col: col, spaceCell)
                }
            }

            dirtyCount += 1
        }

        buffer.commitUpdate()
        return dirtyCount
    }

    // MARK: - Cell Conversion

    /// Converts a single SwiftTerm CharData to a Metal TerminalCell.
    private func convertCell(_ charData: CharData) -> TerminalCell {
        let attr = charData.attribute
        let style = attr.style

        // Resolve colors
        var fg = resolveColor(attr.fg, isFg: true, isBold: style.contains(.bold))
        var bg = resolveColor(attr.bg, isFg: false, isBold: false)

        // Apply style modifiers
        if style.contains(.inverse) {
            swap(&fg, &bg)
        }

        if style.contains(.dim) {
            fg = SIMD4(fg.x * 0.6, fg.y * 0.6, fg.z * 0.6, fg.w)
        }

        if style.contains(.invisible) {
            fg = bg
        }

        // Convert style flags to bitmask
        var flags: UInt32 = 0
        if style.contains(.bold) { flags |= 1 }
        if style.contains(.italic) { flags |= 2 }
        if style.contains(.underline) { flags |= 4 }
        if style.contains(.crossedOut) { flags |= 8 }
        if style.contains(.blink) { flags |= 16 }

        // Character codepoint via public getCharacter() API
        let char = charData.getCharacter()
        let codepoint = char.unicodeScalars.first.map { UInt32($0.value) } ?? 0x20

        return TerminalCell(
            character: codepoint,
            foreground: fg,
            background: bg,
            flags: flags
        )
    }

    /// Resolves an Attribute.Color to SIMD4<Float> using the cached palette.
    private func resolveColor(_ color: Attribute.Color, isFg: Bool, isBold: Bool) -> SIMD4<Float> {
        switch color {
        case .defaultColor:
            return isFg ? defaultFg : defaultBg

        case .defaultInvertedColor:
            let base = isFg ? defaultFg : defaultBg
            return SIMD4(1.0 - base.x, 1.0 - base.y, 1.0 - base.z, base.w)

        case .ansi256(let code):
            // Map bold+dark colors to bright variants (ANSI convention)
            let idx: Int
            if isBold && code < 8 {
                idx = Int(code) + 8
            } else {
                idx = Int(code)
            }
            guard idx < cachedPalette.count else { return isFg ? defaultFg : defaultBg }
            return cachedPalette[idx]

        case .trueColor(let r, let g, let b):
            return SIMD4(
                Float(r) / 255.0,
                Float(g) / 255.0,
                Float(b) / 255.0,
                1.0
            )
        }
    }

    // MARK: - Color Utilities

    /// Converts NSColor to SIMD4<Float> (one-time cost, cached in palette).
    /// Falls back to gray if the color cannot be converted to sRGB (e.g., pattern colors).
    private func nsColorToSIMD(_ color: NSColor) -> SIMD4<Float> {
        // First try sRGB conversion (handles most calibrated and catalog colors)
        if let rgb = color.usingColorSpace(.sRGB) {
            return SIMD4(
                Float(rgb.redComponent),
                Float(rgb.greenComponent),
                Float(rgb.blueComponent),
                Float(rgb.alphaComponent)
            )
        }
        // Try component-based conversion (avoids ObjC exception from getRed on non-RGB colors)
        if let comp = color.usingType(.componentBased),
           let rgb = comp.usingColorSpace(.sRGB) {
            return SIMD4(
                Float(rgb.redComponent),
                Float(rgb.greenComponent),
                Float(rgb.blueComponent),
                Float(rgb.alphaComponent)
            )
        }
        // Ultimate fallback: mid-gray (pattern colors, etc.)
        Log.warn("SwiftTermBridge: Cannot convert color to sRGB, using fallback gray")
        return SIMD4(0.5, 0.5, 0.5, 1.0)
    }

    /// Converts hex color string (e.g. "#RRGGBB") to SIMD4<Float>
    private func hexToSIMD(_ hex: String) -> SIMD4<Float> {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let val = UInt32(h, radix: 16) else {
            return SIMD4(0.5, 0.5, 0.5, 1.0)
        }
        let r = Float((val >> 16) & 0xFF) / 255.0
        let g = Float((val >> 8) & 0xFF) / 255.0
        let b = Float(val & 0xFF) / 255.0
        return SIMD4(r, g, b, 1.0)
    }
}
