import CoreText
import UIKit

/// Font-derived grid geometry. CoreText measures the terminal row and its
/// baseline; UIKit string drawing takes the top of the text line instead.
/// Keep those coordinates distinct so glyphs stay in their background/cursor row.
struct RemoteTerminalCellMetrics {
    /// Advance of the monospaced font: the horizontal distance between the
    /// origins of two adjacent cells. Measured from a representative glyph
    /// (all ASCII advances are identical in a monospaced font) and used
    /// *exactly*, rather than `ceil(max)`, which inflated every cell by ~12%
    /// and visibly loosened the character spacing.
    let cellWidth: CGFloat
    /// Height of one terminal row, in points.
    let cellHeight: CGFloat
    /// Distance from the top of a cell down to the text baseline. The glyph box occupies
    /// `[baseline - ascent, baseline + descent]` and must sit inside
    /// `[0, cellHeight]`.
    let baselineOffset: CGFloat

    /// NSString.draw(at:) expects a line origin, not a baseline. Account for
    /// the actual style font's ascender while retaining the grid's baseline.
    func textOriginOffset(for font: UIFont) -> CGFloat {
        baselineOffset - font.ascender
    }

    /// Shared by both canvas paths and the actual UIKit bitmap regressions.
    func drawGlyph(_ text: String, at cellOrigin: CGPoint, font: UIFont,
                   attributes: [NSAttributedString.Key: Any]) {
        (text as NSString).draw(
            at: CGPoint(x: cellOrigin.x, y: cellOrigin.y + textOriginOffset(for: font)),
            withAttributes: attributes
        )
    }

    var cellSize: CGSize { CGSize(width: cellWidth, height: cellHeight) }

    init(font: UIFont) {
        let ctFont = font as CTFont

        var probe = Array("0".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: probe.count)
        CTFontGetGlyphsForCharacters(ctFont, &probe, &glyphs, probe.count)
        var advances = [CGSize](repeating: .zero, count: probe.count)
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphs, &advances, advances.count)
        let advance = advances.first?.width ?? max(1, font.pointSize * 0.6)
        cellWidth = max(0.5, advance)

        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        // The cell must be tall enough for the whole line box (ink + leading).
        let lineBox = ascent + descent + leading
        cellHeight = max(1, lineBox.rounded(.up))
        // Centre the line box's ink inside the cell, then drop to the baseline.
        baselineOffset = ((cellHeight - lineBox) / 2) + ascent
    }
}

enum RemoteTerminalFontMetrics {
    static let baseFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// Cell geometry for the current rendering font.
    static func metrics(for font: UIFont = baseFont) -> RemoteTerminalCellMetrics {
        RemoteTerminalCellMetrics(font: font)
    }

    static func cellSize(for font: UIFont = baseFont) -> CGSize {
        metrics(for: font).cellSize
    }
}
