import AppKit
import CoreText

// MARK: - Rust FFI Types (matching chau7_terminal.h)

/// Cell attribute flags from Rust FFI. Shared across CPU renderer, Metal bridge, and grid view.
enum RustCellFlags {
    static let bold: UInt8 = 1 << 0
    static let italic: UInt8 = 1 << 1
    static let underline: UInt8 = 1 << 2
    static let strikethrough: UInt8 = 1 << 3
    static let inverse: UInt8 = 1 << 4
    static let dim: UInt8 = 1 << 5
    static let hidden: UInt8 = 1 << 6
    /// Mask for style flags passed to Metal (bold | italic | underline | strikethrough)
    static let metalStyleMask: UInt8 = 0x0F
}

/// C-compatible cell data matching Rust's CellData (chau7_terminal.h).
/// Single definition used by both CPU renderer and Metal bridge.
struct RustCellData {
    var character: UInt32
    var fg_r: UInt8
    var fg_g: UInt8
    var fg_b: UInt8
    var bg_r: UInt8
    var bg_g: UInt8
    var bg_b: UInt8
    var flags: UInt8
    var _pad: UInt8 // bits 0-2: underline variant
    var link_id: UInt16 // OSC 8 hyperlink ID (0 = no link)
}

/// C-compatible grid snapshot matching Rust's GridSnapshot (chau7_terminal.h).
struct RustGridSnapshot {
    var cells: UnsafeMutablePointer<RustCellData>?
    var cols: UInt16
    var rows: UInt16
    var cursor_visible: UInt8 // DECTCEM: 0 = hidden, 1 = visible
    var _pad: (UInt8, UInt8, UInt8) // Alignment padding to next UInt32
    var scrollback_rows: UInt32
    var display_offset: UInt32
    var capacity: Int // Must match Rust's usize (8 bytes on 64-bit)
}

// MARK: - Terminal Font Utilities

/// Shared font resolution and cell size computation.
/// Single source of truth used by CPU renderer, Metal renderer, settings preview, and view representable.
enum TerminalFont {
    /// Resolves an NSFont from a family name, handling SF Mono's system-restricted API.
    /// Three-tier fallback: monospacedSystemFont (SF Mono) -> NSFontManager -> NSFont(name:) -> fallback.
    static func resolveFont(family: String, size: CGFloat) -> NSFont {
        if family == "SF Mono" {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        if let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }
        if let font = NSFont(name: family, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Computes terminal cell size for a given font.
    /// Width: max advance of printable ASCII (32-126), ceil'd.
    /// Height: max of (ascent+descent+leading) and NSLayoutManager.defaultLineHeight, ceil'd.
    /// This is the single source of truth — used by both CPU and Metal renderers.
    static func cellSize(for font: NSFont) -> CGSize {
        let ctFont = font as CTFont
        var characters = (32 ... 126).map { UniChar($0) }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        CTFontGetGlyphsForCharacters(ctFont, &characters, &glyphs, characters.count)
        var advances = [CGSize](repeating: .zero, count: characters.count)
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphs, &advances, glyphs.count)
        var maxWidth: CGFloat = 0
        for i in 0 ..< glyphs.count where glyphs[i] != 0 {
            maxWidth = max(maxWidth, advances[i].width)
        }
        let width = max(1, ceil(maxWidth))

        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        let baseLineHeight = ascent + descent + leading
        let layoutManager = NSLayoutManager()
        let defaultLineHeight = layoutManager.defaultLineHeight(for: font)
        let height = max(1, ceil(max(baseLineHeight, defaultLineHeight)))

        return CGSize(width: width, height: height)
    }
}
